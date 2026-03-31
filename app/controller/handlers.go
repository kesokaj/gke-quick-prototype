package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// Handlers holds HTTP handler dependencies.
type Handlers struct {
	client     kubernetes.Interface
	restConfig *rest.Config
	store      *Store
	namespace  string // target namespace for sandbox pods
	deployName string
	kickCh     chan struct{} // signal reconciler to sync immediately
}

// NewHandlers creates a new handlers instance.
func NewHandlers(client kubernetes.Interface, restConfig *rest.Config, store *Store, namespace, deployName string, kickCh chan struct{}) *Handlers {
	return &Handlers{client: client, restConfig: restConfig, store: store, namespace: namespace, deployName: deployName, kickCh: kickCh}
}

// ProvisionRequest is the JSON body for POST /api/provision.
type ProvisionRequest struct {
	Lifetime string `json:"lifetime"` // "unlimited" (default), duration "1h", or date "2025-12-31"
}

// ProvisionResponse is returned after provisioning.
type ProvisionResponse struct {
	Name      string     `json:"name"`
	Node      string     `json:"node"`
	PodIP     string     `json:"podIP"`
	State     string     `json:"state"`
	ExpiresAt *time.Time `json:"expiresAt,omitempty"`
}

// PoolSizeRequest is the JSON body for PUT /api/pool-size.
type PoolSizeRequest struct {
	Size int `json:"size"`
}

// RegisterRoutes sets up all HTTP routes.
func (h *Handlers) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/status", h.handleStatus)
	mux.HandleFunc("GET /api/sandboxes", h.handleListSandboxes)
	mux.HandleFunc("GET /api/sandboxes/", h.handleSandboxGet)

	mux.HandleFunc("PUT /api/pool-size", h.handleSetPoolSize)

	mux.HandleFunc("POST /api/provision", h.handleProvision)
	mux.HandleFunc("POST /api/sandboxes/", h.handleSandboxAction)
	mux.HandleFunc("DELETE /api/sandboxes/", h.handleDeleteSandbox)
	mux.HandleFunc("DELETE /api/claimed", h.handleDeleteAllClaimed)

	mux.HandleFunc("GET /api/metrics/summary", h.handleMetricsSummary)
	mux.HandleFunc("POST /api/metrics/reset", h.handleMetricsReset)

	mux.HandleFunc("GET /healthz", h.handleHealthz)
}

func (h *Handlers) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.store.Status())
}

func (h *Handlers) handleListSandboxes(w http.ResponseWriter, r *http.Request) {
	sandboxes := h.store.List()
	writeJSON(w, http.StatusOK, sandboxes)
}

func (h *Handlers) handleSetPoolSize(w http.ResponseWriter, r *http.Request) {
	var req PoolSizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
		return
	}

	if req.Size < 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "pool size must be >= 0"})
		return
	}

	// Patch Deployment replicas — K8s is the source of truth.
	patch := fmt.Sprintf(`{"spec":{"replicas":%d}}`, req.Size)
	_, err := h.client.AppsV1().Deployments(h.namespace).Patch(
		r.Context(), h.deployName, types.MergePatchType, []byte(patch), metav1.PatchOptions{},
	)
	if err != nil {
		slog.Error("failed to patch deployment replicas", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to set replicas: " + err.Error()})
		return
	}

	old := h.store.GetPoolSize()
	h.store.SetPoolSize(req.Size)
	slog.Info("pool size changed", "from", old, "to", req.Size)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"poolSize": req.Size,
		"previous": old,
	})
}

