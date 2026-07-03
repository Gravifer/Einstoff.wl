(* ::Package:: *)

(* Einstoff lowering — shared hub.

   Each lowering path (operator) lives in its own file under Kernel/:

     Reshape.wl   Einstoff["Massage"]    / EinstoffMassage (univalent engine:
                  rearrange/repeat/direct-sum + within-tensor pairwise contraction) and
                  its two guards Einstoff[ArrayReshape]/EinstoffReshape (bijective) and
                  Einstoff["ArrayContract"]/EinstoffContract (no repetition)
     Reduce.wl    Einstoff[ArrayReduce]  / EinstoffReduce  (curried in the reducer)
     Map.wl       Einstoff[Map]          / EinstoffMap     (curried in the map fn)
     Dot.wl       Einstoff[Dot]/[Inner]  / EinstoffDot, EinstoffInner (Inner curried)
     Einsum.wl    Einstoff["einsum"]     / EinstoffEinsum  (dispatch: 1 tensor ->
                  Massage, >=2 -> Dot fold; pairwise-contraction subset)
     DirectSum.wl Einstoff[Join]/[Split] / EinstoffJoin (CirclePlus concat/split)

   This hub holds what they share: the public `Einstoff` operator symbol and its
   messages, and the cross-file-private (`PackageScope`) helpers for desc parsing
   and atomic-axis decomposition.  Every path turns a satisfiable description
   (resolved by Einstoff`Parsing`) into native array ops — ArrayReshape /
   Transpose / ArrayReduce / Dot — over atomic axes.

   On the SPF private-helper sharing: undeclared symbols are private *per file*,
   so helpers used by more than one path are declared `PackageScope` here to make
   them visible package-wide without exporting them publicly. *)

PackageExported[{Einstoff}]

Einstoff::usage =
  "Einstoff[op] yields the Einstoff operator implementing op: Einstoff[\"Massage\"] \
(the permissive single-tensor engine: rearrange/reshape, repetition, direct sum, and \
within-tensor pairwise contraction), Einstoff[ArrayReshape] (its bijective guard: \
count-preserving rearrange only), Einstoff[\"ArrayContract\"] (its no-repetition guard: \
adds within-tensor contraction), Einstoff[ArrayReduce][reducer] (reduction), \
Einstoff[Map][f] (shape-preserving elementary op along a bracketed axis — \
flip/sort/softmax/…), Einstoff[Dot] (einsum contraction) and its generalization \
Einstoff[Inner][mul, add], Einstoff[\"einsum\"] (the pairwise-contraction subset, \
within- and cross-tensor), Einstoff[Join]/[Split] (direct sum). Applied as \
op[desc, tensors, bindings]; the reducer, map fn and (mul, add) are curried.";

(* Shared diagnostics for every lowering path. *)
Einstoff::unsupp = "`1`";
Einstoff::unsat =
  "description is not satisfiable against the given tensor(s): `1`";
(* A binding key that arrived as a plain value — probably a shadowed axis symbol
   (Block[{c=3}, {c->2}] reaches us as {3->2}).  Non-fatal: the entry is dropped and
   resolution continues (it fails later only if the shapes are then unsatisfiable). *)
Einstoff::evalkey = "`1`";

PackageScoped[{descParts, canonHeld, canonBindingList, withAxisScope, $axisFresh,
  normUnitTerms, flattenDirectSum,
  normShapes, normHeldShapes, rearrangeAtoms, atomSize, firstDuplicateAxis,
  distinctAxesQ, reduceAtoms, materializeOutput, selfContract, reshapeTo, hasCirclePlus,
  directSumConcat, directSumSplit, einThrowTag, einCatch}]

(* Internal control-flow tag.  The lowering helpers signal an unsupported / unsatisfiable
   desc with Throw[$Failed, einThrowTag]; the operator that called them recovers it with
   einCatch (a Catch scoped to that tag).  The TAG is load-bearing: several paths run
   *user-supplied* functions inside the caught region — Inner's (mul, add), ArrayReduce's
   reducer, Map's f — and a user function that itself throws (untagged, or with its own
   tag) must propagate OUT rather than be swallowed as our $Failed sentinel.  Scoping every
   internal throw/catch to einThrowTag isolates our control flow from the user's.
   einThrowTag needs no definition — an undefined package symbol is a unique, stable tag. *)
