// Package middleware provides the single composition point every handler is
// wired through. Milestone 1 only needs request metrics here; later
// milestones (failure simulation, tracing) add more middleware in this same
// chain rather than touching individual handlers.
package middleware

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	requestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests by path and status code.",
	}, []string{"path", "status"})

	requestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency by path.",
		Buckets: prometheus.DefBuckets,
	}, []string{"path"})
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// Metrics wraps a handler, recording request count and latency labeled by
// the given logical path name (not the raw URL, to keep cardinality fixed).
func Metrics(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next(rec, r)

		requestsTotal.WithLabelValues(path, strconv.Itoa(rec.status)).Inc()
		requestDuration.WithLabelValues(path).Observe(time.Since(start).Seconds())
	}
}
