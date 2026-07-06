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

## Follow-up: purify `EinstoffShapes` — DONE (branch `refactor/purify-einstoffshapes`)

**Implemented** as the two-phase invariant below (commits `e33e3ef` phase 1, `878d2fc`
phase 2, `c11a904` tests; suite 281 = 230 WL + 51 xval). `EinstoffShapes` is now an
operator-agnostic resolver that rejects only a duplicate **output** axis; a repeated
**input** axis resolves (matching `Einstoff["ArrayContract"]`) and is rejected by each
non-contracting operator itself via the shared predicate `distinctAxesQ` (built on
`firstDuplicateAxis`, both PackageScoped in Lowering.wl). The original analysis follows.

A code review surfaced that the public `EinstoffShapes` preflight disagrees with
the contraction surface this branch promoted: `EinstoffShapes[{{a_,b_,a,d_}} :>
{{b,d}}, {{2,3,2,5}}]` returns `Satisfiable -> False` ("axis a appears more than
once within a single shape"), while `Einstoff["ArrayContract"]` lowers the same
desc correctly to a `{3,5}` tensor. Root cause: the duplicate-axis check
(`Parsing.wl`, `firstDuplicateAxis[Join[lhs, relRhs]]`) rejects a repeated **LHS**
name, which is a caller-specific *policy*, not shape truth — `EinstoffMatch`'s
`unify` already resolves repeated LHS names by binding once and enforcing equality.

**Do NOT patch this on `feat/entrance-guards`, and do NOT relax `EinstoffShapes`
to "RHS-only" as an immediate one-line change.** This is a rejection of the
*sequencing*, not of the eventual end state — the target shape-layer behavior
genuinely *is* "RHS duplicate stays central, LHS duplicate is no longer rejected"
(see the two-phase plan below). The point is you cannot get there by flipping the
check now: the current mismatch is *conservative* (the preflight is stricter than
the operator) — a false negative on satisfiability, which never authorizes a bad
lowering. Relaxing the LHS check *before* the callers are hardened would flip that
risk — it would let `Reduce`/`Map`/`Dot`/`DirectSum`, which call `EinstoffShapes`
and are not all hardened against a repeated-LHS desc, trust an input they cannot
lower (false *positive* → possible mis-lowering). Trading a harmless conservative
false-negative for a latent correctness hazard is a bad trade. The contraction
paths (`Massage`/`Contract`/`einsum`) already bypass `EinstoffShapes` via
`EinstoffMatch`, so no internal code path is currently wrong — this is purely an
external-preflight-consistency gap.

**Target (einx-aligned).** einx's public solver surface — `solve_shapes`,
`solve_axes`, `matches` — is entirely operator-agnostic; einx exposes no public
per-operator preflight (operator applicability is decided *inside* the operator
call). Mirror that:

- **`EinstoffMatch`** — pure axis unification / shape solving. Already exists,
  already used by the repeat-capable paths. Low-level.
- **`EinstoffShapes`** — an operator-**agnostic** *transformation* shape resolver:
  parse desc, solve LHS bindings, derive RHS output shapes. It keeps only
  **universal shape invariants** — positive-integer output dims and **RHS axis
  uniqueness** (a duplicate *output* axis has no well-defined layout and every
  lowering assumes RHS identities are unique; `Massage` already re-asserts this).
  It stops rejecting a repeated **LHS** axis merely for repeating. Note it is
  *not* `einx.solve_shapes` (which is operation-free and symmetric); "pure" here
  means **policy-free, not operation-free** — it still derives `lhs -> rhs` output
  shapes.
- **Operator front doors** — each asserts its own LHS-repeat admissibility:
  `ArrayReshape` rejects a contraction repeat; `"ArrayContract"`/`"Massage"`/
  single-input `"einsum"` accept a pairwise-dropped repeat; `ArrayReduce`/`Map`
  reject a repeated LHS name until a meaning is defined; `Dot` already rejects
  within-operand repeats in multi-tensor descs. This layer already effectively
  exists — the `massageCore` policy gate is exactly it — so "call the operator,
  get a classified `$Failed`" is already the operator-aware check.

**Split, precisely:** RHS-duplicate = central invariant (stays in the shape
layer); LHS-duplicate = operator policy (moves to the callers). Sequence it as a
**two-phase invariant** so there is never a window where the preflight is more
permissive than a caller can handle:

1. **Harden first** — give every caller of `EinstoffShapes` (`Reduce`, `Map`,
   `Dot`, `DirectSum`) an explicit repeated-LHS policy guard.
2. **Then relax** — once all callers self-guard, drop the LHS-repeat rejection
   from `EinstoffShapes` (RHS uniqueness + positive dims remain).

This two-phase purification has landed: `EinstoffShapes` is now an operator-agnostic
shape resolver for repeated LHS axes, while callers enforce their own LHS-repeat
policy guards. A possible future dry-run helper (an operator-aware, non-executing
check) remains a convenience only — einx ships none, so it is out of the critical path.

## Deferred (feature roadmap, not this change)

Combiner-generalized contraction (`ArrayContract[…, add]` / `Tr[…, add]`,
mirroring `Inner`); diagonal-keep; mixed within+cross multi-operand einsum; the
`EinstoffTandem` cross-tensor backend.
