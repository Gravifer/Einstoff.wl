(* ::Package:: *)

(* Map / Operate path.  Einstoff[Operate] is the shape-preserving targeted-block
   operation path for einx miscellaneous ops (flip, roll, sort, softmax,
   log_softmax, id): targeted axes are passed to f as one rectangular block, and
   f must return the same block shape.  Einstoff[Map] is the broader blockwise
   transform: the same target/vmap layout is used, but f may change the target
   block shape and the final result is validated against the RHS.

   Examples:
     Einstoff[Operate]["flip"]     reverse along the target   (einx.flip)
     Einstoff[Operate]["sort"]     sort along the target       (einx.sort)
     Einstoff[Operate]["softmax"]  softmax along the target    (einx.softmax)
     Einstoff[Operate][RotateLeft[#, 2] &]   roll              (einx.roll; the shift
       is a parameter, so roll is expressed as a function rather than a name).

   As with the reducer (and for the same reason — a hold attribute cannot survive
   the compound head EinstoffMap[f][…]), desc is NOT held; that is the uniform
   convention (a globally bound axis symbol substitutes, a bound integer reads as a
   literal dimension, illegal values are rejected by the matcher).

   Shared shape helpers (descParts, distinctAxesQ) live in ShapeChecker.wl; atom and
   materialization helpers live in Lowering.wl. *)

PackageExported[{EinstoffMap, EinstoffOperate}]

EinstoffMap::usage =
  "EinstoffMap[f][desc, tensors, bindings] realizes a blockwise transform of \
one tensor: targeted axes are fed to f as one rectangular block, every untargeted \
axis is vmapped, and the result is checked against the RHS shape. If there are no \
targets, f is mapped over scalar blocks.";

EinstoffOperate::usage =
  "EinstoffOperate[f][desc, tensors, bindings] realizes a shape-preserving \
targeted-block op (einx flip/roll/sort/softmax/log_softmax, einx.misc): the \
targeted axes are fed to f as one rectangular block and f must return the same \
block shape, while every untargeted axis is vmapped.";

Einstoff[Map] := EinstoffMap;
Einstoff["Map"] := EinstoffMap;
Einstoff[Operate] := EinstoffOperate;
Einstoff["Operate"] := EinstoffOperate;

Options[EinstoffMap] = {TraceAction -> None};
Options[EinstoffOperate] = {TraceAction -> None};

mapSoftmaxBlock[x_] :=
  Module[{v = Flatten[x], y},
    y = Exp[v - Max[v]];
    ArrayReshape[y/Total[y], Dimensions[x]]];

mapLogSoftmaxBlock[x_] :=
  Module[{v = Flatten[x], y},
    y = (v - Max[v]) - Log[Total[Exp[v - Max[v]]]];
    ArrayReshape[y, Dimensions[x]]];

(* Resolve a map spec to a target-block -> same-shape block function.  A raw function is used as-is;
   a convenience string is matched case-insensitively to the einx misc op of that
   name.  softmax/log_softmax use the max-shift stable form.  roll is omitted (its
   shift is a parameter — pass RotateLeft[#, k]& directly). *)
mapFunction[s_String] := Replace[ToLowerCase[s], {
  "id" | "identity" -> Identity,
  "flip" | "reverse" -> Reverse,
  "sort" -> Sort,
  "softmax" -> mapSoftmaxBlock,
  "log_softmax" | "logsoftmax" -> mapLogSoftmaxBlock,
  (* An unknown string is a typo, not a function: flag it so the caller rejects it. *)
  _ :> Missing["UnknownMapOp", s]}];
mapFunction[f_] := f;

mapCore[fSpec_, desc_, tensors_, bindings_List, traceAction_, strictQ_] :=
  Module[{f = mapFunction[fSpec], planned},
    planned = If[MissingQ[f],
      Einstoff`Internal`IR`FailureRecord["UnknownMapOp", "Plan",
        <|"Value" -> HoldComplete[fSpec]|>],
      tryMapIRPlan[Hold[desc], tensors, bindings, f, strictQ, traceAction]];
    Which[
      plannerFailureQ[planned],
        If[MatchQ[planned,
            Einstoff`Internal`IR`FailureRecord[
              "TargetBlockShape", "Plan", _Association]],
          Message[Einstoff::unsat,
            "the map function returned block dimensions that do not match the RHS"];
          $Failed,
          reportPlannerFailure[planned]],
      True,
        planned
    ]
  ];

(* Curried operators, like EinstoffReduce[reducer][…]. *)
EinstoffMap[fSpec_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffMap]] :=
  mapCore[fSpec, desc, tensors, bindings,
    OptionValue[EinstoffMap, {opts}, TraceAction], False];

EinstoffOperate[fSpec_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffOperate]] :=
  mapCore[fSpec, desc, tensors, bindings,
    OptionValue[EinstoffOperate, {opts}, TraceAction], True];