SetAttributes[einCatch, HoldFirst];
einCatch[expr_] := Catch[expr, einThrowTag];

(* ------------------------------------------------------------------ *)
(* desc parsing.  Operators are HoldFirst and pass Hold[desc] in, so the *)
(* RHS stays held until bindings are substituted; we extract lhs and the *)
(* (released) rhs shape lists.  Returns $Failed if desc isn't lhs :> rhs. *)
(* ------------------------------------------------------------------ *)

(* A bracketed axis #name == Slot["name"] denotes the axis `name`.  Resolve each
   bracket string to the *symbol the desc itself uses* for that name — collected from
   the desc's own symbols (System` heads like List/CircleTimes/Slot excluded) — so #b
   and a bare b are the same axis regardless of $Context.  This removes the
   Symbol["b"]-resolved-in-the-wrong-context hazard (a string would otherwise become a
   symbol in whatever $Context happens to be live).  A name that appears only as a
   string (never bare) is internal-only, so the Symbol[] fallback is harmless.  Shared
   by both desc entry points (descParts here, parseDesc in the shape layer). *)
resolveSlotStrings[h_Hold] :=
  Module[{byName},
    byName = Association @ Cases[h,
      s_Symbol /; Context[s] =!= "System`" :> (SymbolName[s] -> s), {0, Infinity}];
    h /. Slot[str_String] :> Slot[Lookup[byName, str, Symbol[str]]]];

(* --- desc-boundary canonicalization (shared by both entry points) ---------------- *)
(* Two orthogonal normalizations are applied once at the desc boundary so all
   downstream code sees a single spelling: {} unit terms become the literal 1, and
   nested CirclePlus is flattened.  descParts (here) and parseDesc (the shape layer)
   both route through normShapes / normHeldShapes below — the only difference is that
   the shape layer keeps the RHS held.  Keeping the policy in one place stops the two
   boundaries from drifting apart as the grammar evolves. *)

(* Normalize an in-shape unit term {} to the literal 1, at any depth WITHIN each shape
   (including inside a CircleTimes/CirclePlus), while leaving a whole-shape {} as a
   scalar (rank-0 operand).  So `{}` and `1` are the same unit axis in every term
   position; only a shape that *is* {} stays scalar. *)
normUnitTerms[shapes_] :=
  Replace[shapes, sh_List :> If[sh === {}, {}, sh /. {} -> 1], {1}];

(* CirclePlus (direct sum) is associative; canonicalize a ⊕ (b ⊕ c) to one flat summand
   list so the direct-sum paths see a single CirclePlus with all summands.  WL gives
   CirclePlus no attributes (neither Flat nor Orderless), so it does not collapse the
   nesting on its own; flattening preserves order (CirclePlus is not Orderless), which
   direct sum requires. *)
flattenDirectSum[expr_] :=
  expr //. CirclePlus[x___, CirclePlus[y___], z___] :> CirclePlus[x, y, z];

(* The one canonicalizer, in two forms for the two entry points.  normShapes normalizes
   a *released* list of shapes; normHeldShapes a *held* one (the shape layer holds the
   RHS so a globally-bound symbol is not released before its value is substituted).  Both
   apply the same policy: {} unit terms -> 1 and nested CirclePlus flattened.  In the held
   form the {} -> 1 rule runs at levels >= 3 of Hold[{shape, ...}] — term positions and
   deeper, never a level-2 whole-shape {} — matching normUnitTerms on the released form. *)
normShapes[shapes_] := flattenDirectSum @ normUnitTerms @ shapes;
normHeldShapes[hshapes_Hold] :=
  flattenDirectSum @ Replace[hshapes, {} -> 1, {3, Infinity}];

(* Operators are HoldFirst and pass Hold[desc]; descParts releases the RHS (at lowering
   time RHS symbols are atom labels, not values to substitute) and canonicalizes both
   sides.  parseDesc (Parsing.wl) is the held-RHS twin. *)
descParts[h : Hold[_Rule | _RuleDelayed]] :=
  With[{hr = resolveSlotStrings[h]},
    {normShapes @ Extract[hr, {1, 1}],
     normShapes @ ReleaseHold @ Extract[hr, {1, 2}, Hold]}];
descParts[_] := $Failed;

(* ------------------------------------------------------------------ *)
(* Atomic-axis decomposition of one dimension term.  An "atom" is an axis *)
(* that survives the transform unchanged (only its position / grouping    *)
(* changes).  Composites expand to their factors in order.                *)
(* ------------------------------------------------------------------ *)

(* Plain decomposition (no brackets): symbols, bindings, integers, products.
   Out-of-subset heads Throw[$Failed, einThrowTag] (recovered by einCatch in the
   calling operator). *)
rearrangeAtoms[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
rearrangeAtoms[s_Symbol] := {s};
rearrangeAtoms[n_Integer] := {n};
rearrangeAtoms[{}] := {1};   (* in-shape unit-axis term {} == literal 1 (einx "()") *)
rearrangeAtoms[CircleTimes[fs__]] := Join @@ (rearrangeAtoms /@ {fs});
rearrangeAtoms[other_] := (
  Message[Einstoff::unsupp,
    "unsupported term: " <> ToString[other, InputForm] <>
      " (direct sums and ellipses are not in the supported subset yet)"];
  Throw[$Failed, einThrowTag]);

atomSize[n_Integer, _] := n;
atomSize[s_, env_] := Lookup[env, s, Throw[$Failed, einThrowTag]];

(* Scalar-safe ArrayReshape: dims === {} means rank-0 (a scalar), where ArrayReshape
   would leak unevaluated — return the lone element instead.  An empty shape {} (a
   scalar operand) and a fully-squeezed array both land here. *)
reshapeTo[arr_, {}] := First @ Flatten @ {arr};
reshapeTo[arr_, dims_] := ArrayReshape[arr, dims];

(* Does any shape in `shapes` contain a CirclePlus (direct-sum) term?  Used to
   route a desc into the direct-sum path and to guard Join/Split direction. *)
hasCirclePlus[shapes_] := ! FreeQ[shapes, CirclePlus];

(* Axis-uniqueness predicate: True iff no axis name repeats *within a single shape* of
   `shapes` (a repeat is within-tensor contraction, which only Massage/Contract/einsum
   lower).  The boolean companion of `firstDuplicateAxis` (Parsing.wl), which names the
   offending axis for a diagnostic.  The non-contracting operators (reduce/map/dot/
   direct-sum) guard with an explicit `If[! distinctAxesQ[lhs], Message[..]; Return[$Failed]]`
   — NOT a `/;`/`?`-gated definition — because they must emit a tailored Einstoff::unsupp
   message and return $Failed, whereas a failed pattern test would leave the call
   unevaluated (no message, breaking the `=== $Failed` contract).  Kept as a named predicate
   so the yes/no question has one spelling; `firstDuplicateAxis` supplies the axis on the
   reject path. *)
distinctAxesQ[shapes_List] := MissingQ[firstDuplicateAxis[shapes]];

(* Bracket-aware decomposition: like rearrangeAtoms but unwraps Slot[...]
   brackets, returning {atom, bracketedQ} pairs.  NB Table/List@@ rather than
   `&/@`: a factor can be Slot[...], and routing it through an anonymous Function
   would reinterpret an integer Slot as that function's argument slot (SPEC 7.2).
   Variable-arity ellipses are out of scope and Throw. *)
reduceAtoms[t_, br_ : False] :=
  Which[
    MatchQ[t, Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]], {{t[[1]], br}},
    Head[t] === Symbol, {{t, br}},
    StringQ[t], {{Symbol[t], br}},   (* #name bracket: Slot["name"] -> axis name *)
    t === {}, {{1, br}},             (* in-shape unit-axis term {} == literal 1 *)
    IntegerQ[t], {{t, br}},
    Head[t] === CircleTimes,
      Join @@ Table[reduceAtoms[f, br], {f, List @@ t}],
    Head[t] === Slot,
      Join @@ Table[reduceAtoms[f, True], {f, List @@ t}],
    True,
      (Message[Einstoff::unsupp,
        "unsupported term: " <> ToString[t, InputForm] <>
          " (direct sums and variable-arity bracket ellipses are not in the \
supported subset yet)"];
       Throw[$Failed, einThrowTag])];

(* ------------------------------------------------------------------ *)
(* Shared output materialization, including repetition.                *)
(*                                                                      *)
(* Given the array `arr` whose atomic axes are exactly `presentAtoms`   *)
(* (in that order), and the held-then-released RHS shape `rhsTerms`,    *)
(* produce the final output array.  Output-only axes (on the RHS but    *)
(* absent from presentAtoms) are *repetition* axes (SPEC 5.5): each is  *)
(* materialized by broadcasting (ConstantArray), sized from `env`       *)
(* (i.e. from `bindings`, since nothing on the input constrains it).    *)
(* Then the atoms are permuted into RHS order and composites recomposed.*)
(* Throws $Failed (caught by the caller) on an unbound or bad axis.     *)
(*                                                                      *)
(* Repetition is layered here, uniformly, so every operator path        *)
(* (reshape/reduce/dot/direct-sum) gets einx-style repeat for free.     *)
(*                                                                      *)
(* A present axis NOT on the RHS is handled here, centrally, not by the *)
(* caller: a size-1 (unit) axis is squeezed; a size-(>1) axis is a data *)
(* loss / reduction and is rejected (Throw).  So callers need NOT pre-  *)
(* ensure presentAtoms ⊆ rhsAtoms — this is the single enforcement      *)
(* point for that invariant (do not move the guard back outward).       *)
(* ------------------------------------------------------------------ *)

materializeOutput[arr_, presentAtoms_, rhsTerms_, env_] :=
  Module[{env2 = env, rhsTerms2, rhsAtoms, present, repeats, acc = arr, order,
          srcOrder, outDims},
    (* A surviving INPUT literal-integer axis of size > 1 cannot be carried to the
       output: under Option A an output literal becomes a fresh anonymous broadcast
       axis, so an input literal has no output identity to map to (cf. einx rejecting
       'a 2 -> a 2').  A size-1 input literal is benign — it is squeezed (e.g. a
       singleton direct-sum summand block 'b (q+1) -> b q, b').  Every lowering path
       funnels here, so reject the size-(>1) case once, centrally, rather than letting
       the layout below produce garbage. *)
    If[AnyTrue[presentAtoms, IntegerQ[#] && # > 1 &], Throw[$Failed, einThrowTag]];
    (* Option A (einx-faithful): give each *duplicated* literal-integer OUTPUT axis a
       unique anonymous identity, sized to its value, so two equal literals (e.g.
       'a 2 2') are DISTINCT broadcast axes — matching einx, which broadcasts
       'a -> a 2 2' to (...,2,2).  A literal that occurs once keeps its integer value, so
       it still repeats (when output-only) or carries (e.g. a singleton summand preserved
       as 'b (q+1) -> b q, b 1'); only genuine duplicates need fresh identities. *)
    Module[{litCounts = Counts[Cases[rhsTerms, _Integer, {0, Infinity}]]},
      rhsTerms2 = Replace[rhsTerms,
        n_Integer /; litCounts[n] > 1 :>
          With[{u = Unique["lit$"]}, env2 = Append[env2, u -> n]; u],
        {0, Infinity}]];
    rhsAtoms = If[rhsTerms2 === {}, {},
      Join @@ Table[rearrangeAtoms[t], {t, rhsTerms2}]];
    (* Backstop: after literal uniquification any remaining duplicate is a real identity
       collision — a repeated NAME — which would make the FirstPosition layout below
       ambiguous; reject rather than leak an unevaluated ArrayReshape.  (Named output
       dups are normally rejected upstream; this covers any caller that bypasses that.) *)
    If[! DuplicateFreeQ[rhsAtoms], Throw[$Failed, einThrowTag]];
    (* Every output atom must resolve to a *positive integer* size.  atomSize Throws on
       an unbound name; a name bound to 0 / a negative / a non-integer, or a literal
       <= 0 immediate, is rejected here.  EinstoffShapes validates this for the paths
       that go through it; callers that bypass it (Massage sizes via EinstoffMatch to
       allow a within-tensor repeat) rely on this guard so bad dims cannot reach
       ArrayReshape and leak as an unevaluated expression. *)
    If[! AllTrue[rhsAtoms, With[{s = atomSize[#, env2]}, IntegerQ[s] && s >= 1] &],
      Throw[$Failed, einThrowTag]];
    (* A present axis absent from the output must be *squeezable*: only a size-1 (unit)
       axis carries no data and may be dropped.  A dropped size-(>1) axis (named or
       literal) is a reduction — keeping it in `present` and then reshaping to the smaller
       output dims would silently TRUNCATE data (the DirectSum concat/split paths hit
       exactly this).  Every lowering path funnels here, so enforce the invariant once,
       centrally — do NOT trust callers to pre-reject it (Massage additionally prechecks
       for a clearer message; DirectSum/Reduce/Map/Dot rely on this guard). *)
    If[AnyTrue[presentAtoms, ! MemberQ[rhsAtoms, #] && atomSize[#, env2] > 1 &],
      Throw[$Failed, einThrowTag]];
    (* Squeeze the surviving size-1 (unit) dropped axes by reshaping to the kept dims. *)
    present = Select[presentAtoms, MemberQ[rhsAtoms, #] &];
    If[present =!= presentAtoms, acc = reshapeTo[acc, atomSize[#, env2] & /@ present]];
    repeats = Select[rhsAtoms, ! MemberQ[present, #] &];
    (* Broadcast each repeat axis on as a new leading axis. *)
    Do[acc = ConstantArray[acc, atomSize[r, env2]], {r, repeats}];
    (* Scalar output: nothing to permute or recompose. *)
    If[rhsAtoms === {}, Return[First @ Flatten @ {acc}]];
    (* acc's axes after the broadcasts: Reverse[repeats] then present. *)
    order = Join[Reverse[repeats], present];
    srcOrder = Flatten[FirstPosition[order, #] & /@ rhsAtoms];
    If[Length[srcOrder] > 1, acc = Transpose[acc, InversePermutation[srcOrder]]];
    outDims = (Times @@ (atomSize[#, env2] & /@ rearrangeAtoms[#])) & /@ rhsTerms2;
    reshapeTo[acc, outDims]];

(* ------------------------------------------------------------------ *)
(* Within-tensor (self-) contraction.  einsum-style: a name repeated   *)
(* within one operand's atom list and absent from the output is summed  *)
(* over its coincident slots (a partial trace, e.g. Ricci R^a_bad).     *)
(*                                                                      *)
(* Reshapes `x` to its atomic dims, then for each repeated dropped name *)
(* contracts that pair of slots via ResourceFunction["ArrayContract"]   *)
(* (Plus, with the explicit array depth — the 3-arg form mis-levels).   *)
(* Returns {atomicTensor, survivingAtoms}: the atomic-granularity array  *)
(* and its remaining atom labels (contracted positions removed).  With  *)
(* no repeats it is just the atomic reshape (no resource-function call). *)
(*                                                                      *)
(* Only *pairwise* contraction is tensorial: a name kept on the output  *)
(* would be a diagonal (deferred) and a name occurring >2 times a       *)
(* super-diagonal (non-tensorial) — both Throw $Failed loudly.          *)
(* Throws (caught by the caller) on an unbound axis too.                *)
(* ------------------------------------------------------------------ *)

selfContract[x_, lhsAtoms_, rhsAtoms_, env_] :=
  Module[{dims, xr, names, repeated, groups, ndims},
    dims = atomSize[#, env] & /@ lhsAtoms;        (* Throws if unbound *)
    xr = reshapeTo[x, dims];                       (* scalar-safe (dims may be {}) *)
    names = DeleteCases[lhsAtoms, _Integer];
    repeated = Select[DeleteDuplicates[names], Count[lhsAtoms, #] >= 2 &];
    If[repeated === {}, Return[{xr, lhsAtoms}]];
    If[AnyTrue[repeated, MemberQ[rhsAtoms, #] &],
      Message[Einstoff::unsupp,
        "a repeated axis is kept on the output (a diagonal) — not supported yet; \
drop the axis to contract it"];
      Throw[$Failed, einThrowTag]];
    If[AnyTrue[repeated, Count[lhsAtoms, #] > 2 &],
      Message[Einstoff::unsupp,
        "an axis occurs more than twice (a super-diagonal) — only pairwise \
contraction is supported (it is the geometrically meaningful, tensorial case)"];
      Throw[$Failed, einThrowTag]];
    (* Disjoint position pairs, one per repeated name.  Table (not &/@) keeps the
       per-name body off an anonymous Function (SPEC 7.2 discipline). *)
    groups = Table[Flatten[Position[lhsAtoms, n]], {n, repeated}];
    ndims = Length[lhsAtoms];
    {ResourceFunction["ArrayContract"][xr, groups, Plus, ndims],
     Delete[lhsAtoms, List /@ Flatten[groups]]}];
