@echo off
rem =========================================================================
rem  Uninstall.bat  -  removes the PCTune task and undoes its setting changes
rem  Version 1.0.0
rem
rem  What it does:
rem   1. Deletes the scheduled tasks "\PCTune\PCTune Watchdog" (telemetry)
rem      and "\PCTune\PCTune Daily Maintenance", and deletes the stored
rem      telemetry token (token.dat) and repo name. Revoke the token on
rem      GitHub as well: deleting the file does not stop it working.
rem   2. Puts back every setting PCTune.bat changed, using the copies it saved
rem      in Backup\ the first time it changed each one:
rem        disk idle on mains     Backup\diskidle_<plan GUID>.txt (one per plan)
rem                               Backup\diskidle_original.txt (older versions)
rem        power plan             Backup\power_scheme_original.txt
rem        Fast Startup           Backup\faststartup_original.txt
rem        restore-point timer    Backup\restorefreq_original.txt
rem      A backup file only exists if PCTune actually changed that setting.
rem      After each one is restored, its file is renamed to *.restored so
rem      running this again does not apply it twice.
rem   3. Leaves the folder and logs in place, so you can read what happened.
rem      To delete the folder afterwards, from an admin prompt:
rem        rd /s /q "%SystemDrive%\PCTune"
rem
rem  Not undone on purpose: if PCTune switched System Protection on (recorded
rem  in Backup\protection_original.txt), it stays on. Switching it off would
rem  delete every restore point on the drive. Turn it off yourself in
rem  System Properties > System Protection if you really want that.
rem
rem  The .reg files in Backup\ are copies of the whole keys taken before any
rem  change, kept for reference. The restore uses the saved values instead,
rem  because importing a .reg file cannot remove a value that did not exist
rem  before.
rem
rem  Exit codes: 0 done, 1 finished with errors, 2 unknown switch, 4 a
rem  PCTune run is in progress, 5 no administrator rights, 6 not in
rem  %SystemDrive%\PCTune, or the folder is not protected (Install.bat has
rem  not been run, or the folder was changed since).
rem =========================================================================

rem The path is read before delayed expansion is on, because delayed
rem expansion would remove any "!" in the folder name.
setlocal EnableExtensions DisableDelayedExpansion
set "PCTUNE_SELF=%~f0"
set "BASE=%~dp0"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"
rem Only run from the folder Install.bat locked down, so the helper script
rem that runs as administrator below is the protected copy.
if /i "%BASE%"=="%SystemDrive%\PCTune" goto :location_ok
echo ERROR: Uninstall.bat must be in %SystemDrive%\PCTune. It is in "%BASE%".
exit /b 6
:location_ok
setlocal EnableDelayedExpansion

set "VERSION=1.0.0"
set "BACKUP=%BASE%\Backup"
set "STATE=%BASE%\State"
set "LOCKDIR=%STATE%\running.lock"
set "LOCK_STALE_MIN=300"
set "HELPER=%BASE%\PCTune.ps1"
set "SYS32=%SystemRoot%\System32"
set "PSEXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"
set "POWERCFG=%SYS32%\powercfg.exe"
set "REGEXE=%SYS32%\reg.exe"
set "FINDSTR=%SYS32%\findstr.exe"
set "KEY_SMPOWER=HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
set "KEY_SR=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
set "ALREADY_ELEVATED=0"
set /a ERRORS=0
set /a RESTORED=0
rem Uninstall.bat takes no switches of its own. /elevated is added by the
rem copy that asks for administrator rights. Anything else stops here.
if not [%1]==[] (
    if /i not "%~1"=="/elevated" goto :bad_arg
    if not [%2]==[] goto :bad_arg
    set "ALREADY_ELEVATED=1"
)
goto :args_ok
:bad_arg
echo ERROR: unknown switch. Uninstall.bat takes no switches. Nothing was done.
exit /b 2
:args_ok

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
    "%PSEXE%" -NoProfile -NonInteractive -Command "Start-Process -FilePath ([Management.Automation.WildcardPattern]::Escape($env:PCTUNE_SELF)) -ArgumentList '/elevated' -Verb RunAs"
    if errorlevel 1 (
        echo ERROR: the UAC prompt was cancelled or failed.
        exit /b 5
    )
    exit /b 0
)

