// Command opencode2api starts the API gateway and its management interface.
package main

import (
	"context"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	adminui "opencode2api/internal/admin"
	"opencode2api/internal/buildinfo"
	"opencode2api/internal/config"
	"opencode2api/internal/gateway"
	"opencode2api/internal/telemetry"
)

// version remains the linker injection point used by release builds.
var version = "dev"

// main loads the configuration, starts the gateway runtime and the API and
// WebUI servers, and shuts them down on SIGINT or SIGTERM.
//
// With -unified the /v1/* + /healthz API and the /api/* + WebUI management
// surface are multiplexed onto a single listener bound to cfg.Listen (typically
// 0.0.0.0:80 on a single-port host such as blitz.cloud). The WebUI listen
// address is ignored in that mode. Without the flag the legacy two-listener
// layout is preserved: API on cfg.Listen, WebUI on cfg.WebUI.Listen.
func main() {
	buildinfo.Version = version
	configPath := flag.String("config", "config.json", "path to config.json")
	listen := flag.String("listen", "", "override the configured API listen address")
	webListen := flag.String("web-listen", "", "override the configured WebUI listen address")
	unified := flag.Bool("unified", false, "serve API and WebUI on a single listener bound to cfg.Listen")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		slog.Error("configuration error", "error", err)
		os.Exit(1)
	}
	if *listen != "" {
		cfg.Listen = *listen
	}
	if *webListen != "" && !*unified {
		cfg.WebUI.Listen = *webListen
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	level := new(slog.LevelVar)
	telemetry.SetLogLevel(level, cfg.Logging.Level)
	hub := telemetry.LogHub(cfg.Logging.RingSize)
	redactor := config.SecretRedactor()
	redactor.Replace(cfg)
	logger := telemetry.StructuredLogger(level, hub, redactor)
	monitor := telemetry.Monitor()
	manager, err := gateway.RuntimeManager(ctx, *configPath, cfg, logger, monitor, hub, redactor, level)
	if err != nil {
		logger.Error("failed to initialize runtime", "component", "runtime", "event", "runtime_initialization_failed", "error", err)
		os.Exit(1)
	}
	defer manager.Shutdown()

	// manager.Handler() is the single dynamic wrapper that routes requests to
	// whichever gateway runtime is current, so it is also the hot-reload seam
	// in unified mode. Build it once and reuse it in both layouts; calling it
	// twice would give each server its own router and break hot reload.
	dynamicGateway := manager.Handler()
	var handler http.Handler = dynamicGateway
	if *unified && cfg.WebUI.Enabled {
		admin := adminui.New(manager, monitor, hub, logger)
		handler = unifiedHandler(dynamicGateway, admin.Handler())
	}

	component := "api"
	if *unified && cfg.WebUI.Enabled {
		component = "unified"
	}
	apiServer := &http.Server{
		Addr: cfg.Listen, Handler: handler, ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 120 * time.Second,
	}
	servers := []*http.Server{apiServer}
	go serveHTTP(cancel, logger, apiServer, component)

	if cfg.WebUI.Enabled && !*unified {
		admin := adminui.New(manager, monitor, hub, logger)
		webServer := &http.Server{
			Addr: cfg.WebUI.Listen, Handler: admin.Handler(), ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 120 * time.Second,
		}
		servers = append(servers, webServer)
		go serveHTTP(cancel, logger, webServer, "webui")
	}

	<-ctx.Done()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()
	for _, server := range servers {
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Error("graceful shutdown failed", "component", "server", "event", "shutdown_failed", "address", server.Addr, "error", err)
		}
	}
}

// unifiedHandler multiplexes the gateway API (/v1/*, /healthz) and the admin
// API + embedded WebUI (/api/*, /) onto a single http.Handler so both can be
// served from one listener.
//
// The two route sets share no prefixes, so dispatch is unambiguous:
//   - /v1/*    -> gateway (inference, models, systemone)
//   - /healthz -> gateway health check
//   - /api/*   -> admin management API
//   - /        -> embedded WebUI static assets (SPA fallback to index.html)
//
// `gateway` must be the dynamic RuntimeController handler (not a static mux),
// because it carries the hot-reload seam that applies configuration changes to
// new requests. Passing the static mux would pin the listener to the
// first-built runtime and silently break configuration hot reload.
func unifiedHandler(gateway http.Handler, admin http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if strings.HasPrefix(path, "/v1/") || path == "/v1" || path == "/healthz" {
			gateway.ServeHTTP(w, r)
			return
		}
		admin.ServeHTTP(w, r)
	})
}

// serveHTTP serves server until it is shut down. An unexpected stop is logged
// and cancels the root context, which begins the shutdown of every server.
func serveHTTP(cancel context.CancelFunc, logger *slog.Logger, server *http.Server, component string) {
	logger.Info("server listening", "component", component, "event", "server_started", "address", server.Addr, "version", buildinfo.Version)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Error("server stopped unexpectedly", "component", "server", "event", "server_failed", "address", server.Addr, "error", err)
		cancel()
	}
}
