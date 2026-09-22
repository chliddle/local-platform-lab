# Local Kubernetes Platform & Progressive Delivery Lab

## Project Purpose

Build a production-style local Kubernetes platform used to learn, test and demonstrate:

* Kubernetes platform engineering
* GitHub Actions CI
* GitOps with Argo CD
* Progressive delivery with Argo Rollouts
* Gateway API
* Canary and blue/green deployments
* Traffic splitting and A/B testing
* Dark launches
* Observability and synthetic monitoring
* Automated rollback
* Container supply-chain security
* Kubernetes admission policy
* Trunk-based development and artefact promotion

The project should favour production-style patterns while remaining practical to run locally.

---

# Architecture Principles

* Everything should be reproducible from Git.
* Infrastructure should be created using Terraform where practical.
* Avoid manual cluster configuration.
* GitHub Actions owns CI.
* Argo CD owns Kubernetes deployment/reconciliation.
* Argo Rollouts owns progressive delivery.
* Applications should be deployed from immutable image digests.
* Build an artefact once and promote the same digest between environments.
* Secrets must never be committed to Git.
* Prefer declarative configuration over imperative scripts.
* All major platform components should be installed through Helm or GitOps.
* Changes should be small, testable and reversible.

---

# Local Kubernetes Environments

Create two local Kubernetes clusters using Kind:

* dev
* prod

Terraform is preferred for cluster/bootstrap orchestration where practical.

Provide a bootstrap command/script capable of recreating the entire environment.

Example goal:

```
make bootstrap
```

or:

```
./scripts/bootstrap.sh
```

The bootstrap process should be idempotent where possible.

---

# GitHub Actions Runners

Deploy self-hosted GitHub Actions runners for local CI/CD experimentation.

Prefer:

* GitHub Actions Runner Controller (ARC)

Requirements:

* runner authentication must not be committed to Git
* runner workloads should use dedicated namespaces/service accounts
* runner permissions should follow least privilege
* consider ephemeral runners
* a rootless/daemonless image builder (BuildKit rootless or Kaniko) for
  any workflow that builds a container image -- the host Docker socket
  and privileged Docker-in-Docker are both host-escape vectors and are
  not used

Document the security implications of allowing CI runners access to a Kubernetes cluster.

**Binding constraint, since this project is intended to go public (see
Milestone 3): self-hosted runners may only be triggered by `push` to
`main` or `workflow_dispatch`, never by `pull_request`.** A self-hosted
runner executing a workflow from a fork's PR is a remote-code-execution
vector against whatever hosts the runner -- in this project's case, the
user's own machine. Anything that needs to validate an external PR
(lint/test/build-check) runs on GitHub-hosted runners instead, which are
safe by design regardless of who opened the PR.

Runners live on a dedicated **management cluster** (Milestone 4), not dev or
prod: colocating CI compute with application workloads means arbitrary (in a
supply-chain-compromise scenario, attacker-influenced) workflow code runs in
the same cluster as production, with the lateral-movement and
resource-contention risk that implies. The management cluster is also the
intended home for centralized observability (Milestone 7) rather than
duplicating a full stack per cluster.

---

# GitOps

Deploy Argo CD to both clusters.

Argo CD should monitor the GitHub repository and reconcile declared Kubernetes state.

The platform is multi-repo and self-service (see Repository Structure): this
platform repo's `gitops/<env>/apps/` holds one lightweight `Application`
manifest per onboarded app, each pointing at that app's *own* repo and its
own `deploy/overlays/<env>` path. Argo CD's repo credentials are a
credential *template* (`argocd.argoproj.io/secret-type: repo-creds`,
matched by GitHub account URL prefix), not one secret per repo -- so
onboarding a new app-team repo is exactly one Terraform-free change: add
its `Application` manifest here.

GitHub Actions should NOT directly deploy application manifests using kubectl unless specifically testing a non-GitOps pattern.

Preferred flow:

```
GitHub Actions
    -> test/build/scan/sign
    -> push image
    -> update GitOps desired state

Argo CD
    -> detect desired state change
    -> reconcile cluster
```

---

# Progressive Delivery

Deploy Argo Rollouts.

Use it to experiment with:

