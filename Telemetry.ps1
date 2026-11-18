<#
    Telemetry.ps1 - consented telemetry for the PCTune laptop maintenance tool.
    Target: Windows PowerShell 5.1 only. Called by the .bat files as:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Telemetry.ps1 -Action <name> [-Base <dir>] [-LogFile <file>] [-DryRun] [-Samples <n>]
    Standalone on purpose: PCTune.ps1 cannot be dot-sourced (it runs its own dispatcher),
    so the few helpers needed are copied here.

    Actions: Protect, CheckPrivate, Setup, Forget, EnsureWatchdog, RemoveWatchdog,
    Watchdog, Collect, Upload.

    Parameters:
      -Base      The PCTune folder. Default C:\PCTune.
      -LogFile   Append log lines to this file instead of writing them to the console.
      -DryRun    Show what the action would change and change nothing (see below).
      -Samples   Only used by Watchdog together with -DryRun: how many samples to take
                 (1 to 1440, default 3). Without -DryRun it is ignored and the watchdog
                 runs until it is stopped.

    Exit codes everywhere: 0 OK, 2 skipped / not set up / nothing to do / deferred, 1 failure.
    Setup only: 3 = Setup failed AND token.dat could not be removed again (a secret may be on disk).
    A dry run uses the same codes as the real action.

    Dry run: every step that would change something logs a line that starts with
    "DRYRUN: would ..." and is skipped. Read-only steps run for real. Nothing is written
    to Telemetry\, token.dat, repo.txt, last_reported_day.txt or the outbox, and nothing
    is deleted or pruned. The output of a dry run goes to <Base>\DryRun\, which is
    created with default (inherited) permissions: samples\, reports\ and token_status.txt.
      Protect, Forget, EnsureWatchdog, RemoveWatchdog: only log what they would do.
      Setup      asks for the repo and token, runs the read-only privacy check against
                 GitHub, stores nothing and uploads no test file.
      Watchdog   takes -Samples samples into DryRun\samples, flushes its alerts and exits 0.
      Collect    covers today only, reads DryRun\samples, writes DryRun\reports\<date>_<PC>.json
                 and .md ("dryRun": true in the JSON); no marker, outbox or prune.
      Upload     never sends; lists the outbox and DryRun\reports files that would go.

    Token expiry: every GitHub reply is checked for the header
    github-authentication-token-expiration. Setup and Upload then write
    Telemetry\token_status.txt (DryRun\token_status.txt in a dry run), one ASCII line and
    no secret:
      OK <yyyy-MM-dd>            more than 14 days left
      WARN <yyyy-MM-dd> <days>   14 days or fewer left
      EXPIRED <yyyy-MM-dd>       the expiry date has passed
      NONE                       GitHub sent no expiry header (the token does not expire)
    Upload stops with exit 1 before any network call once the file says EXPIRED, and logs
    a warning from 14 days before. Collect puts the same warning at the top of the report
    and adds tokenExpiry to the JSON. Forget deletes the file together with the token.

    What is collected is limited to: system numbers, process name/PID/CPU/RAM/exe path,
    installed program names, driver info, update titles, event headlines and startup
    program paths. It never collects passwords, browser data, file contents, documents,
    screenshots, keystrokes, Wi-Fi keys or process command lines.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Protect','CheckPrivate','Setup','Forget','EnsureWatchdog','RemoveWatchdog',
                 'Watchdog','Collect','Upload')]
    [string]$Action,
    [string]$Base = 'C:\PCTune',
    [string]$LogFile,
    [switch]$DryRun,
    [ValidateRange(1, 1440)]
    [int]$Samples = 3
)

# Any unexpected error becomes a terminating error so the dispatcher can report it.
$ErrorActionPreference = 'Stop'

$script:Code = 0
# The plain token, only while a function holds it. Write-Log scrubs it from every line.
$script:Secret = ''

# Token expiry seen in the GitHub replies of this run (see Update-TokenExpiryFromReply).
# TokenExpiryDate is the latest valid expiry as a UTC datetime. GhOkReplies counts 2xx
# replies whose headers were read, so "no header" is only believed after a good reply.
$script:TokenExpiryDate = $null
$script:ExpiryHeaderBad = $false
$script:ExpiryBadLogged = $false
$script:GhOkReplies = 0
$script:ExpiryWarned = $false
# Expiry state read from token_status.txt before the network was used (Upload).
$script:KnownExpiry = $null

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$ProfileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

$Base        = $Base.TrimEnd('\')
$TelDir      = Join-Path $Base 'Telemetry'
$RealSamplesDir = Join-Path $TelDir 'samples'
$OutboxDir   = Join-Path $TelDir 'outbox'
$TokenFile   = Join-Path $Base 'token.dat'
$RepoFile    = Join-Path $TelDir 'repo.txt'
$ComputerName = $env:COMPUTERNAME

# Dry run output lives in DryRun\ and nowhere else. $SamplesDir is the folder the
# watchdog writes to and Collect reads from, so pointing it at DryRun\samples keeps
# those functions free of dry run checks. Protect uses $RealSamplesDir.
$DryDir        = Join-Path $Base 'DryRun'
$DryReportsDir = Join-Path $DryDir 'reports'
if ($DryRun) { $SamplesDir = Join-Path $DryDir 'samples' } else { $SamplesDir = $RealSamplesDir }
# Scratch folder for the battery report: Telemetry\ normally, DryRun\ in a dry run.
if ($DryRun) { $WorkDir = $DryDir } else { $WorkDir = $TelDir }

# token_status.txt holds no secret. It is written inside Telemetry\ like
# last_reported_day.txt, so it inherits that folder's locked permissions. A dry run
# writes DryRun\token_status.txt, and reads that one first, then the real one.
$TokenStatusRealFile = Join-Path $TelDir 'token_status.txt'
if ($DryRun) {
    $TokenStatusOut = Join-Path $DryDir 'token_status.txt'
    $TokenStatusReadFiles = @($TokenStatusOut, $TokenStatusRealFile)
}
else {
    $TokenStatusOut = $TokenStatusRealFile
    $TokenStatusReadFiles = @($TokenStatusRealFile)
}
$TokenExpiryHeader = 'github-authentication-token-expiration'

$PCTuneVersion = '1.0.0'
$KeepDays      = 14
# Days before the expiry date from which the token counts as "about to expire".
$TokenWarnDays = 14

$SidSystem         = 'S-1-5-18'
$SidAdmins         = 'S-1-5-32-544'
$SidTrustedInstall = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$OkSids            = @($SidSystem, $SidAdmins, $SidTrustedInstall)

# Not a secret. DPAPI "entropy" only separates this use from other DPAPI blobs.
# Random entropy kept in the registry would not help: restore points and disk
# backups copy the registry along with the file. The file ACL plus revoking the
# token on GitHub is the protection.
$EntropyText = 'PCTune-telemetry-v1'

$DirSddl  = 'D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
$FileSddl = 'D:PAI(A;;FA;;;SY)(A;;FA;;;BA)'

$RepoPattern = '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
# Fine-grained personal access tokens only. Classic tokens (ghp_) cannot be limited
# to one repository, so a leaked one would expose every repo of the account.
# The pattern is also letters, digits and underscore only, so a pasted newline can
# never end up in a header.
$TokenPattern = '^github_pat_[A-Za-z0-9_]{22,255}$'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Write one timestamped line to the log file, or to stdout when no log file was given.
# A logging failure must never crash an action, so fall back to stdout.
# The token is scrubbed here as a last line of defence; callers also never log it.
function Write-Log {
    param([string]$Message)
    if (-not [string]::IsNullOrEmpty($script:Secret)) {
        $Message = $Message.Replace($script:Secret, '[redacted]')
    }
    $line = '{0}  [TEL] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv), $Message
    # Console, not Write-Output: output inside a function becomes part of its
    # return value, and a log line must never end up in a report section or in an
    # exit-code variable.
    if ([string]::IsNullOrEmpty($LogFile)) {
        [Console]::Out.WriteLine($line)
        return
    }
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding Default
    }
    catch {
        [Console]::Out.WriteLine($line)
    }
}

# Number to text with a fixed number of decimals, always using a dot.
function Format-Num {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    if ($Digits -gt 0) { $fmt = '0.' + ('0' * $Digits) } else { $fmt = '0' }
    return ([math]::Round([double]$Value, $Digits)).ToString($fmt, $Inv)
}

function Get-Stamp {
    param([datetime]$When)
    return $When.ToString('yyyy-MM-ddTHH:mm:sszzz', $Inv)
}

function Get-DateText {
    param([datetime]$When)
    return $When.ToString('yyyy-MM-dd', $Inv)
}

# Run a native exe and return its text. PS 5.1 can throw on native stderr when
# ErrorActionPreference is Stop, so relax it just for this call.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $Exe @Arguments 2>&1 | Out-String)
        # Exit code kept for callers that need it (read $script:NativeExit at once).
        $script:NativeExit = $LASTEXITCODE
        return $out
    }
    finally {
        $ErrorActionPreference = $old
    }
}

# Real user profiles (SIDs starting S-1-5-21-). System profiles are excluded.
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

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Append text as UTF-8 without BOM. Retries because Collect may be reading the
# same file at that moment.
function Add-TextRetry {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    for ($i = 1; $i -le 3; $i++) {
        try {
            [IO.File]::AppendAllText($Path, $Text, $enc)
            return
        }
        catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

# Delete old files in a folder. Age comes from the yyyy-MM-dd at the start of the
# file name when -ByNameDate is used (outbox), otherwise from LastWriteTime.
# Links are never touched. Returns how many files were removed.
function Remove-OldFiles {
    param([string]$Dir, [int]$Days, [switch]$ByNameDate)
    $removed = 0
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    $cutoff = (Get-Date).Date.AddDays(-$Days)
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force)) {
        if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $age = $f.LastWriteTime
        if ($ByNameDate) {
            $m = [regex]::Match($f.Name, '^(\d{4}-\d{2}-\d{2})')
            if (-not $m.Success) { continue }
            try { $age = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $Inv) }
            catch { continue }
        }
        if ($age -ge $cutoff) { continue }
        try {
            Remove-Item -LiteralPath $f.FullName -Force
            $removed++
        }
        catch {
            Write-Log "prune: could not delete $($f.Name): $($_.Exception.Message)"
        }
    }
    return $removed
}

# ---------------------------------------------------------------------------
# Link-safe file inspection (copied in trimmed form from PCTune.ps1's PCTuneFs)
# The handle is opened without following reparse points, so a junction or
# symlink is seen as such instead of being followed.
# ---------------------------------------------------------------------------
$TelFsSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using FILETIME = System.Runtime.InteropServices.ComTypes.FILETIME;

public static class PCTuneTelFs
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

    private const uint FILE_READ_ATTRIBUTES = 0x80;
    private const uint SHARE_ALL = 0x7;
    private const uint OPEN_EXISTING = 3;
    private const uint FLAG_OPEN_REPARSE_POINT = 0x200000;
    private const uint FLAG_BACKUP_SEMANTICS = 0x2000000;

    private static SafeFileHandle Open(string path)
    {
        string p = path.StartsWith(@"\\?\") ? path : @"\\?\" + path;
        return CreateFileW(p, FILE_READ_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING,
            FLAG_OPEN_REPARSE_POINT | FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
    }

    // Attributes and hard link count without following reparse points.
    // Returns 0, or the Win32 error code (2 or 3 means "not found").
    public static int Inspect(string path, out uint attributes, out uint links)
    {
        attributes = 0;
        links = 0;
        using (SafeFileHandle h = Open(path))
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

    // The path the handle really points to (no \\?\ prefix, no trailing backslash).
    // Null on error or for network paths. A junction anywhere above the item
    // makes this differ from the path that was asked for.
    public static string FinalPath(string path)
    {
        using (SafeFileHandle h = Open(path))
        {
            if (h.IsInvalid) return null;
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
    }
}
'@

function Initialize-TelFs {
    if (-not ('PCTuneTelFs' -as [type])) {
        Add-Type -TypeDefinition $TelFsSource -Language CSharp
    }
}

# True if the item exists, even when it is a dangling link (Test-Path would follow it).
# Win32 2 (file not found) and 3 (path not found) mean "not there". Any other code,
# such as access denied, says nothing about existence, so it is thrown instead of
# being treated as "missing" (which could skip a security check).
function Test-ItemExists {
    param([string]$Path)
    Initialize-TelFs
    $attr = [uint32]0
    $links = [uint32]0
    $rc = [int][PCTuneTelFs]::Inspect($Path, [ref]$attr, [ref]$links)
    if ($rc -eq 0) { return $true }
    if ($rc -eq 2 -or $rc -eq 3) { return $false }
    throw "Cannot check whether $Path exists (Win32 error $rc)"
}

# Every item below $Root (not $Root itself) with its attributes. Links are
# listed but never entered.
function Get-TreeEntries {
    param([string]$Root)
    Initialize-TelFs
    $result = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        }
        catch {
            $result.Add([pscustomobject]@{ Path = $dir; IsDir = $true; Reparse = $false; Links = 0; Error = "cannot list folder: $($_.Exception.Message)" })
            continue
        }
        foreach ($item in $items) {
            $full = [IO.Path]::Combine($dir, $item.Name)
            $attr = [uint32]0
            $links = [uint32]0
            $rc = [PCTuneTelFs]::Inspect($full, [ref]$attr, [ref]$links)
            if ($rc -ne 0) {
                $result.Add([pscustomobject]@{ Path = $full; IsDir = $false; Reparse = $false; Links = 0; Error = "cannot inspect (error $rc)" })
                continue
            }
            $isDir = (($attr -band 0x10) -ne 0)
            $reparse = (($attr -band 0x400) -ne 0)
            $result.Add([pscustomobject]@{ Path = $full; IsDir = $isDir; Reparse = $reparse; Links = [int]$links; Error = $null })
            if ($isDir -and -not $reparse) { $stack.Push($full) }
        }
    }
    return ,$result.ToArray()
}

# ---------------------------------------------------------------------------
# ACL helpers
# ---------------------------------------------------------------------------

function Get-OwnerSid {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    return $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
}

# Owner must already be Administrators (Install sets it). This only repairs it.
function Set-OwnerIfNeeded {
    param([string]$Path, [bool]$IsDir)
    $owner = Get-OwnerSid $Path
    if (($OkSids -contains $owner)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($IsDir) { $s = New-Object System.Security.AccessControl.DirectorySecurity }
    else { $s = New-Object System.Security.AccessControl.FileSecurity }
    $s.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($SidAdmins)))
    $item.SetAccessControl($s)
    Write-Log "Protect: owner changed from $owner to Administrators: $Path"
}

# A child that was created before the parent was locked may carry its own
# explicit ACEs or have inheritance switched off. Make it inherit only.
function Reset-ChildAcl {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $acl = $item.GetAccessControl()
    $acl.SetAccessRuleProtection($false, $false)
    foreach ($r in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
        [void]$acl.RemoveAccessRuleSpecific($r)
    }
    $item.SetAccessControl($acl)
}

# ---------------------------------------------------------------------------
# Protect
# ---------------------------------------------------------------------------

# Install.bat runs this after "icacls C:\PCTune\* /reset /T". The parent grants
# Users read access, and that reset would also undo any earlier lock on
# Telemetry\ and token.dat, so the lock is applied again here.
function Invoke-Protect {
    # Test-ItemExists throws on codes other than "not found"; that must end as a
    # logged failure (exit 1), never as a silent "missing".
    try { if ($DryRun) { Invoke-ProtectDry } else { Invoke-ProtectCore } }
    catch {
        Write-Log "Protect: failed: $($_.Exception.Message)"
        $script:Code = 1
    }
}

function Invoke-ProtectCore {
    Initialize-TelFs
    if (-not (Test-Path -LiteralPath $Base -PathType Container)) { throw "Base folder not found: $Base" }

    # New folders are created with the locked ACL already attached, so there is
    # no moment where Users can read them.
    $dirSec = New-Object System.Security.AccessControl.DirectorySecurity
    $dirSec.SetSecurityDescriptorSddlForm($DirSddl, [System.Security.AccessControl.AccessControlSections]::Access)
    foreach ($d in @($TelDir, $SamplesDir, $OutboxDir)) {
        if (-not (Test-ItemExists $d)) {
            [void][IO.Directory]::CreateDirectory($d, $dirSec)
            Write-Log "Protect: created $d"
        }
    }

    # A link in place of Telemetry\ would send the ACL change somewhere else.
    $final = [PCTuneTelFs]::FinalPath($TelDir)
    if ($null -eq $final -or -not [string]::Equals($final, [IO.Path]::GetFullPath($TelDir).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Telemetry folder is a link or resolves elsewhere ('$final'), refusing to change permissions."
    }

    $failed = 0
    Set-OwnerIfNeeded $TelDir $true
    (Get-Item -LiteralPath $TelDir -Force).SetAccessControl($dirSec)
    Write-Log "Protect: permissions set on $TelDir"

    # Setting the parent ACL propagates to unprotected children; this also fixes
    # the protected ones and the owners.
    foreach ($e in (Get-TreeEntries $TelDir)) {
        if ($e.Error) { Write-Log "Protect: $($e.Error): $($e.Path)"; $failed++; continue }
        if ($e.Reparse) { Write-Log "Protect: link left alone, remove it: $($e.Path)"; $failed++; continue }
        if (-not $e.IsDir -and $e.Links -ne 1) { Write-Log "Protect: file has $($e.Links) hard links, left alone: $($e.Path)"; $failed++; continue }
        try {
            Set-OwnerIfNeeded $e.Path $e.IsDir
            Reset-ChildAcl $e.Path
        }
        catch {
            Write-Log "Protect: failed on $($e.Path): $($_.Exception.Message)"
            $failed++
        }
    }

    if (Test-ItemExists $TokenFile) {
        $attr = [uint32]0
        $links = [uint32]0
        [void][PCTuneTelFs]::Inspect($TokenFile, [ref]$attr, [ref]$links)
        if (($attr -band 0x400) -ne 0 -or $links -ne 1) {
            Write-Log "Protect: token.dat is a link or has hard links, not touched: $TokenFile"
            $failed++
        }
        else {
            try {
                Set-OwnerIfNeeded $TokenFile $false
                $fileSec = New-Object System.Security.AccessControl.FileSecurity
                $fileSec.SetSecurityDescriptorSddlForm($FileSddl, [System.Security.AccessControl.AccessControlSections]::Access)
                (Get-Item -LiteralPath $TokenFile -Force).SetAccessControl($fileSec)
                Write-Log "Protect: permissions set on $TokenFile"
            }
            catch {
                Write-Log "Protect: failed on token.dat: $($_.Exception.Message)"
                $failed++
            }
        }
    }

    if ($failed -gt 0) {
        Write-Log "Protect: $failed problem(s)"
        $script:Code = 1
    }
    else { $script:Code = 0 }
}

# Dry run of Protect: reports what would be created and locked. The only thing it
# runs is the read-only permission check of Telemetry\.
function Invoke-ProtectDry {
    Initialize-TelFs
    if (-not (Test-Path -LiteralPath $Base -PathType Container)) { throw "Base folder not found: $Base" }
    foreach ($d in @($TelDir, $RealSamplesDir, $OutboxDir)) {
        if (-not (Test-ItemExists $d)) { Write-Log "DRYRUN: would create $d with the locked permissions" }
    }
    if (Test-ItemExists $TelDir) {
        $problems = New-Object System.Collections.Generic.List[string]
        Test-AclSafe $TelDir $problems
        if ($problems.Count -eq 0) { Write-Log "DRYRUN: $TelDir already has safe permissions (read-only check)" }
        else {
            foreach ($p in ($problems | Select-Object -First 10)) { Write-Log "DRYRUN: current state of ${TelDir}: $p" }
        }
    }
    Write-Log "DRYRUN: would set the locked permissions on $TelDir and reset owner and inheritance of everything below it"
    if (Test-ItemExists $TokenFile) { Write-Log "DRYRUN: would set the locked permissions on $TokenFile" }
    else { Write-Log 'DRYRUN: token.dat does not exist, so there is nothing to lock there' }
    $script:Code = 0
}

# ---------------------------------------------------------------------------
# CheckPrivate
# ---------------------------------------------------------------------------

# Owner and "any allow ACE for another SID" checks for one item.
# -Child is for items below Telemetry\. Protect resets those to inherit only, so
# their DACL is not protected; that is safe because the parent is checked as
# protected and every inherited rule is still checked below.
function Test-AclSafe {
    param([string]$Path, $Problems, [switch]$Child)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($OkSids -notcontains $owner) { $Problems.Add("owner is $owner : $Path") }
        # A NULL DACL gives everyone full access, and an unprotected DACL still
        # inherits entries from the parent, so both fail even with no extra ACE.
        $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $sd.DiscretionaryAcl) { $Problems.Add("NULL DACL (everyone has access): $Path") }
        elseif (-not $Child -and -not $acl.AreAccessRulesProtected) { $Problems.Add("permissions are not protected from inheritance: $Path") }
        foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($r.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = $r.IdentityReference.Value
            if ($OkSids -contains $sid) { continue }
            $Problems.Add(("{0} has access (rights 0x{1:x}): {2}" -f $sid, [int32]$r.FileSystemRights, $Path))
        }
    }
    catch {
        $Problems.Add("cannot read permissions: $Path ($($_.Exception.Message))")
    }
}

