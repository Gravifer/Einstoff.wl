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
matching do double duty as both parser and shape matcher.

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
| Named dimension (blank — infer-only) | `a` | `a_` | `Pattern[a, Blank[]]` |
| Named dimension (reference / env-capture) | `a` (repeated) | `a` | bare symbol |
| Named dimension (string tier — fully hygienic) | `a` | `"a"` | a `String` (a valid identifier) — see §5.6 |
| Integer immediate | `2` | `2` | literal integer |
| Anonymous dimension | `_` | `_` | `Blank[]` |
| Ellipsis (anonymous) | `...` | `___` | `BlankNullSequence[]` |
| Ellipsis (anonymous, ≥1) | — | `__` | `BlankSequence[]` |
| Named axis-sequence (capture repeated axes) | `a...` | `a__` / `a___`; `a : pattern..` for structured terms | `Pattern[a, BlankSequence[]]` / `Pattern[a, BlankNullSequence[]]`; `Pattern[a, Repeated[pattern]]` for structured terms |
| Named axis-sequence inner mvar (destructuring template, see §5.3) | inner names in `(pattern)...` | names inside `term..` / `term...` | — (provisional) |
| Product / axis composition | `(a b)` | `a ⊗ b` | `CircleTimes` |
| Direct sum / concatenation | `(a + b)` | `a ⊕ b` | `CirclePlus` |
| Targeted string axis | `[a]` | `#a`, highlighted/framed `"a"` | `Slot["a"]`, `Highlighted["a"]`, or `Framed["a"]` — targeted string spelling; kept with the same target head on the RHS when the targeted axis is kept |
| Targeted blank axis | `[a]` | highlighted/framed `a_` | `Highlighted[a_]` or `Framed[a_]` — visually targeted blank; RHS references it as bare `a` |
| Targeted bare axis | `[a]` | highlighted/framed `a` | `Highlighted[a]` or `Framed[a]` — visually targeted bare reference; bind with `a -> n` or the matching target-head key when needed |
| Multiple targeted axes | `[a b]` ≡ `[a][b]` | `#a #b` | `Slot["a"], Slot["b"]` — adjacent single targeted string axes, `[a b]≡[a][b]`, see §7.3 |
| Targeted anonymous ellipsis | `[...]` | `##` | `SlotSequence[1]` |
| Targeted literal | `[2]` | `Slot[2]`, `Highlighted[2]`, `Framed[2]` | targeted literal; `#2` is `Slot[2]`, see §7.2 |

## 4. Grammar

### 4.1 Shape

A *shape* is a `List` of dimension terms. A dimension term is one of:

- a bare symbol (reference / env-capture) or `name_` (blank, infer-only)
- a `String` `"a"` (a hygienic named axis — must be a valid identifier; §5.6)
- an integer
- `_`, `__`, `___`
- `name__` / `name___` (named axis-sequence), `name : term..` /
  `name : term...` (structured named axis-sequence), or bare `term..` /
  `term...` (anonymous structural sequence)
- `CircleTimes[term, term, ...]` (product)
- `CirclePlus[term, term, ...]` (direct sum)
- `Slot[term, ...]`, `Highlighted[term, ...]`, or `Framed[term, ...]` wrapping any
  of the above (targeted; einx spells this with brackets), nestable at any depth inside `CircleTimes`/
  `CirclePlus`/`Repeated`. Targetedness is orthogonal to the spelling inside the
  wrapper: blank `a_` still means infer-only, bare `a` is bindable/reference-like, and
  string `"a"` is the hygienic string tier. `Slot["a"]`, `Highlighted["a"]`, and
  `Framed["a"]` are targeted string spellings; `Slot[...]` is reserved for string-kind
  targets, while `Highlighted[...]` and `Framed[...]` also provide visually targeted
  blank/bare symbol spellings. `Squiggled[...]` is intentionally not used because it is
  visually confusing in the frontend.

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
enough across the grammar (any named axis-sequence combination), `:>` is used
uniformly rather than switched per-operation.

Two sugars are allowed at the *call-site* (front-end), not in the core
grammar:

- a single shape `{...}` may stand in for `{{...}}` when there is exactly
  one input/output tensor
- a one-sided shape `{...}` (no `RuleDelayed`) for shape-preserving ops,
  normalized internally to `{...} :> {...}` before reaching the core engine

## 5. Semantics

### 5.1 Blank vs. Reference

