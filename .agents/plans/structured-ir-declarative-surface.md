# Structured IR and Declarative Surface

## Objective

Re-architect Einstoff as a staged compiler while preserving its Wolfram Language
surface semantics:

```text
held WL description
  -> controlled surface capture
  -> normalized inert IR
  -> constraints and shape solution
  -> operator analysis
  -> execution plan
  -> execution or held rendering
```

Native WL patterns remain the user's mental model.  After surface capture, neither
the kernel pattern matcher nor rule evaluation is authoritative.  Public operator
signatures, public shape-result associations, and the exposed
`"Targeting" -> False | Automatic | True` option remain compatible.

The migration adds two-argument inline axis-size forms using `Annotation` and
`Labeled`, replaces temporary-symbol identities with operation-local integer-backed
IR identities, and eventually makes immediate execution and `TraceAction` consume
one execution plan.

## Non-negotiable surface semantics

### The whole LHS is one binding scope

This rule is easy to misread and must remain prominent in the spec, implementation
comments, and regression tests:

- `a_` on the LHS binds/infer-checks logical axis `a`.
- Every repeated LHS occurrence `a_` denotes the same logical axis and must have the
  same size.
- Bare `a` on the LHS is always an ambient expression/capture.  It does **not** become
  a localized reference because another LHS occurrence used `a_`.
- Bare `a` on the RHS references the completed whole-LHS binding when the LHS contains
  a binder `a_` or an explicit sized declaration for `a`.
- Without such a declaration, bare RHS `a` follows ambient-capture semantics.
- A blank is not replaced by a bare reference in a later LHS position.  Shared and
  repeated inferred axes use repeated blanks.

Canonical examples:

```wl
{{a_, a_}} :> {{a}}  (* two equal inferred dimensions, one RHS reference *)
{{a, a}} :> {{a}}    (* no LHS binder; bare occurrences are ambient *)
{{a_, a}} :> {{a}}   (* one binder plus one unrelated ambient LHS expression *)
```

The parser must collect all LHS binders before resolving RHS references.  It must not
interpret LHS terms sequentially or localize a bare LHS symbol by textual name.

### Relationship to native WL patterns

Einstoff surface patterns are a structural constraint language modeled on WL
patterns:

- `Pattern`, `Blank`, `BlankSequence`, `BlankNullSequence`, `Repeated`, products, and
  sums retain recognizable structural meanings.
- They compile to constraints over logical axis identities and shape structures rather
  than being applied directly to numeric shape lists.
- Inner binders in a repeated group are lifted pointwise across repetitions.  This is
  the documented divergence from native `Repeated`, whose named binders normally share
  one binding.
- For example, `(2 ⊗ a_)..` applies the same product schema to every captured member:
  each matching dimension is even, while the inferred `a` size may differ by member.
- No post-capture stage may use `MatchQ` or native pattern-variable binding to define
  semantics.

### `RuleDelayed`, `Rule`, and the RHS

- `RuleDelayed` is canonical.  It protects the RHS during construction and expresses
  that RHS references are resolved only after matching the complete LHS.
- The compiler parses the held RHS.  It never releases the rule to obtain substitutions
  or output derivations.
- `Rule` remains best-effort compatibility input and retains its warning.  It is not
  equivalent to `RuleDelayed`: its RHS may already have evaluated before Einstoff sees
  it.
- The RHS must normalize into the shape grammar plus a finite declarative sequence
  algebra: sequence reference, projection, zip, repetition, and composition.
- Existing postfix sequence projections compile into those nodes.
- Arbitrary RHS `Map`, `MapThread`, callbacks, and other WL computation are rejected
  with a structured diagnostic naming the held fragment.
- User code remains valid only in explicit operator parameters: reducers, map/operate
  functions, and `Inner` combiners.

### Permanent capture policies

Validate these once during capture and carry only their normalized consequences:

