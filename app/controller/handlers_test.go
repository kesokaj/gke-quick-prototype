package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clienttesting "k8s.io/client-go/testing"

	"k8s.io/client-go/kubernetes/fake"
)

// patchMetadata mirrors the structure we expect to see in the JSON merge patch.
type patchMetadata struct {
	Labels          map[string]string          `json:"labels,omitempty"`
	Annotations     map[string]string          `json:"annotations,omitempty"`
	OwnerReferences []metav1.OwnerReference    `json:"ownerReferences"`
}

type patchPayload struct {
	Metadata patchMetadata `json:"metadata"`
}

// TestProvisionPatchClearsOwnerReferences verifies that the /api/provision handler
// sends a patch that atomically clears ownerReferences alongside the label change.
func TestProvisionPatchClearsOwnerReferences(t *testing.T) {
	// Create a fake pod that simulates an idle warmpool pod with an ownerReference
	// pointing to a ReplicaSet (as K8s would set up).
	rsUID := types.UID("rs-uid-12345")
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "sandbox-pool-abc123",
			Namespace: "sandbox",
			Labels: map[string]string{
				"managed-by": "warmpool",
				"warmpool":   "true",
			},
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion: "apps/v1",
					Kind:       "ReplicaSet",
					Name:       "sandbox-pool-7f8d9c6b5",
					UID:        rsUID,
					Controller: boolPtr(true),
				},
			},
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			PodIP: "10.0.0.42",
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
		},
		Spec: corev1.PodSpec{
			NodeName: "node-1",
		},
	}

	client := fake.NewSimpleClientset(pod)

	// Capture the patch action so we can inspect it.
	var capturedPatch []byte
	client.PrependReactor("patch", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		patchAction := action.(clienttesting.PatchAction)
		capturedPatch = patchAction.GetPatch()
		// Return the pod as-is; we only care about the patch content.
		return false, nil, nil
	})

	store := NewStore(10)
	store.Upsert(&Sandbox{
		Name:  pod.Name,
		State: "idle",
		Node:  "node-1",
		PodIP: "10.0.0.42",
	})

	kickCh := make(chan struct{}, 1)
	h := NewHandlers(client, nil, store, "sandbox", "sandbox-pool", kickCh)

	body := bytes.NewBufferString(`{"lifetime":"5m"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/provision", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	h.handleProvision(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// --- Verify the patch payload ---
	if capturedPatch == nil {
		t.Fatal("no patch was captured; provision did not patch the pod")
	}

	var patch patchPayload
	if err := json.Unmarshal(capturedPatch, &patch); err != nil {
		t.Fatalf("failed to unmarshal patch: %v\npatch bytes: %s", err, string(capturedPatch))
	}

	// 1. Label must be changed to "false"
	if patch.Metadata.Labels["warmpool"] != "false" {
		t.Errorf("expected warmpool label 'false', got %q", patch.Metadata.Labels["warmpool"])
	}

	// 2. ownerReferences must be explicitly set to an empty array
	if patch.Metadata.OwnerReferences == nil {
		t.Fatal("ownerReferences field is nil (missing from patch); must be an empty array []")
	}
	if len(patch.Metadata.OwnerReferences) != 0 {
		t.Errorf("expected ownerReferences to be empty array, got %d items", len(patch.Metadata.OwnerReferences))
	}

	// 3. Verify the raw JSON distinguishes null from [] — JSON merge patch treats them differently
	if !bytes.Contains(capturedPatch, []byte(`"ownerReferences":[]`)) {
		t.Errorf("patch JSON does not contain exact 'ownerReferences:[]' string.\npatch: %s", string(capturedPatch))
	}

	// 4. Verify the annotation was set
	if patch.Metadata.Annotations["sandbox.gvisor/state"] != "claimed" {
		t.Errorf("expected state annotation 'claimed', got %q", patch.Metadata.Annotations["sandbox.gvisor/state"])
	}
	if _, ok := patch.Metadata.Annotations["sandbox.gvisor/claimed-at"]; !ok {
		t.Error("expected claimed-at annotation to be present")
	}

	// 5. Verify store state was updated to provisioning->active flow
	sb, ok := store.Get(pod.Name)
	if !ok {
		t.Fatal("sandbox not found in store after provision")
	}
	if sb.ExpiresAt == nil {
		t.Error("expected ExpiresAt to be set for 5m lifetime")
	}
	if sb.DetachedAt == nil {
		t.Error("expected DetachedAt to be set")
	}

	t.Logf("Patch payload: %s", string(capturedPatch))
}

// TestProvisionPatchIsMergePatch verifies that the patch type is MergePatch,
// NOT StrategicMergePatch. This matters because with MergePatch, an empty array []
// replaces the entire field, while StrategicMergePatch would attempt to merge.
func TestProvisionPatchIsMergePatch(t *testing.T) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "sandbox-pool-xyz789",
			Namespace: "sandbox",
			Labels: map[string]string{
				"managed-by": "warmpool",
				"warmpool":   "true",
			},
			OwnerReferences: []metav1.OwnerReference{
				{
					APIVersion: "apps/v1",
					Kind:       "ReplicaSet",
					Name:       "sandbox-pool-abc",
					UID:        "rs-uid-999",
					Controller: boolPtr(true),
				},
			},
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			PodIP: "10.0.0.99",
			Conditions: []corev1.PodCondition{
				{Type: corev1.PodReady, Status: corev1.ConditionTrue},
			},
		},
		Spec: corev1.PodSpec{NodeName: "node-2"},
	}

	client := fake.NewSimpleClientset(pod)

	var capturedPatchType types.PatchType
	client.PrependReactor("patch", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		patchAction := action.(clienttesting.PatchAction)
		capturedPatchType = patchAction.GetPatchType()
		return false, nil, nil
	})

	store := NewStore(10)
	store.Upsert(&Sandbox{
		Name:  pod.Name,
		State: "idle",
		Node:  "node-2",
		PodIP: "10.0.0.99",
	})

	kickCh := make(chan struct{}, 1)
	h := NewHandlers(client, nil, store, "sandbox", "sandbox-pool", kickCh)

	req := httptest.NewRequest(http.MethodPost, "/api/provision", nil)
	w := httptest.NewRecorder()
	h.handleProvision(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	if capturedPatchType != types.MergePatchType {
		t.Errorf("expected patch type %q, got %q — ownerReferences:[] only works correctly with MergePatch, not StrategicMergePatch",
			types.MergePatchType, capturedPatchType)
	}
}

func boolPtr(b bool) *bool {
	return &b
}
