# Entrance-guard restructure — target contract

Status: **done** (branch `feat/entrance-guards`). This is the API-surface
stabilization step: it stops `Einstoff[ArrayReshape]` from being a permissive
alias and pins each named entrance to a precise, intent-declaring contract, so a
rejected desc classifies cleanly as "wrong guard" vs "wrong lowering".

## The one engine, three (four) policies

All single-tensor structural work is one engine (`massageCore` in
`Einstoff/Kernel/Reshape.wl`). The entrances differ only in which non-bijective
features they admit. The natural ordering is by **element count** of a single
input tensor (N = product of its dims) and by number of tensors:

| Entrance | Symbol | Admits | Element count |
|---|---|---|---|
| `Einstoff[ArrayReshape]` | `EinstoffReshape` | permute / split / merge, unit-axis insert & squeeze, scalar↔singleton | `out == in` (**bijective**) |
| `Einstoff["ArrayContract"]` | `EinstoffContract` | the above **+ within-tensor pairwise contraction** | `out ≤ in`, **no repetition** |
| `Einstoff["Massage"]` | `EinstoffMassage` | the above **+ repetition + direct sum** | any (**permissive**) |
| `Einstoff["einsum"]` | `EinstoffEinsum` | pairwise contraction dispatcher: 1 tensor → contraction semantics, ≥2 → the `Dot` fold | — |

`Einstoff["Reshape"]` / `["Rearrange"]` alias the bijective guard;
`Einstoff["Contract"]` aliases the contraction guard.

## Precise rules

Both guards are **single-tensor** and reject **direct sum** (a structural
join/split — `Einstoff[Join]`/`[Split]` or `Massage`).

- **Bijective (`ArrayReshape`)** — an element-count-preserving reindexing.
  Rejects, each with a message naming the right entrance:
  - **repetition** — an output-only axis of size > 1 (a named axis absent from
    the input, or an output literal integer > 1). *A size-1 output-only axis is a
    unit-axis insert — still count-preserving, so it is allowed* (`a -> a 1`).
  - **within-tensor contraction** — a repeated, dropped input axis (→ `ArrayContract`).
  - **reduction** — a dropped size > 1 input axis (→ `ArrayReduce`).
- **No-repetition (`ArrayContract`)** — everything the bijective guard allows,
  plus a within-tensor pairwise contraction. Still rejects **repetition** and
  **direct sum**; a plain single-index sum-reduction stays out of scope
  (→ `ArrayReduce`). Only *pairwise* contraction is tensorial: a kept repeat
  (diagonal `a a -> a`) and an index occurring > 2 times (super-diagonal) are
  rejected, as in `einsum`.

### Why "no repetition" and not merely "non-increasing"

A size-1 output-only axis (unit insert) preserves the element count, so it is
admitted by *both* guards — the boundary is not literally "count strictly
preserved / decreased" but "no output-only axis of size > 1". This is checked
directly (an output atom not carried from the input, whose size is > 1 or
unbound), so a pathological contraction-plus-repetition mix is still rejected by
the repetition rule even though its *net* count might be ≤ input.

## Implementation

`massageCore[desc, tensors, bindings, policy]` carries a `policy` of
`All | "Reshape" | "Contract"`. The three public wrappers set it. The gate lives
inside the core, at the exact point each feature becomes known:

- the direct-sum branch rejects when `policy =!= All`;
- after `selfContract`, with `atomsc` (surviving input atoms) and the raw output
  atoms known: `contracted = atomsc =!= lhsAtoms` (forbidden by `"Reshape"`);
  `repeated =` an output-only atom of size > 1 or unbound (forbidden by both).

Keeping the classification in the shared core means the guards are pure intent
declarations and the reduction/materialization guards (positive dims, literal
carry, unit squeeze) are inherited unchanged.

## Tests

- `tests/ArrayContract.wlt` — the new contraction entrance (traces, bijective
  subset allowed, repetition / direct-sum / single-drop / diagonal /
  super-diagonal / multi-tensor rejected; agreement with `Massage` and `einsum`).
- `tests/Reshape.wlt` — repetition tests retargeted to `Einstoff["Massage"]`; a
  new section asserts the bijective entrance rejects repeat / contraction /
  direct-sum descs; unit-axis & scalar tests stay on `ArrayReshape`.
- `tests/DirectSum.wlt`, `tests/python/{Reshape,DirectSum}.wlt` — the repeat /
  direct-sum sites migrated from `Einstoff[ArrayReshape]` to `Einstoff["Massage"]`.

Suite green: 224 WL + 51 xval = 275.

## Deferred (feature roadmap, not this change)

Combiner-generalized contraction (`ArrayContract[…, add]` / `Tr[…, add]`,
mirroring `Inner`); diagonal-keep; mixed within+cross multi-operand einsum; the
`EinstoffTandem` cross-tensor backend.
