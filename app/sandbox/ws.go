package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

const (
	wsPingInterval   = 2 * time.Second
	wsReconnectDelay = 2 * time.Second
	wsConnectTimeout = 10 * time.Second
)

// wsSessionLoop maintains a persistent WebSocket connection to the WS server.
// It sends "ping" every 2s and expects "pong" back. On disconnect it reconnects.
// Runs until ctx is cancelled (SIGTERM / TTL expiry).
func wsSessionLoop(ctx context.Context) {
	wsURL := os.Getenv("WS_SERVER_URL")
	if wsURL == "" {
		logEvent("ws", "WS_SERVER_URL not set — skipping WebSocket session", nil)
		return
	}

	podName := os.Getenv("POD_NAME")
	if podName == "" {
		podName = fmt.Sprintf("local-%d", os.Getpid())
	}

	// Derive audience from WSS URL: wss://service.run.app/ws → https://service.run.app
	audience := wsURL
	audience = strings.Replace(audience, "wss://", "https://", 1)
	audience = strings.Replace(audience, "ws://", "http://", 1)
	if idx := strings.Index(audience, "/ws"); idx > 0 {
		audience = audience[:idx]
	}

	logEvent("ws", "starting WebSocket session loop", map[string]interface{}{
		"url":             wsURL,
		"audience":        audience,
		"ping_interval":   wsPingInterval.String(),
		"reconnect_wait":  wsReconnectDelay.String(),
		"connect_timeout": wsConnectTimeout.String(),
	})

	var reconnectCount int64
	sessionStart := time.Now()

	for {
		select {
		case <-ctx.Done():
			logEvent("ws", "session loop stopped — context cancelled", map[string]interface{}{
				"total_reconnects":   atomic.LoadInt64(&reconnectCount),
				"session_lifetime_s": time.Since(sessionStart).Seconds(),
			})
			setWSConnected(false)
			return
		default:
		}

		connStart := time.Now()
		reason := wsConnect(ctx, wsURL, audience, podName)
		connDuration := time.Since(connStart)

		setWSConnected(false)
		atomic.AddInt64(&reconnectCount, 1)

		logEvent("ws", "connection lost — scheduling reconnect", map[string]interface{}{
			"reason":           reason,
			"connection_dur_s": connDuration.Seconds(),
			"reconnect_count":  atomic.LoadInt64(&reconnectCount),
			"delay":            wsReconnectDelay.String(),
		})

		select {
		case <-time.After(wsReconnectDelay):
		case <-ctx.Done():
			return
		}
	}
}

// fetchIDToken gets a Google ID token for the given audience via the GCE metadata server.
// Uses the metadata IP directly (169.254.169.254) since sandbox pods use dnsPolicy: None
// with public nameservers that cannot resolve metadata.google.internal.
func fetchIDToken(audience string) (string, error) {
	metadataURL := fmt.Sprintf(
		"http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/identity?audience=%s",
		url.QueryEscape(audience),
	)

	req, err := http.NewRequest("GET", metadataURL, nil)
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Metadata-Flavor", "Google")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("metadata request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("metadata HTTP %d: %s", resp.StatusCode, string(body))
	}

	token, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read token: %w", err)
	}
	return strings.TrimSpace(string(token)), nil
}

// wsConnect establishes a single WebSocket connection and runs the ping/pong loop.
// Returns a reason string describing why the connection ended.
func wsConnect(ctx context.Context, wsURL, audience, podName string) string {
	header := http.Header{}
	header.Set("X-Pod-Name", podName)

	token, err := fetchIDToken(audience)
	if err != nil {
		logEvent("ws", "ID token fetch failed — trying without auth", map[string]interface{}{
			"error":    err.Error(),
			"audience": audience,
		})
	} else {
		header.Set("Authorization", "Bearer "+token)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: wsConnectTimeout,
	}

	logEvent("ws", "dialing", map[string]interface{}{
		"url":       wsURL,
		"timeout":   wsConnectTimeout.String(),
		"has_token": token != "",
	})

	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		detail := map[string]interface{}{
			"error": err.Error(),
			"url":   wsURL,
		}
		if resp != nil {
			detail["http_status"] = resp.StatusCode
		}
		if ctx.Err() != nil {
			detail["ctx_err"] = ctx.Err().Error()
		}
		logEvent("ws", "connection failed", detail)
		return fmt.Sprintf("dial_error: %s", err.Error())
	}

	setWSConnected(true)
	connectedAt := time.Now()
	var pingsSent, pongsReceived int64

	logEvent("ws", "connected", map[string]interface{}{
		"url": wsURL,
		"pod": podName,
	})

	defer func() {
		conn.WriteMessage(websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, "shutdown"))
		conn.Close()
		logEvent("ws", "disconnected", map[string]interface{}{
			"connected_dur_s": time.Since(connectedAt).Seconds(),
			"pings_sent":      pingsSent,
			"pongs_received":  pongsReceived,
		})
	}()

	errCh := make(chan error, 1)
	go func() {
		for {
			_, msg, err := conn.ReadMessage()
			if err != nil {
				errCh <- err
				return
			}
			if string(msg) == "pong" {
				count := atomic.AddInt64(&pongsReceived, 1)
				if count == 1 {
					logEvent("ws", "first pong received ✓", map[string]interface{}{
						"connected_dur_s": time.Since(connectedAt).Seconds(),
					})
				}
			}
		}
	}()

	ticker := time.NewTicker(wsPingInterval)
	defer ticker.Stop()

	const logEveryN = 30

	for {
		select {
		case <-ctx.Done():
			return "context_cancelled"

		case err := <-errCh:
			logEvent("ws", "read error — connection lost", map[string]interface{}{
				"error":           err.Error(),
				"connected_dur_s": time.Since(connectedAt).Seconds(),
				"pings_sent":      pingsSent,
				"pongs_received":  pongsReceived,
			})
			return fmt.Sprintf("read_error: %s", err.Error())

		case <-ticker.C:
			if err := conn.WriteMessage(websocket.TextMessage, []byte("ping")); err != nil {
				logEvent("ws", "write error — connection lost", map[string]interface{}{
					"error":           err.Error(),
					"connected_dur_s": time.Since(connectedAt).Seconds(),
					"pings_sent":      pingsSent,
					"pongs_received":  pongsReceived,
				})
				return fmt.Sprintf("write_error: %s", err.Error())
			}
			count := atomic.AddInt64(&pingsSent, 1)
			if count == 1 || count%logEveryN == 0 {
				logEvent("ws", "ping/pong heartbeat", map[string]interface{}{
					"pings_sent":      count,
					"pongs_received":  atomic.LoadInt64(&pongsReceived),
					"connected_dur_s": time.Since(connectedAt).Seconds(),
				})
			}
		}
	}
}
