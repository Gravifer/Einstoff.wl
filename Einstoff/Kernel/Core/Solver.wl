(* ::Package:: *)

(* Explicit positive-integer shape constraints over normalized IR.  Algebraic solver
   variables are Indexed expressions keyed by AxisId's integer payload; no symbol is
   created per logical axis. *)

PackageScoped[{buildConstraintDesc, solveConstraintDesc, solveDescIR}]

irs[name_String] := Symbol["Einstoff`Internal`IR`" <> name];

solveDescIR[compiled_Association, inputShapes_] :=
  Module[{normalized, constraints, solved},
    normalized = Lookup[compiled, "Normalized", Missing["Normalized"]];
    If[solverFailureQ[normalized],
      Return[Join[compiled, <|"Constraints" -> normalized, "Solved" -> normalized|>]]];
    constraints = buildConstraintDesc[normalized, inputShapes];
    If[solverFailureQ[constraints],
      Return[Join[compiled, <|"Constraints" -> constraints, "Solved" -> constraints|>]]];
    solved = solveConstraintDesc[constraints];
    Join[compiled, <|"Constraints" -> constraints, "Solved" -> solved|>]
  ];

buildConstraintDesc[normalized : irs["NormalizedDesc"][a_Association],
    inputShapes_] :=
  Module[{inputIR, shapes, constraints = {}, bindings, terms, r},
    If[! MatchQ[inputShapes, {___List}],
      Return[solverFailure["InvalidInputShapes", "Constraints",
        <|"InputShapes" -> HoldComplete[inputShapes]|>]]];
    inputIR = a["Inputs"];
    shapes = Replace[inputIR, irs["Inputs"][s_List] :> s];
    If[! ListQ[shapes] || Length[shapes] =!= Length[inputShapes],
      Return[solverFailure["OperandCountMismatch", "Constraints",
        <|"Expected" -> If[ListQ[shapes], Length[shapes], Missing[]],
          "Actual" -> Length[inputShapes]|>]]];
    bindings = Replace[a["Bindings"], irs["BindingFacts"][f_List] :> f];
    Do[
      AppendTo[constraints,
        Replace[fact, irs["BindingFact"][id_, size_, source_] :>
          irs["KnownSize"][id, size, source]]],
      {fact, bindings}];
    Do[
      terms = Replace[shapes[[i]], irs["Shape"][t_List] :> t];
      If[! ListQ[terms] || Length[terms] =!= Length[inputShapes[[i]]],
        Return[solverFailure["RankMismatch", "Constraints",
          <|"Input" -> i, "Expected" -> If[ListQ[terms], Length[terms], Missing[]],
            "Actual" -> Length[inputShapes[[i]]]|>]]];
      Do[
        r = sizeExpression[terms[[j]]];
        If[solverFailureQ[r], Return[r]];
        AppendTo[constraints, irs["EqualSize"][r, inputShapes[[i, j]],
          <|"Input" -> i, "Dimension" -> j|>]],
        {j, Length[terms]}],
      {i, Length[shapes]}];
    irs["ConstraintDesc"][<|
      "Normalized" -> normalized,
      "InputShapes" -> inputShapes,
      "Constraints" -> irs["Constraints"][constraints]
    |>]
  ];
buildConstraintDesc[other_, inputShapes_] :=
  solverFailure["ExpectedNormalizedDesc", "Constraints",
    <|"Expression" -> HoldComplete[other],
      "InputShapes" -> HoldComplete[inputShapes]|>];

sizeExpression[irs["AxisOccurrence"][_, id_, _]] := irs["SizeAxis"][id];
sizeExpression[irs["LiteralAxis"][_, n_Integer, _]] := irs["SizeLiteral"][n];
sizeExpression[irs["ProductAxis"][_, children_List, _]] :=
  sizeComposite["SizeProduct", children];
sizeExpression[irs["DirectSumAxis"][_, children_List, _]] :=
  sizeComposite["SizeSum", children];
sizeExpression[other_] := solverFailure["UnsupportedSizeTerm", "Constraints",
  <|"Expression" -> HoldComplete[other]|>];

sizeComposite[head_String, children_List] :=
  Module[{out = {}, r},
    Do[
      r = sizeExpression[child];
      If[solverFailureQ[r], Return[r]];
      AppendTo[out, r],
      {child, children}];
    irs[head][out]
  ];

