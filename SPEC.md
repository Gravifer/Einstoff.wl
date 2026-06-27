# Einstoff — Spec

Replicating einsum / einops / einx for Wolfram Language, using native pattern
objects (`Pattern`, `Blank`, `CirclePlus`, `CircleTimes`, `Repeated`, `Slot`)
as the AST itself, rather than an opaque string grammar.

Status: design draft. Section 7 (Open Issues) is unresolved and should be
read as part of the spec, not an appendix.

---

## 1. Motivation

einops gives Python a readable notation for permute/reshape/reduce/repeat.
einx extends it with multi-tensor einsum-style contraction, named/bracketed
sub-tensor signatures, ellipses, and direct-sum (concatenation) axes.

Both represent everything as a single opaque string that gets parsed
internally. Wolfram Language already ships a pattern-matching vocabulary
that maps almost one-to-one onto the *concepts* einx needs (named binding,
anonymous wildcard, repetition, sequence). Einstoff's premise: use that
vocabulary directly as the surface syntax, and let `MatchQ`/`Cases`-style
matching do double duty as both parser and shape-binder.

## 2. Design principles

- The top level is a standard `List`, not a string.
- An operation with input shape(s) and output shape(s) is a `RuleDelayed`:
  `lhs :> rhs` — **not** `Rule`. `Rule`'s RHS is evaluated immediately at
  construction time, before any match against real data has happened, using
  whatever (unbound) values the pattern-variable symbols currently carry.
  `RuleDelayed` has `HoldRest`: the RHS stays unevaluated until a match
  succeeds and bindings are substituted in. Since LHS is built entirely out
  of patterns whose RHS routinely needs to *use* those bindings (see §4.2,
  §7.1), `:>` is the only idiomatic choice — this is the same reason
  `Cases[list, pat :> body]` and `f[x_] := body` are written the way they
  are, not a new mechanism invented for Einstoff.
- Internal parsing is still allowed/expected; what changes is the *surface*
  representation people write and that the engine pattern-matches against.

## 3. Symbol glossary

| Concept | einops/einx string | Einstoff form | WL construct |
|---|---|---|---|
| Named dimension (binding) | `a` | `a_` | `Pattern[a, Blank[]]` |
| Named dimension (reference to an already-bound name) | `a` (repeated) | `a` | bare symbol |
| Integer immediate | `2` | `2` | literal integer |
| Anonymous dimension | `_` | `_` | `Blank[]` |
| Ellipsis (anonymous) | `...` | `___` | `BlankNullSequence[]` |
| Ellipsis (anonymous, ≥1) | — | `__` | `BlankSequence[]` |
| Named ellipsis (capture the whole repeated group) | `a...` | `a : pattern..` | `Pattern[a, Repeated[pattern]]` (or `RepeatedNull`) |
| Named ellipsis (structural constraint only, not captured per-element) | inner names in `(pattern)...` | names inside `Repeated[...]` | — |
| Product / axis composition | `(a b)` | `a ⊗ b` | `CircleTimes` |
| Direct sum / concatenation | `(a + b)` | `a ⊕ b` | `CirclePlus` |
| Bracket (elementary-op signature axis) | `[a]` | `#a` | `Slot["a"]` |
| Bracket, multiple axes | `[a b]` | `Slot[a_, b_]` | `Slot` (non-standard arity, inert) |
| Bracket, anonymous ellipsis | `[...]` | `Slot[___]` | `Slot` |
| Bracket, integer immediate | `[2]` | `Slot[2]` | `Slot[2]` — **aliases `#2`, see §7.4** |

## 4. Grammar

### 4.1 Shape

A *shape* is a `List` of dimension terms. A dimension term is one of:

- a bare symbol (reference) or `name_` (binding)
- an integer
- `_`, `__`, `___`
- `name : Repeated[term]` (named ellipsis) or bare `Repeated[term]` /
  `RepeatedNull[term]` (anonymous-name ellipsis — structural only)
- `CircleTimes[term, term, ...]` (product)
- `CirclePlus[term, term, ...]` (direct sum)
- `Slot[term, ...]` wrapping any of the above (bracket), nestable at any
  depth inside `CircleTimes`/`CirclePlus`/`Repeated`

### 4.2 Operation

