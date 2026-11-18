@echo off
rem =========================================================================
rem  PCTune.bat  -  maintenance for a Windows 11 laptop with an SSD
rem  Version 1.0.0
rem
rem  Built for a scheduled task that runs as SYSTEM, hidden, once a day at
rem  logon. It can also be run by hand from an admin prompt.
rem
rem  Usage:
rem    PCTune.bat               manual run, always runs
rem    PCTune.bat /scheduled    used by the scheduled task, skips if it
rem                             already ran today
rem    PCTune.bat /weekly       also run the weekly jobs now, whatever the
rem                             last-run dates say
rem    PCTune.bat /dryrun       show what a run would do, change nothing
rem
rem  /dryrun (admin rights are still needed, for the read-only health checks):
rem    Every step that changes something logs "DRYRUN: would ..." and does
rem    nothing. The read-only parts run for real: the system checks, the free
rem    space, the health report, and the telemetry report build. Telemetry.ps1
rem    gets -DryRun, and its watchdog samples 3 times in the foreground, which
rem    takes about 3 minutes. Nothing is uploaded or stored.
rem    Every step is shown, whatever the once-a-day and weekly dates say, and
rem    those dates are not written. Nothing is written to Logs, State, Backup
rem    or LastRun.txt. Everything goes under DryRun instead:
rem      DryRun\Logs\PCTune_DryRun.log   the log, started fresh each run
rem      DryRun\LastRun.txt              the summary
rem      DryRun\Work                     temporary files and the lock folder
rem      DryRun\samples, DryRun\reports telemetry samples and the report
rem    A wrong folder, or a folder that is not locked, is a warning instead of
rem    a stop, so the suite can be tried before Install.bat. A normal run is
rem    not changed by any of this.
rem
rem  Every step logs its result and the script carries on if a step fails.
rem  Exit code: 0 = all steps OK or skipped, 1 = one or more steps failed,
rem             2 = unknown switch, nothing was done,
rem             3 = could not start logging, 4 = not Windows 11,
rem             5 = could not get administrator rights,
rem             6 = not in %SystemDrive%\PCTune, or the folder is not
rem                 protected (run Install.bat first).
rem  A dry run uses the same codes. It stops with 6 only when the folder
rem  contains links or could not be scanned for them.
rem
rem  The PowerShell parts live in PCTune.ps1 next to this file. They are
rem  kept separate because batch cannot safely do things like event log
rem  queries, restore point checks or junction-safe deletion.
rem =========================================================================

