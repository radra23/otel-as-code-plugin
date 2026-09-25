package main

import (
	"log"
	"net/http"
)

// A separate MODULE — its own go.mod means its own service, independent of orders.
func main() {
	http.HandleFunc("/shipments", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	log.Fatal(http.ListenAndServe(":8081", nil))
}
