@echo off
rem =========================================================================
rem  Setup-Telemetry.bat  -  stores the GitHub repo and token for telemetry
rem  Version 1.0.0
rem
rem  Run once, after Install.bat, from an administrator Command Prompt:
rem    cd /d %SystemDrive%\PCTune
rem    Setup-Telemetry.bat            asks for the repo and token, stores them
rem    Setup-Telemetry.bat /remove    deletes them and removes the watchdog
rem    Setup-Telemetry.bat /dryrun    walks through setup, stores nothing
rem
rem  What it does:
rem   1. Checks that Install.bat has locked the folder.
rem   2. Asks for the repo (owner/name) and a fine-grained token. The token
rem      is typed at a hidden prompt and is never shown, logged or written
rem      to any script.
rem   3. Checks with GitHub that the repo is PRIVATE and that the token can
rem      write to it, by uploading a small test file reports/.setup_<PC>.txt.
rem      It refuses a public repo.
rem   4. Encrypts the token with Windows DPAPI into token.dat, which only
rem      SYSTEM and Administrators can read, and saves the repo name in
rem      repo.txt.
rem   5. Creates the hidden watchdog task "\PCTune\PCTune Watchdog".
rem
rem  Running it again replaces the stored repo and token.
rem  To turn telemetry off without deleting anything, set DO_TELEMETRY=0 in
rem  PCTune.bat. The next daily run removes the watchdog task.
rem
rem  Run it from an open administrator prompt rather than by double-clicking,
rem  so the window stays open and you can read the result. The result is
rem  also written to Logs\Setup-Telemetry.log.
rem
rem  /dryrun (also works together with /remove):
rem    Administrator rights are still needed. Setup still asks for the repo
rem    and the token and still checks with GitHub that the repo is private,
rem    but nothing is stored: no token.dat, no repo.txt, no watchdog task,
rem    and the test file is not uploaded. With /remove it only reports what
rem    would be removed. A wrong folder, or a folder Install.bat has not
rem    locked, is a warning instead of a stop. In a folder that is not locked
rem    the token prompt is skipped: anyone who can change the scripts there
rem    could read a token typed into them. A folder that contains links stops
rem    the dry run before the log is opened. The log is
rem    DryRun\Logs\Setup-Telemetry.log, started fresh each time. Nothing is
rem    written to Logs. Telemetry.ps1 does the real work, so the dry-run
rem    behaviour of each step is its -DryRun switch.
rem
rem  Exit codes: 0 done, 1 failed, 2 unknown switch, 5 no administrator
rem  rights, 6 not in %SystemDrive%\PCTune or Install.bat has not been run
rem  (a dry run uses 6 only when the folder contains links).
rem =========================================================================

