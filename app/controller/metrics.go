package main

import (
	"math"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	dto "github.com/prometheus/client_model/go"
)

var schedulingBuckets = []float64{0.1, 0.25, 0.5, 1, 2.5, 5, 10, 15, 30, 60}

var (
	sandboxScheduleDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "sandbox_schedule_duration_seconds",
		Help:    "Time from pod creation to Running state (includes scheduling + gVisor boot).",
		Buckets: schedulingBuckets,
	})

	sandboxClaimToReady = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "sandbox_claim_to_ready_seconds",
		Help:    "Time from sandbox claim to readiness probe passing.",
		Buckets: schedulingBuckets,
	})

	sandboxPoolSize = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "sandbox_pool_size",
		Help: "Configured warm pool size target.",
	})

	sandboxStateCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "sandbox_state_count",
		Help: "Number of sandboxes by state.",
	}, []string{"state"})

	sandboxGCTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "sandbox_gc_total",
		Help: "Total sandbox pods garbage collected by the controller.",
	}, []string{"reason"})
)

var sandboxSyncMismatchTotal = promauto.NewCounter(prometheus.CounterOpts{
	Name: "sandbox_sync_mismatch_total",
	Help: "Total instances where the controller store state had to be reverted because of GKE label mismatch.",
})

var sandboxClaimTotal = promauto.NewCounter(prometheus.CounterOpts{
	Name: "sandbox_claim_total",
	Help: "Total number of sandboxes successfully claimed by clients.",
})

var sandboxScheduledTotal = promauto.NewCounter(prometheus.CounterOpts{
	Name: "sandbox_scheduled_total",
	Help: "Total number of new pods in the warmpool that have become Ready.",
})

// resetMetrics re-registers histogram metrics, effectively zeroing them.
func resetMetrics() {
	prometheus.Unregister(sandboxScheduleDuration)
	sandboxScheduleDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "sandbox_schedule_duration_seconds",
		Help:    "Time from pod creation to Running state (includes scheduling + gVisor boot).",
		Buckets: schedulingBuckets,
	})

	prometheus.Unregister(sandboxClaimToReady)
	sandboxClaimToReady = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "sandbox_claim_to_ready_seconds",
		Help:    "Time from sandbox claim to readiness probe passing.",
		Buckets: schedulingBuckets,
	})
}

// HistogramSummary holds computed percentiles from a Prometheus histogram.
type HistogramSummary struct {
	Count uint64  `json:"count"`
	Sum   float64 `json:"sum"`
	Avg   float64 `json:"avg"`
	P50   float64 `json:"p50"`
	P95   float64 `json:"p95"`
	P99   float64 `json:"p99"`
}

// extractHistogramSummary reads a Prometheus histogram and computes approximate percentiles.
func extractHistogramSummary(h prometheus.Histogram) HistogramSummary {
	var m dto.Metric
	if err := h.Write(&m); err != nil {
		return HistogramSummary{}
	}

	hist := m.GetHistogram()
	if hist == nil {
		return HistogramSummary{}
	}

	count := hist.GetSampleCount()
	sum := hist.GetSampleSum()
	avg := 0.0
	if count > 0 {
		avg = math.Round(sum/float64(count)*1000) / 1000
	}

	return HistogramSummary{
		Count: count,
		Sum:   math.Round(sum*1000) / 1000,
		Avg:   avg,
		P50:   histogramQuantile(0.50, hist),
		P95:   histogramQuantile(0.95, hist),
		P99:   histogramQuantile(0.99, hist),
	}
}

// histogramQuantile computes an approximate quantile from histogram buckets
// using linear interpolation between bucket boundaries (same as Prometheus histogram_quantile).
func histogramQuantile(q float64, hist *dto.Histogram) float64 {
	buckets := hist.GetBucket()
	if len(buckets) == 0 {
		return 0
	}

	count := float64(hist.GetSampleCount())
	if count == 0 {
		return 0
	}

	rank := q * count


	var prevCount float64
	var prevBound float64
	for _, b := range buckets {
		cumCount := float64(b.GetCumulativeCount())
		if cumCount >= rank {
			bucketCount := cumCount - prevCount
			if bucketCount == 0 {
				return math.Round(b.GetUpperBound()*1000) / 1000
			}
			fraction := (rank - prevCount) / bucketCount
			interpolated := prevBound + fraction*(b.GetUpperBound()-prevBound)
			return math.Round(interpolated*100) / 100
		}
		prevCount = cumCount
		prevBound = b.GetUpperBound()
	}

	return math.Round(buckets[len(buckets)-1].GetUpperBound()*1000) / 1000
}

// extractCounterValue reads a Prometheus counter and returns its value.
func extractCounterValue(c prometheus.Counter) float64 {
	var m dto.Metric
	if err := c.Write(&m); err != nil {
		return 0
	}
	return m.GetCounter().GetValue()
}
