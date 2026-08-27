#!/usr/bin/env python3
"""Prepare an auditable legacy-SPF staging tree from canonical Einstoff source."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys


MAPPING_VERSION = 4
SOURCE_NORMALIZATION = "lf-v1"
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
IDENTIFIER_PATTERN = re.compile(rb"[A-Za-z$][A-Za-z0-9$`]*")
LOADER_PATTERN = re.compile(
    rb'\s*PackageInitialize\s*\[\s*"([A-Za-z$][A-Za-z0-9$`]*`)"\s*\]\s*\Z'
)


class CompatibilityError(RuntimeError):
    """Raised when canonical source cannot be lowered safely."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def symbol_start_byte(value: int) -> bool:
    return (
        ord("A") <= value <= ord("Z")
        or ord("a") <= value <= ord("z")
        or value == ord("$")
    )


def symbol_continue_byte(value: int) -> bool:
    return (
        symbol_start_byte(value)
        or ord("0") <= value <= ord("9")
        or value == ord("`")
    )


def identifier_end(data: bytes, start: int) -> int:
    end = start
    while end < len(data) and symbol_continue_byte(data[end]):
        end += 1
    return end


def complete_ascii_identifier(data: bytes, start: int, end: int) -> bool:
    """Reject an ASCII suffix that may belong to a larger WL identifier."""

    def may_continue_identifier(value: int) -> bool:
        return (
            symbol_start_byte(value)
            or value == ord("`")
            or value >= 0x80
            or value in b"\\_"
        )

    follows_bom = start == 3 and data.startswith(b"\xef\xbb\xbf")
    if start and not follows_bom and (
        may_continue_identifier(data[start - 1]) or data[start - 1] == ord("]")
    ):
        return False
    return end >= len(data) or not may_continue_identifier(data[end])


def starts_in_column_one(data: bytes, start: int) -> bool:
    if start == 3 and data.startswith(b"\xef\xbb\xbf"):
        return True
    return start == 0 or data[start - 1] in b"\r\n"


def call_occupies_expression(data: bytes, call_end: int) -> bool:
    cursor = call_end
    while cursor < len(data) and data[cursor] in b" \t":
        cursor += 1
    return cursor >= len(data) or data[cursor] in b"\r\n"


def followed_by_call(data: bytes, identifier_end_index: int) -> bool:
    cursor = identifier_end_index
    while cursor < len(data) and data[cursor] in b" \t\r\n":
        cursor += 1
    return cursor < len(data) and data[cursor] == ord("[")


def canonical_source_bytes(data: bytes) -> bytes:
    """Normalize text-file line endings before hashing and transformation."""

    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def directive_call(data: bytes, identifier_end_index: int, relative_path: str) -> tuple[int, bytes]:
    cursor = identifier_end_index
    while cursor < len(data) and data[cursor] in b" \t\r\n":
        cursor += 1
    if cursor >= len(data) or data[cursor] != ord("["):
        raise CompatibilityError(f"{relative_path}: SPF directive is not followed by a call")

    argument_start = cursor + 1
    depth = 1
    index = argument_start
    comment_depth = 0
    in_string = False
    while index < len(data):
        if in_string:
            current = data[index]
            index += 1
            if current == ord("\\") and index < len(data):
                index += 1
            elif current == ord('"'):
                in_string = False
            continue
        if comment_depth:
            if data.startswith(b"(*", index):
                comment_depth += 1
                index += 2
            elif data.startswith(b"*)", index):
                comment_depth -= 1
                index += 2
            else:
                index += 1
            continue
        if data.startswith(b"(*", index):
            comment_depth = 1
            index += 2
            continue
        if data[index] == ord('"'):
            in_string = True
            index += 1
            continue
        if data[index] == ord("["):
            depth += 1
        elif data[index] == ord("]"):
            depth -= 1
            if depth == 0:
                return index + 1, data[argument_start:index]
        index += 1
    raise CompatibilityError(f"{relative_path}: unterminated SPF directive call")


def list_symbols(argument: bytes, relative_path: str) -> list[bytes] | None:
    stripped = argument.strip()
    if not (stripped.startswith(b"{") and stripped.endswith(b"}")):
        return None
    body = stripped[1:-1].strip()
    if not body:
        raise CompatibilityError(f"{relative_path}: empty SPF declaration list")
    symbols = [candidate.strip() for candidate in body.split(b",")]
    if any(IDENTIFIER_PATTERN.fullmatch(symbol) is None for symbol in symbols):
        raise CompatibilityError(
            f"{relative_path}: legacy SPF lowering accepts only symbol names in declaration lists"
        )
    return symbols