* standard rolling deployments
* canary deployments
* blue/green deployments
* weighted traffic splitting
* A/B testing
* dark launches
* automated promotion
* automated rollback

Each strategy should have its own example application/configuration.

---

# Gateway API

Install Kubernetes Gateway API CRDs.

Install a Gateway API implementation/controller.

Preferred options:

1. Istio
2. Envoy Gateway

Istio is preferred initially because the lab should also demonstrate:

* ingress TLS termination
* internal mTLS
* workload identity
* Gateway API routing
* Istio VirtualService routing
* comparison between Gateway API and Istio-native routing

Provide examples for:

* Gateway
* GatewayClass
* HTTPRoute
* path routing
* hostname routing
* weighted backendRefs
* TLS termination

---

# Local Load Balancing

Provide local LoadBalancer support for Kind.

Evaluate:

* cloud-provider-kind
* MetalLB

The implementation must allow Gateway API implementations to expose services locally.

---

# DNS

Provide predictable local DNS names for applications.

Example:

```
app1.dev.platform.local
app2.dev.platform.local

app1.prod.platform.local
app2.prod.platform.local
```

Possible implementations:

* dnsmasq
* local hosts configuration
* another simple local DNS solution

Document the chosen approach.

---

# TLS and Certificates

Deploy cert-manager.

Use a local/private CA initially.

Demonstrate:

* root CA
* intermediate CA where practical
* leaf/server certificate
* Certificate resource
* Issuer / ClusterIssuer
* Kubernetes TLS Secret
* Gateway API certificateRefs
* certificate renewal

TLS should terminate at the configured Gateway implementation.

If Istio is used:

```
client
  -> public/local TLS
  -> Istio Gateway Envoy
  -> Istio mTLS
  -> workload Envoy
  -> application
```

---

# Example Applications

Create several small web services.

Start with a simple hello-world application but make it capable of simulating failures.

The application should expose:

```
/
/health
/ready
/version
/metrics
```

It should display:

* application name
* application version
* Git commit SHA
* environment
* pod hostname

Provide ways to simulate:

* HTTP 500 responses
* increased latency
* failed readiness
* failed liveness
* high error rate
* intermittent failures

This will allow progressive delivery failure scenarios to be tested.

---

# Container Images

Images should be built by GitHub Actions.

Registry:

* GitHub Container Registry (GHCR)

Tag images with:

* Git commit SHA
* semantic release version where appropriate

Deploy using immutable digest:

```
ghcr.io/<org>/<app>@sha256:<digest>
```

Never rebuild an image when promoting between environments.

The exact same digest must move through:

```
dev -> validation -> prod
```

---

# Container Supply Chain

Add:

* Trivy image scanning
* dependency scanning
* secret scanning
* SBOM generation
* Cosign image signing

Where practical, sign images using GitHub Actions OIDC/keyless signing.

Kyverno should verify trusted images before admission.

---

# Kubernetes Security

Deploy Kyverno.

Start policies in Audit mode before moving stable policies to Enforce.

Implement policies for:

* require runAsNonRoot
* disallow privileged containers
* disallow privilege escalation
* drop Linux capabilities
* RuntimeDefault seccomp
* restrict hostNetwork
* restrict hostPID
* restrict hostIPC
* restrict hostPath
* trusted container registries
* signed container images
* resource requests/limits
* readiness/liveness probes
* disallow latest image tag

Document any required PolicyExceptions.

---

# Observability

Deploy:

* Prometheus
* Grafana
* Loki
* Tempo
* OpenTelemetry Collector
* Blackbox Exporter

Mimir may be added later for experimentation with scalable metrics storage.

Applications should expose Prometheus metrics.

Capture:

* request count
* HTTP status
* request latency
* pod health
* rollout state
* Kubernetes metrics

---

# Synthetic Monitoring

Use Blackbox Exporter and/or dedicated synthetic test jobs to continuously test applications.

Validate:

* HTTP success
* expected response content
* latency
* TLS availability
* DNS resolution

Use these signals where possible as part of progressive delivery analysis.

---

# Progressive Delivery Dashboard

Create Grafana dashboards showing:

