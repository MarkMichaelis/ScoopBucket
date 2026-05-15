
$scoopBucketPsd1 = Join-Path $PSScriptRoot '..\module\ScoopBucket\ScoopBucket.psd1'
if (Test-Path $scoopBucketPsd1) { Import-Module $scoopBucketPsd1 -Force } else { Import-Module ScoopBucket -Force }

# Claude for Excel is an Office Web Add-in (Microsoft 365 only), distributed
# exclusively through Microsoft AppSource as asset id WA200010001 - it has no
# winget / Microsoft Store / Chocolatey entry, no public manifest XML, and no
# direct dl.* URL. Microsoft does not expose a programmatic per-user install
# path for Office Web Add-ins; the only sanctioned routes are:
#   1. the Excel "Get Add-ins" UI (one-click "Get it now" on AppSource)
#   2. M365 admin-center Centralized Deployment (org-wide, requires admin)
#   3. developer sideload via HKCU\Software\Microsoft\Office\16.0\WEF\Developer
#      (requires a local manifest XML which AppSource does not redistribute)
#
# We follow the same browser-prompt pattern AIAgents already uses for non-
# winget surfaces: open the AppSource page, instruct the user to click "Get
# it now", then poll the Office WEF registry to confirm the add-in landed.

# The canonical Anthropic landing page is the source of truth - it forwards
# to AppSource and is updated by Anthropic if Microsoft re-keys the listing
# (which happens; the AppSource asset id is not stable enough to hardcode).
$Script:ClaudeExcelLandingPage  = 'https://claude.com/claude-for-excel'
$Script:ClaudeExcelMarketplace  = 'https://appsource.microsoft.com/en-us/marketplace/apps?search=Claude%20for%20Excel&product=office%3Bexcel'
$Script:ClaudeExcelWefRegRoot   = 'HKCU:\Software\Microsoft\Office\16.0\WEF'

Function Test-ClaudeExcelInstalled {
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    if (-not (Test-Path $Script:ClaudeExcelWefRegRoot)) {
        return $false
    }

    # Office records every installed Web Add-in under WEF\<subkey> with values
    # that include the AppSource asset id (e.g. WA200010001) or the publisher
    # name. A recursive value scan is the most resilient detection: the exact
    # subkey name varies across Office builds (Manifests vs Developer vs
    # OfficeStoreAddins vs newer per-version variants).
    # Detection needs to match the Anthropic add-in regardless of which Microsoft
    # asset id Microsoft is currently using - check publisher and product name.
    $needles = @('Claude for Excel', 'Anthropic')
    $hits = Get-ChildItem -Path $Script:ClaudeExcelWefRegRoot -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $key = $_
            try {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
            } catch { return }
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $val = [string]$prop.Value
                foreach ($needle in $needles) {
                    if ($val -like "*$needle*" -or $key.Name -like "*$needle*") {
                        return $true
                    }
                }
            }
        } |
        Where-Object { $_ }

    return [bool]$hits
}

Function Install-ClaudeExcel {
    Write-Host "Running $($MyInvocation.MyCommand.Name)..."

    if (Test-ClaudeExcelInstalled) {
        Write-Host 'Claude for Excel already installed; skipping.'
        return
    }

    Write-Host ''
    Write-Host 'Claude for Excel is an Office Web Add-in distributed only through'
    Write-Host 'Microsoft AppSource. Microsoft does not provide an unattended install'
    Write-Host 'path for Office Web Add-ins, so a one-time browser click is required.'
    Write-Host ''
    Write-Host "  1. Opening Anthropic's Claude for Excel page: $Script:ClaudeExcelLandingPage"
    Write-Host '     (Click "Get it on Microsoft AppSource" - this redirects to the'
    Write-Host '      official AppSource listing maintained by Anthropic.)'
    Write-Host '  2. Click "Get it now" on AppSource and follow the Excel prompts.'
    Write-Host '  3. (Optional) Sign in with your Claude account inside Excel.'
    Write-Host "     Alternative AppSource search: $Script:ClaudeExcelMarketplace"
    Write-Host ''

    try {
        Start-Process $Script:ClaudeExcelLandingPage | Out-Null
    }
    catch {
        Write-Warning "Couldn't auto-open the browser: $($_.Exception.Message). Visit $Script:ClaudeExcelLandingPage manually."
    }

    $timeoutSeconds = 300
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    Write-Host "Waiting up to $timeoutSeconds seconds for the Office WEF registry to record Claude for Excel..."
    while ((Get-Date) -lt $deadline) {
        if (Test-ClaudeExcelInstalled) {
            Write-Host 'Claude for Excel detected in the Office Web Add-in registry.'
            return
        }
        Start-Sleep -Seconds 5
    }

    Write-Warning "Claude for Excel was not detected within $timeoutSeconds seconds. If you completed the AppSource flow, a fresh Excel launch may be required for the registry to update. Otherwise, install manually from $Script:ClaudeExcelLandingPage."
}

Install-ClaudeExcel