# Exit 2 not set up, 1 not private, 0 private.
function Invoke-CheckPrivate {
    # See Invoke-Protect: an existence check that cannot answer is a failure.
    try { Invoke-CheckPrivateCore }
    catch {
        Write-Log "CheckPrivate: failed: $($_.Exception.Message)"
        $script:Code = 1
    }
}

function Invoke-CheckPrivateCore {
    Initialize-TelFs
    if (-not (Test-ItemExists $TokenFile) -or -not (Test-ItemExists $RepoFile)) {
        Write-Log 'CheckPrivate: telemetry is not set up (token.dat or repo.txt missing)'
        $script:Code = 2
        return
    }

    $problems = New-Object System.Collections.Generic.List[string]

    # token.dat
    $attr = [uint32]0
    $links = [uint32]0
    [void][PCTuneTelFs]::Inspect($TokenFile, [ref]$attr, [ref]$links)
    if (($attr -band 0x400) -ne 0) { $problems.Add("token.dat is a link: $TokenFile") }
    else {
        if ($links -ne 1) { $problems.Add("token.dat has $links hard links: $TokenFile") }
        Test-AclSafe $TokenFile $problems
    }

    # Telemetry\ itself: the real path must be the expected one, which also catches
    # a junction on any folder above it.
    $want = [IO.Path]::GetFullPath($TelDir).TrimEnd('\')
    $final = [PCTuneTelFs]::FinalPath($TelDir)
    if ($null -eq $final -or -not [string]::Equals($final, $want, [StringComparison]::OrdinalIgnoreCase)) {
        $problems.Add("Telemetry folder is a link or resolves elsewhere ('$final')")
    }
    else {
        Test-AclSafe $TelDir $problems
        foreach ($e in (Get-TreeEntries $TelDir)) {
            if ($e.Error) { $problems.Add("$($e.Error): $($e.Path)"); continue }
            if ($e.Reparse) { $problems.Add("junction or symbolic link: $($e.Path)"); continue }
            if (-not $e.IsDir -and $e.Links -ne 1) { $problems.Add("file has $($e.Links) hard links: $($e.Path)") }
            Test-AclSafe $e.Path $problems -Child
        }
    }

    if ($problems.Count -eq 0) {
        Write-Log 'CheckPrivate: token and Telemetry folder are private (owner, permissions and links OK)'
        $script:Code = 0
        return
    }
    foreach ($p in ($problems | Select-Object -First 50)) { Write-Log "CheckPrivate: $p" }
    Write-Log "CheckPrivate: $($problems.Count) problem(s). Run Install.bat again as administrator."
    $script:Code = 1
}

# ---------------------------------------------------------------------------
# Dry run folders
# ---------------------------------------------------------------------------

# Creates DryRun\, DryRun\samples and DryRun\reports with default (inherited)
# permissions. That is the dry run's own output and the only place it writes to.
function New-DryRunDirs {
    if (-not (Test-Path -LiteralPath $Base -PathType Container)) { throw "Base folder not found: $Base" }
    foreach ($d in @($DryDir, $SamplesDir, $DryReportsDir)) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { [void][IO.Directory]::CreateDirectory($d) }
    }
}

# ---------------------------------------------------------------------------
# Token expiry
# ---------------------------------------------------------------------------

# GitHub sends the expiry of a token that has one in the response header
# github-authentication-token-expiration. The documented format is
# "2026-12-31 00:00:00 UTC"; a numeric offset such as "+0000" is accepted too.
# Returns the moment as a UTC datetime, or $null when the text has neither form.
function ConvertFrom-TokenExpiryHeader {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text.Trim(), '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*(UTC|GMT|Z|[+-]\d{2}:?\d{2})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    $local = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$local)) { return $null }
    $offset = [TimeSpan]::Zero
    $zm = [regex]::Match($m.Groups[2].Value, '^([+-])(\d{2}):?(\d{2})$')
    if ($zm.Success) {
        $hh = [int]$zm.Groups[2].Value
        $mm = [int]$zm.Groups[3].Value
        if ($hh -gt 14 -or $mm -gt 59) { return $null }
        $offset = New-Object TimeSpan($hh, $mm, 0)
        if ($zm.Groups[1].Value -eq '-') { $offset = $offset.Negate() }
    }
    # A date at the very start of the calendar minus an offset would overflow.
    try { return [datetime]::SpecifyKind($local.Subtract($offset), [DateTimeKind]::Utc) }
    catch { return $null }
}

# Days left and status for an expiry date, counted in whole calendar days against
# Today. EXPIRED: the date is before today. WARN: WarnDays or fewer left, which
# includes the expiry day itself (0 days). OK: more than that.
function Get-TokenExpiryState {
    param([datetime]$ExpiryDate, [datetime]$Today, [int]$WarnDays = 14)
    $days = [int][math]::Round(($ExpiryDate.Date - $Today.Date).TotalDays)
    if ($days -lt 0) { $status = 'EXPIRED' }
    elseif ($days -le $WarnDays) { $status = 'WARN' }
    else { $status = 'OK' }
    return [pscustomobject]@{ Date = $ExpiryDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); DaysLeft = $days; Status = $status }
}

# The one line of token_status.txt. $null or Status NONE gives "NONE".
function Format-TokenStatusLine {
    param($State)
    if ($null -eq $State -or $State.Status -eq 'NONE') { return 'NONE' }
    if ($State.Status -eq 'WARN') { return "WARN $($State.Date) $($State.DaysLeft)" }
    return "$($State.Status) $($State.Date)"
}

# Reads a token_status.txt line back. Only the date is trusted: status and day count
# are worked out again against Today, because the file can be days old. Returns $null
# when the text is not a valid status line.
function ConvertFrom-TokenStatusLine {
    param([string]$Text, [datetime]$Today, [int]$WarnDays = 14)
    $line = ''
    foreach ($l in ($Text -split '\r?\n')) {
        if ($l.Trim() -ne '') { $line = $l.Trim(); break }
    }
    if ($line -eq 'NONE') { return [pscustomobject]@{ Date = $null; DaysLeft = $null; Status = 'NONE' } }
    $m = [regex]::Match($line, '^(OK|WARN|EXPIRED) (\d{4}-\d{2}-\d{2})( \d+)?$')
    if (-not $m.Success) { return $null }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($m.Groups[2].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $null }
    return (Get-TokenExpiryState -ExpiryDate $d -Today $Today -WarnDays $WarnDays)
}

function Get-TokenExpiredText {
    param([string]$Date)
    return "the GitHub token expired on $Date. Run Setup-Telemetry.bat to enter a new token."
}

function Get-TokenWarnText {
    param([string]$Date, [int]$Days)
    return "the GitHub token expires on $Date ($Days days). Run Setup-Telemetry.bat to enter a new token before then."
}

# Called for every GitHub reply, good or bad (the header is read from error replies
# too). A missing header means the token has no expiry, but that is only believed
# after a 2xx reply with readable headers. An unreadable header is logged once and
# never fails the action.
function Update-TokenExpiryFromReply {
    param($Result)
    if ($Result.Status -ge 200 -and $Result.Status -lt 300 -and [string]::IsNullOrEmpty($Result.HeaderError)) { $script:GhOkReplies++ }
    if (-not $Result.Headers.ContainsKey($TokenExpiryHeader)) { return }
    $raw = [string]$Result.Headers[$TokenExpiryHeader]
    $exp = ConvertFrom-TokenExpiryHeader -Text $raw
    if ($null -ne $exp) {
        $script:TokenExpiryDate = $exp
        return
    }
    $script:ExpiryHeaderBad = $true
    if (-not $script:ExpiryBadLogged) {
        $script:ExpiryBadLogged = $true
        $clean = ($raw -replace '[^\x20-\x7e]', '?')
        if ($clean.Length -gt 40) { $clean = $clean.Substring(0, 40) }
        Write-Log "WARNING: GitHub sent a token expiry header in a form that could not be read ('$clean'). The expiry is unknown, continuing."
    }
}

# State from token_status.txt, recomputed against today, or $null when there is no
# usable file. A dry run looks at DryRun\token_status.txt first, then the real file.
function Read-TokenStatusState {
    # The stored date is a UTC date, so today is counted in UTC as well.
    $today = [datetime]::UtcNow
    foreach ($p in $TokenStatusReadFiles) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try { $text = [IO.File]::ReadAllText($p) }
        catch {
            Write-Log "Token status: could not read ${p}: $($_.Exception.Message). The token expiry is unknown."
            return $null
        }
        $st = ConvertFrom-TokenStatusLine -Text $text -Today $today -WarnDays $TokenWarnDays
        if ($null -eq $st) {
            Write-Log "Token status: $p has an unexpected format, ignoring it."
            return $null
        }
        if ($DryRun) { Write-Log "DRYRUN: read the token status from $p" }
        # PCTune.bat shows the line as it is in the file, so a line written days ago
        # could still say OK after the warning window has started. Write the status
        # recomputed for today back. A dry run writes only its own copy in DryRun\.
        $fresh = Format-TokenStatusLine $st
        $old = $text -split '\r?\n' | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1
        if ($null -ne $old) { $old = $old.Trim() }
        if ($p -ne $TokenStatusOut -or $old -ne $fresh) {
            if ((Write-TokenStatusFile $fresh) -and $DryRun) { Write-Log "DRYRUN: wrote $TokenStatusOut ($fresh)" }
        }
        return $st
    }
    return $null
}

# Writes the status line (ASCII, CRLF) under a temp name and renames it, so a reader
# never sees half a line. Telemetry\ is never created here. Returns $true or $false;
# a failure is logged and never fails the action.
function Write-TokenStatusFile {
    param([string]$Line)
    $tmp = $TokenStatusOut + '.tmp'
    try {
        if ($DryRun) { New-DryRunDirs }
        if (-not (Test-Path -LiteralPath (Split-Path -Parent $TokenStatusOut) -PathType Container)) { throw 'the folder does not exist' }
        [IO.File]::WriteAllText($tmp, $Line + "`r`n", [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $tmp -Destination $TokenStatusOut -Force
        return $true
    }
    catch {
        Write-Log "Token status: could not write ${TokenStatusOut}: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# After Setup and Upload: turns what the GitHub replies of this run said into the
# status file. With no usable reply the file is left as it is.
function Save-TokenStatusFromRun {
    param([string]$Who)
    if ($null -ne $script:TokenExpiryDate) {
        $line = Format-TokenStatusLine (Get-TokenExpiryState -ExpiryDate $script:TokenExpiryDate -Today ([datetime]::UtcNow) -WarnDays $TokenWarnDays)
    }
    elseif ($script:ExpiryHeaderBad) {
        Write-Log "${Who}: the token expiry is unknown, so token_status.txt was left as it was."
        return
    }
    elseif ($script:GhOkReplies -gt 0) { $line = 'NONE' }
    else { return }
    if (Write-TokenStatusFile $line) {
        if ($DryRun) { Write-Log "DRYRUN: wrote $TokenStatusOut ($line)" }
        else { Write-Log "${Who}: token status is now: $line" }
    }
}

# Logs the "expires soon" warning once per run, whichever source finds it first.
function Write-ExpiryWarningOnce {
    param([string]$Date, [int]$Days)
    if ($script:ExpiryWarned) { return }
    $script:ExpiryWarned = $true
    Write-Log ('WARNING: ' + (Get-TokenWarnText $Date $Days))
}

# True (and logs the failure) when GitHub answered 401 and the expiry date, from this
# run's header or from token_status.txt, has been reached. On the expiry day itself
# GitHub may already refuse the token, so 0 days left counts here.
function Test-ExpiredAt401 {
    param($Res)
    if ($Res.Status -ne 401) { return $false }
    $st = $null
    if ($null -ne $script:TokenExpiryDate) { $st = Get-TokenExpiryState -ExpiryDate $script:TokenExpiryDate -Today ([datetime]::UtcNow) -WarnDays $TokenWarnDays }
    elseif ($null -ne $script:KnownExpiry) { $st = $script:KnownExpiry }
    if ($null -eq $st -or $st.Status -eq 'NONE') { return $false }
    if ($st.DaysLeft -gt 0) { return $false }
    Write-Log ('FAIL: ' + (Get-TokenExpiredText $st.Date))
    return $true
}

# ---------------------------------------------------------------------------
# GitHub REST helper
# ---------------------------------------------------------------------------

# Returns Status (0 = no HTTP answer at all: DNS, connect, timeout), Body, Json
# (only parsed for bodies up to 1 MB, because ConvertFrom-Json in PS 5.1 stops at
# about 2 MB), Message (GitHub's own "message" field), NetError (exception
# status name, no text from the request; 'BadJson' when a 2xx body could not be
# parsed) and Headers (response headers, keys lower-case, e.g. x-oauth-scopes,
# x-ratelimit-remaining). The token expiry header is read from every reply, error
# replies included (Update-TokenExpiryFromReply).
# The token is only used to build the Authorization header. Exceptions are
# caught here and reduced to a status code or a status name, so the token cannot
# end up in a log line or a rethrown message.
# Redirects are not followed, so the token is never sent to another host.
function Invoke-GitHub {
    param([string]$Method, [string]$Uri, [string]$Token, [string]$Body)
    $result = [pscustomobject]@{ Status = 0; Body = ''; Json = $null; Message = ''; NetError = ''; Headers = @{}; HeaderError = '' }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
        $req.Method = $Method
        $req.UserAgent = 'PCTune-telemetry'
        $req.Accept = 'application/vnd.github+json'
        $req.Headers.Add('Authorization', "Bearer $Token")
        $req.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 60000
        $req.AllowAutoRedirect = $false
        if (-not [string]::IsNullOrEmpty($Body)) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentType = 'application/json'
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream()
            try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Dispose() }
        }
        $resp = $req.GetResponse()
    }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            $result.NetError = [string]$_.Exception.Status
            return $result
        }
    }
    catch {
        $result.NetError = $_.Exception.GetType().Name
        return $result
    }

    try {
        $result.Status = [int]$resp.StatusCode
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $result.Body = $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    catch {
        $result.NetError = 'ReadFailed'
    }
    finally {
        # Headers are copied before the response is disposed. Names are lower-cased
        # so callers can look them up without caring about case.
        try {
            foreach ($k in $resp.Headers.AllKeys) { $result.Headers[$k.ToLowerInvariant()] = [string]$resp.Headers[$k] }
        }
        catch { $result.HeaderError = $_.Exception.GetType().Name }
        $resp.Dispose()
    }

    Update-TokenExpiryFromReply -Result $result

    if ($result.Body.Length -gt 0 -and $result.Body.Length -le 1000000) {
        try {
            $result.Json = $result.Body | ConvertFrom-Json
            if ($result.Json.message -is [string]) {
                $m = ($result.Json.message -replace '[\r\n]+', ' ')
                if ($m.Length -gt 200) { $m = $m.Substring(0, 200) }
                $result.Message = $m
            }
        }
        catch {
            # Only the exception type is kept, never its text. A good HTTP answer
            # with an unreadable body is reported as BadJson, not as a bad repo.
            $result.Json = $null
            if ($result.Status -ge 200 -and $result.Status -lt 300 -and [string]::IsNullOrEmpty($result.NetError)) { $result.NetError = 'BadJson' }
        }
    }
    return $result
}

# One log-safe description of a failed call: status code and GitHub's message only.
function Get-HttpText {
    param($Res)
    if ($Res.Status -eq 0) { return "no response ($($Res.NetError))" }
    if ($Res.NetError -eq 'BadJson') { return "HTTP $($Res.Status): GitHub reply could not be read" }
    if ($Res.Message) { return "HTTP $($Res.Status): $($Res.Message)" }
    return "HTTP $($Res.Status)"
}

# True when GitHub says the caller is throttled: HTTP 429, or 403 with no calls
# left in the window. This is not a bad token, so callers defer instead of failing.
function Test-RateLimited {
    param($Res)
    if ($Res.Status -eq 429) { return $true }
    if ($Res.Status -eq 403 -and $Res.Headers.ContainsKey('x-ratelimit-remaining') -and $Res.Headers['x-ratelimit-remaining'].Trim() -eq '0') { return $true }
    return $false
}

