(* ::Package:: *)

BeginTestSection["Einstoff`Planner"];

ClearAll[a, b, c, h, r, w];

compile = Symbol["Einstoff`PackageScope`compileDescIR"];
solve = Symbol["Einstoff`PackageScope`solveDescIR"];
plan = Symbol["Einstoff`PackageScope`planStructuralIR"];
planContract = Symbol["Einstoff`PackageScope`planSelfContractIR"];
execute = Symbol["Einstoff`PackageScope`executeExecutionPlan"];
render = Symbol["Einstoff`PackageScope`renderExecutionPlan"];
planReduce = Symbol["Einstoff`PackageScope`planReduceIR"];
planMap = Symbol["Einstoff`PackageScope`planMapIR"];
planInner = Symbol["Einstoff`PackageScope`planInnerIR"];
planDirectSum = Symbol["Einstoff`PackageScope`planDirectSumIR"];
ir[name_] := Symbol["Einstoff`Internal`IR`" <> name];

makePlan[desc_, x_, bindings_ : {}, op_ : "Reshape"] :=
  plan[solve[compile[desc, bindings], {Dimensions[x]}]["Solved"], op];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    execute[makePlan[{{a_, b_}} :> {{b, a}}, x], {x}]],
  Transpose @ ArrayReshape[Range[6], {2, 3}],
  TestID -> "plan-execute-transpose"
];

VerificationTest[
  With[{x = Range[12]},
    execute[makePlan[{{CircleTimes["h", w_]}} :> {{"h", w}}, x, {"h" -> 3}], {x}]],
  ArrayReshape[Range[12], {3, 4}],
  TestID -> "plan-execute-split"
];

VerificationTest[
  With[{x = Range[3]},
    execute[makePlan[{{a_}} :> {{a, Annotation[c, 2]}}, x, {}, "Massage"], {x}]],
  ConstantArray[Range[3], {2}] // Transpose,
  TestID -> "plan-execute-broadcast"
];

VerificationTest[
  With[{x = ArrayReshape[Range[3], {1, 3}]},
    execute[makePlan[{{1, a_}} :> {{a}}, x], {x}]],
  Range[3],
  TestID -> "plan-execute-unit-squeeze"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}], p, hld},
    p = makePlan[{{a_, b_}} :> {{b, a}}, x];
    hld = render[p, {x}];
    {Head[hld], ReleaseHold[hld] === execute[p, {x}]}],
  {HoldComplete, True},
  TestID -> "plan-render-parity"
];

VerificationTest[
  Head @ makePlan[{{a_}} :> {{a, Annotation[c, 2]}}, Range[3], {}, "Reshape"],
  ir["FailureRecord"],
  TestID -> "plan-reshape-rejects-broadcast"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}]],
  Transpose @ ArrayReshape[Range[6], {2, 3}],
  TestID -> "plan-public-reshape-integration"
];

