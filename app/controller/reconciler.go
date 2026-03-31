package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	metricsClient "k8s.io/metrics/pkg/client/clientset/versioned"
)

// Reconciler watches kube-api and maintains the store.
type Reconciler struct {
	client        kubernetes.Interface
	restConfig    *rest.Config
	metricsClient metricsClient.Interface
	store         *Store
	namespace     string
	deployName    string
	httpClient    *http.Client // reusable client for pod health checks
	kickCh        chan struct{} // non-blocking signal to trigger immediate sync
}

// NewReconciler creates a new reconciler.
func NewReconciler(client kubernetes.Interface, restConfig *rest.Config, mc metricsClient.Interface, store *Store, namespace, deployName string, kickCh chan struct{}) *Reconciler {
	return &Reconciler{
		client:        client,
		restConfig:    restConfig,
		metricsClient: mc,
		store:         store,
		namespace:     namespace,
		deployName:    deployName,
		httpClient: &http.Client{
			Timeout: 2 * time.Second,
			Transport: &http.Transport{
				MaxIdleConns:        50,
				MaxIdleConnsPerHost: 5,
				IdleConnTimeout:     30 * time.Second,
			},
		},
		kickCh: kickCh,
	}
}

// Run starts the reconciler loop.
func (r *Reconciler) Run(ctx context.Context) {
	slog.Info("reconciler started", "namespace", r.namespace, "deploy", r.deployName)
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("reconciler stopped")
			return
		case <-ticker.C:
			r.sync(ctx)
		case <-r.kickCh:
			for len(r.kickCh) > 0 {
				<-r.kickCh
			}
			r.sync(ctx)
		}
	}
}

// sync fetches pod state from kube-api and updates the store.
func (r *Reconciler) sync(ctx context.Context) {
	syncStart := time.Now()
	defer func() {
		slog.Debug("sync completed", "duration_ms", time.Since(syncStart).Milliseconds())
	}()

	pods, err := r.client.CoreV1().Pods(r.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "managed-by=warmpool",
	})
	if err != nil {
		slog.Error("failed to list pods", "error", err)
		return
	}

	// Deployment replicas is the source of truth for pool size.
	deploy, err := r.client.AppsV1().Deployments(r.namespace).Get(ctx, r.deployName, metav1.GetOptions{})
	if err == nil && deploy.Spec.Replicas != nil {
		r.store.SetPoolSize(int(*deploy.Spec.Replicas))
	}

	// Fetch metrics concurrently — don't block pod state sync.
	metricsCh := make(chan map[string]*PodMetrics, 1)
	go func() {
		metricsCh <- r.fetchMetrics(ctx)
	}()

	liveNames := make(map[string]bool, len(pods.Items))

	// Wait for metrics (ran concurrently during pod list).
	metricsMap := <-metricsCh

	for i := range pods.Items {
		pod := &pods.Items[i]

		if pod.DeletionTimestamp != nil {
			continue
		}

		liveNames[pod.Name] = true

		state := "idle"
		if pod.Labels["warmpool"] == "false" {
			state = "active"
		}

		if state == "idle" && pod.Status.Phase != corev1.PodRunning {
			state = "pending"
		}

		if pod.Status.Phase == "Failed" || pod.Status.Phase == "Unknown" {
			state = "failed"
		}
		for _, cs := range pod.Status.ContainerStatuses {
			if cs.State.Waiting != nil {
				reason := cs.State.Waiting.Reason
				if reason == "CrashLoopBackOff" || reason == "ImagePullBackOff" || reason == "ErrImagePull" {
					state = "failed"
				}
			}
			if cs.State.Terminated != nil && cs.State.Terminated.ExitCode != 0 {
				state = "failed"
			}
		}

		existing, exists := r.store.Get(pod.Name)
		podReady := isPodReady(pod)

		sb := &Sandbox{
			Name:      pod.Name,
			State:     state,
			CreatedAt: pod.CreationTimestamp.Time,
			Node:      pod.Spec.NodeName,
			PodIP:     pod.Status.PodIP,
			Phase:     string(pod.Status.Phase),
			Ready:     podReady,
			ImageTag:  extractImageTag(pod),
		}

		if m, ok := metricsMap[pod.Name]; ok {
			sb.Metrics = m
		}

		if exists {
			sb.Config = existing.Config
			sb.DetachedAt = existing.DetachedAt
			sb.ExpiresAt = existing.ExpiresAt
			sb.ScheduleObserved = existing.ScheduleObserved
			sb.ReadyObserved = existing.ReadyObserved
		}

		// Detect detach time for newly-active pods.
		if state == "active" && !exists {
			// Use claimed-at annotation for accurate timing after controller restart.
			if claimedAt, ok := pod.Annotations["sandbox.gvisor/claimed-at"]; ok {
				if t, err := time.Parse(time.RFC3339, claimedAt); err == nil {
					sb.DetachedAt = &t
				}
			}
			if sb.DetachedAt == nil {
				now := time.Now()
				sb.DetachedAt = &now
			}
			sb.ReadyObserved = true
		}
		if state == "active" && exists && existing.State == "idle" {
			now := time.Now()
			sb.DetachedAt = &now
		}

		// Record schedule duration when a pod first becomes Ready.
		if state == "idle" && podReady && !sb.ScheduleObserved {
			duration := podReadyDuration(pod)
			sandboxScheduleDuration.Observe(duration)
			sb.ScheduleObserved = true
			slog.Info("metric: sandbox scheduled", "name", sb.Name, "duration_s", fmt.Sprintf("%.3f", duration))
		}

		r.store.Upsert(sb)
	}

	r.store.Prune(liveNames)
	r.updateGauges()
	r.gc(ctx)
	r.gcCompletedPods(ctx)

	// No ensurePoolSize() needed: the Deployment controller handles replica
	// replacement natively when a pod is detached (warmpool=false).
}

