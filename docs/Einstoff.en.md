---
title: "Einstoff"
language: "en"
type: "Symbol"
summary: "Einstoff[op] gives a shape-description interface for array rearrangement, reduction, mapping, contraction and direct-sum operations. Einstoff[op][desc, tensors, bindings] applies the operation op to tensors using axis sizes inferred from desc and any explicit bindings."
keywords:
- array
- tensor
- reshape
- rearrange
- reduction
- contraction
- direct sum
- named axes
source: "Einstoff Documentation"
related_guides:
  -
    title: "Rearranging & Restructuring Lists"
    link: "https://reference.wolfram.com/language/guide/RearrangingAndRestructuringLists.en.md"
  -
    title: "Tensors"
    link: "https://reference.wolfram.com/language/guide/Tensors.en.md"
  -
    title: "Matrix Operations"
    link: "https://reference.wolfram.com/language/guide/MatrixOperations.en.md"
related_functions:
  -
    title: "ArrayReshape"
    link: "https://reference.wolfram.com/language/ref/ArrayReshape.en.md"
  -
    title: "Transpose"
    link: "https://reference.wolfram.com/language/ref/Transpose.en.md"
  -
    title: "ArrayReduce"
    link: "https://reference.wolfram.com/language/ref/ArrayReduce.en.md"
  -
    title: "Tr"
    link: "https://reference.wolfram.com/language/ref/Tr.en.md"
---

# Einstoff

`Einstoff[ArrayReshape][desc, tensors]` performs an element-count-preserving rearrangement of the tensors according to the shape description `desc`.

`Einstoff["Massage"][desc, tensors]` uses the permissive single-tensor structural engine.

`Einstoff["ArrayContract"][desc, tensors]` performs within-tensor pairwise contractions together with reshaping.

`Einstoff[ArrayReduce][f][desc, tensors]` reduces axes of a single tensor using `f`.

`Einstoff[Map][f][desc, tensors]` maps a shape-preserving operation `f` over targeted axes of a single tensor.

`Einstoff[Dot][desc, tensors]` performs a sum-of-products contraction over two or more tensors.

`Einstoff[Inner][mul, add][desc, tensors]` performs a generalized contraction using `mul` and `add`.

`Einstoff[Join][desc, tensors]` concatenates structural direct sums.

`Einstoff[Split][desc, tensors]` splits structural direct sums.

`Einstoff[op][desc, tensors, bindings]` uses the axis-size bindings in `bindings`.

## Details and Options

- `desc` is normally a `RuleDelayed` expression of the form `{in1, in2, ...} :> {out1, out2, ...}`.
- Each input or output shape is a list of dimension terms.
- `tensors` is a list of tensors.
- `bindings` is a list of rules such as `{"channels" -> 3}` or `{c -> 3}`.
- The public operators do not hold `desc`.
- `TraceAction -> Hold` and `TraceAction -> Defer` return the lowered Wolfram expression in held or deferred form.

Dimension terms include:

| Term | Meaning |
| --- | --- |
| `a_` | infer a named axis size |
| `a` | refer to an established axis or to a bound symbol value |
| `"a"` | hygienic string-named axis |
| `__` | infer a sequence of one or more axes sizes |
| `___` | infer a sequence of zero or more axes sizes |
| `2` | literal size |
| `{}` or `1` | unit axis |
| `a ⊗ b` | product axis |
| `a ⊕ b` | direct-sum axis |
| `#a`(`Slot["a"]`), `Highlighted["a"]`, `Framed["a"]` | targeted string axis |
| `Highlighted[a_]`, `Framed[a_]` | targeted blank axis |
| `Highlighted[a]`, `Framed[a]` | targeted bare axis |
| `#2`(`Slot[2]`), `Highlighted[2]`, `Framed[2]` | targeted literal axis |
| `##` | targeted anonymous axis sequence |

The following options can be given:

| Option | Default | Description |
| --- | --- | --- |
| `TraceAction` | `None` | Use `Hold` or `Defer` to inspect the lowered Wolfram expression. |

## Examples

### Basic Examples

Permute axes:

```wl
x = ArrayReshape[Range[24], {2, 3, 4}];
Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}]
```

Merge axes:

```wl
m = ArrayReshape[Range[6], {2, 3}];
Einstoff[ArrayReshape][{{a_, b_}} :> {{a ⊗ b}}, {m}]
```

Reduce an axis:

```wl
x = ArrayReshape[Range[12], {3, 4}];
Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}]
```

Contract two tensors:

```wl
x = ArrayReshape[Range[6], {2, 3}];
y = ArrayReshape[Range[12], {3, 4}];
Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]
```

### Scope

Split a composed axis with an explicit binding:

```wl
Einstoff[ArrayReshape][{{"a" ⊗ b_}} :> {{"a", b}}, {Range[6]}, {"a" -> 2}]
```

