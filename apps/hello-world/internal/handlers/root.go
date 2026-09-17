package handlers

import (
	"fmt"
	"net/http"

	"github.com/chliddle/local-platform/apps/hello-world/internal/buildinfo"
)

const rootTemplate = `<!doctype html>
<html>
<head><title>%s</title></head>
<body>
<h1>%s</h1>
<ul>
<li>version: %s</li>
<li>git commit: %s</li>
<li>environment: %s</li>
<li>hostname: %s</li>
</ul>
</body>
</html>
`

// Root handles "/": a human-readable page showing app identity.
func Root(w http.ResponseWriter, r *http.Request) {
	info := buildinfo.Current()

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, rootTemplate, info.Name, info.Name, info.Version, info.GitCommitSHA, info.Environment, info.Hostname)
}
