# local-platform

A local Kubernetes platform-engineering lab: Kind clusters, Argo CD GitOps,
Argo Rollouts progressive delivery, Gateway API/Istio, observability, and
container supply-chain security. See [CLAUDE.md](CLAUDE.md) for the full
project spec and milestone roadmap.

This repo currently implements **Milestone 1**: a dev Kind cluster,
Terraform-driven bootstrap, one hello-world application, GitHub Actions CI
publishing to GHCR, and Argo CD deploying it via GitOps.

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

1. Create a fine-grained PAT scoped to this repo: **Contents: Read-only**,
   plus **read:packages** for GHCR.
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
make bootstrap
export KUBECONFIG=$(terraform -chdir=terraform/environments/dev output -raw kubeconfig_path)

kubectl get nodes
kubectl -n argocd get application hello-world
```

`make bootstrap` is idempotent -- re-running it reconciles any drift instead
of failing.

## Tear down

```bash
make destroy
```

## Repository layout

```
apps/hello-world/        Go app source, tests, Dockerfile, Kustomize base
terraform/modules/        Reusable Terraform modules (kind-cluster)
terraform/environments/   Per-environment root modules (dev)
platform/argocd/          Argo CD Helm values + the root app-of-apps Application
gitops/dev/                Argo CD Application manifests + Kustomize overlays, reconciled by Argo CD
scripts/                  Bootstrap automation
.github/workflows/        CI: app build/test/push, terraform validate, manifest validate
```