rem The script's own path is read before delayed expansion is switched on,
rem because a "!" in a path would be lost once it is on.
setlocal EnableExtensions DisableDelayedExpansion
set "PCTUNE_SELF=%~f0"
set "BASE=%~dp0"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"
rem The switches are read here, ahead of the location check, because a dry
rem run is allowed to carry on from any folder.
set "DRYRUN=0"
set "MODE_SCHEDULED=0"
set "FORCE_WEEKLY=0"
set "ALREADY_ELEVATED=0"
set "ARG_BAD=0"
call :parse_args %*
if "%ARG_BAD%"=="1" (
    echo(ERROR: unknown switch. Use /dryrun, /weekly, /scheduled or no switch. Nothing was done.
    exit /b 2
)
rem The task runs this file as SYSTEM. Anywhere other than the protected
rem folder on the system drive, a normal user might be able to swap it.
if /i "%BASE%"=="%SystemDrive%\PCTune" goto :location_ok
rem A dry run changes nothing, so it goes on from any folder. A warning is
rem logged once the log exists.
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
if "%DRYRUN%"=="1" goto :location_ok
echo(ERROR: PCTune must be run from %SystemDrive%\PCTune. Nothing was done.
exit /b 6
:location_ok
setlocal EnableDelayedExpansion

rem =========================================================================
rem  CONFIG  -  1 = on, 0 = off
rem =========================================================================

rem Create a System Restore point before any change. Strongly recommended.
set "DO_RESTORE_POINT=1"
rem If the restore point fails, skip the steps that change settings
rem (power plan, Fast Startup, network reset). Cleanup and the report still
rem run, because a restore point would not bring deleted temp files back
rem anyway.
set "REQUIRE_RESTORE_POINT=1"
rem Turn System Protection on for the system drive if it is off. Without it
rem no restore point can be made. It uses a slice of disk space that
rem Windows manages by itself.
set "ENABLE_SYSTEM_PROTECTION=1"

rem Daily: user and Windows temp files plus old error reports.
set "DO_CLEANUP=1"
rem Daily: Windows Update download cache, the Download subfolder only.
set "DO_WU_CACHE=1"
rem Daily: Delivery Optimization cache, the update-sharing cache.
set "DO_DO_CACHE=1"

rem Weekly: DISM /StartComponentCleanup, removes superseded update files.
set "DO_COMPONENT_CLEANUP=1"
rem Weekly: TRIM the SSD with defrag /L. It never runs a full defrag.
set "DO_TRIM=1"
rem Weekly: delete the thumbnail cache. Frees space only, no speed gain.
set "DO_THUMBNAILS=1"
rem Weekly: chkdsk /scan. Online, read-mostly, no reboot, no /f.
set "DO_CHKDSK_SCAN=1"
rem Weekly: DISM /RestoreHealth followed by sfc /scannow.
set "DO_HEALTH_REPAIR=1"

rem Use Balanced if High performance, Ultimate or Power saver is active, and
rem stop the SSD powering down while on mains power.
set "DO_POWER=1"
rem Fast Startup is always checked and reported. Set this to 1 to switch it
rem on if it is off. See :step_faststartup for the reasons.
set "DO_FASTSTARTUP_ENABLE=0"

rem Flush the DNS cache. Harmless, but it does nothing for boot speed.
set "DO_DNS_FLUSH=0"
rem Reset Winsock and the IP stack. Only for broken networking. It is
rem honoured on manual runs only, never from the scheduled task, and it
rem needs a restart afterwards.
set "DO_NETWORK_RESET=0"

rem Write the health report into the log.
set "DO_HEALTH_REPORT=1"

rem Telemetry: once a day, upload a health snapshot (disk, RAM, CPU,
rem processes, startup apps, programs, drivers, updates, errors) to the
rem owner's PRIVATE GitHub repo, and run a small background watchdog that
rem samples CPU and RAM every 60 seconds. No passwords, browser data, files,
rem screenshots, keystrokes or Wi-Fi keys are collected. Needs a one-off
rem Setup-Telemetry.bat first. 0 = off: nothing is collected or uploaded and
rem the watchdog task is removed on the next run.
set "DO_TELEMETRY=1"

rem Temp files newer than this many days are left alone, because a running
rem installer or app may still need them.
set "TEMP_MIN_AGE_DAYS=2"
rem How often the weekly jobs run, in days.
set "WEEKLY_INTERVAL_DAYS=7"
rem How many daily log files to keep.
set "LOG_KEEP=30"

rem =========================================================================
rem  FIXED VALUES  -  no need to edit below this line
rem =========================================================================

set "PCTUNE_VERSION=1.0.0"
set "SELF=%PCTUNE_SELF%"
set "HELPER=%BASE%\PCTune.ps1"
set "TELEHELPER=%BASE%\Telemetry.ps1"
set "LOGDIR=%BASE%\Logs"
set "STATE=%BASE%\State"
set "BACKUP=%BASE%\Backup"
set "LASTRUN=%BASE%\LastRun.txt"
set "DRYRUN_ARG="
rem A dry run keeps its files apart from the real ones. Work holds the temp
rem files and the lock folder. Backup points at Work too, so a missed guard
rem could never touch the real Backup folder.
if "%DRYRUN%"=="1" set "LOGDIR=%BASE%\DryRun\Logs"
if "%DRYRUN%"=="1" set "STATE=%BASE%\DryRun\Work"
if "%DRYRUN%"=="1" set "BACKUP=%BASE%\DryRun\Work"
if "%DRYRUN%"=="1" set "LASTRUN=%BASE%\DryRun\LastRun.txt"
if "%DRYRUN%"=="1" set "DRYRUN_ARG=-DryRun"
set "LOCKDIR=%STATE%\running.lock"
rem A lock older than this is left over from a crash or power cut. The task
rem time limit is 4 hours (240 minutes), so 300 leaves a margin.
set "LOCK_STALE_MIN=300"
rem Random names so a second copy started by hand cannot share these files.
set "PSOUT=%STATE%\ps_%RANDOM%%RANDOM%.tmp"
set "PSERR=%STATE%\ps_%RANDOM%%RANDOM%.err"
set "SUMMARY_TMP=%STATE%\summary.tmp"
set "SYSDRV=%SystemDrive%"
set "SYS32=%SystemRoot%\System32"
rem Full paths so nothing on PATH can stand in for a system tool.
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "POWERCFG=%SYS32%\powercfg.exe"
set "REGEXE=%SYS32%\reg.exe"
set "DISMEXE=%SYS32%\Dism.exe"
set "FINDSTR=%SYS32%\findstr.exe"

rem Built-in power plan GUIDs. These are the same on every Windows install.
rem A copied plan (for example a duplicated Ultimate plan) gets a random
rem GUID, so it is not recognised here and is left alone.
set "GUID_BALANCED=381b4222-f694-41f0-9685-ff5bb260df2e"
set "GUID_HIGHPERF=8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
set "GUID_POWERSAVER=a1841308-3541-4fab-bc81-f71556f20b4a"
set "GUID_ULTIMATE=e9a42b02-d5df-448d-aa00-03f14749eb61"

set "ALLOW_CHANGES=1"
set "IS_SSD=0"
set "LOG="
set "FINAL_RC="
set "GOT_LOCK=0"
set "MODE_TXT=manual"
set "TOKEN_NOTE="
set /a OK_COUNT=0, FAIL_COUNT=0, SKIP_COUNT=0

rem =========================================================================
rem  MAIN FLOW
rem =========================================================================

rem --- Administrator rights ----------------------------------------------
rem Almost every step needs admin rights. The scheduled task already runs
rem as SYSTEM. A manual run asks for elevation through UAC.
call :ensure_admin
set "ELEV_RC=%errorlevel%"
if "%ELEV_RC%"=="1" exit /b 0
if not "%ELEV_RC%"=="0" exit /b 5

rem --- Dry run: look for links first ---------------------------------------
rem A dry run may start in a folder that was never locked. The log folder and
rem the log are written as administrator, and a link planted there could send
rem them somewhere else. So the folder is scanned (read-only) before anything
rem is created in it. The scan prints to the screen, as there is no log yet.
if not "%DRYRUN%"=="1" goto :dry_scan_done
rem Without the helper the folder cannot be checked, so nothing is written.
if not exist "%HELPER%" (
    echo(DRY RUN stopped: PCTune.ps1 is missing, so the folder could not be checked for links. Nothing was done.
    exit /b 6
)
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action ScanFolder -Path "%BASE%"
if errorlevel 1 (
    echo(DRY RUN stopped: %BASE% contains links or could not be scanned. Nothing was done. Remove the items listed above and run it again.
    exit /b 6
)
:dry_scan_done

rem --- Logging -------------------------------------------------------------
call :init_logging
if errorlevel 1 (
    rem No log, so leave a note where a technician will look.
    >"%LASTRUN%" echo(PCTune %PCTUNE_VERSION%: could not start logging in %LOGDIR%. Nothing was done.
    exit /b 3
)
if "%DRYRUN%"=="1" echo(DRY RUN: nothing will be changed. Log: %LOG%
rem The dry-run token status copy is rebuilt from the real one on each run, so
rem an old copy from an earlier dry run can never hide a newer real status.
if "%DRYRUN%"=="1" if exist "%BASE%\DryRun\token_status.txt" del /f /q "%BASE%\DryRun\token_status.txt" 2>nul
if "%DRYRUN%"=="1" if /i not "%BASE%"=="%SystemDrive%\PCTune" call :log "WARNING: this dry run is in %BASE%, not in %SystemDrive%\PCTune. A normal run would stop here with exit code 6."

rem --- Folder protection ---------------------------------------------------
rem Refuse to run as SYSTEM from a folder that a normal user could change.
rem This catches a copy that was never installed, or permissions that were
rem loosened later. Install.bat sets them.
call :run_ps CheckFolder -Path "%BASE%"
if errorlevel 1 (
    if "%DRYRUN%"=="1" (
        rem The check is read-only, so it runs. A dry run only warns.
        call :log "WARNING: %BASE% is not protected or contains links. A normal run would stop here with exit code 6. Run Install.bat as administrator first."
    ) else (
        call :log "ABORT: %BASE% is not protected or contains links. Run Install.bat as administrator. Nothing was changed."
        >"%LASTRUN%" echo(PCTune %PCTUNE_VERSION%: stopped, the folder is not protected. Run Install.bat as administrator. See %LOG%
        exit /b 6
    )
)

rem --- Single instance -----------------------------------------------------
rem A folder works as a lock because creating one either succeeds or fails
rem in a single step. GOT_LOCK records that this run made it, so a run that
rem did not get the lock never removes another run's lock.
mkdir "%LOCKDIR%" 2>nul && set "GOT_LOCK=1"
if not "!GOT_LOCK!"=="1" (
    call :ps_get LOCK_AGE MinutesSince "%LOCKDIR%"
    call :is_number LOCK_AGE
    if errorlevel 1 set "LOCK_AGE=0"
    if !LOCK_AGE! GEQ %LOCK_STALE_MIN% (
        call :log "Removing a stale lock that is !LOCK_AGE! minutes old."
        rd "%LOCKDIR%" 2>nul
        mkdir "%LOCKDIR%" 2>nul && set "GOT_LOCK=1"
    )
)
if not "!GOT_LOCK!"=="1" (
    call :log "Another PCTune run is in progress. Exiting."
    exit /b 0
)

rem --- Once per day for the scheduled task -------------------------------
rem The task fires at every logon. This date check stops it repeating after
rem several reboots on the same day. The date is written at the start, not
rem the end, so a run cut short by a shutdown does not start again on every
rem logon that day. Manual runs always go ahead, and they also count as
rem today's run.
rem A dry run skips this check and the date file, so every step is shown.
if "%DRYRUN%"=="1" call :log "DRYRUN: the once-a-day check is skipped and State\LastRunDate.txt is not written."
if "%DRYRUN%"=="1" goto :daily_done
set "LAST_RUN_DATE="
if exist "%STATE%\LastRunDate.txt" set /p LAST_RUN_DATE=<"%STATE%\LastRunDate.txt"
if "%MODE_SCHEDULED%"=="1" if "!LAST_RUN_DATE!"=="%TODAY%" (
    call :log "Already ran today, %TODAY%. Scheduled run skipped."
    goto :release_lock
)
>"%STATE%\LastRunDate.txt" echo(%TODAY%|| call :log "WARNING: could not write LastRunDate.txt. The once-a-day check may not work."
:daily_done

del /q "%SUMMARY_TMP%" 2>nul
set "START_T=%TIME: =0%"
set "START_T=%START_T:~0,8%"
call :write_header

rem --- Checks before doing anything ----------------------------------------
call :check_windows
if errorlevel 1 (
    call :log "ABORT: this script is for Windows 11 only, build 22000 or newer."
    set /a FAIL_COUNT+=1
    >>"%SUMMARY_TMP%" echo(Windows version check: FAILED, not Windows 11
    set "FINAL_RC=4"
    goto :finish
)
call :check_drive

rem --- Free space before ---------------------------------------------------
call :ps_get FREE_BEFORE FreeMB
call :log "Free space on %SYSDRV% before: !FREE_BEFORE! MB"

rem --- Safety net ----------------------------------------------------------
call :step_restore_point

rem --- Daily jobs ----------------------------------------------------------
call :step_cleanup

rem --- Weekly jobs ---------------------------------------------------------
call :step_component_cleanup
call :step_trim
call :step_thumbnails
call :step_chkdsk
call :step_health_repair

rem --- Settings ------------------------------------------------------------
call :step_power
call :step_faststartup
call :step_network

rem --- Free space after ----------------------------------------------------
call :ps_get FREE_AFTER FreeMB
call :log "Free space on %SYSDRV% after: !FREE_AFTER! MB"
set "RECOVERED=unknown"
call :is_number FREE_BEFORE
if not errorlevel 1 (
    call :is_number FREE_AFTER
    if not errorlevel 1 set /a RECOVERED=FREE_AFTER-FREE_BEFORE
)
rem A negative number is possible: other programs, such as Windows Update,
rem write to the disk while this runs.
call :log "Space recovered: !RECOVERED! MB"

rem --- Report and housekeeping ---------------------------------------------
call :step_report
call :step_telemetry
call :token_status
call :run_ps RotateLogs -Path "%LOGDIR%" -Keep %LOG_KEEP%
call :result "Log rotation, keep %LOG_KEEP%" %errorlevel% ps dry

set "FINAL_RC=0"
if %FAIL_COUNT% GTR 0 set "FINAL_RC=1"

:finish
call :write_summary
call :log "Finished. OK: %OK_COUNT%  Skipped: %SKIP_COUNT%  Failed: %FAIL_COUNT%"
call :log "======================================================================"
if "%DRYRUN%"=="1" echo(DRY RUN finished. Nothing was changed. Summary: %LASTRUN%

:release_lock
if "%GOT_LOCK%"=="1" rd "%LOCKDIR%" 2>nul
if not defined FINAL_RC set "FINAL_RC=0"
exit /b %FINAL_RC%


rem =========================================================================
rem  SETUP ROUTINES
rem =========================================================================

:parse_args
rem Only the switches below are accepted. Anything else, an empty "" included,
rem sets ARG_BAD and the run stops, so a typo such as /dryrn can never start a
rem real run. Only the known switches are passed on to the elevated copy.
if [%1]==[] exit /b 0
set "ARG_KNOWN=0"
if /i "%~1"=="/scheduled" (set "MODE_SCHEDULED=1" & set "ARG_KNOWN=1")
if /i "%~1"=="/weekly"    (set "FORCE_WEEKLY=1" & set "ARG_KNOWN=1")
if /i "%~1"=="/elevated"  (set "ALREADY_ELEVATED=1" & set "ARG_KNOWN=1")
if /i "%~1"=="/dryrun"    (set "DRYRUN=1" & set "ARG_KNOWN=1")
if "%ARG_KNOWN%"=="0" set "ARG_BAD=1"
shift
goto :parse_args

:ensure_admin
rem fltmc only works with admin rights, so its exit code is a simple admin
rem test that does not depend on the Windows language.
rem Returns: 0 = admin, 1 = elevated copy started, 2 = elevation failed.
"%SYS32%\fltmc.exe" >nul 2>&1
if not errorlevel 1 exit /b 0
if "%ALREADY_ELEVATED%"=="1" exit /b 2
set "RELAUNCH_ARGS=/elevated"
if "%MODE_SCHEDULED%"=="1" set "RELAUNCH_ARGS=!RELAUNCH_ARGS! /scheduled"
if "%FORCE_WEEKLY%"=="1" set "RELAUNCH_ARGS=!RELAUNCH_ARGS! /weekly"
if "%DRYRUN%"=="1" set "RELAUNCH_ARGS=!RELAUNCH_ARGS! /dryrun"
rem The path is passed through an environment variable rather than pasted
rem into the command, so no character in it can change the command.
rem WildcardPattern.Escape stops "[" or "]" being read as a wildcard.
(call)
"%PSEXE%" -NoProfile -NonInteractive -Command "Start-Process -FilePath ([Management.Automation.WildcardPattern]::Escape($env:PCTUNE_SELF)) -ArgumentList '%RELAUNCH_ARGS%' -Verb RunAs"
if errorlevel 1 exit /b 2
exit /b 1

:init_logging
for %%D in ("%LOGDIR%" "%STATE%" "%BACKUP%") do (
    if not exist "%%~D\" mkdir "%%~D" 2>nul
    if not exist "%%~D\" exit /b 1
)
if not exist "%HELPER%" exit /b 1
rem Get the date from PowerShell. %DATE% changes format with the regional
rem settings, and the log file name needs a fixed yyyy-MM-dd form.
call :ps_get TODAY Today
echo(%TODAY%| "%FINDSTR%" /r /x "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" >nul
if errorlevel 1 exit /b 1
set "LOG=%LOGDIR%\PCTune_%TODAY%.log"
if "%DRYRUN%"=="1" goto :init_dry_log
rem A failed redirection does not change errorlevel, so || is used instead.
>>"%LOG%" echo(|| exit /b 1
exit /b 0
:init_dry_log
rem One dry-run log, started fresh each time, so its first line is always the
rem dry-run notice.
set "LOG=%LOGDIR%\PCTune_DryRun.log"
>"%LOG%" echo(DRY RUN: nothing was changed.|| exit /b 1
exit /b 0

:write_header
call :log "======================================================================"
call :log "PCTune version %PCTUNE_VERSION% started"
if "%MODE_SCHEDULED%"=="1" (set "MODE_TXT=scheduled") else (set "MODE_TXT=manual")
if "%DRYRUN%"=="1" set "MODE_TXT=dry run"
call :log "Computer: %COMPUTERNAME%   Mode: !MODE_TXT!   Account: %USERNAME%"
call :log "Script: %SELF%"
call :log "Config: restore=%DO_RESTORE_POINT% cleanup=%DO_CLEANUP% wu=%DO_WU_CACHE% do=%DO_DO_CACHE% component=%DO_COMPONENT_CLEANUP% trim=%DO_TRIM% thumbs=%DO_THUMBNAILS% chkdsk=%DO_CHKDSK_SCAN% repair=%DO_HEALTH_REPAIR% power=%DO_POWER% faststartup_enable=%DO_FASTSTARTUP_ENABLE% dns=%DO_DNS_FLUSH% netreset=%DO_NETWORK_RESET% report=%DO_HEALTH_REPORT%"
call :log "======================================================================"
exit /b 0

:check_windows
rem Windows 11 starts at build 22000. Windows 11 still reports version
rem "10.0", so the build number is the reliable test.
set "OS_BUILD="
for /f "tokens=3" %%B in ('%REGEXE% query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| %FINDSTR% /i "REG_SZ"') do set "OS_BUILD=%%B"
call :is_number OS_BUILD
if errorlevel 1 (
    call :log "Could not read the Windows build number."
    exit /b 1
)
call :log "Windows build: !OS_BUILD!"
if !OS_BUILD! LSS 22000 exit /b 1
exit /b 0

:check_drive
rem Find out whether the system drive is an SSD. TRIM and the disk power
rem setting only apply to SSDs. On anything else they are skipped.
set "DRV_MEDIA="
set "DRV_FS="
call :ps_kv DriveInfo DRV_
if errorlevel 1 set "DRV_MEDIA="
if not defined DRV_MEDIA (
    call :log "WARNING: could not read the system drive type."
    call :result "System drive check" 1
)
if /i "!DRV_MEDIA!"=="SSD" set "IS_SSD=1"
call :log "System drive %SYSDRV%: media type !DRV_MEDIA!, file system !DRV_FS!"
if not "!IS_SSD!"=="1" call :log "Not confirmed as an SSD. SSD-specific steps will be skipped."
exit /b 0


rem =========================================================================
rem  STEPS
rem =========================================================================

:step_restore_point
if not "%DO_RESTORE_POINT%"=="1" (
    call :skip "System Restore point" "disabled in config"
    if "%REQUIRE_RESTORE_POINT%"=="1" set "ALLOW_CHANGES=0"
    exit /b 0
)
rem Windows normally allows only one restore point every 24 hours, through
rem the documented SystemRestorePointCreationFrequency value in minutes.
rem The helper backs that value up to restorefreq_original.txt, sets it to
rem 0 for a moment, makes the restore point, then puts the old value back.
rem The backup file lets it, and Uninstall.bat, put back the true original
rem even if an earlier run was cut off halfway. If the backup cannot be
rem written, the helper stops before changing anything.
rem A copy of the whole key is exported once, for reference only.
if "%DRYRUN%"=="1" call :log "DRYRUN: would export the SystemRestore registry key to Backup\SystemRestore_original.reg if that file is not there yet."
if "%DRYRUN%"=="1" goto :rp_export_done
if not exist "%BACKUP%\SystemRestore_original.reg" (
    (call)
    "%REGEXE%" export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" "%BACKUP%\SystemRestore_original.reg" /y >>"%LOG%" 2>&1
    if errorlevel 1 call :log "WARNING: could not export the SystemRestore key for reference."
)
:rp_export_done
if "%ENABLE_SYSTEM_PROTECTION%"=="1" (
    call :run_ps RestorePoint -Description "PCTune %PCTUNE_VERSION% %TODAY%" -Path "%BACKUP%\restorefreq_original.txt" -EnableProtection
) else (
    call :run_ps RestorePoint -Description "PCTune %PCTUNE_VERSION% %TODAY%" -Path "%BACKUP%\restorefreq_original.txt"
)
set "RC=%errorlevel%"
call :result "System Restore point" %RC% ps dry
if not "%RC%"=="0" if "%REQUIRE_RESTORE_POINT%"=="1" (
    set "ALLOW_CHANGES=0"
    call :log "No restore point, so the settings changes in this run will be skipped."
)
exit /b 0

:step_cleanup
rem Cleanup frees space and removes clutter. On an SSD it does not make boot
rem itself faster. It helps when the drive is nearly full, because SSDs slow
rem down when they have little free space left.
if "%DO_CLEANUP%"=="1" (
    call :run_ps CleanTemp -MinAgeDays %TEMP_MIN_AGE_DAYS%
    call :result "Temp files, older than %TEMP_MIN_AGE_DAYS% days" !errorlevel! ps dry
    call :run_ps CleanWER
    call :result "Old error reports" !errorlevel! ps dry
) else (
    call :skip "Temp files" "disabled in config"
    call :skip "Old error reports" "disabled in config"
)
if "%DO_WU_CACHE%"=="1" (
    rem The helper stops wuauserv and BITS, empties only
    rem SoftwareDistribution\Download, then restarts the services that were
    rem running. It skips if an update is being installed right now.
    call :run_ps CleanWU
    call :result "Windows Update download cache" !errorlevel! ps dry
) else (
    call :skip "Windows Update download cache" "disabled in config"
)
if "%DO_DO_CACHE%"=="1" (
    call :run_ps CleanDO
    call :result "Delivery Optimization cache" !errorlevel! ps dry
) else (
    call :skip "Delivery Optimization cache" "disabled in config"
)
exit /b 0

:step_component_cleanup
rem Removes old versions of updated system files from WinSxS. Windows does
rem this on its own schedule too, so this mainly reclaims space sooner.
rem /ResetBase is NOT used: it would stop installed updates from being
rem uninstalled, which matters if an update ever breaks something.
if not "%DO_COMPONENT_CLEANUP%"=="1" (call :skip "Component cleanup" "disabled in config" & exit /b 0)
call :due COMPONENT
if "!DUE!"=="0" (call :skip "Component cleanup" "ran within %WEEKLY_INTERVAL_DAYS% days" & exit /b 0)
if "%DRYRUN%"=="1" (call :dryskip "Component cleanup" "run DISM /StartComponentCleanup /English" & exit /b 0)
call :log "Running DISM /StartComponentCleanup. This can take several minutes."
rem (call) sets errorlevel to 1 first. If the log cannot be opened, the
rem command does not run and the 1 stays, so it counts as a failure.
(call)
"%DISMEXE%" /Online /Cleanup-Image /StartComponentCleanup /English >>"%LOG%" 2>&1
set "RC=%errorlevel%"
rem 3010 means it worked but a restart is needed to finish.
if "%RC%"=="3010" (call :log "DISM: restart required to finish." & set "RC=0")
call :result "Component cleanup" %RC% native
call :mark_done COMPONENT
exit /b 0

:step_trim
rem TRIM tells the SSD which blocks are free so it can prepare them ahead of
rem time. That keeps write speed steady. Windows already does this weekly
rem through "Optimize Drives", so this is a safety net for laptops where
rem that task is not running. defrag /L only sends TRIM. It never moves
rem data, so this is not a defrag.
if not "%DO_TRIM%"=="1" (call :skip "SSD TRIM" "disabled in config" & exit /b 0)
if not "%IS_SSD%"=="1" (call :skip "SSD TRIM" "system drive not confirmed as SSD" & exit /b 0)
call :due TRIM
if "!DUE!"=="0" (call :skip "SSD TRIM" "ran within %WEEKLY_INTERVAL_DAYS% days" & exit /b 0)
if "%DRYRUN%"=="1" (call :dryskip "SSD TRIM" "send TRIM to %SYSDRV% with defrag /L" & exit /b 0)
(call)
"%SYS32%\defrag.exe" %SYSDRV% /L >>"%LOG%" 2>&1
set "RC=%errorlevel%"
call :result "SSD TRIM, defrag /L" %RC% native
call :mark_done TRIM
exit /b 0

:step_thumbnails
rem Explorer rebuilds the thumbnail cache when needed. Deleting it frees
rem space and fixes broken thumbnails, but gives no speed gain. That is why
rem it runs weekly, not daily. The file the signed-in user has open is
rem locked and gets skipped.
if not "%DO_THUMBNAILS%"=="1" (call :skip "Thumbnail cache" "disabled in config" & exit /b 0)
call :due THUMBS
if "!DUE!"=="0" (call :skip "Thumbnail cache" "ran within %WEEKLY_INTERVAL_DAYS% days" & exit /b 0)
call :run_ps CleanThumbs
call :result "Thumbnail cache" %errorlevel% ps dry
if not "%DRYRUN%"=="1" call :mark_done THUMBS
exit /b 0

:step_chkdsk
rem chkdsk /scan checks NTFS while Windows is running. It needs no reboot
rem and does not lock the drive. /f and /r are never used, because they need
rem a reboot and an offline scan.
if not "%DO_CHKDSK_SCAN%"=="1" (call :skip "chkdsk /scan" "disabled in config" & exit /b 0)
if /i not "%DRV_FS%"=="NTFS" (call :skip "chkdsk /scan" "file system is not NTFS" & exit /b 0)
call :due CHKDSK
if "!DUE!"=="0" (call :skip "chkdsk /scan" "ran within %WEEKLY_INTERVAL_DAYS% days" & exit /b 0)
if "%DRYRUN%"=="1" (call :dryskip "chkdsk /scan" "run chkdsk %SYSDRV% /scan" & exit /b 0)
(call)
"%SYS32%\chkdsk.exe" %SYSDRV% /scan >>"%LOG%" 2>&1
set "RC=%errorlevel%"
rem chkdsk exit codes: 0 = no errors, 1 = errors found and fixed,
rem 2 = cleanup done or skipped, 3 = problems that need an offline chkdsk /f.
if "%RC%"=="1" (call :log "chkdsk found and fixed errors online." & set "RC=0")
if "%RC%"=="2" set "RC=0"
if "%RC%"=="3" call :log "chkdsk found problems it cannot fix online. Run chkdsk %SYSDRV% /f by hand and restart."
call :result "chkdsk /scan" %RC% native
call :mark_done CHKDSK
exit /b 0

:step_health_repair
rem DISM /RestoreHealth repairs the component store that sfc copies good
rem files from, so it runs first. Both are slow, from 10 to 30 minutes, and
rem only fix corruption. That is why they run weekly. The date is recorded
rem even if a run fails, for example with no internet, so a failure does not
rem cost 30 minutes at every logon.
if not "%DO_HEALTH_REPAIR%"=="1" (call :skip "DISM RestoreHealth and SFC" "disabled in config" & exit /b 0)
call :due HEALTH
if "!DUE!"=="0" (call :skip "DISM RestoreHealth and SFC" "ran within %WEEKLY_INTERVAL_DAYS% days" & exit /b 0)
if "%DRYRUN%"=="1" (call :dryskip "DISM RestoreHealth and SFC" "run DISM /RestoreHealth, then sfc /scannow" & exit /b 0)
call :log "Running DISM /RestoreHealth. This can take 10 to 30 minutes."
(call)
"%DISMEXE%" /Online /Cleanup-Image /RestoreHealth /English >>"%LOG%" 2>&1
set "RC=%errorlevel%"
if "%RC%"=="3010" (call :log "DISM: restart required to finish." & set "RC=0")
call :result "DISM RestoreHealth" %RC% native
call :log "Running sfc /scannow."
set "SFC_OUT=%LOGDIR%\sfc_%TODAY%.txt"
rem sfc writes UTF-16 text, which looks garbled inside an ANSI log. It goes
rem to its own file and the helper copies the readable lines across.
(call)
"%SYS32%\sfc.exe" /scannow >"%SFC_OUT%" 2>&1
set "RC=%errorlevel%"
call :run_ps AppendUnicode -Path "%SFC_OUT%"
if errorlevel 1 call :log "Could not copy the sfc output into this log. See %SFC_OUT%"
rem Microsoft does not document sfc exit codes. Treat non-zero as a failure
rem to look at, and read the sfc text above or %SystemRoot%\Logs\CBS\CBS.log.
call :result "sfc /scannow" %RC% native
call :mark_done HEALTH
exit /b 0

:step_power
rem Balanced is Microsoft's recommended plan for laptops. It raises CPU
rem speed when there is work and drops it when idle. High performance mainly
rem costs battery and heat, Power saver slows everything, and Ultimate
rem Performance is meant for workstations, not laptops. OEM or custom plans
rem are left alone because the maker may have tuned them for the hardware.
if not "%DO_POWER%"=="1" (call :skip "Power plan" "disabled in config" & exit /b 0)
if "%ALLOW_CHANGES%"=="0" (call :skip "Power plan" "no restore point this run" & exit /b 0)
set "PW_SCHEME="
set "PW_DISKIDLE_AC="
call :ps_kv PowerGet PW_
if not defined PW_SCHEME (
    call :log "Could not read the active power plan."
    call :result "Power plan" 1
    exit /b 0
)
call :log "Active power plan: !PW_SCHEME!"
set "SWITCH_PLAN=0"
for %%G in (%GUID_HIGHPERF% %GUID_ULTIMATE% %GUID_POWERSAVER%) do if /i "!PW_SCHEME!"=="%%G" set "SWITCH_PLAN=1"
if "%DRYRUN%"=="1" if "!SWITCH_PLAN!"=="1" (
    call :dryskip "Power plan, switch to Balanced" "switch the active power plan !PW_SCHEME! to Balanced, after saving the original plan to Backup\power_scheme_original.txt"
    goto :power_disk
)
if "!SWITCH_PLAN!"=="1" (
    rem The original plan is recorded once only, so later runs never
    rem overwrite the real original with a value this script set.
    if not exist "%BACKUP%\power_scheme_original.txt" >"%BACKUP%\power_scheme_original.txt" echo(SCHEME=!PW_SCHEME!
    if not exist "%BACKUP%\power_scheme_original.txt" (
        call :log "Could not back up the power plan. Not changing it."
        call :result "Power plan, switch to Balanced" 1
        exit /b 0
    )
    (call)
    "%POWERCFG%" /setactive %GUID_BALANCED% >>"%LOG%" 2>&1
    call :result "Power plan, switch to Balanced" !errorlevel! native
) else (
    call :log "Power plan is Balanced or an OEM plan. No change needed."
)
:power_disk
rem "Turn off hard disk after" on mains power is set to Never so the SSD is
rem not put into a low-power state between bursts of activity. Waking from
rem that state adds a small delay. Honest note: on an SSD the gain is small,
rem and it does not change boot time, because Windows does not power the
rem disk down during boot. Battery settings are left alone to keep battery
rem life.
if not "%IS_SSD%"=="1" (call :skip "SSD power, mains" "system drive not confirmed as SSD" & exit /b 0)
set "PW_SCHEME="
set "PW_DISKIDLE_AC="
call :ps_kv PowerGet PW_
call :is_number PW_DISKIDLE_AC
if errorlevel 1 (
    call :log "Could not read the disk idle setting."
    call :result "SSD power, mains" 1
    exit /b 0
)
if "!PW_DISKIDLE_AC!"=="0" (
    call :log "Disk idle on mains is already Never."
    call :result "SSD power, mains" 0
    exit /b 0
)
call :is_guid PW_SCHEME
if errorlevel 1 (
    call :log "Could not read the active power plan GUID. Not changing the disk idle setting."
    call :result "SSD power, mains" 1
    exit /b 0
)
if "%DRYRUN%"=="1" (
    call :dryskip "SSD power, disk idle on mains set to Never" "save the current disk idle value, !PW_DISKIDLE_AC! seconds, to Backup\diskidle_!PW_SCHEME!.txt, then set Turn off hard disk after to Never on mains power"
    exit /b 0
)
rem One backup per plan, because the setting belongs to the plan. The first
rem value seen for a plan is kept, so a later run never overwrites the true
rem original with a value this script set.
set "DI_BK=%BACKUP%\diskidle_!PW_SCHEME!.txt"
if not exist "%DI_BK%" (
    (
        echo(SCHEME=!PW_SCHEME!
        echo(AC=!PW_DISKIDLE_AC!
    ) >"%DI_BK%"
)
rem Read the backup back. Only change the setting if it holds this plan and
rem a valid number.
set "V_SCHEME="
set "V_AC="
if exist "%DI_BK%" for /f "usebackq tokens=1,* delims==" %%A in ("%DI_BK%") do (
    if /i "%%A"=="SCHEME" set "V_SCHEME=%%B"
    if /i "%%A"=="AC" set "V_AC=%%B"
)
set "DI_BK_OK=1"
if /i not "!V_SCHEME!"=="!PW_SCHEME!" set "DI_BK_OK=0"
call :is_number V_AC
if errorlevel 1 set "DI_BK_OK=0"
if "!DI_BK_OK!"=="0" (
    call :log "Could not back up the disk idle setting to %DI_BK%. Not changing it."
    call :result "SSD power, mains" 1
    exit /b 0
)
(call)
"%POWERCFG%" /setacvalueindex !PW_SCHEME! SUB_DISK DISKIDLE 0 >>"%LOG%" 2>&1
set "RC=%errorlevel%"
rem Re-applying the active plan makes the new value take effect now.
if "%RC%"=="0" (
    (call)
    "%POWERCFG%" /setactive SCHEME_CURRENT >>"%LOG%" 2>&1
)
if "%RC%"=="0" set "RC=%errorlevel%"
call :result "SSD power, disk idle on mains set to Never" %RC% native
exit /b 0

:step_faststartup
rem Fast Startup recommendation: keep it ON for this laptop.
rem When you shut down with Fast Startup on, Windows saves the kernel and
rem drivers to hiberfil.sys and reloads them at the next power-on instead of
rem starting from scratch. That makes cold boot faster on a slow laptop.
rem Restart always does a full boot, so updates and driver changes still get
rem a clean start when you use Restart.
rem Turn it OFF only if: you dual-boot another OS, a device or driver
rem misbehaves after power-on but is fine after Restart, or you need a
rem guaranteed full power-off for troubleshooting.
rem By default this step only reports. Set DO_FASTSTARTUP_ENABLE=1 to switch
rem it on when it is off.
set "PW_HIBERBOOT="
set "PW_HIBERNATE="
call :ps_kv PowerGet PW_
set "FS_RC=%errorlevel%"
set "FS_BAD=0"
if not "%FS_RC%"=="0" set "FS_BAD=1"
if not defined PW_HIBERBOOT set "FS_BAD=1"
if not defined PW_HIBERNATE set "FS_BAD=1"
if /i "!PW_HIBERBOOT!"=="error" set "FS_BAD=1"
if /i "!PW_HIBERNATE!"=="error" set "FS_BAD=1"
if "!FS_BAD!"=="1" (
    rem A read error must never be mistaken for "off", so nothing is changed.
    call :log "Could not read the Fast Startup settings. Nothing changed."
    call :result "Fast Startup check" 1
    exit /b 0
)
call :log "Fast Startup: HiberbootEnabled=!PW_HIBERBOOT!  HibernateEnabled=!PW_HIBERNATE!"
set "FS_ON=0"
if "!PW_HIBERBOOT!"=="1" if not "!PW_HIBERNATE!"=="0" set "FS_ON=1"
if "!FS_ON!"=="1" (
    call :log "Fast Startup is ON. Recommendation: leave it on."
    call :result "Fast Startup check" 0
    exit /b 0
)
call :log "Fast Startup is OFF. Recommendation: turn it on unless one of the reasons in the script comments applies."
if not "%DO_FASTSTARTUP_ENABLE%"=="1" (call :result "Fast Startup check, report only" 0 & exit /b 0)
if "%ALLOW_CHANGES%"=="0" (call :skip "Fast Startup enable" "no restore point this run" & exit /b 0)
if "%DRYRUN%"=="1" (call :dryskip "Fast Startup enable" "turn on hibernation if it is off and set HiberbootEnabled to 1 in the registry, after saving the original values to Backup\faststartup_original.txt" & exit /b 0)
set "FS_BK=%BACKUP%\faststartup_original.txt"
if not exist "%FS_BK%" (
    (
        echo(HIBERBOOT=!PW_HIBERBOOT!
        echo(HIBERNATE=!PW_HIBERNATE!
    ) >"%FS_BK%"
    (call)
    "%REGEXE%" export "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "%BACKUP%\SessionManagerPower_original.reg" /y >>"%LOG%" 2>&1
    if errorlevel 1 call :log "WARNING: could not export the Session Manager\Power key for reference."
)
rem Read the backup back. Only change anything if both values are in it.
set "V_HB="
set "V_HN="
if exist "%FS_BK%" for /f "usebackq tokens=1,* delims==" %%A in ("%FS_BK%") do (
    if /i "%%A"=="HIBERBOOT" set "V_HB=%%B"
    if /i "%%A"=="HIBERNATE" set "V_HN=%%B"
)
if not defined V_HB set "V_HB=bad"
if not defined V_HN set "V_HN=bad"
if /i "!V_HB!"=="bad" goto :fs_backup_failed
if /i "!V_HN!"=="bad" goto :fs_backup_failed
rem Fast Startup needs hibernation, so turn that on first if it is off.
rem HIBERNATE_CHANGED=1 tells Uninstall.bat that PCTune turned it on, so only
rem then does uninstall turn it off again. It is written before the change,
rem so a cut-off run still leaves the record.
if not "!PW_HIBERNATE!"=="1" (
    >>"%FS_BK%" echo(HIBERNATE_CHANGED=1|| (
        call :log "Could not record the hibernation change in %FS_BK%. Not changing it."
        call :result "Fast Startup enable" 1
        exit /b 0
    )
    (call)
    "%POWERCFG%" /hibernate on >>"%LOG%" 2>&1
    if errorlevel 1 (
        call :log "Could not turn hibernation on, so Fast Startup cannot be enabled."
        call :result "Fast Startup enable" 1
        exit /b 0
    )
)
(call)
"%REGEXE%" add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1
call :result "Fast Startup enable" %errorlevel% native
exit /b 0

:fs_backup_failed
call :log "Could not back up the Fast Startup settings to %FS_BK%. Not changing them."
call :result "Fast Startup enable" 1
exit /b 0

:step_network
rem Neither of these makes Windows boot faster. They are fixes for network
rem problems and are off by default.
if "%DO_DNS_FLUSH%"=="1" (
    if "%DRYRUN%"=="1" (
        call :dryskip "DNS cache flush" "run ipconfig /flushdns"
    ) else (
        (call)
        "%SYS32%\ipconfig.exe" /flushdns >>"%LOG%" 2>&1
        call :result "DNS cache flush" !errorlevel! native
    )
) else (
    call :skip "DNS cache flush" "disabled in config"
)
if not "%DO_NETWORK_RESET%"=="1" (call :skip "Winsock and IP reset" "disabled in config" & exit /b 0)
rem A reset at every logon would wipe custom network settings each day and
rem break the connection until a restart. So the scheduled task never does
rem it.
if "%MODE_SCHEDULED%"=="1" (call :skip "Winsock and IP reset" "manual runs only" & exit /b 0)
if "%ALLOW_CHANGES%"=="0" (call :skip "Winsock and IP reset" "no restore point this run" & exit /b 0)
if "%DRYRUN%"=="1" (call :dryskip "Winsock and IP reset" "run netsh winsock reset and netsh int ip reset, which need a restart afterwards" & exit /b 0)
(call)
"%SYS32%\netsh.exe" winsock reset >>"%LOG%" 2>&1
call :result "Winsock reset" %errorlevel% native
rem netsh int ip reset often reports "Access is denied" for one protected
rem key and returns an error even when the rest of the reset worked. Read
rem the log lines above before assuming it failed.
(call)
"%SYS32%\netsh.exe" int ip reset >>"%LOG%" 2>&1
call :result "IP stack reset" %errorlevel% native
call :log "Network reset done. Restart the laptop for it to take effect."
exit /b 0

:step_report
if not "%DO_HEALTH_REPORT%"=="1" (call :skip "Health report" "disabled in config" & exit /b 0)
call :log "----- Health report -----"
call :log "Free space before: !FREE_BEFORE! MB   after: !FREE_AFTER! MB   recovered: !RECOVERED! MB"
call :run_ps Report
call :result "Health report" %errorlevel%
call :log "----- End of health report -----"
exit /b 0

:step_telemetry
rem Off: remove the watchdog task so one switch turns everything off.
if "%DO_TELEMETRY%"=="1" goto :tele_on
if not exist "%TELEHELPER%" (call :skip "Telemetry" "off in config" & exit /b 0)
call :run_tps RemoveWatchdog
set "T_RC=%errorlevel%"
if "%T_RC%"=="2" (call :skip "Telemetry" "off in config" & exit /b 0)
call :result "Telemetry off, watchdog task removed" %T_RC%
exit /b 0
:tele_on
call :log "NOTICE: telemetry is ON. A health snapshot is uploaded once a day to the owner's private GitHub repo. Set DO_TELEMETRY=0 in PCTune.bat to turn it off."
if not exist "%TELEHELPER%" (call :result "Telemetry, Telemetry.ps1 missing" 1 & exit /b 0)
if "%DRYRUN%"=="1" goto :tele_dry
rem Nothing is collected or sent unless the token file and the data folder
rem are readable only by SYSTEM and Administrators.
call :run_tps CheckPrivate
set "T_RC=%errorlevel%"
if "%T_RC%"=="2" (call :skip "Telemetry" "not set up, run Setup-Telemetry.bat" & exit /b 0)
call :result "Telemetry token and data protected" %T_RC%
if not "%T_RC%"=="0" (
    call :log "Telemetry: not collecting or uploading, because the token or data folder is not protected. Run Install.bat again."
    exit /b 0
)
call :run_tps EnsureWatchdog
call :result "Telemetry watchdog task" %errorlevel%
call :run_tps Collect
call :result "Telemetry snapshot" %errorlevel%
rem Upload sends today's report and any older ones that could not be sent.
rem Exit 2 means no internet or nothing to send: the reports are kept and
rem tried again next run.
call :run_tps Upload
call :result "Telemetry upload" %errorlevel%
exit /b 0

:tele_dry
rem Dry run: same order as a real run, but Telemetry.ps1 is told -DryRun, so it
rem registers, stores and sends nothing. The protection check is left out,
rem because a PC that is only being tested has no token. The watchdog runs in
rem the foreground for 3 samples, about 3 minutes, and writes DryRun\samples.
rem Collect builds the report for real under DryRun\reports.
call :log "DRYRUN: not checking the token and data protection, because a dry run stores and needs no token."
call :run_tps EnsureWatchdog
call :result "Telemetry watchdog task" !errorlevel! ps dry
call :log "DRYRUN: the watchdog takes 3 samples in the foreground. This takes about 3 minutes."
call :run_tps Watchdog -Samples 3
call :result "Telemetry watchdog, 3 samples" !errorlevel! ps dry
call :run_tps Collect
call :result "Telemetry snapshot" !errorlevel! ps dry
set "T_REPORT=%BASE%\DryRun\reports\%TODAY%_%COMPUTERNAME%"
if exist "!T_REPORT!.json" (
    call :log "DRYRUN: the telemetry report was saved as !T_REPORT!.json and !T_REPORT!.md"
) else (
    call :log "The dry-run telemetry report was not found at !T_REPORT!.json. See the log lines above."
    call :result "Telemetry report file" 1
)
call :run_tps Upload
call :result "Telemetry upload" !errorlevel! ps dry
call :log "DRYRUN: nothing was uploaded."
exit /b 0

:token_status
rem Telemetry.ps1 leaves a one-line status file: OK <date>, WARN <date> <days>,
rem EXPIRED <date> or NONE. The content is not trusted. findstr keeps only a
rem line that is exactly WARN or EXPIRED, then a date, then digits, so nothing
rem else ever reaches a variable. A missing file, OK, NONE and anything
rem malformed all mean there is nothing to say.
set "TOKEN_NOTE="
set "TS_FILE=%BASE%\Telemetry\token_status.txt"
if "%DRYRUN%"=="1" set "TS_FILE=%BASE%\DryRun\token_status.txt"
if not exist "%TS_FILE%" exit /b 0
set "TS_WORD="
set "TS_DATE="
set "TS_DAYS="
for /f "tokens=1-3" %%A in ('%FINDSTR% /r /x /c:"WARN [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]*" /c:"EXPIRED [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "%TS_FILE%" 2^>nul') do if not defined TS_WORD (
    set "TS_WORD=%%A"
    set "TS_DATE=%%B"
    set "TS_DAYS=%%C"
)
if "!TS_WORD!"=="WARN" set "TOKEN_NOTE=WARNING: the GitHub telemetry token expires on !TS_DATE! (!TS_DAYS! days). Run Setup-Telemetry.bat to enter a new token."
if "!TS_WORD!"=="EXPIRED" set "TOKEN_NOTE=FAIL: the GitHub telemetry token expired on !TS_DATE!. Run Setup-Telemetry.bat to enter a new token."
rem An expired token stops every upload, so the run counts as failed.
if "!TS_WORD!"=="EXPIRED" set /a FAIL_COUNT+=1
if defined TOKEN_NOTE call :log "!TOKEN_NOTE!"
exit /b 0

:write_summary
rem LastRun.txt is a short summary a customer or technician can read
rem without opening the full log.
set "END_T=%TIME: =0%"
set "END_T=%END_T:~0,8%"
(
    if "%DRYRUN%"=="1" echo(DRY RUN: nothing was changed.
    if defined TOKEN_NOTE echo(!TOKEN_NOTE!
    echo(PCTune %PCTUNE_VERSION% - last run summary
    echo(Date: %TODAY%   Started: %START_T%   Finished: !END_T!
    echo(Computer: %COMPUTERNAME%   Mode: !MODE_TXT!
    echo(Free space on %SYSDRV%: before !FREE_BEFORE! MB, after !FREE_AFTER! MB, recovered !RECOVERED! MB
    echo(Results: %OK_COUNT% OK, %SKIP_COUNT% skipped, %FAIL_COUNT% failed
    echo(
    if exist "%SUMMARY_TMP%" type "%SUMMARY_TMP%"
    echo(
    echo(Full log: %LOG%
) >"%LASTRUN%" || call :log "WARNING: could not write %LASTRUN%"
del /q "%SUMMARY_TMP%" 2>nul
exit /b 0


rem =========================================================================
rem  HELPERS
rem =========================================================================

:log
rem Writes one timestamped line to the log. %TIME% has a leading space
rem before 10:00, so spaces are swapped for zeros.
set "L_T=%TIME: =0%"
>>"%LOG%" echo(%TODAY% %L_T:~0,8%  %~1
exit /b 0

:result
rem %1 = step name, %2 = exit code, %3 = "native" for a Windows program,
rem %4 = "dry" for a step that is only previewed in a dry run.
rem 0 = OK. 2 = skipped, but only for the PowerShell helper, which uses 2
rem for "nothing to do here". For Windows programs such as DISM or reg, 2 is
rem a real error code, so it counts as a failure. Anything else = failed.
set "R_NAME=%~1"
set "R_RC=%~2"
set "R_SRC=%~3"
set "R_DRY=%~4"
if not defined R_RC set "R_RC=1"
set "R_KIND=fail"
if "%R_RC%"=="0" set "R_KIND=ok"
if "%R_RC%"=="2" if /i not "%R_SRC%"=="native" set "R_KIND=skip"
if "%R_KIND%"=="ok" (
    set /a OK_COUNT+=1
    set "R_TXT=OK"
    if "%DRYRUN%"=="1" if /i "%R_DRY%"=="dry" set "R_TXT=OK, dry run: nothing changed"
) else if "%R_KIND%"=="skip" (
    set /a SKIP_COUNT+=1
    set "R_TXT=SKIPPED, see log"
) else (
    set /a FAIL_COUNT+=1
    set "R_TXT=FAILED, exit code %R_RC%"
)
call :log "RESULT  !R_NAME!: !R_TXT!"
>>"%SUMMARY_TMP%" echo(!R_NAME!: !R_TXT!
exit /b 0

:dryskip
rem %1 = step name, %2 = what the step would do. A dry run does not run a
rem step that changes something. It logs it and counts it as skipped.
set /a SKIP_COUNT+=1
call :log "DRYRUN: would %~2"
>>"%SUMMARY_TMP%" echo(%~1: DRYRUN, would %~2
exit /b 0

:skip
rem %1 = step name, %2 = reason.
set /a SKIP_COUNT+=1
call :log "SKIP    %~1: %~2"
>>"%SUMMARY_TMP%" echo(%~1: skipped, %~2
exit /b 0

:run_ps
rem Runs one PCTune.ps1 action and passes back its exit code. Output goes to
rem a temp file first, then into the log. That way the helper can write to
rem the log itself without both programs having the file open at once.
rem (call) sets the exit code to 1 first. If the redirect fails, PowerShell
rem never starts and the 1 is kept, so the step counts as failed.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action %* -LogFile "%LOG%" %DRYRUN_ARG% >"%PSOUT%" 2>&1
set "PSRC=%errorlevel%"
if exist "%PSOUT%" for %%F in ("%PSOUT%") do if %%~zF GTR 0 type "%PSOUT%" >>"%LOG%"
del /q "%PSOUT%" 2>nul
exit /b %PSRC%

:run_tps
rem Same as :run_ps, for one Telemetry.ps1 action. Anything after the action
rem name, such as -Samples 3, is passed on.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TELEHELPER%" -Action %* -Base "%BASE%" -LogFile "%LOG%" %DRYRUN_ARG% >"%PSOUT%" 2>&1
set "PSRC=%errorlevel%"
if exist "%PSOUT%" for %%F in ("%PSOUT%") do if %%~zF GTR 0 type "%PSOUT%" >>"%LOG%"
del /q "%PSOUT%" 2>nul
exit /b %PSRC%

:ps_get
rem %1 = variable to fill, %2 = helper action, %3 = optional -Path value.
rem Keeps the first line the helper prints. Output goes to a temp file
rem rather than a for /f pipe, because a pipe hides the helper's exit code.
rem On failure the variable stays empty, the error is logged, and the exit
rem code is passed back.
set "%~1="
(call)
if "%~3"=="" (
    "%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action %~2 >"%PSOUT%" 2>"%PSERR%"
) else (
    "%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action %~2 -Path "%~3" >"%PSOUT%" 2>"%PSERR%"
)
set "PG_RC=%errorlevel%"
if "%PG_RC%"=="0" (
    if exist "%PSOUT%" for /f "usebackq delims=" %%L in ("%PSOUT%") do (
        if not defined %~1 set "%~1=%%L"
    )
) else (
    call :ps_fail %~2 %PG_RC%
)
del /q "%PSOUT%" "%PSERR%" 2>nul
exit /b %PG_RC%

:ps_kv
rem %1 = helper action that prints NAME=value lines, %2 = variable prefix.
rem For example DriveInfo with prefix DRV_ sets DRV_MEDIA and DRV_FS.
rem Same temp-file pattern as ps_get, so a failure is seen and logged.
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action %~1 >"%PSOUT%" 2>"%PSERR%"
set "PK_RC=%errorlevel%"
if "%PK_RC%"=="0" (
    if exist "%PSOUT%" for /f "usebackq tokens=1,* delims==" %%A in ("%PSOUT%") do set "%~2%%A=%%B"
) else (
    call :ps_fail %~1 %PK_RC%
)
del /q "%PSOUT%" "%PSERR%" 2>nul
exit /b %PK_RC%

:ps_fail
rem %1 = helper action, %2 = exit code. Logs the failure and whatever the
rem helper printed. Before the log exists (very early in a run) it does
rem nothing, and the caller's own error handling reports the problem.
if not defined LOG exit /b 0
if not exist "%LOG%" exit /b 0
call :log "Helper action %~1 failed with exit code %~2"
if exist "%PSOUT%" type "%PSOUT%" >>"%LOG%" 2>nul
if exist "%PSERR%" type "%PSERR%" >>"%LOG%" 2>nul
exit /b 0

:chars_ok
rem %1 = the NAME of a variable, %2 = the characters it may contain.
rem The value is read with delayed expansion and never pasted into a command
rem line, so characters such as & | > or quotes cannot run anything. Every
rem allowed character is used as a delimiter: if anything is left after the
rem leading _, the value has a character that is not allowed.
rem The tokens are compared with delayed expansion switched off, because
rem with it on a leftover "!" would vanish and the value would pass.
set "C_VAL=!%~1!"
if not defined C_VAL exit /b 1
set "C_OK=0"
for /f "tokens=1,* delims=%~2" %%C in ("_!C_VAL!") do (
    setlocal DisableDelayedExpansion
    if "%%C%%D"=="_" (
        endlocal
        set "C_OK=1"
    ) else (
        endlocal
    )
)
if "!C_OK!"=="1" exit /b 0
exit /b 1

:is_number
rem %1 = the NAME of a variable. Exit code 0 if it holds digits only.
call :chars_ok %~1 0123456789
exit /b %errorlevel%

:is_guid
rem %1 = the NAME of a variable. Exit code 0 if it holds the 8-4-4-4-12 hex
rem GUID form, so a bad value can never be passed to powercfg.
call :chars_ok %~1 0123456789abcdefABCDEF-
if errorlevel 1 exit /b 1
rem findstr is not used: it runs out of memory on a pattern this long and
rem then rejects every GUID. Instead the value must be 36 characters, with
rem dashes at positions 8, 13, 18 and 23 and nowhere else.
set "G_VAL=!%~1!"
if "!G_VAL:~35,1!"=="" exit /b 1
if not "!G_VAL:~36!"=="" exit /b 1
for %%P in (8 13 18 23) do if not "!G_VAL:~%%P,1!"=="-" exit /b 1
set "G_HEX=!G_VAL:-=!"
if "!G_HEX:~31,1!"=="" exit /b 1
if not "!G_HEX:~32!"=="" exit /b 1
exit /b 0

:due
rem Sets DUE=1 if weekly job %1 has not run in the last
rem WEEKLY_INTERVAL_DAYS days. The last-run date is kept in
rem State\Last_<name>.txt.
set "DUE=0"
rem A dry run shows every weekly step, whatever the dates say.
if "%DRYRUN%"=="1" (set "DUE=1" & exit /b 0)
if "%FORCE_WEEKLY%"=="1" (set "DUE=1" & exit /b 0)
call :ps_get DAYS_SINCE DaysSince "%STATE%\Last_%~1.txt"
call :is_number DAYS_SINCE
if errorlevel 1 (set "DUE=1" & exit /b 0)
if !DAYS_SINCE! GEQ %WEEKLY_INTERVAL_DAYS% set "DUE=1"
exit /b 0

:mark_done
rem Never records a date in a dry run. The steps do not call it then either.
if "%DRYRUN%"=="1" exit /b 0
>"%STATE%\Last_%~1.txt" echo(%TODAY%|| call :log "WARNING: could not record the last-run date for %~1."
exit /b 0
