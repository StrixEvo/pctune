PCTune 1.0.0 - maintenance for a Windows 11 laptop with an SSD
=================================================================

FILES
  PCTune.bat     Main script. Runs every step, logs everything.
  PCTune.ps1     PowerShell 5.1 helper. PCTune.bat calls it for the jobs
                 batch cannot do safely. Do not run it on its own.
  Install.bat    Locks the folder permissions and creates the scheduled task.
  Uninstall.bat  Removes the task and puts back every setting PCTune changed.
  Telemetry.ps1  PowerShell 5.1 helper for telemetry: the watchdog, the daily
                 report and the upload. See TELEMETRY below.
  Setup-Telemetry.bat  Asks once for the GitHub repo and token and stores
                 them encrypted.
  README.txt     This file.
  REVIEW.md      Instructions for Claude on how to review a report. Copy it
                 into the root of the private reports repo.

Created when it runs:
  Logs\PCTune_YYYY-MM-DD.log   Full log for each day. The newest 30 are kept.
  Logs\sfc_YYYY-MM-DD.txt      Raw sfc output on weekly-repair days.
  Logs\Install.log, Logs\Uninstall.log
  LastRun.txt                  Short summary of the last run.
  State\                       Last-run dates and the lock folder.
  Backup\                      Original values of every setting changed.
  token.dat, repo.txt          Telemetry token (encrypted) and repo name.
  Telemetry\                   Watchdog samples, alerts and unsent reports.
  Telemetry\token_status.txt   When the GitHub token expires (no secret).
  DryRun\                      Only after a dry run: its log, LastRun.txt,
                               samples and report. Safe to delete.

No wrapper file (VBS or similar) is needed. The task runs as SYSTEM, which
has no desktop, so nothing ever appears on screen.


SETUP
-----
1. Copy the whole PCTune folder to C:\PCTune on the laptop. It must be
   exactly there. Install.bat refuses to run anywhere else, because a
   folder a normal user owns could have its script swapped out.
   Do the copy from an administrator account (or approve the UAC prompt
   Explorer shows), into a new, empty C:\PCTune folder. Do not reuse a
   folder a normal user created earlier.
2. Optional: open PCTune.bat in Notepad and look at the CONFIG block at the
   top. Every step has a 1/0 switch. The defaults suit most laptops.
3. Right-click Install.bat and pick "Run as administrator", or just double-
   click it and accept the UAC prompt. It will:
     - check that this is Windows 11
     - check the folder for junctions, symbolic links and hard links, and
       stop if it finds any
     - lock the top folder so a normal user can no longer add anything to
       it, then check for links again
     - make Administrators the owner of the folder and set permissions so
       only SYSTEM and Administrators can change the files
     - check the permissions it just set
     - create the task "\PCTune\PCTune Daily Maintenance"
4. Read the output. The last line should be "Install finished."
5. For telemetry, run Setup-Telemetry.bat next. See TELEMETRY below.

Run Install.bat BEFORE any manual run. PCTune.bat checks the folder
permissions at the start of every run. If the folder was never locked, it
stops with exit code 6 and changes nothing.

If you edit PCTune.bat after installing, you need administrator rights to
save it. That is intended. If a run stops because of a folder owner or
permission problem, run Install.bat again.