# Classic tokens answer with an X-OAuth-Scopes header; fine-grained ones do not.
function Test-ClassicTokenReply {
    param($Res)
    return $Res.Headers.ContainsKey('x-oauth-scopes')
}

# 'private' only when GitHub says visibility is exactly private. Internal repos
# also report private=true but are visible to a whole enterprise, so they fail.
# 'unreadable' when the reply is missing, not JSON, or lacks the fields; that is
# a different problem from a repo that is not private.
function Get-RepoPrivacy {
    param($Res)
    if ($Res.NetError -eq 'BadJson' -or $null -eq $Res.Json) { return 'unreadable' }
    $vis = $Res.Json.visibility
    $priv = $Res.Json.private
    if ($null -eq $vis -or $null -eq $priv -or $vis -isnot [string]) { return 'unreadable' }
    if ($vis -eq 'private' -and $priv -eq $true) { return 'private' }
    return 'notprivate'
}

function Initialize-Tls {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# Token storage
# ---------------------------------------------------------------------------

function Initialize-Dpapi {
    Add-Type -AssemblyName System.Security
}

function Clear-Bytes {
    param([byte[]]$Bytes)
    if ($null -ne $Bytes) { [Array]::Clear($Bytes, 0, $Bytes.Length) }
}

# Decrypt token.dat. The returned string cannot be wiped (strings are immutable
# in .NET); the byte arrays are cleared on a best-effort basis.
function Get-StoredToken {
    Initialize-Dpapi
    $b64 = ([IO.File]::ReadAllText($TokenFile)).Trim()
    $enc = [Convert]::FromBase64String($b64)
    $ent = [Text.Encoding]::UTF8.GetBytes($EntropyText)
    $bytes = $null
    try {
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $ent, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $t = ([Text.Encoding]::UTF8.GetString($bytes)).Trim()
    }
    finally {
        Clear-Bytes $bytes
    }
    if ($t -notmatch $TokenPattern) { throw 'the stored token is not usable, run Setup again' }
    $script:Secret = $t
    return $t
}

# Create the token file with its locked ACL already attached (no window in which
# Users could read it), replacing any older file.
function Write-SecretFile {
    param([string]$Path, [string]$Text)
    $sec = New-Object System.Security.AccessControl.FileSecurity
    $sec.SetSecurityDescriptorSddlForm($FileSddl, [System.Security.AccessControl.AccessControlSections]::Access)
    if (Test-ItemExists $Path) { Remove-Item -LiteralPath $Path -Force }
    $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $sec)
    try {
        $b = [Text.Encoding]::ASCII.GetBytes($Text)
        $fs.Write($b, 0, $b.Length)
    }
    finally { $fs.Dispose() }
}

function Read-PlainFromSecure {
    param([System.Security.SecureString]$Secure)
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

# ---------------------------------------------------------------------------
# Setup (interactive, admin)
# ---------------------------------------------------------------------------

# Why DataProtectionScope LocalMachine and not ConvertFrom-SecureString:
# setup runs as the admin user but the scheduled upload runs as SYSTEM.
# ConvertFrom-SecureString (and CurrentUser DPAPI) bind the secret to the user
# who made it, so SYSTEM could not decrypt it.
# Limit, stated plainly: machine-scope DPAPI can be decrypted by any process on
# this PC that can read token.dat. The file ACL is the real protection, and any
# administrator on this PC can read the token.
# Delete token.dat and repo.txt after a failed Setup, with errors visible, then
# check again. Sets $script:Code (not a return value, because Write-Log may print
# to the pipeline): 1 when nothing remains (Setup failed but is clean), 3 when
# token.dat could not be removed (a secret may still be on disk, the caller must act). An existence check that cannot answer counts as "still there".
function Remove-SetupFiles {
    $tokenLeft = $false
    foreach ($f in @($TokenFile, $RepoFile)) {
        try {
            if (Test-ItemExists $f) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
        }
        catch {
            Write-Log "Setup: could not delete ${f}: $($_.Exception.Message)"
        }
        $still = $true
        try { $still = Test-ItemExists $f } catch { $still = $true }
        if ($still) {
            Write-Log "Setup: STILL PRESENT after cleanup: $f"
            if ($f -eq $TokenFile) { $tokenLeft = $true }
        }
    }
    if ($tokenLeft) {
        Write-Log 'Setup: token.dat could not be removed. Delete it by hand and revoke the token on GitHub.'
        $script:Code = 3
        return
    }
    $script:Code = 1
}

function Invoke-Setup {
    if (-not (Test-IsAdmin)) {
        if (-not $DryRun) {
            Write-Log 'Setup: run this as administrator'
            $script:Code = 1
            return
        }
        Write-Log 'DRYRUN: not running as administrator. The real Setup would stop here; the read-only checks continue.'
    }

    $repo = ([string](Read-Host 'Private GitHub repo as owner/repo')).Trim()
    if ($repo -notmatch $RepoPattern) {
        Write-Log 'Setup: the repo must look like owner/repo (letters, digits, - . _). Nothing stored.'
        $script:Code = 1
        return
    }
    $secure = Read-Host 'GitHub token (input is hidden)' -AsSecureString
    if ($null -eq $secure -or $secure.Length -eq 0) {
        if ($null -ne $secure) { $secure.Dispose() }
        Write-Log 'Setup: no token entered. Nothing stored.'
        $script:Code = 1
        return
    }

    $plain = $null
    $bytes = $null
    $ent = $null
    $enc = $null
    try {
        $plain = (Read-PlainFromSecure $secure).Trim()
        $secure.Dispose()
        if ($plain -notmatch $TokenPattern) {
            Write-Log 'Setup: only fine-grained tokens (they start with github_pat_) are accepted. Classic tokens (ghp_) are refused, because they cannot be limited to one repository. Create a fine-grained token with Contents: read and write on that one repo. Nothing stored.'
            $script:Code = 1
            return
        }
        $script:Secret = $plain
        Initialize-Tls
        $api = "https://api.github.com/repos/$repo"

        # 1) The repo must be reachable and private.
        $r = Invoke-GitHub -Method 'GET' -Uri $api -Token $plain
        if (Test-ClassicTokenReply $r) {
            Write-Log 'Setup: GitHub treats this as a classic token (X-OAuth-Scopes header). Refused. Use a fine-grained token. Nothing stored.'
            $script:Code = 1
            return
        }
        if (Test-RateLimited $r) {
            Write-Log 'Setup: GitHub rate limit reached. Try again later. Nothing stored.'
            $script:Code = 1
            return
        }
        if ($r.Status -ne 200) {
            Write-Log "Setup: could not read the repo ($(Get-HttpText $r)). Check the name and the token. Nothing stored."
            $script:Code = 1
            return
        }
        $priv = Get-RepoPrivacy $r
        if ($priv -eq 'unreadable') {
            Write-Log 'Setup: GitHub reply could not be read, so privacy is unknown. Nothing stored.'
            $script:Code = 1
            return
        }
        if ($priv -ne 'private') {
            Write-Log 'Setup: that repo is NOT private (visibility must be exactly private; internal is refused too). Refusing, reports must never go to a public repo. Nothing stored.'
            $script:Code = 1
            return
        }

        if ($DryRun) {
            Write-Log "DRYRUN: repo $repo is private (read-only check passed)"
            Write-Log "DRYRUN: would upload the test file reports/.setup_$ComputerName.txt to $repo to prove Contents write access (not tested in a dry run)"
            Write-Log 'DRYRUN: would lock the Telemetry folder (Protect)'
            Write-Log 'DRYRUN: would store the token in token.dat'
            Write-Log 'DRYRUN: would write repo.txt'
            Write-Log 'DRYRUN: would run Protect and CheckPrivate again to verify the stored files'
            # token_status.txt describes the stored token. The token typed here is
            # not stored, so its expiry is only logged.
            if ($null -ne $script:TokenExpiryDate) {
                $ts = Get-TokenExpiryState -ExpiryDate $script:TokenExpiryDate -Today ([datetime]::UtcNow) -WarnDays $TokenWarnDays
                Write-Log "DRYRUN: the token entered expires on $($ts.Date) ($($ts.DaysLeft) days). token_status.txt is not written, because this token is not stored."
            }
            Write-Log 'Setup: dry run finished, nothing was stored.'
            $script:Code = 0
            return
        }

        # 2) Prove Contents write works with a small test file.
        $testName = ".setup_$ComputerName.txt"
        $testUri = "$api/contents/reports/" + [uri]::EscapeDataString($testName)
        $sha = $null
        $g = Invoke-GitHub -Method 'GET' -Uri $testUri -Token $plain
        if (Test-ClassicTokenReply $g) {
            Write-Log 'Setup: GitHub treats this as a classic token (X-OAuth-Scopes header). Refused. Nothing stored.'
            $script:Code = 1
            return
        }
        if ($g.Status -eq 200) {
            $sm = [regex]::Match($g.Body, '"sha"\s*:\s*"([0-9a-f]{40})"')
            if ($sm.Success) { $sha = $sm.Groups[1].Value }
        }
        elseif ($g.Status -ne 404) {
            Write-Log "Setup: test file lookup failed ($(Get-HttpText $g)). Nothing stored."
            $script:Code = 1
            return
        }
        $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('PCTune telemetry setup test ' + (Get-Stamp (Get-Date))))
        $body = '{"message":"PCTune setup test","content":"' + $content + '"'
        if ($sha) { $body += ',"sha":"' + $sha + '"' }
        $body += '}'
        $p = Invoke-GitHub -Method 'PUT' -Uri $testUri -Token $plain -Body $body
        if (Test-ClassicTokenReply $p) {
            Write-Log 'Setup: GitHub treats this as a classic token (X-OAuth-Scopes header). Refused. Nothing stored.'
            $script:Code = 1
            return
        }
        if ($p.Status -ne 200 -and $p.Status -ne 201) {
            Write-Log "Setup: test write failed ($(Get-HttpText $p)). The token needs Contents: read and write on that repo. Nothing stored."
            $script:Code = 1
            return
        }
        Write-Log "Setup: repo $repo is private and the test write worked"

        # 3) Both checks passed: store. The folder is locked first, so repo.txt
        # is never created in an open folder.
        Invoke-Protect
        if ($script:Code -ne 0) {
            Write-Log 'Setup: could not lock the Telemetry folder. Nothing stored.'
            $script:Code = 1
            return
        }

        # From here on token.dat or repo.txt may exist on disk. Any failure must
        # remove them again, and the removal itself is verified.
        try {
            Initialize-Dpapi
            $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
            # Fixed entropy, not a secret (see $EntropyText).
            $ent = [Text.Encoding]::UTF8.GetBytes($EntropyText)
            $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $ent, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
            Write-SecretFile -Path $TokenFile -Text ([Convert]::ToBase64String($enc))
            Write-SecretFile -Path $RepoFile -Text $repo

            # Apply the full lock again (owner, children) and verify it.
            Invoke-Protect
            if ($script:Code -ne 0) { throw 'Protect failed after storing the token' }
            Invoke-CheckPrivate
            if ($script:Code -ne 0) { throw 'the stored files are not private' }
        }
        catch {
            Write-Log "Setup: failed after storing ($($_.Exception.Message)). Removing the stored files."
            Remove-SetupFiles
            return
        }
        Save-TokenStatusFromRun 'Setup'
        Write-Log "Setup: done. Telemetry will upload to $repo."
        $script:Code = 0
    }
    finally {
        # Best effort: the arrays are cleared, but the string copy of the token
        # lives until the garbage collector reuses its memory.
        Clear-Bytes $bytes
        Clear-Bytes $ent
        Clear-Bytes $enc
        if ($null -ne $secure) { $secure.Dispose() }
        $plain = $null
        $script:Secret = ''
    }
}

# ---------------------------------------------------------------------------
# Forget
# ---------------------------------------------------------------------------

function Invoke-Forget {
    if ($DryRun) {
        $dryHad = 0
        foreach ($f in @($TokenFile, $RepoFile)) {
            if (-not (Test-ItemExists $f)) { continue }
            $dryHad++
            Write-Log "DRYRUN: would delete $f"
        }
        if (Test-ItemExists $TokenStatusRealFile) { Write-Log "DRYRUN: would delete $TokenStatusRealFile" }
        if ($dryHad -eq 0) {
            Write-Log 'Forget: nothing to delete'
            $script:Code = 2
            return
        }
        $script:Code = 0
        return
    }
    $had = 0
    foreach ($f in @($TokenFile, $RepoFile)) {
        if (-not (Test-ItemExists $f)) { continue }
        $had++
        Remove-Item -LiteralPath $f -Force
        if (Test-ItemExists $f) { throw "Could not delete $f" }
        Write-Log "Forget: deleted $f"
    }
    # The expiry date belongs to the token that was just removed, so it goes too.
    # It does not count as "something was deleted" for the exit code.
    if (Test-ItemExists $TokenStatusRealFile) {
        Remove-Item -LiteralPath $TokenStatusRealFile -Force
        if (Test-ItemExists $TokenStatusRealFile) { throw "Could not delete $TokenStatusRealFile" }
        Write-Log "Forget: deleted $TokenStatusRealFile"
    }
    if ($had -eq 0) {
        Write-Log 'Forget: nothing to delete'
        $script:Code = 2
        return
    }
    Write-Log 'Forget: the token is gone from this PC. System Restore points or backups made while the token was stored may still hold an encrypted copy, so revoke the token on GitHub (Settings, Developer settings, Personal access tokens).'
    $script:Code = 0
}

# ---------------------------------------------------------------------------
# Watchdog task
# ---------------------------------------------------------------------------

$WatchTaskName = 'PCTune Watchdog'
$WatchTaskPath = '\PCTune\'

# The task, or $null if it does not exist. Other errors are thrown, so they are
# never mistaken for "not installed".
function Get-WatchTask {
    try {
        return Get-ScheduledTask -TaskName $WatchTaskName -TaskPath $WatchTaskPath -ErrorAction Stop
    }
    catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $null }
        throw
    }
}

function Invoke-EnsureWatchdog {
    $script = Join-Path $Base 'Telemetry.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Script not found: $script" }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # The watchdog writes its own log next to the samples, so Collect can report
    # its errors and nobody has to pass a log path by hand.
    $wlog = Join-Path $SamplesDir 'watchdog.log'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Watchdog -Base "{1}" -LogFile "{2}"' -f $script, $Base, $wlog
    $act = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $Base

    # The watchdog now runs without a time limit. Two triggers: at logon (5 minute
    # delay so it does not compete with the logon rush) and daily at 12:00, so it
    # also comes back after sleep, a crash or a stop when nobody logs on again.
    # A second start while it is running is ignored (MultipleInstances IgnoreNew).
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $logon.Delay = 'PT5M'
    $daily = New-ScheduledTaskTrigger -Daily -At '12:00'
    $triggers = @($logon, $daily)

    $principal = New-ScheduledTaskPrincipal -UserId $SidSystem -LogonType ServiceAccount -RunLevel Highest
    # New-TimeSpan with no arguments is zero, which Task Scheduler reads as "no limit".
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan) -Priority 7 `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    # Idempotent: leave a matching task alone, replace one that differs. A running
    # old instance keeps its old command line, so it is stopped before replacing
    # (open alerts are closed by the next start, see Close-StaleAlerts).
    $t = Get-WatchTask
    $same = $false
    if ($t) {
        $a = @($t.Actions) | Select-Object -First 1
        $tr = @($t.Triggers)
        $hasLogon = @($tr | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.Delay -eq 'PT5M' }).Count -eq 1
        $hasDaily = @($tr | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' -and "$($_.StartBoundary)" -match 'T12:00:00' -and [int]$_.DaysInterval -eq 1 }).Count -eq 1
        $s = $t.Settings
        $same = ($a -and $a.Execute -eq $exe -and $a.Arguments -eq $arguments -and $a.WorkingDirectory -eq $Base -and
                 $tr.Count -eq 2 -and $hasLogon -and $hasDaily -and
                 "$($s.ExecutionTimeLimit)" -eq 'PT0S' -and "$($s.MultipleInstances)" -eq 'IgnoreNew' -and
                 [int]$s.RestartCount -eq 3 -and "$($s.RestartInterval)" -eq 'PT1M' -and [int]$s.Priority -eq 7)
    }
    if ($DryRun) {
        if ($same) { Write-Log 'DRYRUN: the task definition is already up to date, would leave it alone' }
        else {
            if ($t -and "$($t.State)" -eq 'Running') { Write-Log "DRYRUN: would stop the running old instance of $WatchTaskPath$WatchTaskName before replacing the definition" }
            if ($t) { Write-Log "DRYRUN: would replace the scheduled task $WatchTaskPath$WatchTaskName (logon with 5 minute delay plus daily 12:00, runs as SYSTEM, no time limit)" }
            else { Write-Log "DRYRUN: would register the scheduled task $WatchTaskPath$WatchTaskName (logon with 5 minute delay plus daily 12:00, runs as SYSTEM, no time limit)" }
        }
        if (-not $same -or "$($t.State)" -ne 'Running') { Write-Log "DRYRUN: would start the task $WatchTaskPath$WatchTaskName now" }
        $script:Code = 0
        return
    }
    if ($same) {
        Write-Log 'EnsureWatchdog: task definition already up to date'
    }
    else {
        if ($t -and "$($t.State)" -eq 'Running') {
            Stop-ScheduledTask -TaskName $WatchTaskName -TaskPath $WatchTaskPath
            Write-Log 'EnsureWatchdog: old running instance stopped before replacing the definition'
        }
        Register-ScheduledTask -TaskName $WatchTaskName -TaskPath $WatchTaskPath -Action $act -Trigger $triggers `
            -Principal $principal -Settings $settings -Description 'PCTune watchdog (samples CPU and RAM once a minute, runs hidden as SYSTEM, no time limit)' -Force | Out-Null
    }

    $t = Get-WatchTask
    if (-not $t) { throw 'Task not found after registering' }
    $delay = ''
    $logonTrigger = @($t.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' } | Select-Object -First 1
    if ($logonTrigger) { $delay = $logonTrigger.Delay }
    Write-Log "EnsureWatchdog: $($t.TaskPath)$($t.TaskName) ready, state=$($t.State), runs as $($t.Principal.UserId), triggers=$(@($t.Triggers).Count) (logon delay=$delay, daily 12:00), time limit=$($t.Settings.ExecutionTimeLimit), restart=$($t.Settings.RestartCount)x/$($t.Settings.RestartInterval), priority=$($t.Settings.Priority)"

    # Start it now if it is not already running, so sampling begins without
    # waiting for the next trigger.
    if ("$($t.State)" -ne 'Running') {
        Start-ScheduledTask -TaskName $WatchTaskName -TaskPath $WatchTaskPath
        Write-Log 'EnsureWatchdog: task was not running, started it'
    }
    $script:Code = 0
}

