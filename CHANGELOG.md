# Changelog

All notable changes to Einstoff will be recorded here.

This project is pre-release, so interfaces may still change before `1.0.0`.

## Unreleased

### Fixed

- Wait for GitHub's automatically generated immutable-release attestation to
  propagate before failing release and asset verification.

## 0.2.1-beta.1 - 2026-08-28

### Added

- Added a provisional, auditable compatibility build that mechanically lowers the
  canonical Wolfram 15 structured-package vocabulary into legacy SPF staging sources.
- Added a manual, sequential historical-engine workflow with structured reports for
  Wolfram Engine 15.0, 14.1, 13.2 and 13.0.
- Added unified stable-release publication to GitHub and the Wolfram Paclet Repository,
  with prereleases remaining GitHub-only.

### Changed

- Lowered the declared minimum Wolfram Language version to `13.0+` after the same
  generated archive passed all 558 tests and 9 smoke checks on every historical gate.
- Pointed authoritative project metadata at the GitHub repository now that the former
  Codeberg mirror is private and no longer maintained as a synchronized remote.

### Fixed

- Hardened compatibility staging against ambiguous declarations, unsafe trees,
  nonportable path collisions and incomplete generated fragment sets.
- Hardened release and historical validation around immutable inputs, secret scope,
  container mounts, structured completion reports and stop-on-first-failure behavior.

## 0.2.0 - 2026-08-15

### Changed

- Completed and synchronized the first-submission metadata, and added a supported
  non-submitting Paclet Repository preflight.

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
