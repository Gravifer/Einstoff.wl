# Einstoff

Einstoff is an experimental Wolfram Language package for writing tensor and
array-axis transformations as Wolfram expressions instead of string mini-languages.
It uses native pattern objects such as `a_`, `_`, `__`, `___`, `CircleTimes` (`⊗`),
`CirclePlus` (`⊕`), `Slot`, `Highlighted`, and `Framed` as surface notation. A held
description is compiled into a private staged IR; native patterns are not the semantic
AST after capture.

The first planned release is the `Gravifer/Einstoff` paclet. After that paclet is
publicly installable, a thin `ResourceFunction["Einstoff"]` facade can install, load,
and forward to it.

## What It Does

Inspired by [einx](https://github.com/fferflo/einx),
Einstoff covers a growing subset of ein-style array notation:

- `Einstoff[ArrayReshape]` for bijective rearrange/reshape operations.
- `Einstoff["Massage"]` for the permissive single-tensor structural engine, including
  repetition, direct sums, and pairwise within-tensor contraction.
- `Einstoff["ArrayContract"]` for the no-repetition reshape-and-contract subset.
- `Einstoff[ArrayReduce][f]` for targeted reductions.
- `Einstoff[Operate][f]` for shape-preserving targeted block operations.
- `Einstoff[Map][f]` for general targeted block maps.
- `Einstoff[Dot]` and `Einstoff[Inner][mul, add]` for cross-tensor contractions.
- `Einstoff[Join]` and `Einstoff[Split]` for structural direct sums.
- `Einstoff["einsum"]` for the implemented pairwise einsum-style subset.

The primary user reference is [`docs/Einstoff.en.md`](docs/Einstoff.en.md). The
developer and agent-facing design notes live under [`.agents/`](.agents/).

## Example

```mathematica
PacletDirectoryLoad[Directory[]];
Needs["Gravifer`Einstoff`"];

x = ArrayReshape[Range[2*3*4], {2, 3, 4}];

Einstoff[ArrayReshape][
  {{a_, b_, c_}} :> {{c, a, b}},
  {x}
]
```

The shape description above says: infer axes `a`, `b`, and `c` from the input, then
return the same data with axes ordered as `c, a, b`.

Targeted axes use Wolfram wrappers rather than einx's bracket syntax:

```mathematica
Einstoff[ArrayReduce][Total][
  {{a_, Slot["b"]}} :> {{a}},
  {ArrayReshape[Range[6], {2, 3}]}
]
```

## Repository Layout

- `Gravifer__Einstoff/` is the publisher-qualified paclet source directory.
- `docs/Einstoff.en.md` is the public reference documentation draft.
- `tests/*.wlt` are the source unit tests.
- `tests/python/*.wlt` are opt-in cross-validation tests against `einx`, `einops`, and
  NumPy where applicable.
- `tests/EinstoffTestSuite.nb` is generated from the `.wlt` tests for maintainer use.
- `.agents/agents.md`, `.agents/SPEC.md`, and `.agents/plans/` are developer and coding
  agent materials.

## Getting Started

Have your own Wolfram Language system ready. The `0.2.0-alpha.1` prerelease targets
Wolfram Language 15.0 or newer, and the test suite runs through `wolframscript`.

Python is used only for the optional cross-validation harness:

```powershell
uv sync
```

Run the default Wolfram-only suite from the repository root:

```powershell
wolframscript -script scripts/run-tests.wls -q
```

Run optional Python cross-validation:

```powershell
wolframscript -script scripts/run-tests.wls python -q
```

For release validation, regenerate the native documentation, validate the source
paclet, build an archive, and rerun the suite against the extracted artifact:

```powershell
pwsh -NoProfile -File scripts/validate-release.ps1 -ExpectedTag v0.2.0-alpha.1
```

Add `-Python` to include the optional Python cross-validation suite. The release
script writes only to the ignored `build/` directory and temporary extraction space;
it does not install the candidate into the normal user paclet repository.

For Paclet Repository preparation, install the checksum-verified PacletCICD version
pinned by this repository, then validate the definition notebook or build through
the same tooling used by CI:

```powershell
wolframscript -script scripts/install-paclet-cicd.wls
wolframscript -script scripts/paclet-cicd.wls check
wolframscript -script scripts/paclet-cicd.wls build
```

If the Wolfram kernel cannot download the release directly, download the configured
archive separately and pass its path to `scripts/install-paclet-cicd.wls`; the same
SHA-256 verification is applied before installation. The installer replaces an
existing copy of the pinned version only after the replacement archive is verified.

Run `check` before `build`; the build command does not repeat the relatively costly
definition-notebook inspection.

The GitHub workflow checks and builds only; it never submits a paclet. Its Wolfram
Engine image and PacletCICD archive are pinned by digest. Licensed jobs run only for
trusted branch events, same-repository pull requests, and manual dispatches; fork and
Dependabot pull requests skip the licensed job. Hosted runs require a GitHub Actions
secret named `WOLFRAMSCRIPT_ENTITLEMENTID`. The approved Publisher ID is not used by
this workflow; a resource publisher token is a separate requirement needed only for
a later submission workflow.

## Publishing GitHub Releases

GitHub Release publication is automated for version tags and remains separate from
Paclet Repository submission. Prepare a release by updating `PacletInfo.wl` and the
matching `CHANGELOG.md` section on a branch, validating it, and merging it to `main`.
After the release changes and workflow are on `main`, run the non-publishing dry run:

```powershell
gh workflow run release.yml --ref main -f ref=main -f expected_tag=v0.2.0-alpha.2
```

The dry run uses trusted tooling from the workflow commit to build the separately
checked-out requested ref, runs PacletCICD checks and the complete Wolfram/Python
suites against the archive, and uploads the paclet and SHA-256 file as Actions
artifacts. Its job has read-only repository permission and cannot instantiate the
tag-only publication job.

Once the dry run passes, create and push a signed annotated tag from that `main`
commit:

```powershell
git tag -s v0.2.0-alpha.2 -m "Einstoff v0.2.0-alpha.2"
git push github v0.2.0-alpha.2
```

The maintainer signs the tag; CI structurally rejects lightweight tags but does not
reverify the cryptographic signature. The tag workflow verifies that the annotated
tag matches the paclet version and points into `main`, rebuilds and retests under
read-only permissions, then passes the validated bundle to a globally serialized
publication job. It creates a SHA-256 checksum and GitHub build provenance and
publishes a prerelease or stable release as appropriate. Older stable versions are
not permitted to replace a newer release as `Latest`.

The workflow verifies build provenance with `gh attestation verify` and separately
verifies GitHub's immutable-release attestation. Maintainers can repeat the latter:

```powershell
gh release verify v0.2.0-alpha.2 --repo Gravifer/Einstoff.wl
```

GitHub is the automated publication target. After publication, the maintainer syncs
`main` and the new tag to Codeberg explicitly.

The Python tests use `ExternalEvaluate` and ZMQ; on some Windows/sandboxed setups,
Python session startup can be flaky even when the Wolfram-only suite is healthy.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for more details.

## Status

Einstoff is preparing its first Paclet Repository submission as
`Gravifer/Einstoff`. Version `0.2.0-alpha.1` is a repository-hosted prerelease;
the `Gravifer` Publisher ID is approved, while the publisher token, submission, and
Paclet Repository review remain later gates for the eventual `0.2.0` release.

## License

Einstoff is licensed under the GNU General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
