@{
    # Declarative post-install verification hints consumed by
    # ManifestInstall.Tests.ps1. One entry per single-package <name>.json
    # manifest in bucket/ that participates in the data-driven harness.
    #
    # Fields:
    #   Verify              — 'Cli' | 'GetProgram' | 'Choco' | 'Custom' | 'Scoop'
    #                         (defaults to 'Scoop' when the entry is omitted)
    #   Cli                 — bare command name when Verify='Cli'
    #   Pattern             — Get-Program -Filter glob when Verify='GetProgram'
    #   ChocoPackage        — chocolatey package id when Verify='Choco'
    #   Script              — scriptblock returning a truthy value when
    #                         Verify='Custom'. Runs after install + idempotent
    #                         checks.
    #   Manual              — $true to mark the case with the 'Manual' tag
    #                         (excluded from CI Heavy runs)
    #   PreserveIfInstalled — $true to skip the BeforeAll `scoop uninstall`
    #                         step (for heavyweight / destructive packages).
    #                         Also skips the 'installs from the local manifest'
    #                         assertion when the package is already present.
    #   Reason              — free text rationale (carries forward the inline
    #                         comments that lived in the old per-package
    #                         Tests.ps1 files).
    #
    # Manifests intentionally NOT covered by this table:
    #   * Declarative bundles (OSBasePackages, DeveloperBasePackages, etc.) —
    #     exercised by Bundles.Tests.ps1.
    #   * Bespoke manifests with one-off Pester files (McAfeeUninstall, Git
    #     Configure*, AddLocalRepoBucket, AddMarkMichaelisScoopBucket).
    #   * Manifests whose only signal is "scoop reports it installed" — they
    #     pick up the default Verify='Scoop' behaviour without an entry.

    # --- Cluster A: Test-Command '<cli>' ----------------------------------
    Aspire                     = @{ Verify = 'Cli'; Cli = 'aspire' }
    Codex                      = @{ Verify = 'Cli'; Cli = 'codex' }
    DbxCli                     = @{ Verify = 'Cli'; Cli = 'dbxcli' }
    dotnet                     = @{ Verify = 'Cli'; Cli = 'dotnet' }
    PowerShellCore             = @{ Verify = 'Cli'; Cli = 'pwsh' }
    ClaudeCode                 = @{ Verify = 'Cli'; Cli = 'claude' }
    GeminiCli                  = @{ Verify = 'Cli'; Cli = 'gemini' }
    GitHubCopilotCli           = @{ Verify = 'Cli'; Cli = 'copilot' }
    Chocolatey                 = @{ Verify = 'Cli'; Cli = 'choco' }

    # --- Cluster B: Get-Program '*pattern*' --------------------------------
    Claude                     = @{ Verify = 'GetProgram'; Pattern = '*Claude*' }
    SmugMug                    = @{ Verify = 'GetProgram'; Pattern = '*SmugMug*' }
    Overdrive                  = @{ Verify = 'GetProgram'; Pattern = '*OverDrive*' }
    Epubor                     = @{ Verify = 'GetProgram'; Pattern = '*Epubor*' }
    AdobeLightroomClassic      = @{ Verify = 'GetProgram'; Pattern = '*Lightroom*' }

    # --- Cluster C: Chocolatey-package verification ------------------------
    TotalCommander             = @{ Verify = 'Choco'; ChocoPackage = 'TotalCommander'
                                    Reason = "Manifest's installer.script delegates to choco install TotalCommander; the post-install signal is whether choco itself reports the package as installed." }
    PowerShellCorePreview      = @{ Verify = 'Choco'; ChocoPackage = 'PowerShell-Preview'
                                    Reason = "Manifest runs `choco install PowerShell-Preview`. The shipped binary may simply be `pwsh` (a different version), so verify chocolatey package presence rather than a uniquely-named CLI." }

    # --- Cluster D: Custom one-liner verification --------------------------
    EnableHybernate            = @{ Verify = 'Custom'; Script = { ((powercfg /AVAILABLESLEEPSTATES) -join "`n") -match 'Hibernate' } }
    SetPowerConfiguration      = @{ Verify = 'Custom'; Script = { ((powercfg /GETACTIVESCHEME) -join "`n") -match 'Power Scheme GUID' } }
    WindowsPowerShell          = @{ Verify = 'Custom'; Script = { Test-Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
                                    Reason = "Manifest runs `choco install PowerShell` which is a no-op on a normal Windows host. Assert the in-box Windows PowerShell binary exists rather than trying to resolve `powershell` on PATH." }
    RemapShiftLockToWindowsKey = @{ Verify = 'Custom'; Script = {
                                        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
                                        $value = (Get-ItemProperty -Path $key -Name 'Scancode Map' -ErrorAction Ignore).'Scancode Map'
                                        [bool]$value
                                    } }

    # --- PowerShell modules ------------------------------------------------
    PSCompletions              = @{ Verify = 'Custom'; PreserveIfInstalled = $true
                                    Script = { [bool](Get-Module -ListAvailable -Name PSCompletions) }
                                    Reason = "PSGallery module; verification is module discoverability via Get-Module -ListAvailable. PreserveIfInstalled skips a destructive `scoop uninstall` (there is no scoop record to remove) — the harness still validates idempotency on the second invoke." }

    # --- Manual / heavyweight installs -------------------------------------
    ChatGPT                    = @{ Verify = 'Custom'; Manual = $true
                                    Script = { Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT\ChatGPT.exe') }
                                    Reason = "ChatGPT.ps1 uses a browser-watch pattern: it opens the official download page and waits for the user to click 'Download for Windows'. Cannot run unattended in CI." }
    Gemini                     = @{ Verify = 'Custom'
                                    Script = { Test-Path (Join-Path $env:LOCALAPPDATA 'Google\Google\latest\google.exe') }
                                    Reason = "Gemini.ps1 performs a fully automated install via direct download from dl.google.com (~11 MB Omaha installer); falls back to the legacy browser-watch pattern only if that direct fetch fails." }
    ClaudeExcel                = @{ Verify = 'Scoop'; Manual = $true
                                    Reason = "Claude for Excel is an Office Web Add-in that Microsoft only allows installing through AppSource's 'Get it now' UI flow (no winget / MS Store / silent installer). Cannot run unattended in CI." }
    MicrosoftCopilot           = @{ Verify = 'Scoop'
                                    Reason = "Manifest is a no-op: it only emits a Write-Warning noting that the consumer Copilot desktop app is built into Windows 11. No external app to verify; post-install assertion is limited to scoop bookkeeping." }
    VisualStudio2026Enterprise = @{ Verify = 'Custom'; Manual = $true; PreserveIfInstalled = $true
                                    Script = {
                                        $vswhere = Get-Command vswhere -ErrorAction Ignore
                                        if ($vswhere) {
                                            $installations = & vswhere.exe -prerelease -products '*' -property installationPath 2>$null
                                            [bool]($installations | Where-Object { $_ -match '2026' })
                                        } else {
                                            [bool](Get-Program -Filter '*Visual Studio*2026*')
                                        }
                                    }
                                    Reason = "Uninstalling Visual Studio is destructive; if already installed, skip the install assertion (idempotency check still validates re-run)." }
    'WSL-Ubuntu-2004'          = @{ Verify = 'Custom'; Manual = $true; PreserveIfInstalled = $true
                                    Script = {
                                        # `wsl --list --quiet` emits UTF-16; pipe through Out-String so
                                        # -match operates on a single normalized string.
                                        $distros = (& wsl.exe --list --quiet 2>$null) | Out-String
                                        [bool]($distros -match 'Ubuntu-20\.04')
                                    }
                                    Reason = "Uninstalling a WSL distro is destructive; if already installed, skip the install assertion (idempotency check still validates re-run)." }
    'WSL-Ubuntu-1804'          = @{ Verify = 'Custom'; Manual = $true; PreserveIfInstalled = $true
                                    Script = {
                                        $distros = (& wsl.exe --list --quiet 2>$null) | Out-String
                                        [bool]($distros -match 'Ubuntu-18\.04')
                                    }
                                    Reason = "Uninstalling a WSL distro is destructive; if already installed, skip the install assertion (idempotency check still validates re-run)." }
}
