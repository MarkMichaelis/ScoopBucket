---
name: evidence-capture
description: "Produce a runtime artifact for every code change, then use an AI review loop to verify the artifact visibly confirms the change. Markdown for CLI/library/perf, HTML+video for UI. Hard gate -- phase cannot exit until review passes or escalation after 3 iterations."
---

# Evidence Capture

Every code change ships with a **runtime artifact** that visibly demonstrates the
change. The AI then **reviews the artifact** against the original intent and the
code diff, identifies any gap or regression, applies a fix, and re-captures. The
phase exits only when the review reports a clean artifact, or after 3 iterations
when it escalates to the human.

This is empirical verification, not aesthetic decoration. The artifact is the
oracle that confirms the change behaved as intended at runtime.

## When to invoke

- Inside the dev loop, as Phase 5b ("Evidence and Verify"), between Functional
  Testing (Phase 5) and Code Review and Fix (Phase 6).
- Whenever a change has user-visible effects: CLI output, library return shape,
  UI element, performance characteristic.

Pure-internal refactors that change zero observable behavior may produce an
**attestation artifact** (a markdown file declaring "no behavior change" plus
the test-run summary) rather than a runtime capture.

## The inner loop

```
   [Identify change type]
            |
            v
     [Capture artifact] <----------+
            |                      |
            v                      |
     [AI reviews artifact          |
      vs. issue intent + diff]     |
            |                      |
       passes?                     |
        / \                        |
       no  yes                     |
       |    \                      |
       v     \--> [Upload to PR    |
   [Identify        comment]       |
    needed fix]      |             |
       |             v             |
       v        [Phase exit]       |
   [Apply fix] -----+              |
   [iter++ <= 3?] --+              |
       |  no                       |
       v                           |
   [Escalate to human]             |
```

**Hard gate.** The phase does not exit until either the AI review passes or the
iteration limit (3) triggers human escalation. There is no "skip" option.

## Capture by change type

Select the format and tooling from the table below. Format is **markdown** by
default (renders inline in GitHub PR comments, AI-readable) with **HTML + video**
for UI changes that benefit from motion.

| Change type | Artifact | Format | How it's produced |
|---|---|---|---|
| CLI / PowerShell command | Command + output transcript | Markdown (fenced code block) | Re-run the canonical sample command from the issue; capture stdout, stderr, exit code |
| Library / API method | Invocation + request/response | Markdown (fenced code block, optional HAR sidecar) | Generated mini test program or existing functional test, output captured |
| Bug fix | Before vs. after | Markdown (two code blocks) | Run the reproduction step against `HEAD~1` and against `HEAD`; diff |
| New test only | Test name + output | Markdown | Test runner output for the new test |
| Refactor (no behavior change) | Diff summary + "no behavior change" attestation + test run summary | Markdown | Tests-pass summary plus `git diff --stat`; no runtime artifact required |
| Configuration / docs change | Rendered output (e.g., README preview, generated config) | Markdown | Render to file; embed snippet |
| UI change (new button, layout) | Screenshot + 5-15 sec recording | HTML page with `<video>` plus before/after screenshots | Playwright script: navigate to relevant view, perform interaction, `page.video()` plus `page.screenshot()` |
| UI bug fix | Before vs. after recording | HTML with two `<video>` tags | Playwright script run against both commits |
| Performance change | Benchmark output (BDN summary, timing) | Markdown table | Run the relevant benchmark before and after; tabulate |

Generated UI HTML pages are self-contained (inlined CSS, MP4 referenced
relatively) so they render correctly when downloaded as a CI artifact.

## Templates

Reference templates live alongside this skill at
`.github/skills/evidence-capture/templates/`:

- `cli-evidence.md.tmpl` -- CLI/command transcript skeleton
- `perf-evidence.md.tmpl` -- benchmark before/after table
- `ui-evidence.html.tmpl` -- self-contained HTML shell with video and screenshots
- `playwright-capture.js.tmpl` -- generic Playwright script

Copy the relevant template into `.evidence/<phase-id>/` and fill in the
placeholders for the specific change.

## Storage and lifecycle

Evidence is **ephemeral by default**. Committed evidence rots as the app evolves
and is rarely consulted after the PR closes.

1. **During the dev loop**: artifacts are written to `.evidence/<phase-id>/`
   inside the worktree (gitignored). The AI-review loop reads from here.
   Intermediate iterations are overwritten; only the final artifact survives the
   phase exit.
2. **At PR open or update**: the dev-loop agent uploads each artifact via
   `Publish-Evidence.ps1` (wraps `gh pr comment --body-file ... -F <artifact>`).
   Files <= 25 MB render inline in the PR comment.
3. **For artifacts > 25 MB** (long screen recordings): the helper falls back to
   uploading via the CI workflow as a GitHub Actions artifact (default 30-day
   retention); the PR comment includes the actions-artifact URL instead of
   inlining the file.
