// chi-service — a net/http-compatible router (chi wraps http.Handler directly), covered by
// the Go generator's net/http-only scope for free.
package main

import (
	"net/http"

	"github.com/go-chi/chi/v5"
)

func main() {
	r := chi.NewRouter()
	r.Get("/health", func(w http.ResponseWriter, req *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	http.ListenAndServe(":8080", r)
}