- Symbol and string spelling for one axis name may not be mixed.
- Symbol contexts do not contribute to logical axis identity.
- `Slot` targets only string-kind axes.
- `Highlighted` and `Framed` may target symbol- or string-kind axes.
- Target-head compatibility for explicit binding spellings remains a surface rule.
- Ambient capture remains supported but must terminate at normalization.
- Evaluated or unrecognized binding candidates may warn and be omitted; malformed
  attempts to bind a recognized axis remain errors.

Update package prose from "native pattern objects as the AST" to "native pattern
objects as surface notation compiled into an internal AST."

## Inline axis-size grammar

### Accepted forms

Accept exactly the two-argument forms:

```wl
Annotation[axisSpec, size]
Labeled[size, axisSpec]
```

They are valid on both sides of a description and contribute both an unwrapped axis
occurrence and an inline size constraint.  On the LHS, a sized bare/string axis is an
explicit declaration rather than an ambient capture and is available to RHS references.

```wl
{{Annotation[a, 3]}} :> {{a}}
{{Labeled[3, a]}} :> {{a}}
{{a_}} :> {{a, Annotation[c, 3]}}
{{a_}} :> {{a, Labeled[3, c]}}
```

`axisSpec` may be a bare symbol, hygienic string, blank binder, or one of those under a
valid `Slot`, `Highlighted`, or `Framed` target.  It may not be an integer, anonymous
axis/sequence, product, direct sum, or repeated group.

The size expression must resolve during controlled capture to a positive integer.
Unsupported `Annotation` arities and general `Labeled` position/list forms are outside
the grammar and reject.  Einstoff borrows these intuitive wrappers, not their complete
graphics protocols.

### Sized blanks

```wl
Annotation[a_, 3]
Labeled[3, a_]
```

bind/infer `a` from the tensor and add the equality check `Size[a] == 3`.  They do not
make blanks generally out-of-band-bindable; `a_ -> 3` remains a category error.

### Composition with targeting

Sizing and targeting are orthogonal.  Normalize both nesting orders identically for
`Framed`, `Highlighted`, and valid string `Slot` forms:

```wl
Annotation[Framed[a], 3]
Framed[Annotation[a, 3]]
Labeled[3, Framed[a]]
Framed[Labeled[3, a]]
```

Keep the original nesting only in source metadata for diagnostics and round-tripping.

### Binding facts and merging

Normalize inline and argument bindings to source-provenanced facts keyed by logical
axis identity:

```wl
BindingFact[axisId, size, sourceKind, sourceReference]
```

Merge with these rules:

- Equal facts coalesce regardless of source.
- Conflicting sizes fail; neither source has precedence.
- Equal repeated inline or argument facts coalesce.
- Wrong spelling kind, target-head mismatch, invalid size, and ordinary attempts to
  bind an inference-only blank remain errors.
- Unrecognized/evaluated candidates remain outside the internal environment and follow
  the warning/drop policy.

The solver sees only a merged, recognized, valid binding table.

## Internal representation

### Context and constructor discipline

