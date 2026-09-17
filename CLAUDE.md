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

Document the security implications of allowing CI runners access to a Kubernetes cluster.

---

# GitOps

Deploy Argo CD to both clusters.

Argo CD should monitor the GitHub repository and reconcile declared Kubernetes state.

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

Prefer a structure similar to:

```
.
├── apps/
│   ├── hello-world/
│   └── failure-demo/
│
├── clusters/
│   ├── dev/
│   └── prod/
│
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
│   └── prod/
│
├── terraform/
│   ├── modules/
│   └── environments/
│
├── scripts/
│
├── tests/
│   ├── integration/
│   ├── synthetic/
│   └── failure/
│
├── .github/
│   └── workflows/
│
└── CLAUDE.md
```

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

## Milestone 1

* Kind dev cluster
* Terraform/bootstrap automation
* one hello-world application
* GitHub Actions CI
* GHCR image
* Argo CD
* basic GitOps deployment

## Milestone 2

* prod Kind cluster
* environment GitOps structure
* immutable digest promotion
* semantic releases

## Milestone 3

* Gateway API
* Istio or Envoy Gateway
* local DNS
* cert-manager
* HTTPS application access

## Milestone 4

* Argo Rollouts
* canary
* blue/green
* automated rollback

## Milestone 5

* Prometheus
* Grafana
* Loki
* Tempo
* OpenTelemetry
* Blackbox Exporter
* rollout dashboards

## Milestone 6

* Kyverno
* Cosign
* SBOM
* trusted registry/signature enforcement
* security policy testing

## Milestone 7

* A/B testing
* dark launches
* failure simulation
* comparison of deployment strategies
* documentation of trade-offs