VerificationTest[
  With[{x = Range[3]},
    Einstoff["Massage"][{{a_}} :> {{a, Annotation[c, 2]}}, {x}]],
  ConstantArray[Range[3], {2}] // Transpose,
  TestID -> "plan-public-massage-integration"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[24], {2, 3, 4}], p},
    p = planReduce[
      solve[compile[{{a_, b_, c_}} :> {{c, a}}], {Dimensions[x]}]["Solved"],
      Total];
    execute[p, {x}]],
  Transpose[Total[ArrayReshape[Range[24], {2, 3, 4}], {2}], {2, 1}],
  TestID -> "plan-execute-reduce-and-permute"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReduce][Total][{{a_, Highlighted[b_]}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[6], {2, 3}], {2}],
  TestID -> "plan-public-reduce-integration"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}], held},
    held = Einstoff[ArrayReduce][Total][
      {{a_, Highlighted[b_]}} :> {{a}}, {x}, {}, TraceAction -> Hold];
    {Head[held], ReleaseHold[held]}],
  {Hold, Total[ArrayReshape[Range[6], {2, 3}], {2}]},
  TestID -> "plan-public-reduce-trace"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[8], {2, 4}], p},
    p = planMap[
      solve[compile[{{a_, Highlighted[b_]}} :> {{a, b}}],
        {Dimensions[x]}]["Solved"],
      Reverse, True];
    execute[p, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "plan-execute-target-block"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[8], {2, 4}], p, held},
    p = planMap[
      solve[compile[{{a_, Highlighted[b_]}} :> {{a, b}}],
        {Dimensions[x]}]["Solved"],
      Reverse, True];
    held = render[p, {x}];
    {Head[held], ReleaseHold[held] === execute[p, {x}]}],
  {HoldComplete, True},
  TestID -> "plan-render-target-block-parity"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[8], {2, 4}], p},
    p = planMap[
      solve[compile[{{a_, Highlighted[b_]}} :> {{a, b}}],
        {Dimensions[x]}]["Solved"],
      Total, True];
    Head @ execute[p, {x}]],
  ir["FailureRecord"],
  TestID -> "plan-target-block-shape-failure"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[8], {2, 4}], calls = 0, held},
    held = Einstoff[Operate][(calls++; Reverse[#]) &][
      {{a_, Highlighted[b_]}} :> {{a, b}}, {x}, {}, TraceAction -> Hold];
    {calls, Head[held], ReleaseHold[held]; calls}],
  {2, Hold, 4},
  TestID -> "plan-target-block-trace-evaluation-count"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[12], {3, 4}], p},
    p = planInner[
      solve[compile[{{a_, b_}, {b_, c_}} :> {{a, c}}],
        {Dimensions[x], Dimensions[y]}]["Solved"],
      Times, Plus, Automatic];
    execute[p, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "plan-execute-inner-step"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[12], {3, 4}], p, held},
    p = planInner[
      solve[compile[{{a_, b_}, {b_, c_}} :> {{a, c}}],
        {Dimensions[x], Dimensions[y]}]["Solved"],
      Times, Plus, Automatic];
    held = render[p, {x, y}];
    {Head[held], ReleaseHold[held] === execute[p, {x, y}]}],
  {HoldComplete, True},
  TestID -> "plan-render-inner-step-parity"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[24], {2, 3, 4}],
      y = ArrayReshape[Range[40], {2, 4, 5}], p},
    p = planInner[
      solve[compile[{{a_, b_, c_}, {a_, c_, d_}} :> {{a, b, d}}],
        {Dimensions[x], Dimensions[y]}]["Solved"],
      Plus, Min, Automatic];
    execute[p, {x, y}]],
  MapThread[Inner[Plus, #1, #2, Min] &,
    {ArrayReshape[Range[24], {2, 3, 4}],
      ArrayReshape[Range[40], {2, 4, 5}]}],
  TestID -> "plan-execute-batched-generalized-inner"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[12], {3, 4}],
      z = ArrayReshape[Range[20], {4, 5}], p},
    p = planInner[
      solve[compile[{{a_, b_}, {b_, c_}, {c_, d_}} :> {{a, d}}],
        {Dimensions[x], Dimensions[y], Dimensions[z]}]["Solved"],
      Times, Plus, Automatic];
    execute[p, {x, y, z}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}] .
    ArrayReshape[Range[20], {4, 5}],
  TestID -> "plan-execute-variadic-inner"
];

