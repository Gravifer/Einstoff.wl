# Project tracking

Adopted 2026-09-26. [Einstoff / Development](https://github.com/users/Gravifer/projects/12)
is the shared work tracker. GitHub owns issue status and planning; Codeberg remains
a repository mirror. Design and evidence stay in the repository.

## Stable entry points

- [Work board](https://github.com/users/Gravifer/projects/12/views/1)
- [Milestones view](https://github.com/users/Gravifer/projects/12/views/2)
- [Completed work](https://github.com/users/Gravifer/projects/12/views/3)
- [Correctness hardening milestone](https://github.com/Gravifer/Einstoff.wl/milestone/1)
- [Releases](https://github.com/Gravifer/Einstoff.wl/releases)

The board should make the current outcome, next action, and needed decision clear
without a conversation recap. Its setup uses Status and Priority, with no estimates,
iterations, or speculative deadlines.

## Information ownership

| Location | Owns |
| --- | --- |
| Issue | Problem, acceptance criteria, evidence, decisions, and next action |
| Project | Status, priority, ordering, and views of the issues |
| Milestone | A bounded commitment and its exit criteria |
| PR | Implementation, review, and validation at a particular commit |
| SPEC and design notes | Language semantics, constraints, and rationale |
| Tests, benchmarks, compatibility docs | Reproducible evidence and supported contracts |
| README and release records | Supported entry points and published versions |

The operating workflow is in [CONTRIBUTING](../CONTRIBUTING.md#tracking-work),
with agent handoff requirements in [AGENTS.md](../AGENTS.md#work-tracking).
Do not maintain a second live task list in Markdown or a second issue tracker.

## Initial issue index

This index records the setup, not current status. Follow the issue or board links
for progress. The five correctness findings were reproduced on 2026-09-05 with
Wolfram Language 15.0 at `cd597cef4b79d54b5d8e2510bb50686158163beb`; filing them
did not constitute a new test run.

| Issue | Outcome |
| --- | --- |
| [#20](https://github.com/Gravifer/Einstoff.wl/issues/20) | Preserve distinct equal-sized targeted literal occurrences |
| [#21](https://github.com/Gravifer/Einstoff.wl/issues/21) | Validate input and function-result shapes before recomposition |
| [#22](https://github.com/Gravifer/Einstoff.wl/issues/22) | Apply reduction targeting policy to literals |
| [#23](https://github.com/Gravifer/Einstoff.wl/issues/23) | Preserve inherited targeting on products |
| [#24](https://github.com/Gravifer/Einstoff.wl/issues/24) | Correct complex variance and standard deviation recipes |
| [#25](https://github.com/Gravifer/Einstoff.wl/issues/25) | Investigate the Python test-runner exit after passing results |
| [#26](https://github.com/Gravifer/Einstoff.wl/issues/26) | Establish baselines and choose a safe plan-reuse contract |
| [#8](https://github.com/Gravifer/Einstoff.wl/issues/8) | Complete a bounded first documentation pass |
| [#9](https://github.com/Gravifer/Einstoff.wl/issues/9) | Record evidence for the minimum supported Wolfram version |

The first milestone contains #20-#24. Performance implementation remains subject
to the contract and measurements established in #26. Scope a later milestone when
its outcome is understood. A release gets a separate issue specifying its version,
publication channels, validation, and availability checks.

## Reference projects

Use [einx](https://github.com/fferflo/einx) as a reference for expressive targeting,
composition, staged inference, and graph compilation, and
[einops](https://github.com/arogozhnikov/einops) for compact cached recipes and
explicit operator boundaries. Relevant issues identify whether Einstoff intends
agreement or a deliberate difference. The review used einx 0.4.3, einops 0.8.2, and
NumPy 2.5.0; record actual reference versions when reproducing behavior.

Wolfram evaluation hygiene, whole-LHS binding, inert IR, and generalized `Inner`
semantics remain Einstoff contracts. Output-only broadcasting is common to
applicable operators; there is no separate repeat operator. Positive dimensions
and deferred syntax sugar remain intentional boundaries. Benchmark against native
WL before drawing conclusions from NumPy view timings.

## Board maintenance

Use native Project workflows to add open repository issues to Backlog and to move
closed issues to Done. Keep status-to-issue closure disabled. Reassess Status when
reopening an issue, and explicitly move reviewable work to In review. The Work
board hides issues closed as not planned; Completed shows the completed closure
reason. Keep completed cards visible until archiving becomes useful.

One card normally represents one issue outcome; its linked PR is implementation
evidence. Small incidental fixes may use a PR without manufacturing an issue.
Only independently discussable, schedulable, or dependent work needs a sub-issue.
Use native issue dependencies for actual prerequisites, and explain external
blockers in the issue. Preferred ordering alone is not a dependency.

Use High, Normal, and Low priorities. Reuse existing labels and add a label only
when it supports a useful filter; do not duplicate Status or Priority in labels.
Avoid counting both a fix issue and its PR in the same milestone. Completion
percentages count items, not remaining effort.
