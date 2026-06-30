# Plan: bracket cleanup (done) → `Einstoff[Map]` → `#a`/`##` notation migration

> Referenced from SPEC.md §9. Parts A and B are **done**; Part C is **designed,
> not yet built** (recorded here so the design survives session boundaries).

## Context

Two einx findings (probed against the repo venv) reshape the bracket roadmap:

- **`[a b c]` ≡ `[a] [b] [c]`** — grouped vs separate brackets are identical; the
  bracketed axes are fed to the elementary op as one flattened unit, order/grouping
  irrelevant. ⇒ a multi-axis bracket is just adjacent single brackets; no multi-arity
  `Slot[a, b]` is ever needed. (Retired SPEC §7.3's "non-standard arity" concern.)
- **Vmap family** = a bracketed axis *kept* on the output (softmax / log_softmax /
  flip / roll / sort / argsort): the op runs along the bracketed (flattened) axes,
  vmapped over the rest. einx has **no generic vmap entry point** — brackets define
  each named op's signature. This is exactly the path `Einstoff[ArrayReduce]` rejects
  today ("feed-to-elementary-op is a separate path"). Resolves the §5.2 ambiguity:
  **bracket dropped = reduce; bracket kept = map/vmap.**

Bracket handling lives in `Parsing.wl` (`matchTerms` Slot-splice, `bracketedNames`,
`factorToExpr`, `evalOutShape` `Slot→Sequence`), `Lowering.wl` (`reduceAtoms` Slot
branch), consumed in `Reduce.wl` (the `lhsBr` kept-bracket reject) and `Dot.wl`
(unwrap); `DirectSum.wl` rejects brackets.

---

## Part A — DONE: retire multi-arity `Slot[a, b]`

Single-axis brackets are canonical; `[a b]` is written `Slot[a_], Slot[b_]`. Changed:
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

The kept-bracket sibling of `Einstoff[ArrayReduce][reducer]`: reduce *drops* the
bracketed axes (`f`: block → scalar); **Map keeps them** (`f`: block → same-shape
block), vmapping over the unbracketed axes. Generic and **curried in `f`**, mirroring
the reducer-currying convention. New file `Einstoff/Kernel/Map.wl`.

- **Surface:** `Einstoff[Map] := EinstoffMap`; subvalue
  `EinstoffMap[f][desc_, tensors_, bindings_List : {}] := …` (like
  `EinstoffReduce[reducer][…]`). Examples:
  `Einstoff[Map][softmaxVec][{{a, b, Slot[c_]}} :> {{a, b, c}}, {x}]`,
  `Einstoff[Map][Reverse]` (flip), `Einstoff[Map][Sort]`, `Einstoff[Map][RotateRight]`
  (roll).
- **Semantics:** the bracketed atoms (`reduceAtoms` `True`-flagged) are the op axes;
  `f` receives them **flattened to one vector** (matching einx's grouped-bracket
  flattening) and returns a same-length vector. Unbracketed axes are vmapped. The
  bracketed axes are **kept** — they must appear on the RHS; a bracketed axis *dropped*
  on the RHS is a reduce (reject → point to `Einstoff[ArrayReduce]`). Output-only axes
  are repetition (free via `materializeOutput`).
- **Lowering** (reuses the Reduce/rearrange machinery):
  1. `EinstoffShapes` → env; `reduceAtoms` → atoms + bracket flags.
  2. `ArrayReshape` input to atomic dims.
  3. `Transpose` so vmap (unbracketed) atoms lead and bracketed atoms trail; flatten
     the trailing bracketed atoms into one axis ⇒ `[vmap…, bracketProd]`.
  4. Apply `f` along the last axis: `Map[f, arr, {-2}]` (each last-axis vector →
     same-length vector).
  5. Reshape the bracket axis back to its atomic dims; `materializeOutput` permutes the
     kept atoms to RHS order, recomposes composites, broadcasts any repeats.
- **`f` contract:** length-`bracketProd` vector → same-length vector (softmax,
  `Reverse` = flip, `Sort`, `RotateRight` = roll, …). Shape-preserving along the bracket.
- **Cross-validation:** `Einstoff[Map][f]` vs `einx.softmax`/`flip`/`sort`/`roll` for
  matching `f`, plus native WL (`Reverse`/`Sort`/…). New `tests/Map.wlt` +
  `tests/python/Map.wlt`.
- **Reduce reciprocity:** once Map exists, the Reduce reject message
  ("feed-to-elementary-op is a separate path") should name `Einstoff[Map]`.

---

## Part C — Design: notation migration `#a` / `##`

Move bracket notation to the ergonomic, hazard-free form:
`Slot[name_]` / `Slot[name]` → **`#name`** (`Slot["name"]`); `Slot[___]` (anonymous
variadic `[...]`) → **`##`** (`SlotSequence[1]`). This is the large endeavor; it also
**subsumes the §7.2 fix** (string-named slots avoid the integer-positional
`Slot[2]` ≡ `#2` Function-aliasing hazard). The SPEC §3 table already documents
`[a]` → `#a` → `Slot["a"]` as the canonical target, so this aligns code to spec.

**Semantic shift (core decision):** a bracketed axis becomes a *string-named* axis
bound by **unification** (first occurrence sets the size, repeats must agree — exactly
how bare-symbol references already work via `unify`), rather than the `Slot[b_]`-binds-
vs-`Slot[b]`-references Pattern asymmetry. So `Slot["b"]` maps to "axis `b`, bracketed"
— the same identity a bare `b` on the RHS references. The non-bracket binding (`a_` vs
`a`) is unchanged; only brackets migrate. Example: `{a_, #b, #b, c} :> {a, c}` —
`a_` binds, `#b` is bracketed-`b` (unify), `c` is a bare reference.

**Touch points (all in scope):**
- `Parsing.wl` `matchTerms`: handle `Slot["b"]` (string → axis `b`, bracketed, unify)
  and `SlotSequence[1]` (a bracketed run, like the variadic `Slot[___]` case);
- `Parsing.wl` `bracketedNames`, `factorToExpr`: read the string-named bracket;
- `Lowering.wl` `reduceAtoms`: `Slot["b"]` → `{b, True}`; `SlotSequence` → variadic
  bracketed (ties into the still-deferred `Slot[___]` lowering);
- `evalOutShape` `Slot→Sequence` stays (brackets rarely on the RHS);
- `DirectSum.wl` `directSumSummandQ` reject updated for the new form;
- **all `Slot[` test sites** (7 files) rewritten to `#name` / `##`.

**Open decisions to settle before building C:**
- **String↔symbol identity:** does `Slot["b"]` resolve to the *symbol* `b` (so a bare
  RHS `b` references it) — recommended — or stay a string key in `env`? Recommended:
  map to symbol `b` so brackets and bare references share identity.
- **Bracketed integer immediates** (gather's `Slot[2]`): `#2` is `Slot[2]` (integer
  slot), not a string — so `#`-sugar can't express a bracketed literal cleanly. Gather
  is deferred anyway; bracketed immediates keep the explicit `Slot[2]`/`Slot["2"]`
  form, to be resolved when gather is built.
- **`##` arity:** `SlotSequence[1]` vs `SlotSequence[]` — confirm the intended head for
  the anonymous variadic bracket, and that the matcher's variadic-run handling
  (currently for `Slot[___]`) maps onto it.

**Sequencing:** B (Map) is notation-agnostic at the operator level (it consumes
`reduceAtoms` flags, not surface syntax), so it can ship before C and be migrated with
the rest. Recommend **B before C** (adds capability sooner; smaller, self-contained).

## Verification (when Parts B & C are built)
- B: `tests/Map.wlt` vs native WL (`Reverse`/`Sort`/softmax) + `tests/python/Map.wlt`
  vs `einx.softmax`/`flip`/`sort`; full suite green.
- C: pure refactor — every existing test rewritten to `#a`/`##` must produce the
  identical pass set (numbers unchanged); add a couple of `#b … #b` unify tests and a
  `##` variadic test.