// fetchMetrics retrieves CPU/memory for all pods via k8s Metrics API.
func (r *Reconciler) fetchMetrics(ctx context.Context) map[string]*PodMetrics {
	result := make(map[string]*PodMetrics)

	if r.metricsClient == nil {
		return result
	}

	podMetricsList, err := r.metricsClient.MetricsV1beta1().PodMetricses(r.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "managed-by=warmpool",
	})
	if err != nil {
		slog.Debug("failed to fetch pod metrics", "error", err)
		return result
	}

	for i := range podMetricsList.Items {
		pm := &podMetricsList.Items[i]
		m := &PodMetrics{}
		for _, c := range pm.Containers {
			cpu := c.Usage[corev1.ResourceCPU]
			mem := c.Usage[corev1.ResourceMemory]
			ephemeral := c.Usage[corev1.ResourceEphemeralStorage]

			m.CPUMillis += cpu.MilliValue()
			m.MemoryMiB += mem.Value() / (1024 * 1024)
			m.DiskMiB += ephemeral.Value() / (1024 * 1024)
		}
		result[pm.Name] = m
	}

	return result
}

// gc garbage-collects pods that should be cleaned up. The controller owns the
// full lifecycle: TTL expiry, failed/crashed/OOM pods, and stale unlimited pods.
func (r *Reconciler) gc(ctx context.Context) {
	now := time.Now()
	const maxUnlimitedLifetime = 24 * time.Hour

	for _, sb := range r.store.List() {
		var reason string

		switch {
		case sb.State == "active" && sb.ExpiresAt != nil && now.After(*sb.ExpiresAt):
			reason = "ttl_expired"

		case sb.State == "failed":
			reason = "failed"

		case sb.State == "active" && sb.Phase != "Running" && sb.Phase != "Pending":
			reason = "exited"

		case sb.State == "active" && sb.ExpiresAt == nil && sb.DetachedAt != nil && now.Sub(*sb.DetachedAt) > maxUnlimitedLifetime:
			reason = "stale"

		default:
			continue
		}

		slog.Info("gc: deleting pod", "name", sb.Name, "reason", reason, "state", sb.State, "phase", sb.Phase)
		sandboxGCTotal.WithLabelValues(reason).Inc()

		grace := int64(0)
		err := r.client.CoreV1().Pods(r.namespace).Delete(ctx, sb.Name, metav1.DeleteOptions{
			GracePeriodSeconds: &grace,
		})
		if err != nil {
			slog.Error("gc: failed to delete pod", "name", sb.Name, "reason", reason, "error", err)
		} else {
			r.store.Remove(sb.Name)
		}
	}
}

// gcCompletedPods deletes Succeeded/Failed pods that are not managed by the warmpool
// (e.g. bench-curl-* pods from benchmarks, one-off debug pods).
// Cleans both the sandbox namespace and the controller namespace.
func (r *Reconciler) gcCompletedPods(ctx context.Context) {
	for _, ns := range []string{r.namespace, "sandbox-control"} {
		pods, err := r.client.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{
			FieldSelector: "status.phase=Succeeded",
		})
		if err != nil {
			continue
		}

		for i := range pods.Items {
			pod := &pods.Items[i]
			if time.Since(pod.CreationTimestamp.Time) < 2*time.Minute {
				continue
			}
			grace := int64(0)
			if err := r.client.CoreV1().Pods(ns).Delete(ctx, pod.Name, metav1.DeleteOptions{
				GracePeriodSeconds: &grace,
			}); err == nil {
				slog.Info("gc: cleaned completed pod", "name", pod.Name, "namespace", ns, "phase", string(pod.Status.Phase))
			}
		}
	}
}

// extractImageTag returns the tag portion of the first container's image.
func extractImageTag(pod *corev1.Pod) string {
	if len(pod.Spec.Containers) == 0 {
		return ""
	}
	image := pod.Spec.Containers[0].Image
	if i := strings.LastIndex(image, ":"); i >= 0 {
		return image[i+1:]
	}
	return "latest"
}

// updateGauges refreshes all Prometheus gauge metrics from the current store state.
func (r *Reconciler) updateGauges() {
	status := r.store.Status()

	sandboxPoolSize.Set(float64(status.PoolSize))
	sandboxStateCount.WithLabelValues("idle").Set(float64(status.Idle))
	sandboxStateCount.WithLabelValues("pending").Set(float64(status.Pending))
	sandboxStateCount.WithLabelValues("active").Set(float64(status.Active))
	sandboxStateCount.WithLabelValues("failed").Set(float64(status.Failed))
}

// isPodReady returns true if the pod has a Ready condition set to True.
func isPodReady(pod *corev1.Pod) bool {
	for _, c := range pod.Status.Conditions {
		if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

// podReadyDuration returns the time from pod creation to the Ready condition
// becoming True. Uses the condition's LastTransitionTime for precision.
func podReadyDuration(pod *corev1.Pod) float64 {
	for _, c := range pod.Status.Conditions {
		if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
			if !c.LastTransitionTime.IsZero() {
				return c.LastTransitionTime.Time.Sub(pod.CreationTimestamp.Time).Seconds()
			}
		}
	}
	return time.Since(pod.CreationTimestamp.Time).Seconds()
}
