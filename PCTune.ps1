<#
    PCTune.ps1 - PowerShell helper for the PCTune laptop maintenance tool.
    Target: Windows PowerShell 5.1 only. Called by PCTune.bat as:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File PCTune.ps1 -Action <name> [options]
    Runs as SYSTEM (Task Scheduler, session 0) or as an elevated admin.
    -DryRun: nothing is changed. An action that would change the system logs
    "DRYRUN: would ..." and exits 0. The Clean actions also count the files
    and MB they would delete. Actions that only read run as normal.
    Because of that, nothing here uses %TEMP% or %USERPROFILE% to mean "the user":
    real profiles are read from the ProfileList registry key instead.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Today','DaysSince','MinutesSince','DriveInfo','FreeMB','RestorePoint',
                 'CleanTemp','CleanWU','CleanDO','CleanThumbs','CleanWER','Report',
                 'RotateLogs','AppendUnicode','PowerGet','RegisterTask','UnregisterTask',
                 'ScanFolder','LockFolder','CheckFolder')]
    [string]$Action,
    [string]$LogFile,
    [string]$Path,
    [string]$Description = 'PCTune maintenance',
    [int]$MinAgeDays = 2,
    [int]$Keep = 30,
    [switch]$EnableProtection,
    [string]$ScriptPath,
    [switch]$DryRun
)

# Any unexpected error becomes a terminating error so our try/catch can report it.
$ErrorActionPreference = 'Stop'

# Exit code chosen by the action function; the switch at the bottom exits with it.
$script:Code = 0
# Set to $true if the log file could not be written (the Report action needs to know).
$script:LogFailed = $false

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$ProfileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Write one timestamped line to the log file, or to stdout when no log file was given.
# A logging failure must never crash an action, so fall back to stdout.
function Write-Log {
    param([string]$Message)
    $line = '{0}  [PS] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv), $Message
    if ([string]::IsNullOrEmpty($LogFile)) {
        Write-Output $line
        return
    }
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding Default
    }
    catch {
        $script:LogFailed = $true
        Write-Output $line
    }
}

# Format a byte count as megabytes with one decimal, always using a dot.
function Format-MB {
    param([double]$Bytes)
    return ([math]::Round($Bytes / 1MB, 1)).ToString('0.0', $Inv)
}

# Find real user profiles (domain/local/Microsoft accounts have SIDs starting S-1-5-21-).
# System profiles (S-1-5-18/19/20) are excluded on purpose. Missing folders are skipped.
function Get-RealProfiles {
    $result = @()
    foreach ($key in (Get-ChildItem -LiteralPath $ProfileListKey)) {
        if ($key.PSChildName -notmatch '^S-1-5-21-') { continue }
        $raw = (Get-ItemProperty -LiteralPath $key.PSPath).ProfileImagePath
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $dir = [Environment]::ExpandEnvironmentVariables($raw)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $result += [pscustomobject]@{
            Sid  = $key.PSChildName
            Path = $dir
            Name = Split-Path -Leaf $dir
        }
    }
    return $result
}

# Run a native exe and return its text. PS 5.1 can throw on native stderr when
# ErrorActionPreference is Stop, so relax it just for this call.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& $Exe @Arguments 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $old
    }
}

# ---------------------------------------------------------------------------
# Safe deletion core
# ---------------------------------------------------------------------------

# Every delete goes through a file handle. The handle is opened without
# following reparse points, then checked (type, link count, real path, age)
# and the delete is done on that same handle. Checking a path and then
# deleting the path would leave a gap in which a junction could be swapped
# in, so a check-then-delete by name is not used anywhere.
$PCTuneFsSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using FILETIME = System.Runtime.InteropServices.ComTypes.FILETIME;

