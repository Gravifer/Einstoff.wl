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
| Named ellipsis (inner mvar — destructuring template, see §5.3) | inner names in `(pattern)...` | names inside `Repeated[...]` | — (provisional) |
| Product / axis composition | `(a b)` | `a ⊗ b` | `CircleTimes` |
| Direct sum / concatenation | `(a + b)` | `a ⊕ b` | `CirclePlus` |
| Bracket (elementary-op signature axis) | `[a]` | `#a` | `Slot["a"]` |
| Bracket, multiple axes | `[a b]` | `Slot[a_, b_]` | `Slot` (non-standard arity, inert) |
| Bracket, anonymous ellipsis | `[...]` | `Slot[___]` | `Slot` |
| Bracket, integer immediate | `[2]` | `Slot[2]` | `Slot[2]` — **aliases `#2`, see §7.3** |

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

Two roles a name can play inside an ellipsis:

- **Outer mvar** (`name : Repeated[pattern]`) — binds the *entire captured
  `Sequence`*; `{name}` listifies it.
- **Inner mvar** (a named sub-pattern inside `Repeated[...]`,
  e.g. `grp:(a:(_Integer|_Symbol))...`) — a destructuring template. After
  `grp` captures the sequence via WL matching, the engine **re-walks**
  `{grp}` element-by-element applying the inner pattern, producing a
  per-repetition binding list `{a} = {a<sub>1</sub>, a<sub>2</sub>, ...}`.

Cross-group consistency (e.g. `Length[{a}] == Length[{b}]` before a
`MapThread`) is enforced by the engine during the manual binding phase, not
pushed into individual `RuleDelayed` RHS bodies.

**Provisional:** WL's stock `Repeated[x_]` semantics enforce that all
repetitions unify to the same value. The engine ignores that constraint and
re-drives matching manually. Safe while no compilation target delegates
`Repeated[x_]` back to native WL pattern matching; revisit if one does.

### 5.4 Size resolution

Outer mvars map to scalar integers in `sizeRules` as usual (cf. einx's
scalar axis sizes). Inner mvars (§5.3) are automatically list-valued —
`a -> {s1, s2, ...}`, one entry per repetition — as a natural product of
the engine's re-walk. No pre-classification of "is this name under a
`Repeated`?" is needed before reading `sizeRules`.

### 5.5 Repetition as uniform vectorization

Following einx, **repetition is not a distinct operation** but a form of
vectorization layered on the output of *any* operator. An axis present on the
RHS but absent from the LHS is *materialized by broadcasting*: each existing
element is replicated along the new axis. Its size cannot come from input-axis
binding (nothing on the LHS constrains it), so it is supplied out of band via
`bindings` (cf. §5.1), mirroring einx's `c=3` keyword. This applies uniformly
to `Einstoff[ArrayReshape]` (≙ einops.repeat / einx.id with an output-only
axis), `Einstoff[ArrayReduce]`, and `Einstoff[Dot]` — there is **no** separate
repeat operator (and no `ArrayRepeat`, which is not a WL builtin). The op symbol
selects the underlying elementary operation; repetition composes with it on the
output side, e.g.

- `einx.id("a b -> a b c", x, c=3)`   ≙ `{{a_,b_}} :> {{a, b, c}}`, `{c -> 3}`
- `einx.sum("a [b] -> a c", x, c=3)`  ≙ `{{a_, #b}} :> {{a, c}}`, `{c -> 3}`
- `einx.dot("a [b], [b] c -> a c r", x, y, r=2)`
  ≙ `{{a_, #b}, {#b, c_}} :> {{a, c, r}}`, `{r -> 2}`

Two further forms of an output-only axis are also repetition, handled the same
way (this is how einx treats them, confirmed against the reference):

- an **explicit integer** on the output that is not inside a bracket — its size
  is the literal itself, no binding needed: `einx.id("a -> a 2", x)`
  ≙ `{{a_}} :> {{a, 2}}`;
- a new axis that is **a factor of an output `CircleTimes`**, bound out of band —
  it is broadcast, then merged into the composite: `einx.id("a -> (a c)", x, c=3)`
  ≙ `{{a_}} :> {{a ⊗ c}}`, `{c -> 3}`.

