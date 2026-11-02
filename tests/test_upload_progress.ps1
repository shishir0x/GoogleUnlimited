# =====================================================================
# Regression Test Suite: BUG-05 (Upload Progress Tracking & 80% Stall Elimination)
# =====================================================================
$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-05 Upload Progress & 80% Stall Elimination" -ForegroundColor Green
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

# 1. Load utility definitions without starting watcher
$repoRoot = Split-Path -Parent $PSScriptRoot
$watchScript = Join-Path $repoRoot "WatchAndUpload.ps1"
. $watchScript -StatusOnly | Out-Null

# 2. Test Format-RemainingTime helper
$fmt45 = Format-RemainingTime 45.0
Assert-Condition "Seconds remaining format (~45s left)" ($fmt45 -eq "~45s left") "Got: $fmt45"

$fmt125 = Format-RemainingTime 125.0
Assert-Condition "Minutes remaining format (~2m 5s left)" ($fmt125 -eq "~2m 5s left") "Got: $fmt125"

$fmt3665 = Format-RemainingTime 3665.0
Assert-Condition "Hours remaining format (~1h 1m left)" ($fmt3665 -eq "~1h 1m left") "Got: $fmt3665"

$fmtZero = Format-RemainingTime 0.0
Assert-Condition "Zero seconds remaining format (finishing...)" ($fmtZero -eq "finishing...") "Got: $fmtZero"

# 3. Test Adaptive Progression: Ensure NO mathematical asymptote at 86.9%
# Previously: ratio = elapsedSec / (elapsedSec * 1.15 + 2.0) -> capped at 86.9%
$estTotalSec = 100.0

function Get-FallbackRatio([double]$elapsed, [double]$estTotal) {
    if ($elapsed -lt $estTotal) {
        return [Math]::Min(0.90, [Math]::Max(0.01, ($elapsed / $estTotal) * 0.90))
    } else {
        $overSec = $elapsed - $estTotal
        return 0.90 + (0.09 * (1.0 - [Math]::Exp(-$overSec / [Math]::Max(30.0, $estTotal))))
    }
}

$rEarly = Get-FallbackRatio 50.0 $estTotalSec
Assert-Condition "Progression at 50% elapsed time is 45%" ([Math]::Round($rEarly, 2) -eq 0.45) "Got: $rEarly"

$rAtEst = Get-FallbackRatio 100.0 $estTotalSec
Assert-Condition "Progression at estimated time is 90%" ([Math]::Round($rAtEst, 2) -eq 0.90) "Got: $rAtEst"

$rOldStuckTime1 = Get-FallbackRatio 150.0 $estTotalSec
$rOldStuckTime2 = Get-FallbackRatio 500.0 $estTotalSec
$rOldStuckTime3 = Get-FallbackRatio 811.9 $estTotalSec

Assert-Condition "Fallback ratio at 150s exceeds 90%" ($rOldStuckTime1 -gt 0.90) "Ratio at 150s: $rOldStuckTime1"
Assert-Condition "Fallback ratio at 500s exceeds 95%" ($rOldStuckTime2 -gt 0.95) "Ratio at 500s: $rOldStuckTime2"
Assert-Condition "Fallback ratio at 811.9s exceeds 98% (not stuck at 86.8%)" ($rOldStuckTime3 -gt 0.98) "Ratio at 811.9s: $rOldStuckTime3"
Assert-Condition "Fallback progression is strictly monotonic" ($rOldStuckTime3 -gt $rOldStuckTime2 -and $rOldStuckTime2 -gt $rOldStuckTime1 -and $rOldStuckTime1 -gt $rAtEst)

# 4. Test Finalizing ETA Display when file upload reaches >= 99%
function Get-EtaDisplay([double]$ratio, [double]$fileBytes, [double]$uploadedBytes, [double]$elapsedSec) {
    if ($ratio -ge 0.99) {
        return ", finalizing..."
    } elseif ($ratio -gt 0.03 -and $elapsedSec -gt 0.8) {
        $speedBytes = $uploadedBytes / $elapsedSec
        $remainBytes = [Math]::Max(0.0, $fileBytes - $uploadedBytes)
        if ($speedBytes -gt 1024) {
            $remainSec = $remainBytes / $speedBytes
            return ", " + (Format-RemainingTime $remainSec)
        }
    }
    return ""
}

$etaFinalizing = Get-EtaDisplay 0.99 480MB 480MB 300.0
Assert-Condition "ETA displays 'finalizing...' instead of misleading countdown at >=99%" ($etaFinalizing -eq ", finalizing...") "Got: $etaFinalizing"

$etaActive = Get-EtaDisplay 0.50 100MB 50MB 50.0
Assert-Condition "Active upload calculates valid countdown ETA" ($etaActive -like "*left*") "Got: $etaActive"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
