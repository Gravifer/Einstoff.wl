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

   This hub holds what the runtime lowerers share: the public `Einstoff` operator
   symbol and messages, atomic-axis decomposition, output materialization, held trace
   builders, and self-contraction.  The shape-DSL checker/hygiene layer lives in
   ShapeChecker.wl.  Every path turns a satisfiable description (resolved by
   Einstoff`Parsing`) into native array ops — ArrayReshape / Transpose /
   ArrayReduce / Dot — over atomic axes.

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
(* The internal Einstoff`Axis` identity context has been externally populated with a value
   that cannot be cleared (Protected and Locked).  Non-fatal: a fresh internal identity is
   used instead, but the user should not assign to Einstoff`Axis` symbols. *)
(* NB the template text carries NO literal backticks: a backtick collides with the `1`
   slot syntax (StringForm::sfr).  The Protected+Locked symbol's full name is passed as
   the argument, whose value backticks are rendered literally, not re-parsed. *)
Einstoff::privctx =
  "the internal axis symbol `1` carries an external value that cannot be cleared (it is \
Protected and Locked); using a fresh internal identity instead. Do not assign to symbols \
in Einstoff's reserved internal axis-identity context.";

PackageScoped[{rearrangeAtoms, atomSize, reduceAtoms, targetDecomposeTerms,
  plainSequenceCount, anonymousSequence, anonymousCaptureAtomList,
  expandAnonymousTargetRhs, materializeOutput, selfContract,
  materializeOutputTrace, materializeOutputExprHeld, heldReshape, heldArrayReduce,
  heldTranspose, heldConstantArray, heldValue, heldTake, heldTakeValue, heldMap, heldMapAt, heldApply,
  heldMapThreadDot,
  heldMapThreadInner, heldJoin, heldList,
  reshapeTo, directSumConcat, directSumSplit, einThrowTag, einCatch,
  traceActionEnabledQ, traceReturn, traceReturnHeld, validateTargetingOption,
  validateTargetingPositions}]

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

traceActionEnabledQ[None | False | Identity] := False;
traceActionEnabledQ[_] := True;

SetAttributes[traceReturn, HoldFirst];
traceReturn[expr_, action_] :=
  If[traceActionEnabledQ[action], Apply[action, Hold[expr]], expr];

traceReturnHeld[HoldComplete[expr_], action_] :=
  If[traceActionEnabledQ[action], Apply[action, Hold[expr]], expr];

validateTargetingOption[mode_] :=
  If[! MatchQ[mode, False | Automatic | True],
    Message[Einstoff::unsupp,
      "\"Targeting\" must be False, Automatic, or True"];
    Throw[$Failed, einThrowTag],
    mode];

validateTargetingPositions[mode_, targetedPos_, operatedPos_, context_String] :=
  Module[{t = Sort[targetedPos], o = Sort[operatedPos]},
    validateTargetingOption[mode];
    Which[
      mode === False, Null,
      mode === Automatic && t =!= {} && t =!= o,
        Message[Einstoff::unsupp,
          context <> ": targeted axes must exactly match the operated axes when \
\"Targeting\" -> Automatic"];
        Throw[$Failed, einThrowTag],
      mode === True && t =!= o,
        Message[Einstoff::unsupp,
          context <> ": operated axes must be explicitly targeted when \
\"Targeting\" -> True"];
        Throw[$Failed, einThrowTag],
      True, Null]];


(* ------------------------------------------------------------------ *)
(* Atomic-axis decomposition of one dimension term.  An "atom" is an axis *)
(* that survives the transform unchanged (only its position / grouping    *)
(* changes).  Composites expand to their factors in order.                *)
(* ------------------------------------------------------------------ *)

(* Plain decomposition (no targeting): symbols, blanks, integers, products.
   Out-of-subset heads Throw[$Failed, einThrowTag] (recovered by einCatch in the
   calling operator). *)
