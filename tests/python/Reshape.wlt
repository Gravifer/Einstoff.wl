(* ::Package:: *)

(* Cross-validation tests for the rearrange/reshape lowering: Einstoff's output
   is checked against the *actual* einx / einops Python implementations (SPEC
   §10.1), not against hand-written expected arrays.

   Opt-in only: run with `wolframscript -script scripts/run-tests.wls python`.
   The runner globs tests/python/*.wlt solely when --python (or the plain word
   `python`) is given.

   Mechanics (SPEC §10.1):
     - ExternalEvaluate over an ephemeral ExternalSessionObject bound directly to
       the repo .venv interpreter (no persistent registry mutation; the session
       object is itself opaque and is DeleteObject'd at the end). Registering by
       UUID and targeting it does NOT work headless under wolframscript, so we
       start a session from the Executable spec instead.
     - Inputs are rebuilt independently on both sides from a shared dims recipe:
       WL  ArrayReshape[Range[Times @@ dims], dims]   (1-based, row-major)
       Py  (1 + np.arange(prod)).reshape(dims)        (1+ to match Range; numpy
                                                        default C-order = row-major)
       so element-wise integer equality is exact (no float tolerance).
     - Only the result crosses the boundary, via .tolist() -> WL integer lists.

   The Python pattern string <-> Wolfram desc equivalence in each test is reasoned
   OUT OF BAND and written by hand (SPEC §10.1); only the implemented reshape
   subset is required to agree.

   BeginTestSection[name, pythonReady] skips (not fails) the whole section when
   Python / the packages are unavailable. *)

ClearAll[a, b, c, d];

(* Project root: exported by the runner; fall back to the loaded paclet's
   location so the file is also usable via a bare TestReport[...]. *)
pyRoot =
  If[ValueQ[Einstoff`Tests`$Root], Einstoff`Tests`$Root,
    ParentDirectory[PacletObject["Einstoff"]["Location"]]];
pyExe = FileNameJoin[{pyRoot, ".venv", "Scripts", "python.exe"}];

(* Reuse the runner's shared session if it spawned one (one ZMQ session per kernel
   is stable, many are not); otherwise spawn our own so the file still runs under a
   bare TestReport, and own only that teardown. *)
pyOwned = Head[Einstoff`Tests`$PySession] =!= ExternalSessionObject;
pySession = If[pyOwned,
  Quiet @ Check[
    If[FileExistsQ[pyExe],
      StartExternalSession[<|"System" -> "Python", "Executable" -> pyExe|>], $Failed], $Failed],
  Einstoff`Tests`$PySession];
pythonReady = TrueQ @ Quiet @ Check[
  Head[pySession] === ExternalSessionObject &&
  ExternalEvaluate[pySession, "import numpy, einops, einx; True"] === True,
  False];

(* ---- reference helper -------------------------------------------------- *)
(* pyRef[backend, pattern, dims, kwargs] rebuilds the input from `dims` inside
   Python, applies the einops/einx call, and returns the result as WL integer
   lists. dims/kwargs are rendered in Python syntax (brackets, not braces). *)

pyDims[l_List] := "[" <> StringRiffle[ToString /@ l, ", "] <> "]";
pyKwargs[kw_Association] := StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, kw], ", "];

pyRef[backend_, pattern_, dims_List, kwargs_ : <||>] :=
  Module[{prod = Times @@ dims, kw = pyKwargs[kwargs], call},
    call = Switch[backend,
      "einops", "einops.rearrange(x, " <> ToString[pattern, InputForm] <>
                  If[kw === "", "", ", " <> kw] <> ")",
      (* einops.rearrange cannot introduce axes; repetition needs einops.repeat *)
      "einops.repeat", "einops.repeat(x, " <> ToString[pattern, InputForm] <>
                  If[kw === "", "", ", " <> kw] <> ")",
      "einx",   "einx.id(" <> ToString[pattern, InputForm] <> ", x" <>
                  If[kw === "", "", ", " <> kw] <> ")"];
    ExternalEvaluate[pySession,
      "import numpy as np, einops, einx\n" <>
      "x = (1 + np.arange(" <> ToString[prod] <> ")).reshape(" <> pyDims[dims] <> ")\n" <>
      "(" <> call <> ").tolist()"]];

(* ======================================================================== *)
BeginTestSection["Einstoff`CrossValidation`Reshape", pythonReady];

(* einops 'a b c -> c a b'  <->  {{a_,b_,c_}} :> {{c,a,b}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  pyRef["einops", "a b c -> c a b", {2, 3, 4}],
  TestID -> "xval-einops-permute"
];

(* einops 'a (b c) -> (b a) c', b=2  <->  {{a_, b_ \[CircleTimes] c_}} :> {{b_ \[CircleTimes] a_, c}} *)
VerificationTest[
  Einstoff[ArrayReshape][
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {ArrayReshape[Range[32], {4, 8}]}, {b -> 2}],
  pyRef["einops", "a (b c) -> (b a) c", {4, 8}, <|"b" -> 2|>],
  TestID -> "xval-einops-split-permute-merge"
];

(* einops 'a b -> (a b)'  <->  {{a_,b_}} :> {{a \[CircleTimes] b}}  (pure merge) *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, b_}} :> {{CircleTimes[a, b]}}, {ArrayReshape[Range[6], {2, 3}]}],
  pyRef["einops", "a b -> (a b)", {2, 3}],
  TestID -> "xval-einops-merge"
];

(* einops '(a b) -> a b', a=2  <->  {{a_ \[CircleTimes] b_}} :> {{a,b}}  (pure split) *)
VerificationTest[
  Einstoff[ArrayReshape][{{CircleTimes[a_, b_]}} :> {{a, b}}, {Range[6]}, {a -> 2}],
  pyRef["einops", "(a b) -> a b", {6}, <|"a" -> 2|>],
  TestID -> "xval-einops-split"
];

(* einops 4D 'b h w c -> b c h w'  <->  {{b_,h_,w_,c_}} :> {{b,c,h,w}} *)
VerificationTest[
  Einstoff[ArrayReshape][
    {{a_, b_, c_, d_}} :> {{a, d, b, c}}, {ArrayReshape[Range[2*3*4*5], {2, 3, 4, 5}]}],
  pyRef["einops", "b h w c -> b c h w", {2, 3, 4, 5}],
  TestID -> "xval-einops-permute-4d"
];

(* einx.id 'a b c -> c a b' (same desc, einx backend)  <->  {{a_,b_,c_}} :> {{c,a,b}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  pyRef["einx", "a b c -> c a b", {2, 3, 4}],
  TestID -> "xval-einx-permute"
];

(* einx.id 'a (b c) -> (b a) c', b=2 (einx backend) *)
VerificationTest[
  Einstoff[ArrayReshape][
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {ArrayReshape[Range[32], {4, 8}]}, {b -> 2}],
  pyRef["einx", "a (b c) -> (b a) c", {4, 8}, <|"b" -> 2|>],
  TestID -> "xval-einx-split-permute-merge"
];

(* --- repetition (SPEC 5.5) --- *)

(* repeat 'a -> a c', c=3  <->  {{a_}} :> {{a, c}}, {c -> 3} — einx and einops *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}],
  pyRef["einx", "a -> a c", {4}, <|"c" -> 3|>],
  TestID -> "xval-einx-repeat"
];
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}],
  pyRef["einops.repeat", "a -> a c", {4}, <|"c" -> 3|>],
  TestID -> "xval-einops-repeat-1d"
];

(* 'a b -> a b c', c=2  <->  {{a_,b_}} :> {{a, b, c}}, {c -> 2} — both backends:
   einops needs einops.repeat (rearrange cannot introduce axes); einx.id is uniform. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, b_}} :> {{a, b, c}}, {ArrayReshape[Range[6], {2, 3}]}, {c -> 2}],
  pyRef["einops.repeat", "a b -> a b c", {2, 3}, <|"c" -> 2|>],
  TestID -> "xval-einops-repeat"
];
VerificationTest[
  Einstoff[ArrayReshape][{{a_, b_}} :> {{a, b, c}}, {ArrayReshape[Range[6], {2, 3}]}, {c -> 2}],
  pyRef["einx", "a b -> a b c", {2, 3}, <|"c" -> 2|>],
  TestID -> "xval-einx-repeat-2d"
];

(* explicit-integer repeat 'a -> a 2'  <->  {{a_}} :> {{a, 2}} — einx and einops *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, 2}}, {Range[4]}],
  pyRef["einx", "a -> a 2", {4}],
  TestID -> "xval-einx-repeat-integer"
];
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, 2}}, {Range[4]}],
  pyRef["einops.repeat", "a -> a 2", {4}],
  TestID -> "xval-einops-repeat-integer"
];

(* repeat inside an output composite 'a -> (a c)', c=3  <->  {{a_}} :> {{a \[CircleTimes] c}}
   — einx and einops *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{CircleTimes[a, c]}}, {Range[4]}, {c -> 3}],
  pyRef["einx", "a -> (a c)", {4}, <|"c" -> 3|>],
  TestID -> "xval-einx-repeat-merge"
];
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{CircleTimes[a, c]}}, {Range[4]}, {c -> 3}],
  pyRef["einops.repeat", "a -> (a c)", {4}, <|"c" -> 3|>],
  TestID -> "xval-einops-repeat-merge"
];

EndTestSection[];
(* ======================================================================== *)

(* Tear down only a session we spawned ourselves; the runner owns the shared one. *)
If[pyOwned && Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
