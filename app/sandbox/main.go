package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	mathrand "math/rand"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Global sandbox state (exposed via /_sandbox/status)

var sandboxState struct {
	mu          sync.RWMutex
	Phase       string  `json:"phase"`       // idle, download, disk, load
	CPUTier     string  `json:"cpuTier"`     // light, medium, heavy (set during load phase)
	DutyPct     float64 `json:"dutyPct"`     // duty cycle percentage (0.3 = 300m)
	WSConnected bool    `json:"wsConnected"` // true if WebSocket session is active
}

func setPhase(phase string) {
	sandboxState.mu.Lock()
	sandboxState.Phase = phase
	sandboxState.mu.Unlock()
}

func setTier(tier string, duty float64) {
	sandboxState.mu.Lock()
	sandboxState.CPUTier = tier
	sandboxState.DutyPct = duty
	sandboxState.mu.Unlock()
}

func setWSConnected(connected bool) {
	sandboxState.mu.Lock()
	sandboxState.WSConnected = connected
	sandboxState.mu.Unlock()
}

func getState() (phase, tier string, duty float64, wsConn bool) {
	sandboxState.mu.RLock()
	defer sandboxState.mu.RUnlock()
	return sandboxState.Phase, sandboxState.CPUTier, sandboxState.DutyPct, sandboxState.WSConnected
}

const downloadTimeout = 30 * time.Second

type downloadFile struct {
	URL  string
	Size int64
}

var downloadFile1MB = downloadFile{"http://speedtest.tele2.net/1MB.zip", 1 * 1024 * 1024}

const downloadCount = 5 // 5 × 1MB = 5MB total per sandbox (Cloud NAT cost control)

func logEvent(phase, msg string, fields map[string]interface{}) {
	entry := map[string]interface{}{
		"ts":    time.Now().UTC().Format(time.RFC3339Nano),
		"phase": phase,
		"msg":   msg,
		"pod":   os.Getenv("POD_NAME"),
	}
	for k, v := range fields {
		entry[k] = v
	}
	data, _ := json.Marshal(entry)
	fmt.Fprintln(os.Stdout, string(data))
}

func phaseDownload(ctx context.Context) {
	setPhase("download")
	logEvent("download", "starting downloads", map[string]interface{}{
		"file_count": downloadCount,
		"file_size":  "1MB",
		"total_mb":   downloadCount,
	})

	downloadDir := "/tmp/downloads"
	if err := os.MkdirAll(downloadDir, 0755); err != nil {
		logEvent("download", "failed to create download dir", map[string]interface{}{"error": err.Error()})
		return
	}

	var totalDownloaded int64

	for i := 0; i < downloadCount; i++ {
		select {
		case <-ctx.Done():
			logEvent("download", "cancelled", nil)
			return
		default:
		}

		destPath := filepath.Join(downloadDir, fmt.Sprintf("file_%d.bin", i))

		logEvent("download", "fetching", map[string]interface{}{
			"url":     downloadFile1MB.URL,
			"file":    destPath,
			"index":   fmt.Sprintf("%d/%d", i+1, downloadCount),
			"timeout": downloadTimeout.String(),
		})

		dlCtx, dlCancel := context.WithTimeout(ctx, downloadTimeout)
		start := time.Now()
		err := downloadToFile(dlCtx, downloadFile1MB.URL, destPath)
		elapsed := time.Since(start)
		dlCancel()

		if err != nil {
			logEvent("download", "download failed", map[string]interface{}{
				"error":   err.Error(),
				"elapsed": elapsed.String(),
				"index":   fmt.Sprintf("%d/%d", i+1, downloadCount),
			})
		} else {
			totalDownloaded += downloadFile1MB.Size
			mbps := float64(downloadFile1MB.Size) / elapsed.Seconds() / (1024 * 1024)
			logEvent("download", "completed", map[string]interface{}{
				"url":           downloadFile1MB.URL,
				"index":         fmt.Sprintf("%d/%d", i+1, downloadCount),
				"elapsed_s":     elapsed.Seconds(),
				"throughput_mb": fmt.Sprintf("%.1f", mbps),
			})
		}
	}

	logEvent("download", "all downloads complete", map[string]interface{}{
		"total_bytes": totalDownloaded,
		"total_mb":    totalDownloaded / (1024 * 1024),
		"file_count":  downloadCount,
	})
}

func downloadToFile(ctx context.Context, url, destPath string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("http %d", resp.StatusCode)
	}

	f, err := os.Create(destPath)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = io.Copy(f, resp.Body)
	return err
}

