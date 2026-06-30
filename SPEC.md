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
| Bracket, multiple axes | `[a b]` ≡ `[a][b]` | `#a #b` | `Slot["a"], Slot["b"]` — adjacent single `Slot`s, `[a b]≡[a][b]`, see §7.3 |
| Bracket, anonymous ellipsis | `[...]` | `##` | `SlotSequence[1]` |
| Bracket, integer immediate | `[2]` | `Slot[2]` | `Slot[2]` — explicit (no `#`-sugar for a bracketed literal), see §7.2 |

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

A **bracketed** axis is written `#name` (= `Slot["name"]`) and binds by
*unification* on its string name: the bind/reference asymmetry of bare symbols
(`a_` vs `a`) does **not** apply inside brackets — every `#b` is just `Slot["b"]`,
so repeated occurrences are symmetric and must agree (first sets the size, the
rest must match), and `#b` shares identity with a bare `b` referenced elsewhere
(the string maps to the symbol `b`). This sidesteps the `Slot[2]`/`#2` integer-slot
hazard (§7.2): named axes never use an integer `Slot`. The matcher still tolerates
the legacy symbol forms `Slot[b_]`/`Slot[b]` (they unify identically), but
`#name` is canonical.

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
   {{a_, Slot["b"]}} :> {{a}}
   ```

6. **Anonymous bracket ellipsis** — `einx.mean("b [...] c", x)`
   ```
   {{b_, SlotSequence[1], c_}} :> {{b, c}}
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
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}
    ```
    `b_` binds in the first operand, bare `b` references it in the second
    — ordinary WL repeated-variable matching, no custom rule needed.

11. **Gather with bracketed immediate** —
    `einx.get_at("b [h w] c, b i [2] -> b i c", x, y)`
    ```
    {{b_, Slot["h"], Slot["w"], c_}, {b, i_, Slot[2]}} :> {{b, i, c}}
    ```
    (a multi-axis bracket `[h w]` is adjacent single brackets — §7.3.)

12. **Shape-preserving, one-sided** — `einx.flip("... (g [c])", x, c=2)`
    ```
    {___, CircleTimes[g_, Slot["c"]]}
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

### 7.2 `Slot` aliasing `Function` slots — largely resolved (named axes are string-keyed)

`Slot[n]` for integer `n` is literally `#n`. Outside a `Function` body it
sits inert; if any bracketed-immediate subexpression were ever spliced into a
`Function`/`&` template and applied, the integer would silently get
reinterpreted as an argument reference instead of a bracketed dimension:

```mathematica
tmpl = {Slot[2], a} &;
tmpl[x, y]      (* {y, a} — silent corruption, no error *)
```

**Resolution.** A bracketed *axis* is now written `#name` = `Slot["name"]` (§5.1)
— a *string* slot, never an integer one — so axes never collide with `Function`'s
positional slots. The only integer `Slot` left is the gather immediate `[2]` =
`Slot[2]`, which is part of the still-deferred gather/scatter path; that case keeps
the explicit `Slot[2]` form and, if gather is built and ever emits `Function`-wrapped
code, is normalized to `Slot["2"]` at that point (the previously-proposed mitigation,
now scoped to just that one construct). The engine already never routes a `Slot`
through an anonymous `Function` (it iterates with `Table`, not `&`/`/@`), and none of
the compilation targets (`Transpose`, `ArrayReshape`, `ArrayReduce`, `Join`, `Inner`,
`Map`) are `Function`s, so even integer immediates do not flow into one today.


### 7.3 `Slot` arity — resolved: brackets are single-axis

A multi-axis bracket `[a b c]` is **identical** to adjacent single brackets
`[a][b][c]` — einx feeds the bracketed axes to the elementary op as one
flattened unit, and the order/grouping of the brackets does not matter (probed
against the venv). So the canonical Einstoff form is one `Slot` per axis:
`[a b]` is written `#a #b` (= `Slot["a"], Slot["b"]`), never `Slot[a_, b_]`. The matcher
still *tolerates* a multi-arg `Slot` harmlessly (it splices `List @@ Slot[...]`
in `matchTerms` / `reduceAtoms`), but that form is non-canonical and not used
in the spec or tests. This retires the former "non-standard arity" concern:
there is no multi-arg `Slot` to guard against, because we never emit one.
(`Slot[]` — bracketed nothing — does not arise.)

### 7.4 Robustness gaps surfaced by code review (2026-06-30)

