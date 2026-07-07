(* ::Package:: *)

(* Tests for Einstoff[Operate] — the shape-preserving targeted-block operation
   path split out from the broader generalized Einstoff[Map]. *)

BeginTestSection["Einstoff`Lowering`Operate"];

ClearAll[a, b, c];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Operate]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "operate-flip-string"
];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Operate]["sort"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
      {Reverse /@ x}]],
  Sort /@ (Reverse /@ ArrayReshape[Range[8], {2, 4}]),
  TestID -> "operate-sort"
];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}],
        sm = Exp[# - Max[#]]/Total[Exp[# - Max[#]]] &},
    Chop[Einstoff[Operate]["softmax"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}] -
      (sm /@ x)] == ConstantArray[0, {2, 4}]],
  True,
  TestID -> "operate-softmax"
];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}],
        lsm = (# - Max[#]) - Log[Total[Exp[# - Max[#]]]] &},
    Chop[Einstoff[Operate]["log_softmax"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}] -
      (lsm /@ x)] == ConstantArray[0, {2, 4}]],
  True,
  TestID -> "operate-log-softmax"
];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Operate]["id"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
  ArrayReshape[Range[8], {2, 4}],
  TestID -> "operate-id"
];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Operate]["flip"][{{a_, Highlighted[b_]}} :> {{a, b}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "operate-highlighted-blank"
];

VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Operate]["flip"][{{a_, Highlighted["b"]}} :> {{a, Highlighted["b"]}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "operate-highlighted-string"
];

VerificationTest[
  With[{z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[Operate][Reverse][{{a_, Highlighted[3]}} :> {{a, Highlighted[3]}}, {z}]],
  Reverse /@ ArrayReshape[Range[6], {2, 3}],
  TestID -> "operate-highlighted-literal"
];

VerificationTest[
  With[{z = ArrayReshape[Range[120], {2, 3, 4, 5}]},
    Einstoff[Operate][Reverse][{{a_, Highlighted[___], c_}} :> {{a, Highlighted[___], c}}, {z}]],
  Reverse /@ ArrayReshape[Range[120], {2, 3, 4, 5}],
  TestID -> "operate-highlighted-blanknullsequence-block"
];

VerificationTest[
  Quiet[
    Einstoff[Operate][Reverse][{{a_, b_}} :> {{a, b}},
      {ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "operate-reject-no-target"
];

VerificationTest[
  Quiet[
    Einstoff[Operate][Total][{{a_, Slot["b"]}} :> {{a}},
      {ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "operate-reject-shape-changing"
];

EndTestSection[];
