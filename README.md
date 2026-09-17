# local-platform

A local Kubernetes platform-engineering lab: Kind clusters, Argo CD GitOps,
Argo Rollouts progressive delivery, Gateway API/Istio, observability, and
container supply-chain security. See [CLAUDE.md](CLAUDE.md) for the full
project spec and milestone roadmap.

This repo currently implements **Milestones 1-2**: dev and prod Kind
clusters, Terraform-driven bootstrap, one hello-world application, GitHub
Actions CI publishing to GHCR, Argo CD deploying it via GitOps in both
environments, and semantic-release-driven promotion of the exact validated
dev digest to prod (no rebuild).

## Prerequisites

- Docker (daemon running)
- [kind](https://kind.sigs.k8s.io/)
- kubectl
- [Helm](https://helm.sh/)
- [Terraform](https://developer.hashicorp.com/terraform) >= 1.5
- [kustomize](https://kustomize.io/) (only needed if you want to run the
  same checks CI runs, locally)

## Secrets

This repo and its GHCR packages are **private**. Bootstrap needs a GitHub
PAT to let Argo CD read the repo and the Kind node pull the image:

1. Create a **classic** PAT (not fine-grained -- fine-grained PATs have no
   "Packages" permission at all, so GHCR auth requires classic) with
   scopes **repo** and **read:packages**.
2. `cp .env.local.example .env.local` and fill in the two values.
   `.env.local` is gitignored and `scripts/bootstrap.sh` sources it
   automatically. It's also denied to Claude (see `.claude/settings.json`)
   so the token never ends up in a conversation transcript.

   Alternatively, just export the two vars in your shell instead of using
   `.env.local`:

   ```bash
   export TF_VAR_github_username=<your-github-username>
   export TF_VAR_github_token=<the-pat>
   ```

CI itself doesn't need this PAT -- it uses the default `GITHUB_TOKEN` for
both pushing to GHCR and committing the resulting image digest back to
`gitops/dev/hello-world`.

One manual, one-time repo setting is also required (not Terraform-managed,
since it's a GitHub API/UI setting rather than cluster or repo content):
**Settings -> Actions -> General -> Workflow permissions -> "Read and write
permissions"**, so CI can push its GitOps-update commit and packages.

## Quick start

```bash
make bootstrap                                # dev cluster
make bootstrap-prod                            # prod cluster
export KUBECONFIG=$(terraform -chdir=terraform/environments/dev output -raw kubeconfig_path)

kubectl get nodes
kubectl -n argocd get application hello-world
```

Both are idempotent -- re-running reconciles any drift instead of failing.

## Tear down

```bash
make destroy
make destroy-prod
```

## Release / promotion

Semantic-release drives production promotion. It runs (`.github/workflows/release.yml`)
only after `hello-world CI` (lint/test/build/push) has completed
successfully on `main` -- an explicit `workflow_run` dependency, not an
inference from which files changed, so nothing reaches prod without having
passed CI first. There's deliberately no manual approval step: trunk-based
development wants small changes to ship often, and gating that on a human
just creates a queue. The automated safety net that makes this genuinely
safe at high frequency (canary analysis, automatic rollback) lands in
Milestone 4 -- until then this gate is CI passing, not yet a live rollout
health check.

**Commit messages on `main` must follow [Conventional Commits](https://www.conventionalcommits.org/)**
(`feat: ...`, `fix: ...`, `chore: ...`, etc.) -- `@semantic-release/commit-analyzer`
uses the prefix to decide whether a commit warrants a release and what kind
(`feat` -> minor, `fix` -> patch, breaking change -> major). Anything else
("chore", "docs", the bot's own `chore(gitops): ...` commits) is correctly
ignored and never triggers a release.

When a release fires, it re-tags the digest already deployed in
`gitops/dev/hello-world` with the new semver (`docker buildx imagetools
create`, no rebuild) and patches that same digest into
`gitops/prod/hello-world`, matching the immutable-artefact-promotion model
in [CLAUDE.md](CLAUDE.md).

## Repository layout

```
apps/hello-world/         Go app source, tests, Dockerfile, Kustomize base
terraform/modules/        Reusable Terraform modules (kind-cluster)
terraform/environments/   Per-environment root modules (dev, prod)
platform/argocd/          Argo CD Helm values + root app-of-apps Application, per environment
gitops/dev/, gitops/prod/ Argo CD Application manifests + Kustomize overlays, reconciled by Argo CD
scripts/                  Bootstrap automation
.github/workflows/        CI (app build/test/push, terraform validate, manifest validate) + release/promotion
```
