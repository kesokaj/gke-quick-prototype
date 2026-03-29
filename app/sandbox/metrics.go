package main

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"cloud.google.com/go/compute/metadata"
	monitoring "cloud.google.com/go/monitoring/apiv3/v2"
	"cloud.google.com/go/monitoring/apiv3/v2/monitoringpb"
	metricpb "google.golang.org/genproto/googleapis/api/metric"
	monitoredrespb "google.golang.org/genproto/googleapis/api/monitoredres"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const (
	metricType = "custom.googleapis.com/benchmark/network_probe_latency_ms"
)

type metricsClient struct {
	client      *monitoring.MetricClient
	projectID   string
	clusterName string
	location    string
	namespace   string
	podName     string

	mu    sync.Mutex
	ready bool
}

func newMetricsClient(ctx context.Context) (*metricsClient, error) {
	client, err := monitoring.NewMetricClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("monitoring.NewMetricClient: %w", err)
	}

	mc := &metricsClient{
		client:  client,
		podName: os.Getenv("POD_NAME"),
	}

	mc.namespace = os.Getenv("POD_NAMESPACE")
	if mc.namespace == "" {
		mc.namespace = "sandbox"
	}

	if metadata.OnGCE() {
		mc.projectID, _ = metadata.ProjectIDWithContext(ctx)
		mc.clusterName, _ = metadata.InstanceAttributeValueWithContext(ctx, "cluster-name")
		mc.location, _ = metadata.InstanceAttributeValueWithContext(ctx, "cluster-location")
	}

	if mc.projectID == "" {
		mc.projectID = os.Getenv("PROJECT")
	}
	if mc.podName == "" {
		mc.podName = fmt.Sprintf("local-%d", os.Getpid())
	}

	if mc.projectID == "" {
		return nil, fmt.Errorf("could not determine project ID from metadata or PROJECT env var")
	}

	mc.ready = true
	return mc, nil
}

func (mc *metricsClient) writeProbeMetric(ctx context.Context, latencyMs float64, status string) error {
	mc.mu.Lock()
	defer mc.mu.Unlock()

	if !mc.ready {
		return fmt.Errorf("metrics client not ready")
	}

	now := time.Now()

	req := &monitoringpb.CreateTimeSeriesRequest{
		Name: fmt.Sprintf("projects/%s", mc.projectID),
		TimeSeries: []*monitoringpb.TimeSeries{
			{
				Metric: &metricpb.Metric{
					Type: metricType,
					Labels: map[string]string{
						"pod_name": mc.podName,
						"status":   status,
					},
				},
				Resource: mc.monitoredResource(),
				Points: []*monitoringpb.Point{
					{
						Interval: &monitoringpb.TimeInterval{
							EndTime: timestamppb.New(now),
						},
						Value: &monitoringpb.TypedValue{
							Value: &monitoringpb.TypedValue_DoubleValue{
								DoubleValue: latencyMs,
							},
						},
					},
				},
			},
		},
	}

	if err := mc.client.CreateTimeSeries(ctx, req); err != nil {
		return fmt.Errorf("CreateTimeSeries: %w", err)
	}
	return nil
}

func (mc *metricsClient) monitoredResource() *monitoredrespb.MonitoredResource {
	if mc.clusterName != "" && mc.location != "" {
		return &monitoredrespb.MonitoredResource{
			Type: "k8s_pod",
			Labels: map[string]string{
				"project_id":     mc.projectID,
				"location":       mc.location,
				"cluster_name":   mc.clusterName,
				"namespace_name": mc.namespace,
				"pod_name":       mc.podName,
			},
		}
	}

	return &monitoredrespb.MonitoredResource{
		Type: "global",
		Labels: map[string]string{
			"project_id": mc.projectID,
		},
	}
}

func (mc *metricsClient) close() {
	if mc.client != nil {
		if err := mc.client.Close(); err != nil {
			logEvent("metrics", "client close error", map[string]interface{}{"error": err.Error()})
		}
	}
}