function Invoke-RemoveWatchdog {
    $t = Get-WatchTask
    if (-not $t) {
        Write-Log 'RemoveWatchdog: task not found, nothing to remove'
        $script:Code = 2
        return
    }
    if ($DryRun) {
        if ("$($t.State)" -eq 'Running') { Write-Log "DRYRUN: would stop the running instance of $WatchTaskPath$WatchTaskName" }
        Write-Log "DRYRUN: would remove the scheduled task $WatchTaskPath$WatchTaskName"
        $script:Code = 0
        return
    }
    if ("$($t.State)" -eq 'Running') {
        Stop-ScheduledTask -TaskName $WatchTaskName -TaskPath $WatchTaskPath
        Write-Log 'RemoveWatchdog: a running instance was stopped'
    }
    Unregister-ScheduledTask -TaskName $WatchTaskName -TaskPath $WatchTaskPath -Confirm:$false
    if (Get-WatchTask) { throw 'Task is still present after unregister.' }
    # The \PCTune\ task folder stays: the main maintenance task lives there.
    Write-Log 'RemoveWatchdog: task removed and verified gone'
    $script:Code = 0
}

# ---------------------------------------------------------------------------
# Process sampling (shared by Watchdog and Collect)
# ---------------------------------------------------------------------------

# Hashtable key -> info. The key holds name, PID and start time, so a reused
# PID is a different process. PID 0 (System Idle) is left out: its "CPU" is idle
# time. TotalProcessorTime and StartTime can be denied for some processes; those
# get a null CPU time and are skipped for CPU. Command lines are never read.
function Get-ProcSnapshot {
    param([bool]$WithPath = $false)
    $snap = @{}
    # Processes that could not be read (denied, or gone while reading) are counted,
    # so a thin snapshot is visible in the sample file and in the log.
    $script:ProcUnreadable = 0
    foreach ($p in @(Get-Process)) {
        try {
            if ($p.Id -eq 0) { continue }
            $cpu = $null
            $start = [long]0
            $path = $null
            try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch { $cpu = $null; $script:ProcUnreadable++ }
            try { $start = $p.StartTime.ToUniversalTime().Ticks } catch { $start = [long]0 }
            if ($WithPath) {
                try { $path = $p.MainModule.FileName } catch { $path = $null }
            }
            $key = '{0}|{1}|{2}' -f $p.ProcessName, $p.Id, $start
            $snap[$key] = [pscustomobject]@{
                Key = $key; Name = $p.ProcessName; ProcId = $p.Id; CpuSec = $cpu
                StartTicks = $start; RamMB = ($p.WorkingSet64 / 1MB); Path = $path
            }
        }
        catch { $script:ProcUnreadable++ }
        finally { $p.Dispose() }
    }
    return $snap
}

# CPU % per process = CPU seconds used since the previous snapshot / elapsed
# seconds / logical cores * 100, i.e. a share of the whole machine. A single
# busy thread on an 8-core PC therefore tops out near 12.5%.
# A process first seen since the last snapshot is measured from its total CPU
# time over the interval. Returns an array of rows.
function Get-ProcUsage {
    param($Prev, $Cur, [datetime]$PrevTimeUtc, [datetime]$NowUtc, [int]$Cores)
    $elapsed = [math]::Max(1.0, ($NowUtc - $PrevTimeUtc).TotalSeconds)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($Cur.Keys)) {
        $c = $Cur[$key]
        $pct = 0.0
        if ($null -ne $c.CpuSec) {
            if ($Prev.ContainsKey($key) -and $null -ne $Prev[$key].CpuSec) {
                $delta = $c.CpuSec - $Prev[$key].CpuSec
                if ($delta -gt 0) { $pct = $delta / $elapsed / $Cores * 100 }
            }
            elseif ($c.StartTicks -gt $PrevTimeUtc.Ticks) {
                $pct = $c.CpuSec / $elapsed / $Cores * 100
            }
        }
        if ($pct -gt 100) { $pct = 100.0 }
        $rows.Add([pscustomobject]@{ Key = $key; Name = $c.Name; ProcId = $c.ProcId; Cpu = $pct; RamMB = $c.RamMB; Path = $c.Path })
    }
    return ,$rows.ToArray()
}

function Get-CoreSortKey {
    param([string]$Name)
    $p = $Name -split ','
    if ($p.Count -eq 2) { return ([int]$p[0] * 1000 + [int]$p[1]) }
    return [int]$p[0]
}

# Win32_PerfFormattedData_* is used instead of Get-Counter because counter
# names are localized. Returns total and the per-core list in core order.
function Get-CpuReading {
    $rows = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor)
    $total = $null
    $t = $rows | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    if ($t) { $total = [double]$t.PercentProcessorTime }
    $cores = @($rows | Where-Object { $_.Name -match '^\d+(,\d+)?$' } |
        Sort-Object -Property @{ Expression = { Get-CoreSortKey $_.Name } } |
        ForEach-Object { [double]$_.PercentProcessorTime })
    return [pscustomobject]@{ Total = $total; Cores = $cores }
}

# ---------------------------------------------------------------------------
# Watchdog
# ---------------------------------------------------------------------------

$SampleSeconds = 60
$HotCpuPct     = 80
# Second CPU test: a process that keeps one logical core busy. Its share of the
# whole machine times the logical core count gives "% of one core", which can
# go above 100 for a multi-threaded process. A process is hot at 90 or more.
# On a multi-core PC a process over 80% of the whole machine is always over this
# too; both are kept so the reason column shows which one applied.
$HotCorePct    = 90
$HotRamMB      = 1024
# Logical core count used to turn whole-machine CPU % into % of one core. Set
# again by Invoke-Watchdog before any alert is written.
$script:WdCores = [math]::Max(1, [Environment]::ProcessorCount)
# A process raises an alert when it is hot in this many samples in a row. Samples
# are 60 s apart, so that is at least 2 minutes. Counting samples is used instead
# of comparing first and last timestamps, because a gap (sleep, a failed sample)
# would otherwise make a short spike look long.
$HotSamples    = 3

# The idle column marks the first sample after the watchdog started (about 5
# minutes after logon). wd_cpu_sec and wd_ws_mb are the watchdog's own CPU time
# and working set, so Collect can report what the watchdog really costs.
# proc_unreadable counts processes whose data could not be read.
$SampleHeader = 'timestamp,idle,cpu_total_pct,ram_used_mb,ram_total_mb,cpu_cores_pct,top_cpu,top_ram,wd_cpu_sec,wd_ws_mb,proc_unreadable'
# peak_cpu_pct is the share of the whole machine; peak_core_pct is the same
# reading as % of one logical core (peak_cpu_pct x logical cores).
$AlertHeader  = 'start,end,state,name,pid,reason,duration_s,peak_cpu_pct,peak_ram_mb,peak_core_pct'
$WatchLogName   = 'watchdog.log'
$OpenAlertsName = 'open_alerts.json'

# Past 1 MB the log moves to .old (replacing the previous .old), so the newest
# errors are never lost and the log cannot grow without limit.
function Invoke-WatchLogRotate {
    $f = Join-Path $SamplesDir $WatchLogName
    if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).Length -gt 1MB)) {
        Move-Item -LiteralPath $f -Destination ($f + '.old') -Force
    }
}

# One error line in samples\watchdog.log (the same file Write-Log uses when the
# task passes -LogFile). If the file cannot be written, the line goes to the
# console error stream instead, so an error is never dropped without a trace.
function Write-WatchError {
    param([string]$Text)
    $clean = ($Text -replace '[\r\n]+', ' ')
    if (-not [string]::IsNullOrEmpty($script:Secret)) { $clean = $clean.Replace($script:Secret, '[redacted]') }
    $line = '{0}  ERROR {1}' -f (Get-Stamp (Get-Date)), $clean
    try {
        Invoke-WatchLogRotate
        Add-TextRetry -Path (Join-Path $SamplesDir $WatchLogName) -Text ($line + "`r`n")
    }
    catch {
        [Console]::Error.WriteLine($line + ' (could not write watchdog.log: ' + $_.Exception.Message + ')')
    }
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[;:,"\r\n]', '_')
}

# Reason lists every test the episode failed, joined with '+': 'cpu' (over 80% of
# the whole machine), 'core' (90% or more of one core) and 'ram' (over 1024 MB),
# for example 'core' or 'cpu+core+ram'.
function Get-AlertReason {
    param($H)
    $parts = @()
    if ($H.CpuHot) { $parts += 'cpu' }
    if ($H.CoreHot) { $parts += 'core' }
    if ($H.RamHot) { $parts += 'ram' }
    return ($parts -join '+')
}

# One row in samples\alerts_YYYY-MM-DD.csv. State is 'ongoing' when the 3-sample
# threshold is crossed, then 'ended' (or 'ended (watchdog restarted)') with the
# final duration. Collect keeps the latest row per name+PID+start, which is the
# one with the longest duration. The resolution is one sample interval (60 s).
function Write-AlertRow {
    param($H, [string]$State, [datetime]$End)
    $dur = ($End - $H.Start).TotalSeconds
    $file = Join-Path $SamplesDir ('alerts_{0}.csv' -f (Get-DateText $End))
    $line = ((Get-Stamp $H.Start), (Get-Stamp $End), $State, (Get-SafeName $H.Name), $H.ProcId, (Get-AlertReason $H),
             [int]$dur, (Format-Num $H.PeakCpu 1), (Format-Num $H.PeakRam 0), (Format-Num ($H.PeakCpu * $script:WdCores) 0)) -join ','
    $text = $line + "`r`n"
    if (-not (Test-Path -LiteralPath $file)) { $text = $AlertHeader + "`r`n" + $text }
    Add-TextRetry -Path $file -Text $text
}

# Current hot episodes on disk, rewritten every sample. If the watchdog is killed
# or the PC loses power, the next start finds this file and closes the episodes.
function Save-OpenAlerts {
    $items = @(foreach ($h in $script:Hot.Values) {
        [pscustomobject]@{
            start = (Get-Stamp $h.Start); last = (Get-Stamp $h.Last); name = (Get-SafeName $h.Name); procId = $h.ProcId
            reason = (Get-AlertReason $h); peakCpu = [math]::Round($h.PeakCpu, 1); peakRam = [math]::Round($h.PeakRam, 0)
            samples = $h.Count; reported = [bool]$h.Reported
        }
    })
    $json = ConvertTo-Json -InputObject $items -Depth 3 -Compress
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $SamplesDir $OpenAlertsName), $json, $enc)
}

# On start: episodes that were already reported as ongoing but never got an end
# row (the watchdog was stopped hard) are closed, with the duration up to the last
# time they were seen. Episodes below the threshold were never reported, so they
# are simply dropped.
function Close-StaleAlerts {
    $f = Join-Path $SamplesDir $OpenAlertsName
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return }
    $closed = 0
    $items = @()
    try {
        $text = [IO.File]::ReadAllText($f)
        if (-not [string]::IsNullOrWhiteSpace($text)) { $items = @($text | ConvertFrom-Json) }
    }
    catch {
        Write-WatchError "open_alerts.json could not be read, ignoring it: $($_.Exception.Message)"
    }
    foreach ($i in $items) {
        try {
            if ($i.reported -ne $true) { continue }
            $parts = ([string]$i.reason) -split '\+'
            $h = [pscustomobject]@{
                Start = [datetime]::ParseExact([string]$i.start, 'yyyy-MM-ddTHH:mm:sszzz', $Inv)
                Last = [datetime]::ParseExact([string]$i.last, 'yyyy-MM-ddTHH:mm:sszzz', $Inv)
                Name = [string]$i.name; ProcId = $i.procId
                CpuHot = (@($parts) -contains 'cpu'); CoreHot = (@($parts) -contains 'core'); RamHot = (@($parts) -contains 'ram')
                PeakCpu = [double]$i.peakCpu; PeakRam = [double]$i.peakRam
            }
            Write-AlertRow -H $h -State 'ended (watchdog restarted)' -End $h.Last
            $closed++
        }
        catch { Write-WatchError "stale alert could not be closed: $($_.Exception.Message)" }
    }
    $script:Hot = @{}
    try { Save-OpenAlerts } catch { Write-WatchError "open_alerts.json could not be reset: $($_.Exception.Message)" }
    if ($closed -gt 0) { Write-Log "Watchdog: closed $closed stale alert(s) from the previous run" }
}

# A process is "hot" above 80% CPU (share of the whole machine), at 90% or more of
# one logical core (whole-machine % x logical cores), or above 1024 MB.
# The key (name, PID, start time) keeps a reused PID from joining two episodes.
# Count is the number of hot samples in a row: a process that is not hot in a
# sample is dropped, so a present entry always means "hot right up to now".
function Update-Alerts {
    param($Rows, [datetime]$Now)
    $seen = @{}
    foreach ($r in $Rows) {
        $cpuHot = ($r.Cpu -gt $HotCpuPct)
        $coreHot = (($r.Cpu * $script:WdCores) -ge $HotCorePct)
        $ramHot = ($r.RamMB -gt $HotRamMB)
        if (-not ($cpuHot -or $coreHot -or $ramHot)) { continue }
        $seen[$r.Key] = $true
        if ($script:Hot.ContainsKey($r.Key)) { $h = $script:Hot[$r.Key] }
        else {
            $h = [pscustomobject]@{ Start = $Now; Last = $Now; Name = $r.Name; ProcId = $r.ProcId; Count = 0; Reported = $false
                                    CpuHot = $false; CoreHot = $false; RamHot = $false; PeakCpu = 0.0; PeakRam = 0.0 }
            $script:Hot[$r.Key] = $h
        }
        $h.Last = $Now
        $h.Count++
        if ($cpuHot) { $h.CpuHot = $true }
        if ($coreHot) { $h.CoreHot = $true }
        if ($ramHot) { $h.RamHot = $true }
        if ($r.Cpu -gt $h.PeakCpu) { $h.PeakCpu = $r.Cpu }
        if ($r.RamMB -gt $h.PeakRam) { $h.PeakRam = $r.RamMB }
        # Threshold crossed: write the ongoing row once. If the write fails,
        # Reported stays false and the next sample tries again.
        if (-not $h.Reported -and $h.Count -ge $HotSamples) {
            try { Write-AlertRow -H $h -State 'ongoing' -End $Now; $h.Reported = $true }
            catch { Write-WatchError "alert write failed: $($_.Exception.Message)" }
        }
    }
    foreach ($key in @($script:Hot.Keys)) {
        if ($seen.ContainsKey($key)) { continue }
        $h = $script:Hot[$key]
        $script:Hot.Remove($key)
        if (-not $h.Reported) { continue }
        try { Write-AlertRow -H $h -State 'ended' -End $h.Last }
        catch { Write-WatchError "alert end write failed: $($_.Exception.Message)" }
    }
    try { Save-OpenAlerts } catch { Write-WatchError "open_alerts.json write failed: $($_.Exception.Message)" }
}