Broadcast an output-only axis:

```wl
Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}]
```

Use strings for hygienic names:

```wl
Einstoff[ArrayReshape][{{"row", "col"}} :> {{"col", "row"}}, {ArrayReshape[Range[6], {2, 3}]}]
```

Use a targeted literal:

```wl
y = ArrayReshape[Range[6], {3, 2}];
Einstoff[ArrayReduce][Total][{{a_, Highlighted[2]}} :> {{a}}, {y}]
```

### Generalizations & Extensions

Use named reducers:

```wl
Einstoff[ArrayReduce]["max"][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}]
```

Apply a shape-preserving operation to targeted blocks:

```wl
x = ArrayReshape[Range[8], {2, 4}];
Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]
```

Use a Wolfram function as the map operation:

```wl
Einstoff[Map][Reverse][{{a_, Highlighted[b_]}} :> {{a, Highlighted[b]}}, {ArrayReshape[Range[6], {2, 3}]}]
```

Generalize a tensor contraction:

```wl
Einstoff[Inner][Plus, Min][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}]
```

Use a within-tensor pairwise contraction:

```wl
t = ArrayReshape[Range[16], {2, 2, 2, 2}];
Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{b, d}}, {t}]
```

Concatenate along a direct-sum axis:

```wl
x = ArrayReshape[Range[6], {2, 3}];
y = ArrayReshape[Range[8], {2, 4}];
Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, a ⊕ b}}, {x, y}]
```

Split a direct-sum axis:

```wl
x = ArrayReshape[Range[20], {2, 10}];
Einstoff[Split][{{b_, "q" ⊕ k_}} :> {{b, "q"}, {b, k}}, {x}, {"q" -> 3}]
```

### Applications

Space-to-depth-style rearrangement:

```wl
x = ArrayReshape[Range[2*4*6], {2, 4, 6}];
Einstoff[ArrayReshape][
  {{b_, h_ ⊗ "h1", w_ ⊗ "w1"}} :>
    {{b, h, w, "h1" ⊗ "w1"}},
  {x}, {"h1" -> 2, "w1" -> 3}]
```

Global pooling:

```wl
x = ArrayReshape[Range[2*3*4], {2, 3, 4}];
Einstoff[ArrayReduce][Mean][{{batch_, height_, width_}} :> {{batch}}, {x}]
```

Batched matrix multiplication:

```wl
x = ArrayReshape[Range[24], {2, 3, 4}];
y = ArrayReshape[Range[40], {2, 4, 5}];
Einstoff[Dot][{{n_, a_, b_}, {n_, b_, c_}} :> {{n, a, c}}, {x, y}]
```

Direct-sum block assembly:

```wl
x11 = {{0, 1}};
x12 = {{10, 11, 12}};
x21 = {{20, 21}, {22, 23}};
x22 = {{30, 31, 32}, {33, 34, 35}};

Einstoff["Massage"][
  {{a_, b_}, {a_, c_}, {d_, b_}, {d_, c_}} :>
    {{a ⊕ d, b ⊕ c}},
  {x11, x12, x21, x22}]
```

### Properties & Relations

- `Einstoff[ArrayReshape]` lowers bijective descriptions to combinations of `Transpose`, `ArrayReshape` and unit-axis handling.
- `Einstoff[ArrayReduce][f]` uses `ArrayReduce` after moving the reduced axes into position.
- `Einstoff[Dot]` is the `Times`/`Plus` case of `Einstoff[Inner][mul, add]`.
- `Einstoff[Join]` and `Einstoff[Split]` are structural direct-sum operations over `CirclePlus`.
- `Einstoff["einsum"]` dispatches single-tensor pairwise contractions and multi-tensor cross contractions.

### Possible Issues

A globally assigned bare axis symbol is evaluated before `Einstoff` sees the description:

```wl
Block[{c = 3}, Einstoff[ArrayReshape][{{"c"}} :> {{"c"}}, {Range[5]}]]
```

Keep `bindings` as a list of rules:

```wl
Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}]
```

Target heads are part of targeted binding keys:

```wl
Einstoff[Map]["id"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {ArrayReshape[Range[6], {2, 3}]}]
```

Structural direct sums use bare `CirclePlus`:

```wl
Einstoff[Join][{{a_}, {b_}} :> {{a ⊕ b}}, {Range[2], Range[3]}]
```

## See Also

`ArrayReshape` | `Transpose` | `ArrayReduce` | `Tr` | `Inner` | `Dot` | `TensorContract` | `TensorTranspose` | `ResourceFunction["ArrayContract"]` | `ResourceFunction["EinsteinSummation"]`

External references: einops `rearrange`, einops `reduce`, einops `einsum`, and the einx operation family.

## Related Guides

- Rearranging & Restructuring Lists
- Tensors
- Matrix Operations
- Handling Arrays of Data

## History

Introduced in 2026.
