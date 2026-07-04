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
  chapterLabel, relativeParts, sectionName, testFilesByChapter
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
  HoldComplete[CompoundExpression[expressions__]],
  init_: False
] := Join @@ (testToCells[#, init] & /@ Thread @ HoldComplete[{expressions}]);

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
        Join @@ (Function[file,
            Module[{held},
              held = Quiet @ Check[
                Import[file, {"WL", "HeldExpressions"}],
                $Failed
              ];
              If[held === $Failed,
                {
                  Cell[sectionName[file], "Section", CellID -> nbCellID[]],
                  Cell["Import failed: " <> file, "Text", CellID -> nbCellID[]]
                },
                Join[
                  {Cell[sectionName[file], "Section", CellID -> nbCellID[]]},
                  Join @@ (testToCells[#, True] & /@ held)
                ]
              ]
            ]
          ] /@ files)
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
