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
  -
    title: "Handling Arrays of Data"
    link: "https://reference.wolfram.com/language/guide/HandlingArraysOfData.en.md"
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
  -
    title: "Inner"
    link: "https://reference.wolfram.com/language/ref/Inner.en.md"
  -
    title: "Dot"
    link: "https://reference.wolfram.com/language/ref/Dot.en.md"
  -
    title: "TensorContract"
    link: "https://reference.wolfram.com/language/ref/TensorContract.en.md"
  -
    title: "TensorTranspose"
    link: "https://reference.wolfram.com/language/ref/TensorTranspose.en.md"
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
- `Einstoff[ArrayReduce]` allows named recipes `"sum" | "total" | "add"` `"mean" | "average"` `"max"` `"min"` `"prod" | "product" | "times"` `"var" | "variance"` `"std" | "stddev"` `"count_nonzero" | "countnonzero"` `"any"` `all` and `"logsumexp" | "lse"`;
  `Einstoff[Map]` allows named recipes `id` `flip` `sort` `softmax` and `log_softmax`.

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
| `"Targeting"` | `Automatic` | For `ArrayReduce`, `Dot`, `Inner`, `Massage`, `ArrayContract`, and `einsum`, use `False` to infer operated axes from RHS absence/repetition, `Automatic` to infer but validate explicit targets, or `True` to require explicit targets. |

## Examples

### Basic Examples

Permute axes:

```wl
In[1]:= x = ArrayReshape[Range[24], {2, 3, 4}];
In[2]:= Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}]

Out[2]= {{{1, 5, 9}, {13, 17, 21}}, {{2, 6, 10}, {14, 18, 22}}, {{3, 7, 11}, {15, 19, 23}}, {{4, 8, 12}, {16, 20, 24}}}
```

Merge axes:

```wl
In[3]:= m = ArrayReshape[Range[6], {2, 3}];
In[4]:= Einstoff[ArrayReshape][{{a_, b_}} :> {{a ⊗ b}}, {m}]

Out[4]= {1, 2, 3, 4, 5, 6}
```

Reduce an axis:

```wl
In[5]:= x = ArrayReshape[Range[12], {3, 4}];
In[6]:= Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}]

Out[6]= {10, 26, 42}
```

Contract two tensors:

```wl
In[7]:= x = ArrayReshape[Range[6], {2, 3}];
In[8]:= y = ArrayReshape[Range[12], {3, 4}];
In[9]:= Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]

Out[9]= {{38, 44, 50, 56}, {83, 98, 113, 128}}
```

Require explicit contraction targets:

```wl
In[10]:= Einstoff[Dot][{{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {x, y}, {}, "Targeting" -> True]

Out[10]= {{38, 44, 50, 56}, {83, 98, 113, 128}}
```

### Scope

Split a composed axis with an explicit binding:

```wl
In[10]:= Einstoff[ArrayReshape][{{"a" ⊗ b_}} :> {{"a", b}}, {Range[6]}, {"a" -> 2}]

Out[10]= {{1, 2, 3}, {4, 5, 6}}
```

Broadcast an output-only axis:

```wl
In[11]:= Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}]

Out[11]= {{1, 1, 1}, {2, 2, 2}, {3, 3, 3}, {4, 4, 4}}
```

Use strings for hygienic names:

```wl
In[12]:= Einstoff[ArrayReshape][{{"row", "col"}} :> {{"col", "row"}}, {ArrayReshape[Range[6], {2, 3}]}]

Out[12]= {{1, 4}, {2, 5}, {3, 6}}
```

Use a targeted literal:

```wl
In[13]:= y = ArrayReshape[Range[6], {3, 2}];
Einstoff[ArrayReduce][Total][{{a_, Highlighted[2]}} :> {{a}}, {y}]

Out[13]= {3, 7, 11}
```

Apply a shape-preserving operation to targeted blocks:

```wl
In[15]:= x = ArrayReshape[Range[8], {2, 4}];
In[16]:= Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]

Out[16]= {{4, 3, 2, 1}, {8, 7, 6, 5}}
```

Use a Wolfram function as the map operation:

