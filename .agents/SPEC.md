# Einstoff — Spec

Replicating einsum / einops / einx for Wolfram Language, using native pattern
objects (`Pattern`, `Blank`, `CirclePlus`, `CircleTimes`, `Repeated`, `Slot`)
as an embedded surface notation rather than an opaque string grammar. The held
surface expression is compiled into a private, inert, staged IR; native pattern
objects are not the semantic AST after capture.

Status: normative language specification with an incremental staged-compiler
migration. Section 7 records remaining language/lowering limits and must be read
as part of the spec, not as an appendix.

---

## 1. Motivation

einops gives Python a readable notation for permute/reshape/reduce/repeat.
einx extends it with multi-tensor einsum-style contraction, named/bracketed
sub-tensor signatures, ellipses, and direct-sum (concatenation) axes.

Both represent everything as a single opaque string that gets parsed
internally. Wolfram Language already ships a pattern-matching vocabulary
that maps closely onto the *concepts* einx needs (named binding, anonymous
wildcard, repetition, sequence). Einstoff uses that vocabulary as its surface
syntax and preserves a simple conceptual mapping back to WL patterns. Capture
then translates it to logical axis identities and explicit constraints. No
post-capture stage delegates language semantics to `MatchQ`, native pattern
variable binding, or rule evaluation.

## 2. Design principles

- The top level is a standard `List`, not a string.
- An operation canonically uses `RuleDelayed`: `lhs :> rhs`. Its WL role is to
  protect the RHS while the descriptor expression is constructed and to model
  resolution after the complete LHS scope is known. Einstoff does **not** release
  the rule to obtain substitutions or derive output shapes.
- `Rule` is warned, best-effort compatibility input. It may have evaluated away
  information before Einstoff receives it, so it is not equivalent to
  `RuleDelayed` even though both valid captured forms compile to the same IR.
- The complete LHS is one binder scope, but bare LHS expressions never become
  localized references. The precise, load-bearing rule is in §5.1.
- Native pattern concepts remain the user mental model. The kernel pattern
  matcher is not operationally authoritative after controlled capture.
- Compilation is staged and immutable:
  `SurfaceDesc` → `CapturedDesc` → `NormalizedDesc` → `ConstraintDesc` →
  `SolvedDesc` → `OperationAnalysis` → `ExecutionPlan`.

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
- `Annotation[axis, positiveInteger]` or
  `Labeled[positiveInteger, axis]` (inline named-axis size; §5.4)
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
list-of-shapes on both sides, unconditionally, canonically connected with
`RuleDelayed`.
There is no grammar-level single-tensor or no-output special case. See §7.1
for why list-of-shapes is load-bearing, and §2 for why `:>` (not `->`) is
load-bearing.

The RHS is declarative. It normalizes to the shape grammar plus a finite
sequence-derivation vocabulary: sequence reference, projection, zip,
repetition, and composition. Postfix projections such as `a..` compile into
that vocabulary. Arbitrary `Map`, `MapThread`, callbacks, or other WL code are
not executed to derive output shapes. A recognized legacy sequence spelling may
be captured and compiled into a declarative node during migration; it never
becomes authority to run arbitrary RHS code. Ordinary user functions remain
allowed only in operator parameters that explicitly accept them (reducer, map
function, and `Inner` combiners).

Two sugars are allowed at the *call-site* (front-end), not in the core
grammar:

- a single shape `{...}` may stand in for `{{...}}` when there is exactly
  one input/output tensor
- a one-sided shape `{...}` (no `RuleDelayed`) for shape-preserving ops,
  normalized internally to `{...} :> {...}` before reaching the core engine

## 5. Semantics

### 5.1 Blank vs. Reference

This rule is deliberately repeated here because implementations and prior agent
sessions have repeatedly inferred the wrong “first declaration, later bare LHS
reference” model.

**The complete LHS is one pattern scope. Localization is side-sensitive:**

- Every LHS `a_` binds or infer-checks the same logical axis `a`.
- Repeated LHS occurrences `a_` must therefore unify to one size.
- A bare `a` on the LHS is always an ambient expression/capture. It is never
  localized merely because some other LHS occurrence is spelled `a_`.
