{
      "displayName": "gVisor Sandbox Platform — Operations",
      "dashboardFilters": [],
      "mosaicLayout": {
            "columns": 48,
            "tiles": [
                  {
                        "yPos": 0,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# ⚡ Hero — Time to Internet (Network Probe Latency)",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 4,
                        "xPos": 0,
                        "width": 48,
                        "height": 16,
                        "widget": {
                              "title": "Network Probe Latency (ms) — All Pods Aggregate",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/benchmark/network_probe_latency_ms\" resource.type=\"k8s_pod\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "avg"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/benchmark/network_probe_latency_ms\" resource.type=\"k8s_pod\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_99",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/benchmark/network_probe_latency_ms\" resource.type=\"k8s_pod\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_95",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/benchmark/network_probe_latency_ms\" resource.type=\"k8s_pod\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_50",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p50 (median)"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Milliseconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 20,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# ⚡ Sandbox Lifecycle — gVisor Startup & Claim-to-Ready",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 24,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Kubelet Pod Start SLI Duration",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(kubelet_pod_start_sli_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(kubelet_pod_start_sli_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(kubelet_pod_start_sli_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 24,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Container Startup Duration",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/uptime\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_99",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p99 uptime"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/uptime\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_50",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p50 uptime"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 24,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Container Restart Count (sandbox)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/restart_count\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Restarts/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 40,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Schedule Duration (creation→Running)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(sandbox_schedule_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(sandbox_schedule_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(sandbox_schedule_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 40,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Claim-to-Ready (claim→Ready)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(sandbox_claim_to_ready_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(sandbox_claim_to_ready_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(sandbox_claim_to_ready_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 40,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Pool State",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sandbox_state_count{cluster=\"__CLUSTER_NAME__\"}"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Count",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 56,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🔧 gVisor Runtime — Container Operations",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 60,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Runtime Ops Latency (p99/p50)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, histogram_quantile(0.99, sum by (le, operation_type) (rate(kubelet_runtime_operations_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m]))))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99 (${metric.labels.operation_type})"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 60,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Runtime Operations Rate",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (operation_type) (rate(kubelet_runtime_operations_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Ops/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 60,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Runtime Operation Errors",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (operation_type) (rate(kubelet_runtime_operations_errors_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Errors/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 76,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "RunPodSandbox Duration (gVisor)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(kubelet_run_podsandbox_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(kubelet_run_podsandbox_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 76,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Pod Worker Duration",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(kubelet_pod_worker_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(kubelet_pod_worker_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 76,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Running Containers",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum(kubelet_running_containers{cluster=\"__CLUSTER_NAME__\", container_state=\"running\"})"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "running"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Count",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 92,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🔌 Cilium — Scheduling Latencies",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 96,
                        "xPos": 0,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ CiliumEndpoint Propagation Delay",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_endpoint_propagation_delay_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(cilium_endpoint_propagation_delay_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_endpoint_propagation_delay_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 96,
                        "xPos": 24,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Service Implementation Delay",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_service_implementation_delay_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(cilium_service_implementation_delay_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_service_implementation_delay_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 112,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Identity Propagation Delay",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_identity_cache_timer_trigger_latency_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_identity_cache_timer_trigger_latency_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 112,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Endpoint Propagation Rate",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum(rate(cilium_endpoint_propagation_delay_seconds_count{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "propagations/s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Events/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 112,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Identity Update Duration",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_identity_cache_timer_duration_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_identity_cache_timer_duration_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 128,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🔍 Cilium — Performance & Bottleneck Detection",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 132,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "BPF Map Pressure (>0 only)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, max by (map_name) (cilium_bpf_map_pressure{cluster=\"__CLUSTER_NAME__\"})) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "pressure"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Pressure (0-1)",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 132,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Failing Controllers",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum(cilium_controllers_failing{cluster=\"__CLUSTER_NAME__\"})"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "failing"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Count",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 132,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Endpoint Regen Time",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_endpoint_regeneration_time_stats_seconds_bucket{cluster=\"__CLUSTER_NAME__\", scope=\"total\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_endpoint_regeneration_time_stats_seconds_bucket{cluster=\"__CLUSTER_NAME__\", scope=\"total\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 148,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Endpoint Regens (rate/s)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (outcome) (rate(cilium_endpoint_regenerations_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Regens/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 148,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Regen by Reason",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (reason) (rate(cilium_endpoint_regenerations_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Regens/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 148,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ K8s Rate Limiter Wait",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_k8s_client_rate_limiter_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_k8s_client_rate_limiter_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 164,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Cilium K8s API Calls",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (method) (rate(cilium_k8s_client_api_calls_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Calls/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 164,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Cilium K8s API Latency",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(cilium_k8s_client_api_latency_time_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(cilium_k8s_client_api_latency_time_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 164,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Agent CPU / Memory",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "avg(rate(cilium_process_cpu_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "CPU Avg (cores)"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "max(rate(cilium_process_cpu_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "CPU Max (cores)"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "avg(cilium_process_resident_memory_bytes{cluster=\"__CLUSTER_NAME__\"}) / 1024 / 1024 / 1024"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "Memory Avg (GB)"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "max(cilium_process_resident_memory_bytes{cluster=\"__CLUSTER_NAME__\"}) / 1024 / 1024 / 1024"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "Memory Max (GB)"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Value",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 180,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🖥️ Node Resources — CPU / Memory / Disk",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 184,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Node CPU Utilization",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/node/cpu/allocatable_utilization\" resource.type=\"k8s_node\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": [
                                                                        "resource.label.\"node_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Utilization (0-1)",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 184,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Node Memory Utilization",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/node/memory/allocatable_utilization\" resource.type=\"k8s_node\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": [
                                                                        "resource.label.\"node_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Utilization (0-1)",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 184,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Node Ephemeral Storage",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/node/ephemeral_storage/used_bytes\" resource.type=\"k8s_node\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": [
                                                                        "resource.label.\"node_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 200,
                        "xPos": 0,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "Container CPU by Namespace",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/cpu/core_usage_time\" resource.type=\"k8s_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "resource.label.\"namespace_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "STACKED_AREA",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Cores",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 200,
                        "xPos": 24,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "Container Memory by Namespace",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/memory/used_bytes\" resource.type=\"k8s_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "resource.label.\"namespace_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "STACKED_AREA",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 216,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 📦 Sandbox Container Resources (namespace=sandbox)",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 220,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Sandbox CPU per Container",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/cpu/core_usage_time\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_99",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/cpu/core_usage_time\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "avg"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Cores",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 220,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Sandbox Memory per Container",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/memory/used_bytes\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_99",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/memory/used_bytes\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "avg"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 220,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Sandbox Ephemeral Storage",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/ephemeral_storage/used_bytes\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_PERCENTILE_99",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/ephemeral_storage/used_bytes\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "avg"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 236,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🎛️ Warmpool Controller (namespace=sandbox-control)",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 240,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Controller CPU",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/cpu/core_usage_time\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox-control\" resource.label.\"container_name\"=\"controller\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "resource.label.\"pod_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Cores",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 240,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Controller Memory",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/memory/used_bytes\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox-control\" resource.label.\"container_name\"=\"controller\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "resource.label.\"pod_name\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 240,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Controller Restarts",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"kubernetes.io/container/restart_count\" resource.type=\"k8s_container\" resource.label.\"namespace_name\"=\"sandbox-control\" resource.label.\"container_name\"=\"controller\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Restarts/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 256,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🌐 Kube API Server — Performance & Bottlenecks",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 260,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "API Server Request Rate",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (verb) (rate(apiserver_request_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Requests/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 260,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ API Server Latency",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\", verb!~\"WATCH|CONNECT\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.50, sum by (le) (rate(apiserver_request_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\", verb!~\"WATCH|CONNECT\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 260,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ API Server Errors (5xx)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (resource) (rate(apiserver_request_total{cluster=\"__CLUSTER_NAME__\", code=~\"5..\"}[5m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Errors/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 276,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Pod Operations / Second",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (verb) (rate(apiserver_request_total{cluster=\"__CLUSTER_NAME__\", resource=\"pods\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Ops/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 276,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Admission Webhook Latency",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(apiserver_admission_webhook_admission_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.50, sum by (le) (rate(apiserver_admission_webhook_admission_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 276,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Inflight Requests",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (request_kind) (apiserver_current_inflight_requests{cluster=\"__CLUSTER_NAME__\"})"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "inflight"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Count",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 292,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 📅 Scheduling Performance",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 296,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Scheduling Attempt Duration",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(scheduler_scheduling_attempt_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(scheduler_scheduling_attempt_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(scheduler_scheduling_attempt_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 296,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Pod Scheduling SLI Duration",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le) (rate(scheduler_pod_scheduling_sli_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.95, sum by (le) (rate(scheduler_pod_scheduling_sli_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p95"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.5, sum by (le) (rate(scheduler_pod_scheduling_sli_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 296,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Scheduler Pending Pods",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (queue) (scheduler_pending_pods{cluster=\"__CLUSTER_NAME__\"})"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "pending"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Count",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 312,
                        "xPos": 0,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Pods Scheduled / Second",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "sum by (result) (rate(scheduler_schedule_attempts_total{cluster=\"__CLUSTER_NAME__\"}[1m]))"
                                                },
                                                "plotType": "STACKED_AREA"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Pods/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 312,
                        "xPos": 24,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ Kubelet Runtime Ops Latency",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.99, sum by (le, operation_type) (rate(kubelet_runtime_operations_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "histogram_quantile(0.50, sum by (le, operation_type) (rate(kubelet_runtime_operations_duration_seconds_bucket{cluster=\"__CLUSTER_NAME__\"}[5m])))"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 328,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🔌 Conntrack & Sockets (per Node)",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 332,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Conntrack Entries (per Node)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/conntrack_entries\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Entries",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 332,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Conntrack Errors (per Node)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/conntrack_error_count\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Errors/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 332,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "TCP Sockets — In Use & TIME_WAIT",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/num_inuse_sockets\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_SUM"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s",
                                                "legendTemplate": "inuse"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/num_tw_sockets\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_SUM"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s",
                                                "legendTemplate": "time_wait"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Sockets",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 348,
                        "xPos": 0,
                        "width": 48,
                        "height": 16,
                        "widget": {
                              "title": "Socket Memory (per Node)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/socket_memory\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 368,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🛡️ gVisor Sandbox Runtime (per Pod)",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 372,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Running Sandboxes (per Node)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/meta_sandbox_running\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Sandboxes",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 372,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "File Opens (per Node)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/fs_opens\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Opens/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 372,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "TCP Established Connections",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/netstack_tcp_current_established\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Connections",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 388,
                        "xPos": 0,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "Network I/O (RX/TX Bytes)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/netstack_nic_rx_bytes\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s",
                                                "legendTemplate": "RX"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/netstack_nic_tx_bytes\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s",
                                                "legendTemplate": "TX"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Bytes/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 388,
                        "xPos": 24,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "Dropped Packets",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"custom.googleapis.com/gke/node/netstack_dropped_packets\" resource.type=\"gke_container\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "120s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_NONE"
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "120s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Packets/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 408,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# 🔗 WebSocket Session (Cloud Run)",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 412,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "WS Request Count",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"sandbox-ws-server\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "metric.label.\"response_code_class\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "STACKED_AREA",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Requests/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 412,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ WS Request Latency (p50 / p99)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"run.googleapis.com/request_latencies\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"sandbox-ws-server\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_PERCENTILE_99",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p99"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"run.googleapis.com/request_latencies\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"sandbox-ws-server\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_PERCENTILE_50",
                                                                  "crossSeriesReducer": "REDUCE_MEAN",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s",
                                                "legendTemplate": "p50"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "ms",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 412,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "WS Active Instances",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"run.googleapis.com/container/instance_count\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"sandbox-ws-server\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_MEAN",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "metric.label.\"state\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "STACKED_AREA",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Instances",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 428,
                        "xPos": 0,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "⚠️ WS 4xx / 5xx Errors",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"sandbox-ws-server\" metric.label.\"response_code_class\"=monitoring.regex.full_match(\"4xx|5xx\")",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": [
                                                                        "metric.label.\"response_code_class\""
                                                                  ]
                                                            }
                                                      }
                                                },
                                                "plotType": "STACKED_BAR",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Errors/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 428,
                        "xPos": 24,
                        "width": 24,
                        "height": 16,
                        "widget": {
                              "title": "WS Billable Instance Time",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "timeSeriesFilter": {
                                                            "filter": "metric.type=\"run.googleapis.com/container/billable_instance_time\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"sandbox-ws-server\"",
                                                            "aggregation": {
                                                                  "alignmentPeriod": "60s",
                                                                  "perSeriesAligner": "ALIGN_RATE",
                                                                  "crossSeriesReducer": "REDUCE_SUM",
                                                                  "groupByFields": []
                                                            }
                                                      }
                                                },
                                                "plotType": "LINE",
                                                "minAlignmentPeriod": "60s"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Instance-seconds/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 444,
                        "xPos": 0,
                        "width": 48,
                        "height": 4,
                        "widget": {
                              "title": "",
                              "text": {
                                    "content": "# ⏱️ Container Pressure (PSI) — CPU, Memory, IO",
                                    "format": "MARKDOWN",
                                    "style": {}
                              }
                        }
                  },
                  {
                        "yPos": 448,
                        "xPos": 0,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "CPU Pressure (PSI)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, sum by (pod) (rate(container_pressure_cpu_waiting_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "waiting (${metric.labels.pod})"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, sum by (pod) (rate(container_pressure_cpu_stalled_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "stalled (${metric.labels.pod})"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 448,
                        "xPos": 16,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "Memory Pressure (PSI)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, sum by (pod) (rate(container_pressure_memory_waiting_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "waiting (${metric.labels.pod})"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, sum by (pod) (rate(container_pressure_memory_stalled_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "stalled (${metric.labels.pod})"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  },
                  {
                        "yPos": 448,
                        "xPos": 32,
                        "width": 16,
                        "height": 16,
                        "widget": {
                              "title": "IO Pressure (PSI)",
                              "xyChart": {
                                    "dataSets": [
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, sum by (pod) (rate(container_pressure_io_waiting_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "waiting (${metric.labels.pod})"
                                          },
                                          {
                                                "timeSeriesQuery": {
                                                      "prometheusQuery": "topk(10, sum by (pod) (rate(container_pressure_io_stalled_seconds_total{cluster=\"__CLUSTER_NAME__\"}[1m]))) > 0"
                                                },
                                                "plotType": "LINE",
                                                "legendTemplate": "stalled (${metric.labels.pod})"
                                          }
                                    ],
                                    "yAxis": {
                                          "label": "Seconds/s",
                                          "scale": "LINEAR"
                                    },
                                    "chartOptions": {
                                          "mode": "COLOR"
                                    }
                              }
                        }
                  }
            ]
      }
}
