$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\MarkMichaelis.ScoopBucket\MarkMichaelis.ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module MarkMichaelis.ScoopBucket -Force }

# Microsoft 365 baseline: Office ProPlus + Teams + any Office Web Add-ins.
# Claude for Excel lives here (not AIAgents) because it is delivered through
# Microsoft AppSource as an Excel-only Office Web Add-in: removing Office
# from the box also removes the add-in, so its lifecycle is tied to Office
# rather than to the agent surface.

$Packages = [Package[]]@(
    [Package]@{
        Name      = 'Microsoft 365 Apps for Enterprise'
        Installer = 'choco'
        Id        = 'Office365ProPlus'
        CISkip    = 'Requires GUI session and license activation (choco exit 17004); skipped in CI.'
        Notes     = 'Choco package is the only unattended path; winget Office IDs require an interactive sign-in.'
    }
    [Package]@{
        Name      = 'Microsoft Teams'
        Installer = 'choco'
        Id        = 'Microsoft-Teams'
        DependsOn = @('Microsoft 365 Apps for Enterprise')
    }
    [Package]@{
        Name        = 'Claude for Excel'
        Installer   = 'custom'
        DependsOn   = @('Microsoft 365 Apps for Enterprise')
        Notes       = 'Office Web Add-in distributed exclusively via Microsoft AppSource (asset id WA200010001). No winget/choco/msstore path exists; install requires a one-time browser click. Detection scans HKCU\Software\Microsoft\Office\16.0\WEF\* for the Anthropic publisher.'
        CustomInstallScript = {
            param($pkg)
            $landing  = 'https://claude.com/claude-for-excel'
            $wefRoot  = 'HKCU:\Software\Microsoft\Office\16.0\WEF'

            function Test-ClaudeExcelInstalled {
                if (-not (Test-Path $wefRoot)) { return $false }
                $needles = @('Claude for Excel','Anthropic')
                $hit = Get-ChildItem -Path $wefRoot -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $key = $_
                        try { $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop } catch { return }
                        foreach ($prop in $props.PSObject.Properties) {
                            if ($prop.Name -like 'PS*') { continue }
                            $val = [string]$prop.Value
                            foreach ($n in $needles) {
                                if ($val -like "*$n*" -or $key.Name -like "*$n*") { return $true }
                            }
                        }
                    } | Where-Object { $_ }
                return [bool]$hit
            }

            if (Test-ClaudeExcelInstalled) {
                Write-Host '  Claude for Excel already registered in the Office WEF registry; skipping.'
                return
            }

            Write-Host '  Opening AppSource landing page; complete the "Get it now" flow in Excel.'
            try { Start-Process $landing | Out-Null } catch {
                Write-Warning "  Could not auto-open the browser: $($_.Exception.Message). Visit $landing manually."
            }

            $deadline = (Get-Date).AddSeconds(300)
            while ((Get-Date) -lt $deadline) {
                if (Test-ClaudeExcelInstalled) {
                    Write-Host '  Claude for Excel detected in the Office WEF registry.'
                    return
                }
                Start-Sleep -Seconds 5
            }
            Write-Warning "  Claude for Excel not detected within 5 minutes. A fresh Excel launch may be required for the registry to update."
        }
        VerifyScript = {
            $wefRoot = 'HKCU:\Software\Microsoft\Office\16.0\WEF'
            if (-not (Test-Path $wefRoot)) { return $false }
            $needles = @('Claude for Excel','Anthropic')
            $hit = Get-ChildItem -Path $wefRoot -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $key = $_
                    try { $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop } catch { return }
                    foreach ($prop in $props.PSObject.Properties) {
                        if ($prop.Name -like 'PS*') { continue }
                        $val = [string]$prop.Value
                        foreach ($n in $needles) {
                            if ($val -like "*$n*" -or $key.Name -like "*$n*") { return $true }
                        }
                    }
                } | Where-Object { $_ }
            return [bool]$hit
        }
    }
)

Invoke-PackageInstall -Packages $Packages -Bundle 'MicrosoftOffice365'

# OneDrive tenant-redirection policy. Tied to Office, not a package, so it
# runs after the package pass instead of being modelled as a Package entry.
Function Get-Office365TenantId {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)][string]$TenantName
    )
    Invoke-RestMethod -Uri "https://login.windows.net/$TenantName.onmicrosoft.com/.well-known/openid-configuration" -UseBasicParsing | `
        Select-Object 'token_endpoint' | Where-Object {
            $_ -match 'https://login.windows.net/(?<TenantId>.+)/oauth2/token'
        } | ForEach-Object { [PSCustomObject]$matches } | Select-Object TenantId
}

Function Set-OneDriveConfig {
    if (-not (Test-Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive')) {
        New-Item -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive' | Out-Null
    }
    if (-not (Test-Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir')) {
        New-Item -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' | Out-Null
    }
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' `
        -Name "$(Get-Office365TenantId 'IntelliTectSP')" -Value 'C:\OneDrive\IntelliTect'
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\DefaultRootDir' `
        -Name "$(Get-Office365TenantId 'Michaelises')"  -Value 'C:\OneDrive\Michaelises'

    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' `
        -Name 'GPOSetUpdateRing' -Value 'dword:00000004'
}

try { Set-OneDriveConfig } catch {
    Write-Warning "Set-OneDriveConfig failed: $($_.Exception.Message)"
}
