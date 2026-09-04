// search-api — a minimal greenfield net/http service.
//
// Carries the two documented /otel-instrument wiring lines (InitOtel + otelhttp.NewHandler);
// tracing.go (which defines InitOtel) is dropped in from tests/snapshots/instrument/go by the
// e2e harness's run.sh, assembling the instrumented state /otel-instrument would leave behind.
package main

import (
	"context"
	"encoding/json"
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

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
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
