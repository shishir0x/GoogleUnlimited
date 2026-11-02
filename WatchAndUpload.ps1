# =====================================================================
# GoogleUnlimited - Portable Google Photos Auto-Sync & Real-Time Watcher
# Runs on ANY Windows PC (PS 5.1 and PS 7+), zero hardcoded paths
# Self-contained SQLite engine with cross-platform deduplication
# =====================================================================
param(
    [string[]]$WatchDirs = @(),
    [string]$Account = "",
    [switch]$ForceResync,
    [switch]$StatusOnly,
    [switch]$ShowLogs,
    [switch]$EnableStartup,
    [switch]$DisableStartup,
    [switch]$StopWatcher,
    [switch]$CheckRunning,
    [switch]$ManageDirs,
    [string]$AddWatchDir = "",
    [string]$RemoveWatchDir = "",
    [switch]$ResetWatchDirs,
    [switch]$ListWatchDirs
)
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# 1. ENVIRONMENT & BASE PATHS
# ---------------------------------------------------------------------
$script:BASE = $PSScriptRoot
if (-not $script:BASE) {
    $script:BASE = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:BASE) {
    $script:BASE = (Get-Location).Path
}

$script:DB = Join-Path $script:BASE "gphotos.db"

# Discover gotohp-cli executable
$script:GOTOHP = $null
$binCandidates = @(
    "gotohp-cli-x64.exe",
    "gotohp-cli.exe",
    "gotohp-x64.exe",
    "gotohp.exe"
)

foreach ($cand in $binCandidates) {
    $testPath = Join-Path $script:BASE $cand
    if ([System.IO.File]::Exists($testPath)) {
        $script:GOTOHP = $testPath
        break
    }
}

if (-not $script:GOTOHP) {
    foreach ($cand in $binCandidates) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($cand)
        $pathCmd = Get-Command $baseName -ErrorAction SilentlyContinue
        if ($pathCmd) {
            $script:GOTOHP = $pathCmd.Source
            break
        }
    }
}

function Assert-BinaryIntegrity([string]$binPath) {
    if (-not [System.IO.File]::Exists($binPath)) { return }
    $trustedHashes = @{
        "gotohp-cli-x64.exe"         = "c272a285a03aeea02a909f0b74d36f84c4a29c235c8dee47f7de75c83f15d2b1"
        "gotohp-x64.exe"             = "5c3f757b9e6b2ffd83934b59274136cf4e67c000265e2eaaa4f34dca6a821088"
        "gotohp-cli_amd64"           = "945021d5dbc36a96f53121eb4f907ace39d9457cea1b43107ed1986441b29030"
        "gotohp-cli-macos-universal" = "d697e23c648881cf5e7db7b93f815f6d3dcbd9d7718a40d0edffee90456b0557"
    }
    $binName = [System.IO.Path]::GetFileName($binPath).ToLower()
    if ($trustedHashes.ContainsKey($binName)) {
        $expected = $trustedHashes[$binName]
        $actual = (Get-FileHash -LiteralPath $binPath -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            Write-Host "CRITICAL: Binary integrity verification failed for $binName!" -ForegroundColor Red
            Write-Host "  Expected SHA-256: $expected" -ForegroundColor Red
            Write-Host "  Actual SHA-256:   $actual" -ForegroundColor Red
            throw "Binary integrity verification failed for $binName. Possible file tampering or corruption."
        }
    }
}

if ($script:GOTOHP) {
    Assert-BinaryIntegrity $script:GOTOHP
}

function Protect-FileAcl([string]$filePath) {
    if (-not [System.IO.File]::Exists($filePath)) { return }
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false) # Disable inheritance, purge inherited permissions
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $filePath -AclObject $acl
    } catch {
        # Gracefully handle filesystems without Windows ACL support (e.g. FAT32/exFAT)
    }
}

# Discover portable configuration
$script:CONFIG_ARGS = @()
$portableConfig = Join-Path $script:BASE "gotohp.config"
if ([System.IO.File]::Exists($portableConfig)) {
    $script:CONFIG_ARGS = @("--config", $portableConfig)
    Protect-FileAcl $portableConfig
}

# ---------------------------------------------------------------------
# 2. QUICK CLI ACTIONS (No database, lock, or directory scanning needed)
# ---------------------------------------------------------------------
if ($CheckRunning) {
    $cleanBase = $script:BASE.ToLower().Replace("\", "_").Replace(":", "").Replace(" ", "_")
    $script:instanceMutexName = "Local\GoogleUnlimited_Watcher_" + $cleanBase
    $isRunning = $false
    try {
        $testMutex = [System.Threading.Mutex]::OpenExisting($script:instanceMutexName)
        if ($testMutex) {
            $testMutex.Dispose()
            $isRunning = $true
        }
    } catch {
        $isRunning = $false
    }
    if ($isRunning) {
        Write-Host "RUNNING"
        exit 0
    } else {
        Write-Host "STOPPED"
        exit 1
    }
}

if ($StopWatcher) {
    Write-Host "Stopping Google Photos background watcher..." -ForegroundColor Cyan
    $currentPid = $PID
    $stopped = 0
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $currentPid -and
        $_.CommandLine -and
        ($_.CommandLine -like "*WatchAndUpload.ps1*")
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Stopped watcher (PID $($_.ProcessId))" -ForegroundColor Green
        $stopped++
    }
    if ($stopped -gt 0) {
        Write-Host "All background watcher instances have been stopped." -ForegroundColor Green
    } else {
        Write-Host "No active background watcher instances found running." -ForegroundColor Yellow
    }
    return
}