rearrangeAtoms[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
rearrangeAtoms[s_Symbol] := {s};
rearrangeAtoms[n_Integer] := {n};
rearrangeAtoms[{}] := {1};   (* in-shape unit-axis term {} == literal 1 (einx "()") *)
rearrangeAtoms[CircleTimes[fs__]] := Join @@ (rearrangeAtoms /@ {fs});
rearrangeAtoms[t_ /; bracketWrapperQ[t]] :=
  Join @@ Table[rearrangeAtoms[f], {f, List @@ t}];
rearrangeAtoms[other_] := (
  Message[Einstoff::unsupp,
    "unsupported term: " <> ToString[other, InputForm] <>
      " (direct sums and unexpanded ellipses are not in the supported subset yet)"];
  Throw[$Failed, einThrowTag]);

atomSize[n_Integer, _] := n;
atomSize[s_, env_] := Lookup[env, s, Throw[$Failed, einThrowTag]];

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
heldTakeValue[e_, specs_List] :=
  With[{v = e, s = specs}, HoldComplete[Take[v, Sequence @@ s]]];
heldMap[HoldComplete[e_], f_] :=
  With[{fn = f}, HoldComplete[Map[fn, e]]];
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


(* Target-aware decomposition: like rearrangeAtoms but unwraps target wrappers
   (Slot, Highlighted, Framed), returning {atom, targetedQ} pairs.  NB Table/List@@
   rather than `&/@`: a factor can be Slot[...], and routing it through an anonymous
   Function would reinterpret an integer Slot as that function's argument slot (SPEC 7.2).
   Variable-arity ellipses are out of scope and Throw. *)
reduceAtoms[t_, br_ : False] :=
  Which[
    MatchQ[t, Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]], {{t[[1]], br}},
    Head[t] === Symbol, {{t, br}},
    StringQ[t], {{Symbol[t], br}},   (* #name target: Slot["name"] -> axis name *)
    t === {}, {{1, br}},             (* in-shape unit-axis term {} == literal 1 *)
    IntegerQ[t], {{t, br}},
    Head[t] === CircleTimes,
      Join @@ Table[reduceAtoms[f, br], {f, List @@ t}],
    bracketWrapperQ[t],
      Join @@ Table[reduceAtoms[f, True], {f, List @@ t}],
    True,
      (Message[Einstoff::unsupp,
        "unsupported term: " <> ToString[t, InputForm] <>
          " (direct sums and unexpanded variable-arity ellipses are not in the \
supported subset here)"];
       Throw[$Failed, einThrowTag])];

targetSequenceQ[t_] :=
  MatchQ[t, Verbatim[BlankSequence[]] | Verbatim[BlankNullSequence[]]] ||
    Head[t] === SlotSequence;

targetSequenceMin[t_] := If[MatchQ[t, Verbatim[BlankSequence[]]], 1, 0];

plainSequenceCount[terms_List] :=
  Count[terms, Verbatim[BlankSequence[]] | Verbatim[BlankNullSequence[]], {1}];

termDimCount[t_] :=
  Which[
    targetSequenceQ[t], targetSequenceMin[t],
    bracketWrapperQ[t] && Length[t] === 1 && targetSequenceQ[First[t]],
      targetSequenceMin[First[t]],
    True, 1];

anonymousTargetAtom[size_, env_] :=
  Module[{u = Unique["target$", {Temporary}]},
    {u, Append[env, u -> size]}];

namedSequenceSpec[Verbatim[Pattern][s_Symbol, Verbatim[BlankSequence[]]]] :=
  <|"Outer" -> s, "Body" -> Blank[], "Min" -> 1, "Named" -> True|>;
namedSequenceSpec[Verbatim[Pattern][s_Symbol, Verbatim[BlankNullSequence[]]]] :=
  <|"Outer" -> s, "Body" -> Blank[], "Min" -> 0, "Named" -> True|>;
namedSequenceSpec[Verbatim[Pattern][s_Symbol, Verbatim[Repeated][body_]]] :=
  <|"Outer" -> s, "Body" -> body, "Min" -> 1, "Named" -> True|>;
namedSequenceSpec[Verbatim[Pattern][s_Symbol, Verbatim[RepeatedNull][body_]]] :=
  <|"Outer" -> s, "Body" -> body, "Min" -> 0, "Named" -> True|>;
namedSequenceSpec[Verbatim[Repeated][body_]] :=
  <|"Outer" -> None, "Body" -> body, "Min" -> 1, "Named" -> False|>;
namedSequenceSpec[Verbatim[RepeatedNull][body_]] :=
  <|"Outer" -> None, "Body" -> body, "Min" -> 0, "Named" -> False|>;
namedSequenceSpec[_] := None;

namedSequenceInnerBinders[body_] := DeleteDuplicates @ Cases[body,
  Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> s, {0, Infinity}];

renameSequenceBody[body_, rules_] := body /. Join[
  Table[
    With[{old = First[r], new = Last[r]},
      Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] /; s === old :> new],
    {r, rules}],
  Table[
    With[{old = First[r], new = Last[r]},
      s_Symbol /; s === old :> new],
    {r, rules}]];