if not exist "%BASE%\Logs\" mkdir "%BASE%\Logs" 2>nul
set "ULOG=%BASE%\Logs\Uninstall.log"
call :say "======================================================================"
call :say "PCTune %VERSION% uninstall started on %COMPUTERNAME% by %USERNAME%"

rem The backups below are read and written back to the registry as
rem administrator. They are only trusted if the folder is still locked the
rem way Install.bat left it, so no normal user could have changed them.
if not exist "%HELPER%" (
    call :say "ERROR: PCTune.ps1 is missing from %BASE%. Nothing was changed."
    exit /b 6
)
(call)
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action CheckFolder -Path "%BASE%" -LogFile "%ULOG%"
if errorlevel 1 (
    call :say "ERROR: %BASE% is not protected, so the backups in it cannot be trusted. Nothing was changed. See %ULOG%"
    exit /b 6
)

rem --- 0. Is PCTune running right now? ------------------------------------
rem Restoring settings while a run is changing them would leave a mix of
rem both. A lock older than LOCK_STALE_MIN minutes is left over from a run
rem that was cut off, so it does not block the uninstall.
if exist "%LOCKDIR%\" (
    set "LOCK_AGE="
    if exist "%HELPER%" (
        set "UTMP=%STATE%\uninst_%RANDOM%%RANDOM%.tmp"
        (call)
        "%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action MinutesSince -Path "%LOCKDIR%" >"!UTMP!" 2>nul
        if not errorlevel 1 if exist "!UTMP!" for /f "usebackq delims=" %%L in ("!UTMP!") do if not defined LOCK_AGE set "LOCK_AGE=%%L"
        del /q "!UTMP!" 2>nul
    )
    call :is_number LOCK_AGE
    if errorlevel 1 (
        call :say "ERROR: a PCTune run may be in progress and its age could not be read. Try again later."
        exit /b 4
    )
    if !LOCK_AGE! LSS %LOCK_STALE_MIN% (
        call :say "ERROR: a PCTune run started !LOCK_AGE! minutes ago and may still be running. Try again when it has finished."
        exit /b 4
    )
    call :say "Found a stale lock from a run !LOCK_AGE! minutes ago. Continuing."
)

