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
  check["minimum Wolfram version", paclet["WolframVersion"] === "15.0+", paclet["WolframVersion"]];
  check["publisher ID", paclet["PublisherID"] === "Gravifer", paclet["PublisherID"]];
  check["primary context", paclet["PrimaryContext"] === "Gravifer`Einstoff`", paclet["PrimaryContext"]];
  check["license", paclet["License"] === "GPL-3.0-or-later", paclet["License"]];
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