TESTING BY HAND
---------------
Test 0, a dry run that changes nothing:
  From "Command Prompt (Admin)":
      C:\PCTune\PCTune.bat /dryrun
  Every step that would change something writes "DRYRUN: would ..." to
  the log and does nothing: no deleting, no restore point, no power plan,
  no DISM, sfc or chkdsk repair, no registry, no scheduled task, no
  permissions, no upload. The read-only parts run for real: the health
  report, the process list, the disk, RAM, driver and update checks, and
  the telemetry report (JSON and Markdown). The watchdog takes 3 samples
  first, so it takes about 3 minutes plus the health checks.
  Everything goes to C:\PCTune\DryRun\ and nowhere else:
      DryRun\LastRun.txt
      DryRun\Logs\PCTune_DryRun.log
      DryRun\reports\YYYY-MM-DD_<PC NAME>.json and .md
  A dry run does not need Install.bat first. If the folder is not locked
  it logs a WARNING and carries on. Install.bat /dryrun and
  Setup-Telemetry.bat /dryrun (also with /remove) work the same way.
  Before it writes its log, a dry run checks the folder for junctions,
  symbolic links and hard links. If it finds any, it stops (exit code 6
  for PCTune.bat and Setup-Telemetry.bat, 1 for Install.bat) and writes
  nothing.
  Setup-Telemetry.bat /dryrun asks for the repo and token and checks that
  the repo is private, but stores nothing and uploads nothing. In a folder
  that is not locked it skips the prompt: anyone who can change the
  scripts there could read a token typed into them. Run Install.bat first
  if you want to test the prompt.
  The switches are checked strictly. A typo such as /dryrn stops the
  script with exit code 2 before it does anything, so a mistyped dry run
  can never turn into a real run.
  A dry run from another folder stops with exit code 6 if the folder name
  holds a bracket, &, ! or ^, because those break the script's commands.
  Copy the files to C:\PCTune and run it from there.

Test 1, a manual run with a visible window:
  Open "Terminal (Admin)" or "Command Prompt (Admin)" and run:
      C:\PCTune\PCTune.bat
  The first run does all the weekly jobs too, so it can take 20-40 minutes
  because of DISM and sfc. To force the weekly jobs again later:
      C:\PCTune\PCTune.bat /weekly
  Then read C:\PCTune\LastRun.txt and today's log in C:\PCTune\Logs.
  The exit code is in %errorlevel%:
      0 = fine
      1 = a step failed (see log)
      2 = unknown switch, nothing was done
      3 = could not start logging (see LastRun.txt)
      4 = not Windows 11
      5 = could not get administrator rights
      6 = not in C:\PCTune, or the folder is not protected. Run
          Install.bat as administrator, then try again.

Test 2, the scheduled task itself (hidden, as SYSTEM):
      schtasks /run /tn "\PCTune\PCTune Daily Maintenance"
      schtasks /query /tn "\PCTune\PCTune Daily Maintenance" /v /fo list
  "Last Result" of 0 means success. 267009 means it is still running.
  If PCTune already ran today, a scheduled run logs "Already ran today"
  and stops. That is the once-a-day rule working. To test anyway, delete
  C:\PCTune\State\LastRunDate.txt from an admin prompt first.

Test 3, at logon:
  Sign out and back in, wait 4 minutes, then check Task Scheduler or
  LastRun.txt for a new run.

Check the restore point:
  Start > "Create a restore point" > System Restore. A point named
  "PCTune 1.0.0 <date>" should be listed.


UNINSTALL
---------
Run Uninstall.bat (it asks for admin rights). It removes both tasks
(maintenance and telemetry watchdog), deletes the stored telemetry token,
and puts back the power plan, disk idle timer, Fast Startup and restore-point
settings from the Backup folder. The logs stay. To remove everything
afterwards, from an admin prompt:
    rd /s /q C:\PCTune

Details:
  - If a PCTune run started less than 300 minutes ago, it stops with exit
    code 4 so it does not undo settings halfway through a run. Wait and
    run it again.
  - If the task was never installed, it says so. That is not an error.
  - Deleting token.dat does not stop the token working. Revoke it on
    GitHub: Settings > Developer settings > Personal access tokens >
    Fine-grained tokens > the PCTune token > Delete.
  - The disk idle timer is saved per power plan (diskidle_<GUID>.txt) and
    each one is put back on its own plan.
  - Hibernation is turned off again only if PCTune turned it on. If it was
    already on, it is left on.
  - For a setting PCTune never changed, it says "No backup ... nothing to
    restore". That is normal.
  - System Protection is NOT switched off, even if PCTune switched it on
    (Backup\protection_original.txt records that). Switching it off would
    delete every restore point. Do it yourself in System Properties if you
    really want to.
  - Uninstall.bat reads the backups only if the folder is still locked
    the way Install.bat left it. If not, it stops and changes nothing.
  - Exit codes: 0 done, 1 some settings not restored (see
    Logs\Uninstall.log), 2 unknown switch (it takes none), 4 a run is in
    progress, 5 no admin rights, 6 not in C:\PCTune or the folder is not
    protected.