rem --- 1. Scheduled tasks --------------------------------------------------
rem The tasks are removed first so they cannot start again halfway through
rem the restore. The telemetry watchdog goes first, so the \PCTune\ task
rem folder is empty when the main task is removed and can be deleted too.
rem The stored GitHub token is then deleted from this laptop. It still works
rem until it is revoked on GitHub, so the message below says so.
if exist "%BASE%\Telemetry.ps1" (
    (call)
    "%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BASE%\Telemetry.ps1" -Action RemoveWatchdog -Base "%BASE%" -LogFile "%ULOG%"
    set "TW_RC=!errorlevel!"
    if "!TW_RC!"=="0" (
        call :say "Telemetry watchdog task removed."
    ) else if "!TW_RC!"=="2" (
        call :say "Telemetry watchdog task was not installed. Nothing to remove."
    ) else (
        call :say "ERROR: could not remove the telemetry watchdog task, exit code !TW_RC!. See %ULOG%"
        set /a ERRORS+=1
    )
    (call)
    "%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%BASE%\Telemetry.ps1" -Action Forget -Base "%BASE%" -LogFile "%ULOG%"
    set "TF_RC=!errorlevel!"
    if "!TF_RC!"=="0" (
        call :say "Telemetry token and repo name deleted from this laptop. Revoke the token on GitHub too: Settings, Developer settings, Personal access tokens. System Restore points or backups made while it was stored may still hold an encrypted copy."
    ) else if "!TF_RC!"=="2" (
        call :say "No telemetry token was stored. Nothing to delete."
    ) else (
        call :say "ERROR: could not delete the telemetry token, exit code !TF_RC!. Delete %BASE%\token.dat by hand and revoke the token on GitHub. See %ULOG%"
        set /a ERRORS+=1
    )
) else (
    rem Without Telemetry.ps1, schtasks removes the watchdog if it exists.
    rem The query comes first, so "not installed" is not counted as a
    rem failure, and the delete is checked by querying again.
    "%SYS32%\schtasks.exe" /Query /TN "\PCTune\PCTune Watchdog" >nul 2>&1
    if not errorlevel 1 (
        "%SYS32%\schtasks.exe" /Delete /TN "\PCTune\PCTune Watchdog" /F >>"%ULOG%" 2>&1
        "%SYS32%\schtasks.exe" /Query /TN "\PCTune\PCTune Watchdog" >nul 2>&1
        if errorlevel 1 (
            call :say "Telemetry watchdog task removed."
        ) else (
            call :say "ERROR: could not remove the telemetry watchdog task. Delete \PCTune\PCTune Watchdog in Task Scheduler. See %ULOG%"
            set /a ERRORS+=1
        )
    )
    if exist "%BASE%\token.dat" (
        call :say "WARNING: Telemetry.ps1 is missing, so %BASE%\token.dat was not deleted. Delete it by hand and revoke the token on GitHub."
        set /a ERRORS+=1
    )
)

if exist "%HELPER%" (
    (call)
    "%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%HELPER%" -Action UnregisterTask -LogFile "%ULOG%"
    set "UT_RC=!errorlevel!"
    if "!UT_RC!"=="0" (
        call :say "Scheduled task removed."
    ) else if "!UT_RC!"=="2" (
        call :say "Scheduled task was not installed. Nothing to remove."
    ) else (
        call :say "ERROR: could not remove the scheduled task, exit code !UT_RC!. See %ULOG%"
        set /a ERRORS+=1
    )
) else (
    rem Without the helper, fall back to schtasks, which is always present.
    (call)
    "%SYS32%\schtasks.exe" /Delete /TN "\PCTune\PCTune Daily Maintenance" /F >>"%ULOG%" 2>&1
    if errorlevel 1 (
        call :say "ERROR: scheduled task not found or could not be removed with schtasks. See %ULOG%"
        set /a ERRORS+=1
    ) else (
        call :say "Scheduled task removed."
    )
)

rem --- 2a. Disk idle on mains ---------------------------------------------
rem This is restored before the power plan. Each backup names the plan it
rem belongs to, so it is put back on that plan whichever plan is active.
set "DI_FOUND=0"
for %%F in ("%BACKUP%\diskidle_*.txt") do (
    set "DI_FOUND=1"
    call :restore_diskidle "%%~fF"
)
if "%DI_FOUND%"=="0" call :say "No backup for disk idle on mains, nothing to restore."

rem --- 2b. Power plan ------------------------------------------------------
set "F=%BACKUP%\power_scheme_original.txt"
if exist "%F%" (
    set "BK_SCHEME="
    for /f "usebackq tokens=1,* delims==" %%A in ("%F%") do set "BK_%%A=%%B"
    call :is_guid BK_SCHEME
    if errorlevel 1 (
        call :say "ERROR: %F% is not in the expected format. Skipped."
        set /a ERRORS+=1
    ) else (
        (call)
        "%POWERCFG%" /setactive !BK_SCHEME! >>"%ULOG%" 2>&1
        if errorlevel 1 (
            call :say "ERROR: could not switch back to power plan !BK_SCHEME!. It may have been deleted."
            set /a ERRORS+=1
        ) else (
            call :say "Power plan restored to !BK_SCHEME!."
            set /a RESTORED+=1
            call :mark_restored "%F%"
        )
    )
) else (
    call :say "No backup for the power plan, nothing to restore."
)

