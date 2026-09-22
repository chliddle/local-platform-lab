# local-platform-lab

A local Kubernetes platform-engineering lab: Kind clusters, Argo CD GitOps,
Argo Rollouts progressive delivery, Gateway API/Istio, observability, and
container supply-chain security. See [CLAUDE.md](CLAUDE.md) for the full
project spec and milestone roadmap.

This repo currently implements **Milestones 1-2**: dev and prod Kind
clusters, Terraform-driven bootstrap, and Argo CD deploying applications
via GitOps in both environments -- plus a **self-service, multi-repo
platform model**: this repo owns clusters and cluster-facing GitOps
plumbing only. Application code, CI, semantic versioning, and deploy
manifests live in each app team's own repo (e.g.
[template-test-1](https://github.com/chliddle/template-test-1), generated
from the
[local-platform-lab-app-template](https://github.com/chliddle/local-platform-lab-app-template)
template repo). Onboarding a new app never requires touching this repo's
Terraform.

## Prerequisites

- Docker (daemon running)
- [kind](https://kind.sigs.k8s.io/)
- kubectl
- [Helm](https://helm.sh/)
- [Terraform](https://developer.hashicorp.com/terraform) >= 1.5
- [kustomize](https://kustomize.io/) (only needed if you want to run the
  same checks CI runs, locally)

## Secrets

This repo and every app repo under this GitHub account are **private**.
Bootstrap needs a GitHub PAT so Argo CD can read them and the Kind nodes
can pull private GHCR images:

1. Create a **classic** PAT (not fine-grained -- fine-grained PATs have no
   "Packages" permission at all, so GHCR auth requires classic) with
   scopes **repo** and **read:packages**.
2. `cp .env.local.example .env.local` and fill in the two values.
   `.env.local` is gitignored and `scripts/bootstrap.sh` sources it
   automatically. It's also denied to Claude (see `.claude/settings.json`,
   and `~/.claude/settings.json` for the cross-project version of the same
   rule) so the token never ends up in a conversation transcript.

   Alternatively, just export the two vars in your shell instead of using
   `.env.local`:

   ```bash
   export TF_VAR_github_username=<your-github-username>
   export TF_VAR_github_token=<the-pat>
   ```

One manual, one-time repo setting is also required in **each** repo (not
Terraform-managed, since it's a GitHub API/UI setting rather than cluster
or repo content): **Settings -> Actions -> General -> Workflow permissions
-> "Read and write permissions"**, so each repo's own CI can push its
digest-update and release commits.

## Quick start

```bash
make bootstrap                                # dev cluster
make bootstrap-prod                            # prod cluster

kubectl config use-context kind-local-platform-dev
kubectl get nodes
kubectl -n argocd get application template-test-1
```

Both are idempotent -- re-running reconciles any drift instead of failing.
Each bootstrap also merges that cluster's context into `~/.kube/config`
(backed up first, to `~/.kube/config.bak`), so `kubectl config
use-context kind-local-platform-{dev,prod}` works without exporting
`KUBECONFIG` by hand. The isolated per-environment kubeconfig
(`terraform/environments/<env>/kubeconfig-*`, what `terraform output
kubeconfig_path` gives you) still exists too, for scripting that
shouldn't depend on or disturb your current kubectl context.

## Tear down

```bash
make destroy
make destroy-prod
```

Also removes that cluster's context from `~/.kube/config`, so a
destroyed cluster doesn't leave a dead entry behind.

## Self-service app onboarding

Argo CD's repo credentials are a **credential template** (`argocd.argoproj.io/secret-type: repo-creds`),
matched by URL **prefix** (`https://github.com/chliddle/`), not a secret
per repo. That single Terraform-managed secret already covers any repo
under this GitHub account, present or future.

So onboarding a new self-service app repo is exactly one change here: add
an `Application` manifest under `gitops/dev/apps/` and `gitops/prod/apps/`
pointing at that repo's own deploy overlays (see
[gitops/dev/apps/template-test-1.yaml](gitops/dev/apps/template-test-1.yaml)
for the pattern). No Terraform changes, no new secret, no coordination
with the platform team beyond that one file. The app team's repo owns
everything else -- its own CI, its own semantic-release, its own
dev-to-prod promotion -- entirely independently.

New app teams start from
[local-platform-lab-app-template](https://github.com/chliddle/local-platform-lab-app-template)
(click "Use this template" on GitHub) -- a one-time `template-init`
workflow renames everything (Go module path, app/Kubernetes-object name,
container image) to match the new repo automatically, so nothing but the
one `Application` manifest above ever needs manual configuration. See
[template-test-1](https://github.com/chliddle/template-test-1) for what a
generated app repo looks like, including its own release pipeline.

## Repository layout

```
terraform/modules/        Reusable Terraform modules (kind-cluster)
terraform/environments/   Per-environment root modules (dev, prod)
platform/argocd/          Argo CD Helm values + root app-of-apps Application, per environment
gitops/dev/, gitops/prod/ Argo CD Application manifests -- one per onboarded app, pointing at that app's own repo
scripts/                  Bootstrap automation
.github/workflows/        Terraform validate, GitOps manifest validate
```