VerificationTest[
  Module[{p},
    p = planInner[
      solve[compile[{{a_}, {a_}, {b_}} :> {{b}}],
        {{3}, {3}, {4}}]["Solved"],
      Times, Plus, Automatic];
    execute[p, {Range[3], Range[3], Range[4]}]],
  (Range[3] . Range[3]) Range[4],
  TestID -> "plan-execute-scalar-contraction-intermediate"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[12], {3, 4}], p},
    p = planInner[
      solve[compile[
          {{a_, Highlighted[b_]}, {Highlighted[b_], c_}} :>
            {{a, c, Annotation[r, 2]}}],
        {Dimensions[x], Dimensions[y]}]["Solved"],
      Times, Plus, Automatic];
    Dimensions @ execute[p, {x, y}]],
  {2, 4, 2},
  TestID -> "plan-execute-contract-then-broadcast"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[8], {2, 4}], solved, p},
    solved = solve[compile[
      {{a_, b_}, {a_, c_}} :> {{a, CirclePlus[b, c]}}],
      {Dimensions[x], Dimensions[y]}]["Solved"];
    p = planDirectSum[solved, "Join"];
    execute[p, {x, y}]],
  Join[ArrayReshape[Range[6], {2, 3}],
    ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "plan-execute-direct-sum-join"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[20], {2, 10}], solved, p},
    solved = solve[compile[
      {{a_, CirclePlus[Annotation[b, 3], c_]}} :> {{a, b}, {a, c}}],
      {Dimensions[x]}]["Solved"];
    p = planDirectSum[solved, "Split"];
    execute[p, {x}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 10}]}],
  TestID -> "plan-execute-direct-sum-split"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[15] - 1, {3, 5}], solved, p},
    solved = solve[compile[
      {{CirclePlus[Annotation[a, 1], d_],
        CirclePlus[Annotation[b, 2], c_]}} :>
        {{a, b}, {a, c}, {d, b}, {d, c}}],
      {Dimensions[x]}]["Solved"];
    p = planDirectSum[solved, "Split"];
    execute[p, {x}]],
  With[{x = ArrayReshape[Range[15] - 1, {3, 5}]},
    {Take[x, {1, 1}, {1, 2}], Take[x, {1, 1}, {3, 5}],
     Take[x, {2, 3}, {1, 2}], Take[x, {2, 3}, {3, 5}]}],
  TestID -> "plan-execute-cartesian-direct-sum-split"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[8], {2, 4}], solved, p, held},
    solved = solve[compile[
      {{a_, b_}, {a_, c_}} :> {{a, CirclePlus[b, c]}}],
      {Dimensions[x], Dimensions[y]}]["Solved"];
    p = planDirectSum[solved, "Join"];
    held = render[p, {x, y}];
    {Head[held], ReleaseHold[held] === execute[p, {x, y}]}],
  {HoldComplete, True},
  TestID -> "plan-render-direct-sum-join-parity"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[20], {2, 10}], solved, p, held},
    solved = solve[compile[
      {{a_, CirclePlus[Annotation[b, 3], c_]}} :> {{b, a}, {a, c}}],
      {Dimensions[x]}]["Solved"];
    p = planDirectSum[solved, "Split"];
    held = render[p, {x}];
    {Head[held], ReleaseHold[held] === execute[p, {x}]}],
  {HoldComplete, True},
  TestID -> "plan-render-direct-sum-split-parity"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[16], {2, 2, 2, 2}], p},
    p = planContract[
      solve[compile[{{a_, b_, a_, c_}} :> {{c, b}}],
        {Dimensions[x]}]["Solved"],
      "Contract", Automatic];
    execute[p, {x}]],
  Transpose @ TensorContract[ArrayReshape[Range[16], {2, 2, 2, 2}],
    {{1, 3}}],
  TestID -> "plan-execute-self-contraction"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[27], {3, 3, 3}], p},
    p = planContract[
      solve[compile[
        {{"a", Highlighted["a"], Highlighted["a"]}} :> {{"a"}}],
        {Dimensions[x]}]["Solved"],
      "Contract", Automatic];
    execute[p, {x}]],
  With[{x = ArrayReshape[Range[27], {3, 3, 3}]},
    Table[Sum[x[[i, j, j]], {j, 3}], {i, 3}]],
  TestID -> "plan-execute-targeted-pair-with-carrier"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[9], {3, 3}], p, held},
    p = planContract[
      solve[compile[{{a_, a_}} :> {{}}], {Dimensions[x]}]["Solved"],
      "Contract", Automatic];
    held = render[p, {x}];
    {Head[held], ReleaseHold[held] === execute[p, {x}]}],
  {HoldComplete, True},
  TestID -> "plan-render-self-contraction-parity"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[16], {2, 2, 2, 2}], held},
    held = Einstoff["einsum"][{{a_, b_, a_, c_}} :> {{c, b}},
      {x}, {}, TraceAction -> Hold];
    {! FreeQ[held, _TensorContract],
      ReleaseHold[held] ===
        Einstoff["einsum"][{{a_, b_, a_, c_}} :> {{c, b}}, {x}]}],
  {True, True},
  TestID -> "plan-public-einsum-self-contraction-trace"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[480], {2, 6, 8, 5}], solvedDesc, p},
    solvedDesc = solve[compile[
      {{b_, grp : (CircleTimes[s_, Highlighted["ds"]]).., c_}} :>
        {{b, s.., c}},
      {"ds" -> 2}], {Dimensions[x]}]["Solved"];
    p = planReduce[solvedDesc, Total];
    execute[p, {x}]],
  Total[Total[ArrayReshape[Range[480], {2, 3, 2, 4, 2, 5}], {5}], {3}],
  TestID -> "plan-execute-structured-sequence-reduction"
];

VerificationTest[
  Module[{x = ArrayReshape[Range[6], {2, 3}],
      y = ArrayReshape[Range[35], {5, 7}], solvedDesc, p},
    solvedDesc = solve[compile[{{a__}, {b__}} :>
      {MapThread[CircleTimes, {{a}, {b}}]}],
      {Dimensions[x], Dimensions[y]}]["Solved"];
    p = planInner[solvedDesc, Times, Plus, Automatic];
    execute[p, {x, y}]],
  ArrayReshape[
    Table[
      ArrayReshape[Range[6], {2, 3}][[i1, j1]] *
        ArrayReshape[Range[35], {5, 7}][[i2, j2]],
      {i1, 2}, {i2, 5}, {j1, 3}, {j2, 7}],
    {10, 21}],
  TestID -> "plan-execute-declarative-sequence-zip"
];

EndTestSection[];
