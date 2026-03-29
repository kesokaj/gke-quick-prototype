package main

import (
	"bufio"
	"context"
	"crypto/rand"
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

// ---------------------------------------------------------------------------
// Download configuration
// ---------------------------------------------------------------------------

const downloadTimeout = 30 * time.Second

type downloadFile struct {
	URL  string
	Size int64
}

var downloadFile1MB = downloadFile{"http://speedtest.tele2.net/1MB.zip", 1 * 1024 * 1024}

const downloadCount = 5 // 5 × 1MB = 5MB total per sandbox (Cloud NAT cost control)



// ---------------------------------------------------------------------------
// Structured logging
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Phase 1: Download 5 × 1MB files (fixed — keeps Cloud NAT egress low)
// ---------------------------------------------------------------------------

func phaseDownload(ctx context.Context) {
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
			// Skip to next file — no GCS fallback for 1MB files (not worth the complexity)
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
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	f, err := os.Create(destPath)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = io.Copy(f, resp.Body)
	return err
}



// ---------------------------------------------------------------------------
// Phase 3: Random load generation (CPU, disk, network)
// ---------------------------------------------------------------------------

func phaseLoadLoop(ctx context.Context) {
	totalCores := runtime.NumCPU()

	roll := mathrand.Intn(100)
	var tier string
	var maxCores int

	switch {
	case roll < 70:
		tier = "light"
		maxCores = 1 + mathrand.Intn(2)
	case roll < 90:
		tier = "medium"
		maxCores = 3 + mathrand.Intn(2)
	default:
		tier = "heavy"
		maxCores = totalCores
	}
	if maxCores > totalCores {
		maxCores = totalCores
	}

	logEvent("load", "starting CPU load", map[string]interface{}{
		"tier":       tier,
		"max_cores":  maxCores,
		"total_cpus": totalCores,
	})

	for {
		select {
		case <-ctx.Done():
			logEvent("load", "load loop stopped", map[string]interface{}{"tier": tier})
			return
		default:
		}

		stateRoll := mathrand.Intn(100)
		var activeCores int
		var state string

		switch {
		case stateRoll < 15:
			state = "idle"
			activeCores = 0
		case stateRoll < 45:
			state = "light"
			activeCores = 1
		case stateRoll < 70:
			state = "moderate"
			activeCores = maxCores / 2
			if activeCores < 1 {
				activeCores = 1
			}
		case stateRoll < 90:
			state = "heavy"
			activeCores = maxCores - 1
			if activeCores < 1 {
				activeCores = 1
			}
		default:
			state = "peak"
			activeCores = maxCores
		}

		holdDuration := time.Duration(3+mathrand.Intn(18)) * time.Second

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
			go func() {
				defer wg.Done()
				x := 1.0001
				for time.Now().Before(deadline) {
					for j := 0; j < 100000; j++ {
						x *= 1.0001
						if x > 1e100 {
							x = 1.0001
						}
					}
					select {
					case <-ctx.Done():
						return
					default:
					}
				}
			}()
		}
		wg.Wait()
	}
}

func burstDisk(ctx context.Context) {
	sizeMB := 10 + mathrand.Intn(191)
	logEvent("load", "disk burst started", map[string]interface{}{"size_mb": sizeMB})

	filePath := "/tmp/loadgen_disk_burst.bin"
	defer os.Remove(filePath)

	f, err := os.Create(filePath)
	if err != nil {
		logEvent("load", "disk write failed", map[string]interface{}{"error": err.Error()})
		return
	}

	buf := make([]byte, 1024*1024)
	for i := 0; i < sizeMB; i++ {
		select {
		case <-ctx.Done():
			f.Close()
			return
		default:
		}
		rand.Read(buf)
		f.Write(buf)
	}
	f.Sync()
	f.Close()

	logEvent("load", "disk write complete, starting read", map[string]interface{}{"size_mb": sizeMB})

	f2, err := os.Open(filePath)
	if err != nil {
		logEvent("load", "disk read failed", map[string]interface{}{"error": err.Error()})
		return
	}
	io.Copy(io.Discard, f2)
	f2.Close()

	logEvent("load", "disk burst finished", map[string]interface{}{"size_mb": sizeMB})
}

// ---------------------------------------------------------------------------
// Phase 2 (disk): Write random data to ephemeral storage
// ---------------------------------------------------------------------------

func phaseDiskWrite(ctx context.Context) {
	roll := mathrand.Intn(100)
	var targetBytes int64
	var label string
	switch {
	case roll < 70:
		targetBytes = 500 * 1024 * 1024
		label = "500 MB (normal)"
	case roll < 90:
		targetBytes = 1 * 1024 * 1024 * 1024
		label = "1 GB"
	case roll < 97:
		targetBytes = 3 * 1024 * 1024 * 1024
		label = "3 GB"
	default:
		targetGB := int64(3) + mathrand.Int63n(8)
		targetBytes = targetGB * 1024 * 1024 * 1024
		label = fmt.Sprintf("%d GB (heavy)", targetGB)
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

		rand.Read(chunk)

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

// ---------------------------------------------------------------------------
// Wait for detach — pod idles until warmpool label is removed/changed
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

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

	// Health endpoint — /_sandbox/status
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/_sandbox/status", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `{"status":"ok","ready":true,"pod":"%s"}`, podName)
		})
		if err := http.ListenAndServe(":3004", mux); err != nil {
			logEvent("startup", "health server failed", map[string]interface{}{"error": err.Error()})
		}
	}()

	// Wait for detach — blocks until controller sets warmpool=false
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

	// Initialize Cloud Monitoring client (non-fatal if it fails)
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
		"phase_2": "disk: write 500 MB-10 GB random data to ephemeral storage",
		"phase_3": "load loop: CPU bursts until controller terminates pod",
	})

	go probeNetworkAccess(ctx, mc)

	// Phase 1: Downloads
	logEvent("scenario", "═══ PHASE 1: DOWNLOAD ═══", map[string]interface{}{
		"description": "fetching random data from speedtest servers to simulate artifact downloads",
	})
	phaseDownload(ctx)

	if ctx.Err() != nil {
		logEvent("lifecycle", "terminated during download phase", nil)
		return
	}

	// Phase 2: Disk write
	logEvent("scenario", "═══ PHASE 2: DISK WRITE ═══", map[string]interface{}{
		"description": "writing random data to ephemeral storage to simulate workspace usage",
	})
	phaseDiskWrite(ctx)

	if ctx.Err() != nil {
		logEvent("lifecycle", "terminated during disk write phase", nil)
		return
	}

	// Phase 3: Load loop — runs indefinitely until controller kills the pod
	logEvent("scenario", "═══ PHASE 3: LOAD LOOP ═══", map[string]interface{}{
		"description": "CPU bursts running until controller terminates pod via TTL",
	})
	phaseLoadLoop(ctx)

	logEvent("lifecycle", "pod terminated by controller", nil)
}
