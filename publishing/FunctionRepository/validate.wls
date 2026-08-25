#!/usr/bin/env wolframscript

notebookPath = FileNameJoin[{DirectoryName[$InputFileName], "Einstoff.nb"}];

ClearAll[fail];
fail[message_String] := (Print["FAIL: " <> message]; Exit[1]);

If[!FileExistsQ[notebookPath], fail["missing " <> notebookPath]];

notebook = Quiet[Check[Get[notebookPath], $Failed]];
If[Head[notebook] =!= Notebook, fail["Einstoff.nb is not a Notebook expression"]];

cellStyles = Cases[notebook, Cell[_, style_String, ___] :> style, Infinity];
requiredCellStyles = {"Title", "UsageInputs", "UsageDescription", "Notes", "Input"};
Scan[
  Function[style,
    If[!MemberQ[cellStyles, style], fail["missing required cell style " <> style]]
  ],
  requiredCellStyles
];

templateGroupNames = DeleteDuplicates @ Cases[
  notebook,
  HoldPattern["TemplateGroupName" -> name_String] :> name,
  Infinity
];
requiredTemplateGroups = {
  "Function", "Documentation", "Usage", "Notes", "Examples",
  "Source & Additional Information", "VerificationTests", "Compatibility"
};
Scan[
  Function[name,
    If[!MemberQ[templateGroupNames, name],
      fail["missing required template group " <> name]
    ]
  ],
  requiredTemplateGroups
];

expressionUUIDs = Cases[
  notebook,
  HoldPattern[ExpressionUUID -> uuid_String] :> uuid,
  Infinity
];
If[!DuplicateFreeQ[expressionUUIDs], fail["duplicate ExpressionUUID values"]];

placeholderFragments = {
  "MyFunction", "xxxx", "One-line description", "Text about the example",
  "Additional information about usage", "Author Name", "keyword 1",
  "SymbolName (documented", "Name of another related resource"
};

notebookText = ToString[notebook, InputForm];
Scan[
  Function[fragment,
    If[StringContainsQ[notebookText, fragment],
      fail["template placeholder remains: " <> fragment]
    ]
  ],
  placeholderFragments
];

reviewerPlaceholderCells = Cases[
  notebook,
  cell : Cell["Additional information for the reviewer.", "Text", ___] :> cell,
  Infinity
];
If[
  Length[reviewerPlaceholderCells] =!= 1 ||
    FreeQ[First[reviewerPlaceholderCells], "DefaultContent", Infinity],
  fail["unexpected reviewer-information placeholder structure"]
];

inputBoxes = Cases[
  notebook,
  Cell[BoxData[boxes_], "Input", ___] :> boxes,
  Infinity
];
parsedInputs = Map[
  Quiet[Check[ToExpression[#, StandardForm, HoldComplete], Nothing]] &,
  inputBoxes
];
definitionCandidates = Select[
  parsedInputs,
  !FreeQ[
    #,
    HoldPattern[PacletSymbol["Gravifer/Einstoff", "Einstoff"]],
    Infinity
  ] &
];
If[Length[definitionCandidates] =!= 1,
  fail["expected exactly one PacletSymbol definition cell"]
];
definition = First[definitionCandidates];

If[
  FreeQ[
    definition,
    HoldPattern[PacletSymbol["Gravifer/Einstoff", "Einstoff"]],
    Infinity
  ],
  fail["definition does not use the expected PacletSymbol selector"]
];

If[!FreeQ[definition, PacletInstall | Needs, Infinity],
  fail["definition contains package-install or context-loading logic"]
];

If[
  !StringContainsQ[notebookText, "15.0+"] &&
    !StringContainsQ[notebookText, "15.0 or later"],
  fail["documentation does not require Wolfram Language 15.0 or later"]
];

scrapedCompatibilityVersions = Cases[
  notebook,
  Cell[version_String, "Text", rest___] /;
      !FreeQ[{rest}, "ScrapeDefault", Infinity] &&
      StringMatchQ[version, DigitCharacter .. ~~ "." ~~ DigitCharacter .. ~~ "+"] :>
    version,
  Infinity
];
If[Length[scrapedCompatibilityVersions] =!= 1,
  fail["expected exactly one scraped compatibility version"]
];
If[First[scrapedCompatibilityVersions] =!= "15.0+",
  Print[
    "WARN: published artifact metadata reports " <>
      First[scrapedCompatibilityVersions] <>
      "; the paclet and resource documentation require 15.0+"
  ]
];

selectedCategories = DeleteDuplicates @ Cases[
  notebook,
  HoldPattern[CheckboxBox[selected_String, {False, category_String}]] /;
      selected === category :>
    selected,
  Infinity
];
If[!MemberQ[selectedCategories, "Data Manipulation & Analysis"],
  fail["published artifact is missing its primary category"]
];

submissionCategoriesNotRetained = Complement[
  {"Core Language & Structure", "Programming Utilities"},
  selectedCategories
];
If[submissionCategoriesNotRetained =!= {},
  Print[
    "WARN: published artifact does not retain submitted categories: " <>
      StringRiffle[submissionCategoriesNotRetained, ", "]
  ]
];

If[$VersionNumber < 15.,
  fail["validation requires Wolfram Language 15.0 or later"]
];

ClearAll[Einstoff, x, a, b, c];
Quiet[Check[ReleaseHold[definition], fail["definition cell did not evaluate"]]];

reshapeActual = Quiet[Check[
  x = ArrayReshape[Range[24], {2, 3, 4}];
  Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}],
  $Failed
]];
reshapeExpected = {
  {{1, 5, 9}, {13, 17, 21}},
  {{2, 6, 10}, {14, 18, 22}},
  {{3, 7, 11}, {15, 19, 23}},
  {{4, 8, 12}, {16, 20, 24}}
};
If[reshapeActual =!= reshapeExpected,
  fail["public PacletSymbol reshape example returned an unexpected result"]
];

reduceActual = Quiet[Check[
  Einstoff[ArrayReduce][Total][
    {{a_, Slot["b"]}} :> {{a}},
    {ArrayReshape[Range[6], {2, 3}]}
  ],
  $Failed
]];
If[reduceActual =!= {6, 15},
  fail["public PacletSymbol reduction example returned an unexpected result"]
];

testActual = Quiet[Check[
  Einstoff[ArrayReshape][
    {{a_, b_}} :> {{b, a}},
    {ArrayReshape[Range[6], {2, 3}]}
  ],
  $Failed
]];
If[testActual =!= {{1, 4}, {2, 5}, {3, 6}},
  fail["public PacletSymbol verification example returned an unexpected result"]
];

Print["PASS: notebook structure and public PacletSymbol delegation"];
Exit[0];
