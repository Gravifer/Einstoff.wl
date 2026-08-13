#!/usr/bin/env wolframscript
(* Runner for the Einstoff test suite.
   Discovers and runs every tests/*.wlt file via TestReport[].

   Level (default = a PASS/FAIL line per test, grouped by file):
     quiet / -q / --quiet      one summary line per file (+ any failures)
     verbose / -v / --verbose  also show per-test time and the test input

   Opt-in groups:
     python / --python         also run tests/python/*.wlt (einx/einops
                               cross-validation via ExternalEvaluate; excluded
                               by default so the WL-only loop stays fast)

   Invoke either way:
     wolframscript -script scripts/run-tests.wls -q          (dash flags, clean)
     wolframscript -file   scripts/run-tests.wls quiet        (plain words)
     wolframscript -script scripts/run-tests.wls python -v    (with x-validation)

   NB: only `-script` sets up $ScriptCommandLine with the trailing args
   verbatim, so dash flags survive there. `wolframscript -file` instead strips
   every dash-prefixed token (and -v/-verbose trips wolframscript's own verbose
   mode), so under -file the level must be a plain word. The runner accepts
   both: dash flags via CommandLineParse, plain words via direct matching.

   Exit code is 0 iff every test passed. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];

(* When EINSTOFF_TEST_PACLET_ARCHIVE names a built .paclet file, extract that
   artifact into a fresh temporary directory and run the same suite against it.
   $Root remains the repository root so optional Python fixtures still resolve. *)
archive = Environment["EINSTOFF_TEST_PACLET_ARCHIVE"];
archiveTemp = None;
pacletLoadRoot = root;
If[StringQ[archive] && archive =!= "",
  If[! FileExistsQ[archive],
    Print["Built paclet archive does not exist: ", archive];
    Exit[1]
  ];
  archiveTemp = CreateDirectory[];
  If[FailureQ @ Quiet @ Check[ExtractArchive[archive, archiveTemp], $Failed],
    Print["Could not extract built paclet archive: ", archive];
    Exit[1]
  ];
  pacletLoadRoot = archiveTemp;
];

(* MUnit gives BeginTestSection/EndTestSection their section semantics
   (skip/require). The .wlt files use those markers but deliberately do not
   import MUnit` themselves (public-paclet convention), so the runner loads it. *)
Needs["MUnit`"];

(* Load the Einstoff paclet from the project tree (structured package format). *)
PacletDirectoryLoad[pacletLoadRoot];
Needs["Gravifer`Einstoff`"];

(* Export the project root so headless .wlt files (e.g. the python
   cross-validation suite) can locate sibling resources like .venv without a
   notebook context. Harmless for the WL-only suites. *)
Gravifer`Einstoff`Tests`$Root = root;

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

wantPython = asked[{"--python"}, {"python"}];

(* Temporary progress panels (TestReport's "Collecting tests…", the
   ExternalEvaluate spinner from the python suite) clutter stdout — silence them
   except in verbose mode, where the user has asked to see everything. *)
$ProgressReporting = verbosity >= 2;

(* Under `-script` $CommandLine carries the literal -script token; under -file
   it is the raw wolfram.exe launch (...-mathlink) with no -script. Warn when
   -file strips dash flags. NB wolframscript routes $Messages to stdout, so for
   a true stderr warning we write to the fd-2 OutputStream directly. *)
stderrStream = FirstCase[Streams[], OutputStream[_, 2], $Output];
If[! MemberQ[$CommandLine, "-script"],
  WriteString[stderrStream,
    "warning: invoked via `wolframscript -file` - dash flags such as -q/-v are ",
    "stripped before the script and have no effect. Use a plain-word level ",
    "(quiet|verbose), or invoke with `-script` to pass dash flags.\n"]];

(* ---- test discovery ----------------------------------------------------
   The default glob over tests/ is non-recursive, so tests/python/*.wlt is
   excluded unless --python (or the plain word `python`) is given. *)

testsDir = FileNameJoin[{root, "tests"}];
testFiles = Sort @ FileNames["*.wlt", testsDir];
pythonTestsDir = FileNameJoin[{testsDir, "python"}];
pythonTestFiles = Sort @ FileNames["*.wlt", pythonTestsDir];
expectedPythonTests = Total[
  StringCount[Import[#, "Text"], "VerificationTest["] & /@ pythonTestFiles
];
If[wantPython,
  testFiles = Join[testFiles, pythonTestFiles]];

If[testFiles === {},
  Print["no tests/*.wlt files found under ", testsDir];
  Exit[1]];

(* Human-readable id for a single TestResultObject, falling back to its
   index when no TestID was supplied. *)
testLabel[tro_, pos_] := Replace[tro["TestID"], {
  _Missing | None -> "#" <> ToString[pos], id_ :> ToString[id]}];

millisOf[q_] := Round[QuantityMagnitude[UnitConvert[q, "Seconds"]] * 1000];

(* Label a test file by its path relative to tests/, so that e.g. Reshape.wlt and
   python/Reshape.wlt are distinguishable. *)
fileLabel[file_] := FileNameJoin[Drop[FileNameSplit[file], Length[FileNameSplit[testsDir]]]];

(* ---- shared Python session --------------------------------------------
   Spawn ONE ExternalEvaluate session here and expose it as Gravifer`Einstoff`Tests`$PySession
   so every tests/python/*.wlt reuses it: many short-lived ZMQ sessions per kernel
   are unstable (intermittent 0xC0000005), one shared session is not. Each .wlt
   falls back to its own session when this is unset (e.g. a bare TestReport). *)

Gravifer`Einstoff`Tests`$PySession = None;
If[wantPython,
  With[{exe = FileNameJoin[{root, ".venv", "Scripts", "python.exe"}]},
    If[FileExistsQ[exe],
      Gravifer`Einstoff`Tests`$PySession = Quiet @ Check[
        StartExternalSession[<|"System" -> "Python", "Executable" -> exe|>], None]]]];

(* ---- run --------------------------------------------------------------- *)

totalPass = 0; totalFail = 0; executedPythonTests = 0;

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
      If[MemberQ[pythonTestFiles, file], executedPythonTests += npass + nfail];

      If[verbosity === 0,
        Print[fileLabel[file], ": ", npass, " passed, ", nfail, " failed"],
        Print[""];
        Print["== ", fileLabel[file], "  (", npass + nfail, " tests, ",
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

(* Tear down the shared session we spawned (the .wlt files leave it alone). *)
If[Head[Gravifer`Einstoff`Tests`$PySession] === ExternalSessionObject,
  Quiet @ DeleteObject[Gravifer`Einstoff`Tests`$PySession]];

If[StringQ[archiveTemp],
  Quiet @ DeleteDirectory[archiveTemp, DeleteContents -> True]];

Print[""];
Print["==== ", totalPass, " passed, ", totalFail, " failed (",
      totalPass + totalFail, " total) ===="];

If[wantPython,
  Print[
    "Python cross-validation: ", executedPythonTests, " of ",
    expectedPythonTests, " tests executed"
  ]
];

Exit[If[
  totalFail === 0 && (! wantPython || executedPythonTests === expectedPythonTests),
  0,
  1
]];