WHAT EACH STEP DOES, AND HOW MUCH IT HELPS
------------------------------------------
Being honest: on an SSD, most of these keep the system healthy and free up
space. They do not make it noticeably faster. The things that really make
boot slow are in MANUAL CHECKS below, and the health report in the log
shows you which ones apply.

System Restore point (every run, before any change)
  A safety net. Windows normally allows one restore point per 24 hours.
  The helper briefly sets the documented SystemRestorePointCreationFrequency
  value to 0, creates the point, checks it really exists (by its sequence
  number, so an older point cannot pass for it), then puts the old value
  back. If no restore point could be made, the settings changes in
  that run (power plan, Fast Startup, network reset) are skipped.

Temp files (daily)
  Deletes files older than 2 days from C:\Windows\Temp and every user's
  AppData\Local\Temp. Newer files are left because a running installer may
  still need them. Junctions and symbolic links are never followed. Each
  item is opened first, checked through the open handle, then deleted
  through that same handle, so it cannot be swapped for a link in between.
  Links and hard-linked files are left alone and counted as "refused" in
  the log. A refused count above 0 is not an error.
  Gain: disk space. No direct speed gain unless the drive was nearly full.

Old error reports (daily)
  Windows Error Reporting files older than 7 days. Space only.

Windows Update download cache (daily)
  Empties C:\Windows\SoftwareDistribution\Download only, never the whole
  SoftwareDistribution folder (that holds update history). The Windows
  Update and BITS services are stopped first and restarted afterwards.
  Skipped if an update is being installed at that moment.
  Gain: space, often a few hundred MB to a few GB after big updates.

Delivery Optimization cache (daily)
  The cache Windows uses to share updates with other PCs. Uses Microsoft's
  own Delete-DeliveryOptimizationCache command. Space only.

Component cleanup (weekly)
  DISM /StartComponentCleanup removes superseded system files from WinSxS.
  Windows does this itself, just more slowly. /ResetBase is not used, so
  updates can still be uninstalled. Space only.

SSD TRIM (weekly, SSD only)
  defrag C: /L sends TRIM. It never defragments. Windows already does this
  weekly via Optimize Drives, so this is a safety net. Keeps write speed
  steady over time. You will not feel a difference if TRIM was already
  working.

Thumbnail cache (weekly)
  Deletes thumbcache_*.db. Explorer rebuilds it. Fixes broken thumbnails.
  The signed-in user's files are locked and skipped. Space only.

chkdsk /scan (weekly, NTFS only)
  Online file system check. No reboot, no /f. If it reports problems it
  cannot fix online, the log tells you to run chkdsk C: /f and restart.

DISM /RestoreHealth then sfc /scannow (weekly)
  Repairs corrupted Windows system files. DISM fixes the store that sfc
  copies from, so it goes first. Takes 10-30 minutes. Only helps if there
  is corruption. Needs internet for DISM to download good copies.

Power plan
  If High performance, Ultimate Performance or Power saver is active, it
  switches to Balanced. Balanced is Microsoft's recommendation for laptops:
  full speed when busy, low power when idle. OEM plans are left alone.

SSD not power-throttled (SSD only)
  Sets "Turn off hard disk after" on mains power to Never. Battery setting
  is left alone. Honest gain: very small on an SSD, and none at boot.

Fast Startup (report only by default)
  Recommendation: leave it ON. It saves the kernel to disk at shutdown so
  the next power-on is faster. Restart always does a full boot anyway.
  Turn it off only for dual-boot, or if a device only works after Restart.
  Set DO_FASTSTARTUP_ENABLE=1 to let the script switch it on.

