# =====================================================================
# Regression Test Suite: Issue #10 & Issue #11 (Update App & Resource Optimization)
# =====================================================================
$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: Issue #10 & #11 Update App & Sweep Optimization" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Condition([string]$testName, [bool]$condition, [string]$detail = "") {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] ${testName}: $detail" -ForegroundColor Red
        $script:failed++
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$watchScript = Join-Path $repoRoot "WatchAndUpload.ps1"
$batScript = Join-Path $repoRoot "GoogleUnlimited.bat"
$shScript = Join-Path $repoRoot "google-unlimited.sh"

# ---------------------------------------------------------------------
# Test Set 1: Issue #11 Sweep & Startup Optimization
# ---------------------------------------------------------------------
Write-Host "`nTest Set 1: Issue #11 Resource Optimization & Sweep Tuning" -ForegroundColor Yellow

$scriptContent = [System.IO.File]::ReadAllText($watchScript)

# Check sweep interval constant is 900 seconds (15 minutes)
$hasSweepConst = $scriptContent -match '\$script:SWEEP_INTERVAL_SECS\s*=\s*900'
Assert-Condition "Sweep interval is configured to 900 seconds (15 minutes)" $hasSweepConst

# Check safety sweep filters out duplicates before logging
$hasSweepDuplicateCheck = $scriptContent -match 'Where-Object\s*\{\s*-not\s*\(Test-IsDuplicateUpload\s*\$_\.FullName\)\s*\}'
Assert-Condition "Safety sweep checks deduplication before logging and invoking upload" $hasSweepDuplicateCheck

# Check startup scan filters out duplicates
$hasStartupDuplicateCheck = $scriptContent -match 'Where-Object\s*\{\s*\$ForceResync\s*-or\s*\(-not\s*\(Test-IsDuplicateUpload\s*\$_\.FullName\)\)\s*\}'
Assert-Condition "Startup scan filters out already uploaded files to prevent redundant passes" $hasStartupDuplicateCheck

# Check Garbage Collection hint is present after sweep
$hasGcHint = $scriptContent -match '\[System\.GC\]::Collect\(\)'
Assert-Condition "Sweep loop contains GC cleanup hint for long-running sessions" $hasGcHint

# ---------------------------------------------------------------------
# Test Set 2: Issue #10 Application Update Functionality & Config Safety
# ---------------------------------------------------------------------
Write-Host "`nTest Set 2: Issue #10 Application Update & Config Preservation" -ForegroundColor Yellow

# Verify parameter and function presence in WatchAndUpload.ps1
$hasUpdateParam = $scriptContent -match '\[switch\]\$UpdateApp'
Assert-Condition "WatchAndUpload.ps1 contains -UpdateApp parameter" $hasUpdateParam

$hasUpdateFunc = $scriptContent -match 'function Update-Application'
Assert-Condition "WatchAndUpload.ps1 defines Update-Application function" $hasUpdateFunc

# Verify config preservation logic in Update-Application
$hasConfigProtection = $scriptContent -match '\$protectedFiles\s*=\s*@\("gotohp\.config"'
Assert-Condition "Update-Application explicitly protects gotohp.config, watch_dirs.txt, gphotos.db" $hasConfigProtection

# Test running -UpdateApp in child process
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $psExe
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$watchScript`" -UpdateApp"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$out = $proc.StandardOutput.ReadToEnd()
$err = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

Assert-Condition "-UpdateApp exits with code 0" ($proc.ExitCode -eq 0) "Exit code: $($proc.ExitCode), Error: $err"
Assert-Condition "-UpdateApp output mentions updater header" ($out -match "Google Unlimited Photos - Application Updater")
Assert-Condition "-UpdateApp output reports configurations preserved" ($out -match "Configuration.*preserved")

# Verify GoogleUnlimited.bat has option 11 and update arg
$batContent = [System.IO.File]::ReadAllText($batScript)
$hasBatMenu = $batContent -match '\[11\] Check / Update Application'
Assert-Condition "GoogleUnlimited.bat menu includes option [11] for updates" $hasBatMenu

$hasBatArg = $batContent -match 'if /i "%arg%"=="update" goto update_app'
Assert-Condition "GoogleUnlimited.bat CLI dispatcher accepts 'update' argument" $hasBatArg

# Verify google-unlimited.sh has update command and function
$shContent = [System.IO.File]::ReadAllText($shScript)
$hasShUpdate = $shContent -match 'do_update\(\)'
Assert-Condition "google-unlimited.sh defines do_update() function" $hasShUpdate

$hasShDispatch = $shContent -match 'update\|--update\|upgrade\|--upgrade\)'
Assert-Condition "google-unlimited.sh CLI dispatcher accepts 'update' command" $hasShDispatch

# ---------------------------------------------------------------------
# Test Set 3: Issue #13 Subfolder Event Detection During Live Watch
# ---------------------------------------------------------------------
Write-Host "`nTest Set 3: Issue #13 Subfolder Event Detection During Live Watch" -ForegroundColor Yellow

$hasSubfolderWatchPs1 = $scriptContent -match 'Get-ChildItem -LiteralPath \$evPath -File -Recurse'
Assert-Condition "Process-WatchEvent recursively scans subfolder additions in WatchAndUpload.ps1" $hasSubfolderWatchPs1

$hasSubfolderWatchSh = $shContent -match 'find "\$fpath" -type f -print0'
Assert-Condition "invoke_upload recursively discovers subfolder files in google-unlimited.sh" $hasSubfolderWatchSh

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
}
exit 0
