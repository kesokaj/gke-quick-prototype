package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"time"
)

const (
	probeTarget         = "https://8.8.8.8"
	probeConnectTimeout = 500 * time.Millisecond
	probeRetryInterval  = 100 * time.Millisecond
	metricReportEvery   = 5 * time.Second
)

func probeNetworkAccess(ctx context.Context, mc *metricsClient) {
	startMs := time.Now().UnixMilli()
	startTime := time.Now()

	fmt.Printf("START: Pod ready to transmit at %d\n", startMs)

	logEvent("probe", "network probe started", map[string]interface{}{
		"target":   probeTarget,
		"start_ms": startMs,
	})

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		DialContext: (&net.Dialer{
			Timeout: probeConnectTimeout,
		}).DialContext,
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   probeConnectTimeout * 2,
	}

	lastMetricReport := time.Now()
	attempt := 0

	for {
		select {
		case <-ctx.Done():
			logEvent("probe", "probe cancelled — context done", map[string]interface{}{
				"attempts": attempt,
				"elapsed":  time.Since(startTime).String(),
			})
			return
		default:
		}

		attempt++
		resp, err := client.Get(probeTarget)
		if err == nil {
			code := resp.StatusCode
			resp.Body.Close()

			if code == 200 || code == 301 || code == 302 {
				endMs := time.Now().UnixMilli()
				deltaMs := endMs - startMs

				fmt.Printf("SUCCESS: Traffic allowed at %d\n", endMs)
				fmt.Printf("RESULT_LATENCY_MS: %d\n", deltaMs)

				logEvent("probe", "network probe succeeded", map[string]interface{}{
					"end_ms":     endMs,
					"latency_ms": deltaMs,
					"http_code":  code,
					"attempts":   attempt,
				})

				if mc != nil {
					if err := mc.writeProbeMetric(ctx, float64(deltaMs), "complete"); err != nil {
						logEvent("probe", "failed to write final metric", map[string]interface{}{
							"error": err.Error(),
						})
					} else {
						logEvent("probe", "final metric written to Cloud Monitoring", map[string]interface{}{
							"latency_ms": deltaMs,
						})
					}
				}
				return
			}
		}

		if mc != nil && time.Since(lastMetricReport) >= metricReportEvery {
			elapsed := float64(time.Now().UnixMilli() - startMs)
			if err := mc.writeProbeMetric(ctx, elapsed, "probing"); err != nil {
				logEvent("probe", "failed to write progress metric", map[string]interface{}{
					"error": err.Error(),
				})
			}
			lastMetricReport = time.Now()
		}

		time.Sleep(probeRetryInterval)
	}
}
