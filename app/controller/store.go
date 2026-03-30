package main

import (
	"log/slog"
	"sync"
	"time"
)

// ProvisionConfig holds the configuration for a provisioned sandbox.
type ProvisionConfig struct {
	Lifetime string `json:"lifetime"` // "unlimited", duration ("1h"), or date ("2025-12-31")
}

// PodMetrics holds resource usage for a sandbox pod.
type PodMetrics struct {
	CPUMillis int64 `json:"cpuMillis"` // CPU usage in millicores
	MemoryMiB int64 `json:"memoryMiB"` // Memory usage in MiB
	DiskMiB   int64 `json:"diskMiB"`   // Ephemeral storage in MiB
}

// Sandbox represents a single sandbox pod's state as tracked by the controller.
type Sandbox struct {
	Name             string           `json:"name"`
	State            string           `json:"state"` // idle, pending, provisioning, active, failed
	CreatedAt        time.Time        `json:"createdAt"`
	DetachedAt       *time.Time       `json:"detachedAt,omitempty"`
	ExpiresAt        *time.Time       `json:"expiresAt,omitempty"`
	Ready            bool             `json:"ready"`
	Node             string           `json:"node"`
	PodIP            string           `json:"podIP,omitempty"`
	Phase            string           `json:"phase"` // k8s pod phase
	ImageTag         string           `json:"imageTag,omitempty"`
	Config           *ProvisionConfig `json:"config,omitempty"`
	Metrics          *PodMetrics      `json:"metrics,omitempty"`
	ScheduleObserved bool             `json:"-"` // true if schedule duration metric has been emitted
	ReadyObserved    bool             `json:"-"` // true if claim-to-ready metric has been emitted
}

// StatusResponse is the response for GET /api/status.
type StatusResponse struct {
	Idle     int `json:"idle"`
	Pending  int `json:"pending"`
	Active   int `json:"active"`
	Failed   int `json:"failed"`
	Total    int `json:"total"`
	PoolSize int `json:"poolSize"`
}

// Store is the in-memory source of truth for all sandbox state.
type Store struct {
	mu        sync.RWMutex
	sandboxes map[string]*Sandbox
	poolSize  int
}

// NewStore creates a new store with the given pool size target.
func NewStore(poolSize int) *Store {
	return &Store{
		sandboxes: make(map[string]*Sandbox),
		poolSize:  poolSize,
	}
}

// SetPoolSize updates the target pool size.
func (s *Store) SetPoolSize(size int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.poolSize = size
}

// GetPoolSize returns the current pool size target.
func (s *Store) GetPoolSize() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.poolSize
}

// Upsert adds or updates a sandbox entry.
func (s *Store) Upsert(sb *Sandbox) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sandboxes[sb.Name] = sb
}

// Remove deletes a sandbox by name.
func (s *Store) Remove(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sandboxes, name)
}

// ResetObservations clears the observation flags on all sandboxes so metrics can be re-emitted.
// Only resets ReadyObserved for idle pods — claimed pods should not be re-measured.
func (s *Store) ResetObservations() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sb := range s.sandboxes {
		sb.ScheduleObserved = false
		if sb.State == "idle" || sb.State == "pending" {
			sb.ReadyObserved = false
		}
	}
}

// Get returns a sandbox by name.
func (s *Store) Get(name string) (*Sandbox, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sb, ok := s.sandboxes[name]
	return sb, ok
}

// List returns all sandboxes.
func (s *Store) List() []*Sandbox {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Sandbox, 0, len(s.sandboxes))
	for _, sb := range s.sandboxes {
		result = append(result, sb)
	}
	return result
}

// ClaimIdle atomically finds the first idle sandbox and marks it as "provisioning".
// Returns nil if no idle sandbox is available. Uses a write lock to prevent
// two concurrent callers from claiming the same sandbox.
func (s *Store) ClaimIdle() *Sandbox {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sb := range s.sandboxes {
		if sb.State == "idle" {
			sb.State = "provisioning"
			return sb
		}
	}
	return nil
}

// Status returns aggregated counts.
func (s *Store) Status() StatusResponse {
	s.mu.RLock()
	defer s.mu.RUnlock()
	resp := StatusResponse{PoolSize: s.poolSize}
	for _, sb := range s.sandboxes {
		switch sb.State {
		case "idle":
			resp.Idle++
		case "pending":
			resp.Pending++
		case "active", "provisioning":
			resp.Active++
		case "failed":
			resp.Failed++
		}
		resp.Total++
	}
	return resp
}

// Prune removes sandboxes not present in the given set of live pod names.
func (s *Store) Prune(liveNames map[string]bool) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	pruned := 0
	for name := range s.sandboxes {
		if !liveNames[name] {
			slog.Info("pruning stale sandbox from store", "name", name)
			delete(s.sandboxes, name)
			pruned++
		}
	}
	return pruned
}
