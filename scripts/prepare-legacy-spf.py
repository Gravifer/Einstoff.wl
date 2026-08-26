#!/usr/bin/env python3
"""Prepare an auditable legacy-SPF staging tree from canonical Einstoff source."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import sys


MAPPING_VERSION = 1
MAPPINGS = {
    b"PackageInitialize": b"Package",
    b"PackageExported": b"PackageExport",
    b"PackageScoped": b"PackageScope",
}
LEGACY_NAMES = frozenset(MAPPINGS.values())
REQUIRED_ROOT_ENTRIES = (
    "Gravifer__Einstoff",
    "tests",
    ".python-version",
    "pyproject.toml",
    "uv.lock",
    "README.md",
    "LICENSE",
)
MANIFEST_NAME = "spf-compatibility-manifest.json"


class CompatibilityError(RuntimeError):
    """Raised when canonical source cannot be lowered safely."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def symbol_byte(value: int) -> bool:
    return (
        ord("A") <= value <= ord("Z")
        or ord("a") <= value <= ord("z")
        or ord("0") <= value <= ord("9")
        or value in (ord("$"), ord("`"))
    )


def identifier_end(data: bytes, start: int) -> int:
    end = start
    while end < len(data) and symbol_byte(data[end]):
        end += 1
    return end


def lower_wl_source(
    data: bytes,
    relative_path: str,
    *,
    reject_legacy: bool = True,
) -> tuple[bytes, Counter[str]]:
    """Lower recognized SPF identifiers while preserving every unrelated byte."""

    output = bytearray()
    counts: Counter[str] = Counter()
    index = 0
    comment_depth = 0
    in_string = False

    while index < len(data):
        if in_string:
            current = data[index]
            output.append(current)
            index += 1
            if current == ord("\\") and index < len(data):
                output.append(data[index])
                index += 1
            elif current == ord('"'):
                in_string = False
            continue

        if comment_depth:
            if data.startswith(b"(*", index):
                output.extend(b"(*")
                comment_depth += 1
                index += 2
            elif data.startswith(b"*)", index):
                output.extend(b"*)")
                comment_depth -= 1
                index += 2
            else:
                output.append(data[index])
                index += 1
            continue

        if data.startswith(b"(*", index):
            output.extend(b"(*")
            comment_depth = 1
            index += 2
            continue
        if data[index] == ord('"'):
            output.append(data[index])
            in_string = True
            index += 1
            continue

        if symbol_byte(data[index]):
            end = identifier_end(data, index)
            identifier = data[index:end]
            replacement = MAPPINGS.get(identifier)
            if replacement is not None:
                output.extend(replacement)
                counts[identifier.decode("ascii")] += 1
            else:
                if identifier in LEGACY_NAMES and reject_legacy:
                    raise CompatibilityError(
                        f"{relative_path}: canonical source contains legacy SPF identifier "
                        f"{identifier.decode('ascii')}"
                    )
                if identifier.startswith(b"Package") and identifier not in LEGACY_NAMES:
                    cursor = end
                    while cursor < len(data) and data[cursor] in b" \t\r\n":
                        cursor += 1
                    if cursor < len(data) and data[cursor] == ord("["):
                        raise CompatibilityError(
                            f"{relative_path}: unsupported SPF directive "
                            f"{identifier.decode('ascii', errors='replace')}"
                        )
                output.extend(identifier)
            index = end
            continue

        output.append(data[index])
        index += 1

    if in_string:
        raise CompatibilityError(f"{relative_path}: unterminated WL string")
    if comment_depth:
        raise CompatibilityError(f"{relative_path}: unterminated WL comment")
    return bytes(output), counts


def ensure_plain_tree(path: Path) -> None:
    for candidate in (path, *path.rglob("*")):
        if candidate.is_symlink():
            raise CompatibilityError(f"symbolic links are not accepted in staging input: {candidate}")


def copy_required_source(source: Path, output: Path) -> None:
    missing = [name for name in REQUIRED_ROOT_ENTRIES if not (source / name).exists()]
    if missing:
        raise CompatibilityError("source root is missing required entries: " + ", ".join(missing))

    if output.exists():
        if not output.is_dir():
            raise CompatibilityError(f"output path is not a directory: {output}")
        if any(output.iterdir()):
            raise CompatibilityError(f"output directory is not empty: {output}")
    else:
        output.mkdir(parents=True)

    for name in REQUIRED_ROOT_ENTRIES:
        source_entry = source / name
        ensure_plain_tree(source_entry)
        output_entry = output / name
        if source_entry.is_dir():
            shutil.copytree(source_entry, output_entry, copy_function=shutil.copy2)
        else:
            shutil.copy2(source_entry, output_entry)


def prepare(source: Path, output: Path) -> dict[str, object]:
    source = source.resolve()
    output = output.resolve()
    if source == output:
        raise CompatibilityError("source and output roots must differ")

    copy_required_source(source, output)
    kernel_root = output / "Gravifer__Einstoff" / "Kernel"
    source_files = sorted(kernel_root.rglob("*.wl"))
    if not source_files:
        raise CompatibilityError("no Kernel/*.wl files were found")

    changed_files: dict[str, object] = {}
    total_counts: Counter[str] = Counter()
    for file_path in source_files:
        relative = file_path.relative_to(output).as_posix()
        before = file_path.read_bytes()
        after, counts = lower_wl_source(before, relative)
        if counts:
            file_path.write_bytes(after)
            total_counts.update(counts)
            changed_files[relative] = {
                "beforeSHA256": sha256(before),
                "afterSHA256": sha256(after),
                "replacements": dict(sorted(counts.items())),
            }

    if total_counts["PackageInitialize"] != 1:
        raise CompatibilityError(
            "canonical source must contain exactly one PackageInitialize directive"
        )
    for required in ("PackageExported", "PackageScoped"):
        if total_counts[required] < 1:
            raise CompatibilityError(f"canonical source contains no {required} directive")

    for file_path in source_files:
        relative = file_path.relative_to(output).as_posix()
        lowered = file_path.read_bytes()
        _, remaining = lower_wl_source(lowered, relative, reject_legacy=False)
        if remaining:
            raise CompatibilityError(f"{relative}: public SPF vocabulary remains after lowering")

    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "mappingVersion": MAPPING_VERSION,
        "sourceFlavor": "public-spf-v15",
        "targetFlavor": "legacy-spf",
        "probeOnly": False,
        "mappings": {
            source.decode("ascii"): target.decode("ascii")
            for source, target in MAPPINGS.items()
        },
        "replacementTotals": dict(sorted(total_counts.items())),
        "changedFiles": changed_files,
    }
    manifest_path = output / MANIFEST_NAME
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return manifest


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True, help="canonical repository root")
    parser.add_argument("--output", type=Path, required=True, help="empty staging root")
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        manifest = prepare(options.source, options.output)
    except (CompatibilityError, OSError) as error:
        print(f"SPF compatibility staging failed: {error}", file=sys.stderr)
        return 1

    print(
        "Prepared legacy SPF source: "
        f"{len(manifest['changedFiles'])} files, "
        f"{sum(manifest['replacementTotals'].values())} replacements"
    )
    print(f"SPF_COMPATIBILITY_MANIFEST={(options.output.resolve() / MANIFEST_NAME)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