func (h *Handlers) handleProvision(w http.ResponseWriter, r *http.Request) {
	var req ProvisionRequest

	if r.Body != nil && r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
			return
		}
	}

	if req.Lifetime == "" {
		req.Lifetime = "5m"
	}

	var expiresAt *time.Time
	if req.Lifetime != "unlimited" {
		t, err := parseExpiry(req.Lifetime)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid lifetime: " + err.Error()})
			return
		}
		maxExpiry := time.Now().Add(2 * time.Hour)
		if t.After(maxExpiry) {
			t = maxExpiry
		}
		expiresAt = &t
	}

	sb := h.store.ClaimIdle()
	if sb == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "no idle sandboxes available"})
		return
	}

	slog.Info("provisioning sandbox", "name", sb.Name, "lifetime", req.Lifetime)
	claimStart := time.Now()

	// Detach from Deployment: warmpool=false orphans the pod and
	// K8s auto-creates a replacement.
	claimedAt := time.Now().Format(time.RFC3339)
	patch := fmt.Sprintf(`{"metadata":{"labels":{"warmpool":"false"},"annotations":{"sandbox.gvisor/state":"claimed","sandbox.gvisor/claimed-at":"%s"}}}`, claimedAt)
	_, err := h.client.CoreV1().Pods(h.namespace).Patch(
		r.Context(), sb.Name, types.MergePatchType, []byte(patch), metav1.PatchOptions{},
	)
	if err != nil {
		slog.Error("failed to detach pod", "name", sb.Name, "error", err)
		// Rollback to idle so it can be claimed again.
		sb.State = "idle"
		h.store.Upsert(sb)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to claim: " + err.Error()})
		return
	}

	now := time.Now()
	sb.DetachedAt = &now
	sb.ExpiresAt = expiresAt
	sb.Config = &ProvisionConfig{
		Lifetime: req.Lifetime,
	}

	claimDuration := time.Since(claimStart).Seconds()
	sandboxClaimToReady.Observe(claimDuration)
	sb.ReadyObserved = true
	slog.Info("metric: claim-to-ready", "name", sb.Name, "duration_s", fmt.Sprintf("%.3f", claimDuration))

	h.store.Upsert(sb)
	sandboxClaimTotal.Inc()

	select {
	case h.kickCh <- struct{}{}:
	default:
	}

	writeJSON(w, http.StatusOK, ProvisionResponse{
		Name:      sb.Name,
		Node:      sb.Node,
		PodIP:     sb.PodIP,
		State:     sb.State,
		ExpiresAt: expiresAt,
	})
}

// ---------- GET /api/sandboxes/{name}[/logs|/events] ----------

func (h *Handlers) handleSandboxGet(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimSuffix(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing sandbox name"})
		return
	}

	// Sub-resource: /api/sandboxes/{name}/logs|events|terminal|status
	lastPart := parts[len(parts)-1]
	switch lastPart {
	case "logs":
		name := parts[len(parts)-2]
		h.handleLogs(w, r, name)
	case "events":
		name := parts[len(parts)-2]
		h.handleEvents(w, r, name)
	case "terminal":
		name := parts[len(parts)-2]
		h.handleTerminal(w, r, name)
	case "status":
		name := parts[len(parts)-2]
		h.handleSandboxStatus(w, r, name)
	default:
		name := lastPart
		sb, ok := h.store.Get(name)
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
			return
		}
		writeJSON(w, http.StatusOK, sb)
	}
}

// handleSandboxStatus proxies the /_sandbox/status endpoint from the pod.
func (h *Handlers) handleSandboxStatus(w http.ResponseWriter, r *http.Request, name string) {
	sb, ok := h.store.Get(name)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
		return
	}
	if sb.PodIP == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "pod IP not available"})
		return
	}

	statusURL := fmt.Sprintf("http://%s:3004/_sandbox/status", sb.PodIP)
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(statusURL)
	if err != nil {
		slog.Warn("failed to proxy sandbox status", "name", name, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "failed to reach sandbox: " + err.Error()})
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// ---------- POST /api/sandboxes/{name}/{action} ----------

func (h *Handlers) handleSandboxAction(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimSuffix(r.URL.Path, "/"), "/")
	if len(parts) < 5 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "expected /api/sandboxes/{name}/{action}"})
		return
	}
	name := parts[len(parts)-2]
	action := parts[len(parts)-1]

	switch action {
	case "restart":
		h.handleRestart(w, r, name)
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown action: " + action})
	}
}

func (h *Handlers) handleRestart(w http.ResponseWriter, r *http.Request, name string) {
	_, ok := h.store.Get(name)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
		return
	}

	slog.Info("restarting sandbox", "name", name)

	// Delete the pod — Deployment controller recreates it.
	grace := int64(0)
	err := h.client.CoreV1().Pods(h.namespace).Delete(
		r.Context(), name, metav1.DeleteOptions{GracePeriodSeconds: &grace},
	)
	if err != nil {
		slog.Error("failed to delete pod for restart", "name", name, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "restart failed: " + err.Error()})
		return
	}

	h.store.Remove(name)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"restarted": true,
		"name":      name,
	})
}

