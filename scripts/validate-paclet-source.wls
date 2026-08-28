#!/usr/bin/env wolframscript

(* Lightweight release-preparation checks. This validates the source paclet and
   its public surface without building documentation or launching a front end. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
configuredRoot = Quiet @ Check[Environment["EINSTOFF_SOURCE_ROOT"], ""];
root = If[StringQ[configuredRoot] && configuredRoot =!= "",
  ExpandFileName[configuredRoot],
  ParentDirectory[scriptDir]
];
pacletDir = FileNameJoin[{root, "Gravifer__Einstoff"}];
definitionFile = FileNameJoin[{pacletDir, "ResourceDefinition.nb"}];
arguments = Rest[$ScriptCommandLine];
If[Length[arguments] > 1,
  Print["Usage: validate-paclet-source.wls [expected-version-tag]"];
  Exit[2]
];
expectedTag = First[arguments, None];

failures = {};
check[name_String, condition_, detail_] :=
  If[TrueQ[condition],
    Print["[PASS] ", name],
    AppendTo[failures, name];
    Print["[FAIL] ", name, ": ", detail]
  ];

PacletDirectoryLoad[root];
paclets = PacletFind["Gravifer/Einstoff"];
definitionNotebook = Quiet @ Check[Get[definitionFile], $Failed];

cellHasTagQ[cell_Cell, tag_String] := MemberQ[
  Flatten @ Cases[List @@ cell, (CellTags -> value_) :> value, {1}],
  tag
];
taggedCellContents[nb_Notebook, tag_String] := Cases[
  nb,
  cell_Cell /; cellHasTagQ[cell, tag] :> First[List @@ cell],
  Infinity
];
taggedCellContents[_, _] := {};

cellHasTemplateGroupNameQ[cell_Cell, name_String] := Cases[
  List @@ cell,
  (TaggingRules -> rules_) /; MemberQ[
    Flatten @ {rules},
    "TemplateGroupName" -> name
  ],
  {1}
] =!= {};
templateGroupFirstContents[nb_Notebook, name_String] := Cases[
  nb,
  Cell[CellGroupData[{header_Cell, value_Cell, ___}, ___], ___] /;
    cellHasTemplateGroupNameQ[header, name] :> First[List @@ value],
  Infinity
];
templateGroupFirstContents[_, _] := {};

check[
  "definition notebook expression",
  MatchQ[definitionNotebook, _Notebook],
  definitionFile
];

definitionNames = taggedCellContents[definitionNotebook, "Name"];
definitionDescriptions = taggedCellContents[definitionNotebook, "Description"];
definitionSourceURLs = templateGroupFirstContents[
  definitionNotebook,
  "SourceControlURL"
];
projectURL = "https://github.com/Gravifer/Einstoff.wl";

check[
  "publisher paclet discovery",
  Length[paclets] == 1,
  paclets
];

If[Length[paclets] == 1,
  paclet = First[paclets];
  version = paclet["Version"];
  check[
    "version format",
    StringQ[version] && StringMatchQ[
      version,
      RegularExpression[
        "[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
      ]
    ],
    version
  ];
  If[StringQ[expectedTag],
    check[
      "version tag",
      expectedTag === "v" <> version,
      <|"ExpectedTag" -> expectedTag, "PacletVersion" -> version|>
    ]
  ];
  check["minimum Wolfram version", paclet["WolframVersion"] === "13.0+", paclet["WolframVersion"]];
  check["publisher ID", paclet["PublisherID"] === "Gravifer", paclet["PublisherID"]];
  check["primary context", paclet["PrimaryContext"] === "Gravifer`Einstoff`", paclet["PrimaryContext"]];
  check["license", paclet["License"] === "GPL-3.0-or-later", paclet["License"]];
  check["project URL", paclet["URL"] === projectURL, paclet["URL"]];
  check[
    "definition notebook name",
    definitionNames === {paclet["Name"]},
    <|"DefinitionNotebook" -> definitionNames, "PacletInfo" -> paclet["Name"]|>
  ];
  check[
    "definition notebook description",
    definitionDescriptions === {paclet["Description"]},
    <|
      "DefinitionNotebook" -> definitionDescriptions,
      "PacletInfo" -> paclet["Description"]
    |>
  ];
  check[
    "definition notebook source URL",
    definitionSourceURLs === {projectURL},
    definitionSourceURLs
  ];
  description = paclet["Description"];
  check[
    "short description length",
    StringQ[description] && StringLength[description] <= 128,
    If[StringQ[description], StringLength[description], description]
  ];
  descriptionFirst = If[StringQ[description] && description =!= "", StringTake[description, 1], ""];
  check[
    "short description capitalization",
    descriptionFirst =!= "" &&
      ToUpperCase[descriptionFirst] === descriptionFirst &&
      ToLowerCase[descriptionFirst] =!= descriptionFirst,
    description
  ];
  check[
    "short description terminal punctuation",
    StringQ[description] && description =!= "" &&
      ! StringContainsQ[".!?;:,", StringTake[description, -1]],
    description
  ];
];

defaultContentCells = If[
  MatchQ[definitionNotebook, _Notebook],
  Cases[
    definitionNotebook,
    cell_Cell /; cellHasTagQ[cell, "DefaultContent"] :> cell,
    Infinity
  ],
  {}
];
check[
  "definition notebook has no template placeholders",
  defaultContentCells === {},
  Length[defaultContentCells]
];
check[
  "definition notebook credits einops and einx",
  ! FreeQ[definitionNotebook, text_String /; StringContainsQ[text, "https://einops.rocks/"], Infinity] &&
    ! FreeQ[definitionNotebook, text_String /; StringContainsQ[text, "https://github.com/fferflo/einx"], Infinity],
  "Expected source references were not both found."
];
check[
  "definition notebook project links",
  ! FreeQ[definitionNotebook, text_String /; StringContainsQ[text, "https://github.com/Gravifer/Einstoff.wl"], Infinity] &&
    ! FreeQ[definitionNotebook, text_String /; StringContainsQ[text, "https://community.wolfram.com/groups/-/m/t/3749957"], Infinity],
  "Expected project links were not both found."
];

loadResult = Quiet @ Check[Needs["Gravifer`Einstoff`"], $Failed];
check["package load", loadResult =!= $Failed, loadResult];
check["public symbol context", Context[Einstoff] === "Gravifer`Einstoff`", Context[Einstoff]];
check["single public symbol", Names["Gravifer`Einstoff`*"] === {"Einstoff"}, Names["Gravifer`Einstoff`*"]];
check["no legacy context", Names["Einstoff`*"] === {}, Names["Einstoff`*"]];

docs = {
  FileNameJoin[{pacletDir, "Documentation", "English", "ReferencePages", "Symbols", "Einstoff.nb"}],
  FileNameJoin[{pacletDir, "Documentation", "English", "Guides", "Einstoff.nb"}]
};

Scan[
  Function[file,
    nb = Quiet @ Check[Get[file], $Failed];
    check["documentation expression: " <> FileNameTake[file], MatchQ[nb, _Notebook], file];
    check["documentation has no placeholders: " <> FileNameTake[file], FreeQ[nb, "XXXX", Infinity], file];
    topLevelCells = If[MatchQ[nb, _Notebook], First[nb], {}];
    check[
      "documentation has well-formed top-level cells: " <> FileNameTake[file],
      ListQ[topLevelCells] && AllTrue[topLevelCells, MatchQ[#, _Cell] &],
      Cases[topLevelCells, item_ /; ! MatchQ[item, _Cell] :> HoldForm[item]]
    ]
  ],
  docs
];

symbolDoc = Quiet @ Check[Get[First[docs]], $Failed];
usageCells = Cases[symbolDoc, c : Cell[_, "Usage", ___] :> c, Infinity];
usageForms = If[
  Length[usageCells] === 1,
  Cases[First[usageCells], Cell[BoxData[_], "InlineFormula", ___], Infinity],
  {}
];
check[
  "single structured usage cell",
  Length[usageCells] === 1 && Length[usageForms] === 12,
  <|"UsageCells" -> Length[usageCells], "UsageForms" -> Length[usageForms]|>
];

symbolSelfLinks = Cases[
  symbolDoc,
  ButtonBox[_, ___, ButtonData -> "paclet:Gravifer/Einstoff/ref/Einstoff", ___],
  Infinity
];
check[
  "symbol documentation has no self-links",
  symbolSelfLinks === {},
  symbolSelfLinks
];

optionTables = Cases[
  symbolDoc,
  Cell[BoxData[GridBox[rows_List]], "3ColumnTableMod", ___] :> rows,
  Infinity
];
check[
  "documentation option-table columns",
  optionTables =!= {} && AllTrue[Flatten[optionTables, 1], Length[#] === 4 &],
  Length /@ Flatten[optionTables, 1]
];

guideDoc = Quiet @ Check[Get[Last[docs]], $Failed];
guideSymbolLinks = Cases[
  guideDoc,
  ButtonBox["Einstoff", ___, ButtonData -> "paclet:Gravifer/Einstoff/ref/Einstoff", ___],
  Infinity
];
check[
  "guide links to the Einstoff symbol page",
  Length[guideSymbolLinks] === 11,
  Length[guideSymbolLinks]
];
guideForms = Cases[
  guideDoc,
  Cell[BoxData[boxes_], "InlineGuideFunction", ___] :>
    Quiet @ Check[
      ToExpression[
        boxes /. ButtonBox[label_, ___] :> label,
        StandardForm,
        HoldComplete
      ],
      $Failed
    ],
  Infinity
];
expectedGuideForms = {
  HoldComplete[Einstoff[ArrayReshape]],
  HoldComplete[Einstoff["Massage"]],
  HoldComplete[Einstoff[ArrayReduce][f]],
  HoldComplete[Einstoff[Dot]],
  HoldComplete[Einstoff[Inner][mul, add]]
};
check[
  "guide distinguishes operator forms",
  ContainsAll[guideForms, expectedGuideForms] && DuplicateFreeQ[guideForms],
  guideForms
];

systemLinks[nb_] := Cases[
  nb,
  ButtonBox[label_String, ___, ButtonData -> uri_String, ___] /;
      StringStartsQ[uri, "paclet:ref/"] :>
    {label, StringDelete[uri, "paclet:ref/"]},
  Infinity
];

expectedSymbolLinks = {
  "Annotation", "ArrayReduce", "ArrayReshape", "Automatic", "Defer", "Dot",
  "False", "Framed", "Highlighted", "Hold", "Inner", "Join", "Labeled", "Map",
  "None", "Operate", "Rule", "RuleDelayed", "Slot", "Split", "TraceAction", "True"
};
expectedGuideLinks = {
  "Annotation", "ArrayReduce", "ArrayReshape", "Dot", "Framed", "Highlighted",
  "Inner", "Join", "Labeled", "Map", "Operate", "Slot", "Split"
};
forbiddenLinkedSyntax = {":>", "->", "\[CircleTimes]", "\[CirclePlus]", "_", "__", "___", "#"};

Scan[
  Function[{entry},
    pageName = First[entry];
    pageLinks = systemLinks[entry[[2]]];
    expectedLinks = entry[[3]];
    check[
      pageName <> " system-link targets",
      AllTrue[pageLinks, #[[1]] === #[[2]] &],
      Select[pageLinks, #[[1]] =!= #[[2]] &]
    ];
    check[
      pageName <> " system-link coverage",
      ContainsAll[DeleteDuplicates[pageLinks[[All, 1]]], expectedLinks],
      Complement[expectedLinks, DeleteDuplicates[pageLinks[[All, 1]]]]
    ];
    check[
      pageName <> " syntax glyphs remain unlinked",
      Intersection[pageLinks[[All, 1]], forbiddenLinkedSyntax] === {},
      Intersection[pageLinks[[All, 1]], forbiddenLinkedSyntax]
    ]
  ],
  {
    {"symbol documentation", symbolDoc, expectedSymbolLinks},
    {"guide documentation", guideDoc, expectedGuideLinks}
  }
];

If[failures === {},
  Print["All source paclet checks passed."];
  Exit[0],
  Print[Length[failures], " source paclet check(s) failed."];
  Exit[1]
];
