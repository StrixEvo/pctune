# How to review a PCTune report

This file is for Claude (or a person) reviewing the reports that PCTune uploads
to this private repo from a friend's laptop. Put it in the root of the repo.
Reports are in `reports/` as pairs: `YYYY-MM-DD_HOSTNAME.json` (full detail)
and `YYYY-MM-DD_HOSTNAME.md` (summary). Read the newest pair first, then the
older ones for comparison.

The goal is a short list of things to remove or fix on the laptop, safest fix
first. Do not suggest anything on the "never suggest" list at the end.

## 1. Before judging anything

- Check `schemaVersion` in the JSON. This file was written for schema 4.
  If it is lower, some fields below may be missing; say so and do not guess.
- Read the `## Collection errors` section of the .md and the `errors` list in
  the JSON. A part that failed to collect is "unknown", not "fine". Say
  which parts are unknown.
- If the .md starts with a GitHub token warning, put it first in your answer:
  uploads stop when the token expires. The fix is to run
  `Setup-Telemetry.bat` on the laptop with a new token.
- If the .md says "DRY RUN - not uploaded", it came from a test run, not the
  laptop. Review it only as a format check.

## 2. What counts as bad

Each line gives where to look and the limit. "Bad" means it goes on the list.
"Watch" means mention it only if it is getting worse across reports.

| Check | Where in the JSON | Bad when |
|---|---|---|
| Free disk space | `disks[]` where `drive` is the system drive, `freePct` | under 15 % free |
| Idle RAM | `ram.days[].stats.ramFirstSampleAfterLogonUsedMB` divided by `ramTotalMB` | over 70 % used |
| Old drivers | `drivers[]` with `old` = true | any, older than 2 years (Microsoft inbox drivers are already excluded) |
| Pending updates | `updates.count` (only when `updates.status` is `ok`) | 1 or more |
| Repeat watchdog alerts | `watchdogAlerts.days[].alerts[]` | the same process `name` alerts on 2 or more days, or 3 or more times in one report |
| Kernel-Power errors | `health.systemLog7d.events[]` with provider `Microsoft-Windows-Kernel-Power`, ID 41 | any (unexpected shutdown or power loss) |
| Disk errors | `health.systemLog7d.events[]` with provider `disk`, `Ntfs`, `Microsoft-Windows-Ntfs`, `stornvme` or `storahci`, `level` 1 (Critical) or 2 (Error); 3 is a warning | any |
| Physical disk health | `health.physicalDisks[]`: `health`, `wear`, `readErrorsTotal`, `writeErrorsTotal` | health not `Healthy`, or error counts above 0, or wear rising between reports |
| Slow boot | `health.boots[].bootTimeSec` and `mainPathBootTimeSec` | getting slower across reports (see section 3) |
| App crashes | `health.appCrashesAndHangs7d` | the same program crashing on several days |
| Battery | `system.battery.batteries[].healthPct` | watch only; under 50 % is worth telling the owner, it is not something software fixes |

Notes on reading these:

- "Idle RAM" is the first watchdog sample about 5 minutes after logon. That
  is not guaranteed to be idle; if a big program was already open (check the
  top processes and alerts at that time), say the reading is uncertain.
- Watchdog alert `reason` is `cpu` (over 80 % of the whole processor),
  `core` (90 % or more of one logical core), `ram` (over 1 GB), or several
  joined with `+`. A `core` alert on its own means one program is pegging a
  single thread, which slows the laptop less than a `cpu` alert but drains
  the battery and keeps the fan on.
- Kernel-Power 41 means Windows did not shut down cleanly. One after a
  known forced power-off is normal. Repeats with no known cause point to
  power, heat or hardware, not to software clean-up.
- Boot times come from Windows' own Diagnostics-Performance event 100. The
  first boot after an update is always slow; judge the typical boot, not
  the worst one.
- CPU % of one core can go above 100 for a program using several cores.

## 3. Compare against previous reports

Open the previous reports in `reports/` for the same HOSTNAME (sorted by the
date in the file name). Look at up to the last 4 weeks. Report only changes
that matter:

- Free disk space: is `freePct` dropping? Give the rate (for example "lost
  6 GB in 2 weeks") so the owner can see if something is filling the disk.
- Idle RAM: is the first-sample-after-logon figure higher than before? If
  yes, compare `startup` lists between the two reports and name what was
  added (run keys, startup folder, scheduled tasks).
- Boot time: compare the typical `bootTimeSec` now with the typical value in
  older reports. Call it slow only if it got clearly worse and stayed worse
  over several boots, and say by how many seconds.
- Watchdog alerts: is a process that alerted before still alerting? Is it new?
- Drivers and updates: did the count go down after the last suggestions? If
  an item stays on the list week after week, say so once, plainly.
- Installed programs (`programs` in the JSON): anything new since the last
  report that also shows up in startup or alerts.
- Event errors: a new provider appearing, or a count rising, matters more
  than a steady low number.

If there is only one report, say there is nothing to compare yet.

## 4. How to write the answer

Keep it short. The owner reads it, then fixes things on the laptop by hand.

1. One line: overall state (for example "Mostly fine, 2 things to do").
2. Any token warning, then anything urgent (disk errors, physical disk
   health not Healthy, repeated Kernel-Power 41). For disk problems the
   first step is always "back up the friend's files now".
3. A numbered list of what to remove or fix, **safest first**. Each item:
   what it is, the evidence (number and report date), and the exact step
   using built-in Windows settings. Order by risk:
   - Safest: install pending updates (Settings, Windows Update); turn off
     a startup app (Task Manager, Startup apps); empty the friend's own
     Downloads only after asking them.
   - Then: uninstall a program the friend confirms they do not use
     (Settings, Apps, Installed apps); update a driver from the laptop
     maker's support page or Windows Update optional updates.
   - Last: anything that needs a restart into recovery, a BIOS update, or
     hardware (battery, SSD replacement). Say why it is needed.
4. One line of what improved since the last report, if anything.
5. Parts that were unknown (collection errors), so the owner knows what was
   not checked.

Use the friend's process and program names exactly as in the report. Do not
invent numbers; if a figure is missing, say it is missing.

## Never suggest

These are on the project's "no" list. They are either harmful, pointless on
an SSD, or weaken security:

- Turning off Defender, Windows Update, the firewall, UAC or any security
  feature.
- "RAM cleaners", deleting Prefetch, disabling SysMain or Windows Search,
  disabling services.
- Registry tweaks such as LargeSystemCache, DisablePagingExecutive, SvcHost
  split, network throttling or TCP tweaks; pagefile changes; bcdedit; the
  Ultimate Performance power plan.
- Clearing event logs, deleting the whole SoftwareDistribution folder,
  ipconfig /release, removing built-in apps.
- Third-party "optimiser" or "driver updater" tools, or any download other
  than drivers from the laptop maker or Windows Update.
- Deleting the friend's personal files, Desktop, Documents, Downloads,
  Recycle Bin or browser data without asking them first.