A review flagged latent robustness issues; the validated ones, with current behaviour
confirmed empirically (none breaks the test suite — they turn *malformed input* into
silent wrong output or fragile invariants):

- **Unknown reducer / map string silently misbehaves** (`reduceFunction` Reduce.wl,
  `mapFunction` Map.wl). A typo like `Einstoff[ArrayReduce]["summ"]` falls through as
  the bare string and is applied as a function — the result is unevaluated `summ[{…}]`
  garbage, *not* `$Failed`. (Map rejects it only by accident, via its shape-preservation
  check.) Fix: reject an unknown string immediately with a clear message. **High value,
  cheap.**
- **Duplicate output axis names produce silent garbage** (`materializeOutput`
  `FirstPosition`, Lowering.wl; same idiom in Dot.wl `contractPair`, Map.wl).
  `{{a_}} :> {{a, c, c}}` resolves shapes (Satisfiable, `{3,2,2}`) but lowering builds
  `InversePermutation[{3,1,1}]` — not a permutation — so the op returns an unevaluated
  `ArrayReshape[Transpose[…]]` rather than a value or a clean error. Fix: validate that
  axis names are unique per shape (and reject duplicates up front).
- **`Symbol[string]` for `#name` axes is `$Context`-sensitive** (matchTerms splice
  Parsing.wl, reduceAtoms Lowering.wl). It works because the desc and the call share a
  context in practice — the same assumption bare-symbol references already make — but the
  invariant is implicit and spread across two files. Fix: centralize into one axis-name
  resolver, ideally context-explicit.
- **Duplicated desc parsing / CirclePlus flattening** in `descParts` (Lowering.wl) and
  `parseDesc`/`flattenDirectSum` (Parsing.wl) — they mirror each other (held vs released
  RHS); future syntax could update one and miss the other. Fix: share the flatten logic.
- **Untagged `Throw[$Failed]`/`Catch`** in shared lowering: in Dot/Inner the user-supplied
  `mul`/`add` run *inside* a `Catch`, so a user function that throws untagged would be
  swallowed as our `$Failed`. Narrow/low-likelihood; tagged throws would isolate it.
- **`Association[bindings]` is unvalidated** (Parsing.wl). Malformed entries degrade to
  later, less-local unsat messages rather than crashing; a small normalization layer would
  localize the error.
- **Dead `Module` locals** `sizes/ends/starts` in `directSumSplit` (the live ones are
  `sz/en/st`). Harmless; remove.

The first two are the priority: they turn bad input into silent wrong output instead of a
clean rejection. To be addressed in a focused cleanup pass, separate from feature work.

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

## 9. Status & next steps

Implemented and cross-validated against einx/einops: the matcher / shape resolver
(`EinstoffShapes`), and the lowering paths `Einstoff[ArrayReshape]`
(rearrange/reshape), `Einstoff[ArrayReduce][reducer]` (reduce, reducer curried),
`Einstoff[Dot]` (einsum contraction over **N ≥ 2 operands** via a pairwise left
fold — `contractPair` keeps the global output axes plus anything a later operand
still needs, so an axis is summed only once nothing downstream uses it), and
uniform repetition (§5.5).

`Einstoff[Inner][mul, add]` generalizes `Dot` (= `Inner[Times, Plus]`): the same
fold with the batched inner product using an arbitrary multiply `mul` and combiner
`add` (cf. WL `Inner`; e.g. `{Plus, Min}` is min-plus/tropical contraction). The
`Times/Plus` case keeps the native `Dot` fast path. Only that case maps to
`einx.dot` for cross-validation; other combiners are checked against native WL
`Inner`. For a semiring `(mul, add)` the N-ary fold is associative; the
left-to-right order is the defined semantics otherwise.

`Einstoff[Map][f]` is the **kept-bracket sibling of `Einstoff[ArrayReduce]`**: a
reduction *drops* the bracketed axes (`f`: block → scalar); a map *keeps* them
(`f`: block → same-length block) and vmaps the op over every unbracketed axis. It
covers einx's shape-preserving miscellaneous ops (flip/roll/sort/softmax/
log_softmax/id) — the bracketed atoms are flattened to one vector (so `[a b]≡[a][b]`)
and handed to `f`, which returns a same-length vector; the axes are kept on the RHS
(dropping one is a reduction → routed to `ArrayReduce`). einx has no generic vmap
entry point, so this single generic operator realizes all of them with `f` supplied.
`f` is any vector→vector function (`Reverse`, `Sort`, a custom map) or a string name
(`"flip"/"sort"/"softmax"/"log_softmax"/"id"`); `roll`'s shift is a parameter, so it
is written `RotateRight[#, k] &`.

