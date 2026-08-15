#!/usr/bin/env wolframscript
(* ::Package:: *)

(* Generate the 720 x 560 Einstoff headline image embedded in the resource
   definition notebook. The design uses Ubuntu Mono when that font is
   available. Wolfram's PNG exporter may add nondeterministic metadata. *)

$HistoryLength = 0;


ClearAll[elementTile, elementStack, elementBanner];

Options[elementTile] = {
   "Symbol" -> "Ei",
   "AtomicNumber" -> "\!\(\*
StyleBox[\"8\",\nFontSlant->\"Italic\"]\)\[VeryThinSpace]\[Pi]\[VeryThinSpace]\!\(\*
StyleBox[\"G\",\nFontSlant->\"Italic\"]\)",
   "AtomicWeight" -> "1.0",
   "PaletteIndex" -> 1,
   "BackgroundColor" -> Automatic,
   "ForegroundColor" -> Black,
   "BorderColor" -> Black,
   "FontFamily" -> "UbuntuMono",
   ImageSize -> 1000
   };

elementTile[OptionsPattern[]] := Module[
   {
    symbol = OptionValue["Symbol"],
    atomicNumber = OptionValue["AtomicNumber"],
    atomicWeight = OptionValue["AtomicWeight"],
    paletteIndex = OptionValue["PaletteIndex"],
    background,
    foreground = OptionValue["ForegroundColor"],
    border = OptionValue["BorderColor"],
    font = OptionValue["FontFamily"],
    imageSize = OptionValue[ImageSize],
    borderFraction = 0.028
    },
   background = Replace[
     OptionValue["BackgroundColor"],
     Automatic :> Lighter[
       ColorData["DefaultChartColors"]@paletteIndex,
       0.7
       ]
     ];
   Graphics[
    {
     EdgeForm[Directive[border, Thickness[borderFraction]]],
     FaceForm[background],
     Rectangle[
      {borderFraction/2, borderFraction/2},
      {1 - borderFraction/2, 1 - borderFraction/2}
      ],

     Inset[
      Style[
       atomicNumber,
       FontFamily -> font,
       FontSize -> 0.11 imageSize,
       FontSlant -> Plain,
       FontColor -> foreground
       ],
      {0.87, 0.95},
      {Right, Top}
      ],

     Inset[
      Style[
       symbol,
       FontFamily -> font,
       FontSize -> 0.70 imageSize,
       FontWeight -> Bold,
       FontColor -> foreground
       ],
      {0.50, 0.48},
      Center
      ],

     Inset[
      Style[
       atomicWeight,
       FontFamily -> font,
       FontSize -> 0.13 imageSize,
       FontSlant -> Italic,
       FontColor -> foreground
       ],
      {0.50, 0.115},
      Center
      ]
     },
    PlotRange -> {{0, 1}, {0, 1}},
    PlotRangePadding -> None,
    ImagePadding -> 0,
    Background -> None,
    ImageSize -> imageSize
    ]
   ];


Options[elementStack] = {
   "TileSpecifications" -> {
     <|"Symbol" -> "Ei", "PaletteIndex" -> 1|>,
     <|
      "Symbol" -> "ns",
      "AtomicNumber" -> "p>",
      "AtomicWeight" -> "0.05",
      "PaletteIndex" -> 3
      |>,
     <|
      "Symbol" -> "to",
      "AtomicNumber" -> "5\[Degree]",
      "AtomicWeight" -> "100 km/h",
      "PaletteIndex" -> 2
      |>,
     <|
      "Symbol" -> "ff",
      "AtomicNumber" -> "--ff-only",
      "AtomicWeight" -> "HEAD \[Rule] main",
      "PaletteIndex" -> 4
      |>
     },
   "FrontOpacity" -> 0.86,
   "RearOpacity" -> 0.72,
   "OutlineOpacityStep" -> 0.14,
   "LayerOffset" -> {-0.10, 0.16, 0.10},
   "TileRasterSize" -> 800,
   ViewPoint -> {-3.0, -7.0, 2.1},
   ImageSize -> 1200
   };

elementStack[OptionsPattern[]] := Module[
   {
    tileSpecifications = OptionValue["TileSpecifications"],
    frontOpacity = OptionValue["FrontOpacity"],
    rearOpacity = OptionValue["RearOpacity"],
    outlineOpacityStep = OptionValue["OutlineOpacityStep"],
    layerOffset = OptionValue["LayerOffset"],
    tileRasterSize = OptionValue["TileRasterSize"],
    viewPoint = OptionValue[ViewPoint],
    imageSize = OptionValue[ImageSize],
    tileImages,
    planes
    },
   tileImages = MapIndexed[
     Function[{specification, index},
      With[
       {
        depth = First[index] - 1,
        paletteIndex = Lookup[specification, "PaletteIndex", 1]
        },
       Rasterize[
        elementTile[
         "Symbol" -> Lookup[specification, "Symbol", "Ei"],
         "AtomicNumber" -> Lookup[
           specification,
           "AtomicNumber",
           Options[elementTile, "AtomicNumber"][[1, 2]]
           ],
         "AtomicWeight" -> Lookup[
           specification,
           "AtomicWeight",
           Options[elementTile, "AtomicWeight"][[1, 2]]
           ],
         "PaletteIndex" -> paletteIndex,
         "BackgroundColor" -> Opacity[
           If[depth == 0, frontOpacity, rearOpacity],
           Lighter[
            ColorData["DefaultChartColors"]@paletteIndex,
            0.7
            ]
           ],
         "BorderColor" -> Opacity[
           Max[0, frontOpacity - depth outlineOpacityStep],
           Black
           ],
         ImageSize -> tileRasterSize
         ],
        "Image",
        RasterSize -> tileRasterSize,
        Background -> None
        ]
       ]
      ],
     tileSpecifications
     ];
   planes = MapIndexed[
     Function[{image, index},
      With[
       {
        depth = First[index] - 1,
        offset = (First[index] - 1) layerOffset
        },
       {
        Texture[image],
        Polygon[
         {
          {-1 + offset[[1]], offset[[2]], -1 + offset[[3]]},
          {1 + offset[[1]], offset[[2]], -1 + offset[[3]]},
          {1 + offset[[1]], offset[[2]], 1 + offset[[3]]},
          {-1 + offset[[1]], offset[[2]], 1 + offset[[3]]}
          },
         VertexTextureCoordinates -> {
           {0, 0}, {1, 0}, {1, 1}, {0, 1}
           }
         ]
        }
       ]
      ],
     tileImages
     ];
   Graphics3D[
    Reverse[planes],
    Boxed -> False,
    Axes -> False,
    Lighting -> {{"Ambient", White}},
    Background -> White,
    ViewPoint -> viewPoint,
    ViewVertical -> {0, 0, 1},
    SphericalRegion -> True,
    PlotRange -> All,
    ImageSize -> imageSize
    ]
   ];


Options[elementBanner] = {
   "Wordmark" -> "nstoff",
   "Slogan" -> "Wolfram-native tensor-axis notation",
   "FontFamily" -> "UbuntuMono",
   "IconPosition" -> {0.25, 0.53},
   "IconSize" -> {0.46, 0.62},
   "WordmarkPosition" -> {0.68, 0.50},
   "WordmarkScale" -> 0.18,
   "SloganPosition" -> {0.68, 0.37},
   "SloganScale" -> 0.028,
   ImageSize -> {720, 560}
   };

elementBanner[stackGraphic_, OptionsPattern[]] := Module[
   {
    wordmark = OptionValue["Wordmark"],
    slogan = OptionValue["Slogan"],
    font = OptionValue["FontFamily"],
    iconPosition = OptionValue["IconPosition"],
    iconSize = OptionValue["IconSize"],
    wordmarkPosition = OptionValue["WordmarkPosition"],
    wordmarkScale = OptionValue["WordmarkScale"],
    sloganPosition = OptionValue["SloganPosition"],
    sloganScale = OptionValue["SloganScale"],
    imageSize = OptionValue[ImageSize],
    width
    },
   width = First[imageSize];
   Graphics[
    {
     Inset[
      stackGraphic,
      iconPosition,
      Center,
      iconSize
      ],
     Inset[
      Style[
       wordmark,
       FontFamily -> font,
       FontSize -> wordmarkScale width,
       FontWeight -> Bold,
       FontColor -> Black
       ],
      wordmarkPosition,
      Center
      ],
     Inset[
      Style[
       slogan,
       FontFamily -> font,
       FontSize -> sloganScale width,
       FontColor -> Black
       ],
      sloganPosition,
      Center
      ]
     },
    PlotRange -> {{0, 1}, {0, 1}},
    PlotRangePadding -> None,
    ImagePadding -> 0,
    Background -> White,
    AspectRatio -> Last[imageSize]/First[imageSize],
    ImageSize -> imageSize
    ]
   ];


stack = elementStack[];
banner = elementBanner[stack];


scriptDirectory = Replace[
   DirectoryName[$InputFileName],
   "" -> Directory[]
   ];

bannerOutputPath = FileNameJoin[{scriptDirectory, "element-banner.png"}];

Export[
 bannerOutputPath,
 Rasterize[
  banner,
  "Image",
  RasterSize -> {720, 560},
  Background -> White
  ],
 "PNG"
 ];

Print["Exported ", bannerOutputPath];