public static class PCTuneFs
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder buffer, uint size, uint flags);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
    private static extern bool SetInfoUInt(SafeFileHandle h, int infoClass, ref uint info, uint size);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
    private static extern bool SetInfoByte(SafeFileHandle h, int infoClass, ref byte info, uint size);

    private const uint DELETE = 0x10000;
    private const uint FILE_READ_ATTRIBUTES = 0x80;
    private const uint SHARE_ALL = 0x7;
    private const uint OPEN_EXISTING = 3;
    private const uint FLAG_OPEN_REPARSE_POINT = 0x200000;
    private const uint FLAG_BACKUP_SEMANTICS = 0x2000000;
    private const uint ATTR_DIRECTORY = 0x10;
    private const uint ATTR_REPARSE = 0x400;
    private const int FileDispositionInfo = 4;
    private const int FileDispositionInfoEx = 21;
    // FILE_DISPOSITION_FLAG_DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE
    private const uint DISPOSITION_FLAGS = 0x1 | 0x2 | 0x10;

    private static SafeFileHandle Open(string path, uint access)
    {
        string p = path.StartsWith(@"\\?\") ? path : @"\\?\" + path;
        return CreateFileW(p, access, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING,
            FLAG_OPEN_REPARSE_POINT | FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
    }

    // The path the handle really points to, without the \\?\ prefix and
    // without a trailing backslash. Null for network paths or on error.
    private static string GetFinal(SafeFileHandle h)
    {
        StringBuilder sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        if (n == 0) return null;
        if (n >= sb.Capacity)
        {
            sb = new StringBuilder((int)n + 1);
            n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (n == 0 || n >= sb.Capacity) return null;
        }
        string s = sb.ToString();
        if (s.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return null;
        if (s.StartsWith(@"\\?\")) s = s.Substring(4);
        return s.TrimEnd('\\');
    }

    // 0 deleted, 1 refused (reparse point, wrong type, hard-linked file or
    // the real path is somewhere else), 2 too new, 3 failed (locked, access
    // denied, folder not empty), 4 already gone.
    public static int TryDelete(string path, bool isDir, bool checkAge, DateTime cutoffUtc, out long size)
    {
        size = 0;
        using (SafeFileHandle h = Open(path, DELETE | FILE_READ_ATTRIBUTES))
        {
            if (h.IsInvalid)
            {
                int e = Marshal.GetLastWin32Error();
                return (e == 2 || e == 3) ? 4 : 3;
            }
            BY_HANDLE_FILE_INFORMATION fi;
            if (!GetFileInformationByHandle(h, out fi)) return 3;
            if ((fi.FileAttributes & ATTR_REPARSE) != 0) return 1;
            bool dir = (fi.FileAttributes & ATTR_DIRECTORY) != 0;
            if (dir != isDir) return 1;
            if (!isDir && fi.NumberOfLinks != 1) return 1;
            string fin = GetFinal(h);
            if (fin == null || !string.Equals(fin, path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return 1;
            if (checkAge)
            {
                long ft = ((long)(uint)fi.LastWriteTime.dwHighDateTime << 32) | (uint)fi.LastWriteTime.dwLowDateTime;
                if (DateTime.FromFileTimeUtc(ft) >= cutoffUtc) return 2;
            }
            long bytes = ((long)fi.FileSizeHigh << 32) | fi.FileSizeLow;
            uint flags = DISPOSITION_FLAGS;
            bool ok = SetInfoUInt(h, FileDispositionInfoEx, ref flags, 4);
            if (!ok)
            {
                // Older disposition class, in case the extended one is refused.
                byte del = 1;
                ok = SetInfoByte(h, FileDispositionInfo, ref del, 1);
            }
            if (!ok) return 3;
            size = bytes;
            return 0;
        }
    }

    // Real path of a folder, or null if it is a reparse point, not a folder
    // or cannot be opened.
    public static string RootFinalPath(string path)
    {
        using (SafeFileHandle h = Open(path, FILE_READ_ATTRIBUTES))
        {
            if (h.IsInvalid) return null;
            BY_HANDLE_FILE_INFORMATION fi;
            if (!GetFileInformationByHandle(h, out fi)) return null;
            if ((fi.FileAttributes & ATTR_REPARSE) != 0) return null;
            if ((fi.FileAttributes & ATTR_DIRECTORY) == 0) return null;
            return GetFinal(h);
        }
    }

    // Attributes and hard link count without following reparse points.
    // Returns 0, or the Win32 error code.
    public static int Inspect(string path, out uint attributes, out uint links)
    {
        attributes = 0;
        links = 0;
        using (SafeFileHandle h = Open(path, FILE_READ_ATTRIBUTES))
        {
            if (h.IsInvalid) return Marshal.GetLastWin32Error();
            BY_HANDLE_FILE_INFORMATION fi;
            if (!GetFileInformationByHandle(h, out fi))
            {
                int e = Marshal.GetLastWin32Error();
                return e == 0 ? -1 : e;
            }
            attributes = fi.FileAttributes;
            links = fi.NumberOfLinks;
            return 0;
        }
    }
}
'@

function Initialize-PCTuneFs {
    if (-not ('PCTuneFs' -as [type])) {
        Add-Type -TypeDefinition $PCTuneFsSource -Language CSharp
    }
}

# Recursive worker. Returns $true only when it removed the directory itself.
# $DirTime is the folder's LastWriteTime as seen from its parent listing,
# taken before any child is deleted (deleting children resets it to "now").
function Clear-OldFolder {
    param(
        [string]$Dir,
        [datetime]$DirTime,
        [datetime]$Cutoff,
        [string]$Filter,
        [hashtable]$State,
        [bool]$IsRoot
    )

    try {
        $items = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop)
    }
    catch {
        $State.Errors++
        if ($IsRoot) { $State.RootError = $true }
        return $false
    }

    $cutoffUtc = $Cutoff.ToUniversalTime()
    $remaining = 0
    foreach ($item in $items) {
        $full = [IO.Path]::Combine($Dir, $item.Name)

        # Never follow or delete junctions/symlinks: they may point outside the root.
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $State.Refused++
            $remaining++
            continue
        }

        if ($item.PSIsContainer) {
            # With a name filter only matching files in the top folder are touched.
            if ($Filter) { $remaining++; continue }
            $removed = Clear-OldFolder -Dir $full -DirTime $item.LastWriteTime -Cutoff $Cutoff -Filter $Filter -State $State -IsRoot $false
            if (-not $removed) { $remaining++ }
            continue
        }

        if ($Filter -and ($item.Name -notlike $Filter)) { $remaining++; continue }

        # Dry run: count what a real run would delete and touch nothing. The
        # same tests apply: too new is kept, a link or hard-linked file is
        # refused. The handle used here only reads attributes.
        if ($State.DryRun) {
            if ($item.LastWriteTimeUtc -ge $cutoffUtc) { $remaining++; continue }
            $attr = [uint32]0
            $links = [uint32]0
            $rc = [PCTuneFs]::Inspect($full, [ref]$attr, [ref]$links)
            if ($rc -ne 0) { $State.Skipped++; $remaining++; continue }
            if (($attr -band 0x400) -ne 0 -or $links -ne 1) { $State.Refused++; $remaining++; continue }
            $State.Files++
            $State.Bytes += [double]$item.Length
            continue
        }

        # The age is checked again on the open handle, so a file written to
        # since the listing is kept.
        $size = [long]0
        $r = [PCTuneFs]::TryDelete($full, $false, $true, $cutoffUtc, [ref]$size)
        switch ($r) {
            0 { $State.Files++; $State.Bytes += [double]$size }
            1 { $State.Refused++; $remaining++ }
            2 { $remaining++ }
            4 { }
            default { $State.Skipped++; $remaining++ }
        }
    }

    # A dry run never removes folders.
    if ($State.DryRun) { return $false }

    # Remove the folder only if it is now empty and was itself old enough. Never the root.
    if (-not $IsRoot -and $remaining -eq 0 -and $DirTime -lt $Cutoff) {
        $size = [long]0
        $r = [PCTuneFs]::TryDelete($Dir, $true, $false, $cutoffUtc, [ref]$size)
        if ($r -eq 0 -or $r -eq 4) { return $true }
        if ($r -eq 1) { $State.Refused++ } else { $State.Skipped++ }
    }
    return $false
}

# Public entry point. Status is 'ok', 'missing', 'reparse' or 'error'.
function Remove-OldItems {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MinAgeDays = 2,
        [string]$Filter
    )

    $state = @{ Files = 0; Bytes = [double]0; Skipped = 0; Refused = 0; Errors = 0; RootError = $false; DryRun = [bool]$DryRun }
    $status = 'ok'

    try {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
            Write-Log "skip: folder not found: $Root"
            $status = 'missing'
        }
        else {
            Initialize-PCTuneFs
            $want = $Root.TrimEnd('\')
            # The real path must be exactly the expected one. This catches a
            # junction on the folder itself and on any folder above it.
            $final = [PCTuneFs]::RootFinalPath($want)
            if ($null -eq $final -or -not [string]::Equals($final, $want, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "skip: root is a reparse point or resolves elsewhere ('$final'), refusing to clean: $Root"
                $status = 'reparse'
            }
            else {
                $cutoff = (Get-Date).AddDays(-$MinAgeDays)
                $rootTime = (Get-Item -LiteralPath $want -Force).LastWriteTime
                Clear-OldFolder -Dir $want -DirTime $rootTime -Cutoff $cutoff -Filter $Filter -State $state -IsRoot $true | Out-Null
                if ($state.RootError) { $status = 'error' }
            }
        }
    }
    catch {
        Write-Log "error while cleaning $Root : $($_.Exception.Message)"
        $state.Errors++
        $status = 'error'
    }

    return [pscustomobject]@{
        Root         = $Root
        Status       = $status
        FilesDeleted = $state.Files
        BytesFreed   = $state.Bytes
        Skipped      = $state.Skipped
        Refused      = $state.Refused
        Errors       = $state.Errors
        DryRun       = [bool]$DryRun
    }
}

# Log one summary line for a cleaned folder. "skipped" means locked or in
# use; "refused" means a link or redirect that was deliberately left alone.
function Write-CleanResult {
    param($Result)
    if ($Result.DryRun) {
        if ($Result.Status -eq 'ok') {
            Write-Log ('DRYRUN: would delete {0} files ({1} MB) from {2}; left alone: {3} locked or unreadable, {4} links, {5} read errors' -f `
                $Result.FilesDeleted, (Format-MB $Result.BytesFreed), $Result.Root, $Result.Skipped, $Result.Refused, $Result.Errors)
        }
        else {
            Write-Log ('DRYRUN: would not clean {0}, status={1}' -f $Result.Root, $Result.Status)
        }
        return
    }
    Write-Log ('{0}: status={1} deleted={2} freed={3} MB skipped={4} refused={5} errors={6}' -f `
        $Result.Root, $Result.Status, $Result.FilesDeleted, (Format-MB $Result.BytesFreed), $Result.Skipped, $Result.Refused, $Result.Errors)
}

# ---------------------------------------------------------------------------
# Simple query actions
# ---------------------------------------------------------------------------

function Invoke-Today {
    # Invariant culture so the date is always yyyy-MM-dd, whatever the regional calendar.
    Write-Output ((Get-Date).ToString('yyyy-MM-dd', $Inv))
    $script:Code = 0
}

function Invoke-DaysSince {
    # 9999 means "unknown/never" so the .bat treats it as "long ago".
    $days = 9999
    try {
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $first = Get-Content -LiteralPath $Path -TotalCount 1
            if ($first) {
                $then = [datetime]::ParseExact($first.Trim(), 'yyyy-MM-dd', $Inv)
                $diff = [int][math]::Floor(((Get-Date).Date - $then).TotalDays)
                if ($diff -ge 0) { $days = $diff }
            }
        }
    }
    catch {
        $days = 9999
    }
    Write-Output $days
    $script:Code = 0
}

function Invoke-MinutesSince {
    # 999999 means "item does not exist".
    $mins = 999999
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $lwt = (Get-Item -LiteralPath $Path -Force).LastWriteTime
        $mins = [int][math]::Max(0, [math]::Floor(((Get-Date) - $lwt).TotalMinutes))
    }
    Write-Output $mins
    $script:Code = 0
}

function Invoke-DriveInfo {
    # The bat decides what to do with Unknown, so this action always exits 0.
    $letter = $env:SystemDrive[0]
    $media = 'Unknown'
    try {
        $disk = Get-Partition -DriveLetter $letter | Get-Disk | Select-Object -First 1
        $phys = Get-PhysicalDisk | Where-Object { "$($_.DeviceId)" -eq "$($disk.Number)" } | Select-Object -First 1
        if ($phys) {
            switch ("$($phys.MediaType)") {
                'SSD'   { $media = 'SSD' }
                'HDD'   { $media = 'HDD' }
                default { $media = 'Unspecified' }
            }
        }
    }
    catch {
        $media = 'Unknown'
    }
    Write-Output "MEDIA=$media"

    $fs = 'Unknown'
    try {
        $vol = Get-Volume -DriveLetter $letter
        if ($vol.FileSystem) { $fs = $vol.FileSystem }
    }
    catch {
        $fs = 'Unknown'
    }
    Write-Output "FS=$fs"
    $script:Code = 0
}

function Invoke-FreeMB {
    $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    Write-Output ([int64][math]::Floor($d.FreeSpace / 1MB))
    $script:Code = 0
}

# Read one HKLM value as text. 'missing' means the key or value does not
# exist; 'error' means it could not be read, which is not the same thing and
# must not be treated as "did not exist" by anything that restores it later.
function Get-RegValueText {
    param([string]$SubKey, [string]$Name)
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey)
        if ($null -eq $k) { return 'missing' }
        try {
            $v = $k.GetValue($Name)
            if ($null -eq $v) { return 'missing' }
            return [string]$v
        }
        finally { $k.Close() }
    }
    catch { return 'error' }
}

function Invoke-PowerGet {
    # Full path, so a powercfg.exe elsewhere on PATH is never picked up.
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    # powercfg text is localized, so only match GUIDs and 0x hex numbers, never words.
    $scheme = ''
    try {
        $txt = Invoke-Native -Exe $powercfg -Arguments @('/getactivescheme')
        $m = [regex]::Match($txt, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
        if ($m.Success) { $scheme = $m.Value }
    }
    catch { $scheme = '' }

    # The last two hex values in the output are the current AC then DC settings.
    $ac = ''
    $dc = ''
    try {
        $txt = Invoke-Native -Exe $powercfg -Arguments @('/q', 'SCHEME_CURRENT', 'SUB_DISK', 'DISKIDLE')
        $hex = @([regex]::Matches($txt, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
        if ($hex.Count -ge 2) {
            $ac = [Convert]::ToInt64($hex[$hex.Count - 2].Substring(2), 16)
            $dc = [Convert]::ToInt64($hex[$hex.Count - 1].Substring(2), 16)
        }
    }
    catch { $ac = ''; $dc = '' }

    # Fast Startup and Hibernate flags: a number, 'missing' or 'error'.
    $boot = Get-RegValueText 'SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $hib = Get-RegValueText 'SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'

    Write-Output "SCHEME=$scheme"
    Write-Output "DISKIDLE_AC=$ac"
    Write-Output "DISKIDLE_DC=$dc"
    Write-Output "HIBERBOOT=$boot"
    Write-Output "HIBERNATE=$hib"
    $script:Code = 0
}

# ---------------------------------------------------------------------------
# Restore point
# ---------------------------------------------------------------------------

# Highest restore point sequence number, 0 if there are none, or $null if
# the list could not be read.
function Get-MaxRestoreSequence {
    try {
        $points = @(Get-ComputerRestorePoint)
        if ($points.Count -eq 0) { return [int64]0 }
        return [int64](($points | Measure-Object -Property SequenceNumber -Maximum).Maximum)
    }
    catch {
        Write-Log "Could not read restore points: $($_.Exception.Message)"
        return $null
    }
}

# True if a restore point newer than the ones that existed before is listed.
# The sequence number is used rather than the time, so a wrong clock or a
# point made by something else a minute earlier cannot pass as ours.
function Test-NewRestorePoint {
    param($Baseline, [datetime]$Since)
    try {
        $points = @(Get-ComputerRestorePoint)
        if ($points.Count -eq 0) { return $false }
        $newest = $points | Sort-Object -Property SequenceNumber -Descending | Select-Object -First 1
        $created = [Management.ManagementDateTimeConverter]::ToDateTime($newest.CreationTime)
        Write-Log ("Newest restore point: #{0} '{1}' created {2}" -f $newest.SequenceNumber, $newest.Description, $created.ToString('yyyy-MM-dd HH:mm:ss', $Inv))
        if ($null -ne $Baseline) { return ([int64]$newest.SequenceNumber -gt $Baseline) }
        # The list could not be read before, so fall back to the creation time.
        return ($created -ge $Since.AddMinutes(-1))
    }
    catch {
        Write-Log "Could not read restore points: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-RestorePoint {
    if ($DryRun) {
        $more = ''
        if ($EnableProtection) { $more = ' System Protection would be switched on first if it is off.' }
        Write-Log ("DRYRUN: would create the System Restore point '{0}'. It would save SystemRestorePointCreationFrequency to '{1}', set it to 0 for a moment, create the point, then put the value back.{2}" -f $Description, $Path, $more)
        $script:Code = 0
        return
    }
    $started = Get-Date
    $subKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $key = "HKLM:\$subKey"
    $name = 'SystemRestorePointCreationFrequency'

    # Current value. A read error stops here, before anything is changed,
    # so "could not read" is never mistaken for "did not exist".
    $existed = $false
    $oldValue = $null
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subKey)
    if ($null -ne $k) {
        try {
            $v = $k.GetValue($name)
            if ($null -ne $v) { $existed = $true; $oldValue = [int64]$v }
        }
        finally { $k.Close() }
    }

    # The backup file only wins when the current value is exactly 0. That is
    # the state a run cut off at the wrong moment leaves behind, and then the
    # backup holds the true original. In every other case the current value
    # is the original, and the backup is rewritten to match it so it can
    # never go stale.
    $usedBackup = $false
    if ($existed -and $oldValue -eq 0 -and $Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $line = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match '^FREQ=' }) | Select-Object -First 1
        if ($line) {
            $raw = $line.Substring(5).Trim()
            if ($raw -eq 'missing') {
                $existed = $false; $oldValue = $null; $usedBackup = $true
            }
            elseif ($raw -match '^0x[0-9a-fA-F]{1,8}$') {
                $oldValue = [Convert]::ToInt64($raw.Substring(2), 16); $usedBackup = $true
            }
            elseif ($raw -match '^\d{1,10}$') {
                $oldValue = [int64]$raw; $usedBackup = $true
            }
            else {
                Write-Log "Restore point: backup value '$raw' not understood, keeping the current value 0"
            }
        }
        if ($usedBackup) { Write-Log "Restore point: current value is 0, using the original from the backup file" }
    }
    if (-not $usedBackup -and $Path) {
        if ($existed) { $text = 'FREQ=0x{0:x}' -f $oldValue } else { $text = 'FREQ=missing' }
        # If the backup cannot be written, stop before changing the value.
        Set-Content -LiteralPath $Path -Value $text -Encoding ASCII
    }

    $baseline = Get-MaxRestoreSequence

    $changed = $false
    $script:Code = 1
    try {
        # 0 minutes disables Windows' "one restore point per 24h" limit, temporarily.
        Set-ItemProperty -LiteralPath $key -Name $name -Value 0 -Type DWord
        $changed = $true
        Write-Log "Restore point: frequency limit lifted temporarily (previously existed=$existed, value=$oldValue)"

        $created = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $err = $null
            $cpWarn = $null
            try {
                Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -WarningVariable cpWarn -WarningAction SilentlyContinue
            }
            catch {
                $err = $_.Exception.Message
            }
            # Checkpoint-Computer can "succeed" while only writing a warning, so log them.
            foreach ($w in @($cpWarn)) { if ($w) { Write-Log "Checkpoint warning: $w" } }
            if ($err) { Write-Log "Checkpoint error (attempt $attempt): $err" }

            if (Test-NewRestorePoint -Baseline $baseline -Since $started) { $created = $true; break }

            # No new point: System Protection may be off. Enable it once, only if allowed.
            if ($attempt -eq 1 -and $EnableProtection) {
                # Record that PCTune switched it on. Uninstall.bat does not
                # switch it off again (that would delete every restore point),
                # but this file shows it was PCTune that turned it on.
                if ($Path) {
                    $protFile = Join-Path (Split-Path -Parent $Path) 'protection_original.txt'
                    if (-not (Test-Path -LiteralPath $protFile)) {
                        Set-Content -LiteralPath $protFile -Encoding ASCII -Value @(
                            'PROTECTION=off',
                            "DRIVE=$env:SystemDrive\",
                            ('ENABLED_BY_PCTUNE=' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv)))
                    }
                }
                Write-Log "No new restore point; enabling System Protection on $env:SystemDrive\ and retrying"
                Enable-ComputerRestore -Drive "$env:SystemDrive\"
                $baseline = Get-MaxRestoreSequence
                continue
            }
            break
        }

        if ($created) {
            Write-Log "Restore point created and verified: '$Description'"
            $script:Code = 0
        }
        else {
            if (-not $EnableProtection) {
                Write-Log 'Restore point NOT created. System Protection may be off; re-run with -EnableProtection to allow enabling it.'
            }
            else {
                Write-Log 'Restore point NOT created even after enabling System Protection.'
            }
            $script:Code = 1
        }
    }
    finally {
        # Always put the registry value back the way it was (or remove it if it was not there).
        if ($changed) {
            try {
                if ($existed) {
                    Set-ItemProperty -LiteralPath $key -Name $name -Value $oldValue -Type DWord
                    Write-Log "Restore point: frequency value restored to $oldValue"
                }
                else {
                    Remove-ItemProperty -LiteralPath $key -Name $name
                    Write-Log 'Restore point: frequency value removed (it did not exist before)'
                }
            }
            catch {
                Write-Log "WARNING: could not restore $name : $($_.Exception.Message)"
                $script:Code = 1
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Clean actions
# ---------------------------------------------------------------------------

function Invoke-CleanTemp {
    # Windows temp plus every real user's local temp.
    $roots = @(Join-Path $env:SystemRoot 'Temp')
    foreach ($p in (Get-RealProfiles)) { $roots += (Join-Path $p.Path 'AppData\Local\Temp') }

    $failed = 0
    foreach ($r in $roots) {
        $res = Remove-OldItems -Root $r -MinAgeDays $MinAgeDays
        Write-CleanResult $res
        if ($res.Status -eq 'reparse' -or $res.Status -eq 'error') { $failed++ }
    }
    if ($failed -gt 0) { $script:Code = 1 } else { $script:Code = 0 }
}

function Invoke-CleanWU {
    $root = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'

    # Do not pull files out from under an install that is in progress.
    if ((Get-Service -Name 'TrustedInstaller').Status -eq 'Running') {
        if ($DryRun) {
            Write-Log 'DRYRUN: would skip CleanWU, because servicing is in progress'
            $script:Code = 0
            return
        }
        Write-Log 'CleanWU: servicing in progress, skipped'
        $script:Code = 2
        return
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-Log "CleanWU: folder not found, nothing to do: $root"
        $script:Code = 0
        return
    }

    # Dry run: the services are only read, never stopped.
    if ($DryRun) {
        $running = @()
        foreach ($n in 'wuauserv', 'bits') {
            if ((Get-Service -Name $n).Status -eq 'Running') { $running += $n }
        }
        $names = 'none running'
        if ($running.Count -gt 0) { $names = $running -join ', ' }
        Write-Log "DRYRUN: would stop these services ($names), empty $root, then start them again"
        $res = Remove-OldItems -Root $root -MinAgeDays 0
        Write-CleanResult $res
        # A link or a read error is reported the same way as in a real run.
        if ($res.Status -eq 'reparse' -or $res.Status -eq 'error') { $script:Code = 1 } else { $script:Code = 0 }
        return
    }

    # Remember which services were running so we only restart those afterwards.
    $wasRunning = @()
    foreach ($n in 'wuauserv', 'bits') {
        if ((Get-Service -Name $n).Status -eq 'Running') { $wasRunning += $n }
    }

    $script:Code = 0
    try {
        # Stop them so the downloaded files are not locked.
        foreach ($n in $wasRunning) {
            $svc = Get-Service -Name $n
            Stop-Service -InputObject $svc -Force
            $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 60))
        }
        # MinAgeDays 0: everything in Download, but never the Download folder itself.
        $res = Remove-OldItems -Root $root -MinAgeDays 0
        Write-CleanResult $res
        if ($res.Status -eq 'reparse' -or $res.Status -eq 'error') { $script:Code = 1 }
    }
    finally {
        # Bring back only what was running before, even if cleaning failed.
        foreach ($n in $wasRunning) {
            try {
                $svc = Get-Service -Name $n
                if ($svc.Status -ne 'Running') {
                    Start-Service -InputObject $svc
                    $svc.WaitForStatus('Running', (New-TimeSpan -Seconds 60))
                }
                Write-Log "CleanWU: service $n running again"
            }
            catch {
                Write-Log "CleanWU: FAILED to restart service $n : $($_.Exception.Message)"
                $script:Code = 1
            }
        }
    }
}

function Invoke-CleanDO {
    # The cmdlet is missing on some builds; exit 2 means "not available".
    if (-not (Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue)) {
        if ($DryRun) {
            Write-Log 'DRYRUN: would skip CleanDO, Delete-DeliveryOptimizationCache is not available on this system'
            $script:Code = 0
            return
        }
        Write-Log 'CleanDO: Delete-DeliveryOptimizationCache not available on this system, skipped'
        $script:Code = 2
        return
    }
    if ($DryRun) {
        Write-Log 'DRYRUN: would run Delete-DeliveryOptimizationCache -Force'
        $script:Code = 0
        return
    }
    Delete-DeliveryOptimizationCache -Force | Out-Null
    Write-Log 'CleanDO: Delivery Optimization cache cleared'
    $script:Code = 0
}

function Invoke-CleanThumbs {
    # Only thumbcache_*.db; Explorer keeps the logged-on user's files locked, those are skipped.
    # Locked files are normal here; a redirected folder or an error is not.
    $failed = 0
    foreach ($p in (Get-RealProfiles)) {
        $dir = Join-Path $p.Path 'AppData\Local\Microsoft\Windows\Explorer'
        $res = Remove-OldItems -Root $dir -MinAgeDays 0 -Filter 'thumbcache_*.db'
        Write-CleanResult $res
        if ($res.Status -eq 'reparse' -or $res.Status -eq 'error') { $failed++ }
    }
    if ($failed -gt 0) { $script:Code = 1 } else { $script:Code = 0 }
}

function Invoke-CleanWER {
    # Windows Error Reporting leftovers older than 7 days, machine-wide and per profile.
    $roots = @()
    foreach ($sub in 'ReportArchive', 'ReportQueue') {
        $roots += (Join-Path $env:ProgramData "Microsoft\Windows\WER\$sub")
    }
    foreach ($p in (Get-RealProfiles)) {
        foreach ($sub in 'ReportArchive', 'ReportQueue') {
            $roots += (Join-Path $p.Path "AppData\Local\Microsoft\Windows\WER\$sub")
        }
    }

    $failed = 0
    foreach ($r in $roots) {
        # Missing folders are normal here, so skip them quietly.
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $res = Remove-OldItems -Root $r -MinAgeDays 7
        Write-CleanResult $res
        if ($res.Status -eq 'reparse' -or $res.Status -eq 'error') { $failed++ }
    }
    if ($failed -gt 0) { $script:Code = 1 } else { $script:Code = 0 }
}

# ---------------------------------------------------------------------------
# Log maintenance
# ---------------------------------------------------------------------------

function Invoke-RotateLogs {
    # Keep below 1 would delete every log, so refuse.
    if ($Keep -lt 1) { throw "Keep must be 1 or more (got $Keep)." }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Log folder not found: $Path"
    }

    # Each pattern is rotated separately; nothing else in the folder is ever touched.
    $removed = 0
    foreach ($pattern in 'PCTune_*.log', 'sfc_*.txt') {
        $files = @(Get-ChildItem -LiteralPath $Path -Filter $pattern -File -Force |
                   Sort-Object -Property LastWriteTime -Descending)
        if ($files.Count -le $Keep) { continue }
        foreach ($f in ($files | Select-Object -Skip $Keep)) {
            if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($DryRun) {
                Write-Log "DRYRUN: would remove $($f.Name)"
                $removed++
                continue
            }
            Remove-Item -LiteralPath $f.FullName -Force
            Write-Log "RotateLogs: removed $($f.Name)"
            $removed++
        }
    }
    if ($DryRun) {
        Write-Log "DRYRUN: would remove $removed old log file(s) from $Path (keeping newest $Keep of each type)"
        $script:Code = 0
        return
    }
    Write-Log "RotateLogs: done, $removed file(s) removed (keeping newest $Keep of each type)"
    $script:Code = 0
}

function Invoke-AppendUnicode {
    # cmd redirection of sfc.exe produces UTF-16LE, so read it as Unicode.
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding Unicode)
    $kept = 0
    foreach ($l in $lines) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        # Drop pure progress lines (sfc may glue several together on one line).
        if ($l -match '^(\s*Verification\s+\d+%\s+complete\.?\s*)+$') { continue }
        Write-Log ('sfc: ' + $l.TrimEnd())
        $kept++
    }
    Write-Log "AppendUnicode: $kept line(s) appended from $Path"
    $script:Code = 0
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

# Run one report subsection; a failure logs "unavailable" and the report carries on.
function Invoke-Section {
    param([string]$Title, [scriptblock]$Body)
    Write-Log "--- $Title ---"
    try { & $Body }
    catch {
        $script:SectionFails++
        Write-Log "  unavailable: $($_.Exception.Message)"
    }
}

# Show a counter value, or say the drive does not report it.
function Show-Val {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return 'not reported by drive' }
    return "$Value"
}

