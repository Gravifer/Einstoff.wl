(* ::Package:: *)

(* Einstoff lowering — shared hub.

   Each lowering path (operator) lives in its own file under Kernel/:

     Reshape.wl   Einstoff[ArrayReshape] / EinstoffRearrange
     Reduce.wl    Einstoff[ArrayReduce]  / EinstoffReduce  (curried in the reducer)
     Map.wl       Einstoff[Map]          / EinstoffMap     (curried in the map fn)
     Dot.wl       Einstoff[Dot]/[Inner]  / EinstoffDot, EinstoffInner (Inner curried)
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
  "Einstoff[op] yields the Einstoff operator implementing op: \
Einstoff[ArrayReshape] (rearrange/reshape), Einstoff[ArrayReduce][reducer] \
(reduction), Einstoff[Map][f] (shape-preserving elementary op along a bracketed \
axis — flip/sort/softmax/…), Einstoff[Dot] (einsum contraction) and its \
generalization Einstoff[Inner][mul, add], Einstoff[Join]/[Split] (direct sum). \
Applied as op[desc, tensors, bindings]; the reducer, map fn and (mul, add) are \
curried.";

(* Shared diagnostics for every lowering path. *)
Einstoff::unsupp = "`1`";
Einstoff::unsat =
  "description is not satisfiable against the given tensor(s): `1`";

PackageScoped[{descParts, rearrangeAtoms, atomSize, reduceAtoms, materializeOutput,
  hasCirclePlus, directSumConcat, directSumSplit}]

(* ------------------------------------------------------------------ *)
(* desc parsing.  Operators are HoldFirst and pass Hold[desc] in, so the *)
(* RHS stays held until bindings are substituted; we extract lhs and the *)
(* (released) rhs shape lists.  Returns $Failed if desc isn't lhs :> rhs. *)
(* ------------------------------------------------------------------ *)

(* CirclePlus is associative; canonicalize a ⊕ (b ⊕ c) to a flat summand list so
   the direct-sum paths see one CirclePlus with all summands (order preserved —
   CirclePlus is not Orderless). Mirrors flattenDirectSum in the shape layer. *)
descParts[h : Hold[_Rule | _RuleDelayed]] :=
  {Extract[h, {1, 1}], ReleaseHold @ Extract[h, {1, 2}, Hold]} //.
    CirclePlus[x___, CirclePlus[y___], z___] :> CirclePlus[x, y, z];
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
  Module[{rhsAtoms, repeats, acc = arr, order, srcOrder, outDims},
    rhsAtoms = If[rhsTerms === {}, {},
      Join @@ Table[rearrangeAtoms[t], {t, rhsTerms}]];
    repeats = Select[rhsAtoms, ! MemberQ[presentAtoms, #] &];
    (* Broadcast each repeat axis on as a new leading axis. *)
    Do[acc = ConstantArray[acc, atomSize[r, env]], {r, repeats}];
    (* Scalar output: nothing to permute or recompose. *)
    If[rhsAtoms === {}, Return[First @ Flatten @ {acc}]];
    (* acc's axes after the broadcasts: Reverse[repeats] then presentAtoms. *)
    order = Join[Reverse[repeats], presentAtoms];
    srcOrder = Flatten[FirstPosition[order, #] & /@ rhsAtoms];
    If[Length[srcOrder] > 1, acc = Transpose[acc, InversePermutation[srcOrder]]];
    outDims = (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ rhsTerms;
    ArrayReshape[acc, outDims]];