# Runs until the task is stopped (no time limit in the task). Its own CPU and
# memory are written into every sample, and Collect reports the measured CPU %,
# so no figure is claimed here.
function Invoke-Watchdog {
    if ($DryRun) {
        New-DryRunDirs
        Write-Log "DRYRUN: Watchdog takes $Samples sample(s) into $SamplesDir and then stops. Nothing is written to $TelDir."
    }
    elseif (-not (Test-Path -LiteralPath $SamplesDir -PathType Container)) {
        # Creating it here would give it the parent's ACL (Users can read), so
        # only Protect creates it.
        Write-Log "Watchdog: $SamplesDir not found. Run the Protect action first."
        $script:Code = 2
        return
    }

    # BelowNormal, not Idle: at Idle priority a PC under full load can starve the
    # sampler for minutes, which is exactly when the alerts matter.
    # Kept in a dry run too: it only changes this process, and the dry run should run
    # the same code as the real one.
    try { (Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal }
    catch { Write-WatchError "could not set BelowNormal priority: $($_.Exception.Message)" }

    if ($DryRun) {
        Write-Log "DRYRUN: would delete sample files older than $KeepDays days from the Telemetry samples folder (skipped)"
    }
    else {
        try {
            $n = Remove-OldFiles -Dir $SamplesDir -Days $KeepDays
            if ($n -gt 0) { Write-Log "Watchdog: pruned $n old sample file(s)" }
        }
        catch { Write-WatchError "prune failed: $($_.Exception.Message)" }
    }

    $cores = [math]::Max(1, [Environment]::ProcessorCount)
    $script:WdCores = $cores
    $script:Hot = @{}
    Close-StaleAlerts
    Write-Log "Watchdog: started, sampling every $SampleSeconds s on $cores logical cores"

    # Baseline for the first CPU deltas. The formatted perf class may report 0 or
    # stale values on its very first read, so one read is discarded as a precaution.
    $prev = Get-ProcSnapshot
    $prevT = [datetime]::UtcNow
    try { [void](Get-CpuReading) } catch { Write-WatchError "warm-up read failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds 10

    $firstSample = $true
    $maxUnreadable = 0
    # Loops started, failed ones included, so a dry run always ends.
    $taken = 0
    $good = 0
    try {
        while ($true) {
            $loopStart = [datetime]::UtcNow
            try {
                $now = Get-Date
                $cur = Get-ProcSnapshot
                $unreadable = $script:ProcUnreadable
                if ($unreadable -gt $maxUnreadable) {
                    Write-Log "Watchdog: $unreadable process(es) could not be fully read in this snapshot"
                    $maxUnreadable = $unreadable
                }
                $nowT = [datetime]::UtcNow
                $rows = @(Get-ProcUsage -Prev $prev -Cur $cur -PrevTimeUtc $prevT -NowUtc $nowT -Cores $cores)
                $cpu = Get-CpuReading
                $os = Get-CimInstance -ClassName Win32_OperatingSystem
                $ramTotal = $os.TotalVisibleMemorySize / 1KB
                $ramUsed = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB

                $me = Get-Process -Id $PID
                try { $wdCpu = $me.TotalProcessorTime.TotalSeconds; $wdWs = $me.WorkingSet64 / 1MB }
                finally { $me.Dispose() }

                $topCpu = @($rows | Where-Object { $_.Cpu -gt 0 } | Sort-Object -Property Cpu -Descending | Select-Object -First 5 |
                    ForEach-Object { '{0}:{1}:{2}:{3}' -f (Get-SafeName $_.Name), $_.ProcId, (Format-Num $_.Cpu 1), (Format-Num $_.RamMB 0) })
                $topRam = @($rows | Sort-Object -Property RamMB -Descending | Select-Object -First 5 |
                    ForEach-Object { '{0}:{1}:{2}:{3}' -f (Get-SafeName $_.Name), $_.ProcId, (Format-Num $_.Cpu 1), (Format-Num $_.RamMB 0) })
                $coreText = (@($cpu.Cores | ForEach-Object { Format-Num $_ 0 })) -join ';'

                # "idle" only means the first sample after start, which is about 5
                # minutes after logon. The PC is not guaranteed to be idle then.
                if ($firstSample) { $idle = 1 } else { $idle = 0 }
                $line = ((Get-Stamp $now), $idle, (Format-Num $cpu.Total 1), (Format-Num $ramUsed 0), (Format-Num $ramTotal 0),
                         $coreText, ($topCpu -join ';'), ($topRam -join ';'),
                         (Format-Num $wdCpu 2), (Format-Num $wdWs 1), $unreadable) -join ','

                $file = Join-Path $SamplesDir ('{0}.csv' -f (Get-DateText $now))
                $text = $line + "`r`n"
                if (-not (Test-Path -LiteralPath $file)) { $text = $SampleHeader + "`r`n" + $text }
                Add-TextRetry -Path $file -Text $text

                Update-Alerts -Rows $rows -Now $now
                $prev = $cur
                $prevT = $nowT
                $firstSample = $false
                $good++
            }
            catch {
                Write-WatchError "sample failed: $($_.Exception.Message)"
            }
            $taken++
            # Dry run only: stop after -Samples samples. The finally block below
            # still does the normal clean-stop flush.
            if ($DryRun -and $taken -ge $Samples) { break }
            $spent = ([datetime]::UtcNow - $loopStart).TotalSeconds
            Start-Sleep -Milliseconds ([int]([math]::Max(1.0, $SampleSeconds - $spent) * 1000))
        }
    }
    finally {
        # Only reached on a clean stop. A hard kill is covered by Close-StaleAlerts.
        foreach ($key in @($script:Hot.Keys)) {
            $h = $script:Hot[$key]
            if (-not $h.Reported) { continue }
            try { Write-AlertRow -H $h -State 'ended (watchdog stopped)' -End $h.Last }
            catch { Write-WatchError "alert flush failed: $($_.Exception.Message)" }
        }
        $script:Hot = @{}
        try { Save-OpenAlerts } catch { Write-WatchError "open_alerts.json reset failed: $($_.Exception.Message)" }
    }
    if ($DryRun) {
        Write-Log "DRYRUN: Watchdog stopped after $taken sample(s), $good of them good. Samples and alerts are in $SamplesDir"
        if ($good -eq 0) {
            Write-Log "FAIL: the watchdog could not take a single sample. See $WatchLogName in $SamplesDir."
            $script:Code = 1
            return
        }
    }
    $script:Code = 0
}

# ---------------------------------------------------------------------------
# Collect: helpers
# ---------------------------------------------------------------------------

$script:Snap = $null
$script:Errors = $null
$script:RowCache = $null
$script:ReportDays = @()
$script:HasMarker = $false
$script:LastReportedDay = $null
$script:ProcUnreadable = 0
$script:NativeExit = 0
$MarkerFile = Join-Path $TelDir 'last_reported_day.txt'
$WatchLogPath = Join-Path $SamplesDir 'watchdog.log'

function Test-IsError {
    param($Obj)
    return (($Obj -is [System.Collections.IDictionary]) -and $Obj.Contains('error'))
}

# One top-level section. A failure is stored as {error: message} and in the
# top-level errors list; the next section still runs.
function Invoke-Section {
    param([string]$Name, [scriptblock]$Body)
    try {
        $v = & $Body
        $script:Snap[$Name] = $v
    }
    catch {
        $msg = $_.Exception.Message
        $script:Snap[$Name] = [ordered]@{ error = $msg }
        $script:Errors.Add("${Name}: $msg")
        Write-Log "Collect: section $Name failed: $msg"
    }
}

# A part inside a section, so one failing query does not hide the others.
function Invoke-Part {
    param([string]$Section, [string]$Part, [scriptblock]$Body)
    try {
        $v = & $Body
        return ,$v
    }
    catch {
        $msg = $_.Exception.Message
        $script:Errors.Add("${Section}.${Part}: $msg")
        Write-Log "Collect: ${Section}.${Part} failed: $msg"
        return [ordered]@{ error = $msg }
    }
}

function Read-CsvShared {
    param([string]$Path)
    $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    finally { $fs.Dispose() }
    $lines = @($text -split '\r?\n' | Where-Object { $_ -ne '' })
    if ($lines.Count -lt 2) { return ,@() }
    return ,@($lines | ConvertFrom-Csv)
}

# Rows of one day's CSV, or $null when that file does not exist.
function Get-DayRows {
    param([string]$Date, [string]$Prefix = '')
    $p = Join-Path $SamplesDir ('{0}{1}.csv' -f $Prefix, $Date)
    # Several sections read the same day; read each file once per run.
    if ($null -ne $script:RowCache -and $script:RowCache.ContainsKey($p)) { return ,$script:RowCache[$p] }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $rows = Read-CsvShared $p
    if ($null -ne $script:RowCache) { $script:RowCache[$p] = $rows }
    return ,$rows
}

# All lines of a text file that another process may be appending to.
function Read-LinesShared {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    finally { $fs.Dispose() }
    return @($text -split '\r?\n' | Where-Object { $_ -ne '' })
}

# The full days this report covers, as yyyy-MM-dd strings in $script:ReportDays.
# Range = (day after the marker) .. yesterday, at most the last 14 days. Today is
# never included because it is not finished. Without a readable marker only
# yesterday is covered. $script:HasMarker says whether a marker was used, because
# a day without samples is only an error when a report was expected to cover it.
# A dry run covers today only, so the samples it has just taken are in the report;
# it ignores the marker.
function Initialize-ReportDays {
    if ($DryRun) {
        $script:HasMarker = $false
        $script:LastReportedDay = $null
        $script:ReportDays = @(Get-DateText (Get-Date))
        return
    }
    $today = (Get-Date).Date
    $yesterday = $today.AddDays(-1)
    $first = $yesterday
    $script:HasMarker = $false
    $script:LastReportedDay = $null
    if (Test-Path -LiteralPath $MarkerFile -PathType Leaf) {
        $txt = ([IO.File]::ReadAllText($MarkerFile)).Trim()
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($txt, 'yyyy-MM-dd', $Inv, [Globalization.DateTimeStyles]::None, [ref]$d)) {
            $script:HasMarker = $true
            $script:LastReportedDay = $txt
            $first = $d.Date.AddDays(1)
        }
        else { Write-Log 'Collect: last_reported_day.txt is not a yyyy-MM-dd date, ignoring it (yesterday only)' }
    }
    $cap = $today.AddDays(-$KeepDays)
    if ($first -lt $cap) { $first = $cap }
    $days = New-Object System.Collections.Generic.List[string]
    for ($d2 = $first; $d2 -le $yesterday; $d2 = $d2.AddDays(1)) { $days.Add((Get-DateText $d2)) }
    $script:ReportDays = $days.ToArray()
}

function ConvertTo-DoubleOrNull {
    param($Text)
    $out = 0.0
    if ([double]::TryParse([string]$Text, [Globalization.NumberStyles]::Float, $Inv, [ref]$out)) { return $out }
    return $null
}

function Get-RoundedOrNull {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value) { return $null }
    return [math]::Round([double]$Value, $Digits)
}

# RAM and CPU figures for one day of watchdog samples.
function Get-DayStats {
    param($Rows)
    if ($null -eq $Rows) { return [ordered]@{ available = $false; reason = 'no samples file for that day' } }
    $ram = New-Object System.Collections.Generic.List[double]
    $cpu = New-Object System.Collections.Generic.List[double]
    $firstRam = $null
    $ramTotal = $null
    $coreSum = @{}
    $coreMax = @{}
    $coreN = @{}
    foreach ($r in $Rows) {
        $u = ConvertTo-DoubleOrNull $r.ram_used_mb
        if ($null -ne $u) {
            $ram.Add($u)
            # idle=1 marks the first sample after the watchdog started (about 5
            # minutes after logon); the PC is not guaranteed to be idle then.
            if ("$($r.idle)" -eq '1' -and $null -eq $firstRam) { $firstRam = $u }
        }
        $t = ConvertTo-DoubleOrNull $r.ram_total_mb
        if ($null -ne $t) { $ramTotal = $t }
        $c = ConvertTo-DoubleOrNull $r.cpu_total_pct
        if ($null -ne $c) { $cpu.Add($c) }
        $i = 0
        foreach ($part in ([string]$r.cpu_cores_pct -split ';')) {
            $v = ConvertTo-DoubleOrNull $part
            if ($null -ne $v) {
                if (-not $coreSum.ContainsKey($i)) { $coreSum[$i] = 0.0; $coreMax[$i] = 0.0; $coreN[$i] = 0 }
                $coreSum[$i] += $v
                if ($v -gt $coreMax[$i]) { $coreMax[$i] = $v }
                $coreN[$i] += 1
            }
            $i++
        }
    }
    $avgCore = New-Object System.Collections.Generic.List[object]
    $maxCore = New-Object System.Collections.Generic.List[object]
    foreach ($i in (@($coreSum.Keys) | Sort-Object)) {
        $avgCore.Add([math]::Round($coreSum[$i] / $coreN[$i], 1))
        $maxCore.Add([math]::Round($coreMax[$i], 1))
    }
    $ramAvg = $null; $ramPeak = $null; $cpuAvg = $null; $cpuPeak = $null
    if ($ram.Count -gt 0) {
        $ramAvg = ($ram | Measure-Object -Average).Average
        $ramPeak = ($ram | Measure-Object -Maximum).Maximum
    }
    if ($cpu.Count -gt 0) {
        $cpuAvg = ($cpu | Measure-Object -Average).Average
        $cpuPeak = ($cpu | Measure-Object -Maximum).Maximum
    }
    $first = $null; $last = $null
    if (@($Rows).Count -gt 0) { $first = @($Rows)[0].timestamp; $last = @($Rows)[@($Rows).Count - 1].timestamp }
    return [ordered]@{
        available           = $true
        samples             = @($Rows).Count
        firstSample         = $first
        lastSample          = $last
        ramTotalMB          = Get-RoundedOrNull $ramTotal 0
        ramFirstSampleAfterLogonUsedMB = Get-RoundedOrNull $firstRam 0
        ramAvgUsedMB        = Get-RoundedOrNull $ramAvg 0
        ramPeakUsedMB       = Get-RoundedOrNull $ramPeak 0
        cpuAvgPct           = Get-RoundedOrNull $cpuAvg 1
        cpuPeakPct          = Get-RoundedOrNull $cpuPeak 1
        perCoreAvgPct       = $avgCore.ToArray()
        perCorePeakPct      = $maxCore.ToArray()
    }
}

# Only the program part of a startup command is kept. Arguments can hold
# secrets, so they are dropped on purpose.
function Get-ProgramPart {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    $c = $Command.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 0) { return $c.Substring(1, $end - 1) }
        return '(unparsed)'
    }
    # Unquoted: arguments usually start at whitespace followed by - or /, or at an
    # "=" (name=value). Cut there first so a switch or value is never reported,
    # even when the command has no known extension.
    $cut = [regex]::Match($c, '\s[-/]|=')
    if ($cut.Success) { $c = $c.Substring(0, $cut.Index).TrimEnd() }
    $m = [regex]::Match($c, '^.*?\.(exe|bat|cmd|com|lnk|vbs|ps1|msc|cpl)\b', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Value }
    $sp = $c.IndexOf(' ')
    if ($sp -gt 0) { return $c.Substring(0, $sp) }
    return $c
}

function Get-RunEntries {
    param([string]$Key, [string]$Scope, [string]$Kind)
    $out = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $Key) {
        $props = (Get-ItemProperty -LiteralPath $Key).PSObject.Properties |
                 Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }
        foreach ($p in $props) {
            $out.Add([ordered]@{ scope = $Scope; kind = $Kind; name = $p.Name; program = (Get-ProgramPart ([string]$p.Value)) })
        }
    }
    return ,$out.ToArray()
}

# CIM dates for driver and BIOS dates are stored as UTC midnight and converted
# to local time, so converting back to UTC gives the original calendar day.
# Not verified on the target PC.
function ConvertTo-CimDay {
    param($Date)
    if ($null -eq $Date) { return $null }
    return ([datetime]$Date).ToUniversalTime().Date
}

function Convert-EventRow {
    param($E)
    $msg = ''
    if ($E.Message) {
        $msg = ($E.Message -split '\r?\n')[0]
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
    }
    return [ordered]@{
        time     = Get-Stamp $E.TimeCreated
        provider = $E.ProviderName
        id       = [int]$E.Id
        level    = [int]$E.Level
        message  = $msg
    }
}

# Newest 100 events plus the total count. "No events" is not an error.
function Get-EventSummary {
    param([hashtable]$Filter)
    try {
        $all = @(Get-WinEvent -FilterHashtable $Filter)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $all = @() }
        else { throw }
    }
    return (New-EventSummary $all)
}

function New-EventSummary {
    param($All)
    $All = @($All)
    $top = @($All | Sort-Object -Property TimeCreated -Descending | Select-Object -First 100)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $top) { $rows.Add((Convert-EventRow $e)) }
    return [ordered]@{ total = $All.Count; shown = $rows.Count; events = $rows.ToArray() }
}

# ---------------------------------------------------------------------------
# Collect: sections
# ---------------------------------------------------------------------------

function Get-DisksSection {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
        if (-not $d.Size) { continue }
        $total = [double]$d.Size
        $free = [double]$d.FreeSpace
        $used = $total - $free
        $list.Add([ordered]@{
            drive   = $d.DeviceID
            totalGB = [math]::Round($total / 1GB, 1)
            usedGB  = [math]::Round($used / 1GB, 1)
            freeGB  = [math]::Round($free / 1GB, 1)
            usedPct = [math]::Round($used / $total * 100, 1)
            freePct = [math]::Round($free / $total * 100, 1)
        })
    }
    return ,$list.ToArray()
}

function Get-RamSection {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalKB = [double]$os.TotalVisibleMemorySize
    $usedKB = $totalKB - [double]$os.FreePhysicalMemory
    $days = New-Object System.Collections.Generic.List[object]
    foreach ($day in $script:ReportDays) {
        $dd = $day
        $st = Invoke-Part 'ram' $dd { Get-DayStats (Get-DayRows $dd) }
        $days.Add([ordered]@{ date = $dd; stats = $st })
    }
    return [ordered]@{
        now = [ordered]@{
            totalGB = [math]::Round($totalKB / 1MB, 1)
            usedGB  = [math]::Round($usedKB / 1MB, 1)
            usedPct = [math]::Round($usedKB / $totalKB * 100, 1)
        }
        days = $days.ToArray()
        note = 'Sample-based figures. "First sample after logon" is the first sample after the watchdog started, about 5 minutes after logon; the PC is not guaranteed to be idle then.'
    }
}

function Get-CpuSection {
    # The perf class can return a stale value on the first read, so read twice
    # and report the second.
    [void](Get-CpuReading)
    Start-Sleep -Seconds 2
    $live = Get-CpuReading
    $days = New-Object System.Collections.Generic.List[object]
    foreach ($day in $script:ReportDays) {
        $dd = $day
        $st = Invoke-Part 'cpu' $dd { Get-DayStats (Get-DayRows $dd) }
        $days.Add([ordered]@{ date = $dd; stats = $st })
    }
    return [ordered]@{
        liveTotalPct   = Get-RoundedOrNull $live.Total 1
        liveCorePct    = @($live.Cores | ForEach-Object { [math]::Round($_, 1) })
        logicalCores   = [Environment]::ProcessorCount
        days           = $days.ToArray()
    }
}

function Get-ProcessesSection {
    $cores = [math]::Max(1, [Environment]::ProcessorCount)
    $s1 = Get-ProcSnapshot
    $t1 = [datetime]::UtcNow
    Start-Sleep -Seconds 5
    $s2 = Get-ProcSnapshot -WithPath $true
    $t2 = [datetime]::UtcNow
    if ($script:ProcUnreadable -gt 0) { Write-Log "Collect: $($script:ProcUnreadable) process(es) could not be fully read (access denied or exited)" }
    $rows = @(Get-ProcUsage -Prev $s1 -Cur $s2 -PrevTimeUtc $t1 -NowUtc $t2 -Cores $cores)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in ($rows | Sort-Object -Property @{ Expression = 'Cpu'; Descending = $true }, @{ Expression = 'RamMB'; Descending = $true })) {
        $list.Add([ordered]@{
            name   = $r.Name
            pid    = $r.ProcId
            cpuPct = [math]::Round($r.Cpu, 1)
            # The same reading as % of one logical core; above 100 means more
            # than one core's worth of work.
            cpuPctOneCore = [math]::Round($r.Cpu * $cores, 1)
            ramMB  = [math]::Round($r.RamMB, 1)
            path   = $r.Path
        })
    }
    return ,$list.ToArray()
}

