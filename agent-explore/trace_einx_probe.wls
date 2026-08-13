#!/usr/bin/env wolframscript

root = ParentDirectory[DirectoryName[$InputFileName]];
PacletDirectoryLoad[root];
Needs["Gravifer`Einstoff`"];

jsonable[x_] := Replace[x, {
    $Failed -> <|"__failed" -> True|>,
    Missing[k___] :> <|"__missing" -> ToString[Missing[k], InputForm]|>
  }, {0, Infinity}];

toJson[x_] := ExportString[jsonable[x], "RawJSON", "Compact" -> True];

heldString[expr_] := ToString[Unevaluated[expr], InputForm];
releaseValue[expr_] := Quiet @ Check[ReleaseHold[expr], $Failed];

SetAttributes[case, HoldRest];
case[name_, op_, trace_] :=
  Module[{normal, graph, released},
    normal = Quiet @ Check[op, $Failed];
    graph = Quiet @ Check[trace, $Failed];
    released = If[graph === $Failed, $Failed, Quiet @ Check[ReleaseHold[graph], $Failed]];
    <|
      "normal" -> normal,
      "graphHead" -> ToString[Head[graph], InputForm],
      "graph" -> heldString[graph],
      "released" -> released,
      "normalEqualsReleased" -> TrueQ[normal === released],
      "hasPrivateMaterialize" -> StringContainsQ[heldString[graph], "materializeOutput"]
    |>
  ];

cases = <|
  "id_permute_2d" -> case[
    "id_permute_2d",
    With[{x = ArrayReshape[Range[6], {2, 3}]},
      Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}]],
    With[{x = ArrayReshape[Range[6], {2, 3}]},
      Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}, {}, TraceAction -> Hold]]],

  "id_split_permute_merge" -> case[
    "id_split_permute_merge",
    With[{x = ArrayReshape[Range[32], {4, 8}]},
      Einstoff[ArrayReshape][{{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {x}, {"b" -> 2}]],
    With[{x = ArrayReshape[Range[32], {4, 8}]},
      Einstoff[ArrayReshape][{{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {x}, {"b" -> 2}, TraceAction -> Hold]]],

  "id_repeat_2d" -> case[
    "id_repeat_2d",
    With[{x = ArrayReshape[Range[6], {2, 3}]},
      Einstoff["Massage"][{{a_, b_}} :> {{a, b, c}}, {x}, {c -> 2}]],
    With[{x = ArrayReshape[Range[6], {2, 3}]},
      Einstoff["Massage"][{{a_, b_}} :> {{a, b, c}}, {x}, {c -> 2}, TraceAction -> Hold]]],

  "id_repeat_merge" -> case[
    "id_repeat_merge",
    With[{x = Range[4]},
      Einstoff["Massage"][{{a_}} :> {{CircleTimes[a, c]}}, {x}, {c -> 3}]],
    With[{x = Range[4]},
      Einstoff["Massage"][{{a_}} :> {{CircleTimes[a, c]}}, {x}, {c -> 3}, TraceAction -> Hold]]],

  "id_unit_squeeze" -> case[
    "id_unit_squeeze",
    With[{x = ArrayReshape[Range[6], {2, 1, 3}]},
      Einstoff[ArrayReshape][{{a_, 1, c_}} :> {{a, c}}, {x}]],
    With[{x = ArrayReshape[Range[6], {2, 1, 3}]},
      Einstoff[ArrayReshape][{{a_, 1, c_}} :> {{a, c}}, {x}, {}, TraceAction -> Hold]]],

  "sum_basic" -> case[
    "sum_basic",
    With[{x = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}]],
    With[{x = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}, {}, TraceAction -> Hold]]],

  "sum_permute" -> case[
    "sum_permute",
    With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"], c_}} :> {{c, a}}, {x}]],
    With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"], c_}} :> {{c, a}}, {x}, {}, TraceAction -> Hold]]],

  "sum_merge" -> case[
    "sum_merge",
    With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"], c_}} :> {{CircleTimes[a, c]}}, {x}]],
    With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"], c_}} :> {{CircleTimes[a, c]}}, {x}, {}, TraceAction -> Hold]]],

  "sum_repeat" -> case[
    "sum_repeat",
    With[{x = ArrayReshape[Range[12], {4, 3}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, c}}, {x}, {c -> 3}]],
    With[{x = ArrayReshape[Range[12], {4, 3}]},
      Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, c}}, {x}, {c -> 3}, TraceAction -> Hold]]
    ],

  "max_basic" -> case[
    "max_basic",
    With[{x = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[ArrayReduce][Max][{{a_, Slot["b"]}} :> {{a}}, {x}]],
    With[{x = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[ArrayReduce][Max][{{a_, Slot["b"]}} :> {{a}}, {x}, {}, TraceAction -> Hold]]
    ],

  "map_flip" -> case[
    "map_flip",
    With[{x = ArrayReshape[Range[8], {2, 4}]},
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
    With[{x = ArrayReshape[Range[8], {2, 4}]},
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}, {}, TraceAction -> Hold]]
    ],

  "map_sort" -> case[
    "map_sort",
    With[{x = ArrayReshape[Reverse[Range[8]], {2, 4}]},
      Einstoff[Map]["sort"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
    With[{x = ArrayReshape[Reverse[Range[8]], {2, 4}]},
      Einstoff[Map]["sort"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}, {}, TraceAction -> Hold]]
    ],

  "dot_matmul" -> case[
    "dot_matmul",
    With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[Dot][{{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {x, y}]],
    With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[Dot][{{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {x, y}, {}, TraceAction -> Hold]]
    ],

  "dot_batch_matmul" -> case[
    "dot_batch_matmul",
    With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
      Einstoff[Dot][{{b_, a_, Slot["k"]}, {b_, Slot["k"], c_}} :> {{b, a, c}}, {x, y}]],
    With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
      Einstoff[Dot][{{b_, a_, Slot["k"]}, {b_, Slot["k"], c_}} :> {{b, a, c}}, {x, y}, {}, TraceAction -> Hold]]
    ],

  "directsum_join" -> case[
    "directsum_join",
    With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
      Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
    With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
      Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}, {}, TraceAction -> Hold]]
    ],

  "directsum_split" -> case[
    "directsum_split",
    With[{x = ArrayReshape[Range[14], {2, 7}]},
      Einstoff[Split][{{m_, CirclePlus["a", "b"]}} :> {{m, "a"}, {m, "b"}}, {x}, {"a" -> 3, "b" -> 4}]],
    With[{x = ArrayReshape[Range[14], {2, 7}]},
      Einstoff[Split][{{m_, CirclePlus["a", "b"]}} :> {{m, "a"}, {m, "b"}}, {x}, {"a" -> 3, "b" -> 4}, TraceAction -> Hold]]
    ]
|>;

Print[toJson[cases]];