- A bare `a` on the RHS references the completed whole-LHS binding when at least
  one LHS binder `a_` exists.
- Without an applicable LHS binder or explicit sized declaration, bare RHS `a`
  follows the ambient-capture hygiene rules in §5.6.
- An inline-sized bare/string axis on the LHS is an explicit declaration and is
  available to RHS references (§5.4).

Canonical regression examples:

```wl
{{a_, a_}} :> {{a}}  (* two binders, one logical axis *)
{{a, a}}   :> {{a}}  (* no binder; all bare occurrences are ambient *)
{{a_, a}}  :> {{a}}  (* binder plus unrelated ambient LHS expression *)
```

This remains WL-intuitive at the conceptual level: `Pattern`, `Blank`, products,
sums, and repetitions describe structural constraints. Internally the constraints
apply to logical axis identities and tensor dimensions, not by matching a numeric
shape list with the kernel pattern matcher. Native `Repeated` is the documented
divergence: Einstoff lifts inner binders pointwise across repetitions. Thus
`(2 ⊗ a_)..` requires every captured member to have the same even structure,
while the per-member `a` sizes may differ.

New axes that appear only on the RHS (repeat-style) are not inferred from an
input dimension. They need an inline or out-of-band positive size and are then
materialized by broadcasting (§5.5).

A named axis has two orthogonal coordinates: spelling kind (`b_` blank,
bare `b`, or string `"b"`) and targetedness (plain or targeted). The targeted
string spelling is `#name` (= `Slot["name"]`) and binds by unification on its
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

Neither native pattern-variable bindings nor evaluation of a `RuleDelayed` are
used to implement these substitutions after capture.

### 5.2 Reduce vs. elementary-op: targetedness disambiguates

"Axis present on LHS, absent on RHS" is ambiguous by itself — it could mean
(a) classic reduction with a user-supplied function (einops `reduce`), or
(b) the axis is fed whole into an elementary operation and everything else
is vmapped (einx bracket semantics). Targeted wrapper presence is the only thing
distinguishing these, so the compiler must branch on targetedness
explicitly; it cannot be inferred from set difference between LHS/RHS axis
names alone.

### 5.3 Named axis-sequences: where the name lives matters

**Shape resolver implemented; first data-lowering slice implemented.**
`EinstoffShapes` and `EinstoffMatch` understand named axis-sequences (`a__` /
`a___`, and structured `grp : term..` / `grp : term...`) and re-walk their
captures manually. The shared single-tensor decomposition path lowers plain named
axis-sequences as carried/vmapped axis runs, and lowers structured repeated groups
when their inner binders are projected on the RHS with postfix sequence syntax
(for example `{{b_, grp : (s_⊗#ds).., c_}} :> {{b, s.., c}}` in an
`Einstoff[ArrayReduce]` recipe). Broader operation-specific lowering remains
deferred.

Two roles a name can play inside an ellipsis:

- **Outer mvar** (`name__`, `name___`, or `name : pattern..`) — binds the *entire captured
  `Sequence`*; `{name}` listifies it.
- **Inner mvar** (a named sub-pattern inside a structured `term..`,
  e.g. `grp:(a:(_Integer|_Symbol))...`) — a destructuring template. The shape
  resolver re-walks `{grp}` element-by-element applying the inner pattern, producing a
  per-repetition binding list `{a} = {a<sub>1</sub>, a<sub>2</sub>, ...}`.

Cross-group consistency is an explicit sequence-length constraint. It is enforced
by the solver before a declarative zip node is planned, not pushed into a
`RuleDelayed` RHS body.

WL's stock implementation of repeated patterns enforces one identical native
binding across repetitions. Einstoff intentionally diverges: it applies the same
structural schema to each member while lifting inner binders pointwise. No
compilation target may delegate this matching back to the native matcher.

### 5.4 Size resolution

For named ellipses, scalar axis bindings remain ordinary positive integers in the
public `Bindings` association. Outer and inner sequence captures are first-class
private solution data used by declarative RHS projection. The public shape API does
not expose those list-valued captures as stable bindings.

