# Plan: CirclePlus (direct sum / concatenation) — concat first

> Working plan for the next lowering feature. Referenced from SPEC.md §9.
> Status: planned, not yet implemented (to be picked up next).

## Context

The four-operator core — `Einstoff[ArrayReshape]`, `[ArrayReduce]`, `[Dot]`, plus
uniform repetition — is done, green, and merged to `main`. `CirclePlus` (`a ⊕ b`,
einx's `a + b`) is the next feature: **direct sum / concatenation along an axis**.
The shape layer (`EinstoffShapes` in `Einstoff/Kernel/Parsing.wl`) already resolves
it; only the **lowering** is missing. This targets the current architecture (hub
`Lowering.wl` + `materializeOutput`, per-path `Reshape.wl`/`Reduce.wl`/`Dot.wl`).

Decisions locked with the user:
- **Fold into `Einstoff[ArrayReshape]`** (einx-faithful: `+` lives in `id`). Add
  `Einstoff[Join]` and `Einstoff[Split]` as the **same machinery + a directional
  guard**: `Join` allows CirclePlus only on the RHS (concat), `Split` only on the
  LHS (split).
- **Concat first** (multi-input → 1 output, ex4 incl. scalar/integer summand).
  Split (LHS CirclePlus → multi-output via `Take`) is **phase 2**.

## Key facts established

- **Shape layer is ready.** `EinstoffShapes` binds CirclePlus summands (split:
  `q=3 ⇒ k=7`; concat: evaluates `(c + 1)` → `c+1`) and produces multi-output
  `OutputShapes`. The concat case `{{b_,c_},{}} :> {{b, c ⊕ 1}}` is already covered
  by the passing `ex4-scalar-operand` test in `tests/Parsing.wlt`.
- **Primitive: `Join[op1, op2, …, n]`** concatenates along dimension `n`.
  `JoinAcrossAll` is a database key-join — NOT applicable; do not use it.
- **einx `+` is positional, left-to-right:** summand *i* ← operand *i*; a scalar
  operand broadcasts to fill its block (ex4's `42`); an integer summand is a
  literal-size block.
- **Grammar — parentheses ≠ brackets.** `CirclePlus` ⇔ einx parentheses `(a + b)`
  (direct sum), distinct from `Slot` ⇔ einx brackets `[…]` (elementary-op marker).
  Concat CirclePlus appears **bare** (not in a `Slot`); the new decomposition must
  treat `CirclePlus` as the concat-axis marker, separate from both `CircleTimes`
  (product) and `Slot` (bracket).

## Approach (concat path)

New file **`Einstoff/Kernel/DirectSum.wl`** holding the shared direct-sum handler
and the `Join`/`Split` dispatch; `Reshape.wl` dispatches to it when a CirclePlus is
detected in the desc. Shared helpers (`descParts`, `atomSize`, `materializeOutput`)
come from the hub.

**Dispatch:**
- `Einstoff[ArrayReshape]` (`EinstoffRearrange`): no CirclePlus → existing
  single-tensor path; CirclePlus on RHS → concat handler; on LHS → split handler
  (phase 2 → reject with a clear "not yet" for now).
- `Einstoff[Join]`: guard CirclePlus appears **only on the RHS** (else reject), then
  call the concat handler.
- `Einstoff[Split]`: guard CirclePlus **only on the LHS** (phase 2).

**Concat handler** — `{op1, …, opk} :> {{ … CirclePlus[s1, …, sk] … }}`
(single output, one CirclePlus with `k` summands, `k` operands; summand *i* ←
operand *i*):
1. `EinstoffShapes` → satisfiability + `env` (binds carrier axes and each summand
   size; integer summand is literal).
2. Decompose the output: the CirclePlus term is the **concat axis** at level `n`
   (position among the output's atomic axes); the other output axes are the
   **carrier** axes.
3. **Align each operand to `{carrier…, s_i}`**, reusing the rearrange +
   `materializeOutput` machinery: an operand missing a carrier axis (scalar) or
   providing a literal-integer block is broadcast to fill (matches einx's `42`).
4. **`Join[aligned1, …, alignedk, n]`** → output atomic array (concat axis = `Σ s_i`).
5. Recompose output composites via `ArrayReshape` / `materializeOutput`.

**First-cut scope:** one CirclePlus on the output; `k` operands ↔ `k` summands; each
summand a bare name or integer (carrier axes may permute); scalar operand + integer
summand supported. Covers `b c, -> b (c + 1)` (ex4) and `m a, m b -> m (a + b)`.

**Deferred:** split direction (phase 2); nested summands (`(a⊗b + c)`); CirclePlus
combined with brackets (`Slot[CirclePlus[…]]`) or with output `CircleTimes` on the
same axis; >1 CirclePlus per shape.

## Files

- **Create `Einstoff/Kernel/DirectSum.wl`** — concat handler + `Einstoff[Join]` /
  `Einstoff[Split]` dispatch + a CirclePlus-aware decomposition distinguishing
  `CirclePlus` from `CircleTimes`/`Slot`.
- **Edit `Einstoff/Kernel/Reshape.wl`** — detect CirclePlus in `EinstoffRearrange`
  and delegate; otherwise unchanged.
- **Possibly edit `Einstoff/Kernel/Lowering.wl`** — shared decomposition helper as
  `PackageScoped` if best placed in the hub.
- **Create `tests/DirectSum.wlt`** — section `Einstoff`Lowering`DirectSum`; WL tests
  vs native `Join`/`ConstantArray` (ex4 scalar-append, 2-array concat, integer
  summand, carrier permute, + rejections: CirclePlus on LHS under `Join`,
  operand/summand count mismatch, unbound summand).
- **Create `tests/python/DirectSum.wlt`** — einx cross-validation, reusing the
  shared-session harness (`Einstoff`Tests`$PySession`).
- **Edit `SPEC.md`** — mark CirclePlus concat implemented once done.

## Verification

1. `wolframscript -script scripts/run-tests.wls -q` — WL suite green incl.
   `DirectSum.wlt`; concat outputs equal native `Join[…, n]` / `ConstantArray`.
2. `wolframscript -script scripts/run-tests.wls python -q` — einx cross-validation
   passes (retry on the known ZMQ flake).
3. Guards: `Einstoff[Join]` with CirclePlus on the LHS → `$Failed`;
   `Einstoff[ArrayReshape]` with LHS CirclePlus → clear "split not yet implemented".
4. No regression in the existing four-operator suites.
