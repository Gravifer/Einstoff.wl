# Plan: bracket cleanup (done) → `Einstoff[Map]` → `#a`/`##` notation migration

> Referenced from SPEC.md §9. Parts A, B and C are all **done** (2026-06-30). This
> file is kept as the rationale/record; the implementation is in the tree.

## Context

Two einx findings (probed against the repo venv) reshape the bracket roadmap:

- **`[a b c]` ≡ `[a] [b] [c]`** — grouped vs separate brackets select the same target
  block. ⇒ a multi-axis bracket is just adjacent single brackets; no multi-arity
  `Slot[a, b]` is ever needed. (Retired SPEC §7.3's "non-standard arity" concern.)
- **Vmap family** = a targeted axis *kept* on the output (softmax / log_softmax /
  flip / roll / sort / argsort): the op runs on the targeted block,
  vmapped over the rest. einx has **no generic vmap entry point** — brackets define
  each named op's signature. This is exactly the path `Einstoff[ArrayReduce]` rejects
  today ("feed-to-elementary-op is a separate path"). Resolves the §5.2 ambiguity:
  **bracket dropped = reduce; bracket kept = map/vmap.**

Target handling lives in `Parsing.wl` (`matchTerms` target-splice,
`targetedNames`, `factorToExpr`, `evalOutShape` wrapper->`Sequence`), `Lowering.wl`
(`reduceAtoms` bracket branch), consumed in `Reduce.wl` (the `lhsBr` kept-bracket
reject) and `Dot.wl` (unwrap); `DirectSum.wl` rejects brackets. The canonical targeted
string axis is `Slot["a"]`/`#a`, `Highlighted["a"]`, or `Framed["a"]`; visual targeted
symbol spellings are `Highlighted[a_]`/`Framed[a_]` for blank and
`Highlighted[a]`/`Framed[a]` for bare. `Slot[...]` is reserved for string-kind targets.
`Squiggled[...]` is not used because its frontend rendering is too easy to confuse with
other notation.

---

## Part A — DONE: retire multi-arity `Slot[a, b]`

Single-axis brackets are canonical; `[a b]` is written `Slot["a"], Slot["b"]`. Changed:
SPEC §7.3 (rewritten as resolved), §3 notation table (row "multiple axes" + fixed the
integer-immediate cross-ref to §7.2), §6 ex11 gather example, and both `Slot[h_, w_]`
sites in `tests/Parsing.wlt` (`:83`, `:149`). The matcher still tolerates a multi-arg
`Slot` harmlessly (splices `List @@ Slot[...]`); it is simply non-canonical now. No
operator logic or numeric outputs changed — suite stayed at 153 green.

---

## Part B — DONE: `Einstoff[Map][f]` (kept-bracket vmap)

**Built** in `Einstoff/Kernel/Map.wl` (subvalue `EinstoffMap[f][desc, tensors,
bindings_List : {}]`, `Einstoff[Map] := EinstoffMap`). `mapFunction` resolves the einx
misc names (`"flip"`→`Reverse`, `"sort"`→`Sort`, `"softmax"`/`"log_softmax"` stable
max-shift, `"id"`→`Identity`); `roll` is a function (`RotateRight[#,k]&`, matching
numpy `shift`). Lowering: `reduceAtoms` flags brackets → `Transpose` vmap-atoms-lead/
bracket-atoms-trail → collapse to `{vmapProd, brProd}` matrix → `f /@ rows` (with a
shape-preserving check) → reshape back → `materializeOutput`. Rejects: dropped axis
(→ `ArrayReduce`), no bracket (→ `ArrayReshape`), non-shape-preserving `f`, multi-
tensor. Also extended `Reduce.wl`'s `reduceFunction` to the full einx reduction set
(var/std population, count_nonzero, any, all, logsumexp). Tests: `tests/Map.wlt` (14)
+ `tests/python/Map.wlt` (4, vs einx.flip/sort/roll/softmax) + 6 new in
`tests/Reduce.wlt`. Suite 177 green (132 WL + 45 xval). The design that was built:

The kept-target sibling of `Einstoff[ArrayReduce][reducer]`: reduce *drops* the
targeted axes (`f`: block -> scalar); **Map keeps them** (`f`: block -> same-shape
block), vmapping over the untargeted axes. Generic and **curried in `f`**, mirroring
the reducer-currying convention. New file `Einstoff/Kernel/Map.wl`.

- **Surface:** `Einstoff[Map] := EinstoffMap`; subvalue
  `EinstoffMap[f][desc_, tensors_, bindings_List : {}] := …` (like
  `EinstoffReduce[reducer][…]`). Examples:
  `Einstoff[Map][softmaxVec][{{a, b, Slot[c_]}} :> {{a, b, c}}, {x}]`,
  `Einstoff[Map][Reverse]` (flip), `Einstoff[Map][Sort]`, `Einstoff[Map][RotateRight]`
  (roll).
- **Current semantics:** the targeted atoms are the op axes; `f` receives the selected
  target as a rectangular Wolfram block, preserving nested list structure, and returns a
  same-shape block. Untargeted axes are vmapped. The targeted axes are **kept** — they
  must appear on the RHS; a targeted axis *dropped* on the RHS is a reduce (reject →
  point to `Einstoff[ArrayReduce]`). Output-only axes are repetition (free via
  `materializeOutput`).
- **Lowering** (reuses the Reduce/rearrange machinery):
  1. `EinstoffShapes` → env; `reduceAtoms` → atoms + bracket flags.
  2. `ArrayReshape` input to atomic dims.
  3. `Transpose` so vmap (untargeted) atoms lead and targeted atoms trail.
  4. Apply `f` at the vmap depth: each target block -> same-shape target block.
  5. `materializeOutput` permutes the kept atoms to RHS order, recomposes composites,
     broadcasts any repeats.
- **`f` contract:** target block -> same-shape target block (softmax,
  `Reverse` = flip, `Sort`, `RotateRight` = roll, ...). Shape-preserving along the target.
- **Cross-validation:** `Einstoff[Map][f]` vs `einx.softmax`/`flip`/`sort`/`roll` for
  matching `f`, plus native WL (`Reverse`/`Sort`/…). New `tests/Map.wlt` +
  `tests/python/Map.wlt`.
- **Reduce reciprocity:** once Map exists, the Reduce reject message
  ("feed-to-elementary-op is a separate path") should name `Einstoff[Map]`.

---

## Part C — DONE: notation migration `#a` / `##`

**Built** (2026-06-30; refined 2026-07). Axis spelling is now a matrix:
blank `b_` / bare `b` / string `"b"` times plain / targeted. A targeted string axis can
be `#name` = `Slot["name"]`, `Highlighted["name"]`, or `Framed["name"]`, bound by
unification on its string name; `[...]` is `##` = `SlotSequence[1]`. Kept targeted
string axes remain targeted on the RHS with the same head (`{{a, #b}}` for `Slot`);
referencing bare `b` is now a spelling-kind mismatch. `Highlighted[b_]` and `Framed[b_]`
spell targeted blank axes; `Highlighted[b]` and `Framed[b]` spell targeted bare axes.
`Slot[...]` is reserved for string-kind targets. Engine changes include `SlotSequence` handling like `___`,
string/bracket reporting, bracket-wrapper unwrapping, and lowering support for
`Slot`/`Highlighted`/`Framed`. Composite targeted symbol axes use `Highlighted[...]` or
`Framed[...]`; integer (`Slot[2]`) brackets
keep their explicit forms (no `#`-sugar); the Repeated destructuring template (§5.3,
deferred) keeps its Pattern bracket `Slot[ds_]` (it is a template, not a unify-by-name).
Suite 180 green (135 WL + 45 xval) at the original migration point. Resolved open
decisions: (1) `Slot["b"]`, `Highlighted["b"]`, and `Framed["b"]` are targeted string
axes; (2) targeted integer literals may use `Slot[2]`, `Highlighted[2]`, or
`Framed[2]`; (3) `##` = `SlotSequence[1]`, treated as `___` for matching.
The original design follows:

Move bracket notation to the ergonomic, hazard-free form:
`Slot[name_]` / `Slot[name]` → **`#name`** (`Slot["name"]`); `Slot[___]` (anonymous
variadic `[...]`) → **`##`** (`SlotSequence[1]`). This is the large endeavor; it also
**subsumes the §7.2 fix** (string-named slots avoid the integer-positional
`Slot[2]` ≡ `#2` Function-aliasing hazard). The SPEC §3 table already documents
`[a]` → `#a` → `Slot["a"]` as the canonical target, so this aligns code to spec.

**Semantic shift (core decision):** a `Slot["b"]` bracket is a targeted string axis
bound by **unification** (first occurrence sets the size, repeats must agree), rather
than the `Slot[b_]`-binds-vs-`Slot[b]`-references Pattern asymmetry. `Highlighted["b"]`
and `Framed["b"]` are alternate visual target heads for the same string kind. Targeted
string does not share identity with bare `b`; blank/bare/string spelling remains
load-bearing, and targetedness is orthogonal. Example: `{a_, #b, #b, c} :> {a, #b, c}`
keeps the targeted string axis.

**Touch points (all in scope):**
- `Parsing.wl` `matchTerms`: handle `Slot["b"]` (string → axis `b`, bracketed, unify)
  and `SlotSequence[1]` (a bracketed run, like the variadic `Slot[___]` case);
- `Parsing.wl` `targetedNames`, `factorToExpr`: read the string-named target;
- `Lowering.wl` target decomposition: `Slot["b"]` → `{b, True}`; `SlotSequence` and
  `Highlighted[__]`/`Highlighted[___]` capture concrete variadic target axes;
- `evalOutShape` `Slot→Sequence` stays (brackets rarely on the RHS);
- `DirectSum.wl` `directSumSummandQ` reject updated for the new form;
- **all `Slot[` test sites** (7 files) rewritten to `#name` / `##`.

**Resolved decisions from Part C:**
- **Resolved:** `Slot["b"]`, `Highlighted["b"]`, and `Framed["b"]` are targeted string
  spellings and should stay targeted with the same head on a kept RHS. Binding may use
  `"b" -> n` or the matching target-head key; a different target head is rejected.
  `Highlighted[b_]`/`Framed[b_]` are targeted blank; `Highlighted[b]`/`Framed[b]` are
  targeted bare.
- **Targeted integer literals** (`Slot[2]`, `Highlighted[2]`, `Framed[2]`): `#2` is
  `Slot[2]` (integer slot), not a string — so `#`-sugar can't express a targeted
  literal cleanly. Targeted literals already lower where the corresponding operation
  supports them (for example `ArrayReduce` and einx `a [2] -> a`). What remains
  deferred is indexing-style gather/scatter lowering, where `[2]` is an index-vector
  axis rather than just an anonymous targeted size-2 axis.
- **Resolved:** `##` is `SlotSequence[1]`. The matcher treats it like `___`; Map/Reduce
  lower it by expanding the matched concrete target dimensions.

**Historical sequencing:** B (Map) shipped before C; C then migrated the bracket
surface syntax across the tree.

## Verification (Parts B & C, historical)
- B: `tests/Map.wlt` vs native WL (`Reverse`/`Sort`/softmax) + `tests/python/Map.wlt`
  vs `einx.softmax`/`flip`/`sort`; full suite green.
- C: pure refactor — every existing test rewritten to `#a`/`##` must produce the
  identical pass set (numbers unchanged); add a couple of `#b … #b` unify tests and a
  `##` variadic test.
