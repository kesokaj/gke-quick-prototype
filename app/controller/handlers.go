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
	// Status & listing.
	mux.HandleFunc("GET /api/status", h.handleStatus)
	mux.HandleFunc("GET /api/sandboxes", h.handleListSandboxes)
	mux.HandleFunc("GET /api/sandboxes/", h.handleSandboxGet) // detail, logs, events

	// Pool management.
	mux.HandleFunc("PUT /api/pool-size", h.handleSetPoolSize)

	// Sandbox lifecycle.
	mux.HandleFunc("POST /api/provision", h.handleProvision)
	mux.HandleFunc("POST /api/sandboxes/", h.handleSandboxAction) // actions
	mux.HandleFunc("DELETE /api/sandboxes/", h.handleDeleteSandbox)

	// Metrics summary (for UI).
	mux.HandleFunc("GET /api/metrics/summary", h.handleMetricsSummary)
	mux.HandleFunc("POST /api/metrics/reset", h.handleMetricsReset)

	// Health.
	mux.HandleFunc("GET /healthz", h.handleHealthz)
}

// ---------- Status + Listing ----------

func (h *Handlers) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.store.Status())
}

func (h *Handlers) handleListSandboxes(w http.ResponseWriter, r *http.Request) {
	sandboxes := h.store.List()
	writeJSON(w, http.StatusOK, sandboxes)
}

// ---------- Pool Management ----------

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

	// Patch Deployment replicas directly — K8s is the source of truth.
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

// ---------- Provision ----------

func (h *Handlers) handleProvision(w http.ResponseWriter, r *http.Request) {
	var req ProvisionRequest

	// Parse optional JSON body.
	if r.Body != nil && r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
			return
		}
	}

	// Default: 5 minute lifetime. The controller owns the lifecycle.
	if req.Lifetime == "" {
		req.Lifetime = "5m"
	}

	// Parse expiry.
	var expiresAt *time.Time
	if req.Lifetime != "unlimited" {
		t, err := parseExpiry(req.Lifetime)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid lifetime: " + err.Error()})
			return
		}
		// Cap at 2 hours max.
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

	// Detach pod from Deployment by changing warmpool=false.
	// This orphans the pod — K8s does NOT terminate orphans.
	// The Deployment sees fewer matching pods and auto-creates a replacement.
	claimedAt := time.Now().Format(time.RFC3339)
	patch := fmt.Sprintf(`{"metadata":{"labels":{"warmpool":"false"},"annotations":{"sandbox.gvisor/state":"claimed","sandbox.gvisor/claimed-at":"%s"}}}`, claimedAt)
	_, err := h.client.CoreV1().Pods(h.namespace).Patch(
		r.Context(), sb.Name, types.MergePatchType, []byte(patch), metav1.PatchOptions{},
	)
	if err != nil {
		slog.Error("failed to detach pod", "name", sb.Name, "error", err)
		// Rollback: restore to idle so it can be claimed again.
		sb.State = "idle"
		h.store.Upsert(sb)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to claim: " + err.Error()})
		return
	}

	// Update state.
	now := time.Now()
	sb.DetachedAt = &now
	sb.ExpiresAt = expiresAt
	sb.Config = &ProvisionConfig{
		Lifetime: req.Lifetime,
	}

	h.store.Upsert(sb)

	// Kick the reconciler to sync immediately (non-blocking).
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

// ---------- Sandbox Actions (restart) ----------

// ---------- GET /api/sandboxes/{name}[/logs|/events] ----------

func (h *Handlers) handleSandboxGet(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimSuffix(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing sandbox name"})
		return
	}

	// Check for sub-resource: /api/sandboxes/{name}/logs|events|terminal
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
	default:
		// Direct sandbox lookup: /api/sandboxes/{name}
		name := lastPart
		sb, ok := h.store.Get(name)
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
			return
		}
		writeJSON(w, http.StatusOK, sb)
	}
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
	sb, ok := h.store.Get(name)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "sandbox not found"})
		return
	}

	slog.Info("restarting sandbox", "name", name)

	// Delete the pod — the Deployment controller will recreate it.
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
	_ = sb // silences unused warning

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"restarted": true,
		"name":      name,
	})
}

// ---------- Delete ----------

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

// ---------- Health ----------

func (h *Handlers) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ---------- Metrics Summary (for UI) ----------

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

// ---------- Logs ----------

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

// ---------- Events ----------

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

// ---------- Helpers ----------

// parseExpiry parses a lifetime string: duration ("1h", "30m") or date ("2025-12-31").
func parseExpiry(lifetime string) (time.Time, error) {
	// Try as date first (YYYY-MM-DD).
	if len(lifetime) == 10 && lifetime[4] == '-' && lifetime[7] == '-' {
		t, err := time.Parse("2006-01-02", lifetime)
		if err == nil {
			return t.Add(23*time.Hour + 59*time.Minute + 59*time.Second), nil // end of day
		}
	}

	// Try as Go duration.
	d, err := time.ParseDuration(lifetime)
	if err != nil {
		return time.Time{}, fmt.Errorf("use duration (1h, 30m) or date (2025-12-31): %w", err)
	}

	return time.Now().Add(d), nil
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
