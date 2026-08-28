#!/usr/bin/env wolframscript

(* A Wolfram 13-safe runner for one prebuilt historical-compatibility probe. *)

arguments = Rest[$ScriptCommandLine];
If[Length[arguments] =!= 4,
  Print["usage: historical-engine-runner.wls ARCHIVE TESTS REPORT EXPECTED_VERSION"];
  Exit[64]
];
{archive, testsDirectory, reportPath, expectedVersion} = arguments;

expectedVersionNumber = Switch[
  expectedVersion,
  "15.0", 15.,
  "14.1", 14.1,
  "13.2", 13.2,
  "13.0", 13.,
  _, $Failed
];

baseReport = <|
  "ExpectedVersion" -> expectedVersion,
  "ActualVersion" -> $Version,
  "ActualVersionNumber" -> $VersionNumber
|>;

writeReport[status_, details_] := Module[{directory, result},
  directory = DirectoryName[reportPath];
  If[! DirectoryQ[directory], CreateDirectory[directory, CreateIntermediateDirectories -> True]];
  result = Quiet @ Check[
    Export[reportPath, Join[baseReport, <|"Status" -> status|>, details], "JSON"],
    $Failed
  ];
  If[result === $Failed, Print["Could not write historical-engine JSON report: ", reportPath]];
  result =!= $Failed
];

failHarness[message_] := (
  Print["HISTORICAL_HARNESS_FAILED: ", message];
  writeReport["HarnessFailure", <|"Message" -> message|>];
  Exit[70]
);

If[expectedVersionNumber === $Failed, failHarness["unsupported expected engine version"]];
If[$VersionNumber =!= expectedVersionNumber,
  failHarness[
    "expected " <> expectedVersion <> ", received " <> ToString[$VersionNumber]
  ]
];
If[! FileExistsQ[archive], failHarness["probe archive does not exist"]];
If[! DirectoryQ[testsDirectory], failHarness["test directory does not exist"]];

archiveHash = Quiet @ Check[
  ToUpperCase @ IntegerString[FileHash[archive, "SHA256"], 16, 64],
  $Failed
];
If[archiveHash === $Failed, failHarness["could not hash probe archive"]];

installed = Quiet @ Check[PacletInstall[archive], $Failed];
If[installed === $Failed || ! MatchQ[installed, _PacletObject],
  failHarness["could not install probe archive"]
];

loadResult = Quiet @ Check[Needs["Gravifer`Einstoff`"] ; True, False];
If[! TrueQ[loadResult], failHarness["could not load Gravifer`Einstoff`"]];

publicSymbols = Sort @ Names["Gravifer`Einstoff`*"];
expectedPublicSymbols = {"Einstoff"};
If[publicSymbols =!= expectedPublicSymbols,
  failHarness["unexpected public symbols: " <> ToString[publicSymbols, InputForm]]
];

reshapeInput = ArrayReshape[Range[6], {2, 3}];
dotLeft = ArrayReshape[Range[6], {2, 3}];
dotRight = ArrayReshape[Range[6], {3, 2}];
joinLeft = ArrayReshape[Range[6], {2, 3}];
joinRight = ArrayReshape[Range[4], {2, 2}];

