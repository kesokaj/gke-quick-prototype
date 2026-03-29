package main

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/remotecommand"
)

var upgrader = websocket.Upgrader{
	CheckOrigin:  func(r *http.Request) bool { return true },
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
}

// handleTerminal upgrades the HTTP connection to a WebSocket and proxies
// stdin/stdout/stderr to a bash shell inside the sandbox pod.
// Works on both idle (warmpool) and claimed (active) pods.
func (h *Handlers) handleTerminal(w http.ResponseWriter, r *http.Request, name string) {
	// Verify pod exists in our store.
	_, ok := h.store.Get(name)
	if !ok {
		http.Error(w, "sandbox not found", http.StatusNotFound)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		slog.Error("terminal: websocket upgrade failed", "name", name, "error", err)
		return
	}
	defer conn.Close()

	slog.Info("terminal: session started", "name", name)

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Minute)
	defer cancel()

	// Build the exec request.
	req := h.client.CoreV1().RESTClient().Post().
		Resource("pods").
		Name(name).
		Namespace(h.namespace).
		SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Command: []string{"/bin/bash"},
			Stdin:   true,
			Stdout:  true,
			Stderr:  true,
			TTY:     true,
		}, scheme.ParameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(h.restConfig, "POST", req.URL())
	if err != nil {
		slog.Error("terminal: failed to create executor", "name", name, "error", err)
		writeWSError(conn, "failed to create exec session: "+err.Error())
		return
	}

	// Create the bidirectional stream adapter.
	stream := &wsStream{conn: conn, done: make(chan struct{})}

	// Run the exec stream — this blocks until the session ends.
	err = exec.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdin:  stream,
		Stdout: stream,
		Stderr: stream,
		Tty:    true,
	})

	if err != nil {
		slog.Info("terminal: session ended", "name", name, "error", err)
	} else {
		slog.Info("terminal: session ended cleanly", "name", name)
	}
}

// wsStream adapts a gorilla/websocket.Conn to io.Reader and io.Writer
// for use with the K8s remote exec stream.
type wsStream struct {
	conn    *websocket.Conn
	readBuf []byte // leftover bytes from previous WebSocket message
	mu      sync.Mutex
	done    chan struct{}
}

// Read reads from the WebSocket connection.
func (s *wsStream) Read(p []byte) (int, error) {
	// Drain leftover buffer first.
	if len(s.readBuf) > 0 {
		n := copy(p, s.readBuf)
		s.readBuf = s.readBuf[n:]
		return n, nil
	}

	_, msg, err := s.conn.ReadMessage()
	if err != nil {
		return 0, err
	}

	// Handle resize messages: JSON starting with {"type":"resize"
	if len(msg) > 0 && msg[0] == '{' {
		// Ignore resize for now — we don't have a TerminalSize queue.
		return 0, nil
	}

	n := copy(p, msg)
	if n < len(msg) {
		s.readBuf = msg[n:]
	}
	return n, nil
}

// Write sends data to the WebSocket connection.
func (s *wsStream) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	err := s.conn.WriteMessage(websocket.BinaryMessage, p)
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

// writeWSError sends an error message to the WebSocket client.
func writeWSError(conn *websocket.Conn, msg string) {
	conn.WriteMessage(websocket.TextMessage, []byte("\r\n\x1b[31mError: "+msg+"\x1b[0m\r\n"))
}

