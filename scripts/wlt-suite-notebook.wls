#!/usr/bin/env wolframscript
(* Prototype aggregate notebook generator for the Einstoff .wlt suite.

   Usage:
     wolframscript -script scripts/wlt-suite-notebook.wls
     wolframscript -script scripts/wlt-suite-notebook.wls path/to/out.nb

   The generated notebook is intentionally not checked in by this script. It
   borrows the MUnit cell-group shape from ResourceFunction["WLTToNotebook"],
   but keeps non-test top-level expressions as initialization/input cells and
   adds suite hierarchy around all tests/**/*.wlt files. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
testsDir = FileNameJoin[{root, "tests"}];

outFile = Replace[Rest[$ScriptCommandLine], {
    {path_, ___} :> path,
    _ :> FileNameJoin[{root, "tests", "EinstoffTestSuite.nb"}]
  }];
If[! AbsoluteFileNameQ[outFile],
  outFile = FileNameJoin[{Directory[], outFile}]];

Needs["MUnit`"];

ClearAll[
  nbCellID, heldBoxes, heldInputCell, testToCells, testCellGroup, envCells,
  commentCell, sourceItems, codeStringToCells, fileToCells, chapterLabel,
  relativeParts, sectionName, testFilesByChapter
];

cellIDs = CreateDataStructure["HashSet"];
nbCellID[] := Module[{id = 0},
  TimeConstrained[
    While[True,
      id = RandomInteger[10^9];
      If[TrueQ @ cellIDs["Insert", id], Break[]]],
    2];
  id
];

SetAttributes[heldBoxes, HoldAllComplete];
heldBoxes[HoldComplete[expr_]] := BoxData @ MakeBoxes[expr, StandardForm];

heldInputCell[held_HoldComplete, init_: True] :=
  Cell[heldBoxes[held], "Input",
    InitializationCell -> init,
    CellID -> nbCellID[]];

SetAttributes[testToCells, HoldAllComplete];

testToCells[
  HoldComplete[expressions__],
  init_: False
] /; Length[HoldComplete[expressions]] > 1 :=
  Join @@ (testToCells[#, init] & /@ Thread @ HoldComplete[{expressions}]);

testToCells[
  HoldComplete[CompoundExpression[expressions__]],
  init_: False
] := Join @@ (testToCells[#, init] & /@ Thread @ HoldComplete[{expressions}]);

testToCells[
  HoldComplete[Null],
  init_: False
] := {};

testToCells[
  HoldComplete[VerificationTest[in_]],
  init_: False
] := {testCellGroup[HoldComplete[in], HoldComplete[True], HoldComplete[{}], HoldComplete[{}]]};

testToCells[
  HoldComplete[VerificationTest[in_, out_, opts : OptionsPattern[]]],
  init_: False
] := {testCellGroup[HoldComplete[in], HoldComplete[out], HoldComplete[{}], HoldComplete[{opts}]]};

testToCells[
  HoldComplete[VerificationTest[in_, out_, msgs_, opts : OptionsPattern[]]],
  init_: False
] := {testCellGroup[HoldComplete[in], HoldComplete[out], HoldComplete[msgs], HoldComplete[{opts}]]};

testToCells[
  HoldComplete[MUnit`BeginTestSection[section_String]],
  init_: False
] := {Cell[section, "Subsection", CellID -> nbCellID[]]};

testToCells[
  HoldComplete[MUnit`BeginTestSection[section_String, condition_]],
  init_: False
] := {
  Cell[section, "Subsection", CellID -> nbCellID[]],
  heldInputCell[HoldComplete[MUnit`BeginTestSection[section, condition]], True]
};

testToCells[
  HoldComplete[MUnit`EndTestSection[]],
  init_: False
] := {};

testToCells[held_HoldComplete, init_: False] := {heldInputCell[held, init]};

testCellGroup[in_, out_, msgs_, opts_] :=
  Cell @ CellGroupData[
    {
      Cell[heldBoxes[in], "VerificationTest", CellID -> nbCellID[]],
      Cell[heldBoxes[out], "ExpectedOutput", CellID -> nbCellID[]],
      Cell[heldBoxes[msgs], "ExpectedMessage", CellID -> nbCellID[]],
      Cell[heldBoxes[opts], "TestOptions", CellID -> nbCellID[]],
      Cell[BoxData @ ToBoxes @ MUnit`bottomCell[], "BottomCell", CellID -> nbCellID[]]
    },
    Open
  ];

commentCell[text_String] := Module[{trimmed, lines},
  trimmed = StringTrim[text];
  If[StringMatchQ[trimmed, "::" ~~ ___ ~~ "::"], Nothing,
    lines = StringTrim /@ StringSplit[trimmed, {"\r\n", "\n", "\r"}, All];
    Cell[StringRiffle[lines, "\n"], "Text", CellID -> nbCellID[]]
  ]
];

sourceItems[text_String] := Module[
  {n = StringLength[text], i = 1, code = "", items = {}, ch, pair, comment,
    rawComment, depth, inString = False, escaped = False},
  While[i <= n,
    ch = StringTake[text, {i}];
    pair = If[i < n, StringTake[text, {i, i + 1}], ""];
    Which[
      inString,
        code = code <> ch;
        Which[
          escaped, escaped = False,
          ch === "\\", escaped = True,
          ch === "\"", inString = False
        ];
        i++,
      ch === "\"",
        inString = True;
        code = code <> ch;
        i++,
      pair === "(*",
        If[StringTrim[code] =!= "" &&
            Quiet @ Check[ToExpression[code, InputForm, HoldComplete]; True, False],
          AppendTo[items, <|"Type" -> "Code", "Text" -> code|>];
          code = ""];
        i += 2;
        depth = 1;
        comment = "";
        rawComment = "(*";
        While[i <= n && depth > 0,
          pair = If[i < n, StringTake[text, {i, i + 1}], ""];
          Which[
            pair === "(*",
              depth++;
              comment = comment <> pair;
              rawComment = rawComment <> pair;
              i += 2,
            pair === "*)",
              depth--;
              rawComment = rawComment <> pair;
              If[depth > 0, comment = comment <> pair];
              i += 2,
            True,
              comment = comment <> StringTake[text, {i}];
              rawComment = rawComment <> StringTake[text, {i}];
              i++
          ]
        ];
        If[StringTrim[code] === "",
          AppendTo[items, <|"Type" -> "Comment", "Text" -> comment|>],
          code = code <> rawComment
        ],
      True,
        code = code <> ch;
        i++
    ]
  ];
  If[StringTrim[code] =!= "",
    AppendTo[items, <|"Type" -> "Code", "Text" -> code|>]];
  items
];

codeStringToCells[code_String] := Module[{held},
  held = Quiet @ Check[
    ToExpression[code, InputForm, HoldComplete],
    $Failed
  ];
  If[held === $Failed,
    {
      Cell["Could not parse source chunk:", "Text", CellID -> nbCellID[]],
      Cell[code, "Program", CellID -> nbCellID[]]
    },
    Apply[testToCells, {held, True}]
  ]
];

fileToCells[file_] := Module[{text, items},
  text = Quiet @ Check[Import[file, "Text"], $Failed];
  If[text === $Failed,
    {
      Cell[sectionName[file], "Section", CellID -> nbCellID[]],
      Cell["Import failed: " <> file, "Text", CellID -> nbCellID[]]
    },
    items = sourceItems[text];
    Join[
      {Cell[sectionName[file], "Section", CellID -> nbCellID[]]},
      Join @@ Replace[items, {
        item_ /; item["Type"] === "Comment" :>
          Replace[commentCell[item["Text"]], {Nothing -> {}, cell_Cell :> {cell}}],
        item_ /; item["Type"] === "Code" :> codeStringToCells[item["Text"]]
      }, {1}]
    ]
  ]
];

envCells[] := {
  Cell["Environment", "Chapter", CellID -> nbCellID[]],
  heldInputCell[HoldComplete[
      root = ParentDirectory @ DirectoryName @ NotebookFileName[];
      testsDir = FileNameJoin[{root, "tests"}];
    ], True],
  heldInputCell[HoldComplete[
      Needs["MUnit`"];
      PacletDirectoryLoad[root];
      Needs["Einstoff`"];
      Einstoff`Tests`$Root = root;
    ], True],
  heldInputCell[HoldComplete[
      Einstoff`Tests`$PySession = None;
      With[{exe = FileNameJoin[{root, ".venv", "Scripts", "python.exe"}]},
        If[FileExistsQ[exe],
          Einstoff`Tests`$PySession = Quiet @ Check[
            StartExternalSession[<|"System" -> "Python", "Executable" -> exe|>],
            None
          ]
        ]
      ];
    ], True]
};

relativeParts[file_] :=
  Drop[FileNameSplit[file], Length @ FileNameSplit[testsDir]];

chapterLabel[file_] := Replace[Most @ relativeParts[file], {
    {} -> "tests",
    parts_ :> FileNameJoin[parts]
  }];

sectionName[file_] := FileBaseName[file] <> "." <> FileExtension[file];

rootTestFiles = Sort @ FileNames["*.wlt", testsDir];
nestedTestFiles = Sort @ Complement[FileNames["*.wlt", testsDir, Infinity], rootTestFiles];
testFiles = Join[rootTestFiles, nestedTestFiles];
If[testFiles === {},
  Print["no tests/*.wlt files found under ", testsDir];
  Exit[1]
];

testFilesByChapter = GroupBy[testFiles, chapterLabel];

bodyCells =
  Join @@ KeyValueMap[
    Function[{chapter, files},
      Join[
        {Cell[chapter, "Chapter", CellID -> nbCellID[]]},
        Join @@ (fileToCells /@ files)
      ]
    ],
    testFilesByChapter
  ];

teardownCells = {
  Cell["Teardown", "Chapter", CellID -> nbCellID[]],
  heldInputCell[HoldComplete[
      If[Head[Einstoff`Tests`$PySession] === ExternalSessionObject,
        Quiet @ DeleteObject[Einstoff`Tests`$PySession]
      ];
    ], False]
};

nb = Notebook[
  Join[
    {
      Cell["Einstoff Test Suite", "Title", CellID -> nbCellID[]],
      Cell["Generated from tests/**/*.wlt by scripts/wlt-suite-notebook.wls.", "Text",
        CellID -> nbCellID[]]
    },
    envCells[],
    bodyCells,
    teardownCells
  ],
  ShowGroupOpener -> True,
  TaggingRules -> Association["$testsRun" -> False],
  StyleDefinitions -> FrontEnd`FileName[{"MUnit"}, "MUnit.nb",
    CharacterEncoding -> "UTF-8"]
];

Export[outFile, nb, "NB"];
Print["wrote ", outFile];
