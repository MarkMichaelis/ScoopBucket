# ----------------------------------------------------------------------------
# ClientBasePackages bundle script tests (Pester v5).
#
# Stubs every install engine the bundle touches: `choco`, `scoop`, `winget`,
# `Invoke-WebRequest`, and `Add-AppxPackage`. Verifies cardinality and a
# few sentinel package IDs to catch drift if the bundle's package set
# changes again.
# ----------------------------------------------------------------------------

Describe 'ClientBasePackages bundle' -Tag 'Light','Bundle' {
    BeforeAll {
        $script:sut = Join-Path $PSScriptRoot 'ClientBasePackages.ps1'
        $script:chocoCalls   = @()
        $script:scoopCalls   = @()
        $script:wingetCalls  = @()
        $script:webRequests  = @()
        $script:appxInstalls = @()

        function choco             { $script:chocoCalls   += ,@($args) }
        function scoop             { $script:scoopCalls   += ,@($args) }
        function winget            { $script:wingetCalls  += ,@($args) }
        function Invoke-WebRequest { $script:webRequests  += ,@($args) }
        function Add-AppxPackage   { $script:appxInstalls += ,@($args) }
        # Install-BucketApp lives in Utils.ps1 (stripped below); route it to
        # the production fallback so `scoop install MarkMichaelis/<App>`
        # assertions still hold.
        function Install-BucketApp { param($Name) scoop install "MarkMichaelis/$Name" }

        $script:InvokeBundle = {
            $src = Get-Content -Raw -Path $script:sut
            $src = $src -replace '(?m)^\s*\.\s+"\$PSScriptRoot\\Utils\.ps1".*$',''
            . ([scriptblock]::Create($src))
        }
        & $script:InvokeBundle
    }

    It 'invokes choco install for each chocolatey base package' {
        $script:chocoCalls.Count | Should -Be 2
        $names = $script:chocoCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain 'exiftool'
        $names | Should -Contain 'geosetter'
        ($script:chocoCalls[0] -join ' ') | Should -Match '^install -y '
    }

    It 'invokes scoop install for each MarkMichaelis bundle manifest' {
        $script:scoopCalls.Count | Should -Be 3
        $names = $script:scoopCalls | ForEach-Object { $_[-1] }
        $names | Should -Contain 'MarkMichaelis/ClaudeExcel'
        $names | Should -Contain 'MarkMichaelis/AIAgents'
        $names | Should -Contain 'MarkMichaelis/DbxCli'
        foreach ($call in $script:scoopCalls) {
            $call[0] | Should -Be 'install'
            # Per-user installs (no -g) — Office/AIAgents land in the user
            # profile.
            $call | Should -Not -Contain '-g'
        }
    }

    It 'invokes winget install for the WinGet + msstore package sets' {
        # 16 entries in $WingetPackages + 4 entries in $MicrosoftStorePackages.
        $script:wingetCalls.Count | Should -Be 20
        $invokedIds = $script:wingetCalls | ForEach-Object {
            $idIdx = [array]::IndexOf($_, '--id')
            if ($idIdx -ge 0) { $_[$idIdx + 1] }
        }
        # Sentinel IDs covering both the regular winget block and the msstore
        # block — drift in either set will trip these assertions.
        $invokedIds | Should -Contain 'Bitwarden.Bitwarden'
        $invokedIds | Should -Contain 'Anthropic.Claude'
        $invokedIds | Should -Contain 'Foxit.FoxitReader'
        $invokedIds | Should -Contain 'Zoom.Zoom.EXE'
        $invokedIds | Should -Contain '9NT1R1C2HH7J'   # ChatGPT (msstore)
        $invokedIds | Should -Contain '9NKSQGP7F2NH'   # WhatsApp (msstore)

        # The msstore block uses --source msstore; the regular block uses
        # --scope machine. Make sure both routings showed up.
        $msstoreCalls = $script:wingetCalls | Where-Object { $_ -contains 'msstore' }
        @($msstoreCalls).Count | Should -Be 4
        $machineCalls = $script:wingetCalls | Where-Object { $_ -contains 'machine' }
        @($machineCalls).Count | Should -Be 16
    }

    It 'sideloads the Readwise Reader MSIX' {
        @($script:webRequests).Count  | Should -Be 1
        @($script:appxInstalls).Count | Should -Be 1
        ($script:webRequests[0] -join ' ') | Should -Match 'readwise\.io'
    }

    It 'is idempotent on re-run' {
        $script:chocoCalls   = @()
        $script:scoopCalls   = @()
        $script:wingetCalls  = @()
        $script:webRequests  = @()
        $script:appxInstalls = @()
        { & $script:InvokeBundle } | Should -Not -Throw
        $script:chocoCalls.Count   | Should -Be 2
        $script:scoopCalls.Count   | Should -Be 3
        $script:wingetCalls.Count  | Should -Be 20
        @($script:webRequests).Count  | Should -Be 1
        @($script:appxInstalls).Count | Should -Be 1
    }
}
