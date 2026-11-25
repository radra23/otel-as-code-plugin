// tests/e2e/log-trace-ids.sh (#279): a net/http service behind the golden tracing.go that logs
// one line with the request's context and one without while POST /pay is handled. The e2e puts
// the app's logging setup on the line after "log setup", either the app's own handler or the
// line /otel-instrument prints (read out of the generator). It stops on SIGTERM and shuts the
// providers down, so the batched span reaches the sink.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	shutdown, err := InitOtel(context.Background())
	if err != nil {
		panic(err)
	}

	// log setup
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/pay", func(w http.ResponseWriter, r *http.Request) {
		slog.InfoContext(r.Context(), "go pay line", "orderId", "o1")
		slog.Info("go pay line without context", "orderId", "o1")
		w.Write([]byte(`{"paid":true}`))
	})
	srv := &http.Server{Addr: "127.0.0.1:" + os.Getenv("PORT"), Handler: otelhttp.NewHandler(mux, "payments")}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			panic(err)
		}
	}()
	<-ctx.Done()
	srv.Shutdown(context.Background())
	shutdown(context.Background())
}
