#!/usr/bin/env python3
"""Print the pinned image digest from a Kustomize overlay's images: stanza.

Usage: read_image_digest.py <kustomization.yaml path> <image name>
"""
import sys

import yaml


def main():
    path, image_name = sys.argv[1], sys.argv[2]

    with open(path) as f:
        doc = yaml.safe_load(f)

    for entry in doc.get("images", []):
        if entry.get("name") == image_name:
            print(entry["digest"])
            return

    sys.exit(f"no images entry for {image_name!r} in {path}")


if __name__ == "__main__":
    main()
