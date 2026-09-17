package handlers

import "net/http"

// Ready handles "/ready" (readiness). Milestone 1 has no failure
// simulation wired in yet, so this always reports ready.
func Ready(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
