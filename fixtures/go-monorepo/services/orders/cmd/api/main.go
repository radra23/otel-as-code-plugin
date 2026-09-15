package main

import (
	"log"
	"net/http"
)

// One MODULE, two BINARIES. api and worker below are entry points of the same service —
// not two services. A scanner that treats every cmd/* as a service doubles the count.
func main() {
	http.HandleFunc("/orders", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	log.Fatal(http.ListenAndServe(":8080", nil))
}
