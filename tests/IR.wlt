(* ::Package:: *)

(* Invariants for the private staged IR. *)

BeginTestSection["Gravifer`Einstoff`Internal`IR"];

VerificationTest[
  Context[Einstoff],
  "Gravifer`Einstoff`",
  TestID -> "paclet-public-symbol-context"
];

VerificationTest[
  Names["Gravifer`Einstoff`*"] === {"Einstoff"},
  True,
  TestID -> "paclet-only-einstoff-is-public"
];

VerificationTest[
  Names["Einstoff`*"],
  {},
  TestID -> "paclet-does-not-create-legacy-context"
];

constructors = {
  "AxisId", "OccurrenceId", "SequenceMemberId", "SequenceOccurrence",
  "SurfaceDesc", "CapturedDesc",
  "NormalizedDesc", "ConstraintDesc", "SolvedDesc",
  "OperationAnalysis", "ExecutionPlan"
};

irSymbol[name_] := Symbol["Gravifer`Einstoff`Internal`IR`" <> name];
irValid = Symbol["Gravifer`Einstoff`PackageScope`irValidQ"];
compile = Symbol["Gravifer`Einstoff`PackageScope`compileDescIR"];
solve = Symbol["Gravifer`Einstoff`PackageScope`solveDescIR"];
analyze = Symbol["Gravifer`Einstoff`PackageScope`analyzeSolvedDesc"];
plan = Symbol["Gravifer`Einstoff`PackageScope`planStructuralIR"];

VerificationTest[
  Context /@ (irSymbol /@ constructors),
  ConstantArray["Gravifer`Einstoff`Internal`IR`", Length[constructors]],
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
  MemberQ[$ContextPath, "Gravifer`Einstoff`Internal`IR`"],
  False,
  TestID -> "ir-context-not-public"
];

VerificationTest[
  FreeQ[
    DownValues /@ {
      Gravifer`Einstoff`Private`irInternAxis,
      Gravifer`Einstoff`Private`compileHeldDescIR,
      Gravifer`Einstoff`Private`solveDescIR,
      Gravifer`Einstoff`Private`analyzeSolvedDesc,
      Gravifer`Einstoff`Private`planStructuralIR,
      Gravifer`Einstoff`Private`planSelfContractIR,
      Gravifer`Einstoff`Private`planReduceIR,
      Gravifer`Einstoff`Private`planMapIR,
      Gravifer`Einstoff`Private`tryMapIRPlan,
      Gravifer`Einstoff`Private`planInnerIR,
      Gravifer`Einstoff`Private`tryInnerIRPlan,
      Gravifer`Einstoff`Private`planDirectSumIR,
      Gravifer`Einstoff`Private`tryDirectSumIRPlan
    },
    _Return,
    Infinity,
    Heads -> True
  ],
  True,
  TestID -> "staged-core-does-not-use-return"
];

VerificationTest[
  Module[{compiled, solvedBundle, analysis, executionPlan, stages},
    compiled = compile[{{a_, b_}} :> {{b, a}}];
    solvedBundle = solve[compiled, {{2, 3}}];
    analysis = analyze[solvedBundle["Solved"], "Reshape", Automatic];
    executionPlan = plan[solvedBundle["Solved"], "Reshape"];
    stages = {compiled["Surface"], compiled["Captured"], compiled["Normalized"],
      solvedBundle["Constraints"], solvedBundle["Solved"], analysis,
      executionPlan};
    irValid /@ stages],
  ConstantArray[True, 7],
  TestID -> "ir-validator-accepts-every-compiler-stage"
];

VerificationTest[
  Module[{compiled, before},
    compiled = compile[{{a_, b_}} :> {{b, a}}];
    before = compiled;
    solve[compiled, {{2, 3}}];
    compiled === before],
  True,
  TestID -> "ir-stage-transformations-do-not-mutate-input"
];

EndTestSection[];
