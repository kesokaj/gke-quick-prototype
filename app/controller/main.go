package main

import (
	"context"
	"embed"
	"fmt"
	"html/template"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	metricsClient "k8s.io/metrics/pkg/client/clientset/versioned"
)

//go:embed ui
var uiFS embed.FS

var uiTemplate *template.Template

func init() {
	uiTemplate = template.Must(template.ParseFS(uiFS, "ui/index.html"))
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	slog.Info("sandbox controller starting")

	namespace := envOr("TARGET_NAMESPACE", "sandbox")
	deployName := envOr("DEPLOYMENT_NAME", "sandbox-pool")
	poolSize := envIntOr("POOL_SIZE", 5)

	config, err := rest.InClusterConfig()
	if err != nil {
		slog.Error("failed to get in-cluster config", "error", err)
		os.Exit(1)
	}

	// Increase throughput for high-concurrency benchmarks
	config.QPS = 100
	config.Burst = 200

	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		slog.Error("failed to create k8s client", "error", err)
		os.Exit(1)
	}

	mc, err := metricsClient.NewForConfig(config)
	if err != nil {
		slog.Warn("failed to create metrics client, metrics will be unavailable", "error", err)
		mc = nil
	}

	// Initialize pool size from actual Deployment replicas (persists across restarts).
	deploy, err := client.AppsV1().Deployments(namespace).Get(context.Background(), deployName, metav1.GetOptions{})
	if err != nil {
		slog.Warn("could not read deployment replicas, using env default", "error", err)
	} else if deploy.Spec.Replicas != nil {
		poolSize = int(*deploy.Spec.Replicas)
		slog.Info("initialized pool size from deployment", "replicas", poolSize)
	}

	store := NewStore(poolSize)
	kickCh := make(chan struct{}, 10)
	reconciler := NewReconciler(client, config, mc, store, namespace, deployName, kickCh)
	handlers := NewHandlers(client, config, store, namespace, deployName, kickCh)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	go reconciler.Run(ctx)

	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux)

	mux.Handle("GET /metrics", promhttp.Handler())

	mux.HandleFunc("GET /ui", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		data := struct {
			PoolSize int
		}{
			PoolSize: store.GetPoolSize(),
		}
		if err := uiTemplate.Execute(w, data); err != nil {
			slog.Error("failed to render UI", "error", err)
			http.Error(w, "template error", http.StatusInternalServerError)
		}
	})

	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/ui", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	})

	addr := fmt.Sprintf(":%s", envOr("PORT", "8080"))
	server := &http.Server{Addr: addr, Handler: mux}

	go func() {
		slog.Info("HTTP server listening", "addr", addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("HTTP server error", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	server.Shutdown(shutdownCtx)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envIntOr(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