function Get-StartupSection {
    $profiles = @(Get-RealProfiles)
    $runKeys = New-Object System.Collections.Generic.List[object]
    $cv = 'SOFTWARE\Microsoft\Windows\CurrentVersion'
    $wow = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion'
    $machine = @(
        @{ Key = "HKLM:\$cv\Run";       Scope = 'HKLM';       Kind = 'Run' },
        @{ Key = "HKLM:\$cv\RunOnce";   Scope = 'HKLM';       Kind = 'RunOnce' },
        @{ Key = "HKLM:\$wow\Run";      Scope = 'HKLM-WOW64'; Kind = 'Run' },
        @{ Key = "HKLM:\$wow\RunOnce";  Scope = 'HKLM-WOW64'; Kind = 'RunOnce' }
    )
    foreach ($m in $machine) {
        foreach ($e in (Get-RunEntries $m.Key $m.Scope $m.Kind)) { $runKeys.Add($e) }
    }
    # Only user hives that are loaded (signed-in users) can be read here.
    $hives = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })
    foreach ($h in $hives) {
        $sid = $h.PSChildName
        $user = $sid
        $pr = $profiles | Where-Object { $_.Sid -eq $sid } | Select-Object -First 1
        if ($pr) { $user = $pr.Name }
        foreach ($kind in 'Run', 'RunOnce') {
            foreach ($e in (Get-RunEntries "Registry::HKEY_USERS\$sid\$cv\$kind" "user:$user" $kind)) { $runKeys.Add($e) }
        }
    }

    $folders = New-Object System.Collections.Generic.List[object]
    $dirs = New-Object System.Collections.Generic.List[object]
    $dirs.Add(@{ Dir = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Scope = 'common' })
    foreach ($p in $profiles) {
        $dirs.Add(@{ Dir = (Join-Path $p.Path 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'); Scope = "user:$($p.Name)" })
    }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d.Dir -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d.Dir -Force -File | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $folders.Add([ordered]@{ scope = $d.Scope; file = $f.Name })
        }
    }

    $tasks = New-Object System.Collections.Generic.List[object]
    $msCount = 0
    $startTypes = @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')
    foreach ($t in @(Get-ScheduledTask)) {
        if ("$($t.State)" -eq 'Disabled') { continue }
        $kinds = New-Object System.Collections.Generic.List[string]
        foreach ($tr in @($t.Triggers)) {
            if ($tr -and ($tr.CimClass.CimClassName -in $startTypes)) {
                if ($tr.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') { $kinds.Add('logon') } else { $kinds.Add('boot') }
            }
        }
        if ($kinds.Count -eq 0) { continue }
        if ($t.TaskPath -like '\Microsoft\*') { $msCount++; continue }
        $exe = ''
        $first = @($t.Actions) | Select-Object -First 1
        if ($first) { $exe = Get-ProgramPart ([string]$first.Execute) }
        $tasks.Add([ordered]@{ path = $t.TaskPath; name = $t.TaskName; state = [string]$t.State; triggers = (@($kinds | Select-Object -Unique) -join ','); program = $exe })
    }

    return [ordered]@{
        runKeys                      = $runKeys.ToArray()
        startupFolders               = $folders.ToArray()
        scheduledTasks               = $tasks.ToArray()
        microsoftLogonBootTaskCount  = $msCount
        note                         = 'Only the program path is kept, never its arguments. Entries disabled in Task Manager may still be listed. Only loaded user hives are read.'
    }
}

function Get-ProgramsSection {
    $keys = New-Object System.Collections.Generic.List[string]
    $keys.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    $keys.Add('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($h in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
        $keys.Add("Registry::HKEY_USERS\$($h.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
    }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $k)) {
            $p = Get-ItemProperty -LiteralPath $sub.PSPath
            $name = [string]$p.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($p.SystemComponent -eq 1) { continue }
            if (-not [string]::IsNullOrEmpty([string]$p.ParentKeyName)) { continue }
            $ver = [string]$p.DisplayVersion
            $pub = [string]$p.Publisher
            if (-not $seen.Add(("$name|$ver|$pub").ToLowerInvariant())) { continue }
            $date = $null
            $raw = [string]$p.InstallDate
            if ($raw -match '^\d{8}$') {
                $d = [datetime]::MinValue
                if ([datetime]::TryParseExact($raw, 'yyyyMMdd', $Inv, [Globalization.DateTimeStyles]::None, [ref]$d)) {
                    $date = $d.ToString('yyyy-MM-dd', $Inv)
                }
            }
            $list.Add([ordered]@{ name = $name; version = $ver; publisher = $pub; installDate = $date })
        }
    }
    return ,@($list.ToArray() | Sort-Object -Property @{ Expression = { $_.name } })
}

function Get-DriversSection {
    $classes = @('DISPLAY', 'NET', 'SCSIADAPTER', 'HDC', 'SYSTEM')
    $oldBefore = (Get-Date).AddYears(-2)
    $placeholder = [datetime]'2006-06-21'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver)) {
        $class = ([string]$d.DeviceClass).ToUpperInvariant()
        if ($classes -notcontains $class) { continue }
        $provider = [string]$d.DriverProviderName
        $isMs = ($provider -match '^Microsoft')
        # SYSTEM is mostly inbox plumbing; only third-party providers (chipset) matter.
        if ($class -eq 'SYSTEM' -and ($isMs -or [string]::IsNullOrWhiteSpace($provider))) { continue }
        $device = [string]$d.DeviceName
        if ([string]::IsNullOrWhiteSpace($device)) { $device = [string]$d.Description }
        $day = ConvertTo-CimDay $d.DriverDate
        $dateText = $null
        $old = $null
        $inbox = $false
        $note = $null
        if ($null -ne $day) {
            $dateText = $day.ToString('yyyy-MM-dd', $Inv)
            if ($isMs -and $day -eq $placeholder) {
                $inbox = $true
                $old = $false
                $note = 'Inbox Microsoft driver; the 2006-06-21 date is a placeholder and not meaningful.'
            }
            else { $old = ($day -lt $oldBefore) }
        }
        $list.Add([ordered]@{
            device = $device; class = $class; provider = $provider; version = [string]$d.DriverVersion
            date = $dateText; old = $old; inbox = $inbox; note = $note
        })
    }
    return ,@($list.ToArray() | Sort-Object -Property @{ Expression = { $_.class } }, @{ Expression = { $_.device } })
}

# The search runs in a job because an online search can hang; the job is
# abandoned after 600 s. Offline or timed out is recorded as a reason, not as a
# collection error.
function Get-UpdatesSection {
    $job = Start-Job -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
        foreach ($u in $result.Updates) {
            $kbs = @()
            foreach ($k in $u.KBArticleIDs) { $kbs += ('KB' + $k) }
            # BrowseOnly / AutoSelectOnWebSites are not available on every Windows Update
            # Agent version; missing values are treated as "unknown".
            $browse = $null
            $auto = $null
            if ($null -ne $u.BrowseOnly) { try { $browse = [bool]$u.BrowseOnly } catch { $browse = $null } }
            if ($null -ne $u.AutoSelectOnWebSites) { try { $auto = [bool]$u.AutoSelectOnWebSites } catch { $auto = $null } }
            [pscustomobject]@{
                Title = [string]$u.Title; Type = [int]$u.Type; Kbs = $kbs
                Browse = $browse; Auto = $auto; Size = [double]$u.MaxDownloadSize
            }
        }
    }
    $status = 'ok'
    $reason = $null
    $items = @()
    try {
        $done = Wait-Job -Job $job -Timeout 600
        if (-not $done) {
            $status = 'timeout'
            $reason = 'update search did not finish within 600 seconds'
            Stop-Job -Job $job
        }
        elseif ($job.State -eq 'Failed') {
            $reason = [string]$job.ChildJobs[0].JobStateInfo.Reason.Message
            # Only network HRESULTs mean "offline": 0x80072Exx (WinINet) and
            # 0x80244xxx (Windows Update client, network side). Any other failure is
            # a real error and is recorded with its HRESULT instead of being passed
            # off as "no internet".
            $hr = [regex]::Match($reason, '0x[0-9A-Fa-f]{8}')
            if ($hr.Success -and $hr.Value -match '^0x(80072[Ee][0-9A-Fa-f]{2}|80244[0-9A-Fa-f]{3})$') {
                $status = 'unavailable'
                $reason += ' (looks like the PC is offline or Windows Update is unreachable)'
            }
            else {
                $status = 'error'
                $hrText = 'no HRESULT in the message'
                if ($hr.Success) { $hrText = $hr.Value }
                $msg = "update search failed ($hrText): $reason"
                $script:Errors.Add("updates: $msg")
                Write-Log "Collect: ERROR updates: $msg"
            }
        }
        else {
            $items = @(Receive-Job -Job $job)
        }
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($u in $items) {
        if ($u.Type -eq 2) { $type = 'Driver' } else { $type = 'Software' }
        $optional = $null
        if ($u.Browse -eq $true -or $u.Auto -eq $false) { $optional = $true }
        elseif ($null -ne $u.Browse -or $null -ne $u.Auto) { $optional = $false }
        $list.Add([ordered]@{
            title = $u.Title; type = $type; kbs = @($u.Kbs); optional = $optional
            sizeMB = [math]::Round($u.Size / 1MB, 1)
        })
    }
    return [ordered]@{ status = $status; reason = $reason; count = $list.Count; updates = $list.ToArray() }
}

function Get-HealthSection {
    $disks = Invoke-Part 'health' 'disks' {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($d in @(Get-PhysicalDisk)) {
            $entry = [ordered]@{
                name = [string]$d.FriendlyName; mediaType = [string]$d.MediaType; busType = [string]$d.BusType
                health = [string]$d.HealthStatus; status = [string]$d.OperationalStatus
                sizeGB = [math]::Round($d.Size / 1GB, 1)
            }
            try {
                $rc = $d | Get-StorageReliabilityCounter
                $entry['wear'] = $rc.Wear
                $entry['temperatureC'] = $rc.Temperature
                $entry['readErrorsTotal'] = $rc.ReadErrorsTotal
                $entry['writeErrorsTotal'] = $rc.WriteErrorsTotal
                $entry['powerOnHours'] = $rc.PowerOnHours
            }
            catch {
                # Many drives do not offer every counter; keep the rest of the entry.
                $entry['counterError'] = $_.Exception.Message
            }
            $list.Add($entry)
        }
        ,$list.ToArray()
    }

    $boot = Invoke-Part 'health' 'boot' {
        $list = New-Object System.Collections.Generic.List[object]
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $events = @() } else { throw }
        }
        foreach ($ev in $events) {
            $xml = [xml]$ev.ToXml()
            $h = @{}
            foreach ($d in $xml.Event.EventData.Data) { $h[$d.Name] = $d.'#text' }
            $row = [ordered]@{ time = Get-Stamp $ev.TimeCreated }
            foreach ($pair in @(@('BootTime', 'bootTimeSec'), @('MainPathBootTime', 'mainPathBootTimeSec'), @('BootPostBootTime', 'postBootTimeSec'))) {
                $v = ConvertTo-DoubleOrNull $h[$pair[0]]
                if ($null -ne $v) { $row[$pair[1]] = [math]::Round($v / 1000, 1) } else { $row[$pair[1]] = $null }
            }
            $list.Add($row)
        }
        ,$list.ToArray()
    }

    $since = (Get-Date).AddDays(-7)
    $sys = Invoke-Part 'health' 'systemLog' {
        # One query per provider: a single query with a list fails as a whole when
        # one provider is not registered on this PC. "No events" (which is also what
        # an unregistered provider reports) is normal; any other error is recorded.
        $all = New-Object System.Collections.Generic.List[object]
        $provErrors = New-Object System.Collections.Generic.List[string]
        foreach ($pv in @('Microsoft-Windows-Kernel-Power', 'disk', 'Ntfs', 'Microsoft-Windows-Ntfs', 'stornvme', 'storahci')) {
            try {
                foreach ($ev in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $since; ProviderName = $pv })) { $all.Add($ev) }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -like 'No events were found*') { continue }
                $m = "${pv}: $($_.Exception.Message)"
                $provErrors.Add($m)
                $script:Errors.Add("health.systemLog.${m}")
                Write-Log "Collect: ERROR health.systemLog provider $m"
            }
        }
        $sum = New-EventSummary $all.ToArray()
        $sum['providerErrors'] = $provErrors.ToArray()
        $sum
    }
    $app = Invoke-Part 'health' 'appCrashes' {
        Get-EventSummary @{
            LogName = 'Application'; Id = 1000, 1002; StartTime = $since
            ProviderName = @('Application Error', 'Application Hang')
        }
    }
    return [ordered]@{ physicalDisks = $disks; boots = $boot; systemLog7d = $sys; appCrashesAndHangs7d = $app }
}