func phaseLoadLoop(ctx context.Context) {
	totalCores := runtime.NumCPU()

	roll := mathrand.Intn(100)
	var tier string
	var maxCores int
	var dutyCycle float64

	switch {
	case roll < 90:
		tier = "light"
		maxCores = 1
		dutyCycle = 0.3
	case roll < 98:
		tier = "medium"
		maxCores = 1
		dutyCycle = 1.0
	default:
		tier = "heavy"
		maxCores = totalCores
		dutyCycle = 1.0
	}

	setPhase("load")
	setTier(tier, dutyCycle)
	logEvent("load", "starting CPU load", map[string]interface{}{
		"tier":       tier,
		"max_cores":  maxCores,
		"duty_cycle": dutyCycle,
		"total_cpus": totalCores,
	})

	for {
		select {
		case <-ctx.Done():
			logEvent("load", "load loop stopped", map[string]interface{}{"tier": tier})
			return
		default:
		}

		states := []string{"idle", "light", "moderate", "heavy", "peak"}
		state := states[mathrand.Intn(len(states))]
		var activeCores int

		switch state {
		case "idle":
			activeCores = 0
		case "light":
			activeCores = 1
		case "moderate":
			activeCores = maxCores / 2
			if activeCores < 1 {
				activeCores = 1
			}
		case "heavy":
			activeCores = maxCores - 1
			if activeCores < 1 {
				activeCores = 1
			}
		case "peak":
			activeCores = maxCores
		}

		holdDuration := 30 * time.Second

		logEvent("load", "state change", map[string]interface{}{
			"tier":       tier,
			"state":      state,
			"cores":      activeCores,
			"duration_s": holdDuration.Seconds(),
		})

		if activeCores == 0 {
			select {
			case <-time.After(holdDuration):
			case <-ctx.Done():
				return
			}
			continue
		}

		var wg sync.WaitGroup
		deadline := time.Now().Add(holdDuration)
		for i := 0; i < activeCores; i++ {
			wg.Add(1)
			go func(duty float64) {
				defer wg.Done()
				x := 1.0001
				const window = 100 * time.Millisecond
				burnDur := time.Duration(float64(window) * duty)
				sleepDur := window - burnDur
				for time.Now().Before(deadline) {
					burnEnd := time.Now().Add(burnDur)
					for time.Now().Before(burnEnd) {
						for j := 0; j < 10000; j++ {
							x *= 1.0001
							if x > 1e100 {
								x = 1.0001
							}
						}
					}
					if sleepDur > 0 {
						time.Sleep(sleepDur)
					}
					select {
					case <-ctx.Done():
						return
					default:
					}
				}
			}(dutyCycle)
		}
		wg.Wait()
	}
}

func phaseDiskWrite(ctx context.Context) {
	setPhase("disk")
	roll := mathrand.Intn(100)
	var targetBytes int64
	var label string
	switch {
	case roll < 90:
		targetBytes = 500 * 1024 * 1024
		label = "500 MB (normal)"
	case roll < 98:
		targetBytes = 1 * 1024 * 1024 * 1024
		label = "1 GB"
	default:
		targetBytes = 3 * 1024 * 1024 * 1024
		label = "3 GB"
	}

	logEvent("disk", "starting ephemeral storage write", map[string]interface{}{
		"target":       label,
		"target_bytes": targetBytes,
	})

	writeDir := "/tmp/ephemeral"
	if err := os.MkdirAll(writeDir, 0755); err != nil {
		logEvent("disk", "failed to create ephemeral dir", map[string]interface{}{"error": err.Error()})
		return
	}

	const chunkSize = 64 * 1024 * 1024
	chunk := make([]byte, chunkSize)
	// pre-fill chunk with dummy data to avoid runtime MathRand overhead
	for i := range chunk {
		chunk[i] = byte(i % 256)
	}
	var totalWritten int64
	fileIndex := 0
	start := time.Now()

	for totalWritten < targetBytes {
		select {
		case <-ctx.Done():
			logEvent("disk", "disk write cancelled", map[string]interface{}{
				"written_gb": float64(totalWritten) / (1024 * 1024 * 1024),
			})
			return
		default:
		}

		filePath := filepath.Join(writeDir, fmt.Sprintf("data_%d.bin", fileIndex))
		if err := os.WriteFile(filePath, chunk, 0644); err != nil {
			logEvent("disk", "write failed", map[string]interface{}{
				"error": err.Error(),
				"file":  filePath,
			})
			break
		}

		totalWritten += chunkSize
		fileIndex++

		if totalWritten%(1024*1024*1024) == 0 {
			logEvent("disk", "write progress", map[string]interface{}{
				"written_gb": totalWritten / (1024 * 1024 * 1024),
				"target":     label,
			})
		}
	}

	elapsed := time.Since(start)
	throughput := float64(totalWritten) / (1024 * 1024) / elapsed.Seconds()

	logEvent("disk", "ephemeral storage write complete", map[string]interface{}{
		"written_gb":      float64(totalWritten) / (1024 * 1024 * 1024),
		"elapsed_s":       elapsed.Seconds(),
		"throughput_mb_s": fmt.Sprintf("%.1f", throughput),
		"files":           fileIndex,
	})
}

