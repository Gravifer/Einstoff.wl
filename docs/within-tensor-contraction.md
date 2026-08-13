# Within-tensor contraction (traces & diagonals) — semantics & design note

> Status: **pairwise core implemented** (2026-06; staged self-contraction plan step,
> `Einstoff["Massage"]`, `Einstoff["einsum"]`). The combiner generalization, diagonal-
> keep, `>2` super-diagonals, and mixed within+cross multi-operand einsum remain deferred
> per §7. Captures how the ein* / NumPy / Wolfram ecosystem treats a *repeated index*,
> the geometric meaning of contraction, and the design boundary. The future public
> documentation should reflect §4 and §7.

## 1. Motivation

General relativity and tensor calculus rely constantly on *within-tensor* contraction
— e.g. the Ricci tensor `R_{bd} = R^a{}_{bad}`, contracting slots 1 and 3 of the
Riemann tensor. In ein* notation this is a **repeated index in one operand**
(`a b a d -> b d`). einx cannot express it; `einops.einsum` / `numpy.einsum` and the
Wolfram primitives can. This note exists because that capability sits right on a
semantic fault line we must understand before building.

## 2. How the ecosystem treats a repeated index (verified empirically)

`einops.einsum` (space-separated axes) is a thin wrapper over `np.einsum`, so they are
identical:

| pattern | meaning | numpy / einops.einsum | WL `EinsteinSummation` (resource) | einx & einops `rearrange/reduce` |
|---|---|---|---|---|
| `a a ->` | trace (repeat **dropped**) | ✅ `15` | ❌ unsupported | ❌ |
| `a b a d -> b d` | partial trace, non-adjacent | ✅ | ❌ | ❌ |
| `a a -> a` | diagonal (repeat **kept**) | ✅ `{1,5,9}` | ❌ | ❌ |
| `a a a ->` | super-diagonal sum (**>2** reps) | ✅ `42` | ❌ ">2 not supported" | ❌ |
| `a a, a ->` | within + cross mixed | ✅ `38` | ✅ (cross part) | ❌ |
| `a -> a a` | repeat on the **output** | ❌ **error** | ❌ | ❌ |
| `a a ->` on a 2×3 | unequal dims | ❌ **error** (dims must match) | — | — |

