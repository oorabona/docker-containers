# GOTCHAS — recurring bug classes (bash / GitHub Actions / CI pipeline)

Stack-scoped bug classes for this project (Bash + GitHub Actions + Docker CI). Code
reviewers (and `senior-code-reviewer`) should search these before a logic pass and treat
each as a checklist item. Most were surfaced by the #595 coverage-checkpoint epic; each
entry states the symptom and the **Prevention**.

> Search: `astix search_semantic(query="<concern> gotcha", project="docker-containers", kind=["heading"])`.

## Partial-observability false recovery / silent drop

Code attributes outcomes from a signal that can be MISSING — a build-result artifact not
uploaded, a job that crashed before its `if: always()` emit step, a `gh`/API call that
failed. If "absence of failure evidence" is read as success, a CLEAR/CLOSE/RECOVER action
fires on incomplete data (false recovery), or a real failure produces no alert.

**Prevention:** RECOVER/CLOSE only on POSITIVE confirmation (an explicit success record),
never on absence-of-negative. Cross-check against an independent completeness signal (e.g.
`count(failed units observed) > count(failure records)` → fail closed / carry-all) before
trusting the present subset. Origin: #595 slice 2 (multi-arch leg failed without a record →
container falsely recovered).

## Signal / exit-code conflation

One value carrying two meanings: exit `1` meaning both "nothing detected" and "operation
failed"; a flag reused across distinct terminal states; a status string a consumer
misinterprets.

**Prevention:** give each distinct outcome a distinct code/value (`0` ok, `1` not-detected,
`2` usage/env, `3` operation-failed). Enumerate EVERY producer and consumer of a status value
and confirm each consumer disambiguates. Origin: #595 slice 3 (`find_or_create_issue`
returned `1` on `gh` failure, colliding with "1 = no dep-bump detected").

## Secondary code-path independence

When a primary gate suppresses action A, a SIBLING mutator on the same event can still run —
a second issue-opener, a parallel job, a cleanup step — because it is not behind the same
gate.

**Prevention:** never assume "the gate suppresses everything." Enumerate every mutator/
side-effect path triggered by the event and trace each independently across ALL state values.
Origin: #595 slice 3 (the dep-attributed open ran on `deferred`/superseded runs even though the
generic open was correctly gated → resurrected an issue a newer run had closed).

## Validation no-op that returns success

A guard that logs-and-`return 0` on invalid input looks like success to a caller using
`cmd || failed=true` → the caller never sets its failure flag → a fallback/downgrade is
suppressed → silent drop.

**Prevention:** invalid input must FAIL CLOSED — return non-zero (or trigger the downgrade
path), never a success code. Origin: #595 slice 3 (invalid `--container` returned 0 →
`issue_open_failed` stayed false → generic backstop suppressed → no alert).

## Large payload passed as a command argument (ARG_MAX)

Passing unbounded data as an argv element — `jq --argjson x "$big"`, `cmd "$big"`,
`foo "$@"` over a huge list — hits the kernel limit: a single arg over ~128 KB
(`MAX_ARG_STRLEN`) or argv+env over ~2 MB (`ARG_MAX`) → `E2BIG` / exit 126
("Argument list too long").

**Prevention:** pipe unbounded data via stdin (`printf '%s' "$big" | jq …`), or slim it at the
source (`gh … --jq 'project only needed fields'`). Origin: #595 slice 1 (789 KB
`gh run view --json jobs` passed via `--argjson` → exit 126, checkpoint never published).

## `set -e` + command substitution = dead recovery branch

Under `set -euo pipefail`, `x=$(cmd); rc=$?; if [ "$rc" -ne 0 ]; then …recover… fi` —
the failing `cmd` aborts the script AT the assignment, BEFORE the rc check runs, so the
recovery branch is unreachable.

**Prevention:** use `if ! x=$(cmd); then …recover… fi`, or wrap the assignment in
`set +e; x=$(cmd); rc=$?; set -e`. Origin: #595 slice 3 (`gh issue list` failure
"recovery" was dead code).

## Glob with `nullglob` off routes to the wrong branch

`jq -s . "$dir"/*/*.json` (or any tool over an unmatched glob) with `nullglob` unset passes
the LITERAL pattern string to the tool → non-empty/garbage output → a presence/empty test
takes the wrong branch (e.g. treats "no files" as "files exist").

**Prevention:** count matches first — `mapfile -t files < <(find "$dir" -type f -name '*.json')`
then branch on `${#files[@]}` — or set `shopt -s nullglob`. Origin: #595 slice 2 (zero
build-result artifacts → glob yielded `"[]\n[]"` ≠ `"[]"` → primary path instead of fallback).

## Concurrent mutation of shared state without compare-and-swap

Force-push / overwrite of a shared ref, tag, row, or file without CAS lets a slower OLDER
run clobber a NEWER run's state (GitHub Actions `cancel-in-progress: false` allows two runs
to reach the same mutation).

**Prevention:** forward-only guard (don't move state backward — verify the current value is an
ancestor/predecessor) + compare-and-swap (`git push --force-with-lease=ref:expected`, conditional
DB update) with a re-read-and-retry loop; mutate dependent side-effects ONLY when this run
actually won the swap (published/owns the state). Origin: #595 slice 1 (coverage checkpoint
tag CAS) + slice 3 (issues mutated only when `published=true`).

## Outcome keyed on a single step vs the job/aggregate status

`result = steps.X.outcome` misses upstream failures: if a step BEFORE X fails, the job
aborts and X is marked `skipped` — which a naive `skipped → success` mapping records as
success.

**Prevention:** derive the outcome from `job.status` (or an aggregate over all required
steps), not one step's `.outcome`. Distinguish "skipped by its own `if:`" (nothing to do) from
"skipped because the job aborted" via `job.status`. Origin: #595 slice 2 (build-result emit
keyed on the build step outcome alone).

## Outward side-effect lifecycle (issues / tags / deploys / files)

For every CREATE of an external entity, ask: is there a guaranteed CLOSE/cleanup path? Can it
be created-but-never-closed (orphan)? Can it be created SPURIOUSLY — attributed by a PROXY
signal (commit message, name token, matrix label) that was never verified against the ACTUAL
failing set?

**Prevention:** trace the full open→close matrix across every terminal state; attribute
side-effects to the VERIFIED state (the precise failed set), not a proxy; ensure every open
has a reachable close. Origin: #595 slice 3 (commit-attributed `dep:<c>` issue opened for a
container that did not fail and was never auto-closed → cross-checked against the checkpoint's
`failed_this_run` allowlist).
