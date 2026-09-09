# CLAUDE.project.md

Claude-specific orientation for **ScoopBucket**. Owned by this project; never
overwritten by `Pull-SDLC.ai.ps1`.

The full project conventions live in
[`.github/instructions/project.instructions.md`](./.github/instructions/project.instructions.md)
— read it. This file carries only the points Claude Code needs up front.

## PR review: an Anthropic model, not Copilot

This project replaces the upstream dev loop's `@copilot` review step. Do **not**
run `gh pr edit <pr-number> --add-reviewer "@copilot"`.

Review every PR with an Anthropic model **other than the one that wrote the
code**, using the `Agent` tool with an explicit `model` override:

1. Read the authoring model from the `Co-Authored-By:` trailer on the branch's
   commits.
2. Spawn a review subagent naming a *different* Anthropic model — code written
   by Opus 5 gets reviewed by Sonnet 5, and vice versa.
3. Brief it with the diff (`git diff main...HEAD`), the linked issue, the sibling
   files establishing the pattern being followed, and any behavior already
   verified by hand, so it spends effort on uncovered paths.
4. Loop as the upstream loop does on Copilot threads — fix, push, re-review —
   until a review introduces zero new findings. Surface the findings to the user;
   a subagent's findings are not automatically correct.

This is the one case in this repo where spawning a subagent is expected rather
than avoided.

## Testing: a green PR check is not verification

The PR gate (`test.yml`) runs only the `Light` Pester tag. `Heavy` tests do run in
CI — but in `validate-installs.yml`, which fires on push to `main`, i.e. *after*
merge, and only over five named test files. So a new manifest's `Heavy` /
`Install` tests, where `Install-LocalManifest` coverage lives, have no CI coverage
at all. Run them locally before merging anything that touches a manifest or an
installer script:

```powershell
.\bucket\Invoke-Tests.ps1                      # Light -- pre-push gate
.\bucket\Invoke-Tests.ps1 -Tag Heavy,Install   # real installs; local only
.\bucket\Invoke-Tests.ps1 -Pattern <Name> -Tag All
```

There is no compile step in this repo — ignore `CLAUDE.md`'s `dotnet build` /
`dotnet test` commands, which are generic upstream boilerplate.

## Every script must be twice-runnable

See the idempotency contract in `README.md`. Run any new or changed script twice
locally before pushing.

## Manifest changes require a version bump

Changing a `bucket/**/*.ps1` requires bumping `version` in every manifest whose
`url` list ships it, bundles included. `.\Test-ManifestVersionBumps.ps1` enforces
this and CI fails without it.
