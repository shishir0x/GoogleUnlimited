@echo off
title Google Unlimited Photos Auto-Sync
cd /d "%~dp0"

set "PS_CMD=powershell.exe -NoProfile -ExecutionPolicy Bypass"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 set "PS_CMD=pwsh.exe -NoProfile -ExecutionPolicy Bypass"

set "CLI_BIN="
if exist "%~dp0gotohp-cli-x64.exe" set "CLI_BIN=%~dp0gotohp-cli-x64.exe"
if not defined CLI_BIN if exist "%~dp0gotohp-cli.exe" set "CLI_BIN=%~dp0gotohp-cli.exe"
if not defined CLI_BIN if exist "%~dp0gotohp-x64.exe" set "CLI_BIN=%~dp0gotohp-x64.exe"
if not defined CLI_BIN if exist "%~dp0gotohp.exe" set "CLI_BIN=%~dp0gotohp.exe"

set "CFG_ARG="
if exist "%~dp0gotohp.config" set "CFG_ARG=--config "%~dp0gotohp.config""

set "IS_MENU=0"
if "%~1"=="" (
    set "IS_MENU=1"
    goto menu
) else (
    goto handle_arg
)

:menu
cls
set "STARTUP_LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\GoogleUnlimited.lnk"
set "BOOT_STATUS=[Status: DISABLED]"
if exist "%STARTUP_LNK%" set "BOOT_STATUS=[Status: ENABLED]"

echo ==========================================================
echo   *  Google Unlimited Photos Auto-Sync (Windows)
echo ==========================================================
echo   [1] Start Live Watcher (Interactive progress)
echo   [2] Start Background Watcher (Silent, zero window)
echo   [3] Check Backup Status
echo   [4] View Activity Logs
echo   [5] Enable Auto-Start on Windows Boot   %BOOT_STATUS%
echo   [6] Disable Auto-Start on Windows Boot
echo   [7] Stop Background Watcher
echo   [8] Manage Watched Folders (Add/List custom folders)
echo   [9] Manage Google Accounts (List/Switch account)
echo   [10] Force Re-scan ^& Sync All Media
echo   [11] Check / Update Application (Keep configs safe)
echo   [0] Exit
echo ==========================================================
set "choice="
set /p "choice=Select an option [1-11, Default: 1]: "
if "%choice%"=="" set "choice=1"
if "%choice%"=="1" goto run_watcher
if "%choice%"=="2" goto run_silent
if "%choice%"=="3" goto check_status
if "%choice%"=="4" goto view_logs
if "%choice%"=="5" goto enable_startup
if "%choice%"=="6" goto disable_startup
if "%choice%"=="7" goto stop_watcher
if "%choice%"=="8" goto manage_folders
if "%choice%"=="9" goto manage_account
if "%choice%"=="10" goto force_resync
if "%choice%"=="11" goto update_app
if "%choice%"=="0" exit /b 0
echo Invalid option.
timeout /t 2 >nul 2>&1 || ping -n 3 127.0.0.1 >nul
goto menu

:handle_arg
set "arg=%~1"
if /i "%arg%"=="watch" goto run_watcher_arg
if /i "%arg%"=="run" goto run_watcher_arg
if /i "%arg%"=="1" goto run_watcher_arg
if /i "%arg%"=="silent" goto run_silent
if /i "%arg%"=="bg" goto run_silent
if /i "%arg%"=="2" goto run_silent
if /i "%arg%"=="status" goto check_status
if /i "%arg%"=="3" goto check_status
if /i "%arg%"=="logs" goto view_logs
if /i "%arg%"=="log" goto view_logs
if /i "%arg%"=="4" goto view_logs
if /i "%arg%"=="enable" goto enable_startup
if /i "%arg%"=="enable-startup" goto enable_startup
if /i "%arg%"=="5" goto enable_startup
if /i "%arg%"=="disable" goto disable_startup
if /i "%arg%"=="disable-startup" goto disable_startup
if /i "%arg%"=="6" goto disable_startup
if /i "%arg%"=="stop" goto stop_watcher
if /i "%arg%"=="7" goto stop_watcher
if /i "%arg%"=="dirs" goto manage_folders
if /i "%arg%"=="folders" goto manage_folders
if /i "%arg%"=="8" goto manage_folders
if /i "%arg%"=="account" goto manage_account
if /i "%arg%"=="creds" goto manage_account
if /i "%arg%"=="9" goto manage_account
if /i "%arg%"=="resync" goto force_resync
if /i "%arg%"=="force" goto force_resync
if /i "%arg%"=="10" goto force_resync
if /i "%arg%"=="update" goto update_app
if /i "%arg%"=="upgrade" goto update_app
if /i "%arg%"=="11" goto update_app
echo Unknown argument: %arg%
echo Usage: GoogleUnlimited.bat [watch^|silent^|status^|logs^|enable^|disable^|stop^|dirs^|account^|resync^|update]
exit /b 1

