@echo off
rem =========================================================================
rem  Install.bat  -  installs the PCTune scheduled task
rem  Version 1.0.0
rem
rem  What it does:
rem   1. Checks that the files are in %SystemDrive%\PCTune and that this is
rem      Windows 11.
rem   2. Checks the folder for junctions, symbolic links and hard links,
rem      locks the top folder, checks again, then locks everything inside so
rem      only SYSTEM and Administrators can change it.
rem      Everyone else gets read-only access, except the telemetry token and
rem      data, which only SYSTEM and Administrators can read. The result is
rem      checked.
rem   3. Registers the task "\PCTune\PCTune Daily Maintenance". It runs as
rem      SYSTEM at logon, 3 minutes delayed, on mains or battery.
rem
rem  Why step 2 matters: the task runs PCTune.bat with full SYSTEM rights. If
rem  a normal user could edit that file, they could make Windows run any
rem  command as SYSTEM. New folders on the root of C: are editable by every
rem  signed-in user by default, so the permissions are reset here.
rem  A link inside the folder could point the permission change at a file
rem  elsewhere on the disk, so the folder is scanned for links first and the
rem  install stops if any are found.
rem
rem  The task is invisible because SYSTEM tasks run in session 0, which has
rem  no desktop. There is no window and no flash, and no wrapper is needed.
rem
rem  Safe to run again. It re-applies the permissions and replaces the task.
rem  It does not run any maintenance itself.
rem
rem  Telemetry is set up separately with Setup-Telemetry.bat, after this.
rem
rem  Install.bat /dryrun
rem    Shows what an install would do and changes nothing. Administrator
rem    rights are still needed. The checks that only read run for real: the
rem    file list, the Windows build, the link scan and the permission check.
rem    Creating folders, setting the owner, locking the folder, resetting
rem    the permissions, protecting the token and registering the task are
rem    not done. Each one logs a "DRYRUN: would ..." line instead.
rem    A wrong folder is a warning, and the permission check is shown as
rem    information, because it is expected to fail before a real install.
rem    The log is DryRun\Logs\Install.log, started fresh each time. Nothing
rem    is written to Logs.
rem
rem  Exit codes: 0 installed (or the dry run finished), 1 failed (a dry run
rem  also stops with 1 if the folder contains links), 2 unknown switch,
rem  4 not Windows 11, 5 no administrator rights, 6 not in
rem  %SystemDrive%\PCTune (not used by a dry run).
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
set "DRYRUN=0"
set "ARG_BAD=0"
call :parse_args %*
if "%ARG_BAD%"=="1" (
    echo ERROR: unknown switch. Use /dryrun or no switch. Nothing was done.
    exit /b 2
)
set "ELEV_ARGS=/elevated"
if "%DRYRUN%"=="1" set "ELEV_ARGS=/elevated /dryrun"
set "DRYRUN_ARG="
if "%DRYRUN%"=="1" set "DRYRUN_ARG=-DryRun"
set "LOC_WARN=0"
rem --- 1. Location ---------------------------------------------------------
rem The folder must be on the root of the system drive. In a user-owned
rem location such as Downloads, the user could rename the whole folder and
rem put their own PCTune.bat in its place, even after the permission lock.
rem This is checked before anything else, so nothing is written elsewhere.
if /i "%BASE%"=="%SystemDrive%\PCTune" goto :location_ok
rem A dry run changes nothing, so it only warns once the log is open.
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
echo ERROR: the files must be in %SystemDrive%\PCTune. They are in "%BASE%".
echo Move the PCTune folder to %SystemDrive%\PCTune and run Install.bat again.
exit /b 6
:location_ok
setlocal EnableDelayedExpansion

set "VERSION=1.0.0"
set "SYS32=%SystemRoot%\System32"
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "ICACLS=%SYS32%\icacls.exe"
set "REGEXE=%SYS32%\reg.exe"
set "FINDSTR=%SYS32%\findstr.exe"
set "HELPER=%BASE%\PCTune.ps1"
set "TASK_NAME=\PCTune\PCTune Daily Maintenance"

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

