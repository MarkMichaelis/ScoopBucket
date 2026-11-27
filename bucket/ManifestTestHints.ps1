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
    #     Config*, AddLocalRepoBucket, AddMarkMichaelisScoopBucket).
    #   * Manifests whose only signal is "scoop reports it installed" — they
    #     pick up the default Verify='Scoop' behaviour without an entry.

    # --- Cluster A: Test-Command '<cli>' ----------------------------------
    Aspire                     = @{ Verify = 'Cli'; Cli = 'aspire' }
    DbxCli                     = @{ Verify = 'Cli'; Cli = 'dbxcli' }
    PowerShellCore             = @{ Verify = 'Cli'; Cli = 'pwsh' }
    Chocolatey                 = @{ Verify = 'Cli'; Cli = 'choco' }

    # --- Cluster B: Get-Program '*pattern*' --------------------------------
    SmugMug                    = @{ Verify = 'GetProgram'; Pattern = '*SmugMug*' }
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
    RemapShiftLockToWindowsKey = @{ Verify = 'Custom'; Script = {
                                        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
                                        $value = (Get-ItemProperty -Path $key -Name 'Scancode Map' -ErrorAction Ignore).'Scancode Map'
                                        [bool]$value
                                    } }

    # --- PowerShell modules ------------------------------------------------
    # (PSCompletions hint removed in #241 along with the PSCompletions.ps1 bundle.)

    # --- Manual / heavyweight installs -------------------------------------
    ChatGPT                    = @{ Verify = 'Custom'; Manual = $true
                                    Script = { [bool](Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue) }
                                    Reason = "ChatGPT.ps1 installs Microsoft Store product 9PLM9XGG6VKS (Appx package OpenAI.Codex) through winget's msstore source, which hosted Windows Server runners cannot reach. Not ChatGPT Classic's OpenAI.ChatGPT-Desktop (#511)." }
    Gemini                     = @{ Verify = 'Custom'
                                    Script = { $null = winget list --id Google.GeminiDesktop --exact --accept-source-agreements 2>$null; $LASTEXITCODE -eq 0 }
                                    Reason = "Gemini.ps1 installs Google's Gemini desktop app from winget (Google.GeminiDesktop, user-scope nullsoft). Not the Google app for desktop it installed before #534." }
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
    WSLUbuntu                  = @{ Verify = 'Custom'; Manual = $true; PreserveIfInstalled = $true
                                    Script = {
                                        # `wsl --list --quiet` emits UTF-16; drop the NULs so -match
                                        # operates on plain text.
                                        $distros = ((& wsl.exe --list --quiet 2>$null) | Out-String) -replace "`0", ''
                                        [bool]($distros -match 'Ubuntu-24\.04')
                                    }
                                    Reason = "Uninstalling a WSL distro is destructive; if already installed, skip the install assertion (idempotency check still validates re-run)." }

    # --- Git set-up items (#563) -------------------------------------------
    GitSshAgent                = @{ Verify = 'Custom'; Script = { (Get-Service ssh-agent -ErrorAction SilentlyContinue).StartType -ne 'Disabled' } }
    GitGlobalSettings          = @{ Verify = 'Custom'; Script = { (git config --global --get core.autocrlf) -eq 'input' } }
    GitDebugDiffTools          = @{ Verify = 'Custom'; Script = { [bool](git config --global --get difftool.debug-powershell.cmd) } }
    GitCommitIdentity          = @{ Verify = 'Custom'; Script = { [bool](git config --global --get user.email) } }
    PoshGit                    = @{ Verify = 'Custom'; Script = { [bool](Get-Module -ListAvailable -Name posh-git) } }
    GitLinkSshToData           = @{ Verify = 'Scoop'; Manual = $true
                                    Reason = "Links ~\.ssh to the synced Data folder when ~\.ssh does not exist yet; run it only on a machine meant to share its SSH keys." }
}