```wl
In[17]:= Einstoff[Map][Reverse][{{a_, Highlighted[b_]}} :> {{a, Highlighted[b]}}, {ArrayReshape[Range[6], {2, 3}]}]

Out[17]= {{3, 2, 1}, {6, 5, 4}}
```

Do a tropical tensor contraction:

```wl
In[18]:= Einstoff[Inner][Plus, Min][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}]

Out[18]= {{2, 3, 4}, {3, 4, 5}}
```

Use a within-tensor pairwise contraction:

```wl
In[19]:= t = ArrayReshape[Range[16], {2, 2, 2, 2}];
In[20]:= Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{b, d}}, {t}]

Out[20]= {{12, 14}, {20, 22}}
```

Concatenate along a direct-sum axis:

```wl
In[21]:= x = ArrayReshape[Range[6], {2, 3}];
In[22]:= y = ArrayReshape[Range[8], {2, 4}];
In[23]:= Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, a ⊕ b}}, {x, y}]

Out[23]= {{1, 2, 3, 1, 2, 3, 4}, {4, 5, 6, 5, 6, 7, 8}}
```

### Generalizations & Extensions

Use named reducers:

```wl
In[14]:= Einstoff[ArrayReduce]["max"][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}]

Out[14]= {4, 8, 12}
```

Split a direct-sum axis:

```wl
In[24]:= x = ArrayReshape[Range[20], {2, 10}];
In[25]:= Einstoff[Split][{{b_, "q" ⊕ k_}} :> {{b, "q"}, {b, k}}, {x}, {"q" -> 3}]

Out[25]= {{{1, 2, 3}, {11, 12, 13}}, {{4, 5, 6, 7, 8, 9, 10}, {14, 15, 16, 17, 18, 19, 20}}}
```

### Applications

Space-to-depth-style rearrangement:

```wl
In[26]:= x = ArrayReshape[Range[2*4*6], {2, 4, 6}];
In[27]:= Einstoff[ArrayReshape][
  {{b_, h_ ⊗ "h1", w_ ⊗ "w1"}} :>
    {{b, h, w, "h1" ⊗ "w1"}},
  {x}, {"h1" -> 2, "w1" -> 3}]

Out[27]= {{{{1, 2, 3, 7, 8, 9}, {4, 5, 6, 10, 11, 12}}, {{13, 14, 15, 19, 20, 21}, {16, 17, 18, 22, 23, 24}}}, {{{25, 26, 27, 31, 32, 33}, {28, 29, 30, 34, 35, 36}}, {{37, 38, 39, 43, 44, 45}, {40, 41, 42, 46, 47, 48}}}}
```

Global pooling:

```wl
In[28]:= x = ArrayReshape[Range[2*3*4], {2, 3, 4}];
In[29]:= Einstoff[ArrayReduce][Mean][{{batch_, height_, width_}} :> {{batch}}, {x}]

Out[29]= {13/2, 37/2}
```

Batched matrix multiplication:

```wl
In[30]:= x = ArrayReshape[Range[24], {2, 3, 4}];
In[31]:= y = ArrayReshape[Range[40], {2, 4, 5}];
In[32]:= Einstoff[Dot][{{n_, a_, b_}, {n_, b_, c_}} :> {{n, a, c}}, {x, y}]

Out[32]= {{{110, 120, 130, 140, 150}, {246, 272, 298, 324, 350}, {382, 424, 466, 508, 550}}, {{1678, 1736, 1794, 1852, 1910}, {2134, 2208, 2282, 2356, 2430}, {2590, 2680, 2770, 2860, 2950}}}
```

Direct-sum block assembly:

```wl
In[33]:= x11 = {{0, 1}};
In[34]:= x12 = {{10, 11, 12}};
In[35]:= x21 = {{20, 21}, {22, 23}};
In[36]:= x22 = {{30, 31, 32}, {33, 34, 35}};

In[37]:= Einstoff["Massage"][
  {{a_, b_}, {a_, c_}, {d_, b_}, {d_, c_}} :>
    {{a ⊕ d, b ⊕ c}},
  {x11, x12, x21, x22}]

Out[37]= {{0, 1, 10, 11, 12}, {20, 21, 30, 31, 32}, {22, 23, 33, 34, 35}}
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
In[29]:= Block[{c = 3}, Einstoff[ArrayReshape][{{"c"}} :> {{"c"}}, {Range[5]}]]

Out[29]= {1, 2, 3, 4, 5}
```

