#!/usr/bin/env wolframscript
(* Runner for the Einstoff parsing-layer test suite.
   Usage:  wolframscript -file run-tests.wl   *)

dir = DirectoryName[$InputFileName];
If[dir === "", dir = Directory[]];

Get[FileNameJoin[{dir, "Einstoff", "Parsing.wl"}]];

report = TestReport[FileNameJoin[{dir, "tests", "Parsing.wt"}]];

Print["Tests succeeded: ", report["TestsSucceededCount"]];
Print["Tests failed:    ", report["TestsFailedCount"]];

failed = Join[
  Values @ report["TestsFailedWrongResults"],
  Values @ report["TestsFailedWithMessages"],
  Values @ report["TestsFailedWithErrors"]
];

If[failed =!= {},
  Print["----- Failures -----"];
  Scan[
    Print["  ", #["TestID"], ":  got ", #["ActualOutput"],
          "  expected ", #["ExpectedOutput"]] &,
    failed]];

Exit[If[report["AllTestsSucceeded"], 0, 1]];
