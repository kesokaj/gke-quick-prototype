package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true }, // allow all origins
}

var activeConnections atomic.Int64

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", handleWS)
	mux.HandleFunc("/healthz", handleHealthz)

	slog.Info("ws-server starting", "port", port)
	if err := http.ListenAndServe(fmt.Sprintf(":%s", port), mux); err != nil {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		slog.Error("websocket upgrade failed", "error", err, "remote", r.RemoteAddr)
		return
	}

	activeConnections.Add(1)
	podName := r.Header.Get("X-Pod-Name")
	slog.Info("ws connected",
		"remote", r.RemoteAddr,
		"pod", podName,
		"active_connections", activeConnections.Load(),
	)

	defer func() {
		conn.Close()
		activeConnections.Add(-1)
		slog.Info("ws disconnected",
			"remote", r.RemoteAddr,
			"pod", podName,
			"active_connections", activeConnections.Load(),
		)
	}()

	for {
		msgType, msg, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Warn("ws read error", "error", err, "pod", podName)
			}
			return
		}

		if msgType == websocket.TextMessage && string(msg) == "ping" {
			if err := conn.WriteMessage(websocket.TextMessage, []byte("pong")); err != nil {
				slog.Warn("ws write error", "error", err, "pod", podName)
				return
			}
		}
	}
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":            "ok",
		"activeConnections": activeConnections.Load(),
		"ts":                time.Now().UTC().Format(time.RFC3339),
	})
}