solveConstraintDesc[constraint : irs["ConstraintDesc"][a_Association]] :=
  Module[{normalized, constraints, axisIds, variables, idToVariable, equations,
          result, concrete, rules, axisSizes, outputs, outShapes},
    normalized = a["Normalized"];
    constraints = Replace[a["Constraints"], irs["Constraints"][c_List] :> c];
    axisIds = DeleteDuplicates @ Cases[normalized,
      id : irs["AxisId"][_Integer] :> id, Infinity];
    variables = solverVariable /@ axisIds;
    idToVariable = AssociationThread[axisIds, variables];
    equations = constraintEquation[#, idToVariable] & /@ constraints;
    If[AnyTrue[equations, solverFailureQ],
      Return[First @ Select[equations, solverFailureQ]]];
    result = Quiet @ Check[
      Solve[Join[equations, Thread[variables > 0]], variables, Integers], $Failed];
    If[result === $Failed || result === {},
      Return[solverFailure["UnsatisfiableConstraints", "Solve",
        <|"Constraints" -> constraint|>]]];
    concrete = Select[result,
      AllTrue[variables /. #, IntegerQ[#] && # > 0 &] &];
    If[Length[concrete] =!= 1,
      Return[solverFailure[
        If[concrete === {}, "UnderdeterminedConstraints", "NonUniqueConstraints"],
        "Solve", <|"Solutions" -> result|>]]];
    rules = First[concrete];
    axisSizes = AssociationThread[axisIds, variables /. rules];
    outputs = Replace[normalized,
      irs["NormalizedDesc"][na_Association] :> na["Outputs"]];
    outShapes = concreteOutputShapes[outputs, axisSizes];
    If[solverFailureQ[outShapes], Return[outShapes]];
    irs["SolvedDesc"][<|
      "Normalized" -> normalized,
      "Constraints" -> constraint,
      "InputShapes" -> a["InputShapes"],
      "OutputShapes" -> outShapes,
      "AxisSizes" -> axisSizes
    |>]
  ];
solveConstraintDesc[other_] := solverFailure["ExpectedConstraintDesc", "Solve",
  <|"Expression" -> HoldComplete[other]|>];

solverVariable[irs["AxisId"][n_Integer]] := Indexed[solverAxis, {n}];

constraintEquation[irs["KnownSize"][id_, n_, _], vars_Association] :=
  If[IntegerQ[n] && n > 0, vars[id] == n,
    solverFailure["InvalidKnownSize", "Constraints",
      <|"Axis" -> id, "Value" -> HoldComplete[n]|>]];
constraintEquation[irs["EqualSize"][expr_, n_Integer, _], vars_Association] :=
  algebraicSize[expr, vars] == n;
constraintEquation[other_, _] := solverFailure["UnsupportedConstraint", "Constraints",
  <|"Constraint" -> HoldComplete[other]|>];

algebraicSize[irs["SizeAxis"][id_], vars_Association] := vars[id];
algebraicSize[irs["SizeLiteral"][n_Integer], _] := n;
algebraicSize[irs["SizeProduct"][xs_List], vars_Association] :=
  Times @@ Table[algebraicSize[x, vars], {x, xs}];
algebraicSize[irs["SizeSum"][xs_List], vars_Association] :=
  Plus @@ Table[algebraicSize[x, vars], {x, xs}];

concreteOutputShapes[irs["Outputs"][shapes_List], sizes_Association] :=
  Module[{out = {}, terms, dims, value},
    Do[
      terms = Replace[shape, irs["Shape"][t_List] :> t];
      dims = {};
      Do[
        value = concreteTermSize[term, sizes];
        If[solverFailureQ[value], Return[value]];
        AppendTo[dims, value],
        {term, terms}];
      AppendTo[out, dims],
      {shape, shapes}];
    out
  ];
concreteOutputShapes[other_, _] := solverFailure["InvalidOutputIR", "Solve",
  <|"Expression" -> HoldComplete[other]|>];

concreteTermSize[term_, sizes_Association] :=
  Module[{expr = sizeExpression[term], value},
    If[solverFailureQ[expr], Return[expr]];
    value = algebraicSize[expr, Association @ KeyValueMap[
      (#1 -> #2) &, sizes]];
    If[IntegerQ[value] && value > 0, value,
      solverFailure["UnresolvedOutputSize", "Solve",
        <|"Term" -> HoldComplete[term], "Value" -> value|>]]
  ];

solverFailure[tag_, stage_, details_Association] :=
  irs["FailureRecord"][tag, stage, details];
solverFailureQ[expr_] := Head[Unevaluated[expr]] === irs["FailureRecord"];
