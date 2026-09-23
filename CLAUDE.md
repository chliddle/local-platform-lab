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
│   └── environments/     # dev, prod, management
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
already-onboarded app, and vice versa) is done: `ci-integration.yml`
(this repo) asserts every app under `gitops/{dev,prod}/apps/` is actually
Synced+Healthy in the real dev/prod clusters, running on the self-hosted
runner from Milestone 4. A throwaway-Kind-cluster version of this was
tried first (see git history) and dropped after repeatedly hitting Argo
CD's reconciliation-timer lag on a cold cluster spun up fresh every run --
a cost of that specific model, not a real bug, and resolved by testing
against the real, already-warm clusters instead.

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

**Status: Milestones 1-4 complete (Milestone 2 extended into a
self-service multi-repo platform, below). Milestone 5 is next.**

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
* branch protection on `main` in all three repos: no force-push, no
  deletion. Required status checks are a separate per-repo choice (see
  the zizmor bullet below) -- outside contributors can't merge anything
  anywhere regardless, since only the owner has write access to any of
  the three repos
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
* a zizmor pre-commit hook (offline audits only, so it never depends on
  a developer's GitHub token being valid) and a `security lint` CI job
  (online audits) in all three repos, catching dangerous GitHub Actions
  patterns -- confirmed by hand that it blocks a deliberately
  reintroduced `pull_request_target` + PR-title-injection test workflow.
  **Required as a branch-protection status check only on the platform
  repo.** The two app repos' own automation (`ci.yml`'s digest-bump
  commit, `release.yml`'s prod promotion, `template-init.yml`) pushes
  bot-authored commits directly to `main`, and GitHub rejects *any*
  direct push whose exact commit SHA hasn't already had a required check
  run against it -- a freshly-created bot commit never has one, so
  requiring the check there breaks the self-service pipeline itself
  (confirmed live: `update-dev-digest` failed with "GH006: Protected
  branch update failed... Required status check 'zizmor' is expected").
  Required status checks are fundamentally a PR-merge-gate mechanism,
  not a way to gate direct pushes from same-repo automation -- keep this
  in mind before requiring any check on a repo whose own CI pushes to
  its default branch
* decide and document: do GHCR packages also go public, or stay private
  while the repos go public? Independent choice, not automatic either
  way

**Status: complete.** All three repos are public, license (MIT),
branch-protected, action-pinned, secret-scanned (GitHub push protection
+ local pre-commit), and Dependabot-enabled. GHCR packages stay private.

## Milestone 4 -- complete

* [x] dedicated management Kind cluster (`terraform/environments/management/`,
  mirrors dev/prod's structure via the shared `kind-cluster` module) --
  not dev, not prod (see GitHub Actions Runners)
* [x] self-hosted GitHub Actions runner (GitHub Actions Runner Controller,
  modern `gha-runner-scale-set` charts) for the platform repo, wired up
  per Milestone 3's binding trigger constraint from the start -- verified
  live that a real job lands on the runner via `workflow_dispatch`/`push`
  and that no workflow anywhere has a `pull_request` trigger. Authenticated
  via a fine-grained PAT (`Repository administration: Read and write`,
  scoped to this one repo only) rather than a GitHub App -- functionally
  equivalent permission either way; the App's shorter-lived token was
  judged not worth the extra setup ceremony for a single-owner project
  (see Security implications, below). Self-service app repos (Milestone 2)
  don't have their own runner yet -- deferred as a fast-follow, since
  nothing in this milestone's actual scope required it (see Security
  implications)
* [x] rootless BuildKit (`moby/buildkit:*-rootless`, pinned to a digest) as
  a `Deployment`+`Service`+`NetworkPolicy` in the management cluster --
  no Docker socket mount, no privileged Docker-in-Docker sidecar, ingress
  restricted to the runner's own namespace. Verified live: a real
  multi-arch (`linux/amd64`+`linux/arm64`) image built and pushed via
  buildx's `remote` driver, no changes needed to the actual
  `docker/build-push-action` step app repos already use -- only the
  buildx driver setup changes, so wiring this into the app repos'
  `ci.yml`/`release.yml` later is a small, low-risk change
* [x] RBAC scoped to what the runner actually needs: a namespaced
  `Role` in dev and prod granting `get/list/watch` on
  `applications.argoproj.io` only (no secrets, no exec, no write verbs --
  verified live that a delete attempt is rejected as `Forbidden`), and a
  separate namespaced `Role` in the management cluster letting the
  runner pod's own ServiceAccount read exactly the two credential Secrets
  it needs (`dev-argocd-reader`, `prod-argocd-reader`), nothing else in
  its namespace
* [x] real cross-repo integration testing against the actual dev/prod
  clusters (`ci-integration.yml`) -- verified live pulling real
  Synced/Healthy status for every app in both environments. Supersedes
  the throwaway-Kind-cluster version tried first from GitHub-hosted
  runners and dropped after repeatedly hitting Argo CD's
  reconciliation-timer lag on a cluster that's always cold (see
  Repository Structure)
* [x] documented security implications of CI compute sharing infra with
  application workloads -- see below

### Security implications

This is the milestone where a public repo's CI first gets real compute
and real network reach on the repo owner's own machine, so the questions
below were checked empirically (live `docker inspect`, live RBAC tests
against running clusters, live credential extraction and API calls) via
two independent adversarial reviews with no prior context on the design,
not assumed from the Terraform reading as intended.

* **No path from any pod to the actual host filesystem.** Verified live
  across all three Kind clusters (dev, prod, management): the only host
  bind-mounts anywhere are `/lib/modules` (read-only) and Docker-managed
  named volumes -- nothing mounts a macOS path, anywhere, in any cluster.
  A full container breakout on a privileged Kind node (see below) lands
  inside Docker Desktop's shared Linux VM, not on the real host; reaching
  macOS itself would need a second, separate hypervisor escape that
  nothing in this project's Kubernetes/Terraform configuration touches
  either way -- that boundary is Docker Desktop's, not this platform's
* **Kind nodes running privileged is pre-existing, not new here.** All
  three Kind node containers (dev, prod, management) run `--privileged`
  with unconfined seccomp/AppArmor -- verified identical across all
  three. This is Kind's own architecture (nested containerd needs it),
  true since Milestone 1, and not something this milestone made worse.
  What this milestone actually changes is that a privileged node now
  hosts pods reachable by an automated trigger (`push` to `main`) instead
  of only by the owner's own `kubectl apply` -- which is exactly why the
  Milestone 3 trigger constraint (no `pull_request`, ever) is binding
  rather than advisory
* **Rootless BuildKit's relaxed seccomp/AppArmor is the documented
  upstream trade-off, not a local misconfiguration** -- verified the live
  pod spec matches moby/buildkit's own reference Kubernetes manifest
  exactly. Its safety model comes from the kernel's unprivileged
  user-namespace mapping (a `RUN` step's "root" maps back to a real
  non-root UID outside the build sandbox), not from seccomp filtering;
  disabling seccomp/AppArmor removes a filtering layer that would
  otherwise partially defend against a kernel 0-day in namespace
  handling specifically -- a real but narrow residual risk, not a
  configuration bug. The buildkitd endpoint itself has no auth of its
  own (plain TCP); access control is entirely delegated to the
  `NetworkPolicy` restricting ingress to the runner's namespace
* **The runner pod carries no meaningful privilege of its own** --
  verified live: no `hostPath`/`hostNetwork`/`hostPID`, no dind sidecar,
  non-root by the image's own default, zero `ClusterRoleBindings`, and
  exactly the two namespaced `Role`s described above
* **Credential blast radius, checked against the live account/clusters,
  not just the manifests:** the runner's PAT is confirmed scoped to this
  one repo only (`403`/`404` against every other repo on the account) and
  to `Administration` only -- confirmed it cannot push code directly
  (a probe write was rejected needing `contents=write`, which this token
  doesn't have). The one real escalation path is `Administration:write`
  including deploy-key management, so a fully compromised management
  cluster could add a push-capable deploy key -- but that already
  requires first fully compromising the cluster, which independently
  grants direct read of the dev/prod Argo CD tokens anyway; what it adds
  beyond that is persistence in the platform repo's source past a
  cluster wipe. The dev/prod reader credential was independently
  confirmed live to be exactly as narrow as configured (`Forbidden` on
  secrets, pods, and any write attempt)
* **The actual widest-blast-radius credential in this whole platform
  predates this milestone and lives outside it**: the classic PAT used
  for Argo CD's git credential and the GHCR pull secret in dev/prod
  (`TF_VAR_github_token`, sourced from `~/.zshrc`) carries `repo` +
  `write:packages` -- full read/write on every repo on the account,
  private ones included, far broader than the new runner PAT. Flagged
  for future rescoping (now that all three repos are public, the `repo`
  scope is likely obsolete -- anonymous HTTPS clone works for public
  repos, only the GHCR pull half is still load-bearing and needs nothing
  beyond `packages:read`); not fixed as part of this milestone since it
  predates it and the user judged current risk acceptable for now
* **No automated pre-merge check on an external PR's diff, by design.**
  Since no workflow anywhere triggers on `pull_request` (Milestone 3),
  `zizmor`/lint/tests only ever run post-merge (`push`). The owner's own
  read-through before clicking merge is the actual, only defense against
  a malicious external PR's content -- not a tooling backstop. This is
  the accepted cost of removing the automated-trigger attack surface
  entirely rather than merely bounding it
* **Container IPs used for cross-cluster access aren't stable.**
  `scripts/sync-runner-creds.sh` resolves dev/prod's control-plane
  container IP on the shared `kind` Docker network at write time; Docker
  doesn't guarantee the same IP across `kind delete`/`create`, so this
  script must be re-run after recreating dev, prod, or management, or
  `ci-integration.yml` will fail against a stale address

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