DNS flush / Winsock and IP reset (off by default)
  Network fixes, not speed tweaks. The reset only runs on manual runs and
  needs a restart afterwards.

Health report (every run)
  Written into the log:
    - boot times from event 100 (BootTime and MainPathBootTime in seconds)
    - SSD health, wear and temperature, when the drive reports them
    - free space before and after, and MB recovered
    - total and free RAM
    - startup apps from Run keys, Startup folders and logon tasks
    - top 10 processes by memory
    - Kernel-Power, disk and NTFS warnings and errors from the last 7 days


TELEMETRY
---------
The laptop's owner has agreed to this. Every run that has it switched on
writes this line to the log:
  NOTICE: telemetry is ON. ...
To switch it off, set DO_TELEMETRY=0 in the CONFIG block of PCTune.bat.
The next run removes the watchdog task, and nothing more is collected or
uploaded. Setup-Telemetry.bat /remove also deletes the stored token.

What it collects, once a day, into reports/YYYY-MM-DD_<PC NAME>.json and a
readable .md summary of the same data:
  1. Every drive: total, used and free GB, and % used and free.
  2. RAM: total, used at the first sample after logon (about 5 minutes
     in, usually close to idle) and the peak for each day.
  3. CPU: average and peak, per core, for each day.
  4. Every running process: name, PID, CPU % (of the whole processor and
     of one core), RAM MB and path.
  5. Startup apps: Run keys, Startup folders and scheduled tasks.
  6. Installed programs with version and install date.
  7. Chipset, graphics, storage and network drivers with version and date.
     Drivers older than 2 years are flagged.
  8. Pending Windows Updates, including optional driver updates.
  9. SSD health, boot times (event 100), and the last 7 days of
     Kernel-Power, disk, NTFS and app crash errors.
  10. Model, BIOS version and date, Windows build, battery health.
It never collects passwords, browser history, files, documents,
screenshots, keystrokes or Wi-Fi keys. Process paths and program names can
still show what software is installed. That is the point of the report.

How it works:
  - The watchdog task "\PCTune\PCTune Watchdog" runs as SYSTEM, hidden,
    at below-normal priority. It starts 5 minutes after logon, and once a
    day at a fixed time as well, so it comes back after sleep or a crash
    without needing a new logon. Only one copy runs at a time.
  - Every 60 seconds it records CPU, RAM and the top processes into
    Telemetry\samples\. A process that, in 3 samples in a row (so for at
    least 2 minutes), is over 80 % of the whole processor, or at 90 % or
    more of one core, or over 1 GB RAM, is written to
    Telemetry\samples\alerts_YYYY-MM-DD.csv with its name, PID, which test
    it failed (cpu, core, ram, or several joined with +), its peak CPU as
    both % of the whole processor and % of one core, and how long it
    lasted. The row is written as soon as the 2 minutes pass, and
    again when it ends, so a shutdown does not lose it.
  - CPU % is a share of the whole processor, as in Task Manager. On a
    4-core, 8-thread laptop, one program maxing out a single thread shows
    as about 12 %, so it will not trigger the 80 % alert. That is what the
    "one core" test is for: % of one core = % of the whole processor x the
    number of logical cores (12.5 % x 8 = 100 %). It can go above 100 for
    a program using several cores. The report shows both figures.
  - The watchdog sleeps between samples. Its own CPU use is measured and
    shown in each report under "watchdog", so you can check it is small.
  - The daily PCTune run, 3 minutes after logon, builds one report. It
    covers every full day since the last report (up to 14 days), never
    today, plus a snapshot of the laptop taken now. Days with no logon
    are still covered by the next report.
  - If there is no internet, the report stays in Telemetry\outbox\ and is
    sent on the next run. If a report has waited more than 2 days, the
    daily run shows the telemetry step as FAIL. Unsent reports older than
    14 days are deleted and the log says how many.
  - The watchdog's own errors go to Telemetry\samples\watchdog.log. The
    report says if a day has no samples.
  - Every GitHub reply says when the token expires. That date is kept in
    Telemetry\token_status.txt. When 14 days or fewer are left, the top
    of the report .md and LastRun.txt show a WARNING. Once it has expired,
    the upload stops with FAIL "Run Setup-Telemetry.bat to enter a new
    token", and the reports wait in the outbox until you do.