Takeaways:
- **`einops.einsum` = `np.einsum`** — the full einsum rule, via the backend.
- **einx and the einops `rearrange/reduce/repeat` family forbid repeated names entirely**
  (einx's model treats names as independent coordinates and cannot compile a diagonal).
- **WL's own `EinsteinSummation` is deliberately restrictive**: cross-tensor only, **≤ 2
  repetitions**, **no diagonal-keep**. A careful WL implementation chose exactly the
  geometrically-meaningful regime (see §4).
- **Repeat on the output is rejected by everyone**, numpy and einops included. Our
  existing RHS-duplicate check already matches this.

## 3. The semantics, precisely

The einsum rule is *total and deterministic* — numpy/einops never guess. The
"ambiguity" lives at three boundaries:

1. **The convention fork.** A repeated name can mean "**same coordinate → couple**
   (diagonal)" or "**independent axes, equal size**". These differ: einx's `[a][a]` sum
   = `45` (independent), einsum's `a a ->` = `15` (coupled). einsum/NumPy/`TensorContract`
   pick **couple, always** — there is no einsum spelling for "independent equal size"
   (use two letters). einx picks the other branch and forbids the notation. Matching
   GR/einsum means choosing **couple**.
2. **Keep vs drop** (once coupled):
   - repeated **dropped** → **contract / trace** (`TensorContract`/`ArrayContract`). *One
     unambiguous meaning.*
   - repeated **kept once** → **diagonal** (`Diagonal`, + a transpose for non-adjacent
     slots). Well-defined, but a *different* primitive and a non-summing operation.
   - repeated on the **output** → **error** everywhere. Keep rejecting it.
3. **Equal dimensions required** — a coupled index forces its slots to share a size
   (numpy errors otherwise). `Gravifer`Einstoff`'s `unify` already enforces this, so a mismatch
   is caught as unsatisfiable before any lowering.

## 4. What an N-way contraction actually *means*

**Genuine tensor contraction is pairwise (2-way).** It pairs two slots and sums their
coincident values.

- *Mathematically*: contracting a (1,1) tensor is the natural pairing `V ⊗ V* → k`
  (evaluation); the trace is the basis-independent `Σ eigenvalues`, invariant under
  `M ↦ P M P⁻¹`. A partial contraction (Ricci `R^a{}_{bad}`) pairs **one** pair of slots,
  leaving a lower-rank tensor.
- *Geometrically*: trace is the first-order volume change,
  `det(I + εM) ≈ 1 + ε·tr M` (Jacobi).
- *Physically*: contracting one **upper** (contravariant) against one **lower**
  (covariant) index yields a coordinate-invariant quantity. Invariance is *why* it is
  pairwise — the natural pairing `V ⊗ V*` is inherently two slots.

**An "N-way" same-name sum (N > 2, `a…a -> … = Σ_i T_{i…i}`) is NOT a tensor
contraction.** It is the sum over the **super-diagonal** — contraction against the
order-N generalized Kronecker delta `δ_{i₁…i_N}` (1 iff all indices coincide). That
delta is not a tensor (it does not transform correctly), so the operation is
**basis-dependent** and geometrically unnatural, and it cannot be assembled from
pairwise contractions of a single tensor. NumPy/`einops.einsum` allow it as an *array*
convenience; physics essentially never uses it. This is precisely why
`EinsteinSummation` stops at 2 repetitions.

Consequence for design: **pairwise contraction is the principled core**; `>2` same-name
is a separate, clearly-labeled super-diagonal (an `ArrayContract[t, {{1,2,3}}, …]`), not
a contraction.

## 5. Interactions unique to Einstoff

Plain einsum has no brackets, composites, direct sums, or repetition, so it never faces
these. We must legislate them:

- **Brackets `[a]`** mark reduce/map/dot axes; a repeated bare `a…a` *also* implies
  contraction. einx errors on the mixed form ("inconsistent bracket usage"). Cleanest
  rule: a repeated name couples regardless of brackets, and a name may not be *both*
  bracketed and repeated → reject.
- **Composites `(a b)` / direct sums `(a ⊕ b)`** containing a name that repeats
  elsewhere → undefined → reject initially.
- **Repetition (§5.5)**: an output-only *new* name is a broadcast; it does not collide
  with a repeated (on-input) name, but the notation then carries three non-rearrange
  behaviors (create / couple-drop / couple-keep) — keep the rules crisp.

## 6. Wolfram primitives available

- **`TensorContract[t, {{i,j}, …}]`** — contracts arbitrary slot **pairs**
  simultaneously; paired slots must share dimensions; goes inert on a mismatch (gated by
  `unify`). The direct match for pairwise contraction.
- **`Tr[t, f, n]`** — generalized trace over *leading* levels: `f` replaces `Plus`
  (`Tr[t, Min]` = tropical trace, `Tr[t, List]` = `Diagonal`), `n` limits depth. Good for
  full/leading traces; needs a transpose for non-adjacent slots.
- **`ArrayContract[t, ctrs, g, d]`** (resource function) — the generalization we want:
  contracts **arbitrary level-groups** (not just pairs → super-diagonals) with an
  **arbitrary head `g`** (not just `Plus`). `ArrayContract[t, {{1,3}}, Min]` is a tropical
  partial trace. This is the *within-tensor* analog of `Einstoff[Inner][mul, add]`.
- **`Diagonal`** — the keep case (`a a -> a`).

## 7. Design implications for Einstoff

- **Support (the unambiguous core):** repeated-and-**dropped** → **pairwise contraction**,
  lowered via `TensorContract`/`ArrayContract`. Equal-dims already enforced by `unify`.
  Makes the dup-axis check **RHS-only** (LHS repeats become meaningful; RHS repeats stay
  rejected — matching numpy/einops).
- **Generalize for free:** because `ArrayContract` takes an arbitrary head, a
  combiner-parametric within-tensor contraction mirrors `Einstoff[Inner][mul, add]`
  exactly — `Tr[_, add]` / `ArrayContract[_, _, add]` is the within-tensor sibling of the
  cross-tensor `Inner`.
- **Defer:** diagonal-**keep** (`a a -> a`) — a distinct (`Diagonal`) operation with
  transpose handling for non-adjacent slots.
- **Reject (at least initially):** output-repeats (already); `>2` same-name
  super-diagonals (non-tensorial — like `EinsteinSummation`); and the
  bracket/composite/direct-sum interactions of §5.
- **Operator placement:** make self-contraction a shared pre-step (contract each
  operand's repeated slots, then the existing pairwise Dot fold), so a 1-tensor trace and
  mixed within+cross-tensor einsum both fall out without special-casing `Dot`'s ≥2 guard.
- **Cross-validation oracle:** `einops.einsum` / `np.einsum` for the `Times/Plus` case;
  native WL (`TensorContract`/`Tr`/`Inner`) for generalized combiners.

### Note for the future public documentation

User-facing docs should: (a) present contraction as **pairwise index coupling** (one
repeated name = couple two slots), with Ricci-style examples; (b) explicitly distinguish
this from numpy's permissive `>2` super-diagonal and label the latter as non-tensorial;
(c) state that `Gravifer`Einstoff` operates at the **array** level and does **not** track
co/contravariance — placing indices in the right slots (raising/lowering with a metric)
is the user's responsibility, exactly as in `numpy.einsum`.