**An operation is always `{shape, shape, ...} :> {shape, shape, ...}`** —
list-of-shapes on both sides, unconditionally, connected with `RuleDelayed`.
There is no grammar-level single-tensor or no-output special case. See §7.1
for why list-of-shapes is load-bearing, and §2 for why `:>` (not `->`) is
load-bearing.

For the common case — pure permute/split/merge, no derived axes — the RHS
is *still* written under `:>`, and evaluates the same way `->` would: after
the LHS matches and binds e.g. `a=4, b=8, c=2`, evaluating a trivial RHS
like `{c, a, b}` is just substitution, nothing computational happens. The
distinction only bites once an operation's RHS needs to *do* something with
the bindings beyond rearrange them (§7.1) — but since that need is common
enough across the grammar (any named-ellipsis combination), `:>` is used
uniformly rather than switched per-operation.

Two sugars are allowed at the *call-site* (front-end), not in the core
grammar:

- a single shape `{...}` may stand in for `{{...}}` when there is exactly
  one input/output tensor
- a one-sided shape `{...}` (no `RuleDelayed`) for shape-preserving ops,
  normalized internally to `{...} :> {...}` before reaching the core engine

## 5. Semantics

### 5.1 Binding vs. reference

`a_` introduces a binding; a bare `a` later in the *same* match (e.g. the
second operand's shape, or the RHS) is a reference and must match the same
value already bound to `a`. This is not bespoke Einstoff logic — it is
exactly how repeated pattern variables already behave in `MatchQ`/`Cases`
(`MatchQ[{3, 3}, {x_, x}]` only succeeds because both `3`s agree). It is what
makes shared/contracted axes across tensors (§6.10) fall out for free.

New axes that appear only on the RHS (repeat-style) are *not* covered by
this mechanism, since there is nothing on the LHS to bind them to — those
are resolved from an out-of-band `sizeRules`-style argument instead.

### 5.2 Reduce vs. elementary-op: the bracket disambiguates

"Axis present on LHS, absent on RHS" is ambiguous by itself — it could mean
(a) classic reduction with a user-supplied function (einops `reduce`), or
(b) the axis is fed whole into an elementary operation and everything else
is vmapped (einx bracket semantics). `Slot[...]` presence is the only thing
distinguishing these, so the compiler must branch on bracket-presence
explicitly; it cannot be inferred from set difference between LHS/RHS axis
names alone.

### 5.3 Named ellipsis: where the name lives matters

- `name : Repeated[pattern]` — `name` binds to the *entire matched
  `Sequence`*. This is the only form that gives you the repeated group back
  as data.
- `Repeated[name_]` — `name` gets rebound on every repetition; only the
  *last* match survives. Names inside `Repeated[...]` function as
  **structural constraints** (e.g. "every element must look like
  `CircleTimes[s_, Slot[ds_]]`"), not as accessors.
- Consequence: extracting the per-repetition `s_i`, `ds_i` families out of
  a captured group requires the engine (or the operation's `:>` RHS, see
  §7.1) to re-walk the bound `Sequence` after matching.
- `Repeated[...]` does **not**, by itself, assert that repetitions are
  pairwise equal (unlike e.g. `{x_, x_, x_}`). If an operation's semantics
  require all repetitions of a named ellipsis to share a size, the engine
  must check it — the pattern match will succeed even if they differ.

### 5.4 Size resolution

For any name *not* under a `Repeated`, `sizeRules` maps `name -> integer`,
as usual. For any name living under a `Repeated`, the corresponding entry
must instead be `name -> {size, size, ...}`, one per repetition (cf. einx's
`ds=(2,2)`). Size-resolution code must know whether a name sits under a
`Repeated` before it knows which shape of value to expect from
`sizeRules`.

## 6. Worked examples

Canonical core-grammar form (always list-of-shapes both sides, `:>`); the
single-tensor sugar is shown only in example 1 for illustration and omitted
after that for brevity.

1. **Plain rearrange** — `rearrange(x, 'a b c -> c a b')`
   - Sugar: `{a_, b_, c_} :> {c, a, b}`
   - Canonical: `{{a_, b_, c_}} :> {{c, a, b}}`

2. **Split + permute + merge** — `einx.id("a (b c) -> (b a) c", x, b=2)`
   ```
   {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}
   ```

3. **Direct-sum split, multi-output** — `einx.id("b (q + k) -> b q, b k", x, q=2)`
   ```
   {{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}}
   ```
   First case that *requires* the list-of-shapes top level — two output
   tensors, not one shape.

4. **Scalar operand + direct-sum append** — `einx.id("b c, -> b (c + 1)", x, 42)`
   ```
   {{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}}
   ```
   The empty `{}` for a scalar operand falls out naturally — no special
   "empty side" token needed.

5. **Bracket reduce** — `einx.sum("a [b]", x)`
   ```
   {{a_, Slot[b_]}} :> {{a}}
   ```

6. **Anonymous bracket ellipsis** — `einx.mean("b [...] c", x)`
   ```
   {{b_, Slot[___], c_}} :> {{b, c}}
   ```

7. **Named ellipsis, cross-tensor zip (Kronecker product)** —
   `einx.multiply("a..., b... -> (a b)...", x, y)`
   ```
   {{a : Repeated[_]}, {b : Repeated[_]}} :> {MapThread[CircleTimes, {{a}, {b}}]}
   ```
   Resolved by `RuleDelayed` (§7.1): `{a}`/`{b}` listify the captured
   `Sequence`s, `MapThread` zips them. Note this does *not* check
   `Length[{a}] == Length[{b}]` — see §7.3.

8. **Named ellipsis with internal structure (pooling)** —
   `einx.sum("b (s [ds])... c", x, ds=(2, 2))`
   ```
   {{b_, grp : Repeated[CircleTimes[s_, Slot[ds_]]], c_}} :> {Join[{b}, Map[First, {grp}], {c}]}
   ```
   `First` on each captured `CircleTimes[s_i, Slot[ds_i]]` reads off `s_i`
   positionally — plain `First`, no replacement rule needed, since
   `CircleTimes` is just a head with ordered arguments.

9. **Outer/broadcast, no brackets** — `einx.add("a, b -> a b", x, y)`
   ```
   {{a_}, {b_}} :> {{a, b}}
   ```
   No axis dropped, no bracket — confirms broadcast/elementwise is a third
   compiled code path alongside permute-reshape and feed-to-elementary-op.

10. **Einsum-style contraction (matmul)** — `einx.dot("a [b], [b] c -> a c", x, y)`
    ```
    {{a_, Slot[b_]}, {Slot[b], c_}} :> {{a, c}}
    ```
    `b_` binds in the first operand, bare `b` references it in the second
    — ordinary WL repeated-variable matching, no custom rule needed.

11. **Gather with bracketed immediate** —
    `einx.get_at("b [h w] c, b i [2] -> b i c", x, y)`
    ```
    {{b_, Slot[h_, w_], c_}, {b, i_, Slot[2]}} :> {{b, i, c}}
    ```

12. **Shape-preserving, one-sided** — `einx.flip("... (g [c])", x, c=2)`
    ```
    {___, CircleTimes[g_, Slot[c_]]}
    ```
    No `RuleDelayed`. Front-end normalizes `p` to `p :> p` before the core
    engine ever sees it, per §4.2.

## 7. Open issues

### 7.1 Output-side derivation for combined/projected named ellipses — RESOLVED at the spec level; lowering remains open

Examples 7 and 8 originally had no literal-pattern RHS: `(a b)...` means
"zip the two captured `Sequence`s pointwise," and projecting `ds` out of
each repetition of `(s [ds])...` is a per-operation computation — neither
is a shape *descriptor*.

**Resolution:** the assumption that the RHS must be a structural shape
pattern was the actual problem, not the grammar. Under `RuleDelayed` (§2),
the RHS is ordinary WL code evaluated after the LHS binds — it can be
`MapThread`, `Join`, `Map[First, ...]`, anything — as long as it evaluates
to a `List` of dimension terms. Examples 7 and 8 above now have real,
evaluable RHS bodies. No bespoke "output-derivation procedure interface"
needs to be designed; `RuleDelayed`'s existing held-then-substituted
semantics already is that interface.

**What's still open**, narrower than before:
- Cross-group consistency (e.g. `{a}` and `{b}` having equal length in
  example 7) is not checked by the match or by `RuleDelayed` — see §7.3.
- Once such an RHS evaluates to a concrete (possibly irregular) shape,
  *lowering* it to actual `Transpose`/`ArrayReshape`/`ArrayReduce`/`Join`
  calls that produce real array data is operation-specific engineering,
  not a generic compile step. This was always going to be true for
  irregular ops like Kronecker product; `RuleDelayed` solves expressibility
  of the spec, not automatic compilation to the four native primitives.

### 7.2 `Slot` aliasing `Function` slots (deferred, not yet fixed)

`Slot[n]` for integer `n` is literally `#n`. Outside a `Function` body it
sits inert; if any bracketed-immediate subexpression is ever spliced into a
`Function`/`&` template and applied, the integer silently gets reinterpreted
as an argument reference instead of a bracketed dimension:

```mathematica
tmpl = {Slot[2], a} &;
tmpl[x, y]      (* {y, a} — silent corruption, no error *)
```

Symbolic brackets (`Slot[ds_]` etc.) fail loudly instead (`Function::slotn`),
since `ds` isn't a valid slot number — only the integer-immediate case is
silent. Proposed mitigation (not yet implemented): normalize `Slot[2]` to
`Slot["2"]` internally. Per discussion, this is deferred until either (a) it
actually breaks something, or (b) the engine starts generating
`Function`-wrapped code (e.g. a vmap-style backend), at which point it stops
being optional. Current mitigating factor: none of the planned compilation
targets (`Transpose`, `ArrayReshape`, `ArrayReduce`, `Join`) are `Function`s,
so the AST is not currently expected to flow into one.

### 7.3 Repeated-group equality is not enforced by the pattern itself

Per §5.3: if an operation's semantics require all repetitions of a named
ellipsis to share a size, that check has to be written by the engine — and
per §7.1, "written by the engine" now concretely means: as a guard inside
(or before) the `RuleDelayed` RHS, e.g. asserting `Length[{a}] ==
Length[{b}]` before `MapThread` runs in example 7. Not yet decided whether
that guard lives in a shared helper all operations call, or is duplicated
per-operation.

### 7.4 `Slot` non-standard arities

`Slot[a_, b_]` (multi-axis bracket) and `Slot[]` (bracketed nothing, if it
ever comes up) are arities `Slot` was never designed for. They're inert
today, but unconfirmed whether any WL builtin or future language version
attaches meaning to multi-argument `Slot`. Worth a guard/sanity check rather
than an assumption.

### 7.5 Per-repetition `sizeRules` shape

Per §5.4, `sizeRules` needs to switch from scalar to list-valued depending
on whether the name sits under a `Repeated`. Not yet decided how that's
detected (engine inspects the parsed LHS to classify each name before
reading `sizeRules`) or how mismatches are reported.

## 8. Resolved / verified (no further action needed)

- `CirclePlus`/`CircleTimes` have no built-in evaluation rules for symbolic
  or numeric arguments — safe to use as inert semantic tags.
- Bare-vs-`_` for binding/reference is stock WL pattern behavior, not
  bespoke logic (§5.1).
- Top-level grammar is unconditionally list-of-shapes both sides, connected
  by `RuleDelayed` (§4.2); single-tensor and one-sided forms are front-end
  sugar only.
- `Slot[...]` nests without issue inside `CircleTimes`, `CirclePlus`, and
  `Repeated` at any depth (confirmed across examples 6, 8, 10, 11).
- Output shapes that depend on combining or projecting captured named
  ellipses (§7.1) are expressible as ordinary `RuleDelayed` RHS code — no
  separate output-derivation interface needs to be designed.

## 9. Next steps

Pick one:

- (a) Work out native-primitive lowering for `RuleDelayed`-derived
  irregular output shapes (Kronecker-style zip, projected pooling) — i.e.
  once the RHS evaluates to a concrete shape, design how the engine
  produces the actual `Transpose`/`ArrayReshape`/`Join` calls that realize
  it, since these aren't simple permute+reshape (§7.1 residual).
- (b) Write the matcher: given a concrete `Dimensions[tensor]` and an
  Einstoff LHS shape, produce the bound axis-size association via
  `MatchQ`/`Cases`, including bracket-aware branching (§5.2) and
  `Repeated`-group re-walking (§5.3), then evaluate the `RuleDelayed` RHS
  to get the output shape.
