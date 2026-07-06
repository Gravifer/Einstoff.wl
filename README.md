# Einstoff

Einstoff is an experimental Wolfram Language package for writing tensor and
array-axis transformations as Wolfram expressions instead of string mini-languages.
It uses native pattern objects such as `a_`, `_`, `__`, `___`, `CircleTimes` (`⊗`),
`CirclePlus` (`⊕`), `Slot`, `Highlighted`, and `Framed` as the shape description AST.

The planned destination is `ResourceFunction["Einstoff"]`. For now this repository is
an unreleased development tree.

## What It Does

Inspired by [einx](https://github.com/fferflo/einx),
Einstoff covers a growing subset of ein-style array notation:

- `Einstoff[ArrayReshape]` for bijective rearrange/reshape operations.
- `Einstoff["Massage"]` for the permissive single-tensor structural engine, including
  repetition, direct sums, and pairwise within-tensor contraction.
- `Einstoff[ArrayReduce][f]` for targeted reductions.
- `Einstoff[Map][f]` for shape-preserving targeted block maps.
- `Einstoff[Dot]` and `Einstoff[Inner][mul, add]` for cross-tensor contractions.
- `Einstoff[Join]` and `Einstoff[Split]` for structural direct sums.
- `Einstoff["einsum"]` for the implemented pairwise einsum-style subset.

The primary user reference is [`docs/Einstoff.en.md`](docs/Einstoff.en.md). The
developer and agent-facing design notes live under [`.agents/`](.agents/).

## Example

```mathematica
PacletDirectoryLoad[Directory[]];
Needs["Einstoff`"];

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

- `Einstoff/` contains the Wolfram paclet-style package sources.
- `docs/Einstoff.en.md` is the public reference documentation draft.
- `tests/*.wlt` are the source unit tests.
- `tests/python/*.wlt` are opt-in cross-validation tests against `einx`, `einops`, and
  NumPy where applicable.
- `tests/EinstoffTestSuite.nb` is generated from the `.wlt` tests for maintainer use.
- `.agents/agents.md`, `.agents/SPEC.md`, and `.agents/plans/` are developer and coding
  agent materials.

## Getting Started

Have your own Wolfram Language system ready. Einstoff currently targets Wolfram
Language 14.0 or newer, and the test suite runs through `wolframscript`.

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

The Python tests use `ExternalEvaluate` and ZMQ; on some Windows/sandboxed setups,
Python session startup can be flaky even when the Wolfram-only suite is healthy.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for more details.

## Status

Einstoff is pre-release. Public APIs, messages, and documentation may still change.
The changelog will stay under `Unreleased` until the project is packaged and published.

## License

Einstoff is licensed under the GNU General Public License v3.0 or later. See
[`LICENSE`](LICENSE).