rem --- Links, before anything is written -----------------------------------
rem The log and the folders below are written as administrator. A link
rem planted in the folder could send them to a file elsewhere, so the folder
rem is scanned first (read-only). There is no log yet, so the scan prints to
rem the screen. Step 4b scans again, after the top folder is locked.
if not exist "%HELPER%" (
    echo ERROR: PCTune.ps1 is missing from %BASE%. Nothing was changed.
    exit /b 1
)
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action ScanFolder -Path "%BASE%"
if errorlevel 1 (
    echo ERROR: the folder contains links or items that could not be checked. Nothing was changed.
    echo Delete the PCTune folder, copy fresh files to %BASE% from an administrator account, and run Install.bat again.
    exit /b 1
)

rem --- Install log ---------------------------------------------------------
set "ILOG=%BASE%\Logs\Install.log"
if "%DRYRUN%"=="1" set "ILOG=%BASE%\DryRun\Logs\Install.log"
for %%D in ("%ILOG%") do if not exist "%%~dpD" mkdir "%%~dpD" 2>nul
if "%DRYRUN%"=="1" goto :dry_log
>>"%ILOG%" echo(|| (
    echo ERROR: cannot write to %ILOG%. Task not installed.
    exit /b 1
)
goto :log_ready
:dry_log
rem Started fresh each time, so the first line is always the dry-run notice.
>"%ILOG%" echo(DRY RUN: nothing was changed.|| (
    echo ERROR: cannot write to %ILOG%. Nothing was changed.
    exit /b 1
)
:log_ready
call :say "======================================================================"
call :say "PCTune %VERSION% install started on %COMPUTERNAME% by %USERNAME%"
if "%DRYRUN%"=="1" call :say "DRY RUN: nothing will be changed."
if "%LOC_WARN%"=="1" call :say "WARNING: the files are in %BASE%, not in %SystemDrive%\PCTune. A real install would stop here with exit code 6."

rem --- 2. Files ------------------------------------------------------------
for %%F in (PCTune.bat PCTune.ps1 Uninstall.bat Telemetry.ps1 Setup-Telemetry.bat) do (
    if not exist "%BASE%\%%F" (
        call :say "ERROR: %%F is missing from %BASE%."
        exit /b 1
    )
)

rem --- 3. Windows 11 -------------------------------------------------------
rem Windows 11 starts at build 22000. The version number still says 10.0.
set "OS_BUILD="
for /f "tokens=3" %%B in ('%REGEXE% query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| %FINDSTR% /i "REG_SZ"') do set "OS_BUILD=%%B"
set "OS_BUILD_NUM=0"
rem %OS_BUILD% and not !OS_BUILD!: each side of a pipe runs in a new cmd
rem without delayed expansion.
echo(%OS_BUILD%| "%FINDSTR%" /r /x "[0-9][0-9]*" >nul && set /a OS_BUILD_NUM=OS_BUILD
if !OS_BUILD_NUM! LSS 22000 (
    call :say "ERROR: Windows 11 is required, build 22000 or newer. Found build: !OS_BUILD!"
    exit /b 4
)
call :say "Windows build !OS_BUILD! OK."

rem --- 4. Folders and permissions ------------------------------------------
if "%DRYRUN%"=="1" call :say "DRYRUN: would create the folders Logs, State and Backup in %BASE% if they are missing."
if "%DRYRUN%"=="1" goto :folders_done
for %%D in (Logs State Backup) do if not exist "%BASE%\%%D\" mkdir "%BASE%\%%D" 2>nul
:folders_done

rem 4a. Replace the top folder's permissions with exactly these, with
rem inheritance from the drive root switched off:
rem   SYSTEM          S-1-5-18      full control
rem   Administrators  S-1-5-32-544  full control
rem   Users           S-1-5-32-545  read and run, so the logs can be read
rem SIDs are used instead of names because group names change with the
rem Windows language. This is done by the helper with one security
rem descriptor, so there is no moment where the folder has a partial list.
rem It comes first so a normal user can no longer add items to the top
rem folder while the steps below run. The helper refuses a folder that is
rem itself a link.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action LockFolder -Path "%BASE%" -LogFile "%ILOG%" %DRYRUN_ARG%
if errorlevel 1 (
    call :say "ERROR: could not set folder permissions. Task not installed. See %ILOG%"
    exit /b 1
)

rem 4b. Look for junctions, symbolic links and hard links again, now that no
rem one else can add items to the top folder, and before the owner and the
rem permissions inside are changed. icacls /T and /reset follow what they
rem find, so a link planted here could hand control of a file outside the
rem folder to the user who planted it.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action ScanFolder -Path "%BASE%" -LogFile "%ILOG%"
if errorlevel 1 if "%DRYRUN%"=="1" (
    call :say "WARNING: the folder contains links or items that could not be checked. A real install would stop here. See %ILOG%"
    goto :scan_done
)
if errorlevel 1 (
    call :say "ERROR: the folder contains links or items that could not be checked. Task not installed. See %ILOG%"
    call :say "Delete the PCTune folder, copy fresh files to %BASE% from an administrator account, and run Install.bat again."
    exit /b 1
)
:scan_done

rem 4c. Make the Administrators group the owner of everything. The owner of
rem a file can always change its permissions, so a normal user who copied
rem the files in would otherwise still be able to unlock them.
if "%DRYRUN%"=="1" call :say "DRYRUN: would make Administrators the owner of everything in %BASE% (icacls /setowner)."
if "%DRYRUN%"=="1" goto :owner_done
(call)
"%ICACLS%" "%BASE%" /setowner *S-1-5-32-544 /T /C /Q >>"%ILOG%" 2>&1
if errorlevel 1 (
    call :say "ERROR: could not set the folder owner. Task not installed."
    exit /b 1
)
:owner_done

rem 4d. Reset everything inside so it only inherits the rules above. This
rem removes any extra permission someone added to a single file.
rem The telemetry token (token.dat), repo.txt and the Telemetry folder are
rem left out. They have their own stricter permissions (SYSTEM and
rem Administrators only), and a reset would give Users read access to the
rem token, even if only until step 4d2 runs.
set "RESET_FAIL=0"
if "%DRYRUN%"=="1" goto :dry_reset
for /f "delims=" %%I in ('dir /b /a "%BASE%" 2^>nul') do (
    if /i not "%%I"=="token.dat" if /i not "%%I"=="repo.txt" if /i not "%%I"=="Telemetry" (
        (call)
        "%ICACLS%" "%BASE%\%%I" /reset /T /C /Q >>"%ILOG%" 2>&1
        if errorlevel 1 set "RESET_FAIL=1"
    )
)
goto :reset_check
:dry_reset
rem Only the number is shown. File names are not passed to the log line.
set /a RESET_N=0
for /f "delims=" %%I in ('dir /b /a "%BASE%" 2^>nul') do if /i not "%%I"=="token.dat" if /i not "%%I"=="repo.txt" if /i not "%%I"=="Telemetry" set /a RESET_N+=1
call :say "DRYRUN: would reset the permissions of !RESET_N! items in %BASE% and everything inside them, leaving out token.dat, repo.txt and Telemetry."
:reset_check
if "%RESET_FAIL%"=="1" (
    call :say "ERROR: could not reset permissions on the files. Task not installed."
    exit /b 1
)

rem 4d2. Lock token.dat, repo.txt and Telemetry\ to SYSTEM and Administrators
rem only, and create Telemetry\ with those permissions if it is missing.
rem If this fails, the token is deleted rather than left with permissions
rem that were not checked. Run Setup-Telemetry.bat again afterwards.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BASE%\Telemetry.ps1" -Action Protect -Base "%BASE%" -LogFile "%ILOG%" %DRYRUN_ARG%
rem In a dry run a failure must never delete the token, so it only warns.
if errorlevel 1 if "%DRYRUN%"=="1" (
    call :say "WARNING: the dry-run token protection check failed. A real install would delete token.dat here. Nothing was deleted. See %ILOG%"
    goto :protect_done
)
if errorlevel 1 (
    if exist "%BASE%\token.dat" del /f /q "%BASE%\token.dat" >>"%ILOG%" 2>&1
    if exist "%BASE%\token.dat" (
        call :say "ERROR: could not protect the telemetry token, and could not delete %BASE%\token.dat. Delete it by hand and revoke the token on GitHub. Task not installed. See %ILOG%"
    ) else (
        call :say "ERROR: could not protect the telemetry token and data. The token was deleted to be safe. Task not installed. See %ILOG%"
    )
    exit /b 1
)
:protect_done

rem 4e. Check the result: owners, no write access for anyone else, and still
rem no links. PCTune.bat runs the same check at the start of every run.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action CheckFolder -Path "%BASE%" -LogFile "%ILOG%"
if "%DRYRUN%"=="1" goto :dry_check
if errorlevel 1 (
    call :say "ERROR: the folder permissions did not check out after locking. Task not installed. See %ILOG%"
    exit /b 1
)
call :say "Folder permissions locked and checked: SYSTEM and Administrators full control, Users read-only."
goto :check_done
:dry_check
rem Nothing was locked in a dry run, so a failure here is expected before the
rem first real install. It is reported as information only.
if errorlevel 1 (
    call :say "INFO: the folder does not pass the permission check yet. That is expected before a real install, which locks it first."
) else (
    call :say "INFO: the folder already passes the permission check."
)
:check_done

rem --- 5. Scheduled task ---------------------------------------------------
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action RegisterTask -ScriptPath "%BASE%\PCTune.bat" -LogFile "%ILOG%" %DRYRUN_ARG%
if errorlevel 1 (
    call :say "ERROR: the scheduled task could not be registered. See %ILOG%"
    exit /b 1
)
if "%DRYRUN%"=="1" call :say "Dry run finished. Nothing was changed. Log: %ILOG%"
if "%DRYRUN%"=="1" exit /b 0
call :say "Scheduled task installed: %TASK_NAME%"
call :say "It runs at logon, 3 minutes delayed, once per day, hidden."
rem This line is written directly, because the quotes in the command cannot
rem be passed through :say.
echo Test it now with:  schtasks /run /tn "%TASK_NAME%"
>>"%ILOG%" echo(%DATE% %TIME%  Test it now with:  schtasks /run /tn "%TASK_NAME%"
call :say "Then read %BASE%\LastRun.txt and the log in %BASE%\Logs"
call :say "Telemetry: if it is not set up yet, run Setup-Telemetry.bat as administrator. See README.txt."
call :say "Install finished."
exit /b 0

:parse_args
rem Only /elevated and /dryrun are accepted. Anything else, an empty ""
rem included, sets ARG_BAD and the install stops, so a typo such as /dryrn
rem can never start a real install.
if [%1]==[] exit /b 0
set "ARG_KNOWN=0"
if /i "%~1"=="/elevated" (set "ALREADY_ELEVATED=1" & set "ARG_KNOWN=1")
if /i "%~1"=="/dryrun"   (set "DRYRUN=1" & set "ARG_KNOWN=1")
if "%ARG_KNOWN%"=="0" set "ARG_BAD=1"
shift
goto :parse_args

:say
rem Show a line on screen and copy it to the install log. %~1 strips the
rem outer quotes.
echo(%~1
>>"%ILOG%" echo(%DATE% %TIME%  %~1
exit /b 0