rem The path is read before delayed expansion is on, because delayed
rem expansion would remove any "!" in the folder name.
setlocal EnableExtensions DisableDelayedExpansion
set "PCTUNE_SELF=%~f0"
set "BASE=%~dp0"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"
rem The switches are read first, because a dry run may carry on from any
rem folder.
set "ALREADY_ELEVATED=0"
set "MODE=setup"
set "DRYRUN=0"
set "ARG_BAD=0"
call :parse_args %*
if "%ARG_BAD%"=="1" (
    echo ERROR: unknown switch. Use /dryrun, /remove, both, or no switch. Nothing was done.
    exit /b 2
)
set "ELEV_ARGS=/elevated"
if "%MODE%"=="remove" set "ELEV_ARGS=/elevated /remove"
if "%DRYRUN%"=="1" set "ELEV_ARGS=%ELEV_ARGS% /dryrun"
set "DRYRUN_ARG="
if "%DRYRUN%"=="1" set "DRYRUN_ARG=-DryRun"
set "LOC_WARN=0"
rem The token ends up readable by the SYSTEM task, so this only runs from
rem the folder Install.bat locked down.
if /i "%BASE%"=="%SystemDrive%\PCTune" goto :location_ok
rem A dry run stores nothing, so it only warns once the log is open.
if not "%DRYRUN%"=="1" goto :path_chars_ok
rem A dry run may start in any folder. A folder name with a bracket, &, !
rem or ^ would break the script's own command lines, so it is refused.
set "B_CHK=%BASE:(=%"
set "B_CHK=%B_CHK:)=%"
set "B_CHK=%B_CHK:&=%"
set "B_CHK=%B_CHK:!=%"
set "B_CHK=%B_CHK:^=%"
if "%B_CHK%"=="%BASE%" goto :path_chars_ok
echo(ERROR: the folder name contains a bracket, ^&, ! or ^^. Copy the files to %SystemDrive%\PCTune and run it from there. Nothing was done.
exit /b 6
:path_chars_ok
if "%DRYRUN%"=="1" set "LOC_WARN=1"
if "%DRYRUN%"=="1" goto :location_ok
echo ERROR: Setup-Telemetry.bat must be in %SystemDrive%\PCTune. It is in "%BASE%".
exit /b 6
:location_ok
setlocal EnableDelayedExpansion

set "VERSION=1.0.0"
set "SYS32=%SystemRoot%\System32"
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "HELPER=%BASE%\PCTune.ps1"
set "TELEHELPER=%BASE%\Telemetry.ps1"

rem --- Administrator rights ----------------------------------------------
"%SYS32%\fltmc.exe" >nul 2>&1
if errorlevel 1 (
    if "%ALREADY_ELEVATED%"=="1" (
        echo ERROR: administrator rights are needed and elevation failed.
        exit /b 5
    )
    rem The path is passed through an environment variable and escaped, so
    rem quotes, brackets or wildcards in it cannot change the command.
    (call)
    "%PSEXE%" -NoProfile -NonInteractive -Command "Start-Process -FilePath ([Management.Automation.WildcardPattern]::Escape($env:PCTUNE_SELF)) -ArgumentList $env:ELEV_ARGS -Verb RunAs"
    if errorlevel 1 (
        echo ERROR: the UAC prompt was cancelled or failed.
        exit /b 5
    )
    exit /b 0
)

rem A dry run may start in a folder that was never locked. The log folder and
rem the log are written as administrator, and a link planted there could send
rem them somewhere else. So the folder is scanned (read-only) before anything
rem is created in it. The scan prints to the screen, as there is no log yet.
if not "%DRYRUN%"=="1" goto :dry_scan_done
rem Without the helper the folder cannot be checked, so nothing is written.
if not exist "%HELPER%" (
    echo DRY RUN stopped: PCTune.ps1 is missing, so the folder could not be checked for links. Nothing was done.
    exit /b 6
)
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action ScanFolder -Path "%BASE%"
if errorlevel 1 (
    echo DRY RUN stopped: %BASE% contains links or could not be scanned. Nothing was done. Remove the items listed above and run it again.
    exit /b 6
)
:dry_scan_done

set "SLOG=%BASE%\Logs\Setup-Telemetry.log"
if "%DRYRUN%"=="1" set "SLOG=%BASE%\DryRun\Logs\Setup-Telemetry.log"
for %%D in ("%SLOG%") do if not exist "%%~dpD" mkdir "%%~dpD" 2>nul
if "%DRYRUN%"=="1" goto :dry_log
>>"%SLOG%" echo(|| (
    echo ERROR: cannot write to %SLOG%. Nothing was changed.
    exit /b 1
)
goto :log_ready
:dry_log
rem Started fresh each time, so the first line is always the dry-run notice.
>"%SLOG%" echo(DRY RUN: nothing was changed.|| (
    echo ERROR: cannot write to %SLOG%. Nothing was changed.
    exit /b 1
)
:log_ready
call :say "======================================================================"
call :say "PCTune %VERSION% telemetry %MODE% started on %COMPUTERNAME% by %USERNAME%"
if "%DRYRUN%"=="1" call :say "DRY RUN: nothing will be stored or changed."
if "%LOC_WARN%"=="1" call :say "WARNING: the files are in %BASE%, not in %SystemDrive%\PCTune. A real setup would stop here with exit code 6."

for %%F in (PCTune.ps1 Telemetry.ps1) do (
    if not exist "%BASE%\%%F" (
        call :say "ERROR: %%F is missing from %BASE%. Nothing was changed."
        exit /b 1
    )
)

rem --- 1. Folder must be locked by Install.bat ----------------------------
rem Storing the token in a folder normal users can change would let them
rem swap Telemetry.ps1 and read the token when the SYSTEM task runs it.
set "FOLDER_UNSAFE=0"
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action CheckFolder -Path "%BASE%" -LogFile "%SLOG%"
if errorlevel 1 if "%DRYRUN%"=="1" (
    call :say "WARNING: the folder is not protected. A real setup would stop here with exit code 6. Run Install.bat as administrator first."
    set "FOLDER_UNSAFE=1"
    goto :folder_done
)
if errorlevel 1 (
    call :say "ERROR: the folder is not protected. Run Install.bat as administrator first. Nothing was changed. See %SLOG%"
    exit /b 6
)
:folder_done

if "%MODE%"=="remove" goto :do_remove

if "!FOLDER_UNSAFE!"=="1" (
    call :say "DRYRUN: skipping the repo and token prompt, because the folder is not protected. Anyone who can change the scripts here could read a token typed into them. Run Install.bat first to test the prompt."
    goto :watchdog_step
)

rem --- 2-4. Ask, check and store ------------------------------------------
rem No -NonInteractive and no -LogFile here: the prompts need the console.
rem Telemetry.ps1 writes nothing about the token except whether it worked.
call :say "Enter the private repo as owner/name, then paste the token. The token is not shown as you type."
(call)
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%TELEHELPER%" -Action Setup -Base "%BASE%" %DRYRUN_ARG%
set "S_RC=!errorlevel!"
rem Telemetry.ps1 Setup exit codes: 0 stored, 1 failed and nothing is left
rem on disk, 3 failed after writing and token.dat could not be deleted.
if "!S_RC!"=="3" (
    call :say "ERROR: setup failed after the token was written, and token.dat could not be deleted. Run Setup-Telemetry.bat /remove, then revoke the token on GitHub. See the messages above."
    exit /b 1
)
if not "!S_RC!"=="0" (
    call :say "ERROR: setup did not finish, exit code !S_RC!. Nothing was stored. Check the repo name, that the repo is private, and that the token is a fine-grained token with Contents read and write for that repo."
    exit /b 1
)
if "%DRYRUN%"=="1" call :say "Dry run: the repo and token were checked, and NOT stored. No token.dat or repo.txt was written."
if not "%DRYRUN%"=="1" call :say "Repo and token stored. The token is encrypted in %BASE%\token.dat, readable only by SYSTEM and Administrators."

rem --- 5. Watchdog task ----------------------------------------------------
:watchdog_step
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TELEHELPER%" -Action EnsureWatchdog -Base "%BASE%" -LogFile "%SLOG%" %DRYRUN_ARG%
if errorlevel 1 (
    call :say "ERROR: the watchdog task could not be created. The next PCTune run will try again. See %SLOG%"
    exit /b 1
)
if "%DRYRUN%"=="1" goto :setup_dry_end
call :say "Watchdog task installed: \PCTune\PCTune Watchdog. It is started now, and from then on 5 minutes after each logon and daily at 12:00, hidden, at below-normal priority."
call :say "The first report is uploaded on the next daily PCTune run. Make sure DO_TELEMETRY=1 in PCTune.bat."
call :say "Telemetry setup finished."
exit /b 0

:setup_dry_end
call :say "DRYRUN: the watchdog task \PCTune\PCTune Watchdog would be created or refreshed. No task was installed."
call :say "Dry run finished. Nothing was stored or changed."
exit /b 0

:do_remove
set /a R_ERR=0
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TELEHELPER%" -Action RemoveWatchdog -Base "%BASE%" -LogFile "%SLOG%" %DRYRUN_ARG%
set "R_RC=!errorlevel!"
if "!R_RC!"=="0" (
    if "%DRYRUN%"=="1" (call :say "DRYRUN: the watchdog task would be removed. Nothing was removed.") else (call :say "Watchdog task removed.")
) else if "!R_RC!"=="2" (
    call :say "Watchdog task was not installed. Nothing to remove."
) else (
    call :say "ERROR: could not remove the watchdog task, exit code !R_RC!. See %SLOG%"
    set /a R_ERR+=1
)
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TELEHELPER%" -Action Forget -Base "%BASE%" -LogFile "%SLOG%" %DRYRUN_ARG%
set "R_RC=!errorlevel!"
if "!R_RC!"=="0" (
    if "%DRYRUN%"=="1" (call :say "DRYRUN: the token and repo name would be deleted. Nothing was deleted.") else (call :say "Token and repo name deleted from this laptop.")
) else if "!R_RC!"=="2" (
    call :say "No token was stored. Nothing to delete."
) else (
    call :say "ERROR: could not delete the token, exit code !R_RC!. Delete %BASE%\token.dat by hand. See %SLOG%"
    set /a R_ERR+=1
)
if "%DRYRUN%"=="1" call :say "Dry run finished. Nothing was removed or changed."
if "%DRYRUN%"=="1" goto :remove_end
call :say "Revoke the token on GitHub too: Settings, Developer settings, Personal access tokens. Deleting the file does not stop it working, and System Restore points or backups made while it was stored may still hold an encrypted copy."
call :say "Set DO_TELEMETRY=0 in PCTune.bat as well, or the daily run will report that telemetry is not set up."
:remove_end
if !R_ERR! GTR 0 exit /b 1
exit /b 0

:parse_args
rem Only /elevated, /remove and /dryrun are accepted. Anything else, an empty
rem "" included, sets ARG_BAD and setup stops, so a typo such as /dryrn can
rem never start a real setup.
if [%1]==[] exit /b 0
set "ARG_KNOWN=0"
if /i "%~1"=="/elevated" (set "ALREADY_ELEVATED=1" & set "ARG_KNOWN=1")
if /i "%~1"=="/remove"   (set "MODE=remove" & set "ARG_KNOWN=1")
if /i "%~1"=="/dryrun"   (set "DRYRUN=1" & set "ARG_KNOWN=1")
if "%ARG_KNOWN%"=="0" set "ARG_BAD=1"
shift
goto :parse_args

:say
rem Show a line on screen and copy it to the setup log. %~1 strips the
rem outer quotes.
echo(%~1
>>"%SLOG%" echo(%DATE% %TIME%  %~1
exit /b 0