rem --- 2c. Fast Startup ----------------------------------------------------
set "F=%BACKUP%\faststartup_original.txt"
if exist "%F%" (
    set "BK_HIBERBOOT="
    set "BK_HIBERNATE="
    set "BK_HIBERNATE_CHANGED="
    for /f "usebackq tokens=1,* delims==" %%A in ("%F%") do set "BK_%%A=%%B"
    set "FS_FAIL=0"
    rem "missing" means the value did not exist before, so delete it rather
    rem than guess what it should be.
    if /i "!BK_HIBERBOOT!"=="missing" (
        "%REGEXE%" query "%KEY_SMPOWER%" /v HiberbootEnabled >nul 2>&1
        if not errorlevel 1 (
            (call)
            "%REGEXE%" delete "%KEY_SMPOWER%" /v HiberbootEnabled /f >>"%ULOG%" 2>&1
            if errorlevel 1 set "FS_FAIL=1"
        )
    ) else (
        call :is_number BK_HIBERBOOT
        if errorlevel 1 (
            set "FS_FAIL=1"
        ) else (
            (call)
            "%REGEXE%" add "%KEY_SMPOWER%" /v HiberbootEnabled /t REG_DWORD /d !BK_HIBERBOOT! /f >>"%ULOG%" 2>&1
            if errorlevel 1 set "FS_FAIL=1"
        )
    )
    rem PCTune.bat writes HIBERNATE_CHANGED=1 just before it turns
    rem hibernation on. Only then is it turned off again here. If hibernation
    rem was already on, or the user turned it on, it is left alone.
    if "!BK_HIBERNATE_CHANGED!"=="1" (
        (call)
        "%POWERCFG%" /hibernate off >>"%ULOG%" 2>&1
        if errorlevel 1 set "FS_FAIL=1"
    )
    if "!FS_FAIL!"=="1" (
        call :say "ERROR: Fast Startup settings were not fully restored. See %ULOG%"
        set /a ERRORS+=1
    ) else (
        if "!BK_HIBERNATE_CHANGED!"=="1" (
            call :say "Fast Startup restored: HiberbootEnabled=!BK_HIBERBOOT!, hibernation turned off again."
        ) else (
            call :say "Fast Startup restored: HiberbootEnabled=!BK_HIBERBOOT!, hibernation left as it was."
        )
        set /a RESTORED+=1
        call :mark_restored "%F%"
    )
) else (
    call :say "No backup for Fast Startup, nothing to restore."
)

rem --- 2d. Restore-point timer ---------------------------------------------
rem PCTune.ps1 puts this value back after every run. This only matters if a
rem run was cut off, for example by a power cut, at the moment the value was
rem set to 0.
set "F=%BACKUP%\restorefreq_original.txt"
if exist "%F%" (
    set "BK_FREQ="
    for /f "usebackq tokens=1,* delims==" %%A in ("%F%") do set "BK_%%A=%%B"
    set "RF_FAIL=0"
    if /i "!BK_FREQ!"=="missing" (
        "%REGEXE%" query "%KEY_SR%" /v SystemRestorePointCreationFrequency >nul 2>&1
        if not errorlevel 1 (
            (call)
            "%REGEXE%" delete "%KEY_SR%" /v SystemRestorePointCreationFrequency /f >>"%ULOG%" 2>&1
            if errorlevel 1 set "RF_FAIL=1"
        )
    ) else (
        rem The backup holds the DWORD in hex, such as 0x5a0. set /a turns
        rem that back into a decimal number for reg add.
        rem set /a evaluates what it is given, so only hex digits and the x
        rem of 0x are let through to it.
        set "RF_DEC="
        call :chars_ok BK_FREQ 0123456789abcdefABCDEFx
        if not errorlevel 1 set /a RF_DEC=!BK_FREQ! 2>nul
        call :is_number RF_DEC
        if errorlevel 1 (
            set "RF_FAIL=1"
        ) else (
            (call)
            "%REGEXE%" add "%KEY_SR%" /v SystemRestorePointCreationFrequency /t REG_DWORD /d !RF_DEC! /f >>"%ULOG%" 2>&1
            if errorlevel 1 set "RF_FAIL=1"
        )
    )
    if "!RF_FAIL!"=="1" (
        call :say "ERROR: could not restore SystemRestorePointCreationFrequency. See %ULOG%"
        set /a ERRORS+=1
    ) else (
        call :say "Restore-point timer restored to: !BK_FREQ!."
        set /a RESTORED+=1
        call :mark_restored "%F%"
    )
) else (
    call :say "No backup for the restore-point timer, nothing to restore."
)