def lower_wl_source(
    data: bytes,
    relative_path: str,
    *,
    reject_legacy: bool = True,
) -> tuple[bytes, Counter[str], Counter[str]]:
    """Lower recognized standalone top-level SPF declarations."""

    output = bytearray()
    counts: Counter[str] = Counter()
    emitted: Counter[str] = Counter()
    index = 0
    comment_depth = 0
    in_string = False
    delimiter_depth = 0
    top_level_boundary = True
    if data.startswith(b"\xef\xbb\xbf"):
        output.extend(b"\xef\xbb\xbf")
        index = 3

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
            if delimiter_depth == 0:
                top_level_boundary = False
            in_string = True
            index += 1
            continue

        if symbol_start_byte(data[index]):
            end = identifier_end(data, index)
            identifier = data[index:end]
            complete_identifier = complete_ascii_identifier(data, index, end)
            is_declaration = (
                complete_identifier
                and starts_in_column_one(data, index)
                and delimiter_depth == 0
                and top_level_boundary
            )
            replacement = MAPPINGS.get(identifier) if is_declaration else None
            if replacement is not None:
                counts[identifier.decode("ascii")] += 1
                call_end, argument = directive_call(data, end, relative_path)
                if not call_occupies_expression(data, call_end):
                    raise CompatibilityError(
                        f"{relative_path}: SPF declarations must occupy a complete "
                        "physical expression"
                    )
                if identifier in (b"PackageExported", b"PackageScoped"):
                    symbols = list_symbols(argument, relative_path)
                    if symbols is not None:
                        output.extend(
                            b"\n".join(
                                replacement + b"[" + symbol + b"]" for symbol in symbols
                            )
                        )
                        emitted[replacement.decode("ascii")] += len(symbols)
                    elif IDENTIFIER_PATTERN.fullmatch(argument.strip()) is None:
                        raise CompatibilityError(
                            f"{relative_path}: legacy SPF lowering accepts only "
                            "symbol names in declarations"
                        )
                    else:
                        output.extend(replacement + data[end:call_end])
                        emitted[replacement.decode("ascii")] += 1
                elif identifier == b"PackageInitialize":
                    output.extend(replacement + data[end:call_end])
                    emitted[replacement.decode("ascii")] += 1
                index = call_end
                top_level_boundary = True
                continue
            else:
                if complete_identifier and identifier in MAPPINGS:
                    raise CompatibilityError(
                        f"{relative_path}: SPF declarations must be standalone "
                        "top-level expressions"
                    )
                if complete_identifier and identifier in LEGACY_NAMES and reject_legacy:
                    raise CompatibilityError(
                        f"{relative_path}: canonical source contains legacy SPF identifier "
                        f"{identifier.decode('ascii')}"
                    )
                if (
                    reject_legacy
                    and complete_identifier
                    and identifier.startswith(b"Package")
                    and followed_by_call(data, end)
                ):
                    raise CompatibilityError(
                        f"{relative_path}: unsupported or ambiguous Package* call "
                        f"{identifier.decode('ascii', errors='replace')}"
                    )
                output.extend(identifier)
            if delimiter_depth == 0:
                top_level_boundary = False
            index = end
            continue

        current = data[index]
        output.append(current)
        if current in b"[({":
            if delimiter_depth == 0:
                top_level_boundary = False
            delimiter_depth += 1
        elif current in b"])}":
            if delimiter_depth:
                delimiter_depth -= 1
            else:
                top_level_boundary = False
        elif current == ord(";") and delimiter_depth == 0:
            top_level_boundary = True
        elif current not in b" \t\r\n":
            if delimiter_depth == 0:
                top_level_boundary = False
        index += 1

    if in_string:
        raise CompatibilityError(f"{relative_path}: unterminated WL string")
    if comment_depth:
        raise CompatibilityError(f"{relative_path}: unterminated WL comment")
    return bytes(output), counts, emitted


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
    if source == output or source in output.parents or output in source.parents:
        raise CompatibilityError("source and output roots must not overlap")

    copy_required_source(source, output)
    kernel_root = output / "Gravifer__Einstoff" / "Kernel"
    source_files = sorted(kernel_root.rglob("*.wl"))
    if not source_files:
        raise CompatibilityError("no Kernel/*.wl files were found")

    loader_matches: list[tuple[Path, bytes]] = []
    for file_path in source_files:
        data = canonical_source_bytes(file_path.read_bytes())
        match = LOADER_PATTERN.fullmatch(data.removeprefix(b"\xef\xbb\xbf"))
        if match is not None:
            loader_matches.append((file_path, match.group(1)))
    if len(loader_matches) != 1:
        raise CompatibilityError(
            "canonical source must contain exactly one standalone PackageInitialize loader"
        )
    loader_path, package_context = loader_matches[0]

    changed_files: dict[str, object] = {}
    total_counts: Counter[str] = Counter()
    emitted_counts: Counter[str] = Counter()
    for file_path in source_files:
        relative = file_path.relative_to(output).as_posix()
        before = canonical_source_bytes(file_path.read_bytes())
        after, counts, emitted = lower_wl_source(before, relative)
        if file_path != loader_path:
            package_line = b'Package["' + package_context + b'"]\n'
            if after.startswith(b"\xef\xbb\xbf"):
                after = b"\xef\xbb\xbf" + package_line + after[3:]
            else:
                after = package_line + after
            emitted["Package"] += 1
        if counts:
            file_path.write_bytes(after)
            total_counts.update(counts)
            emitted_counts.update(emitted)
            changed_files[relative] = {
                "beforeSHA256": sha256(before),
                "afterSHA256": sha256(after),
                "replacements": dict(sorted(counts.items())),
            }
        elif after != before:
            file_path.write_bytes(after)
            emitted_counts.update(emitted)
            changed_files[relative] = {
                "beforeSHA256": sha256(before),
                "afterSHA256": sha256(after),
                "replacements": {},
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
        _, remaining, _ = lower_wl_source(lowered, relative, reject_legacy=False)
        if remaining:
            raise CompatibilityError(f"{relative}: public SPF vocabulary remains after lowering")
        payload = lowered.removeprefix(b"\xef\xbb\xbf").lstrip(b" \t\r\n")
        expected_prefix = b'Package["' + package_context + b'"]'
        if not payload.startswith(expected_prefix):
            raise CompatibilityError(f"{relative}: generated fragment has no legacy Package directive")

    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "mappingVersion": MAPPING_VERSION,
        "sourceNormalization": SOURCE_NORMALIZATION,
        "sourceFlavor": "public-spf-v15",
        "targetFlavor": "legacy-spf",
        "probeOnly": False,
        "mappings": {
            source.decode("ascii"): target.decode("ascii")
            for source, target in MAPPINGS.items()
        },
        "replacementTotals": dict(sorted(total_counts.items())),
        "emittedDirectiveTotals": dict(sorted(emitted_counts.items())),
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