Sizes may be supplied out of band in the binding-list argument or inline with
exactly these two-argument forms, on either side of the descriptor:

```wl
Annotation[axisSpec, positiveInteger]
Labeled[positiveInteger, axisSpec]
```

They normalize to an unwrapped axis occurrence plus a source-provenanced size
fact. A bare/string axis sized on the LHS is an explicit declaration, not an
ambient capture, and establishes an identity available on the RHS. A sized blank
such as `Annotation[a_, 3]` still infers `a` from the tensor and adds the check
`Size[a] == 3`; it does not make ordinary `a_ -> 3` binding keys legal.

The accepted `axisSpec` is a bare symbol, hygienic string, or blank binder,
optionally under a valid `Slot`, `Highlighted`, or `Framed` target wrapper.
Anonymous axes/sequences, integers as binding keys, products, direct sums, and
repeated groups are not accepted binding keys.

Sizing and targeting are orthogonal and commute syntactically:

```wl
Annotation[Framed[a], 3]   Framed[Annotation[a, 3]]
Labeled[3, Highlighted[a]] Highlighted[Labeled[3, a]]
```

Only the two-argument forms are borrowed; Einstoff does not inherit the complete
graphics-wrapper protocols of `Annotation` or `Labeled`. Equal inline and
out-of-band facts coalesce. Conflicting facts fail. The solver receives only a
recognized, fully valid merged binding table; evaluated/unrecognized candidates
may warn and are excluded before normalization.

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

A desc is an embedded WL expression, so controlled ambient capture is a supported
surface feature. Capture classifies each occurrence before normalization. Semantic
axis identity is then an operation-local `AxisId[positiveInteger]`, never a user
symbol or a fresh global symbol. A named axis has a spelling kind (blank, bare,
string) and an orthogonal targeted bit:

| Kind | Plain WL | Targeted WL | Role | Hygiene |
|---|---|---|---|---|
| blank | `a_` | `Highlighted[a_]` / `Framed[a_]` | LHS binder/infer-check | captured under hold, normalized to an axis ID |
| bare | `a` | `Highlighted[a]` / `Framed[a]` | LHS ambient expression; RHS reference only when resolved from the completed LHS scope or explicit declaration, otherwise ambient | opt-in capture: a bound `a` may read as its literal value |
| string | `"a"` | `#a` = `Slot["a"]`, `Highlighted["a"]`, `Framed["a"]` | fully-hygienic named axis; targeted form marks the elementary-op axis (§5.2) | immune to any `Block` |

**Resolved vs. captured.** Resolution is not symmetric across the rule. All bare
LHS occurrences are ambient, including a bare `a` beside `a_`. After the entire LHS
has been captured, a bare RHS `a` resolves to the LHS binder `a_` or an explicit
sized declaration. Otherwise it remains an ambient capture. `RuleDelayed` holding
the RHS is useful surface staging, but native rule substitution is not involved.

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

**Normalization.** Each recognized logical name is interned into an integer-backed
operation-local identity such as ``Einstoff`Internal`IR`AxisId[1]``. The axis table
stores display name, spelling kind, and provenance; targeting stays per occurrence.
No `Unique`, symbol value, downvalue, clearing, or temporary-symbol lifecycle is part
of semantic identity or capture. A string name must be a valid identifier. Public
results recover display names from the axis metadata/source map.

### 5.7 Binding-key grammar

`bindings` supplies sizes for axes not inferable from the tensors (repetition §5.5,
composite split-factors). A key names an axis; accepted spellings mirror the desc
spelling kind and normalize to its operation-local axis identity:

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
- Duplicate equal facts coalesce, including inline/out-of-band duplicates.
  Conflicting sizes for one logical axis are rejected independent of ordering.

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
   {{a__}, {b__}} :> {{CircleTimes[a, b]..}}
   ```
   The repeated product schema compiles to a declarative sequence-zip node (§7.1).
   `MapThread` is rejected like all other arbitrary RHS computation. Cross-group
   length consistency is a solver constraint.

