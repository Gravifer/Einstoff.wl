(* ::Package:: *)

BeginTestSection["Einstoff`Analysis"];

ClearAll[a, b, c];

compile = Symbol["Einstoff`PackageScope`compileDescIR"];
solve = Symbol["Einstoff`PackageScope`solveDescIR"];
analyze = Symbol["Einstoff`PackageScope`analyzeSolvedDesc"];
ir[name_] := Symbol["Einstoff`Internal`IR`" <> name];

analysis[desc_, shapes_, bindings_, op_, targeting_ : Automatic] :=
  analyze[solve[compile[desc, bindings], shapes]["Solved"], op, targeting];

VerificationTest[
  Cases[analysis[{{a_, b_}} :> {{b, a}}, {{2, 3}}, {}, "Reshape"],
    ir["Carried"][id_, _, _] :> id, Infinity],
  {ir["AxisId"][1], ir["AxisId"][2]},
  TestID -> "analysis-carried-reshape-axes"
];

VerificationTest[
  Cases[analysis[{{a_, b_}} :> {{a}}, {{2, 3}}, {}, "Reduce"],
    ir["Reduced"][id_, _] :> id, Infinity],
  {ir["AxisId"][2]},
  TestID -> "analysis-reduced-axis"
];

VerificationTest[
  Cases[analysis[{{a_, a_}} :> {{}}, {{3, 3}}, {}, "Contract"],
    ir["Contracted"][id_, kind_, _] :> {id, kind}, Infinity],
  {{ir["AxisId"][1], "Within"}},
  TestID -> "analysis-within-contraction"
];

VerificationTest[
  Cases[analysis[{{a_, b_}, {b_, c_}} :> {{a, c}},
      {{2, 3}, {3, 4}}, {}, "Dot"],
    ir["Contracted"][id_, kind_, _] :> {id, kind}, Infinity],
  {{ir["AxisId"][2], "Cross"}},
  TestID -> "analysis-cross-contraction"
];

VerificationTest[
  Cases[analysis[{{a_}} :> {{a, Annotation[c, 2]}}, {{3}}, {}, "Massage"],
    ir["Broadcast"][id_, n_, _] :> {id, n}, Infinity],
  {{ir["AxisId"][2], 2}},
  TestID -> "analysis-broadcast-axis"
];

VerificationTest[
  Replace[
    analysis[{{a_}} :> {{a, Annotation[c, 2]}}, {{3}}, {}, "Reshape"],
    ir["OperationAnalysis"][x_Association] :> x["Valid"]],
  False,
  TestID -> "analysis-reshape-rejects-nonunit-broadcast"
];

VerificationTest[
  Cases[analysis[{{a_, Highlighted[b_]}} :> {{a}}, {{2, 3}}, {}, "Reduce", True],
    ir["TargetPolicy"][p_Association] :> p, Infinity],
  {<|"Infer" -> False, "ValidateExplicit" -> True, "RequireExplicit" -> True|>},
  TestID -> "analysis-target-policy-triple"
];

VerificationTest[
  Replace[
    analysis[{{a_, Highlighted[b_]}} :> {{a}}, {{2, 3}}, {}, "Map"],
    ir["OperationAnalysis"][x_Association] :> x["Valid"]],
  True,
  TestID -> "analysis-map-allows-target-block-collapse"
];

VerificationTest[
  Replace[
    analysis[{{a_, b_, Highlighted[c_]}} :> {{a, c}}, {{2, 4, 3}}, {}, "Map"],
    ir["OperationAnalysis"][x_Association] :> x["Valid"]],
  False,
  TestID -> "analysis-map-rejects-untargeted-disappearance"
];

EndTestSection[];
