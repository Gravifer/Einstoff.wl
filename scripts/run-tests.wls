#!/usr/bin/env wolframscript
(* Runner for the Einstoff test suite.
   Discovers and runs every tests/*.wlt file via TestReport[].

   Usage:  wolframscript -file scripts/run-tests.wls [quiet|verbose]
     quiet  (q)      one summary line per file (+ any failures)
     (default)       a PASS/FAIL line per test, grouped by file
     verbose (v)     also show per-test time and the test input

   NB: `wolframscript -file` strips every dash-prefixed token before the
   script sees it (and -v/-verbose additionally trips wolframscript's own
   verbose mode), so the level is selected with plain words here. The
   equivalent -q/-v/--quiet/--verbose dash flags are still honored when the
   script is run directly via its shebang (./scripts/run-tests.wls -v), where
   they do reach $ScriptCommandLine.

   Exit code is 0 iff every test passed. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];

(* MUnit gives BeginTestSection/EndTestSection their section semantics
   (skip/require). The .wlt files use those markers but deliberately do not
   import MUnit` themselves (public-paclet convention), so the runner loads it. *)
Needs["MUnit`"];

(* Load the Einstoff paclet from the project tree (structured package format). *)
PacletDirectoryLoad[root];
Needs["Einstoff`"];

(* ---- verbosity from the command line ----------------------------------
   Dash flags (-v/--verbose/-q/--quiet) are parsed with the CommandLineParse
   resource function — each parsed entry is
   <|prog -> <|"Flag" -> "-x", "Parameter" -> ...|>|> — and survive only under
   direct shebang invocation. Plain words (verbose/v, quiet/q) cover the
   `wolframscript -file` path, where dash tokens are stripped. *)
clFlags =
  Module[{parsed = Quiet @ ResourceFunction["CommandLineParse"][$ScriptCommandLine]},
    If[FailureQ[parsed] || ! MatchQ[parsed, _Dataset | _List | _Association],
      Select[Rest[$ScriptCommandLine], StringStartsQ["-"]],
      Cases[Normal[parsed], KeyValuePattern["Flag" -> f_] :> f, {0, Infinity}]]];

clWords = ToLowerCase @ Select[Rest[$ScriptCommandLine], ! StringStartsQ[#, "-"] &];

asked[flags_, words_] := IntersectingQ[clFlags, flags] || IntersectingQ[clWords, words];

verbosity = Which[
  asked[{"-v", "--verbose"}, {"verbose", "v"}], 2,
  asked[{"-q", "--quiet"}, {"quiet", "q"}], 0,
  True, 1];

(* ---- test discovery ---------------------------------------------------- *)

testFiles = Sort @ FileNames["*.wlt", FileNameJoin[{root, "tests"}]];

If[testFiles === {},
  Print["no tests/*.wlt files found under ", FileNameJoin[{root, "tests"}]];
  Exit[1]];

(* Human-readable id for a single TestResultObject, falling back to its
   index when no TestID was supplied. *)
testLabel[tro_, pos_] := Replace[tro["TestID"], {
  _Missing | None -> "#" <> ToString[pos], id_ :> ToString[id]}];

millisOf[q_] := Round[QuantityMagnitude[UnitConvert[q, "Seconds"]] * 1000];

(* ---- run --------------------------------------------------------------- *)

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

      If[verbosity === 0,
        Print[FileNameTake[file], ": ", npass, " passed, ", nfail, " failed"],
        Print[""];
        Print["== ", FileNameTake[file], "  (", npass + nfail, " tests, ",
              millisOf @ report["TimeElapsed"], " ms) =="]];

      MapIndexed[
        Function[{tro, p},
          If[tro["Outcome"] === "Success",
            (* passing test: listed only at verbosity >= 1 *)
            If[verbosity >= 1,
              Print["  [PASS] ", testLabel[tro, First[p]],
                If[verbosity >= 2,
                  "  (" <> ToString[millisOf @ tro["AbsoluteTimeUsed"]] <> " ms)",
                  ""]];
              If[verbosity >= 2,
                (* default OutputForm renders the stored HoldForm[...] wrapper
                   transparently; InputForm would print "HoldForm[...]" literally *)
                Module[{in = ToString[tro["Input"]]},
                  Print["           in: ",
                    If[StringLength[in] > 140, StringTake[in, 137] <> "...", in]]]]],
            (* failing test: always reported in full, regardless of verbosity *)
            Print["  [FAIL] ", testLabel[tro, First[p]]];
            Print["           outcome:  ", tro["Outcome"]];
            Print["           got:      ", tro["ActualOutput"]];
            Print["           expected: ", tro["ExpectedOutput"]]]],
        results]]],
  testFiles];

Print[""];
Print["==== ", totalPass, " passed, ", totalFail, " failed (",
      totalPass + totalFail, " total) ===="];

Exit[If[totalFail === 0, 0, 1]];
