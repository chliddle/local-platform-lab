#!/usr/bin/env python3
"""Print the metadata.name of every Argo CD Application manifest under
gitops/<env>/apps/, one per line. Used by the integration test to
discover which apps are currently onboarded without hardcoding names.

Usage: app_names.py <env>
"""
import glob
import sys

import yaml


def main():
    env = sys.argv[1]
    for path in sorted(glob.glob(f"gitops/{env}/apps/*.yaml")):
        with open(path) as f:
            doc = yaml.safe_load(f)
        print(doc["metadata"]["name"])


if __name__ == "__main__":
    main()
