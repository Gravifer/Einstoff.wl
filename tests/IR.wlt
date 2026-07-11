(* ::Package:: *)

(* Invariants for the private staged IR. *)

BeginTestSection["Einstoff`Internal`IR"];

constructors = {
  "AxisId", "OccurrenceId", "SurfaceDesc", "CapturedDesc",
  "NormalizedDesc", "ConstraintDesc", "SolvedDesc",
  "OperationAnalysis", "ExecutionPlan"
};

irSymbol[name_] := Symbol["Einstoff`Internal`IR`" <> name];

VerificationTest[
  Context /@ (irSymbol /@ constructors),
  ConstantArray["Einstoff`Internal`IR`", Length[constructors]],
  TestID -> "ir-constructor-context"
];

VerificationTest[
  MemberQ[Attributes[#], Protected] & /@ (irSymbol /@ constructors),
  ConstantArray[True, Length[constructors]],
  TestID -> "ir-constructors-protected"
];

VerificationTest[
  {OwnValues[#], DownValues[#], SubValues[#], UpValues[#]} & /@
    (irSymbol /@ constructors),
  ConstantArray[{{}, {}, {}, {}}, Length[constructors]],
  TestID -> "ir-constructors-inert"
];

VerificationTest[
  Attributes /@ (irSymbol /@ {"AxisId", "NormalizedDesc", "ExecutionPlan"}),
  ConstantArray[{Protected}, 3],
  TestID -> "ir-no-hold-attributes"
];

VerificationTest[
  With[{axis = irSymbol["AxisId"], occ = irSymbol["OccurrenceId"]},
    {axis[1], axis[2], occ[1]}],
  With[{axis = irSymbol["AxisId"], occ = irSymbol["OccurrenceId"]},
    {axis[1], axis[2], occ[1]}],
  TestID -> "ir-identities-are-inert-data"
];

VerificationTest[
  MemberQ[$ContextPath, "Einstoff`Internal`IR`"],
  False,
  TestID -> "ir-context-not-public"
];

EndTestSection[];