8. **Named ellipsis with internal structure (pooling)** —
   `einx.sum("b (s [ds])... c", x, ds=(2, 2))`
   ```
   {{b_, grp : (CircleTimes[s_, Slot[ds_]]).., c_}} :> {{b, s.., c}}
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
    Both targeted string occurrences normalize to one logical axis identity;
    the constraint solver enforces equal sizes across operands.

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

### 7.1 Declarative output derivation for named ellipses

Examples 7 and 8 originally had no literal-pattern RHS: `(a b)...` means
"zip the two captured `Sequence`s pointwise," and projecting `ds` out of
each repetition of `(s [ds])...` is a per-operation computation — neither
is a shape *descriptor*.

**Resolution:** the RHS is structural shape syntax plus a finite declarative
sequence language. Its internal nodes are sequence reference, projection, zip,
repetition, and composition. Postfix forms such as `s..` are surface projections.
The compiler may recognize narrowly specified legacy spellings such as example 7
and translate them to those nodes, but it must reject an arbitrary held
`MapThread`, `Map`, callback, or other WL computation with a structured error that
identifies the offending fragment.

The solver owns sequence lengths and pointwise member captures. The planner sees
only solved sequence data and explicit derivation nodes. `RuleDelayed` protects the
surface expression during construction; it is not an output-derivation procedure
interface and is never released to execute user code.

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
  **Superseded again by the staged IR (§5.6):** capture now interns names directly into
  operation-local integer-backed `AxisId` values. `canonHeld`, temporary symbols, and
  reserved-context clearing have been removed. Contexts intentionally do not contribute
  to logical axis identity.
- ✅ **Duplicated desc normalization** across the former `descParts` and `parseDesc`
  boundaries — *fixed.* One held compiler entry performs unit-axis and `CirclePlus`
  normalization, and public parsing/shape APIs project from the same captured/normalized
  stages used by operators. The duplicate parser and lowerer paths have been removed.
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
  non-positive/non-integer size) now returns a structured capture/constraint failure
  rather than degrading into a deeper unsat message. Duplicate equal facts coalesce;
  conflicting duplicates reject without order dependence.
- ✅ **Dead `Module` locals** `sizes/ends/starts` in `directSumSplit` — *removed* (the live
  ones, `sz/en/st`, live in the inner block `Module`).

All §7.4 review items are now resolved: the two silent-wrong-output items, the
context-sensitive axis resolver, the duplicated desc normalization, bindings validation,
the tagged-throw isolation, and the dead `directSumSplit` locals.

## 8. Resolved / verified (no further action needed)

- `CirclePlus`/`CircleTimes` have no built-in evaluation rules for symbolic
  or numeric arguments — safe to use as inert semantic tags.
- Blank binding and RHS reference preserve the stock WL mental model, with the
  explicit whole-LHS and bare-LHS rules in §5.1 and pointwise repetition divergence.
- Top-level grammar is unconditionally list-of-shapes both sides, connected
  by `RuleDelayed` (§4.2); single-tensor and one-sided forms are front-end
  sugar only.
- `Slot[...]` nests without issue inside `CircleTimes` and `CirclePlus`.
- Named axis-sequence output derivation uses the restricted declarative vocabulary in
  §7.1; ordinary RHS WL code is not an execution interface.

## 9. Status & next steps

Implemented and cross-validated against einx/einops: staged capture, normalized IR,
restricted shape constraints, operation analysis, and backend-neutral execution
plans for the non-sequence operator subset. Immediate execution and `TraceAction`
render from the same plan. Public paths include `Einstoff["Massage"]` (the permissive
univalent engine) with its intent guards `Einstoff[ArrayReshape]` (bijective
rearrange/reshape) and `Einstoff["ArrayContract"]` (within-tensor contraction, no
repetition), `Einstoff[ArrayReduce][reducer]` (reduce, reducer curried),
`Einstoff[Dot]` (einsum contraction over **N ≥ 2 operands** via an `InnerStep`
pairwise left fold — the plan keeps the global output axes plus anything a later operand
still needs, so an axis is summed only once nothing downstream uses it), and
uniform repetition (§5.5).

`Einstoff[Inner][mul, add]` generalizes `Dot` (= `Inner[Times, Plus]`): the same
fold with the batched inner product using an arbitrary multiply `mul` and combiner
`add` (cf. WL `Inner`; e.g. `{Plus, Min}` is min-plus/tropical contraction). The
`Times/Plus` case keeps the native `Dot` fast path. Only that case maps to
`einx.dot` for cross-validation; other combiners are checked against native WL
`Inner`. For a semiring `(mul, add)` the N-ary fold is associative; the
left-to-right order is the defined semantics otherwise.

`Einstoff[Operate][f]` is the **shape-preserving targeted-block operation path**:
targeted axes are passed to `f` as one rectangular block, every untargeted axis is
vmapped, and `f` must return the same block shape. It has a few optional convenience
string recipes for einx's shape-preserving miscellaneous ops
(flip/roll/sort/softmax/log_softmax/id), but these are not a core parity surface and
should not grow into an einx-style named operation catalog.
**Not planned:** first-class named elementwise families such as add/subtract/where/
comparisons/logaddexp/maximum/minimum. einx can promise optimized backend graphs for
those named ops; Einstoff only promises correctness of the explicit Wolfram function
the user supplies. The generic Wolfram contract is: the selected target axes are
presented to `f` as a rectangular Wolfram subarray/block, preserving nested list
structure, and `f` must return a block with the same dimensions. Adjacent targets
(`[a][b]` / `#a #b`) select one target block, not separate passes; raw functions
therefore follow Wolfram expression semantics (`Reverse`, `Sort`, custom maps,
ResourceFunction calls, etc.) rather than einx's per-op arity restrictions. `roll`'s
shift is a parameter, so it is written with an explicit function such as
`RotateRight[#, k] &`. `Einstoff[Map][f]` uses the same target/vmap layout but allows
`f` to change the target block shape; the produced block is validated against the RHS.
With no target, `Map` follows einx's no-bracket misc-op behavior and maps over scalar
blocks, not over the whole tensor. `ArrayReduce` remains the declarative reducer path.