# Log the entries of one Run/RunOnce registry key.
function Write-RunKey {
    param([string]$Key, [string]$Label)
    if (-not (Test-Path -LiteralPath $Key)) { Write-Log "  $Label : (key not present)"; return }
    $props = (Get-ItemProperty -LiteralPath $Key).PSObject.Properties |
             Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }
    if (-not $props) { Write-Log "  $Label : (empty)"; return }
    foreach ($p in $props) { Write-Log "  $Label : $($p.Name) = $($p.Value)" }
}

# Log the files in a Startup folder, ignoring desktop.ini.
function Write-StartupFolder {
    param([string]$Dir, [string]$Label)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    $files = @(Get-ChildItem -LiteralPath $Dir -Force -File | Where-Object { $_.Name -ne 'desktop.ini' })
    if ($files.Count -eq 0) { Write-Log "  $Label folder: (empty)"; return }
    foreach ($f in $files) { Write-Log "  $Label folder: $($f.Name)" }
}

function Invoke-Report {
    Write-Log '===== PCTune health report ====='
    $script:SectionFails = 0

    Invoke-Section 'Operating system' {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        Write-Log "  Caption: $($os.Caption)"
        Write-Log "  Version: $($os.Version)  Build: $($os.BuildNumber)"
        Write-Log "  Last boot: $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss', $Inv))"
    }

    Invoke-Section 'Boot time (last 5 boots, event 100)' {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5)
        }
        catch {
            # An empty log is normal, so report it differently from a real error.
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Write-Log '  no boot-time events recorded in this log'
                return
            }
            throw
        }
        foreach ($ev in $events) {
            $xml = [xml]$ev.ToXml()
            $h = @{}
            foreach ($d in $xml.Event.EventData.Data) { $h[$d.Name] = $d.'#text' }
            $parts = @()
            foreach ($f in 'BootTime', 'MainPathBootTime', 'BootPostBootTime') {
                if ($h[$f]) {
                    $sec = [double]::Parse($h[$f], $Inv) / 1000
                    $parts += ('{0}={1}s' -f $f, $sec.ToString('0.0', $Inv))
                }
                else { $parts += "$f=n/a" }
            }
            Write-Log ("  {0}  {1}" -f $ev.TimeCreated.ToString('yyyy-MM-dd HH:mm', $Inv), ($parts -join '  '))
        }
    }

    Invoke-Section 'Storage' {
        foreach ($d in (Get-PhysicalDisk)) {
            Write-Log ("  {0}: media={1} bus={2} health={3} status={4} size={5} GB" -f `
                $d.FriendlyName, $d.MediaType, $d.BusType, $d.HealthStatus, $d.OperationalStatus,
                ([math]::Round($d.Size / 1GB, 1)).ToString('0.0', $Inv))
            try {
                $rc = $d | Get-StorageReliabilityCounter
                Write-Log ("    Wear={0}  Temperature={1}  ReadErrorsTotal={2}  WriteErrorsTotal={3}  PowerOnHours={4}" -f `
                    (Show-Val $rc.Wear), (Show-Val $rc.Temperature), (Show-Val $rc.ReadErrorsTotal),
                    (Show-Val $rc.WriteErrorsTotal), (Show-Val $rc.PowerOnHours))
            }
            catch { Write-Log "    reliability counters unavailable: $($_.Exception.Message)" }
        }
    }

    Invoke-Section 'Free space (system drive)' {
        $v = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        Write-Log ("  {0} total {1} GB, free {2} GB" -f $env:SystemDrive,
            ([math]::Round($v.Size / 1GB, 1)).ToString('0.0', $Inv),
            ([math]::Round($v.FreeSpace / 1GB, 1)).ToString('0.0', $Inv))
    }

    Invoke-Section 'RAM' {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        # These two values are in KB, so dividing by 1MB (1048576) gives GB.
        Write-Log ("  Total {0} GB, free {1} GB" -f
            ([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)).ToString('0.0', $Inv),
            ([math]::Round($os.FreePhysicalMemory / 1MB, 1)).ToString('0.0', $Inv))
    }

    Invoke-Section 'Startup apps (report only, nothing is changed)' {
        Write-Log '  Note: entries disabled in Task Manager are tracked in StartupApproved and may still be listed here.'
        Write-Log '  Note: only user hives that are currently loaded (signed-in users) are shown.'

        # Machine-wide Run keys (including the 32-bit view).
        Write-RunKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'HKLM Run'
        Write-RunKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'HKLM RunOnce'
        Write-RunKey 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' 'HKLM WOW6432Node Run'

        # Per-user Run keys, only for loaded hives; _Classes hives are excluded by the regex.
        $profiles = @(Get-RealProfiles)
        $hives = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })
        foreach ($h in $hives) {
            $sid = $h.PSChildName
            $user = $sid
            $pr = $profiles | Where-Object { $_.Sid -eq $sid } | Select-Object -First 1
            if ($pr) { $user = $pr.Name }
            Write-RunKey "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "User $user Run"
            Write-RunKey "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" "User $user RunOnce"
        }

        # Startup folders: shared one, then each real profile's own.
        Write-StartupFolder (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp') 'Common Startup'
        foreach ($p in $profiles) {
            Write-StartupFolder (Join-Path $p.Path 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup') "User $($p.Name) Startup"
        }

        # Scheduled tasks that fire at logon or boot. Microsoft's own are only counted.
        $startTypes = @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')
        $msCount = 0
        $shown = 0
        foreach ($t in (Get-ScheduledTask)) {
            if ("$($t.State)" -eq 'Disabled') { continue }
            $isStart = $false
            foreach ($tr in @($t.Triggers)) {
                if ($tr -and ($tr.CimClass.CimClassName -in $startTypes)) { $isStart = $true }
            }
            if (-not $isStart) { continue }
            if ($t.TaskPath -like '\Microsoft\*') { $msCount++; continue }
            $exe = ''
            $first = @($t.Actions) | Select-Object -First 1
            if ($first) { $exe = $first.Execute }
            Write-Log "  Task: $($t.TaskPath)$($t.TaskName)  ->  $exe"
            $shown++
        }
        if ($shown -eq 0) { Write-Log '  Task: no non-Microsoft logon/boot tasks found' }
        Write-Log "  Microsoft logon/boot tasks under \Microsoft\ (count only): $msCount"
    }

    Invoke-Section 'Top 10 processes by memory' {
        foreach ($p in (Get-Process | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 10)) {
            Write-Log ("  {0} (PID {1}): {2} MB" -f $p.ProcessName, $p.Id, ([math]::Round($p.WorkingSet64 / 1MB, 0)).ToString('0', $Inv))
        }
    }

    Invoke-Section 'System log: warnings/errors, last 7 days (power, disk, NTFS, storage)' {
        $filter = @{
            LogName      = 'System'
            Level        = 1, 2, 3
            ProviderName = @('Microsoft-Windows-Kernel-Power', 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci')
            StartTime    = (Get-Date).AddDays(-7)
        }
        try {
            $all = @(Get-WinEvent -FilterHashtable $filter)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Write-Log '  none found'
                return
            }
            throw
        }
        if ($all.Count -eq 0) { Write-Log '  none found'; return }
        $top = @($all | Sort-Object -Property TimeCreated -Descending | Select-Object -First 50)
        Write-Log "  total events: $($all.Count) (showing newest $($top.Count))"
        foreach ($e in $top) {
            $msg = ''
            if ($e.Message) {
                $msg = ($e.Message -split "\r?\n")[0]
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
            }
            Write-Log ("  {0}  {1}  id={2}  {3}  {4}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss', $Inv), $e.ProviderName, $e.Id, $e.LevelDisplayName, $msg)
        }
    }

    # A section that could not be read is reported, not treated as a failed
    # run: some drives and builds simply do not offer every counter.
    if ($script:SectionFails -gt 0) {
        Write-Log "  $($script:SectionFails) report section(s) were unavailable, see 'unavailable' lines above"
    }
    Write-Log '===== end of report ====='
    if ($script:LogFailed) { $script:Code = 1 } else { $script:Code = 0 }
}

# ---------------------------------------------------------------------------
# Scheduled task registration
# ---------------------------------------------------------------------------

$TaskName = 'PCTune Daily Maintenance'
$TaskPathFolder = '\PCTune\'

function Invoke-RegisterTask {
    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "ScriptPath not found: $ScriptPath"
    }
    $workDir = Split-Path -Parent $ScriptPath

    # cmd /c needs the whole command wrapped in an extra pair of quotes so a path with spaces works.
    $arguments = '/d /c ""{0}" /scheduled"' -f $ScriptPath
    if ($DryRun) {
        Write-Log ("DRYRUN: would register the task {0}{1} to run as SYSTEM at logon with a 3 minute delay: cmd.exe {2}" -f $TaskPathFolder, $TaskName, $arguments)
        $script:Code = 0
        return
    }
    $act = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument $arguments -WorkingDirectory $workDir

    # Run at logon, but wait 3 minutes so we do not compete with the user's startup.
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT3M'

    # SYSTEM (S-1-5-18) runs in session 0, so no window or flash is ever shown to the user.
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest

    # Priority is left at the default 7 (below normal) on purpose, so the task stays out of the way.
    # 4 hours: a weekly run with DISM /RestoreHealth and sfc on a slow
    # laptop can pass 2 hours, and a killed run leaves services stopped.
    # PCTune.bat treats its lock as stale after 300 minutes, which is longer.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -StartWhenAvailable

    # -Force replaces an existing task of the same name.
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPathFolder -Action $act -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'PCTune daily maintenance (runs hidden as SYSTEM)' -Force | Out-Null

    # Read it back to prove it exists.
    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPathFolder
    Write-Log "RegisterTask: $($t.TaskPath)$($t.TaskName) registered, state=$($t.State), runs as $($t.Principal.UserId)"
    $script:Code = 0
}