smokeChecks = {
  {"reshape",
    Quiet @ Check[
      Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {reshapeInput}],
      $Failed
    ],
    Transpose[reshapeInput]},
  {"reduce",
    Quiet @ Check[
      Einstoff[ArrayReduce][Total][{{a_, b_}} :> {{a}}, {reshapeInput}],
      $Failed
    ],
    Total[reshapeInput, {2}]},
  {"map",
    Quiet @ Check[
      Einstoff[Map][Reverse][
        {{a_, Highlighted[b_]}} :> {{a, b}}, {reshapeInput}
      ],
      $Failed
    ],
    Reverse /@ reshapeInput},
  {"operate",
    Quiet @ Check[
      Einstoff[Operate][Reverse][
        {{a_, Highlighted[b_]}} :> {{a, b}}, {reshapeInput}
      ],
      $Failed
    ],
    Reverse /@ reshapeInput},
  {"dot",
    Quiet @ Check[
      Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {dotLeft, dotRight}],
      $Failed
    ],
    Dot[dotLeft, dotRight]},
  {"inner",
    Quiet @ Check[
      Einstoff[Inner][Times, Plus][
        {{a_, b_}, {b_, c_}} :> {{a, c}}, {dotLeft, dotRight}
      ],
      $Failed
    ],
    Dot[dotLeft, dotRight]},
  {"join",
    Quiet @ Check[
      Einstoff[Join][
        {{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
        {joinLeft, joinRight}
      ],
      $Failed
    ],
    Join[joinLeft, joinRight, 2]},
  {"split",
    Quiet @ Check[
      Einstoff[Split][
        {{m_, CirclePlus["q", k_]}} :> {{m, "q"}, {m, k}},
        {Join[joinLeft, joinRight, 2]}, {"q" -> 3}
      ],
      $Failed
    ],
    {joinLeft, joinRight}},
  {"broadcast",
    Quiet @ Check[
      Dimensions @ Einstoff["Massage"][
        {{a_}} :> {{a, c}}, {Range[2]}, {c -> 3}
      ],
      $Failed
    ],
    {2, 3}}
};

failedSmokeChecks = Cases[
  smokeChecks,
  {name_, actual_, expected_} /; actual =!= expected :>
    <|
      "Name" -> name,
      "Actual" -> ToString[actual, InputForm],
      "Expected" -> ToString[expected, InputForm]
    |>
];
If[failedSmokeChecks =!= {},
  Print["HISTORICAL_SMOKE_FAILED: ", failedSmokeChecks // InputForm];
  reportWritten = writeReport[
    "TestFailure",
    <|
      "ArchiveSHA256" -> archiveHash,
      "PublicSymbols" -> publicSymbols,
      "FailedSmokeChecks" -> failedSmokeChecks
    |>
  ];
  If[! TrueQ[reportWritten], Exit[70]];
  Exit[1]
];

Needs["MUnit`"];
Gravifer`Einstoff`Tests`$Root = ParentDirectory[testsDirectory];
testFiles = Sort @ FileNames["*.wlt", testsDirectory];
If[testFiles === {}, failHarness["no Wolfram .wlt tests were found"]];
expectedTestCount = Total[
  StringCount[Import[#, "Text"], "VerificationTest["] & /@ testFiles
];

totalSucceeded = 0;
totalFailed = 0;
Scan[
  Function[file,
    Module[{testReport, testCounts},
      Print["Running ", FileNameTake[file], "..."];
      (* Do not wrap TestReport in Check: message-bearing VerificationTest cases
         are valid MUnit input and must not become harness failures. Validate the
         returned report through its count properties after evaluation instead. *)
      testReport = TestReport[file];
      testCounts = Quiet @ Check[
        {testReport["TestsSucceededCount"], testReport["TestsFailedCount"]},
        $Failed
      ];
      If[
        ! MatchQ[testCounts, {_Integer, _Integer}] ||
          ! And @@ Map[Function[count, count >= 0], testCounts],
        failHarness["TestReport returned invalid counts for " <> file]
      ];
      totalSucceeded += testCounts[[1]];
      totalFailed += testCounts[[2]];
      If[testCounts[[2]] > 0, Print[testReport]]
    ]
  ],
  testFiles
];

executedTestCount = totalSucceeded + totalFailed;
finalStatus = If[
  totalFailed === 0 && executedTestCount === expectedTestCount,
  "Passed",
  "TestFailure"
];
reportWritten = writeReport[
  finalStatus,
  <|
    "ArchiveSHA256" -> archiveHash,
    "PublicSymbols" -> publicSymbols,
    "SmokeChecksPassed" -> Length[smokeChecks],
    "TestFiles" -> (FileNameTake /@ testFiles),
    "ExpectedTestCount" -> expectedTestCount,
    "ExecutedTestCount" -> executedTestCount,
    "TestsSucceededCount" -> totalSucceeded,
    "TestsFailedCount" -> totalFailed
  |>
];
If[! TrueQ[reportWritten], Exit[70]];

Print[
  "Historical engine ", expectedVersion, ": ", totalSucceeded,
  " passed, ", totalFailed, " failed (", executedTestCount,
  " of ", expectedTestCount, " expected)."
];
Exit[If[finalStatus === "Passed", 0, 1]];