`a_` is a blank and infers a size; a bare `a` later in the *same* match (e.g. the
second operand's shape, or the RHS) is a reference and must match that inferred
size. This is not bespoke Einstoff logic — it is
exactly how repeated pattern variables already behave in `MatchQ`/`Cases`
(`MatchQ[{3, 3}, {x_, x}]` only succeeds because both `3`s agree). It is what
makes shared/contracted axes across tensors (§6.10) fall out for free.

New axes that appear only on the RHS (repeat-style) are *not* covered by
this mechanism, since there is nothing on the LHS to bind them to — those
are resolved from an out-of-band `sizeRules`-style argument instead.

A named axis has two orthogonal coordinates: spelling kind (`b_` blank,
bare `b`, or string `"b"`) and targetedness (plain or targeted). The targeted
string spelling is `#name` (= `Slot["name"]`) and binds by *unification* on its
string name: repeated occurrences are symmetric and must agree (first sets the
size, the rest must match). Because this spelling is string-kind and targeted, a
kept targeted string axis must stay targeted on the RHS (`{{a_, #b}} :> {{a, #b}}`);
writing bare `b` mixes spelling kind and is rejected. Targeted blank/bare symbol
spellings use `Highlighted[...]` or `Framed[...]`: `Highlighted[b_]` infers a
targeted blank axis, while `Highlighted[b]` is a targeted bare reference/bindable
axis. `Highlighted["b"]` and `Framed["b"]` are also targeted string axes, with a
different visual target head. `Slot` is reserved for string-kind targeting; use
`Highlighted`/`Framed` for targeted blank or bare symbol axes. `#name` sidesteps the
`Slot[2]`/`#2` integer-slot hazard (§7.2): named axes never use an integer `Slot`.

### 5.2 Reduce vs. elementary-op: targetedness disambiguates

"Axis present on LHS, absent on RHS" is ambiguous by itself — it could mean
(a) classic reduction with a user-supplied function (einops `reduce`), or
(b) the axis is fed whole into an elementary operation and everything else
is vmapped (einx bracket semantics). Targeted wrapper presence is the only thing
distinguishing these, so the compiler must branch on targetedness
explicitly; it cannot be inferred from set difference between LHS/RHS axis
names alone.

### 5.3 Named ellipsis: where the name lives matters

**Shape resolver implemented; data lowering deferred.** `EinstoffShapes` and
`EinstoffMatch` understand named axis-sequences (`a__` / `a___`, and structured
`grp : term..` / `grp : term...`) and re-walk their captures manually. Runtime
lowerers reject raw descs containing named axis-sequences today, because
operation-specific lowering for data arrays is not implemented yet.

Two roles a name can play inside an ellipsis:

- **Outer mvar** (`name__`, `name___`, or `name : pattern..`) — binds the *entire captured
  `Sequence`*; `{name}` listifies it.
- **Inner mvar** (a named sub-pattern inside a structured `term..`,
  e.g. `grp:(a:(_Integer|_Symbol))...`) — a destructuring template. The shape
  resolver re-walks `{grp}` element-by-element applying the inner pattern, producing a
  per-repetition binding list `{a} = {a<sub>1</sub>, a<sub>2</sub>, ...}`.

Cross-group consistency (e.g. `Length[{a}] == Length[{b}]` before a
`MapThread`) should be enforced by the engine during the manual binding phase, not
pushed into individual `RuleDelayed` RHS bodies.

**Provisional:** WL's stock implementation of repeated patterns enforces that all
repetitions unify to the same value. The resolver ignores that constraint and
re-drives matching manually. Safe while no compilation target delegates axis-sequence
matching back to native WL pattern matching; revisit if one does.

### 5.4 Size resolution

For named ellipses, scalar axis bindings remain ordinary positive integers in the
public `Bindings` association. Outer and inner ellipsis captures are private resolver
state used to evaluate the `RuleDelayed` RHS: outer mvars listify the captured
structural terms, and inner mvars listify the per-repetition sizes. The public
shape API does not expose those list-valued captures as stable bindings.

### 5.5 Repetition as uniform vectorization

Following einx, **repetition is not a distinct operation** but a form of
vectorization layered on the output of *any* operator. An axis present on the
RHS but absent from the LHS is *materialized by broadcasting*: each existing
element is replicated along the new axis. Its size cannot come from input-axis
binding (nothing on the LHS constrains it), so it is supplied out of band via
`bindings` (cf. §5.1), mirroring einx's `c=3` keyword. This applies uniformly
to `Einstoff["Massage"]` (≙ einops.repeat / einx.id with an output-only
axis), `Einstoff[ArrayReduce]`, and `Einstoff[Dot]` — there is **no** separate
repeat operator (and no `ArrayRepeat`, which is not a WL builtin). The bijective
`Einstoff[ArrayReshape]` guard is the one entrance that *rejects* an output-only
size > 1 axis (repetition is not a count-preserving reindexing). The op symbol
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

### 5.6 Evaluation hygiene and the axis-name spelling matrix

A desc is an *ordinary WL expression*, so a global binding of an axis symbol
(`Block[{c = 3}, …]`) would leak its value into the axis identity — turning axis
`c` into the literal `3`, corrupting shapes and (as an `Association` key) the size
environment. Einstoff removes this hazard by **canonicalizing every axis identity at
the desc boundary** to a fresh, value-less `Temporary` symbol *before* any downstream
code inspects it. A *named* axis has a spelling kind (blank, bare, string) and an
orthogonal targeted bit:

| Kind | Plain WL | Targeted WL | Role | Hygiene |
|---|---|---|---|---|
| blank | `a_` | `Highlighted[a_]` / `Framed[a_]` | infer-only | safe (canonicalized) |
| bare | `a` | `Highlighted[a]` / `Framed[a]` | reference to an *established* axis, else env-capture; bindable when explicit size is needed | opt-in: a bound `a` reads as its literal size |
| string | `"a"` | `#a` = `Slot["a"]`, `Highlighted["a"]`, `Framed["a"]` | fully-hygienic named axis; targeted form marks the elementary-op axis (§5.2) | immune to any `Block` |

**Established vs. captured.** A bare symbol is an axis *reference* only if its name is
**established** — spelled somewhere in the desc as blank `a_`, targeted blank
`Highlighted[a_]`/`Framed[a_]`, targeted/bare `a`, targeted string `#a`, or string
`"a"`. An *unestablished* bare symbol env-captures: it evaluates, so a globally
bound `k` reads as its literal dimension (`{{a_, k}} :> {{a}}` with `k = 4` reduces a
size-4 axis) and an unbound one is an ordinary (unsafe) axis. This holds symmetrically
on LHS and RHS — a bare RHS name is **not** automatically hygienic just because `:>`
holds it; it is a reference iff established, else a captured value. (The desc's own
`a_` on the LHS ↔ bare `a` on the RHS is WL's native `x_ :> f[x]` idiom: declare as a
blank, use as bare.)

> **Note — env-capture of a string value.** Since a `String` is now a legal axis
> spelling, an unestablished bare symbol that env-captures to a *string* becomes that
> (string-kind) axis rather than being rejected. E.g. `Block[{k = "oops"}, {{a_, k}} :>
> {{a}}]` treats `"oops"` as an axis and reduces over it, where a pre-string-tier engine
> rejected the stray non-size key. This is the intended, consistent consequence of
> the bare = env-capture rule meeting the string kind — a bound symbol reads as whatever
> it evaluates to (an integer → a literal dim; a valid-identifier string → that axis). To
> get a *checked* stray-binding rejection, spell the axis hygienically (`a_` / `#a` /
> `"a"`) so the name cannot be captured.

**No mishmash.** A single name may not mix spelling kinds within one desc: blank/bare
symbol spellings (`a_`, `a`, `Highlighted[a_]`, `Highlighted[a]`, and `Framed[...]`
counterparts) cannot be mixed with string spellings (`"a"`/`#a`). Targetedness itself is
orthogonal: mixing plain and targeted forms of the same spelling kind is allowed when
the operator semantics allow the targeted axis to be kept or consumed.

**Contexts are ignored.** Axis identity is the axis *name*, not the Wolfram Language
context of the symbol used to spell it. Thus ``Foo`a_``, ``Bar`a_``, and `a_`
all denote the same blank-kind surface name `a`; `"a"` and `#a` denote the
string-kind surface name `a` (subject to the mishmash rule above).
This is deliberate: axis names in the eDSL are small local labels, not WL namespace
entities. If a desc needs so many axis names that contexts look necessary to avoid
collisions, the desc should be refactored or use clearer local names instead of
expecting contexts to carry semantic identity.

**Canonicalization.** Each established name is rewritten to one fresh
`Unique[name <> "$", {Temporary}]` symbol shared across all its occurrences (blank,
bare reference, targeted form, binding key); the symbols are per-parse hermetic and GC'd when the
parse scope closes. Names *inside a targeted composite* (`Highlighted[(c d)]` =
`Highlighted[CircleTimes[c_, d_]]`) are grammar positions and are canonicalized too. A string
name must be a valid identifier (a locally-rolled `validAxisNameQ` — not the cloud
`ResourceFunction["ValidSymbolIdentifierQ"]`, which is unavailable/slow in some
kernels). Public output (`EinstoffParse`; `EinstoffShapes`' `Bindings`/`Targeted`) is
mapped back to the user's names for display; a *shadowed* name maps to a value-less
`Einstoff`Axis`nm` (still `SymbolName`-recoverable) rather than leaking its value.

Implementation: `canonHeld` / `collectEstablished` / `canonBindingList` / `deCanon` in
Lowering.wl, opened per operator by `withAxisScope`; the functional/backtracking
matcher is untouched (it simply sees fresh symbols). Tests: `tests/Hygiene.wlt`.

### 5.7 Binding-key grammar

`bindings` supplies sizes for axes not inferable from the tensors (repetition §5.5,
composite split-factors). A key names an axis; accepted spellings mirror the desc
spelling kind and are canonicalized to the axis's fresh identity:

- **Target-head keys** (`#a -> n`, `Highlighted["a"] -> n`, `Framed["a"] -> n`,
  `Highlighted[a] -> n`, `Framed[a] -> n`) — accepted only when the desc used the same
  target head for axis `a`.
- **`a -> n`** (bare symbol key) — binds a bare or targeted bare axis; convenient but
  unsafe because a shadowed `a` evaluates before we see it (`{a -> 2}` under `a = 3`
  arrives as `{3 -> 2}`).
- **`"a" -> n`** (string key) — works for any string-kind axis, plain or targeted.
- **`->` and `:>`** are accepted indistinguishably for any non-`Pattern` key (the size
  is a concrete value; the arrow is moot).

Rejections and tolerances:

- A **`Pattern` key** `a_ -> n` / `a_ :> n` is a category error (a matcher, not a name)
  — **hard reject** with a redirect (do not silently ignore, which would let a
  whole-axis blank be "bound" and still succeed by tensor inference).
- A **blank** `a_` is **inference-only**, plain or targeted and whether it is a
  whole axis or a composite factor: binding it is rejected. Spell an externally supplied
  split factor as a bare axis (`a`) or string axis (`"a"`) instead.
- A cross-**kind** key (a string axis bound by a symbol key, or vice versa) is rejected.
  A target-head key with a different head than the desc's targeted spelling is also
  rejected.
- An **evaluated / junk key** (a non-name, e.g. the integer `3` from a shadowed
  `c = 3`) **warns and is dropped**, and resolution continues — failing only if the
  shapes are then unsatisfiable. The warning is targeted when the key equals the
  current value of a desc axis.

Tests: `hyg-*` (`tests/Hygiene.wlt`); `bindings-*` (`tests/Parsing.wlt`).

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
   {{a__}, {b__}} :> {MapThread[CircleTimes, {{a}, {b}}]}
   ```
   Resolved by `RuleDelayed` (§7.1): `{a}`/`{b}` listify the captured
   `Sequence`s, `MapThread` zips them. Cross-group length consistency
   (`Length[{a}] == Length[{b}]`) is enforced by the engine's manual
   binding phase (§5.3).

8. **Named ellipsis with internal structure (pooling)** —
   `einx.sum("b (s [ds])... c", x, ds=(2, 2))`
   ```
   {{b_, grp : (CircleTimes[s_, Slot[ds_]]).., c_}} :> {Join[{b}, Map[First, {grp}], {c}]}
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

11. **Indexing-style gather with targeted literal** —
    `einx.get_at("b [h w] c, b i [2] -> b i c", x, y)`
    ```
    {{b_, Slot["h"], Slot["w"], c_}, {b, i_, Slot[2]}} :> {{b, i, c}}
    ```
    (a multi-axis einx bracket `[h w]` is adjacent single targeted axes — §7.3.
    In WL, targeted literals may be spelled `Slot[2]`, `Highlighted[2]`, or
    `Framed[2]`; the indexing-style lowering itself remains deferred.)

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
sits inert; if any targeted-literal subexpression were ever spliced into a
`Function`/`&` template and applied, the integer would silently get
reinterpreted as an argument reference instead of a targeted dimension:

```mathematica
tmpl = {Slot[2], a} &;
tmpl[x, y]      (* {y, a} — silent corruption, no error *)
```

**Resolution.** A targeted *axis* is now written `#name` = `Slot["name"]` (§5.1)
— a *string* slot, never an integer one — so axes never collide with `Function`'s
positional slots. Targeted literals may be written `Slot[2]`, `Highlighted[2]`, or
`Framed[2]`; the integer `Slot` spelling is retained because it is the direct WL
counterpart of einx `[2]`. Targeted literals already work for operations whose
einx counterpart accepts them (for example `ArrayReduce` over `a [2] -> a`).
What remains deferred is not the literal syntax but indexing-style gather/scatter
lowering such as `get_at`, where `[2]` is an index-vector axis. If that lowering is
built and ever emits `Function`-wrapped code, integer `Slot[2]` should be normalized
to `Slot["2"]` at that point (the previously-proposed mitigation, now scoped to that
construct). The engine already never routes a `Slot`
through an anonymous `Function` (it iterates with `Table`, not `&`/`/@`), and none of
the compilation targets (`Transpose`, `ArrayReshape`, `ArrayReduce`, `Join`, `Inner`,
`Map`) are `Function`s, so even integer immediates do not flow into one today.


### 7.3 Target arity — resolved: einx brackets are single-axis groups

A multi-axis einx bracket `[a b c]` is **identical** to adjacent single brackets
`[a][b][c]` — einx feeds the targeted axes to the elementary op as one
flattened unit, and the order/grouping of the brackets does not matter (probed
against the venv). So the canonical Einstoff form is one `Slot` per axis:
`[a b]` is written `#a #b` (= `Slot["a"], Slot["b"]`), never `Slot[a_, b_]`. The matcher
still *tolerates* a multi-arg `Slot` harmlessly (it splices `List @@ Slot[...]`
in `matchTerms` / `reduceAtoms`), but that form is non-canonical and not used
in the spec or tests. This retires the former "non-standard arity" concern:
there is no multi-arg `Slot` to guard against, because we never emit one.
(`Slot[]` — bracketed nothing — does not arise.)

### 7.4 Robustness gaps surfaced by code review (2026-06-30)

A review flagged latent robustness issues; behaviour confirmed empirically. **All are now
fixed** (2026-06-30 – 2026-07-02); none ever broke the suite — they were fragile
invariants / maintainability smells. Retained here as a record of the hardening:

- ✅ **Unknown reducer / map string** (`reduceFunction` Reduce.wl, `mapFunction` Map.wl)
  — *fixed.* A typo like `Einstoff[ArrayReduce]["summ"]` used to fall through as the bare
  string and be applied as a function (`summ[{…}]` garbage). Both resolvers now return
  `Missing["Unknown…", s]` for an unrecognized name and the operators reject it with a
  clear message listing the valid names. (Reject tests: `reduce-reject-unknown-string`,
  `map-reject-unknown-string`.)
- ✅ **Duplicate output axis names** (`EinstoffShapes`, Parsing.wl) — *fixed.*
  `{{a_}} :> {{a, c, c}}` used to resolve shapes and then build a bad
  `InversePermutation[{3,1,1}]`, returning an unevaluated `ArrayReshape[Transpose[…]]`.
  `EinstoffShapes` rejects any axis name that repeats *within the output shape (RHS)* as
  unsatisfiable — a universal invariant (a duplicate output axis has no layout), mirroring
  einx's `SemanticError: "the output expression must not contain multiple vectorized axes
  with the same name"` (verified against the venv — einx raises rather than replicating).
  A name repeated *within an input shape* is **not** rejected here: that is within-tensor
  contraction, which the resolver handles by unification and which `Massage`/
  `ArrayContract`/single-tensor `einsum` lower; its admissibility is per-operator policy
  (the non-contracting reduce/map/dot/direct-sum paths reject it themselves via
  `distinctAxesQ`). `firstDuplicateAxis`/`termAxisNames`/`distinctAxesQ` helpers; tests
  `reject-duplicate-output-axis` (RHS reject) and `accept-repeated-input-axis` (LHS now
  resolves). Distinct-across-shapes (shared/contracted/kept axes) is unaffected. (A single
  new RHS axis still broadcasts — §5.5 repetition — only a *repeated name* is rejected.)
- ✅ **`Symbol[string]` for `#name` axes was `$Context`-sensitive** — *fixed.* The old
  resolver `resolveSlotStrings` mapped each `#name` bracket to the desc-local symbol
  for that name instead of `Symbol["name"]` in the live `$Context`, so adversarial
  `$Context` no longer broke bracket matching. Demonstrated by
  `bracket-context-robust`. env stays symbol-keyed, so the CAS/`Solve` layer is
  untouched.
  **Superseded (2026-07, desc-hygiene branch, §5.6):** `resolveSlotStrings` was replaced
  by `canonHeld`, which canonicalizes *every* axis identity — blank, targeted, string —
  to a fresh `Temporary` symbol, so the `Block[{c=3},…]` value-leak (not just the
  `$Context` variant) is closed, and a string axis tier `"a"` is added. `#a` now belongs
  to that string kind, while targeted blank/bare symbol axes use `Highlighted[...]` or
  `Framed[...]`.
  The new canonicalizer intentionally keys identities by `SymbolName`, not full symbol
  context: contexts are not part of axis identity in this eDSL.
- ✅ **Duplicated desc normalization** across `descParts` (Lowering.wl) and `parseDesc`
  (Parsing.wl) — *fixed.* The `{} -> 1` unit policy and the CirclePlus-flatten rule (which
  were written out three times: `flattenDirectSum`, `normHeldRhs`, and inline in
  `descParts`) are now single shared canonicalizers in the hub: `flattenDirectSum` +
  `normShapes` (released) / `normHeldShapes` (held, `{} -> 1` at levels `>= 3`). Both desc
  boundaries route through them, so the two forms differ only in held (parseDesc) vs
  released (descParts) RHS and cannot drift. `normHeldRhs`/`flattenDirectSum` no longer
  live in Parsing.wl. Suite unchanged (246 green).
- ✅ **Untagged `Throw[$Failed]`/`Catch`** in shared lowering — *fixed.* Several paths run
  *user-supplied* functions inside a caught region (Inner's `mul`/`add`, ArrayReduce's
  reducer, Map's `f`), so a user function that threw untagged would be swallowed by our bare
  `Catch` and mistaken for the `$Failed` sentinel. Every internal throw/catch is now scoped
  to a package-private tag: helpers `Throw[$Failed, einThrowTag]`, operators recover with
  `einCatch` (a `Catch[expr, einThrowTag]`, HoldFirst). An untagged (or differently-tagged)
  user throw now propagates out unchanged. Regression test `inner-user-throw-propagates`
  (a combiner that throws must escape our control flow, not be returned as a result).
- ✅ **`Association[bindings]` is unvalidated** (Parsing.wl) — *fixed.* `EinstoffMatch`
  now validates `bindings` at the entrance: it must be a list of axis-name -> size rules
  (a bare `Symbol` key, a positive-integer size; `Rule` or `RuleDelayed`; the default `{}`
  is vacuously valid). A malformed spec (a non-rule entry, a non-symbol key, or a
  non-positive/non-integer size) now returns a local `ok -> False` reason here rather than
  degrading into a deeper unsat message or leaking an unevaluated `Association[...]`
  through `matchTerms`. A **duplicate key** is also rejected outright (a follow-up review
  edge: `Association` would silently keep the last value, so `{c -> 2, c -> 99}` and
  `{c -> 99, c -> 2}` would differ order-dependently with no diagnostic). Nine regression
  tests (`bindings-reject-*`, `bindings-ruledelayed-ok`).
- ✅ **Dead `Module` locals** `sizes/ends/starts` in `directSumSplit` — *removed* (the live
  ones, `sz/en/st`, live in the inner block `Module`).

All §7.4 review items are now resolved: the two silent-wrong-output items, the
context-sensitive axis resolver, the duplicated desc normalization, bindings validation,
the tagged-throw isolation, and the dead `directSumSplit` locals.

## 8. Resolved / verified (no further action needed)

- `CirclePlus`/`CircleTimes` have no built-in evaluation rules for symbolic
  or numeric arguments — safe to use as inert semantic tags.
- Bare-vs-`_` for binding/reference is stock WL pattern behavior, not
  bespoke logic (§5.1).
- Top-level grammar is unconditionally list-of-shapes both sides, connected
  by `RuleDelayed` (§4.2); single-tensor and one-sided forms are front-end
  sugar only.
- `Slot[...]` nests without issue inside `CircleTimes` and `CirclePlus`.
- The named axis-sequence design does not need a separate output-derivation interface:
  the shape resolver evaluates `RuleDelayed` RHS code after substituting captured
  sequences, so ordinary WL helpers can project them.

## 9. Status & next steps

Implemented and cross-validated against einx/einops: the matcher / shape resolver
(`EinstoffShapes`), and the lowering paths `Einstoff["Massage"]` (the permissive
univalent engine) with its intent guards `Einstoff[ArrayReshape]` (bijective
rearrange/reshape) and `Einstoff["ArrayContract"]` (within-tensor contraction, no
repetition), `Einstoff[ArrayReduce][reducer]` (reduce, reducer curried),
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

`Einstoff[Map][f]` is the **kept-target sibling of `Einstoff[ArrayReduce]`**: a
reduction *drops* the targeted axes (`f`: block -> scalar); a map *keeps* them
(`f`: block -> same-length block) and vmaps the op over every untargeted axis. It
covers einx's shape-preserving miscellaneous ops (flip/roll/sort/softmax/
log_softmax/id), but the generic Wolfram contract is broader: the selected target
axes are presented to `f` as a rectangular Wolfram subarray/block, preserving nested
list structure, and `f` must return a block with the same dimensions. Adjacent
targets (`[a][b]` / `#a #b`) select one target block, not separate passes; raw
functions therefore follow Wolfram expression semantics (`Reverse`, `Sort`, custom
maps, etc.) rather than einx's per-op arity restrictions. The axes are kept on the
RHS (dropping one is a reduction → routed to `ArrayReduce`). `roll`'s shift is a
parameter, so it is written with an explicit function such as `RotateRight[#, k] &`.

The reducer, the map `f` and `(mul, add)` are **curried** into the operator
(`Einstoff[ArrayReduce][Total][…]`, `Einstoff[Map][f][…]`,
`Einstoff[Inner][mul, add][…]`); no operator holds `desc` (uniform convention — §2
note), so a globally bound axis symbol substitutes (a bound integer reads as a
literal dimension; illegal values are rejected by the matcher). The reducer string
set covers **every einx reduction op** (sum/mean/var/std/prod/count_nonzero/any/all/
max/min/logsumexp); `var`/`std` are population (ddof = 0, matching numpy/einx), and
any raw list-reducer (`Total`, `Variance`, a custom function) is also accepted.

**`CirclePlus` (direct sum) — implemented and cross-validated.** The direct-sum
axis `(a + b)` lowers two ways, both folded into the permissive `Einstoff["Massage"]`
(einx puts `+` in `id`; the bijective `Einstoff[ArrayReshape]` guard rejects a direct
sum — use `Einstoff[Join]`/`[Split]` or `Massage`) and routed by where the CirclePlus
appears:

- **Concatenation** (CirclePlus on the RHS, `{op1, …, opk} :> {{… a ⊕ b …}}`; ex4):
  each operand is aligned to the output shape with its own direct-sum summand
  combination (reusing `materializeOutput`, so a scalar operand / integer summand
  broadcasts — einx's `b c, -> b (c + 1)` with 42) and the blocks are `Join`'d
  along the direct-sum axes. Multiple top-level direct-sum axes enumerate their
  Cartesian product, matching einx's positional order (last axis fastest).
- **Splitting** (CirclePlus on the LHS, `{{… a ⊕ b …}} :> {out1, …, outk}`; ex3):
  the direct-sum axes are sliced into contiguous Cartesian blocks (`Take`, output
  *i* ← summand-combination *i*, left-to-right with the last axis fastest) and each
  block is rearranged to its output shape; returns a `List` of arrays (the
  multi-output path).

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
atoms (`Take` slice, then reshape). Targeted direct sums
(`Highlighted[CirclePlus[…]]` / `Framed[CirclePlus[…]]`, and `Slot[CirclePlus[…]]`
for string-only summands) are rejected by `Einstoff[ArrayReduce]` and `Einstoff[Map]`:
feeding a structural concatenation as one elementary-operation target is semantically
ambiguous, matching einx's rejection of bracketed concatenation. Structural
`Join`/`Split` syntax intentionally remains the bare `CirclePlus` form. The structural
direct-sum gap that remains deferred is equal repeated
summands such as `b (q + q) -> b q, b q` (the distinct-axis policy rejects this
today). Historical plan: `.agents/plans/circleplus-direct-sum.md`.

**Target notation — string-named axes (implemented).** A targeted string axis is now
`#name` = `Slot["name"]` (§5.1, §3 glossary), bound by unification on its string
name; the anonymous variadic bracket `[...]` is `##` = `SlotSequence[1]`. This is the
canonical out-facing form used throughout the tests; the legacy `Slot[name_]`/`Slot[name]`
symbol forms are still tolerated (they unify identically). It subsumes the §7.2
integer-slot aliasing hazard for axes (named axes never use an integer `Slot`).
`Einstoff[Map][f]`, the kept-bracket vmap, is also implemented (see above).
Plain anonymous sequences (`__` / `___`) lower as non-targeted carried/vmapped
axis runs when kept on the output. The implemented subset is one plain anonymous
sequence per shape; matching multiple unnamed plain sequences in one shape is
deferred because deciding which capture corresponds to which output occurrence
needs a real matching policy beyond `Longest` / `Shortest`. Targeted variadic runs (`##`,
`Highlighted[__]`, `Highlighted[___]`, etc.) remain the spelling for feeding a
captured run to `ArrayReduce` / `Map`.

**Other deferred lowering items** (rejected loudly today, not mis-compiled):
named axis-sequence data lowering (§5.3); within-operand reduction
before contraction in `Einstoff[Dot]`.

**Within-tensor contraction — pairwise core implemented.** A name repeated in one
operand and dropped on the output is summed over its coincident slots (GR-style traces,
e.g. Ricci `R^a{}_{bad}`), which einx cannot express but `einops.einsum`/`np.einsum` and
WL can. Lowered by `selfContract` (Lowering.wl) via
`ResourceFunction["ArrayContract"][x, pairs, Plus, ArrayDepth[x]]` (the explicit depth is
required — the 3-arg form mis-levels). Exposed two ways:
- `Einstoff["Massage"]` / `EinstoffMassage` (Reshape.wl) — the **univalent** (single-
  tensor) structural engine: rearrange + repeat + direct sum **and** within-tensor
  contraction. It sizes via `EinstoffMatch` (not `EinstoffShapes`) so a within-tensor
  repeat is allowed, while the shape-layer uniqueness check still protects reduce/map.
- `Einstoff["einsum"]` / `EinstoffEinsum` (Einsum.wl) — the pairwise-contraction subset:
  1 tensor → Massage, ≥2 → the `Dot` cross-tensor fold; rejects repetition and the mixed
  multi-operand case (deferred). Cross-validated against `einops.einsum`.

Only *pairwise* is supported (the tensorial case): a kept repeat (diagonal `aa->a`), an
axis occurring `>2` times (super-diagonal, non-tensorial — `EinsteinSummation` also caps
at 2), and a single dropped index (plain sum-reduction → `Einstoff[ArrayReduce]`) are all
rejected. **Deferred:** the combiner generalization (`ArrayContract[…, add]` /
`Tr[…, add]`, mirroring `Einstoff[Inner]`); diagonal-keep; mixed within+cross multi-
operand einsum; and the bracket/composite interactions. Analysis:
`docs/within-tensor-contraction.md`.

**Entrance re-architecture (done).** `Einstoff["Massage"]` is the permissive engine; the
named entrances are now intent guards over one shared core (`massageCore` in Reshape.wl),
each a policy that admits only the features it declares (element counts, single tensor):
- `Einstoff[ArrayReshape]` / `EinstoffReshape` — **bijective**: an element-count-preserving
  reindexing (permute/split/merge + unit-axis insert/squeeze + scalar↔singleton). It
  rejects repetition (an output-only axis of size > 1), within-tensor contraction,
  reduction, and direct sum, each with a message naming the guard and the right entrance.
- `Einstoff["ArrayContract"]` / `EinstoffContract` — **no repetition**: everything
  ArrayReshape allows *plus* a within-tensor pairwise contraction. It rejects repetition
  and direct sum; a plain single-index sum-reduction stays out of scope (`ArrayReduce`).
- `Einstoff["Massage"]` — permissive (also repetition and direct sum).
- `Einstoff["einsum"]` — the pairwise-contraction dispatcher (1 tensor → the contraction
  entrance semantics, ≥2 → the Dot fold).

The repetition / direct-sum test sites that formerly rode on `Einstoff[ArrayReshape]`
migrated to `Einstoff["Massage"]`; `tests/ArrayContract.wlt` covers the new guard, and
`tests/Reshape.wlt` asserts the bijective entrance now rejects those descs. Design note:
`.agents/plans/entrance-guards.md`. A future cross-tensor backend parallel to the univalent
Massage — working name **`EinstoffTandem`** — would unify the `Dot`/`Inner` structural
role under the same metaphor (potential TODO). **Remaining feature-roadmap work:** the
combiner generalization (`ArrayContract[…, add]` / `Tr[…, add]`), diagonal-keep, and mixed
within+cross multi-operand einsum.

**Validation policy (settled, not a deferred CI project).** Contributors are expected
to run the default Wolfram-only suite locally before submitting a PR/MR. Public hosted
CI is not a near-term goal because `wolframscript` requires a ready Wolfram system and
the public-runner story is mostly license / installer ceremony for little gain. The
Python cross-validation suite remains opt-in (`run-tests.wls python`), useful for
maintainers and larger lowering changes, but not required status. If Python/ZMQ session
startup flakes on Windows (`0xC0000005` has been observed), retrying locally is fine;
the cross-validation logic is deterministic once the session starts.

**Deferred post-publication CI/CD integration.** After the project is published as a
public repo, setting up Wolfram/PacletCICD-style automation may be opened as a
help-wanted issue. This is intentionally separate from the settled local-validation
policy above: do not spend near-term implementation effort on CI/CD plumbing before
publication.

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
the implemented lowering — nested name-binding and surface forms without a Python
equivalent — is explicitly **not** required to agree until that lowering exists.
Targeted direct sums are rejected in line with einx: use bare `CirclePlus` for
structural `Join`/`Split`, not as a single reduce/map target.

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
