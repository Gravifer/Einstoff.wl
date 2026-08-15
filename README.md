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

To inspect the source paclet separately, install the checksum-verified PacletCICD
version pinned by this repository, then check or build with the same tooling used by
CI:

```powershell
wolframscript -script scripts/install-paclet-cicd.wls
wolframscript -script scripts/paclet-cicd.wls check
wolframscript -script scripts/paclet-cicd.wls submission-check
wolframscript -script scripts/paclet-cicd.wls build
```

Run `check` before `build`; the build command does not repeat the definition-notebook
inspection. `submission-check` performs a non-authenticated, non-submitting repository
preflight. The ordinary GitHub workflow selects free or licensed phases from the changed
files, and deliberately avoids hosted Python cross-validation. Fork pull requests
receive free checks; contributors with their own entitlement can run the licensed
workflow in their fork.

## Releases and Publication

GitHub Release publication is automated for signed version tags after a
non-publishing dry run. Release validation builds the archive, runs the complete
Wolfram and Python suites against it, produces a checksum, and verifies GitHub
attestations. Paclet Repository submission is a separate later workflow and is never
performed by ordinary CI or GitHub Release automation.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the CI selection policy, fork workflow,
PacletCICD fallback installation, and detailed maintainer release sequence. GitHub is
the only automated publication target; maintainers synchronize `main` and release
tags to Codeberg explicitly.

## Status

Einstoff is preparing its first Paclet Repository submission as
`Gravifer/Einstoff`. Version `0.2.0-alpha.1` is a repository-hosted prerelease;
the `Gravifer` Publisher ID is approved, while the publisher token, submission, and
Paclet Repository review remain later gates for the eventual `0.2.0` release.

## License

Einstoff is licensed under the GNU General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
