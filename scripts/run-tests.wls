#!/usr/bin/env wolframscript
(* Runner for the Einstoff test suite.
   Discovers and runs every tests/*.wlt file via TestReport[], printing a
   per-test PASS/FAIL line (even when all green) plus a grand-total summary.
   Usage:  wolframscript -file scripts/run-tests.wls   *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];

(* Load the Einstoff paclet from the project tree (structured package format). *)
PacletDirectoryLoad[root];
Needs["Einstoff`"];

testFiles = Sort @ FileNames["*.wlt", FileNameJoin[{root, "tests"}]];

If[testFiles === {},
  Print["no tests/*.wlt files found under ", FileNameJoin[{root, "tests"}]];
  Exit[1]];

(* Human-readable id for a single TestResultObject, falling back to its
   index when no TestID was supplied. *)
testLabel[tro_, pos_] := Replace[tro["TestID"], {
  _Missing | None -> "#" <> ToString[pos], id_ :> ToString[id]}];

millisOf[q_] := Round[QuantityMagnitude[UnitConvert[q, "Seconds"]] * 1000];

totalPass = 0; totalFail = 0;

Scan[
  Function[file,
    Module[{report, results, npass, nfail},
      report = TestReport[file];
      (* TestResults is keyed by internal hashes, but its Values come back in
         source / run order — take them as-is (sorting by key would scramble). *)
      results = Values @ report["TestResults"];
      npass = report["TestsSucceededCount"];
      nfail = report["TestsFailedCount"];
      totalPass += npass; totalFail += nfail;
      Print[""];
      Print["== ", FileNameTake[file], "  (", npass + nfail, " tests, ",
            millisOf @ report["TimeElapsed"], " ms) =="];
      MapIndexed[
        Function[{tro, p},
          Module[{ok = tro["Outcome"] === "Success"},
            Print["  ", If[ok, "[PASS] ", "[FAIL] "], testLabel[tro, First[p]]];
            If[! ok,
              Print["           outcome:  ", tro["Outcome"]];
              Print["           got:      ", tro["ActualOutput"]];
              Print["           expected: ", tro["ExpectedOutput"]]]]],
        results]]],
  testFiles];

Print[""];
Print["==== ", totalPass, " passed, ", totalFail, " failed (",
      totalPass + totalFail, " total) ===="];

Exit[If[totalFail === 0, 0, 1]];