func (h *Handlers) handleDeleteSandbox(w http.ResponseWriter, r *http.Request) {
	name := extractName(r.URL.Path)
	if name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing sandbox name"})
		return
	}

	slog.Info("deleting sandbox", "name", name)

	grace := int64(0)
	err := h.client.CoreV1().Pods(h.namespace).Delete(
		r.Context(), name, metav1.DeleteOptions{GracePeriodSeconds: &grace},
	)
	if err != nil {
		slog.Error("failed to delete pod", "name", name, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "delete failed: " + err.Error()})
		return
	}

	h.store.Remove(name)
	writeJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (h *Handlers) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handlers) handleMetricsSummary(w http.ResponseWriter, r *http.Request) {
	schedule := extractHistogramSummary(sandboxScheduleDuration)
	claimToReady := extractHistogramSummary(sandboxClaimToReady)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"scheduleDuration": schedule,
		"claimToReady":     claimToReady,
	})
}

func (h *Handlers) handleMetricsReset(w http.ResponseWriter, r *http.Request) {
	resetMetrics()
	h.store.ResetObservations()
	slog.Info("metrics reset by user")
	writeJSON(w, http.StatusOK, map[string]string{"status": "reset"})
}

func (h *Handlers) handleLogs(w http.ResponseWriter, r *http.Request, name string) {
	_, ok := h.store.Get(name)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
		return
	}

	tailLines := int64(100)
	opts := &corev1.PodLogOptions{
		TailLines: &tailLines,
	}

	req := h.client.CoreV1().Pods(h.namespace).GetLogs(name, opts)
	stream, err := req.Stream(r.Context())
	if err != nil {
		slog.Error("failed to stream pod logs", "name", name, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "logs unavailable: " + err.Error()})
		return
	}
	defer stream.Close()

	logs, err := io.ReadAll(stream)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to read logs"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"name": name, "logs": string(logs)})
}

func (h *Handlers) handleEvents(w http.ResponseWriter, r *http.Request, name string) {
	_, ok := h.store.Get(name)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
		return
	}

	events, err := h.client.CoreV1().Events(h.namespace).List(r.Context(), metav1.ListOptions{
		FieldSelector: "involvedObject.name=" + name,
	})
	if err != nil {
		slog.Error("failed to list events", "name", name, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "events unavailable"})
		return
	}

	type eventInfo struct {
		Type    string `json:"type"`
		Reason  string `json:"reason"`
		Message string `json:"message"`
		Age     string `json:"age"`
		Count   int32  `json:"count"`
	}
	result := make([]eventInfo, 0, len(events.Items))
	for _, e := range events.Items {
		age := time.Since(e.LastTimestamp.Time).Truncate(time.Second).String()
		result = append(result, eventInfo{
			Type:    e.Type,
			Reason:  e.Reason,
			Message: e.Message,
			Age:     age,
			Count:   e.Count,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"name": name, "events": result})
}

// parseExpiry parses a lifetime string: duration ("1h", "30m") or date ("2025-12-31").
func parseExpiry(lifetime string) (time.Time, error) {
	if len(lifetime) == 10 && lifetime[4] == '-' && lifetime[7] == '-' {
		t, err := time.Parse("2006-01-02", lifetime)
		if err == nil {
			return t.Add(23*time.Hour + 59*time.Minute + 59*time.Second), nil // end of day
		}
	}

	d, err := time.ParseDuration(lifetime)
	if err != nil {
		return time.Time{}, fmt.Errorf("use duration (1h, 30m) or date (2025-12-31): %w", err)
	}

	return time.Now().Add(d), nil
}

func (h *Handlers) handleDeleteAllClaimed(w http.ResponseWriter, r *http.Request) {
	pods, err := h.client.CoreV1().Pods(h.namespace).List(r.Context(), metav1.ListOptions{
		LabelSelector: "managed-by=warmpool,warmpool=false",
	})
	if err != nil {
		slog.Error("failed to list claimed pods", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	deleted := 0
	grace := int64(0)
	for i := range pods.Items {
		name := pods.Items[i].Name
		if err := h.client.CoreV1().Pods(h.namespace).Delete(r.Context(), name, metav1.DeleteOptions{
			GracePeriodSeconds: &grace,
		}); err == nil {
			h.store.Remove(name)
			deleted++
		} else {
			slog.Error("failed to delete claimed pod", "name", name, "error", err)
		}
	}

	select {
	case h.kickCh <- struct{}{}:
	default:
	}
	slog.Info("killed all claimed pods", "deleted", deleted, "total", len(pods.Items))
	writeJSON(w, http.StatusOK, map[string]interface{}{"deleted": deleted})
}

func extractName(path string) string {
	parts := strings.Split(strings.TrimSuffix(path, "/"), "/")
	if len(parts) < 4 {
		return ""
	}
	return parts[len(parts)-1]
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("failed to encode JSON response", "error", err)
	}
}
