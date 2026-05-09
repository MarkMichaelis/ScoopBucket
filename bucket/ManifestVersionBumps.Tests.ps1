# ----------------------------------------------------------------------------
# Manifest version-bump rule tests (Pester v5).
#
# Belt-and-suspenders for the CI verify-versions gate. Iterates every
# bucket/*.json with `installer.script` set and asserts that the helper
# (../Test-ManifestVersionBumps.ps1) reports no violations.
#
# This test runs AFTER the CI gate has applied any auto-fix, so it should
# always pass on a properly maintained branch. A failure here means the
# auto-fix pipeline didn't run (e.g. on a fork PR) — the failure message
# points at -Fix.
# ----------------------------------------------------------------------------

Describe 'Manifest version-bump rule' -Tag 'Light','Meta' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:helper   = Join-Path $script:repoRoot 'Test-ManifestVersionBumps.ps1'
        $script:helper | Should -Exist
    }

    It 'reports no violations across all bundle manifests' {
        $output = & pwsh -NoProfile -File $script:helper 2>&1
        $exit   = $LASTEXITCODE
        if ($exit -ne 0) {
            $msg = @(
                "Manifest version-bump check failed. Output:",
                ($output | Out-String),
                "",
                "Re-run with -Fix to auto-correct, or enable the opt-in pre-push hook:",
                "    pwsh -NoProfile -File ./Test-ManifestVersionBumps.ps1 -Fix",
                "    git config core.hooksPath .githooks"
            ) -join [Environment]::NewLine
            throw $msg
        }
        $exit | Should -Be 0
    }
}