Setup, once:
  1. On GitHub, create a new repository and set it to PRIVATE. An empty
     one is fine. Never use a public repo or a gist: the upload refuses a
     repo that is not private, and checks again before every upload.
  2. Create a fine-grained token: GitHub > Settings > Developer settings >
     Personal access tokens > Fine-grained tokens > Generate new token.
       - Repository access: Only select repositories > that one repo.
       - Permissions: Repository permissions > Contents > Read and write.
         Nothing else. (Metadata read-only is added automatically.)
       - Expiration: set one, for example 1 year, and put a reminder in
         your calendar to renew it.
     Copy the token. GitHub shows it only once. It starts with
     github_pat_. Setup refuses classic tokens (ghp_...), because they
     cannot be limited to one repo.
  3. On the laptop, open "Command Prompt (Admin)" and run:
         cd /d C:\PCTune
         Setup-Telemetry.bat
     Type the repo as owner/name, then paste the token. The token is not
     shown. Setup checks that the repo is private and that the token can
     write to it by uploading reports/.setup_<PC NAME>.txt. Then it stores
     the token and creates the watchdog task.
  4. The first full report arrives after the next daily run.
  To change the repo or token later, run Setup-Telemetry.bat again.

Where the token is kept, and how safe that is:
  - token.dat holds the token encrypted with Windows DPAPI, machine scope.
    The file can only be read by SYSTEM and Administrators. The token is
    never written in plain text to a script, a log or the screen.
  - Machine scope is used because Setup runs as your admin account but
    the task runs as SYSTEM. User scope would tie the token to the admin
    account and the task could not read it.
  - Be clear about the limit: any administrator on this laptop, or any
    program running as administrator, can decrypt it. The encryption
    stops the file being useful if it is copied off the laptop. The file
    permissions are the real protection.
  - That is why the token is limited to one private repo with Contents
    only, and has an expiry date. If the laptop is lost or you are in any
    doubt, revoke it on GitHub. That stops it at once.

Reading the reports at home:
  1. Once, on your own computer:
         git clone https://github.com/<owner>/<repo>.git
     Sign in when Git asks (GitHub Desktop works too). Use your own
     GitHub login here, not the laptop's token.
  2. Each time you want the latest:
         cd <repo>
         git pull
  3. Open reports\<date>_<PC NAME>.md for the readable summary. The .json
     file has the full detail.
  You can also read them on github.com in the repo's reports folder.

Getting Claude to review them:
  In the cloned folder, start Claude Code and ask, for example:
      Review the latest report in reports/. What is slowing this laptop
      down, and what should I fix first?
  or, to spot trends:
      Compare the last 7 reports in reports/ and tell me what has changed.
  Claude reads the .json and .md files directly. Copy REVIEW.md from
  C:\PCTune into the root of the repo once (commit and push it). It tells
  Claude which numbers count as bad, what to compare with older reports,
  and to list fixes safest first. Then just ask:
      Review the latest report following REVIEW.md.


THINGS PCTune DELIBERATELY DOES NOT DO
-------------------------------------
No RAM "cleaning", no Prefetch deletion, no disabling SysMain or Search,
no service disabling, no pagefile, bcdedit, TCP or "SystemResponsiveness"
type tweaks, no Ultimate Performance plan, no app removal, no clearing of
event logs, and no changes to Defender, the firewall, UAC or Windows
Update. These are either useless on Windows 11 or make things worse.
Personal files, Downloads, Desktop, Documents, the Recycle Bin and browser
data are never touched.


MANUAL CHECKS THE SCRIPT CANNOT DO
----------------------------------
These usually matter far more for a slow boot than anything above.