if ($EnableStartup) {
    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupFolder "GoogleUnlimited.lnk"

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  *  Windows Startup Configuration"                          -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan

    if ([System.IO.File]::Exists($shortcutPath)) {
        Write-Host ""
        Write-Host "[INFO] Auto-start on boot is ALREADY ENABLED." -ForegroundColor Yellow
        Write-Host "       Shortcut: $shortcutPath" -ForegroundColor Gray
        Write-Host "       Only one startup entry can be added. It is already set to run on Windows boot." -ForegroundColor Gray
        Write-Host "       (To remove it, select option [6] Disable Auto-Start)" -ForegroundColor Cyan
        Write-Host ""
        return
    }

    Write-Host "Setting up Google Photos Auto-Sync to run on Windows startup..." -ForegroundColor Cyan
    $scriptFile = Join-Path $script:BASE "WatchAndUpload.ps1"
    if (-not [System.IO.File]::Exists($scriptFile)) {
        Write-Host "[ERROR] Could not find $scriptFile" -ForegroundColor Red
        return
    }

    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { "powershell.exe" }

    try {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($shortcutPath)
        $s.TargetPath = $psExe
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptFile`""
        $s.WorkingDirectory = $script:BASE
        $s.Description = "Google Photos Unlimited Auto-Sync Watcher"
        $s.Save()

        if ([System.IO.File]::Exists($shortcutPath)) {
            Write-Host ""
            Write-Host "[OK] Startup shortcut created: $shortcutPath" -ForegroundColor Green
            Write-Host "Google Photos Auto-Sync will now start automatically in the background on boot." -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host "[ERROR] Failed to create startup shortcut at $shortcutPath" -ForegroundColor Red
        }
    } catch {
        Write-Host "[ERROR] Failed to create startup shortcut: $_" -ForegroundColor Red
    }
    return
}

if ($DisableStartup) {
    $startupFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupFolder "GoogleUnlimited.lnk"

    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  *  Windows Startup Configuration"                          -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan

    if ([System.IO.File]::Exists($shortcutPath)) {
        try {
            Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
            if (-not [System.IO.File]::Exists($shortcutPath)) {
                Write-Host ""
                Write-Host "[OK] Startup shortcut removed successfully." -ForegroundColor Green
                Write-Host "     Deleted: $shortcutPath" -ForegroundColor Gray
                Write-Host "Google Photos Auto-Sync will NO LONGER launch automatically on boot." -ForegroundColor Yellow
                Write-Host ""
            } else {
                Write-Host "[ERROR] Could not remove $shortcutPath. Please check file permissions." -ForegroundColor Red
            }
        } catch {
            Write-Host "[ERROR] Failed to remove startup shortcut: $_" -ForegroundColor Red
        }
    } else {
        Write-Host ""
        Write-Host "[INFO] Startup shortcut was NOT present (already disabled)." -ForegroundColor Yellow
        Write-Host "       Target: $shortcutPath" -ForegroundColor Gray
        Write-Host ""
    }
    return
}

# ---------------------------------------------------------------------
# BACKUP FOLDERS MANAGEMENT (Interactive & CLI)
# ---------------------------------------------------------------------
$script:customDirsFile = Join-Path $script:BASE "watch_dirs.txt"

function Get-StandardWindowsFolders {
    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $regDown = $null
    try {
        $regDown = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue)."{374DE290-123F-4565-9164-39C4925E467B}"
    } catch {}
    $downPath = if ($regDown -and [System.IO.Directory]::Exists($regDown)) { $regDown } else { Join-Path $userHome "Downloads" }

    $oneDriveRoot = $env:OneDrive
    if (-not $oneDriveRoot -and [System.IO.Directory]::Exists((Join-Path $userHome "OneDrive"))) {
        $oneDriveRoot = Join-Path $userHome "OneDrive"
    }
    $oneDrivePic = if ($oneDriveRoot) { Join-Path $oneDriveRoot "Pictures" } else { Join-Path $userHome "OneDrive\Pictures" }

    return [ordered]@{
        "Pictures"         = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
        "Downloads"        = $downPath
        "OneDrivePictures" = $oneDrivePic
        "Desktop"          = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
        "Videos"           = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyVideos)
        "Documents"        = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        "Music"            = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyMusic)
    }
}

function Get-ConfiguredFoldersList {
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $stdFolders = Get-StandardWindowsFolders
    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)

    if ([System.IO.File]::Exists($script:customDirsFile)) {
        $lines = [System.IO.File]::ReadAllLines($script:customDirsFile)
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith("#")) {
                $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
                if ([System.IO.Directory]::Exists($expanded)) {
                    $resolved = (Resolve-Path -LiteralPath $expanded).Path
                    if (-not $dirs.Contains($resolved)) { $dirs.Add($resolved) }
                } else {
                    if (-not $dirs.Contains($expanded)) { $dirs.Add($expanded) }
                }
            }
        }
    } else {
        # Default cleanly to image folders: Pictures & Downloads (plus cloud photos)
        if ($stdFolders["Pictures"] -and [System.IO.Directory]::Exists($stdFolders["Pictures"])) {
            $dirs.Add($stdFolders["Pictures"])
        }
        if ($stdFolders["Downloads"] -and [System.IO.Directory]::Exists($stdFolders["Downloads"])) {
            if (-not $dirs.Contains($stdFolders["Downloads"])) { $dirs.Add($stdFolders["Downloads"]) }
        }
        $cloudPic = $stdFolders["OneDrivePictures"]
        if ($cloudPic -and [System.IO.Directory]::Exists($cloudPic) -and -not $dirs.Contains($cloudPic)) { $dirs.Add($cloudPic) }
        $iCloud = Join-Path $userHome "Pictures\iCloud Photos\Photos"
        if ([System.IO.Directory]::Exists($iCloud) -and -not $dirs.Contains($iCloud)) { $dirs.Add($iCloud) }
    }
    return $dirs
}

function Get-MutableConfiguredFoldersList {
    $result = New-Object 'System.Collections.Generic.List[string]'
    $items = Get-ConfiguredFoldersList
    if ($items) {
        foreach ($item in $items) {
            if ($item -and -not $result.Contains($item)) {
                $result.Add($item)
            }
        }
    }
    return ,$result
}

function Save-ConfiguredFoldersList($folderList) {
    $content = New-Object 'System.Collections.Generic.List[string]'
    $content.Add("# GoogleUnlimited Watched Folders")
    $content.Add("# Add one folder path per line. Photos and videos in these folders are automatically backed up.")
    foreach ($f in $folderList) {
        if (-not [string]::IsNullOrWhiteSpace($f)) {
            $content.Add($f.Trim())
        }
    }
    [System.IO.File]::WriteAllLines($script:customDirsFile, $content.ToArray())
}

if ($ListWatchDirs) {
    $current = Get-ConfiguredFoldersList
    Write-Host "GoogleUnlimited Configured Watch Folders:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $current.Count; $i++) {
        Write-Host "  [$($i + 1)] $($current[$i])"
    }
    return
}

if ($AddWatchDir) {
    $cleanPath = $AddWatchDir.Trim().Trim('"').Trim("'")
    $expanded = [Environment]::ExpandEnvironmentVariables($cleanPath)
    $resolved = if ([System.IO.Directory]::Exists($expanded)) { (Resolve-Path -LiteralPath $expanded).Path } else { $expanded }
    $current = Get-MutableConfiguredFoldersList
    if (-not $current.Contains($resolved)) {
        $current.Add($resolved)
        Save-ConfiguredFoldersList $current
        Write-Host "[OK] Added folder to watch list: $resolved" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Folder is already in watch list: $resolved" -ForegroundColor Yellow
    }
    return
}

if ($RemoveWatchDir) {
    $current = Get-MutableConfiguredFoldersList
    [int]$idx = 0
    $removed = $null
    if ([int]::TryParse($RemoveWatchDir, [ref]$idx) -and $idx -ge 1 -and $idx -le $current.Count) {
        $removed = $current[$idx - 1]
        $current.RemoveAt($idx - 1)
    } else {
        $target = $RemoveWatchDir.Trim().Trim('"').Trim("'")
        $found = $current | Where-Object { $_ -eq $target -or (Resolve-Path -LiteralPath $_ -ErrorAction SilentlyContinue).Path -eq $target }
        if ($found) {
            $removed = $found
            $null = $current.Remove($found)
        }
    }
    if ($removed) {
        Save-ConfiguredFoldersList $current
        Write-Host "[OK] Removed folder from watch list: $removed" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Could not find folder to remove: $RemoveWatchDir" -ForegroundColor Red
    }
    return
}

if ($ResetWatchDirs) {
    if ([System.IO.File]::Exists($script:customDirsFile)) {
        Remove-Item -LiteralPath $script:customDirsFile -Force
    }
    Write-Host "[OK] Reset watch folders to default image folders (Pictures & Downloads)." -ForegroundColor Green
    return
}

if ($ManageDirs) {
    $stdFolders = Get-StandardWindowsFolders
    while ($true) {
        Clear-Host
        $current = Get-MutableConfiguredFoldersList
        $hasCustomFile = [System.IO.File]::Exists($script:customDirsFile)

        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  *  Google Photos Backup Folders Manager"                   -ForegroundColor Green
        Write-Host "  Config: $script:customDirsFile $(if (-not $hasCustomFile) { '[Clean Defaults]' } else { '[Customized]' })" -ForegroundColor Gray
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Active Backup Folders:" -ForegroundColor Yellow
        if ($current.Count -eq 0) {
            Write-Host "  (No folders configured! Choose an option below to add folders.)" -ForegroundColor Red
        } else {
            for ($i = 0; $i -lt $current.Count; $i++) {
                $f = $current[$i]
                $tag = "[Custom]"
                if ($f -eq $stdFolders["Pictures"]) { $tag = "[Default: Pictures]" }
                elseif ($f -eq $stdFolders["Downloads"]) { $tag = "[Default: Downloads]" }
                elseif ($f -eq $stdFolders["OneDrivePictures"]) { $tag = "[OneDrive: Pictures]" }
                elseif ($f -eq $stdFolders["Desktop"]) { $tag = "[Desktop]" }
                elseif ($f -eq $stdFolders["Videos"]) { $tag = "[Videos]" }
                elseif ($f -eq $stdFolders["Documents"]) { $tag = "[Documents]" }
                elseif ($f -eq $stdFolders["Music"]) { $tag = "[Music]" }

                $exists = [System.IO.Directory]::Exists($f)
                $statusColor = if ($exists) { "Green" } else { "DarkYellow" }
                $existsTag = if (-not $exists) { " (folder not found)" } else { "" }

                Write-Host "  [$($i + 1)] " -NoNewline -ForegroundColor Cyan
                Write-Host "$f " -NoNewline -ForegroundColor White
                Write-Host "$tag$existsTag" -ForegroundColor $statusColor
            }
        }
        Write-Host ""

        Write-Host "Quick-Toggle Standard Windows Folders:" -ForegroundColor Cyan
        $picActive  = $current.Contains($stdFolders["Pictures"])
        $downActive = $current.Contains($stdFolders["Downloads"])
        $onePicPath = $stdFolders["OneDrivePictures"]
        $oneActive  = if ($onePicPath) { $current.Contains($onePicPath) } else { $false }
        $vidActive  = $current.Contains($stdFolders["Videos"])
        $deskActive = $current.Contains($stdFolders["Desktop"])
        $docActive  = $current.Contains($stdFolders["Documents"])
        $musActive  = $current.Contains($stdFolders["Music"])

        Write-Host "  [P] Pictures  : $($stdFolders['Pictures']) " -NoNewline
        Write-Host $(if ($picActive) { "[ON  - Press P to Remove]" } else { "[OFF - Press P to Add]" }) -ForegroundColor $(if ($picActive) { "Green" } else { "DarkGray" })

        Write-Host "  [W] Downloads : $($stdFolders['Downloads']) " -NoNewline
        Write-Host $(if ($downActive) { "[ON  - Press W to Remove]" } else { "[OFF - Press W to Add]" }) -ForegroundColor $(if ($downActive) { "Green" } else { "DarkGray" })

        if ($onePicPath -and [System.IO.Directory]::Exists($onePicPath)) {
            Write-Host "  [O] OneDrive  : $onePicPath " -NoNewline
            Write-Host $(if ($oneActive) { "[ON  - Press O to Remove]" } else { "[OFF - Press O to Add]" }) -ForegroundColor $(if ($oneActive) { "Green" } else { "DarkGray" })
        }

        Write-Host "  [V] Videos    : $($stdFolders['Videos']) " -NoNewline
        Write-Host $(if ($vidActive) { "[ON  - Press V to Remove]" } else { "[OFF - Press V to Add]" }) -ForegroundColor $(if ($vidActive) { "Green" } else { "DarkGray" })

        Write-Host "  [D] Desktop   : $($stdFolders['Desktop']) " -NoNewline
        Write-Host $(if ($deskActive) { "[ON  - Press D to Remove]" } else { "[OFF - Press D to Add]" }) -ForegroundColor $(if ($deskActive) { "Green" } else { "DarkGray" })

        Write-Host "  [M] Documents : $($stdFolders['Documents']) " -NoNewline
        Write-Host $(if ($docActive) { "[ON  - Press M to Remove]" } else { "[OFF - Press M to Add]" }) -ForegroundColor $(if ($docActive) { "Green" } else { "DarkGray" })

        Write-Host "  [U] Music     : $($stdFolders['Music']) " -NoNewline
        Write-Host $(if ($musActive) { "[ON  - Press U to Remove]" } else { "[OFF - Press U to Add]" }) -ForegroundColor $(if ($musActive) { "Green" } else { "DarkGray" })

        Write-Host ""
        Write-Host "Actions:" -ForegroundColor Cyan
        Write-Host "  [A] Browse & Add Folder (Opens Windows Folder Picker)" -ForegroundColor Yellow
        Write-Host "  [T] Type or Paste a Custom Folder Path"
        Write-Host "  [R] Remove a Folder by Number"
        Write-Host "  [X] Reset to Clean Defaults (Pictures & Downloads only)"
        Write-Host "  [0] Done / Back to Main Menu" -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Cyan

        $action = Read-Host "Select an option"
        if (-not $action) { continue }
        $action = $action.Trim().ToUpper()

        switch ($action) {
            "0" { return }
            "A" {
                Write-Host "Opening Windows folder picker..." -ForegroundColor Yellow
                $selected = $null
                try {
                    $shell = New-Object -ComObject Shell.Application
                    $browse = $shell.BrowseForFolder(0, "Select a folder to back up to Google Photos", 0x41)
                    if ($browse) { $selected = $browse.Self.Path }
                } catch {
                    try {
                        Add-Type -AssemblyName System.Windows.Forms
                        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
                        $fbd.Description = "Select a folder to back up to Google Photos"
                        $fbd.ShowNewFolderButton = $true
                        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                            $selected = $fbd.SelectedPath
                        }
                    } catch {}
                }

                if ($selected) {
                    $expanded = [Environment]::ExpandEnvironmentVariables($selected)
                    $resolved = if ([System.IO.Directory]::Exists($expanded)) { (Resolve-Path -LiteralPath $expanded).Path } else { $expanded }
                    if (-not $current.Contains($resolved)) {
                        $current.Add($resolved)
                        Save-ConfiguredFoldersList $current
                        Write-Host "[OK] Added folder: $resolved" -ForegroundColor Green
                    } else {
                        Write-Host "[INFO] Folder is already in the list: $resolved" -ForegroundColor Yellow
                    }
                    Start-Sleep -Seconds 1
                }
            }
            "T" {
                $newPath = Read-Host "Enter or paste the full folder path"
                $newPath = $newPath.Trim().Trim('"').Trim("'")
                if ($newPath) {
                    $expanded = [Environment]::ExpandEnvironmentVariables($newPath)
                    $resolved = if ([System.IO.Directory]::Exists($expanded)) { (Resolve-Path -LiteralPath $expanded).Path } else { $expanded }
                    if (-not $current.Contains($resolved)) {
                        $current.Add($resolved)
                        Save-ConfiguredFoldersList $current
                        Write-Host "[OK] Added folder: $resolved" -ForegroundColor Green
                    } else {
                        Write-Host "[INFO] Folder is already in the list." -ForegroundColor Yellow
                    }
                    Start-Sleep -Seconds 1
                }
            }
            "R" {
                if ($current.Count -eq 0) {
                    Write-Host "No folders to remove." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }
                $numStr = Read-Host "Enter the number of the folder to remove [1-$($current.Count)]"
                [int]$idx = 0
                if ([int]::TryParse($numStr, [ref]$idx) -and $idx -ge 1 -and $idx -le $current.Count) {
                    $removed = $current[$idx - 1]
                    $current.RemoveAt($idx - 1)
                    Save-ConfiguredFoldersList $current
                    Write-Host "[OK] Removed: $removed" -ForegroundColor Green
                } else {
                    Write-Host "Invalid folder number." -ForegroundColor Red
                }
                Start-Sleep -Seconds 1
            }
            "P" {
                $p = $stdFolders["Pictures"]
                if ($p) {
                    if ($current.Contains($p)) { $null = $current.Remove($p); Write-Host "[OK] Removed Pictures" -ForegroundColor Yellow }
                    else { $current.Add($p); Write-Host "[OK] Added Pictures" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "W" {
                $d = $stdFolders["Downloads"]
                if ($d) {
                    if ($current.Contains($d)) { $null = $current.Remove($d); Write-Host "[OK] Removed Downloads" -ForegroundColor Yellow }
                    else { $current.Add($d); Write-Host "[OK] Added Downloads" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "O" {
                $o = $stdFolders["OneDrivePictures"]
                if ($o) {
                    if ($current.Contains($o)) { $null = $current.Remove($o); Write-Host "[OK] Removed OneDrive Pictures" -ForegroundColor Yellow }
                    else { $current.Add($o); Write-Host "[OK] Added OneDrive Pictures" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "V" {
                $v = $stdFolders["Videos"]
                if ($v) {
                    if ($current.Contains($v)) { $null = $current.Remove($v); Write-Host "[OK] Removed Videos" -ForegroundColor Yellow }
                    else { $current.Add($v); Write-Host "[OK] Added Videos" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "D" {
                $d = $stdFolders["Desktop"]
                if ($d) {
                    if ($current.Contains($d)) { $null = $current.Remove($d); Write-Host "[OK] Removed Desktop" -ForegroundColor Yellow }
                    else { $current.Add($d); Write-Host "[OK] Added Desktop" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "M" {
                $doc = $stdFolders["Documents"]
                if ($doc) {
                    if ($current.Contains($doc)) { $null = $current.Remove($doc); Write-Host "[OK] Removed Documents" -ForegroundColor Yellow }
                    else { $current.Add($doc); Write-Host "[OK] Added Documents" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "U" {
                $m = $stdFolders["Music"]
                if ($m) {
                    if ($current.Contains($m)) { $null = $current.Remove($m); Write-Host "[OK] Removed Music" -ForegroundColor Yellow }
                    else { $current.Add($m); Write-Host "[OK] Added Music" -ForegroundColor Green }
                    Save-ConfiguredFoldersList $current
                    Start-Sleep -Milliseconds 600
                }
            }
            "X" {
                $current.Clear()
                if ($stdFolders["Pictures"]) { $current.Add($stdFolders["Pictures"]) }
                if ($stdFolders["Downloads"]) { $current.Add($stdFolders["Downloads"]) }
                Save-ConfiguredFoldersList $current
                Write-Host "[OK] Reset to default photo folders (Pictures & Downloads)." -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
        }
    }
    return
}

# ---------------------------------------------------------------------
# 3. SINGLE-INSTANCE PROTECTION (Named Windows Mutex)
# ---------------------------------------------------------------------
$script:instanceMutex = $null
$script:hasInstanceMutex = $false

# Diagnostic/management commands do not start background work and should not be blocked
if (-not ($StatusOnly -or $ShowLogs -or $CheckRunning -or $ManageDirs -or $AddWatchDir -or $RemoveWatchDir -or $ResetWatchDirs -or $ListWatchDirs)) {
    $cleanBase = $script:BASE.ToLower().Replace("\", "_").Replace(":", "").Replace(" ", "_")
    $script:instanceMutexName = "Local\GoogleUnlimited_Watcher_" + $cleanBase

    try {
        [bool]$createdNew = $false
        $script:instanceMutex = New-Object System.Threading.Mutex($false, $script:instanceMutexName, [ref]$createdNew)
        try {
            $script:hasInstanceMutex = $script:instanceMutex.WaitOne(1000, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $script:hasInstanceMutex = $true
        }
    } catch [System.Threading.AbandonedMutexException] {
        $script:hasInstanceMutex = $true
    } catch {
        Write-Host "Warning: Could not access instance mutex: $_" -ForegroundColor Yellow
        $script:hasInstanceMutex = $false
    }

    if (-not $script:hasInstanceMutex) {
        Write-Host "Another instance is already running. Exiting." -ForegroundColor Yellow
        if ($script:instanceMutex) {
            try { $script:instanceMutex.Dispose() } catch {}
            $script:instanceMutex = $null
        }
        exit 0
    }
}

try {
    # -----------------------------------------------------------------
    # 4. CONFIGURATION CONSTANTS & STATE
    # -----------------------------------------------------------------
    $script:MIN_BYTES = 10240   # 10 KB minimum file size
    $script:MAX_RETRY = 3       # Max retry attempts per file
    $script:LOG_RETENTION_DAYS = 30
    $script:lastUploadSpeed = 2MB  # Adaptive baseline for smooth, realistic progress tracking
    $script:currentUploadProc = $null

    # Supported media extensions (photos, camera RAWs, and videos)
    $script:EXT = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $extList = @(
        # Standard Photos & Images
        ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".bmp", ".tiff", ".tif", ".svg", ".ico", ".jfif", ".avif",
        # Camera RAW Formats
        ".dng", ".raw", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".pef", ".srw", ".raf",
        # Video Formats
        ".mp4", ".mov", ".mkv", ".avi", ".m4v", ".3gp", ".3g2", ".wmv", ".webm", ".mpg", ".mpeg", ".mts", ".m2ts", ".ts", ".flv", ".vob"
    )
    foreach ($e in $extList) { $script:EXT.Add($e) | Out-Null }

    # Bounded in-memory LRU cache (capped at 5,000 items to prevent unbounded memory growth)
    $script:MAX_CACHE_SIZE = 5000
    $script:history        = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:cacheQueue     = New-Object 'System.Collections.Generic.Queue[string]'
    $script:fileLookup     = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:pathSize       = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:pathHash       = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:retryMap       = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:inFlight       = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Mutex for thread-safe cross-process SQLite database access
    $cleanPath = $script:DB.ToLower().Replace("\", "_").Replace(":", "").Replace(" ", "_")
    $mutexName = "GotohpDBMutex_" + $cleanPath
    try {
        $script:dbMutex = New-Object System.Threading.Mutex($false, $mutexName)
    } catch {
        $script:dbMutex = New-Object System.Threading.Mutex($false, ("Local\" + $cleanPath))
    }

    # -----------------------------------------------------------------
    # 5. UTILITY HELPERS
    # -----------------------------------------------------------------

    function Format-RemainingTime([double]$sec) {
        $s = [int][Math]::Round($sec)
        if ($s -ge 3600) {
            $h = [Math]::Floor($s / 3600)
            $m = [Math]::Floor(($s % 3600) / 60)
            return "~${h}h ${m}m left"
        } elseif ($s -ge 60) {
            $m = [Math]::Floor($s / 60)
            $remS = $s % 60
            return "~${m}m ${remS}s left"
        } elseif ($s -gt 0) {
            return "~${s}s left"
        } else {
            return "finishing..."
        }
    }

    function Format-WindowsArgument([string]$arg) {
        if ([string]::IsNullOrEmpty($arg)) { return '""' }
        if ($arg -notmatch '[\s"\\<>&|^]') { return $arg }
        $escaped = $arg -replace '(\\+)"', '$1$1\"' -replace '(\\+)$', '$1$1' -replace '"', '\"'
        return "`"$escaped`""
    }

    function Get-FileHashSafe([string]$path) {
        try {
            if (-not [System.IO.File]::Exists($path)) { return "" }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes = $sha.ComputeHash($stream)
                return [System.BitConverter]::ToString($bytes).Replace("-", "").ToLower()
            } finally {
                $stream.Dispose()
                $sha.Dispose()
            }
        } catch {
            return ""
        }
    }

    function Safe-ConsoleWrite([string]$text) {
        try {
            $esc = [char]27
            try {
                $pos = $Host.UI.RawUI.CursorPosition
                $pos.X = 0
                $Host.UI.RawUI.CursorPosition = $pos
            } catch {
                try { [Console]::CursorLeft = 0 } catch {}
            }
            $cleanText = "`r$esc[2K$esc[1G" + $text.TrimStart("`r")
            Write-Host -NoNewline $cleanText
        } catch {
            try {
                if ([Environment]::UserInteractive) {
                    [Console]::Write($text)
                }
            } catch {}
        }
    }

    function Resolve-ExistingFolder([string]$fPath) {
        if (-not [string]::IsNullOrWhiteSpace($fPath)) {
            $expanded = [Environment]::ExpandEnvironmentVariables($fPath)
            if ([System.IO.Directory]::Exists($expanded)) {
                return (Resolve-Path -LiteralPath $expanded).Path
            }
        }
        return $null
    }

    # Discover watch folders (registry, shell special folders, custom folders, and CLI arguments)
    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)

    $regDownloads = $null
    try {
        $regDownloads = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue)."{374DE290-123F-4565-9164-39C4925E467B}"
    } catch {}

    $folderCandidates = @()
    $customDirsFile = Join-Path $script:BASE "watch_dirs.txt"

    if ([System.IO.File]::Exists($customDirsFile)) {
        # When watch_dirs.txt exists, watch ONLY user-configured directories
        try {
            $lines = [System.IO.File]::ReadAllLines($customDirsFile)
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -and -not $trimmed.StartsWith("#")) {
                    $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
                    $folderCandidates += $expanded
                }
            }
        } catch {}
    } else {
        # Default behavior: ONLY image and photo folders (Pictures, Downloads, cloud photo folders)
        $folderCandidates = @(
            $regDownloads,
            [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures),
            (Join-Path $userHome "Pictures"),
            (Join-Path $userHome "Downloads"),
            (Join-Path $userHome "OneDrive\Pictures"),
            (Join-Path $userHome "OneDrive\Pictures\Camera Roll"),
            (Join-Path $userHome "Pictures\iCloud Photos\Photos"),
            (Join-Path $userHome "Google Drive\Google Photos"),
            (Join-Path $userHome "Google Photos")
        )
    }

    # Add CLI specified directories
    if ($WatchDirs -and $WatchDirs.Count -gt 0) {
        foreach ($wd in $WatchDirs) {
            if (-not [string]::IsNullOrWhiteSpace($wd)) {
                $expanded = [Environment]::ExpandEnvironmentVariables($wd.Trim())
                $folderCandidates += $expanded
            }
        }
    }

    $seenFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:WATCH_DIRS = New-Object 'System.Collections.Generic.List[string]'

    foreach ($cand in $folderCandidates) {
        $resolved = Resolve-ExistingFolder $cand
        if ($resolved -and -not $seenFolders.Contains($resolved)) {
            $seenFolders.Add($resolved) | Out-Null
            $script:WATCH_DIRS.Add($resolved) | Out-Null
        }
    }

    # -----------------------------------------------------------------
    # 6. PORTABLE SQLITE ENGINE & DATABASE OPERATIONS
    # -----------------------------------------------------------------
    if (-not (Get-Module -Name PSSQLite)) {
        $modulePaths = @(
            (Join-Path $script:BASE "Modules\PSSQLite\PSSQLite.psd1"),
            (Join-Path $script:BASE "Modules\PSSQLite\1.1.0\PSSQLite.psd1"),
            (Join-Path $env:USERPROFILE "Documents\PowerShell\Modules\PSSQLite\1.1.0\PSSQLite.psd1"),
            (Join-Path $env:USERPROFILE "Documents\PowerShell\Modules\PSSQLite\PSSQLite.psd1"),
            (Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\Modules\PSSQLite\1.1.0\PSSQLite.psd1"),
            (Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\Modules\PSSQLite\PSSQLite.psd1")
        )

        $loaded = $false
        foreach ($mp in $modulePaths) {
            if ([System.IO.File]::Exists($mp)) {
                Import-Module -Name $mp -ErrorAction SilentlyContinue
                $loaded = $true
                break
            }
        }

        if (-not $loaded) {
            Import-Module -Name PSSQLite -ErrorAction SilentlyContinue
        }
    }

    # Fallback installer if running on a fresh PC without bundled modules
    if (-not (Get-Command -Name Invoke-SqliteQuery -ErrorAction SilentlyContinue)) {
        Write-Host "[Setup] SQLite module not detected. Installing automatically..." -ForegroundColor Yellow
        try {
            Install-Module -Name PSSQLite -Force -Scope CurrentUser -ErrorAction Stop
            Import-Module PSSQLite -ErrorAction Stop
            Write-Host "[Setup] SQLite module installed successfully." -ForegroundColor Green
        } catch {
            Write-Host "ERROR: Could not load or install PSSQLite. Please check internet connection." -ForegroundColor Red
            exit 1
        }
    }

    function Initialize-DB {
        # Security: Enforce restrictive user-only ACLs on database and journals (SEC-03)
        if (-not [System.IO.File]::Exists($script:DB)) {
            try { [System.IO.File]::WriteAllBytes($script:DB, @()) } catch {}
        }
        Protect-FileAcl $script:DB
        Protect-FileAcl ($script:DB + "-wal")
        Protect-FileAcl ($script:DB + "-shm")
        if ([System.IO.File]::Exists($portableConfig)) {
            Protect-FileAcl $portableConfig
        }

        $ddl = @"
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS uploads (
    path        TEXT PRIMARY KEY,
    media_key   TEXT,
    uploaded_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE IF NOT EXISTS retry_queue (
    path         TEXT PRIMARY KEY,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_attempt TEXT
);

CREATE TABLE IF NOT EXISTS logs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    level     TEXT NOT NULL,
    message   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_logs_ts    ON logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
"@
        Invoke-SqliteQuery -DataSource $script:DB -Query $ddl | Out-Null

        # Schema migration for dual-boot cross-platform tracking and content hash verification
        try {
            Invoke-SqliteQuery -DataSource $script:DB -Query "ALTER TABLE uploads ADD COLUMN file_name TEXT;" -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        try {
            Invoke-SqliteQuery -DataSource $script:DB -Query "ALTER TABLE uploads ADD COLUMN file_size INTEGER;" -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        try {
            Invoke-SqliteQuery -DataSource $script:DB -Query "CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);" -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        try {
            Invoke-SqliteQuery -DataSource $script:DB -Query "ALTER TABLE uploads ADD COLUMN content_hash TEXT;" -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        try {
            Invoke-SqliteQuery -DataSource $script:DB -Query "CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);" -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }

    function Write-Log([string]$msg, [string]$level = "INFO") {
        $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "[$ts][$level] $msg"
        $hasMutex = $false
        try {
            $hasMutex = $script:dbMutex.WaitOne(3000)
            if ($hasMutex) {
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "INSERT INTO logs(level, message) VALUES(@lv, @m)" `
                    -SqlParameters @{ lv = $level; m = $msg } | Out-Null
            }
        } catch {}
        finally {
            if ($hasMutex) {
                try { $script:dbMutex.ReleaseMutex() } catch {}
            }
        }

        switch ($level) {
            "ERROR" { Write-Host $line -ForegroundColor Red }
            "WARN"  { Write-Host $line -ForegroundColor DarkYellow }
            "OK"    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line -ForegroundColor Gray }
        }
    }

    function Add-ToCache([string]$path, [long]$fileSize = 0, [string]$contentHash = "", [string]$fileName = "") {
        if (-not $path) { return }
        if (-not $fileName) {
            $fileName = [System.IO.Path]::GetFileName($path)
        }

        if (-not $script:history.Contains($path)) {
            while ($script:cacheQueue.Count -ge $script:MAX_CACHE_SIZE) {
                $evicted = $script:cacheQueue.Dequeue()
                if ($evicted) {
                    $null = $script:history.Remove($evicted)
                    $null = $script:pathSize.Remove($evicted)
                    $null = $script:pathHash.Remove($evicted)
                }
            }
            $script:history.Add($path) | Out-Null
            $script:cacheQueue.Enqueue($path)
        }

        if ($fileSize -gt 0) {
            $script:pathSize[$path] = $fileSize
        }
        if ($contentHash) {
            $script:pathHash[$path] = $contentHash
        }
        if ($fileName -and $fileSize -gt 0) {
            if ($script:fileLookup.Count -ge ($script:MAX_CACHE_SIZE * 2)) {
                $script:fileLookup.Clear()
            }
            $script:fileLookup.Add("$fileName|$fileSize") | Out-Null
        }
    }

    function Load-Cache {
        $totalCountRow = Invoke-SqliteQuery -DataSource $script:DB -Query "SELECT COUNT(*) AS c FROM uploads" -ErrorAction SilentlyContinue
        $totalCount = if ($totalCountRow -and $totalCountRow.c) { [int]$totalCountRow.c } else { 0 }

        # Preload the most recent items into LRU cache (bounded by MAX_CACHE_SIZE)
        $rows = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT path, file_name, file_size, content_hash FROM uploads ORDER BY uploaded_at DESC LIMIT $($script:MAX_CACHE_SIZE)"
        foreach ($r in $rows) {
            if ($r.path) {
                $fSize = if ($r.file_size) { [long]$r.file_size } else { 0 }
                $fHash = if ($r.content_hash) { [string]$r.content_hash } else { "" }
                $fName = if ($r.file_name) { [string]$r.file_name } else { "" }
                Add-ToCache -path $r.path -fileSize $fSize -contentHash $fHash -fileName $fName
            }
        }
        Write-Log "Cache loaded: $($script:history.Count) recent uploaded files ($totalCount total in database)."

        $retries = Invoke-SqliteQuery -DataSource $script:DB -Query "SELECT path, attempts FROM retry_queue"
        foreach ($r in $retries) {
            if ($r.path) {
                $alreadyUploaded = $script:history.Contains($r.path)
                if (-not $alreadyUploaded) {
                    $dbCheck = Invoke-SqliteQuery -DataSource $script:DB `
                        -Query "SELECT 1 FROM uploads WHERE path = @p LIMIT 1" `
                        -SqlParameters @{ p = $r.path } -ErrorAction SilentlyContinue
                    if ($dbCheck) { $alreadyUploaded = $true }
                }
                if (-not $alreadyUploaded) {
                    $script:retryMap[$r.path] = [int]$r.attempts
                }
            }
        }
        if ($script:retryMap.Count -gt 0) {
            Write-Log "Retry queue: $($script:retryMap.Count) file(s) pending." "WARN"
        }

        Invoke-SqliteQuery -DataSource $script:DB `
            -Query "DELETE FROM logs WHERE timestamp < datetime('now', '-$($script:LOG_RETENTION_DAYS) days')" | Out-Null
    }

    function Save-Upload([string]$path, [string]$mediaKey, [string]$fileName = "", [long]$fileSize = 0, [string]$contentHash = "") {
        if (-not $fileName) { $fileName = [System.IO.Path]::GetFileName($path) }
        if ($fileSize -le 0 -and [System.IO.File]::Exists($path)) {
            try { $fileSize = (New-Object System.IO.FileInfo($path)).Length } catch {}
        }
        if (-not $contentHash -and [System.IO.File]::Exists($path)) {
            $contentHash = Get-FileHashSafe $path
        }

        $hasMutex = $false
        $saved = $false
        try {
            $hasMutex = $script:dbMutex.WaitOne(3000)
            if ($hasMutex) {
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "INSERT OR REPLACE INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES(@p, @k, @fn, @fs, @h)" `
                    -SqlParameters @{ p = $path; k = $mediaKey; fn = $fileName; fs = $fileSize; h = $contentHash } -ErrorAction Stop | Out-Null
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "DELETE FROM retry_queue WHERE path = @p" `
                    -SqlParameters @{ p = $path } -ErrorAction SilentlyContinue | Out-Null
                $saved = $true
            } else {
                Write-Log "Database mutex timeout (3000ms) saving upload for $fileName." "ERROR"
            }
        } catch {
            Write-Log "Failed to persist upload record for $fileName to database: $_" "ERROR"
        } finally {
            if ($hasMutex) {
                try { $script:dbMutex.ReleaseMutex() } catch {}
            }
        }

        if ($saved) {
            Add-ToCache -path $path -fileSize $fileSize -contentHash $contentHash -fileName $fileName
            $null = $script:retryMap.Remove($path)
            return $true
        } else {
            Save-Retry $path 0
            return $false
        }
    }

    function Save-Retry([string]$path, [int]$attempts) {
        $hasMutex = $false
        try {
            $hasMutex = $script:dbMutex.WaitOne(3000)
            if ($hasMutex) {
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "INSERT OR REPLACE INTO retry_queue(path, attempts, last_attempt) VALUES(@p, @a, datetime('now','localtime'))" `
                    -SqlParameters @{ p = $path; a = $attempts } -ErrorAction SilentlyContinue | Out-Null
            }
            $script:retryMap[$path] = $attempts
        } finally {
            if ($hasMutex) {
                try { $script:dbMutex.ReleaseMutex() } catch {}
            }
        }
    }

    function Remove-Retry([string]$path) {
        $hasMutex = $false
        try {
            $hasMutex = $script:dbMutex.WaitOne(3000)
            if ($hasMutex) {
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "DELETE FROM retry_queue WHERE path = @p" `
                    -SqlParameters @{ p = $path } -ErrorAction SilentlyContinue | Out-Null
            }
            $null = $script:retryMap.Remove($path)
        } finally {
            if ($hasMutex) {
                try { $script:dbMutex.ReleaseMutex() } catch {}
            }
        }
    }

    # -----------------------------------------------------------------
    # 7. FILE READINESS, DEDUPLICATION & UPLOAD ENGINE
    # -----------------------------------------------------------------
    function Wait-ForFileReady([string]$path) {
        if (-not [System.IO.File]::Exists($path)) { return "NOT_FOUND" }

        $lastSize = -1

        for ($i = 0; $i -lt 30; $i++) {
            try {
                if (-not [System.IO.File]::Exists($path)) { return "NOT_FOUND" }
                $info = New-Object System.IO.FileInfo($path)

                if ($info.Length -le 0) {
                    Start-Sleep -Seconds 1
                    continue
                }

                if ($info.Length -ne $lastSize) {
                    $lastSize = $info.Length
                    $wait = if ($info.Length -ge 50MB) { 4 } else { 2 }
                    Start-Sleep -Seconds $wait
                    continue
                }

                # Verify write-exclusivity so active recordings (OBS, Game Bar) are not uploaded mid-recording
                try {
                    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    $fs.Close()
                    $fs.Dispose()
                    return "READY"
                } catch {
                    try {
                        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                        $fs.Close()
                        $fs.Dispose()
                        return "READY"
                    } catch {
                        try {
                            # Fallback for cloud-synced files (OneDrive, iCloud) where sync engine holds shared read lock
                            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                            $fs.Close()
                            $fs.Dispose()
                            return "READY"
                        } catch {}
                    }
                }
            } catch {
                Start-Sleep -Seconds 2
            }
        }
        return "LOCKED_OR_GROWING"
    }

    function Test-IsDuplicateUpload([string]$filePath) {
        # 1. Fast in-memory LRU cache check
        if ($script:history.Contains($filePath)) {
            $fiCheck = New-Object System.IO.FileInfo($filePath)
            if ($fiCheck.Exists) {
                if ($script:pathSize.ContainsKey($filePath) -and $script:pathSize[$filePath] -gt 0) {
                    if ($script:pathSize[$filePath] -ne $fiCheck.Length) {
                        $null = $script:history.Remove($filePath)
                        $null = $script:pathSize.Remove($filePath)
                        $null = $script:pathHash.Remove($filePath)
                        return $false
                    }
                }
                if ($script:pathHash.ContainsKey($filePath) -and -not [string]::IsNullOrEmpty($script:pathHash[$filePath])) {
                    $curHash = Get-FileHashSafe $filePath
                    if ($curHash -and $curHash -ne $script:pathHash[$filePath]) {
                        $null = $script:history.Remove($filePath)
                        $null = $script:pathSize.Remove($filePath)
                        $null = $script:pathHash.Remove($filePath)
                        return $false
                    }
                }
            }
            return $true
        }

        $fi = New-Object System.IO.FileInfo($filePath)
        if (-not $fi.Exists) { return $false }
        $name = $fi.Name
        $len = $fi.Length

        # 2. Database check for exact path (indexed PRIMARY KEY lookup on cache miss)
        $exactDb = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT file_size, content_hash FROM uploads WHERE path = @p LIMIT 1" `
            -SqlParameters @{ p = $filePath } -ErrorAction SilentlyContinue

        if ($exactDb) {
            $prevSize = if ($exactDb.file_size) { [long]$exactDb.file_size } else { 0 }
            $prevHash = if ($exactDb.content_hash) { [string]$exactDb.content_hash } else { "" }

            if ($prevSize -gt 0 -and $len -gt 0 -and $prevSize -ne $len) {
                return $false
            }
            if ($prevHash) {
                $curHash = Get-FileHashSafe $filePath
                if ($curHash -and $curHash -ne $prevHash) {
                    return $false
                }
            }
            # Cache the verified path in LRU cache so subsequent sweeps hit memory
            Add-ToCache -path $filePath -fileSize $len -contentHash $prevHash -fileName $name
            return $true
        }

        # 3. Dual-boot cross-platform deduplication check (matching name and size)
        $lookupKey = "$name|$len"
        $mightBeDuplicate = $script:fileLookup.Contains($lookupKey)
        if (-not $mightBeDuplicate) {
            # Check DB index idx_uploads_file on cache miss
            $dbNameCheck = Invoke-SqliteQuery -DataSource $script:DB `
                -Query "SELECT 1 FROM uploads WHERE file_name = @fn AND file_size = @fs AND file_size > 0 LIMIT 1" `
                -SqlParameters @{ fn = $name; fs = $len } -ErrorAction SilentlyContinue
            if ($dbNameCheck) {
                $mightBeDuplicate = $true
            }
        }

        if (-not $mightBeDuplicate) {
            return $false
        }

        $candidateHash = Get-FileHashSafe $filePath
        $existing = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT content_hash FROM uploads WHERE file_name = @fn AND file_size = @fs AND file_size > 0 LIMIT 1" `
            -SqlParameters @{ fn = $name; fs = $len } -ErrorAction SilentlyContinue

        $isDuplicate = $false
        if ($existing -and $existing.content_hash) {
            if ($existing.content_hash -eq $candidateHash) {
                $isDuplicate = $true
            }
        } elseif ($existing) {
            $isDuplicate = $true
            if ($candidateHash) {
                Invoke-SqliteQuery -DataSource $script:DB `
                    -Query "UPDATE uploads SET content_hash = @h WHERE file_name = @fn AND file_size = @fs AND content_hash IS NULL" `
                    -SqlParameters @{ h = $candidateHash; fn = $name; fs = $len } -ErrorAction SilentlyContinue | Out-Null
            }
        }

        if ($isDuplicate) {
            Save-Upload $filePath "DUAL_BOOT_SYNC" $name $len $candidateHash | Out-Null
            return $true
        }
        return $false
    }

    function Test-IsSymlinkOrJunction($item) {
        if (-not $item) { return $false }
        try {
            if ($item -is [string]) {
                if ([System.IO.Directory]::Exists($item)) {
                    $item = New-Object System.IO.DirectoryInfo($item)
                } elseif ([System.IO.File]::Exists($item)) {
                    $item = New-Object System.IO.FileInfo($item)
                } else {
                    return $false
                }
            }
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return $false
            }
            # Reparse point is present: distinguish true links (Symlink, Junction, MountPoint) from Cloud Sync Reparse Points (OneDrive, iCloud, etc.)
            $lt = $item.LinkType
            if ($lt -and ($lt -eq "SymbolicLink" -or $lt -eq "Junction" -or $lt -eq "MountPoint")) {
                return $true
            }
            if ($item.PSObject.Properties["LinkTarget"] -and -not [string]::IsNullOrEmpty($item.LinkTarget)) {
                return $true
            }
            if ($item.PSObject.Properties["Target"] -and $item.Target) {
                return $true
            }
            return $false
        } catch {
            return $false
        }
    }

    function Test-IsEligibleMedia([System.IO.FileInfo]$fi) {
        if (-not $script:EXT.Contains($fi.Extension.ToLower())) { return $false }
        if ($fi.FullName.Contains("\Modules\")) { return $false }
        # Security: Skip symbolic links and junction directories (SEC-05), allow cloud sync files (OneDrive, iCloud)
        if (Test-IsSymlinkOrJunction $fi) { return $false }
        try {
            if ($fi.Directory -and (Test-IsSymlinkOrJunction $fi.Directory)) { return $false }
        } catch {}
        if ($script:inFlight.Contains($fi.FullName)) { return $false }
        if (-not $ForceResync -and (Test-IsDuplicateUpload $fi.FullName)) { return $false }
        return $true
    }

    function Invoke-Upload([string]$path, [int]$current = 1, [int]$total = 1) {
        if ($path.Contains("\Modules\")) { return }
        $ext = [System.IO.Path]::GetExtension($path).ToLower()
        if (-not $script:EXT.Contains($ext)) { return }
        if (-not $ForceResync -and (Test-IsDuplicateUpload $path)) { return }

        $name = [System.IO.Path]::GetFileName($path)
        $fileInfo = New-Object System.IO.FileInfo($path)
        if (-not $fileInfo.Exists) { return }
        # Security: Skip symbolic links and junction directories (SEC-05), allow cloud sync files (OneDrive, iCloud)
        if (Test-IsSymlinkOrJunction $fileInfo) { return }
        try {
            if ($fileInfo.Directory -and (Test-IsSymlinkOrJunction $fileInfo.Directory)) { return }
        } catch {}

        if (-not $script:inFlight.Add($path)) { return }

        try {
            $fileSizeMB = [Math]::Round($fileInfo.Length / 1MB, 2)
            if ($fileSizeMB -lt 1) {
                $sizeLabel = "$([Math]::Round($fileInfo.Length / 1KB, 1)) KB"
            } else {
                $sizeLabel = "$fileSizeMB MB"
            }

            Write-Host ""
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Detected  : $name ($sizeLabel)" -ForegroundColor Cyan
            Write-Host "             Path      : $path"                               -ForegroundColor DarkGray

            $status = Wait-ForFileReady $path
            if ($status -ne "READY") {
                if ($status -eq "NOT_FOUND") {
                    Remove-Retry $path
                    return
                }

                $prev = 0
                if ($script:retryMap.ContainsKey($path)) { $prev = $script:retryMap[$path] }
                Write-Log "File still downloading or locked ($name) - remaining in queue for completion." "WARN"
                Save-Retry $path $prev
                return
            }

            # Start gotohp-cli and render live active progress bar with elapsed time
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:GOTOHP
            $uploadArgs = @()
            if ($script:CONFIG_ARGS.Count -gt 0) {
                $uploadArgs += $script:CONFIG_ARGS
            }
            $uploadArgs += @("upload", "--no-tui")
            if ($Account) {
                $uploadArgs += @("--account", $Account)
            }
            if ($ForceResync) {
                $uploadArgs += @("--force")
            }
            $uploadArgs += @($path)

            if ($psi.PSObject.Properties['ArgumentList']) {
                foreach ($arg in $uploadArgs) {
                    [void]$psi.ArgumentList.Add($arg)
                }
            } else {
                $psi.Arguments = ($uploadArgs | ForEach-Object { Format-WindowsArgument $_ }) -join " "
            }

            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            $script:currentUploadProc = $proc
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $barWidth = 14

            # Asynchronously read standard output and standard error to avoid pipe deadlocks (BUG-02)
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            $timeoutSeconds = [Math]::Max(600, [int]($fileInfo.Length / 50KB))
            $timedOut = $false

            $fileBytes = [double]$fileInfo.Length
            $isMB = $fileBytes -ge 1MB
            $unitDiv = if ($isMB) { 1MB } else { 1KB }
            $unitName = if ($isMB) { "MB" } else { "KB" }
            $totalFormatted = [Math]::Round($fileBytes / $unitDiv, 1).ToString("0.0")

            # Scale baseline speed estimation: multi-GB files estimate using realistic sustained home upload speed (e.g. 2 MB/s ~ 16 Mbps)
            # to prevent the simulated progress bar from racing to 50% and stalling
            $estSpeed = if ($fileBytes -gt 1GB) {
                2MB
            } elseif ($script:lastUploadSpeed -and $script:lastUploadSpeed -gt 0) {
                $script:lastUploadSpeed
            } else {
                3MB
            }
            $estTotalSec = [Math]::Max(3.0, $fileBytes / $estSpeed)

            try {
                while (-not $proc.WaitForExit(150)) {
                    $elapsedSec = $sw.Elapsed.TotalSeconds
                    if ($elapsedSec -ge $timeoutSeconds) {
                        $timedOut = $true
                        try {
                            $proc.Kill()
                        } catch {}
                        break
                    }

                    # Adaptive monotonic progression for smooth, realistic upload tracking without unmanaged code
                    $ratio = 0.0
                    if ($elapsedSec -lt $estTotalSec) {
                        $ratio = [Math]::Min(0.90, [Math]::Max(0.01, ($elapsedSec / $estTotalSec) * 0.90))
                    } else {
                        $overSec = $elapsedSec - $estTotalSec
                        $ratio = 0.90 + (0.09 * (1.0 - [Math]::Exp(-$overSec / [Math]::Max(30.0, $estTotalSec))))
                    }
                    $uploadedBytes = [Math]::Min($fileBytes * 0.99, $fileBytes * $ratio)

                    $pct = [Math]::Round($ratio * 100.0, 1)
                    $filled = [int][Math]::Floor($ratio * $barWidth)
                    $filled = [Math]::Max(0, [Math]::Min($barWidth, $filled))
                    $bar = ("#" * $filled) + ("-" * ($barWidth - $filled))

                    $currFormatted = [Math]::Round($uploadedBytes / $unitDiv, 1).ToString("0.0")
                    $pctStr = ($pct.ToString("0.0")).PadLeft(5)

                    $timeStr = "$([Math]::Round($elapsedSec, 1).ToString('0.0'))s"
                    $etaStr = ""
                    if ($ratio -ge 0.99) {
                        $etaStr = ", finalizing..."
                    } elseif ($ratio -gt 0.03 -and $elapsedSec -gt 0.8) {
                        $speedBytes = $uploadedBytes / $elapsedSec
                        $remainBytes = [Math]::Max(0.0, $fileBytes - $uploadedBytes)
                        if ($speedBytes -gt 1024) {
                            $remainSec = $remainBytes / $speedBytes
                            $etaStr = ", " + (Format-RemainingTime $remainSec)
                        }
                    }

                    $progLine = "  [$bar] $pctStr% | $currFormatted / $totalFormatted $unitName ($timeStr$etaStr)"
                    Safe-ConsoleWrite ($progLine.PadRight(68))
                }
            } finally {
                $script:currentUploadProc = $null
                if ([System.IO.File]::Exists($portableConfig)) {
                    Protect-FileAcl $portableConfig
                }
            }

            $stdout = ""
            $stderr = ""
            try {
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
            } catch {}

            $exitCode = if ($timedOut) { -1 } else { $proc.ExitCode }
            $totalTime = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            $doneBar = "#" * $barWidth

            $mediaKey = ""
            $cliErr = ""

            if ($stdout) {
                if ($stdout -match '"mediaKey":\s*"([^"]+)"') {
                    $mediaKey = $matches[1]
                }
                if ($stdout -match '"error":\s*"([^"]+)"') {
                    $cliErr = $matches[1]
                } elseif ($stdout -match '"message":\s*"([^"]+)"') {
                    $cliErr = $matches[1]
                }
            }
            if (-not $cliErr -and $stderr) {
                $cliErr = $stderr.Trim()
            }

            $hasExplicitSuccess = ($stdout -match '"success":\s*true') -or (-not [string]::IsNullOrEmpty($mediaKey))
            $isSuccess = ($exitCode -eq 0) -and (-not $timedOut) -and (-not $cliErr) -and $hasExplicitSuccess

            if ($isSuccess) {
                $contentHash = Get-FileHashSafe $path
                if ($totalTime -ge 1.0 -and $fileBytes -ge 1MB) {
                    $speed = $fileBytes / $totalTime
                    $script:lastUploadSpeed = [Math]::Max(200KB, [Math]::Min(200MB, ($script:lastUploadSpeed * 0.4) + ($speed * 0.6)))
                }
                $avgSpeed = if ($totalTime -gt 0 -and $fileBytes -gt 0) {
                    $speed = $fileBytes / $totalTime
                    if ($speed -ge 1MB) {
                        " ($([Math]::Round($speed / 1MB, 1)) MB/s)"
                    } else {
                        " ($([Math]::Round($speed / 1KB, 1)) KB/s)"
                    }
                } else { "" }
                Safe-ConsoleWrite ("  [$doneBar] 100.0% [OK] Uploaded in $($totalTime)s$($avgSpeed): $name ($totalFormatted $unitName)".PadRight(70))
                Write-Host ""
                Write-Log "SUCCESS | $name ($totalFormatted $unitName in $($totalTime)s$($avgSpeed))" "OK"
                Save-Upload $path $mediaKey $name $fileInfo.Length $contentHash | Out-Null
            } else {
                if ($timedOut) {
                    Safe-ConsoleWrite ("  [--------------] TIMED OUT after $($totalTime)s: $name".PadRight(70))
                    Write-Host ""
                    Write-Log "TIMEOUT | Upload exceeded ${timeoutSeconds}s threshold: $name" "ERROR"
                } else {
                    Safe-ConsoleWrite ("  [--------------] FAILED in $($totalTime)s: $name".PadRight(70))
                    Write-Host ""
                    if ($cliErr) {
                        Write-Log "CLI error for ${name}: $cliErr" "WARN"
                    }
                }

                $attempts = 1
                if ($script:retryMap.ContainsKey($path)) {
                    $attempts = $script:retryMap[$path] + 1
                }

                if ($attempts -ge $script:MAX_RETRY) {
                    Write-Log "GAVE UP after $attempts upload attempts: $name" "ERROR"
                    Remove-Retry $path
                } else {
                    $errSuffix = if ($cliErr) { " ($cliErr)" } else { "" }
                    Write-Log "FAILED upload$errSuffix (attempt $attempts/$($script:MAX_RETRY)) - queued for retry: $name" "WARN"
                    Save-Retry $path $attempts
                }
            }
        } catch {
            Write-Log "EXCEPTION for $([System.IO.Path]::GetFileName($path)): $_" "ERROR"
        } finally {
            $null = $script:inFlight.Remove($path)
        }
    }

    # -----------------------------------------------------------------
    # 8. BINARY VALIDATION, ACCOUNT CHECK & DIAGNOSTICS
    # -----------------------------------------------------------------
    if (-not [System.IO.File]::Exists($script:GOTOHP)) {
        Write-Host "ERROR: gotohp binary not found in $script:BASE or system PATH." -ForegroundColor Red
        exit 1
    }

    if ($Account) {
        Write-Host "Setting active Google Photos account to: $Account" -ForegroundColor Cyan
        & $script:GOTOHP $script:CONFIG_ARGS creds set $Account 2>&1 | Out-Null
    }

    $listArgs = $script:CONFIG_ARGS + @("creds", "list")
    $credsOutput = & $script:GOTOHP $listArgs 2>&1 | Out-String

    # Auto-recovery: If credentials exist but none has '*', activate the first available account
    if ($credsOutput -notmatch "No credentials found" -and $credsOutput -notmatch "\*") {
        if ($credsOutput -match '(?m)^\s*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})') {
            $firstAcc = $matches[1]
            Write-Host "  [Auto-Recovery] Activating Google Photos account: $firstAcc" -ForegroundColor Yellow
            & $script:GOTOHP $script:CONFIG_ARGS creds set $firstAcc 2>&1 | Out-Null
            $credsOutput = & $script:GOTOHP $listArgs 2>&1 | Out-String
        }
    }

    $hasAccount = ($credsOutput -notmatch "No credentials found") -and ($credsOutput -match "\*")
    if ($env:GOOGLEUNLIMITED_TEST_MODE -eq "1") {
        $hasAccount = $true
    }

    if (-not $hasAccount) {
        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Red
        Write-Host "  ACTION REQUIRED: No Google Account Logged In!"            -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Red
        Write-Host "  Please sign in to Google Photos first:"                  -ForegroundColor White
        Write-Host "    1. Double-click 'gotohp-x64.exe' to log in via GUI, OR" -ForegroundColor Gray
        Write-Host "    2. Run: .\gotohp-cli-x64.exe creds add"                 -ForegroundColor Gray
        Write-Host "==========================================================" -ForegroundColor Red
        Write-Host ""
        if (-not $StatusOnly) {
            exit 1
        }
    } else {
        if ($credsOutput -match '\*\s*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})') {
            Write-Host "  Active Account: $($matches[1])" -ForegroundColor Green
        }
    }

    Initialize-DB
    Load-Cache

    if ($StatusOnly) {
        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  *  Google Photos Sync Status"                             -ForegroundColor Green
        Write-Host "  Database: $script:DB"                                     -ForegroundColor Gray
        Write-Host "==========================================================" -ForegroundColor Cyan
        
        # Display active background watcher service state
        $cleanBase = $script:BASE.ToLower().Replace("\", "_").Replace(":", "").Replace(" ", "_")
        $mutexName = "Local\GoogleUnlimited_Watcher_" + $cleanBase
        $watcherRunning = $false
        try {
            $m = [System.Threading.Mutex]::OpenExisting($mutexName)
            if ($m) {
                $m.Dispose()
                $watcherRunning = $true
            }
        } catch {}

        if ($watcherRunning) {
            Write-Host "  Watcher Service State: RUNNING (Active in Background)" -ForegroundColor Green
        } else {
            Write-Host "  Watcher Service State: STOPPED (Not running)" -ForegroundColor DarkGray
        }
        Write-Host ""
        
        $totalCountRow = Invoke-SqliteQuery -DataSource $script:DB -Query "SELECT COUNT(*) AS c FROM uploads" -ErrorAction SilentlyContinue
        $totalCount = if ($totalCountRow -and $totalCountRow.c) { [int]$totalCountRow.c } else { $script:history.Count }
        $retCount   = $script:retryMap.Count
        Write-Host "  Total Uploaded Files : $totalCount" -ForegroundColor Yellow
        Write-Host "  Pending Retries      : $retCount"   -ForegroundColor $(if ($retCount -gt 0) { "Red" } else { "Green" })
        
        $recent = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT path, uploaded_at FROM uploads ORDER BY uploaded_at DESC LIMIT 10"
        if ($recent) {
            Write-Host ""
            Write-Host "  Last 10 Uploads:" -ForegroundColor Cyan
            foreach ($r in $recent) {
                $name = [System.IO.Path]::GetFileName($r.path)
                Write-Host "    [$($r.uploaded_at)] $name" -ForegroundColor Gray
            }
        }
        
        if ($retCount -gt 0) {
            Write-Host ""
            Write-Host "  Pending Retries in Queue:" -ForegroundColor DarkYellow
            foreach ($qf in $script:retryMap.Keys) {
                Write-Host "    $qf (attempt $($script:retryMap[$qf]))" -ForegroundColor DarkYellow
            }
        }
        Write-Host "==========================================================" -ForegroundColor Cyan
        return
    }

    if ($ShowLogs) {
        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "  *  Google Photos Sync - Activity Logs (Last 30)"          -ForegroundColor Green
        Write-Host "  Database: $script:DB"                                     -ForegroundColor Gray
        Write-Host "==========================================================" -ForegroundColor Cyan

        $logRows = Invoke-SqliteQuery -DataSource $script:DB `
            -Query "SELECT timestamp, level, message FROM logs ORDER BY id DESC LIMIT 30"
        if ($logRows) {
            $logArray = @($logRows)
            [Array]::Reverse($logArray)
            foreach ($l in $logArray) {
                $color = switch ($l.level) {
                    "ERROR" { "Red" }
                    "WARN"  { "DarkYellow" }
                    "OK"    { "Green" }
                    default { "Gray" }
                }
                Write-Host "[$($l.timestamp)][$($l.level)] $($l.message)" -ForegroundColor $color
            }
        } else {
            Write-Host "  No activity logs found." -ForegroundColor DarkGray
        }
        Write-Host "==========================================================" -ForegroundColor Cyan
        return
    }

    # -----------------------------------------------------------------
    # 9. STARTUP BANNER & SYNCHRONIZATION ENGINE
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  *  Google Photos Auto-Sync - gotohp (Portable Edition)"   -ForegroundColor Green
    Write-Host "  Location: $script:BASE"                                   -ForegroundColor Yellow
    Write-Host "  Database: $script:DB"                                     -ForegroundColor Gray
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Watched Folders:" -ForegroundColor DarkCyan
    foreach ($dir in $script:WATCH_DIRS) {
        Write-Host "    -> $dir" -ForegroundColor Gray
    }
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""

    # Phase 1 - Startup scan for unrecorded files
    Write-Host "[Phase 1] Scanning for unrecorded files..." -ForegroundColor Cyan

    $unrecorded = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'

    foreach ($dir in $script:WATCH_DIRS) {
        try {
            Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    -not (Test-IsSymlinkOrJunction $_) -and
                    (-not $_.Directory -or -not (Test-IsSymlinkOrJunction $_.Directory))
                } |
                Where-Object { Test-IsEligibleMedia $_ } |
                ForEach-Object { $unrecorded.Add($_) }
        } catch {
            Write-Log "Scan error in $dir - $_" "WARN"
        }
    }

    # Include pending retry queue files
    foreach ($qf in @($script:retryMap.Keys)) {
        $fi = New-Object System.IO.FileInfo($qf)
        if ($fi.Exists -and ($ForceResync -or (-not (Test-IsDuplicateUpload $qf)))) {
            $unrecorded.Add($fi)
        }
    }

    if ($unrecorded.Count -eq 0) {
        Write-Host "[Phase 1] [OK] Everything backed up - zero new files." -ForegroundColor Green
    } else {
        $total = $unrecorded.Count
        Write-Host "[Phase 1] Found $total file(s) to upload." -ForegroundColor Yellow
        $i = 0
        foreach ($f in $unrecorded) {
            $i++
            $pct = [Math]::Round(($i / $total) * 100)
            Write-Progress -Activity "Startup sync" -Status "[$i/$total] $($f.Name)" -PercentComplete $pct
            Invoke-Upload $f.FullName $i $total
        }
        Write-Progress -Activity "Startup sync" -Completed
        Write-Host "[Phase 1] [OK] Startup sync complete ($total file(s))." -ForegroundColor Green
    }

    # Phase 2 - Real-time watchers
    Write-Host ""
    Write-Host "[Phase 2] Real-time watcher active." -ForegroundColor Yellow
    Write-Host "  Waiting for new downloads... Press Ctrl+C to stop." -ForegroundColor DarkGray
    Write-Host ""

    $script:recentEvents = New-Object 'System.Collections.Generic.Dictionary[string,DateTime]' ([System.StringComparer]::OrdinalIgnoreCase)

    function Process-WatchEvent([string]$evPath) {
        if (-not $evPath) { return }
        if ([System.IO.Directory]::Exists($evPath)) { return }

        $ext = [System.IO.Path]::GetExtension($evPath).ToLower()
        if (-not $script:EXT.Contains($ext)) { return }

        # Debounce duplicate filesystem events within 1.5 seconds
        $now = [DateTime]::Now
        $shouldProcess = $false
        if ($script:recentEvents.ContainsKey($evPath)) {
            $diff = ($now - $script:recentEvents[$evPath]).TotalSeconds
            if ($diff -ge 1.5) {
                $script:recentEvents[$evPath] = $now
                $shouldProcess = $true
            }
        } else {
            $script:recentEvents[$evPath] = $now
            $shouldProcess = $true
        }

        if ($shouldProcess) {
            # Prune debouncer entries older than 60 seconds when table grows
            if ($script:recentEvents.Count -gt 200) {
                $cutoff = $now.AddSeconds(-60)
                $expiredKeys = @($script:recentEvents.Keys | Where-Object { $script:recentEvents[$_] -lt $cutoff })
                foreach ($k in $expiredKeys) {
                    $null = $script:recentEvents.Remove($k)
                }
            }
            Invoke-Upload $evPath 1 1
        }
    }

    $action = {
        try {
            $p = $Event.SourceEventArgs.FullPath
            if ($p) {
                Process-WatchEvent $p
            }
        } catch {
            Write-Log "Error processing watcher event: $_" "WARN"
        }
    }

    $script:watchers = New-Object 'System.Collections.Generic.List[System.IO.FileSystemWatcher]'

    foreach ($dir in $script:WATCH_DIRS) {
        try {
            $w = New-Object System.IO.FileSystemWatcher
            $w.Path                  = $dir
            $w.IncludeSubdirectories = $true
            $w.InternalBufferSize    = 65536
            $w.NotifyFilter          = [System.IO.NotifyFilters]::FileName -bor `
                                       [System.IO.NotifyFilters]::LastWrite -bor `
                                       [System.IO.NotifyFilters]::Size -bor `
                                       [System.IO.NotifyFilters]::CreationTime -bor `
                                       [System.IO.NotifyFilters]::DirectoryName

            Register-ObjectEvent $w 'Error' -Action {
                Write-Log "FSW buffer overflow on $($Event.Sender.Path)" "WARN"
            } | Out-Null
            Register-ObjectEvent $w 'Created' -Action $action | Out-Null
            Register-ObjectEvent $w 'Changed' -Action $action | Out-Null
            Register-ObjectEvent $w 'Renamed' -Action $action | Out-Null

            $w.EnableRaisingEvents = $true
            $script:watchers.Add($w)
        } catch {
            Write-Log "Could not watch $dir - $_" "WARN"
        }
    }

    # -----------------------------------------------------------------
    # 10. MAIN LOOP - Periodic retry flush (30s) + safety sweep (30s)
    # -----------------------------------------------------------------
    $lastSweep = [DateTime]::MinValue
    $lastRetryFlush = [DateTime]::MinValue
    while ($true) {
        Start-Sleep -Seconds 1
        $now = [DateTime]::Now

        # Periodic retry queue flush every 30 seconds
        if (($now - $lastRetryFlush).TotalSeconds -ge 30) {
            $lastRetryFlush = $now
            foreach ($qf in @($script:retryMap.Keys)) {
                $alreadyUploaded = $script:history.Contains($qf)
                if (-not $alreadyUploaded) {
                    $dbCheck = Invoke-SqliteQuery -DataSource $script:DB `
                        -Query "SELECT 1 FROM uploads WHERE path = @p LIMIT 1" `
                        -SqlParameters @{ p = $qf } -ErrorAction SilentlyContinue
                    if ($dbCheck) {
                        $alreadyUploaded = $true
                        Add-ToCache -path $qf
                    }
                }
                if ($alreadyUploaded) {
                    Remove-Retry $qf
                    continue
                }
                if ([System.IO.File]::Exists($qf)) {
                    if (-not $script:inFlight.Contains($qf)) {
                        Invoke-Upload $qf 1 1
                    }
                } else {
                    Remove-Retry $qf
                }
            }
        }

        # Recursive filesystem safety sweep every 30 seconds
        if (($now - $lastSweep).TotalSeconds -ge 30) {
            $lastSweep = $now
            foreach ($dir in $script:WATCH_DIRS) {
                try {
                    Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object {
                            -not (Test-IsSymlinkOrJunction $_) -and
                            (-not $_.Directory -or -not (Test-IsSymlinkOrJunction $_.Directory))
                        } |
                        Where-Object { Test-IsEligibleMedia $_ } |
                        ForEach-Object {
                            Write-Log "Sweep detected new file: $($_.Name)" "INFO"
                            Invoke-Upload $_.FullName 1 1
                        }
                } catch {
                    Write-Log "Sweep error in $dir - $_" "WARN"
                }
            }
        }
    }
} finally {
    if ($script:watchers) {
        foreach ($w in $script:watchers) {
            try {
                $w.EnableRaisingEvents = $false
                $w.Dispose()
            } catch {}
        }
    }
    Get-EventSubscriber -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -notlike "PowerShell*" } |
        Unregister-Event -ErrorAction SilentlyContinue

    if ($script:currentUploadProc -and -not $script:currentUploadProc.HasExited) {
        try {
            $script:currentUploadProc.Kill()
        } catch {}
        $script:currentUploadProc = $null
    }

    if ($script:hasInstanceMutex -and $script:instanceMutex) {
        try {
            $script:instanceMutex.ReleaseMutex()
        } catch {}
        $script:hasInstanceMutex = $false
    }
    if ($script:instanceMutex) {
        try {
            $script:instanceMutex.Dispose()
        } catch {}
        $script:instanceMutex = $null
    }

    if (-not ($StatusOnly -or $ShowLogs -or $CheckRunning -or $ManageDirs -or $AddWatchDir -or $RemoveWatchDir -or $ResetWatchDirs -or $ListWatchDirs -or $EnableStartup -or $DisableStartup -or $StopWatcher)) {
        Write-Host ""
        Write-Host "Watcher stopped. Database: $script:DB" -ForegroundColor Red
        if (Get-Command -Name Invoke-SqliteQuery -ErrorAction SilentlyContinue) {
            Write-Log "Watcher stopped cleanly." "INFO"
        }
    }
}