function Get-SystemSection {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $biosDay = ConvertTo-CimDay $bios.ReleaseDate
    $biosText = $null
    if ($null -ne $biosDay) { $biosText = $biosDay.ToString('yyyy-MM-dd', $Inv) }
    $up = (Get-Date) - $os.LastBootUpTime

    $battery = Invoke-Part 'system' 'battery' {
        $bat = @(Get-CimInstance -ClassName Win32_Battery)
        if ($bat.Count -eq 0) { return [ordered]@{ present = $false; status = 'no battery' } }
        $xmlPath = Join-Path $WorkDir 'battery.xml'
        try {
            if (Test-Path -LiteralPath $xmlPath) { Remove-Item -LiteralPath $xmlPath -Force }
            $pcOut = Invoke-Native -Exe (Join-Path $env:SystemRoot 'System32\powercfg.exe') -Arguments @('/batteryreport', '/xml', '/output', $xmlPath)
            $pcExit = $script:NativeExit
            if ($pcExit -ne 0 -or -not (Test-Path -LiteralPath $xmlPath)) {
                # Keep powercfg's own message: it says why (for example no battery
                # service), which the bare failure would hide.
                $pcText = ("$pcOut" -replace '\s+', ' ').Trim()
                if ($pcText.Length -gt 300) { $pcText = $pcText.Substring(0, 300) }
                Write-Log "Collect: powercfg /batteryreport failed (exit $pcExit): $pcText"
                throw "powercfg failed (exit $pcExit): $pcText"
            }
            $xml = New-Object System.Xml.XmlDocument
            $xml.XmlResolver = $null
            $xml.Load($xmlPath)
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($b in $xml.SelectNodes("//*[local-name()='Batteries']/*[local-name()='Battery']")) {
                $dn = $b.SelectSingleNode("*[local-name()='DesignCapacity']")
                $fn = $b.SelectSingleNode("*[local-name()='FullChargeCapacity']")
                $cn = $b.SelectSingleNode("*[local-name()='CycleCount']")
                $design = $null; $full = $null; $cycles = $null; $health = $null
                if ($dn) { $design = ConvertTo-DoubleOrNull $dn.InnerText }
                if ($fn) { $full = ConvertTo-DoubleOrNull $fn.InnerText }
                if ($cn) { $cycles = ConvertTo-DoubleOrNull $cn.InnerText }
                if ($design -and $null -ne $full) { $health = [math]::Round($full / $design * 100, 1) }
                $list.Add([ordered]@{
                    designCapacityMWh = $design; fullChargeCapacityMWh = $full; healthPct = $health
                    cycleCount = $cycles
                })
            }
            # A cycle count of 0 can also mean the battery does not report it.
            return [ordered]@{ present = $true; batteries = $list.ToArray() }
        }
        finally {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [ordered]@{
        manufacturer = [string]$cs.Manufacturer
        model        = [string]$cs.Model
        biosVersion  = [string]$bios.SMBIOSBIOSVersion
        biosDate     = $biosText
        windows      = [string]$os.Caption
        displayVersion = [string]$cv.DisplayVersion
        build        = ('{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR)
        uptimeHours  = [math]::Round($up.TotalHours, 1)
        lastBoot     = Get-Stamp $os.LastBootUpTime
        battery      = $battery
    }
}

function Get-AlertsSection {
    # One alert episode can have several rows (ongoing, then ended), possibly in two
    # day files. Keep the latest row per name+PID+start, which has the longest
    # duration, and show it under the day file it was found in.
    $best = @{}
    $dayErrors = @{}
    foreach ($day in $script:ReportDays) {
        $dd = $day
        $rows = Invoke-Part 'watchdogAlerts' $dd { $r = Get-DayRows $dd 'alerts_'; if ($null -eq $r) { ,@() } else { ,@($r) } }
        if (Test-IsError $rows) { $dayErrors[$dd] = $rows; continue }
        foreach ($r in @($rows)) {
            $dur = ConvertTo-DoubleOrNull $r.duration_s
            if ($null -eq $dur) { $dur = 0.0 }
            $key = '{0}|{1}|{2}' -f $r.name, $r.pid, $r.start
            if ($best.ContainsKey($key) -and $best[$key].Dur -gt $dur) { continue }
            $best[$key] = [pscustomobject]@{ Row = $r; Day = $dd; Dur = $dur }
        }
    }
    $days = New-Object System.Collections.Generic.List[object]
    foreach ($day in $script:ReportDays) {
        if ($dayErrors.ContainsKey($day)) { $days.Add([ordered]@{ date = $day; alerts = $dayErrors[$day] }); continue }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($b in @($best.Values | Where-Object { $_.Day -eq $day } | Sort-Object -Property @{ Expression = { [string]$_.Row.start } })) {
            $a = $b.Row
            $list.Add([ordered]@{
                start = [string]$a.start; end = [string]$a.end; state = [string]$a.state; name = [string]$a.name; pid = [string]$a.pid
                reason = [string]$a.reason; duration_s = [string]$a.duration_s; peak_cpu_pct = [string]$a.peak_cpu_pct; peak_ram_mb = [string]$a.peak_ram_mb
                peak_core_pct = [string]$a.peak_core_pct
            })
        }
        $days.Add([ordered]@{ date = $day; alerts = $list.ToArray() })
    }
    return [ordered]@{ days = $days.ToArray() }
}

# Measured CPU cost of the watchdog, its sample coverage and its error log, for the
# covered days. A day without any sample after a report was already expected to
# cover it is an error (the watchdog did not run), but the report is still written.
function Get-WatchdogSection {
    $cores = [math]::Max(1, [Environment]::ProcessorCount)
    $days = New-Object System.Collections.Generic.List[object]
    $totCpu = 0.0
    $totElapsed = 0.0
    $wsSum = 0.0
    $wsN = 0
    $firstAll = $null
    $lastAll = $null
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($day in $script:ReportDays) {
        $rows = @()
        $r0 = Get-DayRows $day
        if ($null -ne $r0) { $rows = @($r0) }
        $dayCpu = 0.0
        $dayElapsed = 0.0
        $prevT = $null
        $prevC = $null
        foreach ($r in $rows) {
            $ws = ConvertTo-DoubleOrNull $r.wd_ws_mb
            if ($null -ne $ws) { $wsSum += $ws; $wsN++ }
            $c = ConvertTo-DoubleOrNull $r.wd_cpu_sec
            $t = $null
            try { $t = [datetimeoffset]::ParseExact([string]$r.timestamp, 'yyyy-MM-ddTHH:mm:sszzz', $Inv) } catch { $t = $null }
            if ($null -ne $c -and $null -ne $t) {
                # Only neighbouring samples count; a longer gap is sleep or a
                # stop, when the watchdog was not running or the PC was off.
                if ($null -ne $prevT) {
                    $gap = ($t - $prevT).TotalSeconds
                    if ($gap -ge 1 -and $gap -le (3 * $SampleSeconds)) {
                        $d = $c - $prevC
                        # A lower value means a new process: its CPU time started from 0.
                        if ($d -lt 0) { $d = $c }
                        $dayCpu += $d
                        $dayElapsed += $gap
                    }
                }
                $prevT = $t
                $prevC = $c
            }
        }
        $first = $null
        $last = $null
        if ($rows.Count -gt 0) { $first = [string]$rows[0].timestamp; $last = [string]$rows[$rows.Count - 1].timestamp }
        if ($null -eq $firstAll -and $first) { $firstAll = $first }
        if ($last) { $lastAll = $last }
        $totCpu += $dayCpu
        $totElapsed += $dayElapsed
        if ($rows.Count -eq 0) { $missing.Add($day) }
        $days.Add([ordered]@{ date = $day; samples = $rows.Count; firstSample = $first; lastSample = $last })
    }

    $ownPct = $null
    if ($totElapsed -gt 0) { $ownPct = [math]::Round($totCpu / $totElapsed / $cores * 100, 3) }
    $avgWs = $null
    if ($wsN -gt 0) { $avgWs = [math]::Round($wsSum / $wsN, 1) }

    # Errors in the covered period. Lines start with the date; the token pattern is
    # scrubbed again here in case a message ever carried one.
    $errLines = New-Object System.Collections.Generic.List[string]
    $logProblem = $null
    foreach ($lf in @($WatchLogPath, ($WatchLogPath + '.old'))) {
        try {
            foreach ($ln in (Read-LinesShared $lf)) {
                if ($ln.Length -lt 10 -or $script:ReportDays -notcontains $ln.Substring(0, 10)) { continue }
                if ($ln -notmatch '\sERROR\s') { continue }
                $clean = [regex]::Replace($ln, '(github_pat|gh[pousr])_[A-Za-z0-9_]+', '[redacted]')
                if ($clean.Length -gt 300) { $clean = $clean.Substring(0, 300) }
                $errLines.Add($clean)
            }
        }
        catch {
            $logProblem = "could not read $(Split-Path -Leaf $lf): $($_.Exception.Message)"
            $script:Errors.Add("watchdog: $logProblem")
            Write-Log "Collect: ERROR watchdog $logProblem"
        }
    }
    $sorted = @($errLines.ToArray() | Sort-Object)
    $lastFive = @($sorted | Select-Object -Last 5)

    if ($script:HasMarker -or $DryRun) {
        foreach ($m in $missing) {
            $msg = "watchdog: no samples on $m (the watchdog did not run that day)"
            $script:Errors.Add($msg)
            Write-Log "Collect: ERROR $msg"
        }
    }

    return [ordered]@{
        days                  = $days.ToArray()
        firstSample           = $firstAll
        lastSample            = $lastAll
        daysWithoutSamples    = $missing.ToArray()
        ownCpuPctOfMachine    = $ownPct
        ownAvgWorkingSetMB    = $avgWs
        ownCpuNote            = 'Measured from the watchdog process CPU time between neighbouring samples, as a share of all logical cores. Null when the samples have no such column or the covered days have no usable pairs.'
        logErrorCount         = $errLines.Count
        logLastErrors         = $lastFive
        logReadProblem        = $logProblem
    }
}

# ---------------------------------------------------------------------------
# Collect: Markdown
# ---------------------------------------------------------------------------

function Get-Cell {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return 'n/a' }
    return (("$Value") -replace '[|\r\n]', '/')
}

function New-ReportMarkdown {
    param($S)
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# PCTune report: $($S.computerName)")
    $L.Add('')
    $te = $S['tokenExpiry']
    if ($null -ne $te -and $te['status'] -eq 'EXPIRED') {
        $L.Add('WARNING: ' + (Get-TokenExpiredText ([string]$te['date'])))
        $L.Add('')
    }
    elseif ($null -ne $te -and $te['status'] -eq 'WARN') {
        $L.Add('WARNING: ' + (Get-TokenWarnText ([string]$te['date']) ([int]$te['daysLeft'])))
        $L.Add('')
    }
    elseif ($null -ne $te -and $te['status'] -eq 'UNKNOWN' -and $S['dryRun'] -ne $true) {
        $L.Add('Note: the GitHub token expiry date is not known yet. It is filled in after the next upload.')
        $L.Add('')
    }
    if ($S['dryRun'] -eq $true) {
        $L.Add('DRY RUN - not uploaded')
        $L.Add('')
    }
    $L.Add("Generated $($S.generated). Schema $($S.schemaVersion), PCTune $($S.pctuneVersion).")
    $L.Add('')

    # Headline
    $L.Add('## Headline')
    $L.Add('')
    if (-not (Test-IsError $S.disks)) {
        $sd = @($S.disks | Where-Object { $_.drive -eq $env:SystemDrive }) | Select-Object -First 1
        if ($sd) { $L.Add("- System drive $($sd.drive): $($sd.freeGB) GB free of $($sd.totalGB) GB ($($sd.freePct)% free)") }
    }
    if (-not (Test-IsError $S.ram)) { $L.Add("- RAM now: $($S.ram.now.usedGB) GB used of $($S.ram.now.totalGB) GB ($($S.ram.now.usedPct)%)") }
    if (-not (Test-IsError $S.cpu)) { $L.Add("- CPU now: $(Get-Cell $S.cpu.liveTotalPct)% on $($S.cpu.logicalCores) logical cores") }
    if (-not (Test-IsError $S.system)) {
        $L.Add("- Uptime: $($S.system.uptimeHours) hours, $($S.system.windows) build $($S.system.build)")
        $bat = $S.system.battery
        if (-not (Test-IsError $bat)) {
            if ($bat.present -eq $true) {
                $b1 = @($bat.batteries) | Select-Object -First 1
                if ($b1) { $L.Add("- Battery health: $(Get-Cell $b1.healthPct)% of design capacity, cycles $(Get-Cell $b1.cycleCount)") }
            }
            else { $L.Add('- Battery: no battery') }
        }
    }
    if (-not (Test-IsError $S.updates)) {
        if ($S.updates.status -eq 'ok') { $L.Add("- Pending updates: $($S.updates.count)") }
        else { $L.Add("- Pending updates: not checked ($($S.updates.status): $($S.updates.reason))") }
    }
    $alertCount = 0
    if (-not (Test-IsError $S.watchdogAlerts)) {
        foreach ($ad in @($S.watchdogAlerts['days'])) {
            if (-not (Test-IsError $ad['alerts'])) { $alertCount += @($ad['alerts']).Count }
        }
    }
    $L.Add("- Days covered: $(@($S.reportDays) -join ', ')")
    $L.Add("- Watchdog alerts on those days: $alertCount")
    $L.Add("- Collection errors: $($S.errors.Count)")
    $L.Add('')

    # Drives
    $L.Add('## Drives')
    $L.Add('')
    if (Test-IsError $S.disks) { $L.Add("Unavailable: $($S.disks.error)") }
    else {
        $L.Add('| Drive | Total GB | Used GB | Free GB | Used % | Free % |')
        $L.Add('|---|---|---|---|---|---|')
        foreach ($d in $S.disks) { $L.Add("| $(Get-Cell $d.drive) | $($d.totalGB) | $($d.usedGB) | $($d.freeGB) | $($d.usedPct) | $($d.freePct) |") }
    }
    $L.Add('')
    if (-not (Test-IsError $S.health) -and -not (Test-IsError $S.health.physicalDisks)) {
        $L.Add('Physical disks (n/a means the drive does not report it):')
        $L.Add('')
        foreach ($d in $S.health.physicalDisks) {
            $L.Add("- $(Get-Cell $d.name): $(Get-Cell $d.mediaType), health $(Get-Cell $d.health), wear $(Get-Cell $d.wear), temp $(Get-Cell $d.temperatureC) C, read errors $(Get-Cell $d.readErrorsTotal), write errors $(Get-Cell $d.writeErrorsTotal), power-on hours $(Get-Cell $d.powerOnHours)")
        }
        $L.Add('')
    }

    # RAM and CPU
    $L.Add('## RAM and CPU')
    $L.Add('')
    if ((Test-IsError $S.ram) -or (Test-IsError $S.cpu)) {
        if (Test-IsError $S.ram) { $L.Add("RAM unavailable: $($S.ram.error)") }
        if (Test-IsError $S.cpu) { $L.Add("CPU unavailable: $($S.cpu.error)") }
    }
    else {
        $cpuByDay = @{}
        foreach ($cd in @($S.cpu['days'])) { $cpuByDay[$cd['date']] = $cd['stats'] }
        foreach ($rd in @($S.ram['days'])) {
            $day = $rd['date']
            $r = $rd['stats']
            $c = $cpuByDay[$day]
            if ($r -and -not (Test-IsError $r) -and $r['available'] -eq $true) {
                $L.Add("- $day ($($r['samples']) samples): RAM used at the first sample after logon $(Get-Cell $r['ramFirstSampleAfterLogonUsedMB']) MB, average $(Get-Cell $r['ramAvgUsedMB']) MB, peak $(Get-Cell $r['ramPeakUsedMB']) MB of $(Get-Cell $r['ramTotalMB']) MB")
                if ($c -and -not (Test-IsError $c) -and $c['available'] -eq $true) {
                    $L.Add("  - CPU average $(Get-Cell $c['cpuAvgPct'])%, peak $(Get-Cell $c['cpuPeakPct'])%; per-core average % $(@($c['perCoreAvgPct']) -join ', '); per-core peak % $(@($c['perCorePeakPct']) -join ', ')")
                }
            }
            else { $L.Add("- ${day}: no watchdog samples") }
        }
    }
    $L.Add('')
    $L.Add('The first sample after logon is taken about 5 minutes after logon. That is not guaranteed to be an idle PC.')
    $L.Add('')

    # Alerts
    $L.Add('## Watchdog alerts')
    $L.Add('')
    $L.Add('A process in 3 samples in a row (60 seconds apart, so at least 2 minutes) that is over 80% of total CPU (reason cpu), at 90% or more of one logical core (reason core), or over 1024 MB RAM (reason ram).')
    $L.Add('')
    if (Test-IsError $S.watchdogAlerts) { $L.Add("Unavailable: $($S.watchdogAlerts.error)") }
    elseif ($alertCount -eq 0) { $L.Add('None.') }
    else {
        $L.Add('| Day | Start | End | State | Process | PID | Reason | Seconds | Peak CPU % of total | Peak CPU % of one core | Peak RAM MB |')
        $L.Add('|---|---|---|---|---|---|---|---|---|---|---|')
        foreach ($ad in @($S.watchdogAlerts['days'])) {
            if (Test-IsError $ad['alerts']) { $L.Add("| $($ad['date']) | unavailable: $(Get-Cell $ad['alerts']['error']) | | | | | | | | | |"); continue }
            foreach ($a in @($ad['alerts'])) {
                $L.Add("| $($ad['date']) | $(Get-Cell $a['start']) | $(Get-Cell $a['end']) | $(Get-Cell $a['state']) | $(Get-Cell $a['name']) | $(Get-Cell $a['pid']) | $(Get-Cell $a['reason']) | $(Get-Cell $a['duration_s']) | $(Get-Cell $a['peak_cpu_pct']) | $(Get-Cell $a['peak_core_pct']) | $(Get-Cell $a['peak_ram_mb']) |")
            }
        }
    }
    $L.Add('')

    # Watchdog health
    $L.Add('## Watchdog')
    $L.Add('')
    if (Test-IsError $S.watchdog) { $L.Add("Unavailable: $($S.watchdog.error)") }
    else {
        foreach ($wd in @($S.watchdog['days'])) {
            $L.Add("- $($wd['date']): $($wd['samples']) samples, first $(Get-Cell $wd['firstSample']), last $(Get-Cell $wd['lastSample'])")
        }
        $L.Add("- Watchdog own CPU: $(Get-Cell $S.watchdog['ownCpuPctOfMachine'])% of the whole machine (measured), average working set $(Get-Cell $S.watchdog['ownAvgWorkingSetMB']) MB")
        $L.Add("- Errors in watchdog.log for these days: $($S.watchdog['logErrorCount'])")
        foreach ($el in @($S.watchdog['logLastErrors'])) { $L.Add("  - $(Get-Cell $el)") }
        if (@($S.watchdog['daysWithoutSamples']).Count -gt 0) { $L.Add("- Days with no samples: $(@($S.watchdog['daysWithoutSamples']) -join ', ')") }
    }
    $L.Add('')

    # Top processes
    $L.Add('## Top processes (live reading)')
    $L.Add('')
    if (Test-IsError $S.processes) { $L.Add("Unavailable: $($S.processes.error)") }
    else {
        $procs = @($S.processes)
        $L.Add("$($procs.Count) processes running. Top 10 by CPU:")
        $L.Add('')
        $L.Add('| Process | PID | CPU % of total | CPU % of one core | RAM MB | Path |')
        $L.Add('|---|---|---|---|---|---|')
        # The rows are ordered dictionaries; Sort-Object -Property does not resolve
        # dictionary keys in PS 5.1, so a script block reads the key instead.
        foreach ($p in ($procs | Sort-Object { $_['cpuPct'] } -Descending | Select-Object -First 10)) {
            $L.Add("| $(Get-Cell $p['name']) | $($p['pid']) | $($p['cpuPct']) | $($p['cpuPctOneCore']) | $($p['ramMB']) | $(Get-Cell $p['path']) |")
        }
        $L.Add('')
        $L.Add('Top 10 by RAM:')
        $L.Add('')
        $L.Add('| Process | PID | CPU % of total | CPU % of one core | RAM MB | Path |')
        $L.Add('|---|---|---|---|---|---|')
        foreach ($p in ($procs | Sort-Object { $_['ramMB'] } -Descending | Select-Object -First 10)) {
            $L.Add("| $(Get-Cell $p['name']) | $($p['pid']) | $($p['cpuPct']) | $($p['cpuPctOneCore']) | $($p['ramMB']) | $(Get-Cell $p['path']) |")
        }
    }
    $L.Add('')

    # Old drivers
    $L.Add('## Old drivers (older than 2 years)')
    $L.Add('')
    if (Test-IsError $S.drivers) { $L.Add("Unavailable: $($S.drivers.error)") }
    else {
        $old = @($S.drivers | Where-Object { $_.old -eq $true })
        if ($old.Count -eq 0) { $L.Add('None found. Inbox Microsoft drivers are not judged by date (their date is a placeholder).') }
        else {
            $L.Add('| Device | Class | Provider | Version | Date |')
            $L.Add('|---|---|---|---|---|')
            foreach ($d in $old) { $L.Add("| $(Get-Cell $d.device) | $(Get-Cell $d.class) | $(Get-Cell $d.provider) | $(Get-Cell $d.version) | $(Get-Cell $d.date) |") }
        }
    }
    $L.Add('')

    # Updates
    $L.Add('## Pending updates')
    $L.Add('')
    if (Test-IsError $S.updates) { $L.Add("Unavailable: $($S.updates.error)") }
    elseif ($S.updates.status -ne 'ok') { $L.Add("Not checked: $($S.updates.status). $($S.updates.reason)") }
    elseif ($S.updates.count -eq 0) { $L.Add('None pending.') }
    else {
        $L.Add('| Title | Type | KB | Optional | Size MB |')
        $L.Add('|---|---|---|---|---|')
        foreach ($u in $S.updates.updates) { $L.Add("| $(Get-Cell $u.title) | $($u.type) | $(Get-Cell (@($u.kbs) -join ', ')) | $(Get-Cell $u.optional) | $($u.sizeMB) |") }
    }
    $L.Add('')

    # Battery
    $L.Add('## Battery')
    $L.Add('')
    if (Test-IsError $S.system) { $L.Add("Unavailable: $($S.system.error)") }
    elseif (Test-IsError $S.system.battery) { $L.Add("Unavailable: $($S.system.battery.error)") }
    elseif ($S.system.battery.present -ne $true) { $L.Add('No battery.') }
    else {
        foreach ($b in @($S.system.battery.batteries)) {
            $L.Add("- Design $(Get-Cell $b.designCapacityMWh) mWh, full charge $(Get-Cell $b.fullChargeCapacityMWh) mWh, health $(Get-Cell $b.healthPct)%, cycles $(Get-Cell $b.cycleCount) (0 can mean not reported)")
        }
    }
    $L.Add('')

    # Errors
    $L.Add('## Event errors (last 7 days)')
    $L.Add('')
    if (Test-IsError $S.health) { $L.Add("Unavailable: $($S.health.error)") }
    else {
        foreach ($pair in @(@('systemLog7d', 'System log warnings/errors (power, disk, NTFS, storage)'), @('appCrashesAndHangs7d', 'Application crashes and hangs'))) {
            $v = $S.health[$pair[0]]
            if (Test-IsError $v) { $L.Add("- $($pair[1]): unavailable ($($v.error))") }
            else { $L.Add("- $($pair[1]): $($v.total) (newest $($v.shown) kept in the JSON)") }
        }
        if (-not (Test-IsError $S.health.boots)) {
            foreach ($b in @($S.health.boots)) { $L.Add("- Boot $($b.time): total $(Get-Cell $b.bootTimeSec) s, main path $(Get-Cell $b.mainPathBootTimeSec) s, post boot $(Get-Cell $b.postBootTimeSec) s") }
        }
    }
    $L.Add('')

    # Startup
    $L.Add('## Startup apps')
    $L.Add('')
    if (Test-IsError $S.startup) { $L.Add("Unavailable: $($S.startup.error)") }
    else {
        foreach ($e in @($S.startup.runKeys)) { $L.Add("- Registry $($e.scope) $($e.kind): $(Get-Cell $e.name) -> $(Get-Cell $e.program)") }
        foreach ($e in @($S.startup.startupFolders)) { $L.Add("- Startup folder ($($e.scope)): $(Get-Cell $e.file)") }
        foreach ($e in @($S.startup.scheduledTasks)) { $L.Add("- Task $(Get-Cell $e.path)$(Get-Cell $e.name) ($($e.triggers)) -> $(Get-Cell $e.program)") }
        $L.Add("- Microsoft logon/boot tasks (count only): $($S.startup.microsoftLogonBootTaskCount)")
    }
    $L.Add('')

    if ($S.errors.Count -gt 0) {
        $L.Add('## Collection errors')
        $L.Add('')
        foreach ($e in $S.errors) { $L.Add("- $(Get-Cell $e)") }
        $L.Add('')
    }
    $L.Add('Full detail (all processes, installed programs, every driver, event lists) is in the JSON file with the same name.')
    return ($L -join "`r`n") + "`r`n"
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------

function Invoke-Collect {
    if ($DryRun) {
        New-DryRunDirs
        Write-Log "DRYRUN: Collect reads $SamplesDir and writes the report to $DryReportsDir. Nothing is written to $TelDir."
    }
    else {
        foreach ($d in @($SamplesDir, $OutboxDir)) {
            if (-not (Test-Path -LiteralPath $d -PathType Container)) {
                # Creating it here would give it the parent's ACL (Users can read).
                Write-Log "Collect: $d not found. Run the Protect action first."
                $script:Code = 2
                return
            }
        }
    }
    # Fixed culture so ConvertTo-Json and number text never use a local decimal comma.
    [Threading.Thread]::CurrentThread.CurrentCulture = $Inv

    # Which full days still need reporting. Nothing to do is exit 2, before any of
    # the slow live queries run.
    Initialize-ReportDays
    if ($script:ReportDays.Count -eq 0) {
        Write-Log "Collect: already reported (last reported day $($script:LastReportedDay), nothing new before today)"
        $script:Code = 2
        return
    }
    Write-Log "Collect: reporting $($script:ReportDays.Count) day(s): $($script:ReportDays[0]) to $($script:ReportDays[$script:ReportDays.Count - 1])"
    $script:RowCache = @{}

    $script:Errors = New-Object System.Collections.Generic.List[string]
    # tokenExpiry comes from token_status.txt (see Read-TokenStatusState); status is
    # UNKNOWN when that file is missing or unreadable.
    $tokenState = Read-TokenStatusState
    if ($null -eq $tokenState) { $tokenExpiry = [ordered]@{ date = $null; daysLeft = $null; status = 'UNKNOWN' } }
    else { $tokenExpiry = [ordered]@{ date = $tokenState.Date; daysLeft = $tokenState.DaysLeft; status = $tokenState.Status } }
    if ($tokenExpiry['status'] -eq 'WARN') { Write-Log ('Collect: WARNING: ' + (Get-TokenWarnText ([string]$tokenExpiry['date']) ([int]$tokenExpiry['daysLeft']))) }
    elseif ($tokenExpiry['status'] -eq 'EXPIRED') { Write-Log ('Collect: WARNING: ' + (Get-TokenExpiredText ([string]$tokenExpiry['date']))) }
    elseif (Test-ItemExists $TokenFile) { Write-Log 'Collect: Token status: expiry unknown (token_status.txt missing or unreadable). It is written by the next upload.' }

    $script:Snap = [ordered]@{ schemaVersion = 4 }
    if ($DryRun) { $script:Snap['dryRun'] = $true }
    $script:Snap['generated']     = Get-Stamp (Get-Date)
    $script:Snap['computerName']  = $ComputerName
    $script:Snap['pctuneVersion'] = $PCTuneVersion
    $script:Snap['reportDays']    = $script:ReportDays
    $script:Snap['tokenExpiry']   = $tokenExpiry

    Invoke-Section 'disks'          { Get-DisksSection }
    Invoke-Section 'ram'            { Get-RamSection }
    Invoke-Section 'cpu'            { Get-CpuSection }
    Invoke-Section 'processes'      { Get-ProcessesSection }
    Invoke-Section 'startup'        { Get-StartupSection }
    Invoke-Section 'programs'       { Get-ProgramsSection }
    Invoke-Section 'drivers'        { Get-DriversSection }
    Invoke-Section 'updates'        { Get-UpdatesSection }
    Invoke-Section 'health'         { Get-HealthSection }
    Invoke-Section 'system'         { Get-SystemSection }
    Invoke-Section 'watchdogAlerts' { Get-AlertsSection }
    Invoke-Section 'watchdog'       { Get-WatchdogSection }
    $script:Snap['errors'] = $script:Errors.ToArray()

    $base = '{0}_{1}' -f (Get-DateText (Get-Date)), $ComputerName
    if ($DryRun) { $outDir = $DryReportsDir } else { $outDir = $OutboxDir }
    $jsonPath = Join-Path $outDir ($base + '.json')
    $mdPath = Join-Path $outDir ($base + '.md')
    $enc = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = $script:Snap | ConvertTo-Json -Depth 8
        $md = New-ReportMarkdown $script:Snap
        # Write under a temp name and rename, so Upload never sees half a file.
        foreach ($pair in @(@($jsonPath, $json), @($mdPath, $md))) {
            $tmp = $pair[0] + '.tmp'
            [IO.File]::WriteAllText($tmp, $pair[1], $enc)
            Move-Item -LiteralPath $tmp -Destination $pair[0] -Force
        }
    }
    catch {
        Write-Log "Collect: could not write the report files: $($_.Exception.Message)"
        $script:Code = 1
        return
    }
    if ($DryRun) {
        Write-Log "DRYRUN: wrote $jsonPath and $mdPath (not uploaded)"
        Write-Log 'DRYRUN: would update last_reported_day.txt and delete old unsent files from the outbox (skipped)'
        if ($script:Errors.Count -gt 0) {
            Write-Log "Collect: $($script:Errors.Count) section(s) had errors, see the errors list in the JSON"
            $script:Code = 1
        }
        else { $script:Code = 0 }
        return
    }
    Write-Log "Collect: wrote $jsonPath and $mdPath"

    # Advance the marker only now that both files are in the outbox. If this
    # fails, the same days are reported again next time (a duplicate, not a gap).
    try {
        $lastDay = $script:ReportDays[$script:ReportDays.Count - 1]
        [IO.File]::WriteAllText($MarkerFile, $lastDay + "`r`n", $enc)
        Write-Log "Collect: last reported day is now $lastDay"
    }
    catch {
        Write-Log "Collect: could not write last_reported_day.txt: $($_.Exception.Message)"
        $script:Code = 1
        return
    }

    try {
        $n = Remove-OldFiles -Dir $OutboxDir -Days $KeepDays -ByNameDate
        if ($n -gt 0) { Write-Log "Collect: deleted $n UNSENT report file(s) older than $KeepDays days" }
    }
    catch { Write-Log "Collect: prune failed: $($_.Exception.Message)" }

    if ($script:Errors.Count -gt 0) {
        Write-Log "Collect: $($script:Errors.Count) section(s) had errors, see the errors list in the JSON"
        $script:Code = 1
    }
    else { $script:Code = 0 }
}

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

# Stop codes: a failure that will not fix itself is 1, "try again later" is 2.
# How a failed connection (no HTTP answer) is judged. Certificate, trust and
# proxy-name problems need a person (1). Plain network trouble (DNS, connect,
# timeout, and anything not listed) is expected to pass, so it is deferred (2).
function Get-NetStopCode {
    param([string]$NetError)
    if (@('SecureChannelFailure', 'TrustFailure', 'ProxyNameResolutionFailure') -contains $NetError) { return 1 }
    return 2
}

# Repo check: reachable, and visibility exactly private. Result goes to
# $script:RepoCheck (0 ok, 1 stop and fail, 2 stop and defer), not to the
# pipeline, because Write-Log may print there.
function Test-UploadRepo {
    param([string]$Api, [string]$Token, [string]$Repo)
    $script:RepoCheck = 1
    $r = Invoke-GitHub -Method 'GET' -Uri $Api -Token $Token
    if ($r.Status -eq 0) {
        $script:RepoCheck = Get-NetStopCode $r.NetError
        Write-Log "Upload: no connection to GitHub ($($r.NetError)). Files kept."
        return
    }
    if (Test-RateLimited $r) {
        $script:RepoCheck = 2
        Write-Log "Upload: GitHub rate limit reached ($(Get-HttpText $r)). Files kept, deferred to the next run."
        return
    }
    if ($r.Status -eq 401 -and (Test-ExpiredAt401 $r)) { return }
    if ($r.Status -eq 401 -or $r.Status -eq 403 -or $r.Status -eq 404) {
        Write-Log "Upload: GitHub refused the repo check ($(Get-HttpText $r)). The token may have expired, the repo name may be wrong, or the token lacks Contents permission. Files kept."
        return
    }
    if ($r.Status -ge 500) {
        $script:RepoCheck = 2
        Write-Log "Upload: GitHub error ($(Get-HttpText $r)). Files kept, will retry next run."
        return
    }
    if ($r.Status -ne 200) {
        Write-Log "Upload: unexpected answer to the repo check ($(Get-HttpText $r)). Files kept."
        return
    }
    $priv = Get-RepoPrivacy $r
    if ($priv -eq 'unreadable') {
        $script:RepoCheck = 2
        Write-Log 'Upload: GitHub reply could not be read, so repo privacy is unknown. Nothing sent, files kept.'
        return
    }
    if ($priv -ne 'private') {
        Write-Log "Upload: REFUSED. The repo $Repo is not private (visibility must be exactly private). Nothing more was uploaded and the files were kept. Fix the repo or run Forget."
        return
    }
    $script:RepoCheck = 0
}

# Before any network call: false (after logging the failure) when token_status.txt
# says the expiry date has passed. Within 14 days of it, a warning is logged once.
function Test-UploadExpiryGate {
    $known = Read-TokenStatusState
    $script:KnownExpiry = $known
    if ($null -eq $known) { return $true }
    if ($known.Status -eq 'EXPIRED') {
        Write-Log ('FAIL: ' + (Get-TokenExpiredText $known.Date))
        return $false
    }
    if ($known.Status -eq 'WARN') { Write-ExpiryWarningOnce $known.Date $known.DaysLeft }
    return $true
}

# After the first good GitHub reply: warns about an expiry that only the live header
# showed (no status file yet, for example after an update of this script).
function Write-LiveExpiryWarning {
    if ($null -eq $script:TokenExpiryDate) { return }
    $live = Get-TokenExpiryState -ExpiryDate $script:TokenExpiryDate -Today ([datetime]::UtcNow) -WarnDays $TokenWarnDays
    if ($live.Status -eq 'WARN') { Write-ExpiryWarningOnce $live.Date $live.DaysLeft }
}

# Dry run of Upload: the same read-only checks as the real run (token status file,
# repo privacy GET), but nothing is sent and no outbox file is changed. The files
# that would go are the outbox plus DryRun\reports.
function Invoke-UploadDry {
    $files = @()
    foreach ($dir in @($OutboxDir, $DryReportsDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $files += @(Get-ChildItem -LiteralPath $dir -File -Force |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_.+\.(json|md)$' -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
            Sort-Object -Property LastWriteTime, Name)
    }
    # The expiry gate runs first, so an expired token is reported even with nothing to send.
    if ((Test-ItemExists $TokenFile) -and -not (Test-UploadExpiryGate)) { $script:Code = 1; return }
    if ($files.Count -eq 0) {
        Write-Log 'DRYRUN: nothing in the outbox or in DryRun\reports, nothing to upload'
        $script:Code = 2
        return
    }
    if (-not (Test-ItemExists $TokenFile) -or -not (Test-ItemExists $RepoFile)) {
        Write-Log "DRYRUN: no token stored; would upload $($files.Count) file(s)"
        $script:Code = 2
        return
    }
    $repo = ([IO.File]::ReadAllText($RepoFile)).Trim()
    if ($repo -notmatch $RepoPattern) { throw 'repo.txt does not contain a valid owner/repo' }

    Initialize-Tls
    try { $token = Get-StoredToken }
    catch {
        Write-Log "DRYRUN: the stored token could not be read ($($_.Exception.Message)). The real run would stop here."
        $script:Code = 1
        return
    }
    Test-UploadRepo -Api "https://api.github.com/repos/$repo" -Token $token -Repo $repo
    if ($script:RepoCheck -ne 0) { $script:Code = $script:RepoCheck; return }
    Write-LiveExpiryWarning

    foreach ($f in $files) { Write-Log "DRYRUN: would upload $($f.FullName)" }
    Write-Log "DRYRUN: $($files.Count) file(s) would be uploaded to $repo. Nothing was sent and no file was removed."
    $script:Code = 0
}

# A report that has waited more than 2 days turns "deferred" (2) into a failure
# (1), so the caller shows it instead of retrying quietly forever.
function Invoke-Upload {
    # The status file is written even when an exception ends the run, as long as
    # GitHub answered at least once.
    try {
        if ($DryRun) { Invoke-UploadDry } else { Invoke-UploadCore }
    }
    finally { Save-TokenStatusFromRun 'Upload' }
    if ($DryRun) { return }
    if ($script:Code -ne 2) { return }
    if (-not (Test-Path -LiteralPath $OutboxDir -PathType Container)) { return }
    $oldest = Get-ChildItem -LiteralPath $OutboxDir -File -Force |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_.+\.(json|md)$' } |
        Sort-Object -Property LastWriteTime | Select-Object -First 1
    if ($oldest -and ((Get-Date) - $oldest.LastWriteTime).TotalDays -gt 2) {
        Write-Log "Upload: the oldest unsent report ($($oldest.Name)) is more than 2 days old, reporting failure"
        $script:Code = 1
    }
}

function Invoke-UploadCore {
    $files = @()
    if (Test-Path -LiteralPath $OutboxDir -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $OutboxDir -File -Force |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_.+\.(json|md)$' -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
            Sort-Object -Property LastWriteTime, Name)
    }
    # Known expired: stop here, before the token is even decrypted, and before the
    # empty-outbox return so an expired token is never reported as "nothing to do".
    if ((Test-ItemExists $TokenFile) -and -not (Test-UploadExpiryGate)) { $script:Code = 1; return }
    if ($files.Count -eq 0) {
        Write-Log 'Upload: nothing in the outbox'
        [void](Remove-OldFiles -Dir $OutboxDir -Days $KeepDays -ByNameDate)
        $script:Code = 2
        return
    }
    if (-not (Test-ItemExists $TokenFile) -or -not (Test-ItemExists $RepoFile)) {
        Write-Log 'Upload: telemetry is not set up (token.dat or repo.txt missing)'
        $script:Code = 2
        return
    }
    $repo = ([IO.File]::ReadAllText($RepoFile)).Trim()
    if ($repo -notmatch $RepoPattern) { throw 'repo.txt does not contain a valid owner/repo' }

    Initialize-Tls
    $token = Get-StoredToken
    $api = "https://api.github.com/repos/$repo"

    # Before the first file, and again every 5 files (see the loop).
    Test-UploadRepo -Api $api -Token $token -Repo $repo
    if ($script:RepoCheck -ne 0) { $script:Code = $script:RepoCheck; return }
    Write-LiveExpiryWarning

    $sent = 0
    $failed = 0
    $stopCode = 0
    $idx = 0
    foreach ($f in $files) {
        if ($idx -gt 0 -and ($idx % 5) -eq 0) {
            Test-UploadRepo -Api $api -Token $token -Repo $repo
            if ($script:RepoCheck -ne 0) { $stopCode = $script:RepoCheck; break }
        }
        $idx++
        $enc = [Uri]::EscapeDataString($f.Name)
        $uri = "$api/contents/reports/$enc"
        if ($f.Length -gt 50MB) {
            Write-Log "Upload: $($f.Name) is larger than 50 MB, skipped"
            $failed++
            continue
        }

        $g = Invoke-GitHub -Method 'GET' -Uri $uri -Token $token
        $sha = $null
        if ($g.Status -eq 200) {
            $sm = [regex]::Match($g.Body, '"sha"\s*:\s*"([0-9a-f]{40})"')
            if ($sm.Success) { $sha = $sm.Groups[1].Value }
        }
        elseif ($g.Status -eq 0) { $stopCode = Get-NetStopCode $g.NetError; Write-Log "Upload: lost the connection ($($g.NetError)). Remaining files kept."; break }
        elseif (Test-RateLimited $g) { $stopCode = 2; Write-Log "Upload: GitHub rate limit reached ($(Get-HttpText $g)). Remaining files kept, deferred to the next run."; break }
        elseif ($g.Status -eq 401 -and (Test-ExpiredAt401 $g)) { $stopCode = 1; break }
        elseif ($g.Status -eq 401 -or $g.Status -eq 403) { $stopCode = 1; Write-Log "Upload: GitHub refused access ($(Get-HttpText $g)). Check the token and its Contents permission."; break }
        elseif ($g.Status -ge 500) { $stopCode = 2; Write-Log "Upload: GitHub error ($(Get-HttpText $g)). Remaining files kept, will retry next run."; break }
        elseif ($g.Status -ne 404) { Write-Log "Upload: lookup of $($f.Name) failed ($(Get-HttpText $g))"; $failed++; continue }

        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
        $msgJson = ConvertTo-Json -InputObject ("PCTune report " + $f.Name) -Compress
        $body = '{"message":' + $msgJson + ',"content":"' + $b64 + '"'
        if ($sha) { $body += ',"sha":"' + $sha + '"' }
        $body += '}'

        $p = Invoke-GitHub -Method 'PUT' -Uri $uri -Token $token -Body $body
        if ($p.Status -eq 200 -or $p.Status -eq 201) {
            Remove-Item -LiteralPath $f.FullName -Force
            Write-Log "Upload: sent $($f.Name)"
            $sent++
        }
        elseif ($p.Status -eq 0) { $stopCode = Get-NetStopCode $p.NetError; Write-Log "Upload: lost the connection ($($p.NetError)). Remaining files kept."; break }
        elseif (Test-RateLimited $p) { $stopCode = 2; Write-Log "Upload: GitHub rate limit reached ($(Get-HttpText $p)). Remaining files kept, deferred to the next run."; break }
        elseif ($p.Status -eq 401 -and (Test-ExpiredAt401 $p)) { $stopCode = 1; break }
        elseif ($p.Status -eq 401 -or $p.Status -eq 403) { $stopCode = 1; Write-Log "Upload: GitHub refused the write ($(Get-HttpText $p)). Check the token and its Contents permission."; break }
        elseif ($p.Status -ge 500) { $stopCode = 2; Write-Log "Upload: GitHub error ($(Get-HttpText $p)). Remaining files kept, will retry next run."; break }
        else { Write-Log "Upload: $($f.Name) failed ($(Get-HttpText $p)). File kept."; $failed++ }
    }

    # Everything left in the outbox is unsent, so deleting old files is data loss
    # and must be loud: log it and fail the run.
    $lost = 0
    try { $lost = Remove-OldFiles -Dir $OutboxDir -Days $KeepDays -ByNameDate }
    catch { Write-Log "Upload: prune failed: $($_.Exception.Message)" }
    if ($lost -gt 0) { Write-Log "Upload: deleted $lost UNSENT report file(s) older than $KeepDays days" }

    Write-Log "Upload: $sent sent, $failed failed"
    if ($stopCode -eq 1 -or $failed -gt 0 -or $lost -gt 0) { $script:Code = 1 }
    elseif ($stopCode -eq 2) { $script:Code = 2 }
    else { $script:Code = 0 }
}

# ---------------------------------------------------------------------------
# Dispatcher: one try/catch around every action
# ---------------------------------------------------------------------------
try {
    switch ($Action) {
        'Protect'        { Invoke-Protect;        exit $script:Code }
        'CheckPrivate'   { Invoke-CheckPrivate;   exit $script:Code }
        'Setup'          { Invoke-Setup;          exit $script:Code }
        'Forget'         { Invoke-Forget;         exit $script:Code }
        'EnsureWatchdog' { Invoke-EnsureWatchdog; exit $script:Code }
        'RemoveWatchdog' { Invoke-RemoveWatchdog; exit $script:Code }
        'Watchdog'       { Invoke-Watchdog;       exit $script:Code }
        'Collect'        { Invoke-Collect;        exit $script:Code }
        'Upload'         { Invoke-Upload;         exit $script:Code }
    }
}
catch {
    # Log the failure; also print it so the calling .bat can see it even without a log file.
    $msg = "ERROR in action ${Action}: $($_.Exception.Message)"
    # The watchdog has no console and runs for days, so its failure goes into
    # watchdog.log (with console fallback) as well, where Collect will find it.
    if ($Action -eq 'Watchdog') { Write-WatchError $msg } else { Write-Log $msg }
    if (-not [string]::IsNullOrEmpty($LogFile)) { Write-Output $msg }
    exit 1
}