* stable version
* canary version
* traffic percentage
* request rate
* HTTP 2xx
* HTTP 5xx
* latency
* pod health
* rollout status
* synthetic probe results

The goal is to visually observe a rollout succeed or fail.

---

# CI Pipeline

The CI pipeline should demonstrate trunk-based development.

## Feature / Change Validation

Run:

* formatting
* linting
* unit tests
* manifest validation
* Helm linting where applicable
* Terraform validation
* security scanning
* dependency scanning
* container scanning

Build the application image once.

Tag it using the Git commit SHA.

Push it to GHCR.

---

# Development Validation

Deploy the candidate artefact to the dev cluster through GitOps.

Run deployment scenarios in isolated namespaces where practical.

Examples:

```
rollout-canary
rollout-bluegreen
rollout-ab
rollout-dark
```

Run:

* integration tests
* API tests
* synthetic tests
* failure simulations
* rollout validation

---

# Failure Behaviour

A bad release must never require rewriting shared Git history.

If a rollout fails:

1. Argo Rollouts should abort the rollout.
2. Traffic should remain on or return to the stable version.
3. The failed candidate must not be promoted.
4. CI should report failure.
5. Git should be corrected using a normal revert commit where necessary.

Never:

* force push main
* reset shared main
* delete later developers' commits

Prefer:

```
git revert <bad-commit>
```

For incomplete features, evaluate feature flags.

---

# Main Branch Protection

Evaluate two trunk-based approaches.

## PR-based trunk development

```
short-lived branch
  -> PR
  -> CI
  -> review
  -> merge main
```

Use:

* required status checks
* required review
* branch protection
* CODEOWNERS where appropriate
* merge queue where useful

## Direct-to-main trunk development

Create a separate experiment documenting how a mature team could safely allow direct commits to main.

Requirements should include:

* pair programming/peer review
* very small commits
* comprehensive automated CI
* feature flags
* immediate deployment validation
* progressive delivery
* automatic traffic rollback
* easy Git revert

Compare the advantages and risks of both approaches.

---

# Release Process

After validation succeeds:

1. Determine semantic version using semantic-release.
2. Create Git release/tag.
3. Add semantic image tag to the existing image digest.
4. Do NOT rebuild the image.
5. Promote the exact tested digest to production.

Example:

```
commit:
  abc123

initial image:
  app:abc123

immutable artefact:
  app@sha256:123456...

release:
  Git tag v1.4.0
  app:v1.4.0 -> same sha256:123456...

production:
  app@sha256:123456...
```

---

# Production Deployment

Production deployments should be initiated by changing GitOps desired state.

Argo CD should reconcile the production cluster.

Argo Rollouts should control progressive delivery.

Production should use the same rollout strategies available in development.

Promotion may require GitHub Environment approval.

Use:

* GitHub protected environments
* required reviewers
* environment-specific permissions
* concurrency controls

Ensure simultaneous releases cannot unintentionally overwrite each other.

---

# Rollback

Distinguish between two types of rollback.

Runtime rollback:

```
Argo Rollouts
  -> detects failed analysis
  -> aborts candidate
  -> returns traffic to stable version
```

Source-of-truth rollback:

```
git revert
  -> corrects desired state
  -> Argo CD reconciles
```

Never rely on manually changing production Kubernetes resources as the normal rollback mechanism.

---

# Repository Structure

**This is a multi-repo, self-service platform, not a monorepo.** One
platform repo owns clusters and cluster-facing GitOps; each application
owns its own repo end to end (code, tests, container build, semantic
versioning, deploy manifests, promotion). Onboarding a new app is one
Application-manifest commit in the platform repo -- never a Terraform
change, never write access to the platform repo for the app team.

## Platform repo (this one, `local-platform-lab`)

```
.
├── platform/
│   ├── argocd/
│   ├── argo-rollouts/
│   ├── cert-manager/
│   ├── gateway-api/
│   ├── istio/
│   ├── kyverno/
│   └── observability/
│
├── gitops/
│   ├── dev/
│   │   └── apps/        # one Application manifest per onboarded app,
│   └── prod/             # pointing at that app's own repo
│
├── terraform/
│   ├── modules/
│   └── environments/     # dev, prod, and (Milestone 4) management
│
├── scripts/
│
├── .github/
│   └── workflows/        # terraform validate, GitOps manifest validate
│
└── CLAUDE.md
```