4. **Cleanup**: `Cleanup-Worktree.ps1` removes `.evidence/` along with the
   worktree. No state outlives the PR.

`.evidence/` must be in the consuming project's `.gitignore` (analogous to
`.playwright-mcp/`).

## AI review semantics

The reviewing AI is given exactly three things:

1. **The issue body or plan section** describing what was supposed to happen.
2. **The code diff** of the current change (`git diff main...HEAD`).
3. **The captured artifact** (markdown, HTML, or linked media).

It answers two questions:

- **A. Does the artifact visibly confirm the intent from (1) given the change
  in (2)?**
- **B. Does the artifact reveal any *new* problem introduced by (2)** -- e.g.,
  extra warnings in the output, layout regression, unexpected slowdown, error
  message wording drift, broken accessibility?

If A = yes and B = no, the phase passes and the artifact is uploaded to the PR.
If either fails, the AI:

1. **Articulates the specific gap** -- missing element, wrong wording,
   regression, missing coverage of the intent. Records the gap in a structured
   diagnosis at the top of the next iteration's artifact directory.
2. **Routes back to the fix step within this phase** -- not back to the dev
   loop's Phase 3 (TDD). The fix is applied, the artifact is re-captured, the
   review re-runs.
3. After **3 failed iterations**, the phase exits with an **escalation note** in
   the plan or issue and yields to the human. The dev loop does **not** proceed
   past this phase automatically.

### Inputs the review must re-read fresh

The review prompt must explicitly re-read:

- The GitHub issue body (live, not cached from earlier in the session).
- The current `git diff` (live, not the diff at the time the change was
  proposed).

This prevents the review from corroborating the same stale context that
authored the change.

## Anti-patterns (forbidden)

- **Self-corroborating evidence.** The AI must not author both the change
  description and the artifact-judging prompt from the same context window
  without grounding in the original issue. The review step re-reads the issue
  file and the live diff fresh.
- **Stale artifacts.** If the code has changed since the artifact was captured,
  the artifact is invalid and must be re-captured. Each artifact directory
  records the SHA of the working tree at capture time
  (`git rev-parse HEAD`).
- **Faked outputs.** The artifact must come from actually running the code, not
  from hand-edited text. The skill mandates a recorded shell invocation or
  Playwright script that anyone can re-run.
- **"It built" is not evidence.** A passing test or a clean build is not, by
  itself, an evidence artifact. The artifact must show the *user-visible
  behavior* the change produced. A `dotnet build` log alone fails this skill.
- **Skipping the phase.** This is a hard gate. The phase has no `--skip` flag.
  If no user-visible effect exists, produce a "no behavior change" attestation;
  do not skip.
- **Reviewing your own code without the artifact.** The review oracle is the
  artifact, not the diff. Reviewing the diff alone defeats the purpose.

## Iteration termination details

The dev-loop agent maintains a counter at `.evidence/<phase-id>/iteration.txt`.
On each capture-review cycle:

1. Increment the counter.
2. Capture the new artifact.
3. Run the review.
4. If review passes, write `.evidence/<phase-id>/PASSED` and exit the phase.
5. If review fails and counter < 3, apply the diagnosed fix and loop.
6. If review fails and counter == 3, write `.evidence/<phase-id>/ESCALATED`
   with the latest diagnosis, post the escalation as a PR comment, and yield to
   the human.

## Integration with Task Complete Summary

Every task-complete summary must include an **Evidence** field whenever
applicable:

```markdown
- **Issue**: [#NNN](https://github.com/owner/repo/issues/NNN)
- **PR**: [#NNN](https://github.com/owner/repo/pull/NNN)
- **Branch**: [`feat/...`](https://github.com/owner/repo/tree/feat/...)
- **Test**: `dotnet test --no-build`
- **Evidence**: [PR comment](https://github.com/owner/repo/pull/NNN#issuecomment-XXX)
```

For files > 25 MB the URL is the GitHub Actions artifact URL.

## Compliance checklist (used by dev-loop-phase-gate)

After invoking this skill, the following must all be true:

- [ ] An artifact exists at `.evidence/<phase-id>/`
- [ ] The artifact directory contains an `iteration.txt` and either a `PASSED`
      marker or an `ESCALATED` marker.
- [ ] If `PASSED`, the artifact was uploaded to the PR (or earmarked for upload
      when the PR is opened).
- [ ] The artifact was produced from a fresh run against the current HEAD SHA.
- [ ] The Task Complete Summary includes an Evidence field.

## Out of scope (deferred)

- **Audio in screen recordings.** UI evidence is silent video by default.
- **Accessibility evidence.** Future addition: pair the visual artifact with an
  axe-core run for UI changes.
- **Diff-against-main automation.** Bug-fix before/after capture currently
  requires the agent to check out `HEAD~1` manually in a side worktree. A
  dedicated `git worktree` helper is a future enhancement.
- **Multi-locale UI capture.** Single-locale capture for now; multi-locale
  diffing is a future enhancement.