const labelsPath = "/etc/podinfo/labels"

func waitForDetach(ctx context.Context) {
	if _, err := os.Stat(labelsPath); os.IsNotExist(err) {
		logEvent("warmpool", "labels file not found — skipping detach wait (local mode)", nil)
		return
	}

	logEvent("warmpool", "pod is idle in warm pool — waiting for detach", map[string]interface{}{
		"state": "waiting",
		"hint":  "pod will start load scenario once warmpool label is set to false",
	})

	start := time.Now()
	ticker := time.NewTicker(1 * time.Second)
	heartbeat := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	defer heartbeat.Stop()

	for {
		select {
		case <-ctx.Done():
			logEvent("warmpool", "context cancelled while waiting for detach", map[string]interface{}{
				"waited_s": time.Since(start).Seconds(),
			})
			return
		case <-heartbeat.C:
			logEvent("warmpool", "still waiting for detach — pod is idle", map[string]interface{}{
				"state":    "waiting",
				"waited_s": int(time.Since(start).Seconds()),
			})
		case <-ticker.C:
			if isDetached() {
				logEvent("warmpool", "detached from warm pool — activating", map[string]interface{}{
					"state":    "detached",
					"waited_s": time.Since(start).Seconds(),
				})
				return
			}
		}
	}
}

func isDetached() bool {
	f, err := os.Open(labelsPath)
	if err != nil {
		return true
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "warmpool=") {
			val := strings.TrimPrefix(line, "warmpool=")
			val = strings.Trim(val, `"`)
			return val != "true"
		}
	}
	return true
}

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())

	podName := os.Getenv("POD_NAME")
	if podName == "" {
		podName = fmt.Sprintf("local-%d", os.Getpid())
	}

	logEvent("startup", "sandbox simulation ready — health server on :3004", map[string]interface{}{
		"pid":        os.Getpid(),
		"gomaxprocs": runtime.GOMAXPROCS(0),
		"num_cpu":    runtime.NumCPU(),
		"go_version": runtime.Version(),
	})

	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/_sandbox/status", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			phase, tier, duty, wsConn := getState()
			fmt.Fprintf(w, `{"status":"ok","ready":true,"pod":"%s","phase":"%s","cpuTier":"%s","dutyPct":%.2f,"wsConnected":%t}`, podName, phase, tier, duty, wsConn)
		})
		if err := http.ListenAndServe(":3004", mux); err != nil {
			logEvent("startup", "health server failed", map[string]interface{}{"error": err.Error()})
		}
	}()

	setPhase("idle")
	waitForDetach(context.Background())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		logEvent("lifecycle", "received SIGTERM from controller — shutting down", map[string]interface{}{
			"signal": sig.String(),
		})
		cancel()
	}()

	mc, err := newMetricsClient(ctx)
	if err != nil {
		logEvent("main", "Cloud Monitoring client init failed — probe will log only", map[string]interface{}{
			"error": err.Error(),
		})
	} else {
		defer mc.close()
	}

	logEvent("scenario", "SCENARIO: active workload — controller owns lifetime", map[string]interface{}{
		"phase_1": "download: 5 × 1MB from speedtest.tele2.net (Cloud NAT cost control)",
		"phase_2": "disk: write 500 MB–3 GB random data to ephemeral storage",
		"phase_3": "load loop: duty-cycled CPU (90% 300m / 8% 1core / 2% all) until SIGTERM",
		"bg_ws":   "WebSocket session: ping/pong every 2s to Cloud Run",
	})

	go probeNetworkAccess(ctx, mc)
	go wsSessionLoop(ctx)

	logEvent("scenario", "═══ PHASE 1: DOWNLOAD ═══", map[string]interface{}{
		"description": "fetching random data from speedtest servers",
	})
	phaseDownload(ctx)

	if ctx.Err() != nil {
		logEvent("lifecycle", "terminated during download phase", nil)
		return
	}

	logEvent("scenario", "═══ PHASE 2: DISK WRITE ═══", map[string]interface{}{
		"description": "writing random data to ephemeral storage",
	})
	phaseDiskWrite(ctx)

	if ctx.Err() != nil {
		logEvent("lifecycle", "terminated during disk write phase", nil)
		return
	}

	logEvent("scenario", "═══ PHASE 3: LOAD LOOP ═══", map[string]interface{}{
		"description": "CPU bursts until controller terminates pod",
	})
	phaseLoadLoop(ctx)

	logEvent("lifecycle", "pod terminated by controller", nil)
}