## App repos (one per self-service app, generated from the
`local-platform-lab-app-template` template repo -- e.g. `template-test-1`)

```
.
├── main.go, internal/, go.mod, ...    # the app itself
├── Dockerfile
│
├── deploy/
│   ├── base/              # Kustomize base
│   └── overlays/
│       ├── dev/           # images: pinned digest, patched by this repo's own CI
│       └── prod/          # images: pinned digest, patched by this repo's own release
│
├── scripts/
│   └── smoke-test.sh      # asserts the platform's app contract: /, /health,
│                           # /ready, /version, /metrics
│
└── .github/
    └── workflows/
        ├── ci.yml          # lint, test, ephemeral-cluster smoke test, build,
        │                    # push to GHCR, patch deploy/overlays/dev
        └── release.yml     # gated on ci.yml succeeding; semantic-release,
                             # then promotes the same digest (no rebuild) to
                             # deploy/overlays/prod
```

Each app repo's own CI is the only thing that ever writes to that repo;
the platform repo is never a target of an app team's automation, and an
app team never needs credentials scoped beyond their own repo.

`tests/integration|synthetic|failure` from earlier drafts of this
structure are superseded by each repo owning its own tests this way.
Real cross-repo integration testing (does a platform change break an
already-onboarded app, and vice versa) is deferred to Milestone 4: a
throwaway-Kind-cluster version of this was tried and dropped (see git
history) after repeatedly hitting Argo CD's reconciliation-timer lag on a
cold cluster spun up fresh every run -- a cost of that specific model,
not a real bug, and moot once self-hosted runners can test against the
real, already-warm dev/prod clusters instead.

---

# Claude Working Rules

When working on this repository:

1. Plan before making significant architectural changes.
2. Explain architectural trade-offs before choosing a solution.
3. Prefer simple implementations before introducing additional components.
4. Do not introduce technology solely because it is fashionable.
5. Prefer production-style practices where they provide learning value.
6. Keep all infrastructure reproducible.
7. Do not commit secrets.
8. Do not bypass GitOps for application deployment without explaining why.
9. Do not rebuild images between environments.
10. Prefer immutable image digests.
11. Add tests with new functionality.
12. Update documentation when architecture changes.
13. Keep dev and prod configuration logically separated.
14. Avoid unnecessary abstraction early in the project.
15. Highlight security implications of architectural decisions.

When asked to implement a large feature, first provide:

* proposed architecture
* files/resources affected
* implementation sequence
* risks/trade-offs
* testing strategy

Wait for approval before performing significant architectural changes while operating in plan mode.

---

# Initial Milestones

Do not attempt to build the entire platform at once.

**Status: Milestones 1-3 complete (Milestone 2 extended into a
self-service multi-repo platform, below). Milestone 4 is next.**

## Milestone 1 -- complete

* [x] Kind dev cluster
* [x] Terraform/bootstrap automation
* [x] one hello-world application
* [x] GitHub Actions CI
* [x] GHCR image
* [x] Argo CD
* [x] basic GitOps deployment

## Milestone 2 -- complete

* [x] prod Kind cluster
* [x] environment GitOps structure
* [x] immutable digest promotion
* [x] semantic releases

Evolved beyond the original scope into a **multi-repo, self-service
platform** (see Repository Structure): this platform repo owns only
clusters and cluster-facing GitOps; application code, CI, semantic
versioning, and deploy manifests live entirely in each app team's own
repo. New app teams start from
[local-platform-lab-app-template](https://github.com/chliddle/local-platform-lab-app-template)
(click "Use this template" on GitHub) -- a one-time `template-init`
workflow renames the Go module path, app/Kubernetes-object name, and
container image to match the new repo automatically, so onboarding never
requires manual configuration beyond one `Application` manifest on the
platform side (and, only if the app needs its own namespace, one small
Terraform addition). `template-test-1` is the platform's live
example/test app, generated from that template and running Synced and
Healthy in both dev and prod.

## Milestone 3 -- complete

Repo and supply-chain hardening across all three repos (platform,
app template, and by inheritance every repo generated from it),
done before flipping any of them public. Motivation: going OSS changes
the threat model from "only I can push code that runs" to "anyone can
open a PR," and that has to be accounted for architecturally before
Milestone 4 adds infrastructure (self-hosted runners) that a compromised
workflow could reach.

* `LICENSE` in each repo
* branch protection on `main` in all three repos: required status checks
  before merge, no force-push, so an outside PR can't merge itself even
  if it happens to pass CI
* every third-party `uses:` action across every workflow in all three
  repos pinned to a full commit SHA, not a mutable tag -- a tag can be
  repointed by the action's maintainer or anyone who compromises their
  account, and would then run automatically with whatever permissions
  that job has
* every job's `permissions:` block audited to least privilege (already
  mostly true from earlier milestones; verify completeness here)
