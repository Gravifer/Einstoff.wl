#!/usr/bin/env wolframscript
(* Public-path comparison benchmark. Pass an optional repository root after the script
   name to benchmark another revision extracted elsewhere. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
args = Select[Rest[$ScriptCommandLine], DirectoryQ];
root = If[args === {}, ParentDirectory[scriptDir], First[args]];
PacletDirectoryLoad[root];
Needs["Einstoff`"];

SetAttributes[timeCase, HoldRest];
timeCase[name_String, repeats_Integer, expr_] :=
  Module[{value, elapsed},
    elapsed = First @ AbsoluteTiming[Do[value = expr, {repeats}]];
    If[value === $Failed || ! FreeQ[value, _Failure],
      Print["FAIL ", name, ": ", InputForm[value]]; Exit[1]];
    Print[name, "=", ToString[N[Round[elapsed/repeats, 10^-6]], InputForm]]];

x = ArrayReshape[Range[120], {10, 12}];
y = ArrayReshape[Range[84], {12, 7}];
z = ArrayReshape[Range[35], {7, 5}];

timeCase["simple-reshape", 20,
  Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}]];
timeCase["composite-split-merge", 20,
  Einstoff[ArrayReshape][
    {{CircleTimes["h", w_]}} :> {{"h", w}}, {Range[120]}, {"h" -> 10}]];
timeCase["long-ellipsis-solve", 20,
  Einstoff`EinstoffShapes[{{a__}} :> {{a..}}, {{2, 3, 4, 5, 6, 7, 8}}]];
timeCase["multi-operand-dot", 10,
  Einstoff[Dot][{{a_, b_}, {b_, c_}, {c_, d_}} :> {{a, d}}, {x, y, z}]];
timeCase["direct-sum", 20,
  Einstoff[Join][{{a_, b_}, {a_, c_}} :> {{a, CirclePlus[b, c]}},
    {ArrayReshape[Range[30], {10, 3}], ArrayReshape[Range[40], {10, 4}]}]];
