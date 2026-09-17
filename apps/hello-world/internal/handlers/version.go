package handlers

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/chliddle/local-platform/apps/hello-world/internal/buildinfo"
)

// Version handles "/version": JSON build/runtime identity, used by
// synthetic tests to assert the deployed digest matches the expected commit.
func Version(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err := json.NewEncoder(w).Encode(buildinfo.Current()); err != nil {
		log.Printf("encoding /version response: %v", err)
	}
}
