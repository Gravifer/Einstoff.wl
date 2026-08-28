# Structured Package Compatibility

Einstoff's checked-in Wolfram source uses the public structured-package-format
(SPF) vocabulary introduced in Wolfram Language 15:

```wl
PackageInitialize
PackageExported
PackageScoped
```

That vocabulary is canonical. It is the form maintainers review and the only form
that should be edited. To prepare for supporting older Wolfram engines without
freezing the source on private names, maintainer release validation and every hosted
build or publication path use a provisional compiler to create a temporary source
tree with the corresponding long-standing package-format names. Direct invocations
of the low-level build scripts remain canonical-source diagnostics.
The transformation has two structural parts:

```text
PackageInitialize loader      -> Package[context] in the retained .wl entry
other Kernel/**/*.wl files    -> same relative path and stem with an .m suffix
PackageExported[{a, b, ...}]  -> one PackageExport declaration per symbol
PackageScoped[{a, b, ...}]    -> one PackageScope declaration per symbol
```

The canonical paclet now declares `"WolframVersion" -> "13.0+"`; the compatibility
build lowers only the structured-package source vocabulary and does not rewrite that
metadata. The Python implementation is
provisional: it remains the production route while it is the smallest deterministic,
unlicensed build dependency, but it may be replaced if Wolfram documents a supported
native migration facility. Any replacement must preserve the same staging,
validation, and provenance contracts.

## Research basis

The implementation was chosen after comparing the public Wolfram 15 format, the
long-standing package scanner described by the community, Wolfram's parsing tools,
and an in-the-wild migration. As of August 2026, this research found no documented
Wolfram helper that emits the legacy format from canonical Wolfram 15 source:

