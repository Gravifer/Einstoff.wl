(* ::Package:: *)

(* Einstoff lowering — shared hub.

   Each lowering path (operator) lives in its own file under Kernel/:

     Reshape.wl   Einstoff["Massage"]    / EinstoffMassage (univalent engine:
                  rearrange/repeat/direct-sum + within-tensor pairwise contraction) and
                  its two guards Einstoff[ArrayReshape]/EinstoffReshape (bijective) and
                  Einstoff["ArrayContract"]/EinstoffContract (no repetition)
     Reduce.wl    Einstoff[ArrayReduce]  / EinstoffReduce  (curried in the reducer)
     Map.wl       Einstoff[Map]/[Operate] / EinstoffMap, EinstoffOperate
                  (curried in the map fn)
     Dot.wl       Einstoff[Dot]/[Inner]  / EinstoffDot, EinstoffInner (Inner curried)
     Einsum.wl    Einstoff["einsum"]     / EinstoffEinsum  (dispatch: 1 tensor ->
                  Massage, >=2 -> Dot fold; pairwise-contraction subset)
     DirectSum.wl Einstoff[Join]/[Split] / EinstoffJoin (CirclePlus concat/split)

   This hub holds what the staged executor paths share: the public `Gravifer`Einstoff` operator
   symbol and messages, scalar-safe array primitives, held trace builders, and tagged
   user-code isolation. ShapeChecker.wl owns surface hygiene; Planner.wl owns all
   backend-neutral analysis, planning, and execution.

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
Einstoff[Operate][f] (shape-preserving operation along a targeted axis: \
flip/sort/softmax/…), Einstoff[Map][f] (general blockwise map), Einstoff[Dot] \
(einsum contraction) and its generalization \
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
(* The internal Gravifer`Einstoff`Axis` identity context has been externally populated with a value
   that cannot be cleared (Protected and Locked).  Non-fatal: a fresh internal identity is
   used instead, but the user should not assign to Gravifer`Einstoff`Axis` symbols. *)
(* NB the template text carries NO literal backticks: a backtick collides with the `1`
   slot syntax (StringForm::sfr).  The Protected+Locked symbol's full name is passed as
   the argument, whose value backticks are rendered literally, not re-parsed. *)
Einstoff::privctx =
  "the internal axis symbol `1` carries an external value that cannot be cleared (it is \
Protected and Locked); using an inert display identity instead. Do not assign to symbols \
in Einstoff's reserved internal axis-identity context.";

PackageScoped[{atomSize, heldReshape, heldArrayReduce, heldTranspose,
  heldConstantArray, heldValue, heldTake, heldMapAt, heldApply,
  heldMapThreadDot, heldMapThreadInner, heldJoin, heldList, reshapeTo,
  einThrowTag, einCatch, traceActionEnabledQ, traceReturnHeld,
  validateTargetingOption}]

(* Internal control-flow tag. Boundary helpers throw a structured FailureRecord and the
   operator-facing einCatch translates it to the established message/$Failed contract.
   The TAG is load-bearing: several paths run
   *user-supplied* functions inside the caught region — Inner's (mul, add), ArrayReduce's
   reducer, Map's f — and a user function that itself throws (untagged, or with its own
   tag) must propagate OUT rather than be swallowed as our $Failed sentinel.  Scoping every
   internal throw/catch to einThrowTag isolates our control flow from the user's.
   einThrowTag needs no definition — an undefined package symbol is a unique, stable tag. *)
SetAttributes[einCatch, HoldFirst];
einCatch[expr_] := Catch[expr, einThrowTag,
  Function[payload,
    If[Head[payload] === Gravifer`Einstoff`Internal`IR`FailureRecord,
      reportPlannerFailure[payload], payload]]];

loweringFailure[tag_String, details_Association] :=
  Gravifer`Einstoff`Internal`IR`FailureRecord[tag, "Boundary",
    Join[<|"MessageParameters" -> {}|>, details]];

traceActionEnabledQ[None | False | Identity] := False;
traceActionEnabledQ[_] := True;

traceReturnHeld[HoldComplete[expr_], action_] :=
  If[traceActionEnabledQ[action], Apply[action, Hold[expr]], expr];

validateTargetingOption[mode_] :=
  If[! MatchQ[mode, False | Automatic | True],
    Throw[loweringFailure["InvalidTargetPolicy", <|
      "Reason" -> "\"Targeting\" must be False, Automatic, or True",
      "Actual" -> HoldComplete[mode],
      "Expected" -> {False, Automatic, True}|>], einThrowTag],
    mode];

atomSize[n_Integer, _] := n;
atomSize[s_, env_] := Lookup[env, s,
  Throw[loweringFailure["MissingAxisSize", <|"Axis" -> s|>], einThrowTag]];

(* Scalar-safe ArrayReshape: dims === {} means rank-0 (a scalar), where ArrayReshape
   would leak unevaluated — return the lone element instead.  An empty shape {} (a
   scalar operand) and a fully-squeezed array both land here. *)
reshapeTo[arr_, {}] := First @ Flatten @ {arr};
reshapeTo[arr_, dims_] := ArrayReshape[arr, dims];

heldReshape[HoldComplete[e_], {}] := HoldComplete[First[Flatten[{e}]]];
heldReshape[HoldComplete[e_], dims_] :=
  With[{d = dims}, HoldComplete[ArrayReshape[e, d]]];
heldConstantArray[HoldComplete[e_], dim_] :=
  With[{d = dim}, HoldComplete[ConstantArray[e, d]]];
heldTranspose[HoldComplete[e_], perm_] :=
  With[{p = perm}, HoldComplete[Transpose[e, p]]];
heldArrayReduce[HoldComplete[e_], reducer_, pos_] :=
  With[{f = reducer, p = pos}, HoldComplete[ArrayReduce[f, e, p]]];
heldValue[e_] := With[{v = e}, HoldComplete[v]];
heldTake[HoldComplete[e_], specs_List] :=
  With[{s = specs}, HoldComplete[Take[e, Sequence @@ s]]];
heldMapAt[HoldComplete[e_], f_, level_] :=
  With[{fn = f, lev = level}, HoldComplete[Map[fn, e, {lev}]]];
heldApply[HoldComplete[e_], f_] :=
  With[{fn = f}, HoldComplete[fn[e]]];
heldMapThreadDot[HoldComplete[e1_], HoldComplete[e2_]] :=
  HoldComplete[MapThread[Dot, {e1, e2}]];
heldMapThreadInner[mul_, add_, HoldComplete[e1_], HoldComplete[e2_]] :=
  With[{m = mul, a = add}, HoldComplete[MapThread[Inner[m, #1, #2, a] &, {e1, e2}]]];
heldJoin[helds_List, n_] :=
  ToExpression[
    "HoldComplete[Join[Sequence @@ {" <> StringRiffle[heldExprString /@ helds, ", "] <>
      "}, " <> ToString[n, InputForm] <> "]]",
    InputForm,
    Identity];
heldExprString[HoldComplete[e_]] := ToString[Unevaluated[e], InputForm];
heldList[helds_List] :=
  ToExpression[
    "HoldComplete[{" <> StringRiffle[heldExprString /@ helds, ", "] <> "}]",
    InputForm,
    Identity];
