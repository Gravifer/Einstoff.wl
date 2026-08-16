#!/usr/bin/env wolframscript

notebookPath = FileNameJoin[{DirectoryName[$InputFileName], "Einstoff.nb"}];

ClearAll[fail];
fail[message_String] := (Print["FAIL: " <> message]; Exit[1]);

If[!FileExistsQ[notebookPath], fail["missing " <> notebookPath]];

notebook = Quiet[Check[Get[notebookPath], $Failed]];
If[Head[notebook] =!= Notebook, fail["Einstoff.nb is not a Notebook expression"]];

ClearAll[hasCellID];
hasCellID[Cell[_, rest___], id_Integer] :=
  !FreeQ[{rest}, HoldPattern[CellID -> id], {1}];

ClearAll[cellsByID];
cellsByID[id_Integer] :=
  Cases[notebook, cell_Cell /; hasCellID[cell, id] :> cell, Infinity];

requiredCellIDs = {
  863144461, 660820806, 876320555, 67839508, 746063541,
  422531486, 586099280, 298664010, 832981051, 291939446,
  448965068, 494498970, 855757352, 694609509, 512303561,
  938599834, 770806, 759771806,
  788185540, 908162033, 711457694
};

Scan[
  Function[id,
    If[Length[cellsByID[id]] =!= 1,
      fail["expected exactly one cell with CellID " <> ToString[id]]
    ]
  ],
  requiredCellIDs
];

placeholderFragments = {
  "MyFunction", "xxxx", "One-line description", "Text about the example",
  "Additional information about usage", "Author Name", "keyword 1",
  "SymbolName (documented", "Name of another related resource",
  "Additional information for the reviewer", "13.0+"
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

definitionCell = First[cellsByID[876320555]];
definitionBoxes = FirstCase[definitionCell, BoxData[boxes_] :> boxes, Missing[], Infinity];
If[MissingQ[definitionBoxes], fail["definition cell has no BoxData"]];

definition = Quiet[Check[
  ToExpression[definitionBoxes, StandardForm, HoldComplete],
  $Failed
]];
If[Head[definition] =!= HoldComplete, fail["definition cell cannot be parsed"]];

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

If[!StringContainsQ[notebookText, "15.0+"],
  fail["minimum Wolfram Language version is not 15.0+"]
];

requiredCategories = {
  "Data Manipulation & Analysis",
  "Core Language & Structure",
  "Programming Utilities"
};
Scan[
  Function[category,
    If[
      FreeQ[
        notebook,
        HoldPattern[CheckboxBox[category, {False, category}]],
        Infinity
      ],
      fail["category is not selected: " <> category]
    ]
  ],
  requiredCategories
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