# The PCTune task, or $null if it does not exist. Any other error (for
# example the Task Scheduler service not answering) is thrown, so it is
# never mistaken for "not installed".
function Get-PCTuneTask {
    try {
        return Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPathFolder -ErrorAction Stop
    }
    catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $null }
        throw
    }
}

# Exit 0 removed, 2 was not installed, 1 failed.
function Invoke-UnregisterTask {
    $t = Get-PCTuneTask
    if ($DryRun) {
        if (-not $t) {
            Write-Log 'DRYRUN: the task is not installed, there would be nothing to remove'
        }
        else {
            Write-Log "DRYRUN: would unregister the task $($t.TaskPath)$($t.TaskName) (state $($t.State)), stopping it first if it is running, then remove the empty task folder"
        }
        $script:Code = 0
        return
    }
    if (-not $t) {
        Write-Log 'UnregisterTask: task not found, nothing to remove'
        $script:Code = 2
    }
    else {
        # Uninstall.bat refuses to start while a run holds a fresh lock, so a
        # running instance here is one that hung past that point.
        if ("$($t.State)" -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPathFolder
            Write-Log 'UnregisterTask: a running instance was stopped'
        }
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPathFolder -Confirm:$false
        if (Get-PCTuneTask) { throw 'Task is still present after unregister.' }
        Write-Log 'UnregisterTask: task removed and verified gone'
        $script:Code = 0
    }

    # Try to remove the now-empty \PCTune\ folder; failure here is harmless.
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $svc.GetFolder('\').DeleteFolder('PCTune', 0)
        Write-Log 'UnregisterTask: removed empty task folder \PCTune\'
    }
    catch {
        Write-Log "UnregisterTask: task folder not removed (ignored): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Folder protection
# The task runs PCTune.bat as SYSTEM, so anyone who can change a file in the
# folder could make Windows run their command as SYSTEM. These actions check
# and set the folder's permissions. They use SIDs, which do not change with
# the Windows language.
# ---------------------------------------------------------------------------
$SidSystem         = 'S-1-5-18'
$SidAdmins         = 'S-1-5-32-544'
$SidTrustedInstall = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'

# Problems that would let the folder's contents point somewhere else:
# junctions or symbolic links anywhere inside, and hard-linked files (a hard
# link shares its permissions with the other name, which may live in a
# folder a normal user controls). Returns a list of text lines.
function Get-TreeProblems {
    param([string]$Base)
    Initialize-PCTuneFs
    $problems = New-Object System.Collections.Generic.List[string]
    $want = $Base.TrimEnd('\')
    $final = [PCTuneFs]::RootFinalPath($want)
    if ($null -eq $final -or -not [string]::Equals($final, $want, [StringComparison]::OrdinalIgnoreCase)) {
        $problems.Add("folder is a reparse point or resolves elsewhere ('$final'): $want")
        return ,$problems
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($want)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        }
        catch {
            $problems.Add("cannot list folder: $dir ($($_.Exception.Message))")
            continue
        }
        foreach ($item in $items) {
            $full = [IO.Path]::Combine($dir, $item.Name)
            $attr = [uint32]0
            $links = [uint32]0
            $rc = [PCTuneFs]::Inspect($full, [ref]$attr, [ref]$links)
            if ($rc -ne 0) {
                $problems.Add("cannot inspect (error $rc): $full")
                continue
            }
            if ($attr -band 0x400) {
                $problems.Add("junction or symbolic link: $full")
                continue
            }
            if ($attr -band 0x10) {
                $stack.Push($full)
            }
            elseif ($links -ne 1) {
                $problems.Add("file has $links hard links: $full")
            }
        }
    }
    return ,$problems
}

# Exit 0 nothing found, 1 problems found. Run before the permissions change,
# so a link planted before install cannot redirect icacls /T.
function Invoke-ScanFolder {
    if (-not $Path) { throw 'ScanFolder needs -Path.' }
    $problems = Get-TreeProblems -Base $Path
    if ($problems.Count -eq 0) {
        Write-Log "ScanFolder: no links or reparse points under $Path"
        $script:Code = 0
        return
    }
    foreach ($p in ($problems | Select-Object -First 50)) { Write-Log "ScanFolder: $p" }
    Write-Log "ScanFolder: $($problems.Count) problem(s) found. Remove them before installing."
    $script:Code = 1
}

# Sets the folder's own permissions, with inheritance from the drive root
# switched off:
#   SYSTEM          full control
#   Administrators  full control
#   Users           read and run (0x1200a9), so the logs can be read
# Only the access list is written. The owner is set by icacls beforehand.
function Invoke-LockFolder {
    if (-not $Path) { throw 'LockFolder needs -Path.' }
    $base = $Path.TrimEnd('\')
    # Setting permissions on a link would change its target instead.
    $item = Get-Item -LiteralPath $base -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$base is a link or junction. Permissions were not changed."
    }
    if ($DryRun) {
        Write-Log "DRYRUN: would replace the permissions on $base : SYSTEM and Administrators full control, Users read and run, inheritance off"
        $script:Code = 0
        return
    }
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $sec.SetSecurityDescriptorSddlForm(
        'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)',
        [System.Security.AccessControl.AccessControlSections]::Access)
    $item.SetAccessControl($sec)
    Write-Log "LockFolder: permissions set on $base"
    $script:Code = 0
}

# Exit 0 the folder is safe, 1 it is not (or could not be checked).
# Checks every item, the folder itself included:
#   - no links or reparse points (Get-TreeProblems)
#   - the owner is SYSTEM, Administrators or TrustedInstaller
#   - no allow rule gives any other account a right that changes data,
#     permissions or the owner
function Invoke-CheckFolder {
    if (-not $Path) { throw 'CheckFolder needs -Path.' }
    $base = $Path.TrimEnd('\')
    $problems = Get-TreeProblems -Base $base
    if ($problems.Count -eq 0) {
        $okSids = @($SidSystem, $SidAdmins, $SidTrustedInstall)
        # WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles,
        # WriteAttributes, Delete, ChangePermissions, TakeOwnership, GenericWrite, GenericAll.
        $writeMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
        $paths = New-Object System.Collections.Generic.List[string]
        $paths.Add($base)
        foreach ($i in @(Get-ChildItem -LiteralPath $base -Force -Recurse -ErrorAction Stop)) { $paths.Add($i.FullName) }
        foreach ($p in $paths) {
            try {
                $acl = Get-Acl -LiteralPath $p -ErrorAction Stop
                $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
                if ($okSids -notcontains $owner) { $problems.Add("owner is $owner : $p") }
                foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
                    if ($r.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                    $sid = $r.IdentityReference.Value
                    if ($okSids -contains $sid) { continue }
                    if (([int64][int32]$r.FileSystemRights -band 0xFFFFFFFFL) -band $writeMask) {
                        $problems.Add(("{0} can change it (rights 0x{1:x}): {2}" -f $sid, [int32]$r.FileSystemRights, $p))
                    }
                }
            }
            catch {
                $problems.Add("cannot read permissions: $p ($($_.Exception.Message))")
            }
        }
    }
    if ($problems.Count -eq 0) {
        Write-Log "CheckFolder: $base is protected (owner and permissions OK, no links)"
        $script:Code = 0
        return
    }
    foreach ($p in ($problems | Select-Object -First 50)) { Write-Log "CheckFolder: $p" }
    Write-Log "CheckFolder: $($problems.Count) problem(s). Run Install.bat again as administrator."
    $script:Code = 1
}

# ---------------------------------------------------------------------------
# Dispatcher: one try/catch around every action
# ---------------------------------------------------------------------------
try {
    switch ($Action) {
        'Today'          { Invoke-Today;         exit $script:Code }
        'DaysSince'      { Invoke-DaysSince;     exit $script:Code }
        'MinutesSince'   { Invoke-MinutesSince;  exit $script:Code }
        'DriveInfo'      { Invoke-DriveInfo;     exit $script:Code }
        'FreeMB'         { Invoke-FreeMB;        exit $script:Code }
        'RestorePoint'   { Invoke-RestorePoint;  exit $script:Code }
        'CleanTemp'      { Invoke-CleanTemp;     exit $script:Code }
        'CleanWU'        { Invoke-CleanWU;       exit $script:Code }
        'CleanDO'        { Invoke-CleanDO;       exit $script:Code }
        'CleanThumbs'    { Invoke-CleanThumbs;   exit $script:Code }
        'CleanWER'       { Invoke-CleanWER;      exit $script:Code }
        'Report'         { Invoke-Report;        exit $script:Code }
        'RotateLogs'     { Invoke-RotateLogs;    exit $script:Code }
        'AppendUnicode'  { Invoke-AppendUnicode; exit $script:Code }
        'PowerGet'       { Invoke-PowerGet;      exit $script:Code }
        'RegisterTask'   { Invoke-RegisterTask;  exit $script:Code }
        'UnregisterTask' { Invoke-UnregisterTask; exit $script:Code }
        'ScanFolder'     { Invoke-ScanFolder;    exit $script:Code }
        'LockFolder'     { Invoke-LockFolder;    exit $script:Code }
        'CheckFolder'    { Invoke-CheckFolder;   exit $script:Code }
    }
}
catch {
    # Log the failure; also print it so the calling .bat can see it even without a log file.
    $msg = "ERROR in action ${Action}: $($_.Exception.Message)"
    Write-Log $msg
    if (-not [string]::IsNullOrEmpty($LogFile)) { Write-Output $msg }
    exit 1
}
