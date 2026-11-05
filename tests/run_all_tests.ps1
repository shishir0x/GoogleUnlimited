# =====================================================================
# Comprehensive Test Runner: Windows (PowerShell)
# =====================================================================
$ErrorActionPreference = "Stop"

$testFiles = @(
    "test_readiness.ps1",
    "test_quoting.ps1",
    "test_deadlock.ps1",
    "test_dedup.ps1",
    "test_persistence.ps1",
    "test_watch_folders_and_ext.ps1",
    "test_upload_verification.ps1",
    "test_single_instance.ps1",
    "test_permissions.ps1",
    "test_lru_cache.ps1",
    "test_upload_progress.ps1",
    "test_onedrive_and_reparse.ps1",
    "test_update_and_sweep.ps1"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$totalPassed = 0
$totalFailed = 0

$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  GoogleUnlimited - Windows Regression Test Suite"         -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

foreach ($testName in $testFiles) {
    $testPath = Join-Path $scriptDir $testName
    Write-Host "`n>>> Running: $testName" -ForegroundColor Yellow
    & $psExe -NoProfile -File $testPath
    if ($LASTEXITCODE -eq 0) {
        $totalPassed++
    } else {
        $totalFailed++
        Write-Host "FAILED: $testName" -ForegroundColor Red
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  FINAL SUMMARY: $totalPassed Suites Passed, $totalFailed Suites Failed" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($totalFailed -gt 0) { exit 1 } else { exit 0 }
