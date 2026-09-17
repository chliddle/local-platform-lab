// Package buildinfo holds the app identity injected at build time (via
// -ldflags) or runtime (via environment), and exposed through / and /version.
package buildinfo

import "os"

var (
	// Name is fixed -- this binary is always "hello-world".
	Name = "hello-world"

	// Version and GitCommitSHA are overridden at build time:
	//   go build -ldflags "-X .../buildinfo.Version=... -X .../buildinfo.GitCommitSHA=..."
	Version      = "dev"
	GitCommitSHA = "unknown"
)

// Info is a point-in-time snapshot of build and runtime identity.
type Info struct {
	Name         string `json:"name"`
	Version      string `json:"version"`
	GitCommitSHA string `json:"gitCommitSha"`
	Environment  string `json:"environment"`
	Hostname     string `json:"hostname"`
}

// Current reads runtime fields (environment, hostname) fresh on every call
// so it always reflects the running pod, then combines them with the
// build-time constants above.
func Current() Info {
	environment := os.Getenv("ENVIRONMENT")
	if environment == "" {
		environment = "unknown"
	}

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	return Info{
		Name:         Name,
		Version:      Version,
		GitCommitSHA: GitCommitSHA,
		Environment:  environment,
		Hostname:     hostname,
	}
}
