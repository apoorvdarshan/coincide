param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\build\x64\Release\Coincide.exe'),
    [string]$Results = (Join-Path $PSScriptRoot '..\build\hosted-recovery-smoke'),
    [switch]$RunInteractive,
    [string]$PreparedHostedData,
    [switch]$KeepData
)
# Requires an explicitly reserved interactive desktop and a completed fixture-enabled app build.
# This script never sends pipe commands, invokes a real provider, or uses owner app data.
# Only its exact owned UI is killed during the crash step. Successful host shutdown must be
# observed after the app's explicit Quit; failure cleanup cannot turn a failure into a pass.
$ErrorActionPreference = 'Stop'
if (!$RunInteractive -or $env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) {
    throw 'Hosted recovery smoke requires -RunInteractive in a reserved Windows desktop session.'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class HostedRecoveryNative {
    [StructLayout(LayoutKind.Sequential)] private struct Info {
        public uint attributes; public System.Runtime.InteropServices.ComTypes.FILETIME created,accessed,written;
        public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern SafeFileHandle CreateFile(string p,uint a,uint s,IntPtr x,uint c,uint f,IntPtr t);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder p,uint s,uint f);
    [DllImport("shell32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr CommandLineToArgvW(string p,out int n);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern SafeFileHandle OpenProcess(uint access,bool inherit,uint id);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetProcessTimes(SafeFileHandle h,out System.Runtime.InteropServices.ComTypes.FILETIME created,out System.Runtime.InteropServices.ComTypes.FILETIME exited,out System.Runtime.InteropServices.ComTypes.FILETIME kernel,out System.Runtime.InteropServices.ComTypes.FILETIME user);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool QueryFullProcessImageName(SafeFileHandle h,uint flags,StringBuilder path,ref uint size);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool TerminateProcess(SafeFileHandle h,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern uint WaitForSingleObject(SafeFileHandle h,uint wait);
    public static void KillExact(uint id,long expectedTicks,string expectedImage) {
        // Open once, then verify and terminate that same kernel process object. A PID
        // reuse between CIM inspection and this open cannot authorize another process.
        using(var h=OpenProcess(0x00101001,false,id)) {
            System.Runtime.InteropServices.ComTypes.FILETIME a,b,c,d;
            if(h.IsInvalid||!GetProcessTimes(h,out a,out b,out c,out d))throw new InvalidOperationException("Owned process identity could not be pinned");
            long filetime=((long)(uint)a.dwHighDateTime<<32)|(uint)a.dwLowDateTime;
            if(Math.Abs(DateTime.FromFileTimeUtc(filetime).Ticks-expectedTicks)>10)throw new InvalidOperationException("Owned process creation identity changed");
            var path=new StringBuilder(32768);uint count=(uint)path.Capacity;
            if(!QueryFullProcessImageName(h,0,path,ref count)||FileIdentity(path.ToString())!=expectedImage)throw new InvalidOperationException("Owned process image identity changed");
            if(!TerminateProcess(h,99)||WaitForSingleObject(h,10000)!=0)throw new InvalidOperationException("The exact owned process did not terminate");
        }
    }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public static string PhysicalDirectory(string path) {
        using(var h=CreateFile(path,0x80,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
            Info i;if(h.IsInvalid||!GetFileInformationByHandle(h,out i)||(i.attributes&0x10)==0)throw new InvalidOperationException("Owned TEMP directory identity is unavailable");
            var text=new StringBuilder(32768);uint n=GetFinalPathNameByHandle(h,text,(uint)text.Capacity,0);
            if(n==0||n>=text.Capacity)throw new InvalidOperationException("Owned TEMP directory path is unavailable");
            var result=text.ToString();return result.StartsWith(@"\\?\")?result.Substring(4):result;
        }
    }
    public static string FileIdentity(string path) {
        using(var h=CreateFile(path,0x80,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
            Info i;if(h.IsInvalid||!GetFileInformationByHandle(h,out i)||(i.attributes&(0x10|0x400))!=0||i.links!=1)throw new InvalidOperationException("The exact ordinary fixture image is unavailable");
            return i.volume.ToString("x8")+":"+i.indexHigh.ToString("x8")+i.indexLow.ToString("x8");
        }
    }
    public static SafeFileHandle PinImage(string path) {
        var h=CreateFile(path,0x81,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);Info i;
        if(h.IsInvalid||!GetFileInformationByHandle(h,out i)||(i.attributes&(0x10|0x400))!=0||i.links!=1){h.Dispose();throw new InvalidOperationException("Could not pin the fixture image");}return h;
    }

    [StructLayout(LayoutKind.Sequential)] private struct AclSizeInfo { public uint count,used,free; }
    [DllImport("advapi32.dll")] private static extern uint GetSecurityInfo(SafeFileHandle handle,uint type,uint requested,out IntPtr owner,out IntPtr group,out IntPtr dacl,out IntPtr sacl,out IntPtr descriptor);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool GetAclInformation(IntPtr acl,out AclSizeInfo info,uint size,uint kind);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool GetAce(IntPtr acl,uint index,out IntPtr ace);
    [DllImport("advapi32.dll")] private static extern bool IsValidAcl(IntPtr acl);
    [DllImport("advapi32.dll")] private static extern bool IsValidSid(IntPtr sid);
    private static void RequirePrivatePreparedAcl(SafeFileHandle handle) {
        IntPtr owner,group,dacl,sacl,descriptor;
        var status=GetSecurityInfo(handle,1,5,out owner,out group,out dacl,out sacl,out descriptor);
        try {
            if(status!=0||descriptor==IntPtr.Zero||owner==IntPtr.Zero||dacl==IntPtr.Zero||!IsValidSid(owner)||!IsValidAcl(dacl))
                throw new InvalidOperationException("Prepared host metadata has an unavailable or invalid private ACL");
            var current=System.Security.Principal.WindowsIdentity.GetCurrent().User;
            AclSizeInfo info;IntPtr ace;
            if(current==null||!current.Equals(new System.Security.Principal.SecurityIdentifier(owner))||
                !GetAclInformation(dacl,out info,(uint)Marshal.SizeOf(typeof(AclSizeInfo)),2)||info.count!=1||
                info.used<24||info.used>(uint)(ushort)Marshal.ReadInt16(dacl,2)||!GetAce(dacl,0,out ace)||ace==IntPtr.Zero)
                throw new InvalidOperationException("Prepared host metadata is not private to the current user");
            var offset=ace.ToInt64()-dacl.ToInt64();
            if(offset<8||offset>info.used-16||Marshal.ReadByte(ace)!=0||(Marshal.ReadByte(ace,1)&0x10)!=0)
                throw new InvalidOperationException("Prepared host metadata requires one explicit current-user Allow ACE");
            var size=(uint)(ushort)Marshal.ReadInt16(ace,2);
            if(size<16||size>info.used-offset)
                throw new InvalidOperationException("Prepared host metadata contains a malformed ACE");
            var sid=IntPtr.Add(ace,8);var sidSize=8+4*(uint)Marshal.ReadByte(sid,1);
            if(Marshal.ReadByte(sid)!=1||sidSize!=size-8||!IsValidSid(sid)||!current.Equals(new System.Security.Principal.SecurityIdentifier(sid)))
                throw new InvalidOperationException("Prepared host metadata is not private to the current user");
        }finally{if(descriptor!=IntPtr.Zero)LocalFree(descriptor);}
    }

    private static SafeFileHandle PinPreparedEntry(string path,bool directory,uint share,long maximum,bool readControl=false) {
        var handle=CreateFile(path,directory?(0x81u|(readControl?0x20000u:0u)):0x80000080u,share,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        Info info;
        if(handle.IsInvalid||!GetFileInformationByHandle(handle,out info)||(info.attributes&0x400)!=0||((info.attributes&0x10)!=0)!=directory||(!directory&&(info.links!=1||(((ulong)info.sizeHigh<<32)|info.sizeLow)>(ulong)maximum))) {
            handle.Dispose();throw new InvalidOperationException("Prepared hosted data contains an unavailable, linked or oversized entry");
        }
        return handle;
    }
    public static SafeFileHandle[] PinPreparedHostedData(string supplied) {
        var pins=new System.Collections.Generic.List<SafeFileHandle>();
        try {
            var requested=System.IO.Path.GetFullPath(supplied).TrimEnd('\\');
            var temporary=PhysicalDirectory(System.IO.Path.GetTempPath()).TrimEnd('\\');
            var leaf=System.IO.Path.GetFileName(requested);Guid suffix;
            const string prefix="Coincide-Host-Connection-";
            if(!leaf.StartsWith(prefix,StringComparison.Ordinal)||!Guid.TryParseExact(leaf.Substring(prefix.Length),"D",out suffix)||
                !String.Equals(System.IO.Path.GetDirectoryName(requested),temporary,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Prepared hosted data must be one physical TEMP child with a fresh fixture GUID name");
            pins.Add(PinPreparedEntry(requested,true,3,0));
            if(!String.Equals(PhysicalDirectory(requested),requested,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Prepared hosted data cannot resolve through an alias or reparse point");
            var count=0;
            foreach(var entry in System.IO.Directory.EnumerateFileSystemEntries(requested)) {
                if(++count>2)throw new InvalidOperationException("Prepared hosted data is not an empty owned fixture");
                var name=System.IO.Path.GetFileName(entry);
                if(!String.Equals(name,"synthetic-connection-fixture.txt",StringComparison.OrdinalIgnoreCase)&&!String.Equals(name,"agent-host-windows",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Prepared hosted data contains workspace, client or unknown files");
            }
            if(count!=2)throw new InvalidOperationException("Prepared hosted data requires its exact marker and empty private host folder");
            var marker=System.IO.Path.Combine(requested,"synthetic-connection-fixture.txt");
            var markerPin=PinPreparedEntry(marker,false,1,128);pins.Add(markerPin);
            var expected=System.Text.Encoding.ASCII.GetBytes("COINCIDE_SYNTHETIC_HOST_CONNECTION\n");
            using(var copy=new SafeFileHandle(markerPin.DangerousGetHandle(),false))using(var stream=new System.IO.FileStream(copy,System.IO.FileAccess.Read)) {
                if(stream.Length!=expected.Length)throw new InvalidOperationException("Prepared hosted marker is invalid");
                for(var i=0;i<expected.Length;++i)if(stream.ReadByte()!=expected[i])throw new InvalidOperationException("Prepared hosted marker is invalid");
            }
            var ledger=System.IO.Path.Combine(requested,"agent-host-windows");var ledgerPin=PinPreparedEntry(ledger,true,3,0,true);pins.Add(ledgerPin);
            RequirePrivatePreparedAcl(ledgerPin);
            count=0;var foundLock=false;
            foreach(var entry in System.IO.Directory.EnumerateFileSystemEntries(ledger)) {
                if(++count>2)throw new InvalidOperationException("Prepared private host folder has unknown files");
                var name=System.IO.Path.GetFileName(entry);
                if(String.Equals(name,"host.lock",StringComparison.OrdinalIgnoreCase)){pins.Add(PinPreparedEntry(entry,false,3,4096));foundLock=true;}
                else if(String.Equals(name,"runtime.json",StringComparison.OrdinalIgnoreCase)){using(var pin=PinPreparedEntry(entry,false,7,16384)) {}}
                else throw new InvalidOperationException("Prepared private host folder has unknown files");
            }
            if(!foundLock)throw new InvalidOperationException("Prepared host has no ownership metadata");
            return pins.ToArray();
        }catch{foreach(var pin in pins)pin.Dispose();throw;}
    }

    public static string[] Arguments(string command) {
        int n;var memory=CommandLineToArgvW(command,out n);if(memory==IntPtr.Zero)throw new InvalidOperationException("Could not inspect owned process arguments");
        try{var result=new string[n];for(int i=0;i<n;++i)result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));return result;}finally{LocalFree(memory);}
    }
}
'@
function Assert-PreparedHostedHost([string]$Directory) {
    function Read-PreparedMetadata([string]$Path,[long]$Limit) {
        $stream=New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if($stream.Length -le 0 -or $stream.Length -gt $Limit){throw 'Prepared host metadata exceeds its empty-state bound.'}
            $encoding=New-Object Text.UTF8Encoding($false,$true)
            $reader=New-Object IO.StreamReader($stream,$encoding,$false)
            try{return ($reader.ReadToEnd()|ConvertFrom-Json)}finally{$reader.Dispose()}
        }finally{$stream.Dispose()}
    }
    $owner=Read-PreparedMetadata (Join-Path $Directory 'agent-host-windows\host.lock') 4096
    if($owner -isnot [pscustomobject] -or @($owner.PSObject.Properties).Count -ne 2 -or $owner.scope -cnotmatch '^[0-9a-f]{64}$' -or $owner.pid -isnot [ValueType] -or [long]$owner.pid -le 0 -or [long]$owner.pid -gt [uint32]::MaxValue -or [double]$owner.pid -ne [long]$owner.pid){throw 'Prepared host ownership metadata is invalid.'}
    $ledger=Join-Path $Directory 'agent-host-windows\runtime.json'
    if(Test-Path -LiteralPath $ledger){
        $document=Read-PreparedMetadata $ledger 16384
        if($document -isnot [pscustomobject] -or @($document.PSObject.Properties).Count -ne 5 -or $document.format -cne 'coincide.windows.background-host' -or $document.version -ne 1 -or $document.scope -cne $owner.scope -or $document.sessions -isnot [pscustomobject] -or @($document.sessions.PSObject.Properties).Count -ne 0 -or $document.commands -isnot [pscustomobject] -or @($document.commands.PSObject.Properties).Count -ne 0){throw 'Prepared host already contains a session, command or unknown durable state.'}
    }
    $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[uint32]$owner.pid)
    if(!$candidate -or $candidate.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or !$candidate.ExecutablePath -or !$candidate.CommandLine -or [HostedRecoveryNative]::FileIdentity($candidate.ExecutablePath) -ne [HostedRecoveryNative]::FileIdentity([IO.Path]::GetFullPath($Executable))){throw 'Prepared host is not the same owned fixture image.'}
    $arguments=[HostedRecoveryNative]::Arguments($candidate.CommandLine)
    if($arguments.Count -ne 3 -or $arguments[1] -cne '--owned-background-host-fixture' -or ![StringComparer]::OrdinalIgnoreCase.Equals([HostedRecoveryNative]::PhysicalDirectory($arguments[2]),$Directory)){throw 'Prepared host is not the fixed synthetic process for this exact data root.'}
}

$Executable = [IO.Path]::GetFullPath($Executable)
if ([IO.Path]::GetFileName($Executable) -ne 'Coincide.exe') {throw 'Select the completed Coincide.exe fixture build.'}
$imagePin = [HostedRecoveryNative]::PinImage($Executable)
$imageIdentity = [HostedRecoveryNative]::FileIdentity($Executable)
$utf8 = New-Object Text.UTF8Encoding($false)
$Results = [IO.Path]::GetFullPath($Results)
New-Item -ItemType Directory -Force $Results | Out-Null
$temporary = [HostedRecoveryNative]::PhysicalDirectory([IO.Path]::GetTempPath())
$preparedPins=$null
if($PreparedHostedData){
    try{
        $preparedPins=[HostedRecoveryNative]::PinPreparedHostedData($PreparedHostedData)
        $data=[HostedRecoveryNative]::PhysicalDirectory($PreparedHostedData)
        Assert-PreparedHostedHost $data
    }catch{if($preparedPins){foreach($pin in $preparedPins){$pin.Dispose()}};$imagePin.Dispose();throw}
}else{
    $data = Join-Path $temporary ('Coincide-Host-Connection-' + [Guid]::NewGuid().ToString())
    if ([IO.Directory]::Exists($data)) {throw 'The unique owned fixture directory already exists.'}
    New-Item -ItemType Directory -Path $data | Out-Null
    $data = [HostedRecoveryNative]::PhysicalDirectory($data)
    if (!$data.StartsWith($temporary.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
        ([IO.File]::GetAttributes($data) -band [IO.FileAttributes]::ReparsePoint) -or
        [IO.Path]::GetFileName($data) -notmatch '^Coincide-Host-Connection-[0-9a-f-]{36}$') {throw 'The owned fixture physical TEMP boundary is invalid.'}
    [IO.File]::WriteAllText((Join-Path $data 'synthetic-connection-fixture.txt'),"COINCIDE_SYNTHETIC_HOST_CONNECTION`n",$utf8)
}
New-Item -ItemType Directory -Path (Join-Path $data 'threads') | Out-Null
$threadID = [Guid]::NewGuid().ToString('B').ToLowerInvariant()
$threadFile = Join-Path $data "threads\$threadID.json"
$indexFile = Join-Path $data 'workspace.json'
$ledgerFile = Join-Path $data 'agent-host-windows\runtime.json'
$journalFile = Join-Path $data 'hosted-client-state-windows\state.json'
function Write-Json([string]$Path,$Value) {[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 16 -Compress),$utf8)}
Write-Json $indexFile @{version=1;projects=@();threads=@(@{id=$threadID;title='Hosted recovery';project='';provider='codex';model='';pinned=$false;archived=$false})}
Write-Json $threadFile @{version=1;id=$threadID;draft='';messages=@();sessions=@()}
$previousData = $env:COINCIDE_DATA_DIR
$previousDiagnostics = $env:COINCIDE_DIAGNOSTICS_PATH
$previousEpoch = $env:COINCIDE_FIXTURE_SCHEDULE_EPOCH
$env:COINCIDE_DATA_DIR = $data
$env:COINCIDE_DIAGNOSTICS_PATH = Join-Path $Results 'hosted-recovery-startup.txt'
$env:COINCIDE_FIXTURE_SCHEDULE_EPOCH = $null
$script:process=$null;$script:window=$null;$script:uiStamp=$null
$indexLock=$null;$transcriptLock=$null;$passed=$false;$failure=$null;$checks=New-Object 'Collections.Generic.List[string]'
$hostBefore=$null;$providerBefore=$null;$hostProcess=$null;$providerProcess=$null;$afterRecovery=$null;$afterQuit=$null
function Read-OwnedJson([string]$Path,[long]$Limit=16777216) {
    $full=[IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($data+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'An owned fixture read escaped its data directory.'}
    $stream=New-Object IO.FileStream($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $Limit) {throw 'An owned metadata file exceeded its expected bound.'}
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try {return ($reader.ReadToEnd()|ConvertFrom-Json)} finally {$reader.Dispose()}
    } finally {$stream.Dispose()}
}
function Wait-For([scriptblock]$Condition,[string]$Reason,[int]$Seconds=30,[switch]$NoUI) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (!$NoUI -and $script:process -and $script:process.HasExited) {throw 'The owned UI exited before the acceptance checkpoint.'}
        try {if (& $Condition) {return}} catch [System.Management.Automation.RuntimeException] {if($_.Exception.Message -like '*acceptance checkpoint*'){throw}}
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Reason
}
function Image-Processes {
    $name=[IO.Path]::GetFileName($Executable).Replace("'","''")
    foreach($candidate in Get-CimInstance Win32_Process -Filter "Name='$name'") {
        if (!$candidate.ExecutablePath -or !$candidate.CommandLine) {continue}
        try {if([HostedRecoveryNative]::FileIdentity($candidate.ExecutablePath) -eq $imageIdentity){$candidate}}catch{}
    }
}
function Stamp($Candidate) {return ([DateTime]$Candidate.CreationDate).ToUniversalTime().Ticks}
function Owned-Hosts {
    foreach($candidate in Image-Processes) {
        $args=[HostedRecoveryNative]::Arguments($candidate.CommandLine)
        if($args.Count -ne 3 -or $args[1] -ne '--owned-background-host-fixture'){continue}
        try{if([StringComparer]::OrdinalIgnoreCase.Equals([HostedRecoveryNative]::PhysicalDirectory($args[2]),$data)){$candidate}}catch{}
    }
}
function Owned-Providers([uint32]$HostID) {
    foreach($candidate in Image-Processes) {
        if($candidate.ParentProcessId -ne $HostID){continue}
        $args=[HostedRecoveryNative]::Arguments($candidate.CommandLine)
        if($args.Count -eq 3 -and $args[1] -eq '--codex-session-fixture' -and $args[2] -eq 'normal'){$candidate}
        else{throw 'An unexpected child appeared in the exact owned host scope.'}
    }
}
function Pin-TrackedProcess($Snapshot) {
    $value=[Diagnostics.Process]::GetProcessById([int]$Snapshot.id)
    try {
        $null=$value.Handle # Keep the original kernel object pinned through explicit Quit.
        if([Math]::Abs($value.StartTime.ToUniversalTime().Ticks-[long]$Snapshot.stamp) -gt 10){throw 'The exact owned process changed before it could be pinned.'}
        return $value
    }catch{$value.Dispose();throw}
}
function Assert-UIIdentity {
    if(!$script:process -or $script:process.HasExited){throw 'The owned UI is not running.'}
    $candidate=@(Image-Processes|Where-Object {$_.ProcessId -eq $script:process.Id})
    if($candidate.Count -ne 1 -or (Stamp $candidate[0]) -ne $script:uiStamp){throw 'The owned UI process identity changed; no process was killed.'}
    $args=[HostedRecoveryNative]::Arguments($candidate[0].CommandLine)
    if($args.Count -ne 2 -or $args[1] -ne '--hosted-fixture-preview'){throw 'The tracked UI is not the owned hosted fixture preview.'}
}
function Find-Control([string]$ID) {
    $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$ID)
    return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
}
function Invoke-Control([string]$ID) {
    Assert-UIIdentity
    $control=Find-Control $ID
    if(!$control -or !$control.Current.IsEnabled){throw 'The expected owned UI command is unavailable.'}
    # Invoke exactly once. A timeout is not permission to repeat a submitted action.
    $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Set-Composer([string]$Text) {
    Wait-For {try{$box=Find-Control 'Composer';if(!$box){return $false};$value=$box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern);$value.SetValue($Text);return $value.Current.Value -eq $Text}catch [Windows.Automation.ElementNotAvailableException]{return $false}} 'The owned composer did not accept its synthetic value.'
}
function Start-OwnedUI {
    $script:process=Start-Process -FilePath $Executable -ArgumentList '--hosted-fixture-preview' -PassThru
    Wait-For {$script:process.Refresh();$script:process.MainWindowHandle -ne [IntPtr]::Zero} 'The owned fixture UI did not open.'
    $candidate=@(Image-Processes|Where-Object {$_.ProcessId -eq $script:process.Id})
    if($candidate.Count -ne 1){throw 'The newly started fixture UI identity could not be verified.'}
    $script:uiStamp=Stamp $candidate[0];Assert-UIIdentity
    $script:window=[Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    [HostedRecoveryNative]::SetForegroundWindow($script:process.MainWindowHandle)|Out-Null
    Wait-For {$null -ne (Find-Control 'Composer')} 'The owned fixture composer did not initialize.'
    $list=Find-Control 'Threads'
    $condition=New-Object Windows.Automation.AndCondition(
        (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Hosted recovery')),
        (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::ListItem)))
    $item=$list.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
    if(!$item){throw 'The exact owned recovery conversation was not visible.'}
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Host-Session($Document) {
    if($Document.format -ne 'coincide.windows.background-host' -or $Document.version -ne 1 -or $Document.scope -notmatch '^[0-9a-f]{64}$'){throw 'The owned host ledger schema is invalid.'}
    $sessions=@($Document.sessions.PSObject.Properties|Where-Object {$_.Value.key.thread -eq $threadID -and $_.Value.key.provider -eq 'codex'})
    if($sessions.Count -ne 1){throw 'The exact owned host generation was unavailable.'}
    return $sessions[0].Value
}
function Client-Generation {
    $doc=Read-OwnedJson $journalFile
    if($doc.format -ne 'coincide.windows.hosted-client-state' -or $doc.schema -ne 1){throw 'The owned hosted journal schema is invalid.'}
    $generation=@($doc.generations|Where-Object {$_.thread -eq $threadID -and $_.provider -eq 'codex'})
    if($generation.Count -ne 1){throw 'The exact owned client generation is unavailable.'}
    return $generation[0]
}
function Commands-Signature($Document) {
    return ((@($Document.commands.PSObject.Properties|ForEach-Object {$_.Name+'|'+$_.Value.digest+'|'+$_.Value.status}|Sort-Object)) -join "`n")
}
function Assert-Durable {
    $index=Read-OwnedJson $indexFile;$transcript=Read-OwnedJson $threadFile;$hostDoc=Read-OwnedJson $ledgerFile;$hosted=Host-Session $hostDoc;$generation=Client-Generation
    if($index.version -ne 2 -or $transcript.version -ne 2 -or $index.hostFormat -ne 'coincide.windows.background-agent' -or $transcript.hostFormat -ne 'coincide.windows.background-agent' -or $index.hostFormatVersion -ne 1 -or $transcript.hostFormatVersion -ne 1){throw 'Hosted recovery lost its explicit durable v2 format boundary.'}
    $row=@($index.threads|Where-Object {$_.id -eq $threadID})
    $indexed=@($row[0].hostEventCursors|Where-Object {$_.provider -eq 'codex'})
    $saved=@($transcript.hostEventCursors|Where-Object {$_.provider -eq 'codex'})
    if($row.Count -ne 1 -or $indexed.Count -ne 1 -or $saved.Count -ne 1 -or $saved[0].epoch -ne $hosted.epoch -or $indexed[0].epoch -ne $hosted.epoch -or $generation.epoch -ne $hosted.epoch -or !$generation.account_scope -or $generation.account_scope -ne $hosted.account_scope -or $indexed[0].sequence -ne $hosted.last -or $saved[0].sequence -ne $hosted.last -or $hosted.acknowledged -ne $hosted.last -or $hosted.last -le 0 -or @($generation.pending).Count){throw 'Transcript/index, actual host ACK and original journal binding did not converge.'}
    return @{sequence=[long]$hosted.last;messages=@($transcript.messages).Count;commands=@($hostDoc.commands.PSObject.Properties).Count}
}
try {
    Start-OwnedUI
    Set-Composer 'stream-finish'
    Wait-For {(Find-Control 'Send').Current.IsEnabled} 'The owned Send command did not become available.'
    Invoke-Control 'Send'
    Wait-For {$null -ne (Find-Control 'DenyApproval')} 'The deterministic synthetic stream barrier did not appear.'
    Wait-For {$doc=Read-OwnedJson $ledgerFile;$session=Host-Session $doc;$gen=Client-Generation;$session.live -and $session.busy -and $gen.account_scope -and @($session.prompts).Count -eq 1} 'The first synthetic turn was not durably accepted in its original verified generation.'
    $hosts=@(Owned-Hosts)
    if($hosts.Count -ne 1){throw 'The exact scoped synthetic host process was not uniquely identified.'}
    $hostBefore=@{id=[uint32]$hosts[0].ProcessId;stamp=(Stamp $hosts[0])};$hostProcess=Pin-TrackedProcess $hostBefore
    $providers=@(Owned-Providers $hostBefore.id)
    if($providers.Count -ne 1){throw 'The exact synthetic provider child was not uniquely identified.'}
    $providerBefore=@{id=[uint32]$providers[0].ProcessId;stamp=(Stamp $providers[0])};$providerProcess=Pin-TrackedProcess $providerBefore
    $checks.Add('Initial send is accepted by the original owned host and synthetic native provider')
    # Confirm queue acceptance while the first turn remains at its explicit approval
    # barrier. Storage failures below target final receipt persistence, not input admission.
    Set-Composer 'hello'
    Wait-For {(Find-Control 'QueueMessage').Current.IsEnabled} 'The owned Queue command was unavailable.'
    Invoke-Control 'QueueMessage'
    Wait-For {$doc=Read-OwnedJson $ledgerFile;$s=Host-Session $doc;$g=Client-Generation;@($s.queued).Count -eq 1 -and @($g.pending|Where-Object {$_.operation -eq 'queue' -and $_.disposition -eq 'accepted'}).Count -eq 1} 'The second synthetic input was not durably accepted as queued work.'
    $before=Read-OwnedJson $ledgerFile;$queued=@((Host-Session $before).queued)[0];$queuedID=$queued.id
    $indexLock=[IO.File]::Open($indexFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $transcriptLock=[IO.File]::Open($threadFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    # Resolving this fixture approval executes no command. It releases the deterministic
    # first stream boundary, then the already-accepted queued fixture completes normally.
    Invoke-Control 'DenyApproval'
    Wait-For {$doc=Read-OwnedJson $ledgerFile;$s=Host-Session $doc;$done=@($s.events|Where-Object {$_.delivery_id -eq $queuedID -and $_.event.kind -eq 8});!$s.busy -and @($s.queued).Count -eq 0 -and $done.Count -eq 1} 'The queued synthetic final reply did not reach the durable host backlog.'
    $beforeCrash=Read-OwnedJson $ledgerFile;$crashSession=Host-Session $beforeCrash;$journalBefore=Client-Generation
    if($crashSession.acknowledged -ge $crashSession.last -or @($journalBefore.pending|Where-Object {$_.id -eq $queuedID}).Count -ne 1){throw 'Storage failure did not preserve an unacknowledged final prefix and its original pending input ID.'}
    $unsaved=Read-OwnedJson $threadFile
    if(@($unsaved.messages|Where-Object {$_.role -eq 'assistant' -and $_.text -eq 'whole reply'}).Count -or @($unsaved.messages).Count -gt 2){throw 'The final replies reached the blocked transcript before the crash checkpoint.'}
    $signature=Commands-Signature $beforeCrash
    $checks.Add('Owned index/transcript replacement failure retains accepted input identity and unacknowledged final receipts')
    Assert-UIIdentity
    [HostedRecoveryNative]::KillExact([uint32]$script:process.Id,$script:uiStamp,$imageIdentity) # Kill this exact UI kernel process only; never /T, Stop-Process by name or host tree.
    if(!$script:process.WaitForExit(10000)){throw 'The exact owned UI crash did not finish.'}
    $hosts=@(Owned-Hosts);$providers=@(Owned-Providers $hostBefore.id)
    if($hosts.Count -ne 1 -or $hosts[0].ProcessId -ne $hostBefore.id -or (Stamp $hosts[0]) -ne $hostBefore.stamp -or $providers.Count -ne 1 -or $providers[0].ProcessId -ne $providerBefore.id -or (Stamp $providers[0]) -ne $providerBefore.stamp){throw 'Crashing the owned UI disturbed its independently owned host/provider.'}
    $checks.Add('Killing only the owned UI leaves the exact host and provider process identities alive')
    $transcriptLock.Dispose();$transcriptLock=$null;$indexLock.Dispose();$indexLock=$null
    Start-OwnedUI
    Wait-For {$state=Assert-Durable;$state.messages -eq 4} 'Reopened UI did not replay and durably ACK the original final prefix.'
    $transcript=Read-OwnedJson $threadFile
    $unicode=([string][char]0x0928)+[char]0x092e+[char]0x0938+[char]0x094d+[char]0x0924+[char]0x0947+' '+[char]0x4f60+[char]0x597d
    $users=@($transcript.messages|Where-Object {$_.role -eq 'user'});$answers=@($transcript.messages|Where-Object {$_.role -eq 'assistant'})
    if($users.Count -ne 2 -or $answers.Count -ne 2 -or @($users|Where-Object {$_.text -eq 'stream-finish'}).Count -ne 1 -or @($users|Where-Object {$_.id -eq $queuedID -and $_.text -eq 'hello'}).Count -ne 1 -or @($answers|Where-Object {$_.text -eq 'whole reply'}).Count -ne 1 -or @($answers|Where-Object {$_.text -eq $unicode}).Count -ne 1 -or @($transcript.messages|Group-Object id|Where-Object {$_.Count -ne 1}).Count -or @($transcript.queuedInputs).Count){throw 'Reopened UI duplicated, lost or silently resent a previously accepted input/final reply.'}
    $afterRecovery=Assert-Durable
    $afterDoc=Read-OwnedJson $ledgerFile
    $replayedSession=Host-Session $afterDoc
    if($replayedSession.epoch -ne $crashSession.epoch -or $replayedSession.last -ne $crashSession.last){throw 'Reopening generated new native receipts instead of replaying the exact pre-crash durable prefix.'}
    $hosts=@(Owned-Hosts);$providers=@(Owned-Providers $hostBefore.id)
    if((Commands-Signature $afterDoc) -ne $signature -or $hosts.Count -ne 1 -or $hosts[0].ProcessId -ne $hostBefore.id -or (Stamp $hosts[0]) -ne $hostBefore.stamp -or $providers.Count -ne 1 -or $providers[0].ProcessId -ne $providerBefore.id -or (Stamp $providers[0]) -ne $providerBefore.stamp){throw 'Restore recreated a provider or issued duplicate native input/control work.'}
    $checks.Add('Same-data relaunch applies each final reply/user row once without new provider/input work')
    $checks.Add('Replayed transcript/index v2 prefix equals actual host ACK and retires the original pending journal ID')
    Assert-UIIdentity
    if(!$script:process.CloseMainWindow()){throw 'The explicit owned Quit request could not reach the UI.'}
    if(!$script:process.WaitForExit(45000) -or $script:process.ExitCode -ne 0){throw 'Explicit Quit did not save and close the owned UI successfully.'}
    if(!$hostProcess.WaitForExit(10000) -or !$providerProcess.WaitForExit(10000)){throw 'Explicit Quit did not terminate the pinned original host/provider kernel objects.'}
    Wait-For {@(Owned-Hosts).Count -eq 0} 'Explicit Quit left its exact scoped owned host running.' 10 -NoUI
    if(@(Owned-Providers $hostBefore.id).Count){throw 'Explicit Quit left its owned synthetic provider running.'}
    $afterQuit=Assert-Durable
    if($afterQuit.sequence -lt $afterRecovery.sequence){throw 'Explicit Quit reduced a durable receipt prefix.'}
    $checks.Add('Explicit Quit persists final state and exits the exact scoped host/provider without a forced cleanup')
    $passed=$true
} catch {$failure=$_.Exception.Message} finally {
    if($transcriptLock){$transcriptLock.Dispose()};if($indexLock){$indexLock.Dispose()}
    if(!$passed){
        # Failure-only cleanup is restricted to exact image/root/PID creation identities.
        # It is reported as failure and is never evidence of successful explicit Quit.
        try{if($script:process -and !$script:process.HasExited){Assert-UIIdentity;[HostedRecoveryNative]::KillExact([uint32]$script:process.Id,$script:uiStamp,$imageIdentity);$null=$script:process.WaitForExit(5000)}}catch{}
        try{foreach($owned in Owned-Hosts){$pidValue=[uint32]$owned.ProcessId;$stampValue=Stamp $owned;$again=@(Owned-Hosts|Where-Object {$_.ProcessId -eq $pidValue -and (Stamp $_) -eq $stampValue});if($again.Count -eq 1){[HostedRecoveryNative]::KillExact($pidValue,$stampValue,$imageIdentity)}}}catch{}
    }
    $env:COINCIDE_DATA_DIR=$previousData;$env:COINCIDE_DIAGNOSTICS_PATH=$previousDiagnostics;$env:COINCIDE_FIXTURE_SCHEDULE_EPOCH=$previousEpoch
    Write-Json (Join-Path $Results 'hosted-recovery-result.json') @{passed=$passed;checks=@($checks);error=$failure;recovery=$afterRecovery;quit=$afterQuit;ownedDataDirectory=$data;limits=@('Synthetic Codex stream/approval fixtures only; no real sign-in, provider, model or network validation.','Storage failure/crash replay is covered; unknown-delivery owner resolution is not exercised by this script.')}
    if($preparedPins){foreach($pin in $preparedPins){$pin.Dispose()};$preparedPins=$null}
    if($passed -and !$KeepData -and @(Owned-Hosts).Count -eq 0 -and (!$script:process -or $script:process.HasExited)){
        if([StringComparer]::OrdinalIgnoreCase.Equals([HostedRecoveryNative]::PhysicalDirectory($data),$data) -and [IO.File]::ReadAllText((Join-Path $data 'synthetic-connection-fixture.txt')) -eq "COINCIDE_SYNTHETIC_HOST_CONNECTION`n"){Remove-Item -LiteralPath $data -Recurse -Force}
    }
    if($hostProcess){$hostProcess.Dispose()};if($providerProcess){$providerProcess.Dispose()}
    $imagePin.Dispose()
}
if(!$passed){throw 'Hosted recovery smoke failed; the bounded result report and owned fixture data were retained.'}
Write-Output ('PASS: '+$checks.Count+' owned full-app hosted crash/relaunch acceptance checkpoints')
