(* ::Package:: *)

(* Einstoff lowering — shared hub.

   Each lowering path (operator) lives in its own file under Kernel/:

     Reshape.wl   Einstoff["Massage"]    / EinstoffMassage (univalent engine:
                  Einstoff[ArrayReshape] alias; rearrange/repeat/direct-sum +
                  within-tensor pairwise contraction)
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
within-tensor pairwise contraction), Einstoff[ArrayReshape] (currently a Massage \
alias), Einstoff[ArrayReduce][reducer] (reduction), Einstoff[Map][f] (shape-preserving \
elementary op along a bracketed axis — flip/sort/softmax/…), Einstoff[Dot] (einsum \
contraction) and its generalization Einstoff[Inner][mul, add], Einstoff[\"einsum\"] \
(the pairwise-contraction subset, within- and cross-tensor), Einstoff[Join]/[Split] \
(direct sum). Applied as op[desc, tensors, bindings]; the reducer, map fn and \
(mul, add) are curried.";

(* Shared diagnostics for every lowering path. *)
Einstoff::unsupp = "`1`";
Einstoff::unsat =
  "description is not satisfiable against the given tensor(s): `1`";

PackageScoped[{descParts, resolveSlotStrings, rearrangeAtoms, atomSize, reduceAtoms,
  materializeOutput, selfContract, hasCirclePlus, directSumConcat, directSumSplit}]

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

(* CirclePlus is associative; canonicalize a ⊕ (b ⊕ c) to a flat summand list so
   the direct-sum paths see one CirclePlus with all summands (order preserved —
   CirclePlus is not Orderless). Mirrors flattenDirectSum in the shape layer. *)
descParts[h : Hold[_Rule | _RuleDelayed]] :=
  With[{hr = resolveSlotStrings[h]},
    {Extract[hr, {1, 1}], ReleaseHold @ Extract[hr, {1, 2}, Hold]} //.
      CirclePlus[x___, CirclePlus[y___], z___] :> CirclePlus[x, y, z]];
descParts[_] := $Failed;

(* ------------------------------------------------------------------ *)
(* Atomic-axis decomposition of one dimension term.  An "atom" is an axis *)
(* that survives the transform unchanged (only its position / grouping    *)
(* changes).  Composites expand to their factors in order.                *)
(* ------------------------------------------------------------------ *)

(* Plain decomposition (no brackets): symbols, bindings, integers, products.
   Out-of-subset heads Throw[$Failed] (caught by the calling operator). *)
rearrangeAtoms[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
rearrangeAtoms[s_Symbol] := {s};
rearrangeAtoms[n_Integer] := {n};
rearrangeAtoms[CircleTimes[fs__]] := Join @@ (rearrangeAtoms /@ {fs});
rearrangeAtoms[other_] := (
  Message[Einstoff::unsupp,
    "unsupported term: " <> ToString[other, InputForm] <>
      " (direct sums and ellipses are not in the supported subset yet)"];
  Throw[$Failed]);

atomSize[n_Integer, _] := n;
atomSize[s_, env_] := Lookup[env, s, Throw[$Failed]];

(* Does any shape in `shapes` contain a CirclePlus (direct-sum) term?  Used to
   route a desc into the direct-sum path and to guard Join/Split direction. *)
hasCirclePlus[shapes_] := ! FreeQ[shapes, CirclePlus];

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
       Throw[$Failed])];

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
(* (reshape/reduce/dot) gets einx-style repeat for free.  Callers must  *)
(* ensure presentAtoms ⊆ rhsAtoms (any present axis must reach output). *)
(* ------------------------------------------------------------------ *)

materializeOutput[arr_, presentAtoms_, rhsTerms_, env_] :=
  Module[{env2 = env, rhsTerms2, rhsAtoms, repeats, acc = arr, order, srcOrder, outDims},
    (* A surviving INPUT literal-integer axis of size > 1 cannot be carried to the
       output: under Option A an output literal becomes a fresh anonymous broadcast
       axis, so an input literal has no output identity to map to (cf. einx rejecting
       'a 2 -> a 2').  A size-1 input literal is benign — it is squeezed (e.g. a
       singleton direct-sum summand block 'b (q+1) -> b q, b').  Every lowering path
       funnels here, so reject the size-(>1) case once, centrally, rather than letting
       the layout below produce garbage. *)
    If[AnyTrue[presentAtoms, IntegerQ[#] && # > 1 &], Throw[$Failed]];
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
    If[! DuplicateFreeQ[rhsAtoms], Throw[$Failed]];
    (* Every output atom must resolve to a *positive integer* size.  atomSize Throws on
       an unbound name; a name bound to 0 / a negative / a non-integer, or a literal
       <= 0 immediate, is rejected here.  EinstoffShapes validates this for the paths
       that go through it; callers that bypass it (Massage sizes via EinstoffMatch to
       allow a within-tensor repeat) rely on this guard so bad dims cannot reach
       ArrayReshape and leak as an unevaluated expression. *)
    If[! AllTrue[rhsAtoms, With[{s = atomSize[#, env2]}, IntegerQ[s] && s >= 1] &],
      Throw[$Failed]];
    repeats = Select[rhsAtoms, ! MemberQ[presentAtoms, #] &];
    (* Broadcast each repeat axis on as a new leading axis. *)
    Do[acc = ConstantArray[acc, atomSize[r, env2]], {r, repeats}];
    (* Scalar output: nothing to permute or recompose. *)
    If[rhsAtoms === {}, Return[First @ Flatten @ {acc}]];
    (* acc's axes after the broadcasts: Reverse[repeats] then presentAtoms. *)
    order = Join[Reverse[repeats], presentAtoms];
    srcOrder = Flatten[FirstPosition[order, #] & /@ rhsAtoms];
    If[Length[srcOrder] > 1, acc = Transpose[acc, InversePermutation[srcOrder]]];
    outDims = (Times @@ (atomSize[#, env2] & /@ rearrangeAtoms[#])) & /@ rhsTerms2;
    ArrayReshape[acc, outDims]];

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
    xr = ArrayReshape[x, dims];
    names = DeleteCases[lhsAtoms, _Integer];
    repeated = Select[DeleteDuplicates[names], Count[lhsAtoms, #] >= 2 &];
    If[repeated === {}, Return[{xr, lhsAtoms}]];
    If[AnyTrue[repeated, MemberQ[rhsAtoms, #] &],
      Message[Einstoff::unsupp,
        "a repeated axis is kept on the output (a diagonal) — not supported yet; \
drop the axis to contract it"];
      Throw[$Failed]];
    If[AnyTrue[repeated, Count[lhsAtoms, #] > 2 &],
      Message[Einstoff::unsupp,
        "an axis occurs more than twice (a super-diagonal) — only pairwise \
contraction is supported (it is the geometrically meaningful, tensorial case)"];
      Throw[$Failed]];
    (* Disjoint position pairs, one per repeated name.  Table (not &/@) keeps the
       per-name body off an anonymous Function (SPEC 7.2 discipline). *)
    groups = Table[Flatten[Position[lhsAtoms, n]], {n, repeated}];
    ndims = Length[lhsAtoms];
    {ResourceFunction["ArrayContract"][xr, groups, Plus, ndims],
     Delete[lhsAtoms, List /@ Flatten[groups]]}];
