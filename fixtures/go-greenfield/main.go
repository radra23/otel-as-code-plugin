// search-api — a minimal greenfield net/http service.
//
// Carries the documented /otel-instrument wiring lines (InitOtel + otelhttp.NewHandler, and the
// optional logs lines between the "otel logs wiring" markers);
// tracing.go (which defines InitOtel) is dropped in from tests/snapshots/instrument/go by the
// e2e harness's run.sh, assembling the instrumented state /otel-instrument would leave behind.
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	shutdown, err := InitOtel(context.Background())
	if err != nil {
		panic(err)
	}
	defer shutdown(context.Background())

	// otel logs wiring begin (the optional lines /otel-instrument prints; needs Go 1.26)
	logsShutdown, _ := InitOtelLogs(context.Background())
	defer logsShutdown(context.Background())
	slog.SetDefault(slog.New(slog.NewMultiHandler(
		slog.NewTextHandler(os.Stderr, nil), // your console output, unchanged
		OtelSlogHandler(),                   // the same records, to OpenTelemetry
	)))
	// otel logs wiring end

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
		slog.InfoContext(r.Context(), "search served", "query", r.URL.Query().Get("q"))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"query":   r.URL.Query().Get("q"),
			"results": []string{},
		})
	})
	handler := otelhttp.NewHandler(mux, "search-api")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		panic(err)
	}
}