Place all constructors in `Einstoff`Internal`IR`` and do not add that context to
`$ContextPath`.  Include identity wrappers, stage roots, structural terms, constraints,
analyses, plan steps, failures, and source references.

For normalized and later-stage constructor heads:

- set `Protected`;
- define no `OwnValues`, `DownValues`, `SubValues`, or semantic `UpValues`;
- add no formatting definitions initially;
- add no hold attributes because all payload is sanitized inert data;
- do not `Lock`, so package reload and tests remain practical;
- validate through separate functions rather than constructor evaluation.

Raw syntax is always an explicit `HoldComplete` payload at the surface boundary.

### Local identities

Use integer-backed, operation-local identities:

```wl
Einstoff`Internal`IR`AxisId[1]
Einstoff`Internal`IR`OccurrenceId[1]
```

Allocation uses explicit local state containing name-to-ID and next-ID fields.  It
creates no global symbols or rules and requires no clearing.  Hot solver tables may use
the integer payload directly if profiling warrants it; typed wrappers remain at stage
boundaries.

### Immutable stages

Every stage transformation returns a new root head.  Never mutate one association from
partially parsed through solved or planned states.

#### `SurfaceDesc`

Contains held original description and bindings plus operator identity/options.  It has
no evaluated semantic assumptions.

#### `CapturedDesc`

Contains parsed list-of-shapes structure, the complete LHS binder table, controlled
ambient-capture results, spelling/targeting observations, inline and argument binding
candidates, source paths/held fragments, and capture diagnostics.

Only this stage may inspect raw `Pattern`, `Blank`, `Rule`, `RuleDelayed`, `Slot`,
`Highlighted`, `Framed`, `Annotation`, or `Labeled`.

#### `NormalizedDesc`

Contains inert input/output shapes, axis and occurrence IDs, literals, products, direct
sums, anonymous/named sequences, repeated groups, declarative sequence operations,
target metadata, axis metadata, normalized binding facts, and source map.

Occurrence syntax roles distinguish LHS binder, LHS ambient result, RHS reference,
explicit sized declaration, and anonymous/literal occurrence.  Targeting is per
occurrence, never part of axis identity.

Invariants:

- no raw user symbol is a semantic identity;
- no surface pattern/presentation wrapper remains;
- ambient evaluation is impossible;
- spelling and wrapper grammar are already validated;
- every localized RHS reference resolves to a whole-LHS binder or explicit declaration;
- every retained binding fact references a known axis.

#### `ConstraintDesc`

Contains restricted equality, known-size, tensor-dimension, product, sum, sequence
length, repeated-member, cross-group, and inline-check constraints.  A CAS may solve
the generated positive-integer equations, but CAS query formulation is not language
semantics.

#### `SolvedDesc`

Contains concrete logical shapes, scalar sizes, solved sequences, per-repetition
bindings/projections, direct-sum segment sizes, merged binding provenance, inference
provenance, source references, or a structured failure.  Sequence captures remain
first-class internally even if public `Bindings` exposes only scalars.

#### `OperationAnalysis`

Classifies carried/vectorized, reduced, within/cross-contracted, broadcast, target-block,
direct-sum, and unit-axis effects without executing tensors.

Compile the public targeting option before classification:

```text
False     -> inference-driven; written targets do not constrain selection
Automatic -> infer when absent; exact validation when present
True      -> explicit targets required and validated
```

Retain operation-specific consistency: einx-like kept target correspondence, targeted
disappearance for reduction, and Einstoff's targeted contraction pair plus untargeted
carrier extension.

#### `ExecutionPlan`

Contains backend-neutral reshape, transpose, reduce, self/cross-contract, inner/dot,
target-block operation, broadcast, slice, concatenate, recomposition, and output
assembly steps.  Plan validation requires all referenced sizes, positions, shapes, and
intermediate values to be consistent.

### Structured failures

Use private failure records with stable tag, stage, operator, source reference,
axis/occurrence IDs, display names, expected/actual values, and message parameters.
Public APIs translate them to existing messages and return shapes.  Keep the tagged
throw boundary solely for internal early exit and isolation from user throws; throw the
structured failure rather than bare `$Failed`.

## Migration sequence and commits

Use coherent `codex/*` branches and Conventional Commit messages.  Do not make a branch
per commit.  Branch again when the work changes architectural scope relative to recent
ancestors.

1. `codex/docs/structured-ir-plan`
   - `docs(architecture): record structured IR migration plan`
2. `codex/refactor/structured-ir`
   - `refactor(ir): add inert staged representation`
   - `feat(parser): normalize inline axis size bindings`
   - `refactor(parser): compile descriptions into normalized IR`
   - `refactor(solver): solve explicit shape constraints`
3. Continue on the same refactor branch while parser/solver integration remains one
   scope:
   - `refactor(analysis): classify operator effects from solved descriptions`
   - `refactor(lowering): emit backend-neutral execution plans`
   - `refactor(executor): execute and render shared plans`
4. If plan execution becomes independently reviewable after several parser/solver
   commits, branch at that boundary as `codex/refactor/execution-plan` rather than
   mixing unrelated executor work into the earlier branch.
5. Finish with focused test/docs commits; do not hide behavior changes inside broad
   refactor commits.

### Foundation

Add IR constructors, validators, walkers, source-map helpers, and local interning.
Write invariant tests before routing public APIs through it.

### Capture and normalization

Replace the overlapping `descParts`/`parseDesc` interpretation with one held capture and
normalization entry.  Supply compatibility projections for existing consumers and
public `EinstoffParse`.  Dual-run old/new paths in tests until parity, then remove
temporary-symbol semantic identity and dynamic axis-scope/de-canonicalization state.

### Constraint solving

Generate explicit constraints for scalar/repeated binders, captures, composites, direct
sums, ellipses, and repeated groups.  Accept multiple anonymous-sequence decompositions
only when the solution is unique.  Project `EinstoffMatch` and `EinstoffShapes` from one
solver so operators no longer call both.

### Operator analysis and planning

Define private declarative capability specifications for arity, structural effects,
targeting, repeated inputs, direct sums, contraction/reduction, broadcasting,
shape-preservation, and user-function contracts.  Represent `Massage`, `ArrayReshape`,
and `ArrayContract` as policies, never plan step names.

Extract atom decomposition/output materialization into planning.  Implement one native
WL executor and one held renderer over the same plan.  Remove parallel immediate/held
lowering only after value, shape, evaluation-count, throw-isolation, scalar, and
singleton parity.

Migrate operators in this order:

1. reshape/massage/within-tensor contract;
2. reduce;
3. map/operate;
4. dot/inner;
5. direct-sum join/split;
6. einsum dispatch.

## Verification and acceptance

### Binder regressions

Test the canonical whole-LHS examples under unbound values, `Block`, different symbol
contexts with the same `SymbolName`, and string axes.  Assert bare LHS symbols are never
localized and RHS references arise only from complete-LHS binders or explicit sized
declarations.

### Rule and RHS staging

Test canonical delayed rules, harmless/corrupted immediate rules, absence of internal
RHS execution, rejection of arbitrary derivation, and equivalent declarative sequence
projection.

### Inline binding matrix

Cover both wrappers on both sides, symbol/string/blank axes, both target/sizing nesting
orders, every target head, sized-blank equality, output broadcasting, equal coalescing,
conflicts, spelling/head mismatch, invalid sizes, invalid keys, and unsupported wrapper
forms.

### IR invariants

Assert contexts/attributes, absence of constructor semantic values and temporary axis
symbols, deterministic local IDs, no raw surface nodes after normalization, no global
cleanup requirement, source recovery, and distinct immutable stage roots.

### Solver, analysis, and plan parity

Keep existing public assertions and add internal solved/classification assertions.
Test unique/ambiguous anonymous sequences and positive-integer constraints.  Compare
legacy execution, plan execution, and rendered-plan evaluation for value, dimensions,
broadcast/target orientation, contraction/reduction positions, direct-sum order,
multi-output order, and diagnostic category.

All existing Wolfram tests must remain green.  Python einx/einops cross-validation may
show only explicitly documented Einstoff extensions.  Respect the five-attempt Windows
Python/ZMQ failure ceiling from the repository instructions.

### Performance

Benchmark simple reshape, composite reshape, long ellipsis, multi-operand dot, direct
sum, and repeated compilation.  Require no global-symbol growth and no material
identity-wrapper regression; use integer payloads directly in hot tables if needed.

## Fixed decisions

- No public IR API is added.
- Existing operator signatures and public shape associations remain compatible.
- `RuleDelayed` is canonical; `Rule` remains warned best-effort compatibility.
- Ambient capture remains surface behavior and ends at normalization.
- No-mishmash remains permanent.
- Bare LHS symbols are never localized references.
- Inline sizing works on both LHS and RHS.
- Sized blanks are inference-plus-equality checks.
- Targeting and sizing wrappers commute in both nesting orders.
- Equal binding facts coalesce; conflicts reject.
- Only two-argument `Annotation` and `Labeled` forms are adopted.
- Identities are local integer-backed objects in `Einstoff`Internal`IR``.
- IR heads are inert, protected, definition-free constructors.
- Stage objects are immutable and type-distinct.
- One execution plan drives immediate execution and tracing.
