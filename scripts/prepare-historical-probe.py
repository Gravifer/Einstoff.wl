#!/usr/bin/env python3
"""Prepare a non-publishable legacy-SPF tree for historical-engine testing."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


COMPATIBILITY_SCRIPT = Path(__file__).with_name("prepare-legacy-spf.py")
SPEC = importlib.util.spec_from_file_location("prepare_legacy_spf", COMPATIBILITY_SCRIPT)
assert SPEC is not None and SPEC.loader is not None
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)

REQUIRED_VERSION = "13.0+"
REQUIRED_FIELD = b'"WolframVersion" -> "13.0+"'


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def prepare_probe(source: Path, output: Path) -> dict[str, object]:
    manifest = compat.prepare(source.resolve(), output.resolve())
    if manifest.get("probeOnly") is not False:
        raise compat.CompatibilityError(
            "historical probe input must be a production compatibility tree"
        )

    paclet_info = output.resolve() / "Gravifer__Einstoff" / "PacletInfo.wl"
    before = paclet_info.read_bytes()
    if before.count(REQUIRED_FIELD) != 1:
        raise compat.CompatibilityError(
            "historical probe requires exactly one canonical 13.0+ WolframVersion field"
        )

    manifest["probeOnly"] = True
    manifest["probeMetadata"] = {
        "wolframVersion": REQUIRED_VERSION,
        "pacletInfoSHA256": sha256(before),
    }
    manifest_path = output.resolve() / compat.MANIFEST_NAME
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return manifest


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        manifest = prepare_probe(options.source, options.output)
    except (compat.CompatibilityError, OSError, ValueError) as error:
        print(f"Historical probe staging failed: {error}", file=sys.stderr)
        return 1

    metadata = manifest["probeMetadata"]
    print(
        "Prepared historical-engine probe: "
        f"WolframVersion {metadata['wolframVersion']} (unchanged)"
    )
    print(
        "HISTORICAL_PROBE_MANIFEST="
        f"{(options.output.resolve() / compat.MANIFEST_NAME)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