The reducer, the map `f` and `(mul, add)` are **curried** into the operator
(`Einstoff[ArrayReduce][Total][…]`, `Einstoff[Operate][f][…]`,
`Einstoff[Map][f][…]`,
`Einstoff[Inner][mul, add][…]`); no operator holds `desc` (uniform convention — §2
note), so a globally bound axis symbol substitutes (a bound integer reads as a
literal dimension; illegal values are rejected by the matcher). The reducer string
set covers **every einx reduction op** (sum/mean/var/std/prod/count_nonzero/any/all/
max/min/logsumexp); `var`/`std` are population (ddof = 0, matching numpy/einx), and
any raw list-reducer (`Total`, `Variance`, a custom function) is also accepted.

`"Targeting" -> False | Automatic | True` is implemented for `ArrayReduce`, `Dot`/
`Inner`, `Massage`, `ArrayContract`, and `einsum` (via delegation). `False` preserves
the old inference-first semantics: reduced/contracted axes are selected from RHS
absence or repeated/shared names. `Automatic` is the default: shorthand inference is
still accepted, but explicit targets must exactly agree with the operated input
occurrences, so mismatched dot targets such as `a [b] c, a [c] d -> a b d` reject.
`True` requires explicit targets for operated axes. Axis identity is unchanged by this
option: targeting is occurrence-role metadata, not a separate size/name identity.

**`CirclePlus` (direct sum) — implemented and cross-validated.** The direct-sum
axis `(a + b)` lowers two ways, both folded into the permissive `Einstoff["Massage"]`
(einx puts `+` in `id`; the bijective `Einstoff[ArrayReshape]` guard rejects a direct
sum — use `Einstoff[Join]`/`[Split]` or `Massage`) and routed by where the CirclePlus
appears:

