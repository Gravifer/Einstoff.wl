# Changelog

All notable changes to Einstoff will be recorded here.

This project is pre-release, so interfaces may still change before `1.0.0`.

## Unreleased

## 0.2.0-alpha.1 - 2026-08-13

### Added

- Added an inert, staged compiler pipeline for surface capture, normalization,
  constraint solving, operation analysis, planning, and execution.
- Added inline positive axis-size declarations with two-argument `Annotation` and
  `Labeled`, including composition with supported targeting wrappers.
- Added native Wolfram reference and guide pages, release-source validation, built
  artifact testing, and migration acceptance benchmarks.

### Changed

- Renamed the paclet to `Gravifer/Einstoff` and the public context to
  ``Gravifer`Einstoff` ``. The legacy ``Einstoff` `` context is not included.
- Made `RuleDelayed` the canonical description form and compile descriptions into
  private logical axis identities instead of using native pattern bindings as the
  semantic representation.
- Unified all operator families behind explicit constraints and backend-neutral
  execution plans, including immediate execution and `TraceAction` rendering.
- Kept whole-LHS binder semantics explicit: blank occurrences bind logical axes,
  bare LHS expressions remain ambient captures, and RHS references resolve only
  after the complete LHS has been captured.

### Fixed

- Standardized structured failure classification across public operators.
- Rejected nondeclarative RHS fallbacks and preserved source provenance in parser,
  solver, and planner diagnostics.
- Made repeated paclet builds independent of stale generated documentation and
  prevented nonfatal build warnings from being reported as total build failures.
- Corrected native documentation layout, usage coverage, built-in symbol links,
  and symbol-page self-links.