* confirm no workflow uses `pull_request_target` (executes with access to
  secrets while checking out/building untrusted PR content -- a
  well-known compromise vector GitHub explicitly warns against)
* **binding constraint for Milestone 4, stated here because it must be
  true before that work starts, not added after**: self-hosted runners
  may only be triggered by `push` to `main` or `workflow_dispatch` --
  never by `pull_request`, regardless of source. GitHub's own guidance is
  explicit that self-hosted runners executing fork-PR workflows on a
  public repo is a remote-code-execution vector against whatever hosts
  the runner (in this project's case, the user's own machine)
* GitHub secret scanning / push protection enabled on all three repos,
  as an ongoing safeguard on top of the disciplined secrets handling
  already in place (no secret has ever been committed to any of the
  three repos -- verified via full git history scan; re-verify at the
  point of actually flipping visibility)
* a gitleaks pre-commit hook (`.pre-commit-config.yaml`, pinned to a
  commit SHA) in all three repos, catching a secret before the commit is
  even made -- earlier and cheaper than GitHub's push protection;
  verified live that it blocks a realistic fake credential while not
  false-positiving on a known placeholder (AWS's own docs example key)
* decide and document: do GHCR packages also go public, or stay private
  while the repos go public? Independent choice, not automatic either
  way

**Status: complete.** All three repos are public, license (MIT),
branch-protected, action-pinned, secret-scanned (GitHub push protection
+ local pre-commit), and Dependabot-enabled. GHCR packages stay private.

## Milestone 4

* dedicated management Kind cluster (not dev, not prod --
  see GitHub Actions Runners)
* self-hosted GitHub Actions runners (GitHub Actions Runner Controller)
  for both the platform repo and self-service app repos, wired up per
  Milestone 3's binding trigger constraint from the start
* a rootless/daemonless image builder (BuildKit in rootless mode, or
  Kaniko) for any workflow that builds a container image on a
  self-hosted runner -- mounting the host's Docker socket or running a
  privileged Docker-in-Docker sidecar are both well-known host-escape
  vectors and are ruled out for this project
* RBAC scoped to what runners actually need (e.g. reaching dev/prod's
  Argo CD API for real integration testing), not broad cluster access
* real cross-repo integration testing against the actual dev/prod
  clusters (a platform change doesn't break an already-onboarded app,
  and vice versa) -- a throwaway-Kind-cluster version of this was tried
  first from GitHub-hosted runners and dropped (see Repository
  Structure); testing against the real, already-warm clusters via
  self-hosted runners avoids the reconciliation-timing problem that
  killed that approach
* documented security implications of CI compute sharing infra with
  application workloads (the reason it's a separate cluster)

## Milestone 5

* Gateway API
* Istio or Envoy Gateway
* local DNS
* cert-manager
* HTTPS application access

## Milestone 6

* Argo Rollouts
* canary
* blue/green
* automated rollback

## Milestone 7

* Prometheus
* Grafana
* Loki
* Tempo
* OpenTelemetry
* Blackbox Exporter
* rollout dashboards
* deployed on the management cluster (Milestone 4), centralized rather
  than duplicated per cluster

## Milestone 8

* Kyverno
* Cosign
* SBOM
* trusted registry/signature enforcement
* security policy testing

## Milestone 9

* A/B testing
* dark launches
* failure simulation
* comparison of deployment strategies
* documentation of trade-offs