:run_watcher
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1"
if "%IS_MENU%"=="1" pause
if "%IS_MENU%"=="1" goto menu
exit /b %ERRORLEVEL%

:run_watcher_arg
set "EXTRA_ARGS="
:strip_loop
shift
if "%~1"=="" goto run_watcher_exec
if not defined EXTRA_ARGS (
    set "EXTRA_ARGS="%~1""
) else (
    set "EXTRA_ARGS=%EXTRA_ARGS% "%~1""
)
goto strip_loop

:run_watcher_exec
if defined EXTRA_ARGS (
    %PS_CMD% -File "%~dp0WatchAndUpload.ps1" %EXTRA_ARGS%
) else (
    %PS_CMD% -File "%~dp0WatchAndUpload.ps1"
)
exit /b %ERRORLEVEL%

:run_silent
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -CheckRunning >nul 2>&1
if errorlevel 1 goto do_launch_silent
echo ==========================================================
echo   *  Google Unlimited Photos Auto-Sync
echo ==========================================================
echo [INFO] Google Photos background watcher is ALREADY running.
echo        No need to start duplicate instance.
echo ==========================================================
if "%IS_MENU%"=="1" pause
if "%IS_MENU%"=="1" goto menu
exit /b 0

:do_launch_silent
echo Launching Google Photos watcher in silent background mode...
%PS_CMD% -Command "Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%~dp0WatchAndUpload.ps1""' -WindowStyle Hidden"
echo [OK] Background watcher launched.
if "%IS_MENU%"=="1" timeout /t 3 >nul 2>&1
if "%IS_MENU%"=="1" goto menu
exit /b 0

:check_status
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -StatusOnly
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:view_logs
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -ShowLogs
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:enable_startup
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -EnableStartup
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:disable_startup
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -DisableStartup
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:stop_watcher
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -StopWatcher
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:manage_folders
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -ManageDirs
if "%IS_MENU%"=="1" goto menu
exit /b %ERRORLEVEL%

:manage_account
cls
echo ==========================================================
echo   *  Google Photos Account Management
echo ==========================================================
if defined CLI_BIN (
    "%CLI_BIN%" %CFG_ARG% creds list
) else (
    echo gotohp-cli executable not found.
)
echo.
echo Options:
echo   [1] Switch active account
echo   [2] Add account via GUI (gotohp-x64.exe)
echo   [0] Back to main menu
echo ==========================================================
set "acchoice="
set /p "acchoice=Select an option [0-2]: "
if "%acchoice%"=="1" goto switch_account
if "%acchoice%"=="2" goto open_account_gui
if "%acchoice%"=="0" goto menu
echo Invalid option.
timeout /t 2 >nul 2>&1 || ping -n 3 127.0.0.1 >nul
goto manage_account

:switch_account
echo.
set "acemail="
set /p "acemail=Enter email address to set active: "
if not defined acemail goto manage_account
:: Sanitize metacharacters and quotes to prevent command injection
set "acemail=%acemail:&=%"
set "acemail=%acemail:|=%"
set "acemail=%acemail:<=%"
set "acemail=%acemail:>=%"
set "acemail=%acemail:^=%"
set "acemail=%acemail:"=%"
if not "%acemail%"=="" if defined CLI_BIN (
    "%CLI_BIN%" %CFG_ARG% creds set "%acemail%"
)
pause
goto manage_account

:open_account_gui
if exist "%~dp0gotohp-x64.exe" start "" "%~dp0gotohp-x64.exe"
pause
goto manage_account

:force_resync
if "%IS_MENU%"=="1" cls
echo Starting full scan ^& force re-sync of all media...
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -ForceResync
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%

:update_app
if "%IS_MENU%"=="1" cls
%PS_CMD% -File "%~dp0WatchAndUpload.ps1" -UpdateApp
if "%IS_MENU%"=="1" (pause & goto menu)
exit /b %ERRORLEVEL%