The reducer, the map `f` and `(mul, add)` are **curried** into the operator
(`Einstoff[ArrayReduce][Total][…]`, `Einstoff[Map][f][…]`,
`Einstoff[Inner][mul, add][…]`); no operator holds `desc` (uniform convention — §2
note), so a globally bound axis symbol substitutes (a bound integer reads as a
literal dimension; illegal values are rejected by the matcher). The reducer string
set covers **every einx reduction op** (sum/mean/var/std/prod/count_nonzero/any/all/
max/min/logsumexp); `var`/`std` are population (ddof = 0, matching numpy/einx), and
any raw list-reducer (`Total`, `Variance`, a custom function) is also accepted.

**`CirclePlus` (direct sum) — implemented and cross-validated.** The direct-sum
axis `(a + b)` lowers two ways, both folded into `Einstoff[ArrayReshape]` (einx
puts `+` in `id`) and routed by where the CirclePlus appears:

- **Concatenation** (CirclePlus on the RHS, `{op1, …, opk} :> {{… a ⊕ b …}}`; ex4):
  each operand is aligned to the output shape with its own summand block (reusing
  `materializeOutput`, so a scalar operand / integer summand broadcasts — einx's
  `b c, -> b (c + 1)` with 42) and the blocks are `Join`'d along the concat axis.
- **Splitting** (CirclePlus on the LHS, `{{… a ⊕ b …}} :> {out1, …, outk}`; ex3):
  the concat axis is sliced into contiguous blocks (`Take`, output *i* ← summand
  *i*, left-to-right) and each block is rearranged to its output shape; returns a
  `List` of arrays (the multi-output path).

`Einstoff[Join]` (RHS-only) and `Einstoff[Split]` (LHS-only) are the same machinery
under a directional guard. **Nested** direct sums are canonicalized by associativity
(`a ⊕ (b ⊕ c)` → `a ⊕ b ⊕ c`, order preserved since CirclePlus is not Orderless;
`flattenDirectSum` in the shape layer + `descParts`), so both directions accept them.

**Composite summands** (a `CircleTimes` block inside the direct sum, e.g.
`(a⊗b) ⊕ c`) are supported in **both** directions. The matcher
(`solveComposite` in Parsing.wl) builds the factor-size equation `op[…] == d` and
hands it to the Mathematica CAS — `Solve` over positive integers — so a unique
solution binds the axes, multiple solutions are reported underdetermined, and none
is a mismatch. This both subsumes the old single-unknown analytic logic and lets us
*uniquely resolve systems einx rejects* (e.g. `m (a + b)` with an axis of size 2
forces `a = b = 1`). On concat the block is just another term aligned by
`materializeOutput` and `Join`'d; on split the block size is the product over its
atoms (`Take` slice, then reshape). **Still deferred:** bracketed direct sum
(`Slot[CirclePlus[…]]`) and >1 CirclePlus per shape. Plan:
`docs/plans/circleplus-direct-sum.md`.

**Bracket notation — string-named axes (implemented).** A bracketed axis is now
`#name` = `Slot["name"]` (§5.1, §3 glossary), bound by unification on its string
name; the anonymous variadic bracket `[...]` is `##` = `SlotSequence[1]`. This is the
canonical out-facing form used throughout the tests; the legacy `Slot[name_]`/`Slot[name]`
symbol forms are still tolerated (they unify identically). It subsumes the §7.2
integer-slot aliasing hazard for axes (named axes never use an integer `Slot`).
`Einstoff[Map][f]`, the kept-bracket vmap, is also implemented (see above).

**Other deferred lowering items** (rejected loudly today, not mis-compiled):
variable-arity bracket ellipsis `##`/`Slot[___]` (ex6) — the matcher resolves its
shape, but lowering an axis-count-varying bracket is deferred; named-ellipsis /
`Repeated[...]` re-walk (§5.3); within-operand reduction before contraction in
`Einstoff[Dot]`.

**Long-term TODO (heavily deferred — do not pursue now) — CI policy for the Python
cross-validation suite.** When CI exists: the `tests/python/*.wlt` einx/einops
cross-tests must *not* be required status checks (opt-in; need a Python venv); and
when run they should be auto-retried up to **3×**, a pass on **any** attempt
counting as a pass — to absorb the intermittent ZMQ `0xC0000005` startup segfault
(the cross-validation logic is deterministic; only session startup is flaky).

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