1. Startup apps
   Task Manager > Startup apps. Disable anything you do not need at
   sign-in (updaters, chat apps, game launchers, OEM helpers). Check the
   "Startup impact" column. The log's report section lists them too.

2. Boot time numbers
   In the log, look at MainPathBootTime. Over about 30 seconds on an SSD
   points to drivers or startup apps. Event Viewer > Applications and
   Services Logs > Microsoft > Windows > Diagnostics-Performance >
   Operational, events 101-110 name the slow drivers and apps.

3. BIOS / UEFI
   - Update the BIOS from the laptop maker's support page.
   - SATA mode should be AHCI (or the maker's NVMe/RST default). Do not
     change this on a working install without research, because Windows
     may stop booting.
   - Turn off network (PXE) boot if it is on, and put Windows Boot Manager
     first in the boot order.
   - "Fast boot" in the BIOS can help, if the maker offers it.

4. Drivers
   Get chipset, storage (Intel RST / AMD), graphics and Wi-Fi drivers from
   the laptop maker or Intel/AMD, not driver-updater tools. Device Manager
   should show no yellow warnings.

5. SSD health and firmware
   If the report shows Wear above about 80, high error counts, or health
   anything other than Healthy, back up and plan a replacement. Check the
   maker's site for SSD firmware updates.

6. RAM
   If the report shows less than about 1.5 GB free with only normal apps
   open, the laptop needs more RAM (8 GB is the practical minimum for
   Windows 11, 16 GB is comfortable). Run Windows Memory Diagnostic
   (mdsched.exe) if you see random crashes.

7. Bloatware
   Settings > Apps > Installed apps. Uninstall OEM trial software, extra
   antivirus suites (Defender is enough, two antivirus products slow
   everything), toolbars and "PC optimiser" apps.

8. Free space
   Keep at least 15-20 % of the SSD free. SSDs slow down when nearly full.

9. Kernel-Power 41 errors in the report
   These mean the laptop lost power or crashed without a clean shutdown.
   Check the battery, the charger, overheating, and BIOS and driver updates.


KNOWN LIMITS
------------
- Microsoft does not document sfc exit codes. A non-zero code is logged as
  a failure to look at, so read the sfc lines in the log.
- netsh int ip reset often shows "Access is denied" for one registry key
  even when the reset worked. Read the log lines.
- The report lists Run keys only for users who are signed in, because the
  task cannot read the hives of users who are not signed in.
- The scheduled task has a 4-hour time limit. A lock older than 300
  minutes is treated as left over from a crash or power cut.
- The folder check catches a copy that was never installed and permissions
  that were loosened later. It cannot catch someone who already had
  administrator rights and replaced PCTune.ps1 or PCTune.bat. An
  administrator can do anything to the PC anyway.
- The power plan step recognises the built-in plans by their fixed GUIDs.
  A copied plan (for example a duplicated Ultimate Performance plan) has a
  random GUID, so PCTune does not recognise it and leaves it alone.
- Telemetry needs the laptop's clock to be roughly right: GitHub refuses
  the upload otherwise, and the report waits in the outbox.
- The token can be decrypted by any administrator on the laptop (see
  TELEMETRY). Limit it to one private repo and give it an expiry date.
- Install.bat runs PCTune.ps1 to check the folder before locking it. If a
  normal user could change the files before you installed, copy them again
  from a trusted source first (see SETUP step 1).
- A dry run in a folder that was never locked runs PCTune.ps1 and
  Telemetry.ps1 as administrator from a folder a normal user may be able
  to change. The link check runs first, but a user who can change the
  scripts could change them between the check and the run. Do dry runs on
  your own PC, or after Install.bat.
- DryRun\ can be read by every user on the PC, like Logs\. The dry-run
  report holds the same data as a real report, never the token.
- Install.bat checks for links again after it locks the top folder. A
  file deeper inside that a normal user was allowed to change before the
  install keeps that permission for the few seconds until the owner and
  permissions are reset in the next step.
