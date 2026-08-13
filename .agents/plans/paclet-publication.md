# Gravifer/Einstoff publication plan

## Fixed release decisions

- Publish paclet version `0.2.0` as `"Gravifer/Einstoff"`.
- Use public context ``Gravifer`Einstoff` `` and keep only `Einstoff` public.
- Make a clean namespace break; do not ship an ``Einstoff` `` compatibility context.
- Require Wolfram Language 15.0 for the first repository release.
- Keep GPL-3.0-or-later and the current intentionally supported feature set.
- Prepare `ResourceDefinition.nb` as the future PacletCICD configuration, without
  adding hosted CI before publication.

## Work sequence

1. Migrate the paclet, source, tests and documentation to the publisher-qualified
   name and context.  Move parser/shape helpers and concrete operator entrances to
   package scope while preserving their white-box tests.
2. Reconcile public documentation and design notes with the implemented release.
   Add one native reference page for `Einstoff`, a main guide page and the English
   documentation extension.
3. Build and install the paclet in an isolated location.  Run the Wolfram suite
   against source and installed artifacts, require all Python cross-validation tests
   to execute, and check clean loading, symbol leakage, tracing and benchmarks.
4. After the `Gravifer` Publisher ID is approved, create the official paclet resource
   definition notebook, complete metadata and disclosures, clear Check All and local
   PacletCICD checks, visually inspect the generated pages, and submit.
5. Once the paclet is publicly installable, submit a thin
   `ResourceFunction["Einstoff"]` facade that installs, loads and forwards to it.

## Release gates

- The source and installed-paclet Wolfram suites pass in full.
- All 63 Python cross-validation tests execute and pass; zero executed tests fails.
- `Needs["Gravifer`Einstoff`"]` exposes only `Einstoff` and creates no old
  ``Einstoff` `` symbols.
- Native reference and guide links resolve from an installed archive.
- The archive excludes tests, agent material, notebooks, virtual environments and
  stale build output.
- Resource definition and PacletCICD checks have no errors, and all warnings have
  been reviewed before submission.

## Deferred, non-blocking features

Indexing/gather-scatter, ambiguous multiple anonymous sequences, diagonal extraction,
super-diagonals, mixed within/cross contraction and the remaining structured
sequence/direct-sum combinations remain explicit unsupported cases for `0.2.0`.
