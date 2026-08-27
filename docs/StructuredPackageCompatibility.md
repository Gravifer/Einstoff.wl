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
freezing the source on private names, every artifact-producing path uses a
provisional compiler to create a temporary source tree with the corresponding
long-standing package-format names.
The transformation has two structural parts:

```text
one PackageInitialize loader -> Package[context] in every Kernel/*.wl fragment
PackageExported[{a, b, ...}]  -> one PackageExport declaration per symbol
PackageScoped[{a, b, ...}]    -> one PackageScope declaration per symbol
```

This compatibility build does not yet lower the paclet's declared
`"WolframVersion" -> "15.0+"`. Historical-engine testing and any eventual minimum
version change are separate, reviewed stages. The Python implementation is
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
dependency-free byte-oriented compiler. Run it through the repository's pinned
`uv` and `.python-version`, not through an independently provisioned Python runtime.
It:

- copies the paclet, tests, and locked Python-environment inputs into an empty
  staging directory;
- reads the context from the one standalone `PackageInitialize` loader;
- adds the legacy `Package[context]` directive to every nested `Kernel/*.wl`
  fragment;
- rewrites complete declaration identifiers outside WL strings and arbitrarily
  nested comments, expanding list-valued declarations into the scalar form accepted
  by the legacy scanner;
- preserves filenames and every unrelated source byte;
- rejects legacy names in canonical source, unrecognized `Package*` directives,
  malformed strings or comments, symlinks, missing source roots, and a nonempty
  destination;
- verifies that all expected public directives were found and none survived; and
- writes deterministic `spf-compatibility-manifest.json` provenance.

The manifest schema records the mapping version, source and target dialects, the
production/probe marker, source replacement counts, emitted legacy directive counts,
changed files, and each changed file's pre- and post-transformation SHA-256. It
intentionally contains no absolute paths, timestamps, host details, or other
nondeterministic data. Git pins canonical `Kernel/**/*.wl` checkout bytes to LF in
`.gitattributes`, keeping those source hashes stable across developer and CI
platforms.

The distinction is essential. The legacy `Package` format automatically scans and
loads all marked fragments, including nested `.wl` files, but every fragment must
carry the `Package` directive and its export/scope declarations are scalar. Community
documentation of this formerly undocumented format describes the same static scan and
per-fragment contract; it also records behavior changes before Wolfram Language 11.
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

The manifest's `probeOnly` field is `false` in production. A future historical-engine
workflow may place a lower-version metadata overlay in an explicitly probe-only tree;
all production validation and submission paths reject such a tree.

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
7. Delete any historical-engine workflow, legacy runner, probe overlay, reports, and
   their tests introduced by the later validation stage.
8. Remove `spf-compatibility-manifest.json`,
   `spfCompatibilityManifestSHA256`, `spfCompatibilityMappingVersion`, and
   `EINSTOFF_RELEASE_SPF_MANIFEST_SHA256` from artifacts, provenance, and recovery
   documentation.
9. Update this document, `CONTRIBUTING.md`, and the README requirements, then run the
   ordinary and release-contract suites once against direct canonical builds.

Do not remove the layer merely because a newer development machine accepts canonical
source. Remove it only when the declared support policy no longer includes any engine
that needs the legacy SPF names.
