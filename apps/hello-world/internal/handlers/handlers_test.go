package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/chliddle/local-platform/apps/hello-world/internal/buildinfo"
)

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()
	Health(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	if rec.Body.String() != "ok" {
		t.Fatalf("expected body %q, got %q", "ok", rec.Body.String())
	}
}

func TestReady(t *testing.T) {
	rec := httptest.NewRecorder()
	Ready(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
}

func TestVersion(t *testing.T) {
	buildinfo.Version = "v1.2.3"
	buildinfo.GitCommitSHA = "abc1234"
	t.Cleanup(func() {
		buildinfo.Version = "dev"
		buildinfo.GitCommitSHA = "unknown"
	})

	rec := httptest.NewRecorder()
	Version(rec, httptest.NewRequest(http.MethodGet, "/version", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var got buildinfo.Info
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to decode JSON body: %v", err)
	}

	if got.Name != "hello-world" {
		t.Errorf("expected name %q, got %q", "hello-world", got.Name)
	}
	if got.Version != "v1.2.3" {
		t.Errorf("expected version %q, got %q", "v1.2.3", got.Version)
	}
	if got.GitCommitSHA != "abc1234" {
		t.Errorf("expected git commit %q, got %q", "abc1234", got.GitCommitSHA)
	}
}

func TestRoot(t *testing.T) {
	rec := httptest.NewRecorder()
	Root(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "hello-world") {
		t.Errorf("expected body to mention app name, got %q", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Errorf("expected html content type, got %q", ct)
	}
}