if exist "%BACKUP%\protection_original.txt" (
    call :say "Note: PCTune switched System Protection on. It is left on so your restore points are kept."
)

if %ERRORS% GTR 0 (
    call :say "Uninstall finished with %ERRORS% error(s) and %RESTORED% setting(s) restored. See %ULOG%"
    exit /b 1
)
call :say "Uninstall finished. %RESTORED% setting(s) restored. Logs and backups are kept in %BASE%."
exit /b 0


:restore_diskidle
rem %1 = one diskidle backup file holding SCHEME= and AC= lines.
set "F=%~1"
set "BK_SCHEME="
set "BK_AC="
for /f "usebackq tokens=1,* delims==" %%A in ("%F%") do set "BK_%%A=%%B"
call :is_guid BK_SCHEME
if errorlevel 1 goto :di_bad
call :is_number BK_AC
if errorlevel 1 goto :di_bad
(call)
"%POWERCFG%" /setacvalueindex !BK_SCHEME! SUB_DISK DISKIDLE !BK_AC! >>"%ULOG%" 2>&1
if errorlevel 1 (
    call :say "ERROR: could not restore the disk idle setting on plan !BK_SCHEME!. The plan may have been deleted."
    set /a ERRORS+=1
    exit /b 0
)
rem Re-applying the active plan makes a change to it take effect now.
(call)
"%POWERCFG%" /setactive SCHEME_CURRENT >>"%ULOG%" 2>&1
if errorlevel 1 (
    call :say "WARNING: disk idle restored on plan !BK_SCHEME!, but re-applying the active plan failed. It takes effect after a restart."
)
call :say "Disk idle on mains restored to !BK_AC! seconds on plan !BK_SCHEME!."
set /a RESTORED+=1
call :mark_restored "%F%"
exit /b 0
:di_bad
call :say "ERROR: %F% is not in the expected format. Skipped."
set /a ERRORS+=1
exit /b 0

:say
echo(%~1
>>"%ULOG%" echo(%DATE% %TIME%  %~1
exit /b 0

:mark_restored
rem Rename so a second uninstall does not apply the same backup again.
if exist "%~1.restored" del /q "%~1.restored" 2>nul
ren "%~1" "%~nx1.restored" 2>nul
if errorlevel 1 call :say "WARNING: could not rename %~1 after restoring it."
exit /b 0

:chars_ok
rem %1 = the NAME of a variable, %2 = the characters it may contain.
rem The value is read with delayed expansion and never pasted into a command
rem line, so characters such as & | > or quotes in a damaged backup file
rem cannot run anything. Every allowed character is used as a delimiter:
rem if anything is left after the leading _, the value has a character that
rem is not allowed.
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
rem %1 = the NAME of a variable. Digits only.
call :chars_ok %~1 0123456789
exit /b %errorlevel%

:is_guid
rem %1 = the NAME of a variable. Accepts the 8-4-4-4-12 hex GUID form only,
rem so a damaged backup file cannot pass anything else to powercfg. The
rem characters are checked first, so the echo below only ever sees hex
rem digits and dashes.
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
