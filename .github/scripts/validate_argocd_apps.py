#!/usr/bin/env python3
"""Sanity-check Argo CD Application manifests without a live cluster.

CI has no cluster to ask for a real dry-run against the Application CRD, so
this just checks the YAML parses and has the fields Argo CD requires. Full
schema validation happens against the real cluster: Argo CD itself refuses
to sync an invalid Application.
"""
import glob
import subprocess
import sys

import yaml

REQUIRED_FIELDS = ["apiVersion", "kind", "metadata", "spec"]


def check_doc(path, doc, expected_kind="Application"):
    # spec is only required for the Application docs this script normally
    # checks -- the bootstrap chart's rendered Secret has no spec field at
    # all (it's stringData), which is valid Kubernetes, just not an
    # Application.
    required = REQUIRED_FIELDS if expected_kind != "Secret" else REQUIRED_FIELDS[:-1]
    missing = [field for field in required if field not in doc]
    if missing:
        sys.exit(f"{path}: missing required field(s) {missing}")
    if expected_kind and doc["kind"] != expected_kind:
        sys.exit(f"{path}: expected kind {expected_kind}, got {doc['kind']}")


def main():
    # platform/argocd/bootstrap-chart's templates carry Go template `{{ }}`
    # syntax -- not valid YAML on their own (confirmed live: a bare
    # yaml.safe_load fails on them) -- so they're rendered via `helm
    # template` first, once per environment shape, same as Terraform's own
    # helm_release.argocd_bootstrap does at apply time. Unlike every other
    # file this script checks, this chart's rendered output is a MIX of
    # kinds (one Secret, two Applications) -- check structural validity
    # for all of them, but only enforce kind==Application on the two that
    # actually are.
    for environment in ["dev", "prod"]:
        rendered = subprocess.run(
            [
                "helm",
                "template",
                "platform/argocd/bootstrap-chart",
                "--set",
                f"environment={environment}",
                "--set",
                "githubUsername=ci-placeholder",
                "--set",
                "githubToken=ci-placeholder",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        label = f"platform/argocd/bootstrap-chart (environment={environment})"
        kinds_seen = []
        for doc in yaml.safe_load_all(rendered):
            if doc is None:
                continue
            check_doc(label, doc, expected_kind=doc.get("kind"))
            kinds_seen.append(doc["kind"])
        if sorted(kinds_seen) != ["Application", "Application", "Secret"]:
            sys.exit(f"{label}: expected [Application, Application, Secret], got {sorted(kinds_seen)}")
        print(f"{label}: OK")

    files = (
        sorted(glob.glob("gitops/dev/apps/*.yaml"))
        + sorted(glob.glob("gitops/prod/apps/*.yaml"))
        + sorted(glob.glob("gitops/dev/platform/*.yaml"))
        + sorted(glob.glob("gitops/prod/platform/*.yaml"))
        + sorted(glob.glob("platform/gitops-platform-apps/*.yaml"))
    )

    for path in files:
        with open(path) as f:
            doc = yaml.safe_load(f)

        check_doc(path, doc)
        print(f"{path}: OK")


if __name__ == "__main__":
    main()
