#!/usr/bin/env python3
"""Sanity-check Argo CD Application manifests without a live cluster.

CI has no cluster to ask for a real dry-run against the Application CRD, so
this just checks the YAML parses and has the fields Argo CD requires. Full
schema validation happens against the real cluster: Argo CD itself refuses
to sync an invalid Application.
"""
import glob
import sys

import yaml

REQUIRED_FIELDS = ["apiVersion", "kind", "metadata", "spec"]


def main():
    files = (
        [
            "platform/argocd/root-app.yaml",
            "platform/argocd/root-app-prod.yaml",
            "platform/argocd/root-platform-dev.yaml",
            "platform/argocd/root-platform-prod.yaml",
            "platform/argocd/root-platform-management.yaml",
        ]
        + sorted(glob.glob("gitops/dev/apps/*.yaml"))
        + sorted(glob.glob("gitops/prod/apps/*.yaml"))
        + sorted(glob.glob("gitops/dev/platform/*.yaml"))
        + sorted(glob.glob("gitops/prod/platform/*.yaml"))
        + sorted(glob.glob("gitops/management/platform/*.yaml"))
    )

    for path in files:
        with open(path) as f:
            doc = yaml.safe_load(f)

        missing = [field for field in REQUIRED_FIELDS if field not in doc]
        if missing:
            sys.exit(f"{path}: missing required field(s) {missing}")
        if doc["kind"] != "Application":
            sys.exit(f"{path}: expected kind Application, got {doc['kind']}")

        print(f"{path}: OK")


if __name__ == "__main__":
    main()
