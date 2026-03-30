package main

import (
	"math"
	"sort"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	dto "github.com/prometheus/client_model/go"
)

// Histogram buckets tuned for sub-second to ~60s container scheduling.
var schedulingBuckets = []float64{0.1, 0.25, 0.5, 1, 2.5, 5, 10, 15, 30, 60}

var (
	// sandboxScheduleDuration measures time from pod creation to Running.
	sandboxScheduleDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "sandbox_schedule_duration_seconds",
		Help:    "Time from pod creation to Running state (includes scheduling + gVisor boot).",
		Buckets: schedulingBuckets,
	})

	// sandboxClaimToReady measures time from claim (detach) to Ready=true.
	sandboxClaimToReady = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "sandbox_claim_to_ready_seconds",
		Help:    "Time from sandbox claim to readiness probe passing.",
		Buckets: schedulingBuckets,
	})

	// sandboxPoolSize tracks the configured pool size target.
	sandboxPoolSize = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "sandbox_pool_size",
		Help: "Configured warm pool size target.",
	})

	// sandboxStateCount tracks the number of sandboxes per state.
	sandboxStateCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "sandbox_state_count",
		Help: "Number of sandboxes by state.",
	}, []string{"state"})

	// sandboxGCTotal counts pods garbage collected by the controller, by reason.
	sandboxGCTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "sandbox_gc_total",
		Help: "Total sandbox pods garbage collected by the controller.",
	}, []string{"reason"})
)

// resetMetrics unregisters and re-registers the histogram metrics, effectively zeroing them.
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

	// Sort buckets by upper bound.
	sort.Slice(buckets, func(i, j int) bool {
		return buckets[i].GetUpperBound() < buckets[j].GetUpperBound()
	})

	// Linear interpolation between bucket boundaries (Prometheus method).
	var prevCount float64
	var prevBound float64
	for _, b := range buckets {
		cumCount := float64(b.GetCumulativeCount())
		if cumCount >= rank {
			// Interpolate within this bucket.
			bucketCount := cumCount - prevCount
			if bucketCount == 0 {
				return math.Round(b.GetUpperBound()*1000) / 1000
			}
			// How far into this bucket the rank falls (0.0 to 1.0).
			fraction := (rank - prevCount) / bucketCount
			interpolated := prevBound + fraction*(b.GetUpperBound()-prevBound)
			return math.Round(interpolated*100) / 100
		}
		prevCount = cumCount
		prevBound = b.GetUpperBound()
	}

	return math.Round(buckets[len(buckets)-1].GetUpperBound()*1000) / 1000
}