Keep `bindings` as a list of rules:

```wl
In[30]:= Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}]

Out[30]= {{1, 1, 1}, {2, 2, 2}, {3, 3, 3}, {4, 4, 4}}
```

Target heads are part of targeted binding keys:

```wl
In[31]:= Einstoff[Map]["id"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {ArrayReshape[Range[6], {2, 3}]}]

Out[31]= {{1, 2, 3}, {4, 5, 6}}
```

Structural direct sums use bare `CirclePlus`:

```wl
In[32]:= Einstoff[Join][{{a_}, {b_}} :> {{a ⊕ b}}, {Range[2], Range[3]}]

Out[32]= {1, 2, 1, 2, 3}
```

### Neat Examples
<!-- fill in notebook version; agents should skip this for now -->

## Additional Information

### Contributed By

* Gravifer

### Version History

* 0.1.0 — 07 July 2026 <!-- not actually published yet -->

### Related Resources

* [`ResourceFunction["ArrayContract"]`](https://resources.wolframcloud.com/FunctionRepository/resources/ArrayContract)
* [`ResourceFunction["EinsteinSummation"]`](https://resources.wolframcloud.com/FunctionRepository/resources/EinsteinSummation)

### Related Symbols

* [`ArrayReshape`](https://reference.wolfram.com/language/ref/ArrayReshape.en.md)
* [`Transpose`](https://reference.wolfram.com/language/ref/Transpose.en.md)
* [`ArrayReduce`](https://reference.wolfram.com/language/ref/ArrayReduce.en.md)
* [`Tr`](https://reference.wolfram.com/language/ref/Tr.en.md)
* [`Inner`](https://reference.wolfram.com/language/ref/Inner.en.md)
* [`Dot`](https://reference.wolfram.com/language/ref/Dot.en.md)
* [`TensorContract`](https://reference.wolfram.com/language/ref/TensorContract.en.md)
* [`TensorTranspose`](https://reference.wolfram.com/language/ref/TensorTranspose.en.md)

### Source/Reference Citation

```bibtex
@inproceedings{
fervers2026its,
title={It's All Just Vectorization: einx, a Universal Notation for Tensor Operations},
author={Florian Fervers and Sebastian Bullinger and Christoph Bodensteiner and Michael Arens},
booktitle={The Fourteenth International Conference on Learning Representations},
year={2026},
url={https://openreview.net/forum?id=QqvQ3iAdpC}
}
```

### Links

* [Python package `einops`](https://einops.rocks)
* [Python package `einx`](https://einx.readthedocs.io)

<!-- #### Related Guides -->

* [Rearranging & Restructuring Lists](https://reference.wolfram.com/language/guide/RearrangingAndRestructuringLists.en.md)
* [`Tensors`](https://reference.wolfram.com/language/guide/Tensors.en.md)
* [Matrix Operations](https://reference.wolfram.com/language/guide/MatrixOperations.en.md)
* [Handling Arrays of Data](https://reference.wolfram.com/language/guide/HandlingArraysOfData.en.md)

<!-- ### Tests -->
<!-- fill in notebook version; agents should ignore -->

### Compatibility

#### Wolfram Language Version

* 14.0+

<!-- 
#### Operating System

* [x] Windows
* [x] Mac
* [x] Unix

#### Required Features

* [ ] Notebooks
* [ ] Parallel Kernels
* [ ] Cloud Access

#### Environments

* [x] Session
* [x] Script
* [x] Subkernel
* [x] WebEvaluation
* [x] WebAPI
* [x] Scheduled
* [x] BatchJob

#### Cloud Support

* [x] Supported in cloud
-->

## Author Notes
<!-- fill in notebook version; agents should ignore -->

<!-- ## Submission Notes -->
<!-- fill in notebook version; agents should ignore -->
