(* ::Package:: *)

BeginTestSection["Einstoff`Planner"];

ClearAll[a, b, c, h, w];

compile = Symbol["Einstoff`PackageScope`compileDescIR"];
solve = Symbol["Einstoff`PackageScope`solveDescIR"];
plan = Symbol["Einstoff`PackageScope`planStructuralIR"];
execute = Symbol["Einstoff`PackageScope`executeExecutionPlan"];
render = Symbol["Einstoff`PackageScope`renderExecutionPlan"];
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

EndTestSection[];