- [Using the Structured Package Format](https://reference.wolfram.com/language/tutorial/UsingTheStructuredPackageFormat.html)
- [`PackageInitialize`](https://reference.wolfram.com/language/ref/PackageInitialize)
- [Backwards compatibility of Structured Package Format](https://mathematica.stackexchange.com/questions/319834/backwards-compatibility-of-structured-package-format)
- [Declaring Package with dependencies in multiple files](https://mathematica.stackexchange.com/questions/176434/declaring-package-with-dependencies-in-multiples-files)
- [What to be aware when using new-style package?](https://mathematica.stackexchange.com/questions/184711/what-to-be-aware-when-using-new-style-package)
- [What are package-context symbols for?](https://mathematica.stackexchange.com/questions/114956/what-are-package-context-symbols-for)
- [IGraph/M's legacy-SPF entry fragment](https://github.com/szhorvat/IGraphM/blob/master/IGraphM/IGraphM.m)
- [OpenVDBLink's legacy-SPF entry fragment](https://github.com/AcademySoftwareFoundation/openvdb/blob/master/openvdb_wolfram/OpenVDBLink/OpenVDBLink.m)
- [WolframResearch/MongoLink's legacy-SPF fragments](https://github.com/WolframResearch/MongoLink/tree/master/MongoLink/Kernel)
- [WolframResearch/QuantumFramework's nested legacy-SPF fragments](https://github.com/WolframResearch/QuantumFramework/tree/main/QuantumFramework/Kernel)
- [WolframResearch/CodeParser](https://github.com/WolframResearch/codeparser)
- [CodeParser documentation](https://reference.wolfram.com/language/CodeParser/guide/CodeParser.html)
- [DiagrammaticComputation's SPF migration](https://github.com/WolframInstitute/DiagrammaticComputation/commit/d68236343b3788ed7e3c793f93c13e48ddfefe20)
- [Wolfram Language 15 launch discussion](https://writings.stephenwolfram.com/2026/06/launching-version-15-of-wolfram-language-mathematica-built-in-useful-ai-lots-of-new-core-functionality/)

The exact compatibility question is intentionally left to the existing Mathematica
Stack Exchange discussion rather than duplicated. A future supported converter can
supersede this provisional compiler; undocumented private APIs are not an acceptable
production dependency.

## Transformer contract

[`scripts/prepare-legacy-spf.py`](../scripts/prepare-legacy-spf.py) is a provisional,
dependency-free byte-oriented compiler. Run it with `uv` and the Python version
pinned by `.python-version`; production CI additionally pins the `uv` binary itself.

Its accepted declaration grammar is deliberately narrower than general Wolfram
Language syntax. `PackageInitialize`, `PackageExported`, and `PackageScoped` must
begin in column one, occur at top level, and occupy the complete physical expression;
the declaration call may span lines, but its closing bracket must be followed only by
horizontal whitespace and then a blank physical line or end of file. Indented,
comment-prefixed, chained, postfixed, nested, assigned, qualified, escaped, embedded,
or otherwise ambiguous occurrences are rejected. Outside strings and comments, any
other identifier containing `Package` is rejected wholesale. Canonical Einstoff source
follows this convention.

This restriction is a trust boundary, not an attempt to specify Wolfram parsing. The
compatibility layer stays small, fail-closed, and straightforward to audit while the
Python route remains provisional. Einstoff intentionally does not reproduce the
vendor's undocumented package scanner or build a replacement Wolfram parser; a future
documented Wolfram migration facility should replace this compiler instead.

It:

- copies the paclet, tests, and locked Python-environment inputs into an empty
  staging directory;
- reads the context from the one standalone `PackageInitialize` loader;
- retains that loader as the only generated `.wl` fragment and emits every other
  `Kernel/**/*.wl` implementation fragment at the same relative path with an `.m`
  suffix;
- adds the legacy `Package[context]` directive to every generated fragment;
- rewrites complete declaration identifiers outside WL strings and arbitrarily
  nested comments, expanding list-valued declarations into the scalar form accepted
  by the legacy scanner;
- preserves relative directories, filename stems, and every unrelated source byte
  after canonical LF line-ending normalization;
- rejects legacy names in canonical source, unrecognized `Package*` directives,
  pre-existing canonical `Kernel/**/*.m` fragments case-insensitively, mixed-case
  SPF suffixes, portable case/Unicode-equivalent path collisions, generated-path collisions,
  malformed strings or comments, symbolic links or Windows directory junctions,
  missing source roots, and a nonempty destination;
- verifies that all expected public directives were found and none survived; and
- writes deterministic `spf-compatibility-manifest.json` provenance.

The manifest schema records the mapping version, source and target dialects, the
production/probe marker, source replacement counts, emitted legacy directive counts,
each canonical source path and generated target path, and each changed file's pre-
and post-transformation SHA-256. It
intentionally contains no absolute paths, timestamps, host details, or other
nondeterministic data. The compiler normalizes canonical `Kernel/**/*.wl` staging
bytes to LF before hashing or rewriting, and Git also pins their checkout policy to LF
in `.gitattributes`. Existing Windows clones therefore produce the same source hashes
without requiring a forced checkout.

The distinction is essential. A Wolfram 14.1 diagnostic established that the legacy
scanner accepts flat and nested `.m` fragments, with symbol- or string-valued
declarations, but silently ignores non-entry `.wl` fragments. A `.wl` entry with
nested `.m` fragments succeeds. This matches the community record and the layouts of
IGraph/M, OpenVDBLink, MongoLink, and QuantumFramework. Every generated fragment must
still carry the `Package` directive, and list-valued public declarations are expanded
to the legacy scalar form. Community documentation of this formerly undocumented
format describes the same static scan and per-fragment contract; it also records
behavior changes before Wolfram Language 11. The one-off diagnostic workflow was
removed after [the v14.1 evidence was captured](https://github.com/Gravifer/Einstoff.wl/actions/runs/33154733195),
rather than retained as a paid maintenance interface.
See [Declaring Package with dependencies in multiple files](https://mathematica.stackexchange.com/questions/176434/declaring-package-with-dependencies-in-multiples-files)
and [What to be aware when using new-style package?](https://mathematica.stackexchange.com/questions/184711/what-to-be-aware-when-using-new-style-package).
Einstoff targets no version below 13, but its v15 acceptance suite still verifies the
generated dialect before historical-engine testing begins.

From PowerShell, inspect a generated tree with:

```powershell
$pythonVersion = (Get-Content .python-version -Raw).Trim()
$destination = Join-Path $env:TEMP 'einstoff-spf-inspection'
New-Item -ItemType Directory -Path $destination
$arguments = @(
    'run', '--no-project', '--managed-python', '--python', $pythonVersion,
    'python', 'scripts/prepare-legacy-spf.py',
    '--source', (Get-Location).Path,
    '--output', $destination
)
uv @arguments
```

Choose a nonexistent or empty destination. Remove that inspection directory when
finished. The automated transformer tests use the same pinned runtime:

```powershell
$pythonVersion = (Get-Content .python-version -Raw).Trim()
uv run --no-project --managed-python --python $pythonVersion python scripts/test_spf_compatibility.py
```

For an actual local release candidate, use the wrapper instead of manually passing
the staging path between commands:

```powershell
pwsh -NoProfile -File scripts/validate-release.ps1 -ExpectedTag vX.Y.Z
```

Add `-Python` when cross-validation is required. The wrapper regenerates native
documentation in canonical source, creates a temporary compatibility tree, validates
and builds from that tree, tests the built archive, copies the archive and manifest
to `build/`, and removes the temporary tree.

## CI, release, and submission flow

The local Docker action is the sole production staging boundary:

```text
canonical tagged checkout
  -> pinned uv + prepare-legacy-spf.py
  -> generated source root
  -> source validation / PacletCICD / Wolfram tests
  -> generated .paclet + compatibility manifest
```

Ordinary trusted CI runs the transformer tests without a Wolfram entitlement, then
runs only the change-selected licensed checks against one generated tree. It does not
repeat the paid suite against both SPF dialects.

Release validation builds and fully tests the generated source. The GitHub Release
contains the paclet, checksum, release manifest, and compatibility manifest. The
release manifest records `spfCompatibilityManifestSHA256` and
`spfCompatibilityMappingVersion` alongside the tagged source commit and archive
digest.

Stable Paclet Repository publication checks out the same tagged commit and regenerates
the compatibility tree. The guarded publication action refuses to submit unless the
new manifest digest exactly matches release validation. PacletCICD therefore checks,
builds, and submits from one generated source flavor even though its public
`SubmitPaclet` API rebuilds the repository archive itself.

The manifest's `probeOnly` field is `false` in production. The manual
`historical-wolfram.yml` workflow creates a separate compatibility tree, validates and
retains the canonical `"WolframVersion" -> "13.0+"` declaration, changes the marker to
`true`, and records the unchanged `PacletInfo.wl` hash. All production validation and
submission paths reject such a tree.

## Historical-engine validation

Historical validation is deliberately manual, non-publishing, and independent of the
declared minimum version. Image and mount preflighting is unlicensed; engine builds
and tests are paid. A branch dispatch with paid confirmation left false runs only the
preflight and never receives the entitlement. Ordinary paid builds and tests require a
`main` dispatch. To commission a workflow or compatibility-build change before merge,
the repository owner may set both paid confirmations on a review branch for any selected
gate. This narrow exception proves the complete build, archive-discovery, engine-runner,
report-copy, and report-validation sequence; it deliberately places that branch's
workflow tooling in the entitlement trust boundary. Both modes accept a separate candidate commit or branch
that must resolve to an exact first-parent snapshot of `main`; intermediate
commits retained inside merged branch histories are rejected. The candidate package
and tests execute inside licensed kernels and are therefore also explicitly inside
the entitlement trust boundary. The remaining input selects the oldest requested
gate:

```text
15.0 -> 15.0
14.1 -> 15.0, 14.1
13.2 -> 15.0, 14.1, 13.2
13.0 -> 15.0, 14.1, 13.2, 13.0
```

The selected official Wolfram Engine images are fixed by their complete Linux/amd64
manifest digests. One probe archive is built under Wolfram 15 and then installed and
tested unchanged at every gate, sequentially, stopping at the first failure. The old
engines run only `scripts/historical-engine-runner.wls`: it checks the actual engine
version, installs the archive, requires the one-symbol public surface, runs
representative operator smokes, and executes every non-Python `.wlt` test with an
expected-count check. It does not invoke Resource Functions, Python cross-validation,
PacletCICD, documentation generation, or publication.

The workflow has `contents: read`, globally serializes runs, and exposes only
`WOLFRAMSCRIPT_ENTITLEMENTID`, only to the build-and-test step. Image pulls, trusted
tooling checkout, candidate verification, probe preparation, container-mount
preflighting, and artifact upload are unlicensed. Before any kernel starts, each
selected image must prove that the probe source is read-only and that only its
dedicated `/output` build mount or report output is writable. Build output is not
nested beneath the read-only probe mount. The general report directory, its logs, and
its checksums are never container-writable. A run uploads the probe archive,
manifest, checksum, build log, and one
JSON/log pair per attempted engine for 14 days. A missing JSON report together with a
container failure identifies licensing or harness startup failure. A zero exit status
is insufficient: the host validates each JSON report's engine version, archive hash,
public surface, smoke count, and complete passing test counts before advancing. A JSON
`TestFailure` identifies package behavior or test-count failure.

Select the oldest intended gate once the workflow and compatibility build have passed
unlicensed review. The workflow runs every gate in order and stops at the first failure,
so selecting `13.0` exercises `15.0`, `14.1`, `13.2`, and `13.0` without repeated paid
dispatches. [Historical run 33157241265](https://github.com/Gravifer/Einstoff.wl/actions/runs/33157241265)
validated one generated archive unchanged on all four engines. Every gate exposed only
`Einstoff`, passed nine representative smoke tests, and passed all 558 Wolfram tests.
That evidence establishes the current `13.0+` floor; future compatibility-sensitive
changes should rerun the ladder before making a new release.

## Removing the layer after pre-v15 support ends

Canonical `.wl` files already use the desired public vocabulary. Removing
compatibility support therefore requires no reverse source rewrite. In one focused
change:

1. Delete `scripts/prepare-legacy-spf.py` and
   `scripts/test_spf_compatibility.py`.
2. Remove compatibility classification and assertions from
   `scripts/classify_ci_changes.py`, `scripts/test_ci_change_classifier.py`,
   `scripts/validate-release-contract.py`, and
   `scripts/test-paclet-publication-action.sh`.
3. Remove staging, digest comparison, copied-output handling, and compatibility
   outputs from `.github/actions/paclet-ci/main.sh` and `action.yml`.
4. Remove the transformer test step and compatibility artifact from
   `.github/workflows/paclet-ci.yml`.
5. Remove the compatibility asset, validation outputs, release-manifest fields,
   publication checks, and Wolfram-submission digest input from
   `.github/workflows/release.yml`.
6. Restore `scripts/build-paclet.wls` and `scripts/validate-release.ps1` to build
   directly from canonical source if `EINSTOFF_SOURCE_ROOT` is no longer needed by
   any other workflow. Review the same environment-root support in
   `scripts/paclet-cicd.wls`, `scripts/run-tests.wls`, and
   `scripts/validate-paclet-source.wls` rather than deleting shared functionality
   blindly.
7. Delete `.github/workflows/historical-wolfram.yml`,
   `scripts/historical-engine-matrix.sh`, `scripts/historical-engine-runner.wls`,
   `scripts/prepare-historical-probe.py`, `scripts/test_historical_probe.py`,
   `scripts/validate-historical-report.py`, `scripts/test_historical_report.py`, and
   their classifier and contract assertions.
8. Remove `spf-compatibility-manifest.json`,
   `spfCompatibilityManifestSHA256`, `spfCompatibilityMappingVersion`, and
   `EINSTOFF_RELEASE_SPF_MANIFEST_SHA256` from artifacts, provenance, and recovery
   documentation.
9. Update this document, `CONTRIBUTING.md`, and the README requirements, then run the
   ordinary and release-contract suites once against direct canonical builds.

Do not remove the layer merely because a newer development machine accepts canonical
source. Remove it only when the declared support policy no longer includes any engine
that needs the legacy SPF names.
