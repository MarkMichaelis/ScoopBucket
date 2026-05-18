# OneDrive completion plan (Issue #183)

## Tasks

### Task 1 - Add red placement test
File: bucket/Bundles.Tests.ps1
Inside the "Specific cross-bundle placement contracts" Describe, add:

    It "OneDrive CLI shim is owned by the MicrosoftOffice365 bundle" {
        $script:byBundle.MicrosoftOffice365.Name | Should -Contain "OneDrive CLI shim"
    }

Run: `Invoke-Pester bucket/Bundles.Tests.ps1 -Tag Light` -> the new test fails.

### Task 2 - Add the Package entry (green)
File: bucket/MicrosoftOffice365.ps1
Insert a new [Package] entry into $Packages array, after "Microsoft Office CLI shims" and before "Claude for Excel". Properties:

- Name = "OneDrive CLI shim"
- Installer = "custom"
- CliCommands = @("onedrive")
- Completion = "native"
- ExpectedCompletions = @{ onedrive = @("/background","/reset","/shutdown","/restart","/addaccount","/configure_business","/silentconfig","/diag","/checkforupdates","/forcedeleteonedrive","/InternalAddBusiness") }
- Notes = curated; OneDrive.exe ships with Windows and has no first-party PowerShell completer.
- CustomInstallScript: locate OneDrive.exe under "C:\Program Files\Microsoft OneDrive\" or the (x86) twin; write ~\scoop\shims\onedrive.cmd with ScoopBucket:OneDriveShim sentinel; detached via @start "" "<bin>" %*.
- CustomUninstallScript: only remove the shim if our sentinel is present.
- VerifyScript: shim exists and contains the sentinel.
- NativeCommandScript: emits Register-ArgumentCompleter -Native -CommandName onedrive with the curated switch list (here-string identical in shape to the Office shims pattern).

Run: `Invoke-Pester bucket/Bundles.Tests.ps1 -Tag Light` -> all green (placement test passes, data-driven invariants pass).

### Task 3 - Bump manifest version
File: bucket/MicrosoftOffice365.json
version: "1.10.000" -> "1.11.000" (README: minor for added package).

### Task 4 - Run full Light suite for the bundle area
Run: `Invoke-Pester bucket/Bundles.Tests.ps1, bucket/Package.Tests.ps1, bucket/ManifestVersionBumps.Tests.ps1 -Tag Light` -> all green.

### Task 5 - Evidence capture
Capture a real TabExpansion2 run for `onedrive ` showing the curated switches. Save to .evidence/<phase-id>/.

### Task 6 - Commit + PR
- test(office): add OneDrive placement assertion
- feat(office): add OneDrive shim + native completion (#183)
- chore(manifest): bump MicrosoftOffice365 to 1.11.000

PR via gh pr create --body-file ..., includes "Closes #183".