- **Concatenation** (CirclePlus on the RHS, `{op1, …, opk} :> {{… a ⊕ b …}}`; ex4):
  each operand is aligned to the output shape with its own direct-sum summand
  combination (the shared execution plan broadcasts a scalar operand / integer summand
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
the held compiler performs this normalization once), so both directions accept them.

**Composite summands** (a `CircleTimes` block inside the direct sum, e.g.
`(a⊗b) ⊕ c`) are supported in **both** directions. The staged constraint builder
emits restricted product/sum size equations and the solver hands only those generated
positive-integer equations to `Solve`, so a unique solution binds the axes, multiple
solutions are reported underdetermined, and none is a mismatch. This lets us
*uniquely resolve systems einx rejects* (e.g. `m (a + b)` with an axis of size 2
forces `a = b = 1`). On concat the block is just another term aligned by
the execution plan and `Join`'d; on split the block size is the product over its
atoms (`Take` slice, then reshape). Targeted direct sums
(`Highlighted[CirclePlus[…]]` / `Framed[CirclePlus[…]]`, and `Slot[CirclePlus[…]]`
for string-only summands) are rejected by `Einstoff[ArrayReduce]` and the
target-block operation paths (`Einstoff[Operate]` / `Einstoff[Map]`): feeding a
structural concatenation as one elementary-operation target is semantically
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
`Einstoff[Operate][f]`, the shape-preserving kept-bracket vmap, and
`Einstoff[Map][f]`, the generalized blockwise transform, are also implemented
(see above).
Plain anonymous sequences (`__` / `___`) lower as non-targeted carried/vmapped
axis runs when kept on the output. The implemented subset is one plain anonymous
sequence per shape; matching multiple unnamed plain sequences in one shape is
deferred because deciding which capture corresponds to which output occurrence
needs a real matching policy beyond `Longest` / `Shortest`. Targeted variadic runs (`##`,
`Highlighted[__]`, `Highlighted[___]`, etc.) remain the spelling for feeding a
captured run to `ArrayReduce` / `Map`.

**Other deferred lowering items** (rejected loudly today, not mis-compiled):
the remaining named axis-sequence lowering surface (§5.3), especially structured
projection and direct-sum interactions; within-operand reduction before contraction
in `Einstoff[Dot]`.

**Within-tensor contraction — pairwise core implemented.** A name repeated in one
operand and dropped on the output is summed over its coincident slots (GR-style traces,
e.g. Ricci `R^a{}_{bad}`), which einx cannot express but `einops.einsum`/`np.einsum` and
WL can. Lowered by a self-contraction execution-plan step via
`ResourceFunction["ArrayContract"][x, pairs, Plus, ArrayDepth[x]]` (the explicit depth is
required — the 3-arg form mis-levels). Exposed two ways:
- `Einstoff["Massage"]` / `EinstoffMassage` (Reshape.wl) — the **univalent** (single-
  tensor) structural engine: rearrange + repeat + direct sum **and** within-tensor
  contraction. The staged solver permits a within-tensor repeat while operation
  analysis still enforces the stricter reduce/map policies.
- `Einstoff["einsum"]` / `EinstoffEinsum` (Einsum.wl) — the pairwise-contraction subset:
  1 tensor → Massage, ≥2 → the `Dot` cross-tensor fold; rejects repetition and the mixed
  multi-operand case (deferred). Cross-validated against `einops.einsum`.

Only *pairwise* is supported (the tensorial case). With default `"Targeting" ->
Automatic`, a targeted pair may be contracted while exactly one untargeted occurrence
of the same axis carries the output (for example `a [a] [a] -> a`, using string-kind
`#a` in WL). A kept repeat without such a carrier (diagonal `aa->a`), an axis occurring
`>2` times after the targeted pair policy (super-diagonal, non-tensorial —
`EinsteinSummation` also caps at 2), and a single dropped index (plain sum-reduction →
`Einstoff[ArrayReduce]`) are all rejected. **Deferred:** the combiner generalization
(`ArrayContract[…, add]` / `Tr[…, add]`, mirroring `Einstoff[Inner]`); diagonal-keep;
mixed within+cross multi-operand einsum; and the bracket/composite interactions. Analysis:
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