Implementation: every lowering path routes its output through one shared
materialization step that broadcasts the repeat axes (replicate), permutes the
atomic axes into RHS order, and recomposes composites — so repetition is written
once and obtained uniformly.

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
   `Sequence`s, `MapThread` zips them. Cross-group length consistency
   (`Length[{a}] == Length[{b}]`) is enforced by the engine's manual
   binding phase (§5.3).

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

### 7.3 `Slot` non-standard arities

`Slot[a_, b_]` (multi-axis bracket) and `Slot[]` (bracketed nothing, if it
ever comes up) are arities `Slot` was never designed for. They're inert
today, but unconfirmed whether any WL builtin or future language version
attaches meaning to multi-argument `Slot`. Worth a guard/sanity check rather
than an assumption.

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
- Inner-mvar re-walk (§5.3): named sub-patterns inside `Repeated[...]` serve
  as destructuring templates; the engine re-walks the captured sequence
  element-by-element to produce per-repetition bindings. Cross-group
  consistency is enforced during the same manual binding phase.
  **Provisional:** WL's `Repeated[x_]` all-same semantics is intentionally
  ignored; revisit if a backend delegates to native WL matching (formerly §7.3).
- `sizeRules` for inner mvars is automatically list-valued as a product of
  the re-walk — no LHS pre-scan needed to detect `Repeated`-nested names
  (formerly §7.5).

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

## 10. Testing & validation

### 10.1 Cross-validation against einx / einops

Beyond the hand-written `VerificationTest`s, a second, independent oracle runs
the *actual* `einx` / `einops` Python implementations on the same inputs and
asserts Einstoff produces the same arrays. This catches a class of bug a
hand-written expected value can share with the implementation.

Mechanics:

- Interop is `ExternalEvaluate["Python", …]` (native, ZMQ-backed — the reason
  `pyzmq` is a project dependency), with the evaluator **registered ephemerally
  under an opaque UUID** pointing at the repo `.venv` interpreter, then
  unregistered when the test section ends. Nothing is persisted to the user's
  external-evaluator registry.
- Inputs are *not* marshaled across the boundary. Both sides rebuild the tensor
  from a shared dims recipe — WL `ArrayReshape[Range[Times @@ dims], dims]`
  vs Python `(1 + np.arange(prod)).reshape(dims)`. The `1+` matches WL's 1-based
  `Range`; numpy's default C-order matches WL `ArrayReshape` row-major. Only the
  *result* is marshaled back, via `.tolist()`, and compared by exact equality
  (integer arrays — no float tolerance needed).
- The tests are **opt-in** (`run-tests.wls python`), excluded from the default
  fast WL-only run, and live under `tests/python/`. Each section is gated with
  `BeginTestSection[name, pythonReady]` so it *skips* (not fails) when Python or
  the packages are unavailable.

**Out-of-band desc equivalence.** Each cross-validation test pairs a Python einx
pattern *string* with its Wolfram `desc` *expression* by hand; the equivalence is
reasoned by a human and written into the test. The implemented subset is required
to match: rearrange/reshape, reduce, dot, and repetition (§5.5) all cross-validate
against einx (and einops where it has a single-call equivalent). Behavior outside
the implemented lowering — variable-arity bracket ellipses, direct sums, nested
name-binding — is explicitly **not** required to agree until that lowering exists.

### 10.2 Future goal — `Interpreter` (einx string → Wolfram desc)

In Mathematica terminology, an `Interpreter`-style converter that mechanically
turns an einx-dialect *string* `desc` (we primarily target the einx dialect) into
the equivalent Wolfram expression `desc`. This would let cross-validation tests
drop the hand-written pairing of §10.1, deriving the Wolfram `desc` from the
Python string automatically.

**Do not implement in the foreseeable future.** This is recorded here so the goal
is not lost; coding agents should not be distracted by it. The near-term work is
the lowering paths (§9), not surface-syntax conversion. (Cf. the standing decision
to not implement the sugar layer either.)

### 10.3 Lesser goal — reverse direction (Wolfram from Python)

Driving the Wolfram engine *from* Python via `wolframclient`
(`WolframLanguageSession`) — the inverse of §10.1's Wolfram→Python call. This is a
**lesser goal**: noted for completeness, not currently pursued. The cross-validation
direction (Wolfram calling Python) is sufficient for validating Einstoff against
the reference implementations.