namedSequenceLength[spec_Association, seq_Association, dimsLeft_Integer] :=
  Module[{keys, lengths},
    keys = Join[
      If[spec["Named"], {spec["Outer"]}, {}],
      namedSequenceInnerBinders[spec["Body"]]];
    lengths = Lookup[seq, keys, Missing["NoCapture"]];
    lengths = DeleteCases[lengths, Missing["NoCapture"]];
    Which[
      lengths =!= {} && SameQ @@ (Length /@ lengths), First[Length /@ lengths],
      lengths =!= {}, $Failed,
      True, dimsLeft]];

(* Package-private payload for one captured anonymous sequence run.  Keep the run grouped until
   the RHS occurrence that consumes it is expanded; do not use active Sequence or public
   Inactive[Sequence], since this is an internal correspondence token. *)
anonymousCaptureAtomList[captures_List] :=
  Join @@ Table[
    Replace[c, {
      anonymousSequence[xs___] :> {xs},
      other_ :> {other}}],
    {c, captures}];

namedCaptureAtomList[captures_Association, key_] :=
  With[{v = Lookup[captures, key, Missing["NoCapture"]]},
    If[MissingQ[v], {}, anonymousCaptureAtomList[{v}]]];

targetDecomposeTerm[t_, d_, env_, br_] :=
  Module[{atoms, env2 = env, atom},
    If[MatchQ[t, Verbatim[Blank[]]],
      {atom, env2} = anonymousTargetAtom[d, env2];
      Return[{{{atom, br}}, env2, {}}]];
    If[br && IntegerQ[t],
      If[t =!= d, Throw[$Failed, einThrowTag]];
      {atom, env2} = anonymousTargetAtom[t, env2];
      Return[{{{atom, True}}, env2, {atom}}]];
    If[br && Head[t] === CirclePlus,
      {atom, env2} = anonymousTargetAtom[d, env2];
      Return[{{{atom, True}}, env2, {atom}}]];
    atoms = Join @@ Table[rearrangeAtoms[f], {f, {t}}];
    If[(Times @@ (atomSize[#, env2] & /@ atoms)) =!= d,
      Throw[$Failed, einThrowTag]];
    {{#, br} & /@ atoms, env2, {}}];

targetDecomposeTerms[terms_List, dims_List, env_, seq_ : <||>] :=
  Module[{tagged = {}, anonymous = {}, named = <||>, env2 = env, workTerms,
          expandFactor, expandTerm, addNamed, vals, seqAtoms, pos = 1, i, t,
          restTerms, minRest, k, atom, group, parts, td, anon, spec, body, inner,
          rules, fresh, renamed, captures, j, outerGroup},
    addNamed[key_, atoms_] := (
      If[KeyExistsQ[named, key], Throw[$Failed, einThrowTag]];
      named = Append[named, key -> (anonymousSequence @@ atoms)]);
    expandFactor[f_] := Which[
      MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[BlankSequence[]]]] &&
          KeyExistsQ[seq, f[[1]]],
        vals = seq[f[[1]]];
        If[! ListQ[vals] || Length[vals] < 1 ||
            ! AllTrue[vals, IntegerQ[#] && # >= 1 &],
          Throw[$Failed, einThrowTag]];
        seqAtoms = Table[
          {atom, env2} = anonymousTargetAtom[v, env2]; atom,
          {v, vals}];
        addNamed[f[[1]], seqAtoms];
        seqAtoms,
      MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[BlankNullSequence[]]]] &&
          KeyExistsQ[seq, f[[1]]],
        vals = seq[f[[1]]];
        If[! ListQ[vals] || ! AllTrue[vals, IntegerQ[#] && # >= 1 &],
          Throw[$Failed, einThrowTag]];
        seqAtoms = Table[
          {atom, env2} = anonymousTargetAtom[v, env2]; atom,
          {v, vals}];
        addNamed[f[[1]], seqAtoms];
        If[seqAtoms === {}, {1}, seqAtoms],
      True, {f}];
    expandTerm[t_] := Which[
      Head[t] === CircleTimes, CircleTimes @@ Flatten[expandFactor /@ (List @@ t)],
      bracketWrapperQ[t], Head[t] @@ (expandTerm /@ (List @@ t)),
      True, t];
    workTerms = expandTerm /@ terms;
    If[plainSequenceCount[workTerms] > 1,
      Message[Einstoff::unsupp,
        "multiple plain anonymous sequences (__ / ___) in one shape are ambiguous; \
support for matching more than one is deferred"];
      Throw[$Failed, einThrowTag]];
    For[i = 1, i <= Length[workTerms], i++,
      t = workTerms[[i]];
      Which[
        AssociationQ[spec = namedSequenceSpec[t]],
          body = spec["Body"];
          If[! FreeQ[HoldComplete[body],
              Verbatim[Repeated][_] | Verbatim[RepeatedNull][_] |
                Verbatim[PatternSequence][___]],
            Message[Einstoff::unsupp,
              "nested named axis-sequences and PatternSequence are not supported in lowering"];
            Throw[$Failed, einThrowTag]];
          restTerms = Drop[workTerms, i];
          minRest = Total[termDimCount /@ restTerms];
          k = namedSequenceLength[spec, seq, Length[dims] - pos + 1 - minRest];
          If[k === $Failed || k < spec["Min"] || k > Length[dims] - pos + 1 - minRest,
            Throw[$Failed, einThrowTag]];
          inner = namedSequenceInnerBinders[body];
          captures = Association@Table[key -> {}, {key, inner}];
          outerGroup = {};
          Do[
            If[body === Blank[],
              {atom, env2} = anonymousTargetAtom[dims[[pos]], env2];
              AppendTo[tagged, {atom, False}];
              AppendTo[outerGroup, atom],
              rules = Table[old -> Unique[SymbolName[old] <> "$seq$", {Temporary}],
                {old, inner}];
              fresh = Last /@ rules;
              vals = Lookup[seq, inner, Missing["NoCapture"]];
              If[Length[inner] > 0,
                If[! ListQ[vals] || MemberQ[vals, Missing["NoCapture"]] ||
                    ! AllTrue[vals, Length[#] >= j &],
                  Throw[$Failed, einThrowTag]];
                Do[env2 = Append[env2, fresh[[p]] -> vals[[p, j]]],
                  {p, Length[fresh]}]];
              renamed = renameSequenceBody[body, rules];
              {td, env2, anon} = targetDecomposeTerm[renamed, dims[[pos]], env2, False];
              tagged = Join[tagged, td];
              anonymous = Join[anonymous, anon];
              Do[captures[inner[[p]]] = Append[captures[inner[[p]]], fresh[[p]]],
                {p, Length[inner]}];
              outerGroup = Join[outerGroup, td[[All, 1]]]];
            pos++,
            {j, k}];
          If[spec["Named"], named = Append[named, spec["Outer"] -> (anonymousSequence @@ outerGroup)]];
          Do[named = Append[named, key -> (anonymousSequence @@ captures[key])],
            {key, Keys[captures]}],
        bracketWrapperQ[t] && Length[t] === 1 && targetSequenceQ[First[t]],
          restTerms = Drop[workTerms, i];
          minRest = Total[termDimCount /@ restTerms];
          k = Length[dims] - pos + 1 - minRest;
          If[k < targetSequenceMin[First[t]], Throw[$Failed, einThrowTag]];
          group = {};
          Do[
            {atom, env2} = anonymousTargetAtom[dims[[pos]], env2];
            AppendTo[tagged, {atom, True}];
            AppendTo[group, atom];
            pos++,
            {k}];
          AppendTo[anonymous, anonymousSequence @@ group],
        Head[t] === SlotSequence,
          restTerms = Drop[workTerms, i];
          minRest = Total[termDimCount /@ restTerms];
          k = Length[dims] - pos + 1 - minRest;
          If[k < targetSequenceMin[t], Throw[$Failed, einThrowTag]];
          group = {};
          Do[
            {atom, env2} = anonymousTargetAtom[dims[[pos]], env2];
            AppendTo[tagged, {atom, True}];
            AppendTo[group, atom];
            pos++,
            {k}];
          AppendTo[anonymous, anonymousSequence @@ group],
        targetSequenceQ[t],
          restTerms = Drop[workTerms, i];
          minRest = Total[termDimCount /@ restTerms];
          k = Length[dims] - pos + 1 - minRest;
          If[k < targetSequenceMin[t], Throw[$Failed, einThrowTag]];
          group = {};
          Do[
            {atom, env2} = anonymousTargetAtom[dims[[pos]], env2];
            AppendTo[tagged, {atom, False}];
            AppendTo[group, atom];
            pos++,
            {k}];
          AppendTo[anonymous, anonymousSequence @@ group],
        bracketWrapperQ[t],
          parts = List @@ t;
          If[Length[parts] === 1,
            {td, env2, anon} = targetDecomposeTerm[First[parts], dims[[pos]], env2, True],
            td = Join @@ Table[reduceAtoms[p, True], {p, parts}];
            If[(Times @@ (atomSize[#, env2] & /@ td[[All, 1]])) =!= dims[[pos]],
              Throw[$Failed, einThrowTag]];
            anon = {}];
          tagged = Join[tagged, td];
          anonymous = Join[anonymous, anon];
          pos++,
        True,
          {td, env2, anon} = targetDecomposeTerm[t, dims[[pos]], env2, False];
          tagged = Join[tagged, td];
          anonymous = Join[anonymous, anon];
          pos++]];
    If[pos =!= Length[dims] + 1, Throw[$Failed, einThrowTag]];
    <|"Tagged" -> tagged, "Env" -> env2, "AnonymousTargetAtoms" -> anonymous,
      "NamedSequenceAtoms" -> named|>];

expandAnonymousTargetRhs[terms_List, anonAtoms_List, namedAtoms_ : <||>] :=
  Module[{q = anonAtoms, expand},
    expand[t_] := Which[
      MatchQ[t, Verbatim[Repeated][_Symbol] | Verbatim[RepeatedNull][_Symbol]] &&
          KeyExistsQ[namedAtoms, First[t]],
        namedCaptureAtomList[namedAtoms, First[t]],
      Head[t] === CircleTimes,
        {CircleTimes @@ Flatten[expand /@ (List @@ t)]},
      bracketWrapperQ[t],
        {Head[t] @@ Flatten[expand /@ (List @@ t)]},
      True, {t}];
    If[plainSequenceCount[terms] > 1,
      Message[Einstoff::unsupp,
        "multiple plain anonymous sequences (__ / ___) in one shape are ambiguous; \
support for matching more than one is deferred"];
      Throw[$Failed, einThrowTag]];
    Flatten @ Table[
      Which[
        MatchQ[t, Verbatim[Repeated][_Symbol] | Verbatim[RepeatedNull][_Symbol]] &&
            KeyExistsQ[namedAtoms, First[t]],
          namedCaptureAtomList[namedAtoms, First[t]],
        bracketWrapperQ[t] && Length[t] === 1 && targetSequenceQ[First[t]],
          With[{a = anonymousCaptureAtomList[q]}, q = {}; a],
        Head[t] === SlotSequence,
          With[{a = anonymousCaptureAtomList[q]}, q = {}; a],
        targetSequenceQ[t],
          With[{a = anonymousCaptureAtomList[q]}, q = {}; a],
        bracketWrapperQ[t] && Length[t] === 1 && IntegerQ[First[t]] && q =!= {},
          With[{a = First[q]}, q = Rest[q]; a],
        True, expand[t]],
      {t, terms}]];

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
          (* Temporary: an internal layout identity for a duplicated output literal; used
             within this function then discarded (never in the result), so it GCs rather
             than persisting in the caller's context — consistent with the axis symbols. *)
          With[{u = Unique["lit$", {Temporary}]}, env2 = Append[env2, u -> n]; u],
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

materializeOutputExpr[arr_, presentAtoms_, rhsTerms_, env_] :=
  materializeOutputExprHeld[HoldComplete[arr], presentAtoms, rhsTerms, env];

materializeOutputExprHeld[acc0_HoldComplete, presentAtoms_, rhsTerms_, env_] :=
  Module[{env2 = env, rhsTerms2, rhsAtoms, present, repeats, acc = acc0, order,
          srcOrder, outDims},
    If[AnyTrue[presentAtoms, IntegerQ[#] && # > 1 &], Throw[$Failed, einThrowTag]];
    Module[{litCounts = Counts[Cases[rhsTerms, _Integer, {0, Infinity}]]},
      rhsTerms2 = Replace[rhsTerms,
        n_Integer /; litCounts[n] > 1 :>
          With[{u = Unique["lit$", {Temporary}]}, env2 = Append[env2, u -> n]; u],
        {0, Infinity}]];
    rhsAtoms = If[rhsTerms2 === {}, {},
      Join @@ Table[rearrangeAtoms[t], {t, rhsTerms2}]];
    If[! DuplicateFreeQ[rhsAtoms], Throw[$Failed, einThrowTag]];
    If[! AllTrue[rhsAtoms, With[{s = atomSize[#, env2]}, IntegerQ[s] && s >= 1] &],
      Throw[$Failed, einThrowTag]];
    If[AnyTrue[presentAtoms, ! MemberQ[rhsAtoms, #] && atomSize[#, env2] > 1 &],
      Throw[$Failed, einThrowTag]];
    present = Select[presentAtoms, MemberQ[rhsAtoms, #] &];
    If[present =!= presentAtoms,
      acc = heldReshape[acc, atomSize[#, env2] & /@ present]];
    repeats = Select[rhsAtoms, ! MemberQ[present, #] &];
    Do[acc = heldConstantArray[acc, atomSize[r, env2]], {r, repeats}];
    If[rhsAtoms === {}, Return[heldReshape[acc, {}]]];
    order = Join[Reverse[repeats], present];
    srcOrder = Flatten[FirstPosition[order, #] & /@ rhsAtoms];
    If[Length[srcOrder] > 1, acc = heldTranspose[acc, InversePermutation[srcOrder]]];
    outDims = (Times @@ (atomSize[#, env2] & /@ rearrangeAtoms[#])) & /@ rhsTerms2;
    heldReshape[acc, outDims]];

SetAttributes[materializeOutputTrace, HoldFirst];
materializeOutputTrace[arr_, presentAtoms_, rhsTerms_, env_, action_] :=
  If[traceActionEnabledQ[action],
    traceReturnHeld[materializeOutputExpr[arr, presentAtoms, rhsTerms, env], action],
    materializeOutput[arr, presentAtoms, rhsTerms, env]];

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

selfContract[x_, lhsAtoms_, rhsAtoms_, env_, targeting_ : False,
    lhsTargeted_ : Automatic] :=
  Module[{dims, xr, names, repeated, groups, ndims, br, atoms, positions,
          targetedPositions, remainingPositions},
    dims = atomSize[#, env] & /@ lhsAtoms;        (* Throws if unbound *)
    xr = reshapeTo[x, dims];                       (* scalar-safe (dims may be {}) *)
    validateTargetingOption[targeting];
    br = If[lhsTargeted === Automatic,
      ConstantArray[False, Length[lhsAtoms]],
      lhsTargeted];
    If[Length[br] =!= Length[lhsAtoms], Throw[$Failed, einThrowTag]];
    If[targeting === True || (targeting === Automatic && AnyTrue[br, TrueQ]),
      atoms = DeleteDuplicates[DeleteCases[lhsAtoms, _Integer]];
      groups = {};
      Do[
        positions = Flatten[Position[lhsAtoms, ax]];
        targetedPositions = Select[positions, TrueQ[br[[#]]] &];
        remainingPositions = Complement[positions, targetedPositions];
        Which[
          targetedPositions === {} && Length[positions] >= 2 && targeting === True,
            Message[Einstoff::unsupp,
              "a repeated axis is contracted without explicit targeting; target the \
pair or set \"Targeting\" -> Automatic/False"];
            Throw[$Failed, einThrowTag],
          targetedPositions === {} && Length[positions] >= 2,
            If[MemberQ[rhsAtoms, ax],
              Message[Einstoff::unsupp,
                "a repeated axis is kept on the output (a diagonal); this is not \
supported yet. drop the axis to contract it"];
              Throw[$Failed, einThrowTag]];
            If[Length[positions] > 2,
              Message[Einstoff::unsupp,
                "an axis occurs more than twice (a super-diagonal); only pairwise \
contraction is supported (it is the geometrically meaningful, tensorial case)"];
              Throw[$Failed, einThrowTag]];
            AppendTo[groups, positions],
          targetedPositions =!= {},
            If[Length[targetedPositions] =!= 2,
              Message[Einstoff::unsupp,
                "a targeted within-tensor contraction must target exactly two \
occurrences of an axis"];
              Throw[$Failed, einThrowTag]];
            If[MemberQ[rhsAtoms, ax] && Length[remainingPositions] =!= 1,
              Message[Einstoff::unsupp,
                "a targeted within-tensor contraction kept on the output needs exactly \
one untargeted occurrence of that axis to carry"];
              Throw[$Failed, einThrowTag]];
            If[Length[remainingPositions] > 1,
              Message[Einstoff::unsupp,
                "an axis has more than one untargeted occurrence after targeted \
contraction; diagonal/super-diagonal cases are not supported"];
              Throw[$Failed, einThrowTag]];
            AppendTo[groups, targetedPositions],
          True, Null],
        {ax, atoms}];
      If[groups === {}, Return[{xr, lhsAtoms}]];
      ndims = Length[lhsAtoms];
      Return[{ResourceFunction["ArrayContract"][xr, groups, Plus, ndims],
        Delete[lhsAtoms, List /@ Flatten[groups]]}]];
    names = DeleteCases[lhsAtoms, _Integer];
    repeated = Select[DeleteDuplicates[names], Count[lhsAtoms, #] >= 2 &];
    If[repeated === {}, Return[{xr, lhsAtoms}]];
    If[AnyTrue[repeated, MemberQ[rhsAtoms, #] &],
      Message[Einstoff::unsupp,
        "a repeated axis is kept on the output (a diagonal); this is not supported yet. \
drop the axis to contract it"];
      Throw[$Failed, einThrowTag]];
    If[AnyTrue[repeated, Count[lhsAtoms, #] > 2 &],
      Message[Einstoff::unsupp,
        "an axis occurs more than twice (a super-diagonal); only pairwise \
contraction is supported (it is the geometrically meaningful, tensorial case)"];
      Throw[$Failed, einThrowTag]];
    (* Disjoint position pairs, one per repeated name.  Table (not &/@) keeps the
       per-name body off an anonymous Function (SPEC 7.2 discipline). *)
    groups = Table[Flatten[Position[lhsAtoms, n]], {n, repeated}];
    ndims = Length[lhsAtoms];
    {ResourceFunction["ArrayContract"][xr, groups, Plus, ndims],
     Delete[lhsAtoms, List /@ Flatten[groups]]}];
