param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\build\x64\Release\Coincide.exe'),
    [string]$Results = (Join-Path $PSScriptRoot '..\build\ui-smoke'),
    [ValidateRange(0,30)][int]$FixtureStartupDelaySeconds = 0,
    [switch]$HostedRuntime,
    [string]$PreparedHostedData,
    [switch]$NativePanelsOnly,
    [switch]$SkipNativePanels,
    [ValidateSet('question','credential','schedule-panel','preferences-panel','instruction-import-panel','provider-accounts-panel','voice-panel','computer-use-panel','git-panel','terminal-panel','usage-panel','credentials-panel','persona-panel','browser-tool-panel','credentials-controller-panel','native-user-prompt','code-hosting-panel','browser-library-panel','instruction-git-panel')][string]$NativeSuite
)
# Run in an interactive Windows desktop session. SSH's service session cannot validate a visible UI.
$ErrorActionPreference = 'Stop'
if($NativePanelsOnly -and $SkipNativePanels){throw 'Choose native panels or app flows, not both skip modes.'}
if($PreparedHostedData -and (!$HostedRuntime -or $NativePanelsOnly)){throw 'PreparedHostedData is supported only for hosted app flows.'}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class CoincideSmokeWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] private struct FileInfo {
        public uint attributes; public System.Runtime.InteropServices.ComTypes.FILETIME created, accessed, written;
        public uint volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FileInfo info);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint size,uint flags);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CommandLineToArgvW(string command,out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static string PhysicalDirectory(string path) {
        using(var handle=CreateFile(path,0x80,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
            FileInfo info; if(handle.IsInvalid || !GetFileInformationByHandle(handle,out info) || (info.attributes&0x10)==0) throw new InvalidOperationException("The owned fixture TEMP directory could not be resolved");
            var text=new StringBuilder(32768);var count=GetFinalPathNameByHandle(handle,text,(uint)text.Capacity,0);
            if(count==0 || count>=text.Capacity) throw new InvalidOperationException("The owned fixture TEMP path is unavailable");
            var value=text.ToString(); if(value.StartsWith(@"\\?\"))value=value.Substring(4);return value;
        }
    }
    public static string FileIdentity(string path) {
        using(var handle=CreateFile(path,0x80,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
            FileInfo info; if(handle.IsInvalid || !GetFileInformationByHandle(handle,out info) || (info.attributes&0x10)!=0) throw new InvalidOperationException("The owned fixture image could not be verified");
            return info.volume.ToString("x8")+":"+info.indexHigh.ToString("x8")+info.indexLow.ToString("x8");
        }
    }

    private static SafeFileHandle PinPreparedEntry(string path,bool directory,uint share,long maximum) {
        var handle=CreateFile(path,directory?0x81u:0x80000080u,share,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        FileInfo info;
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
            var owner=System.Security.Principal.WindowsIdentity.GetCurrent().User;
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
            var ledger=System.IO.Path.Combine(requested,"agent-host-windows");pins.Add(PinPreparedEntry(ledger,true,3,0));
            var security=System.IO.Directory.GetAccessControl(ledger);var rules=security.GetAccessRules(true,true,typeof(System.Security.Principal.SecurityIdentifier));
            if(!owner.Equals(security.GetOwner(typeof(System.Security.Principal.SecurityIdentifier)))||rules.Count!=1||
                !owner.Equals(rules[0].IdentityReference)||((System.Security.AccessControl.FileSystemAccessRule)rules[0]).AccessControlType!=System.Security.AccessControl.AccessControlType.Allow)
                throw new InvalidOperationException("Prepared host metadata is not private to the current user");
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
        int count;var memory=CommandLineToArgvW(command,out count);if(memory==IntPtr.Zero)throw new InvalidOperationException("The owned host arguments could not be decoded");
        try{var result=new string[count];for(int i=0;i<count;++i)result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));return result;}finally{LocalFree(memory);}
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
    if(!$candidate -or $candidate.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or !$candidate.ExecutablePath -or !$candidate.CommandLine -or [CoincideSmokeWindow]::FileIdentity($candidate.ExecutablePath) -ne [CoincideSmokeWindow]::FileIdentity([IO.Path]::GetFullPath($Executable))){throw 'Prepared host is not the same owned fixture image.'}
    $arguments=[CoincideSmokeWindow]::Arguments($candidate.CommandLine)
    if($arguments.Count -ne 3 -or $arguments[1] -cne '--owned-background-host-fixture' -or ![StringComparer]::OrdinalIgnoreCase.Equals([CoincideSmokeWindow]::PhysicalDirectory($arguments[2]),$Directory)){throw 'Prepared host is not the fixed synthetic process for this exact data root.'}
}


$Results = [IO.Path]::GetFullPath($Results)
New-Item -ItemType Directory -Force $Results | Out-Null
$preparedPins=$null
if($PreparedHostedData){
    try{
        $preparedPins=[CoincideSmokeWindow]::PinPreparedHostedData($PreparedHostedData)
        $data=[CoincideSmokeWindow]::PhysicalDirectory($PreparedHostedData)
        Assert-PreparedHostedHost $data
    }catch{if($preparedPins){foreach($pin in $preparedPins){$pin.Dispose()}};throw}
}else{
    $data = if($HostedRuntime){Join-Path ([CoincideSmokeWindow]::PhysicalDirectory([IO.Path]::GetTempPath())) ('Coincide-Host-Connection-'+[Guid]::NewGuid().ToString())}else{Join-Path $Results ([Guid]::NewGuid().ToString())}
}
New-Item -ItemType Directory -Force (Join-Path $data 'threads') | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
if($HostedRuntime -and !$PreparedHostedData){[IO.File]::WriteAllText((Join-Path $data 'synthetic-connection-fixture.txt'),"COINCIDE_SYNTHETIC_HOST_CONNECTION`n",$utf8)}
function Write-JsonFile($path, $value) {
    [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 12 -Compress), $utf8)
}

$first = [Guid]::NewGuid().ToString('B')
$second = [Guid]::NewGuid().ToString('B')
$threads = @()
foreach ($entry in @(@($first, 'Smoke A', 'END-A'), @($second, 'Smoke B', 'END-B'))) {
    $threads += @{id=$entry[0]; title=$entry[1]; project=''; provider='claude'; model=''; pinned=$false; archived=$false}
    $messages = @()
    for ($i=0; $i -lt 1500; $i++) {
        $text = "Reply $i " + ('wrapped conversation text ' * (1 + ($i % 8)))
        if ($i -eq 1499) { $text = $entry[2] }
        $messages += @{id=[Guid]::NewGuid().ToString('B'); role='assistant'; text=$text; provider='claude'}
    }
    Write-JsonFile (Join-Path $data "threads\$($entry[0]).json") @{
        version=1; id=$entry[0]; draft="Draft $($entry[1])"; messages=$messages; sessions=@()
    }
}
$scheduledThread = [Guid]::NewGuid().ToString('B')
$scheduledTask = [Guid]::NewGuid().ToString('B')
$fixtureEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$due = $fixtureEpoch + 10
$threads += @{id=$scheduledThread; title='Schedule target'; project=''; provider='codex'; model=''; pinned=$false; archived=$false}
Write-JsonFile (Join-Path $data "threads\$scheduledThread.json") @{version=1; id=$scheduledThread; draft='Keep this scheduled-thread draft'; messages=@(); sessions=@()}
# An isolated, previously approved fixture task. Both fixture preview modes force every provider
# child to the synthetic protocol fixture; no real account, model or user schedule is involved.
Write-JsonFile (Join-Path $data 'scheduled-tasks.json') @{format='coincide.windows.schedules'; version=1; tasks=@(@{
    id=$scheduledTask; threadID=$scheduledThread; name='Native schedule fixture'; prompt='hello'; awaitingApproval=$false; paused=$false; reviewRequired=$false;
    recurrence=@{kind='once'; timeZone='UTC'; date=$due; hour=9; minute=0; weekday=2; intervalMinutes=0; cron=''; weekdays=@()}; nextRunAt=$due
})}
Write-JsonFile (Join-Path $data 'workspace.json') @{version=1; projects=@(); threads=$threads}
$previousData = $env:COINCIDE_DATA_DIR
$previousDiagnostics = $env:COINCIDE_DIAGNOSTICS_PATH
$previousFixtureEpoch = $env:COINCIDE_FIXTURE_SCHEDULE_EPOCH
$env:COINCIDE_DATA_DIR = $data
$env:COINCIDE_DIAGNOSTICS_PATH = Join-Path $Results 'startup.txt'
# Only the explicit fixture preview modes read this clock. The real schedule store/controller/timer
# still dispatches the persisted task; cold process startup cannot consume its occurrence.
$env:COINCIDE_FIXTURE_SCHEDULE_EPOCH = [string]$fixtureEpoch
$process = $null
$checks = @()
$hostedCursorBaseline = @()
$preserveHostedData = $false

function Find-OwnedHostedProcesses {
    $identity=[CoincideSmokeWindow]::FileIdentity([IO.Path]::GetFullPath($Executable))
    $name=[IO.Path]::GetFileName($Executable).Replace("'","''")
    foreach($candidate in Get-CimInstance Win32_Process -Filter "Name='$name'"){
        if(!$candidate.CommandLine -or !$candidate.ExecutablePath){continue}
        $arguments=[CoincideSmokeWindow]::Arguments($candidate.CommandLine)
        if($arguments.Count -ne 3 -or $arguments[1] -ne '--owned-background-host-fixture'){continue}
        if(![StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($arguments[2]),$data)){continue}
        if([CoincideSmokeWindow]::FileIdentity($candidate.ExecutablePath) -eq $identity){$candidate}
    }
}
function Assert-HostedDurability {
    $index=Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($index.version -ne 2 -or $index.hostFormat -ne 'coincide.windows.background-agent' -or $index.hostFormatVersion -ne 1){throw 'Hosted execution did not retain its explicit version2 workspace boundary.'}
    $stateFile=Join-Path $data 'hosted-client-state-windows\state.json'
    $client=Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if($client.format -ne 'coincide.windows.hosted-client-state' -or $client.schema -ne 1 -or !$client.scope -or $client.revision -le 0){throw 'Hosted client routing metadata was not durably retained.'}
    $evidence=@()
    foreach($thread in $index.threads){
        foreach($cursor in @($thread.hostEventCursors | Where-Object {$null -ne $_})){
            $transcript=Get-Content (Join-Path $data "threads\$($thread.id).json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved=@($transcript.hostEventCursors | Where-Object {$_.provider -eq $cursor.provider -and $_.epoch -eq $cursor.epoch})
            $generation=@($client.generations | Where-Object {$_.thread -eq $thread.id -and $_.provider -eq $cursor.provider -and $_.epoch -eq $cursor.epoch})
            if($transcript.version -ne 2 -or $transcript.hostFormat -ne 'coincide.windows.background-agent' -or $saved.Count -ne 1 -or $saved[0].sequence -lt $cursor.sequence -or $cursor.sequence -le 0 -or $generation.Count -ne 1 -or !$generation[0].account_scope){throw 'A hosted transcript/index prefix lost its matching generation, account binding or durable positive cursor.'}
            if(@($generation[0].pending).Count){throw 'A completed owned hosted flow retained an unresolved input intent.'}
            $evidence+=@{thread=$thread.id;provider=$cursor.provider;epoch=$cursor.epoch;sequence=$cursor.sequence;transcriptSequence=$saved[0].sequence}
        }
    }
    foreach($required in @($codex[0].id,$scheduledThread)){if(!@($evidence | Where-Object {$_.thread -eq $required}).Count){throw 'A completed interactive or scheduled turn has no durable hosted event cursor.'}}
    foreach($previous in $hostedCursorBaseline){$current=@($evidence | Where-Object {$_.thread -eq $previous.thread -and $_.provider -eq $previous.provider -and $_.epoch -eq $previous.epoch});if($current.Count -ne 1 -or $current[0].sequence -lt $previous.sequence){throw 'Orderly hosted Quit lost or reduced a previously durable receipt prefix.'}}
    return $evidence
}
function Close-OwnedPreview {
    if(!$process){return}
    if(!$process.HasExited){
        $process.CloseMainWindow() | Out-Null
        $milliseconds=if($HostedRuntime){45000}else{10000}
        if(!$process.WaitForExit($milliseconds)){
            $process.Kill()
            if($HostedRuntime){$script:preserveHostedData=$true;throw 'Hosted orderly Quit exceeded45seconds and required killing only the owned UI process; retained fixture data needs review.'}
        }
    }
    if($HostedRuntime){
        try{
            if($process.ExitCode -ne 0){throw 'The owned hosted UI exited unsuccessfully during orderly Quit.'}
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            do{$left=@(Find-OwnedHostedProcesses);if(!$left.Count){break};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
            if($left.Count){throw 'Orderly Quit left an exact-image, exact-root owned host process running.'}
        }catch{$script:preserveHostedData=$true;throw}
    }
}

function Wait-Until([scriptblock]$Condition, [string]$Failure) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($process.HasExited) { throw "Preview exited unexpectedly: $($process.ExitCode)" }
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Failure
}
function Find-Control($parent, [string]$id) {
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    $parent.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Select-Thread([string]$name) {
    $list = Find-Control $script:window 'Threads'
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::NameProperty, $name)
    $item = $list.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    if (!$item) { throw "Cannot find conversation $name" }
    $pattern = $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
    $pattern.Select()
}
function Latest-IsVisible([string]$marker) {
    $list = Find-Control $script:window 'Transcript'
    if (!$list) { return $false }
    $elements = $list.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition)
    foreach ($item in $elements) {
        if ($item.Current.Name -like "*$marker*" -and !$item.Current.IsOffscreen) {
            return $item.Current.BoundingRectangle.Height -gt 0
        }
    }
    return $false
}
function Save-WindowEvidence {
    if (!$process -or $process.HasExited -or !$script:window) { return }
    try {
        $elements=$script:window.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.Condition]::TrueCondition)
        $tree=@()
        foreach($element in $elements) {
            $current=$element.Current
            $tree += @{name=$current.Name; id=$current.AutomationId; offscreen=$current.IsOffscreen;
                type=$current.ControlType.ProgrammaticName; bounds=$current.BoundingRectangle.ToString()}
        }
        Write-JsonFile (Join-Path $Results 'controls.json') $tree
        if ([CoincideSmokeWindow]::GetForegroundWindow() -ne $process.MainWindowHandle) { return }
        $rect = New-Object CoincideSmokeWindow+Rect
        if (![CoincideSmokeWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) { return }
        $bitmap = New-Object Drawing.Bitmap(($rect.Right-$rect.Left), ($rect.Bottom-$rect.Top))
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
            $bitmap.Save((Join-Path $Results 'preview.png'), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    } catch { }
}

try {
    # The title identifies a protocol-fixture test, and this mode requires the isolated directory above.
    # Every provider response comes from the local fixture subprocess; no account or network is used.
    if (!$NativePanelsOnly) {
    if($FixtureStartupDelaySeconds){Start-Sleep -Seconds $FixtureStartupDelaySeconds}
    $fixtureMode=if($HostedRuntime){'--hosted-fixture-preview'}else{'--codex-fixture-preview'}
    $process = Start-Process -FilePath $Executable -ArgumentList $fixtureMode -PassThru
    Wait-Until { $process.Refresh(); $process.MainWindowHandle -ne [IntPtr]::Zero } 'No application window appeared.'
    $script:window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    [CoincideSmokeWindow]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
    Wait-Until { Latest-IsVisible 'END-A' } 'The initial long conversation did not show its latest row.'
    $checks += 'Initial long conversation shows its latest row without scrolling'
    Select-Thread 'Smoke B'
    Wait-Until { Latest-IsVisible 'END-B' } 'Switching conversations did not show the latest row.'
    $checks += 'Second long conversation shows its latest row without scrolling'
    $composer = Find-Control $script:window 'Composer'
    $value = $composer.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    if ($value.Current.Value -ne 'Draft Smoke B') { throw 'The second conversation has the wrong draft.' }
    $checks += 'Draft belongs to the selected conversation'
    Select-Thread 'Smoke A'
    Wait-Until { Latest-IsVisible 'END-A' } 'Returning to the first conversation left the transcript blank.'
    $checks += 'Returning to a long conversation renders without manual scrolling'

    function Invoke-Control([string]$id) {
        $observed=@{control=$null;more=$null}
        $toolbarCommand=$id -in @('OpenPasswords','OpenPullRequests')
        Wait-Until {
            $observed.control=Find-Control $script:window $id
            if($toolbarCommand -and !$observed.control){
                $toolbar=Find-Control $script:window 'ConversationToolbar'
                if(!$toolbar){$toolbar=$script:window}
                $observed.more=Find-Control $toolbar 'MoreButton'
            }
            $null -ne $observed.control -or $null -ne $observed.more
        } "Cannot observe current control or toolbar overflow for $id"
        $control=$observed.control
        if (!$control -and $observed.more) {
            # Observe fresh peers after long-thread/tool-pane layout, then invoke once.
            $observed.more.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            $filter=New-Object Windows.Automation.AndCondition(
                (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$id)),
                (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)))
            Wait-Until {$null -ne [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Descendants,$filter)} "Cannot find overflow command $id"
            $control=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Descendants,$filter)
        }
        if (!$control) { throw "Cannot find $id" }
        $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    function Set-ControlValue([string]$id,[string]$text) {
        # Native XAML may recreate an automation peer while a prompt row changes size.
        # Setting a value is idempotent; wait for the current editable peer, never retry Invoke.
        Wait-Until {
            $box=Find-Control $script:window $id
            if(!$box){return $false}
            try {$value=$box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern);if(!$value){return $false};$value.SetValue($text);return $value.Current.Value -eq $text}
            catch [Windows.Automation.ElementNotAvailableException] {return $false}
        } "The native $id editor did not accept its owned fixture value."
    }
    function Set-Message([string]$text) {Set-ControlValue 'Composer' $text}
    function Send-Message([string]$text) {
        Set-Message $text
        Wait-Until { (Find-Control $script:window 'Send').Current.IsEnabled } 'Send was not enabled for the Codex conversation.'
        Invoke-Control 'Send'
        # InvokePattern can return before the dispatcher handles the click. A previous identical reply
        # and its idle controls are not evidence that this send has been accepted or completed.
        Wait-Until {
            (Find-Control $script:window 'Composer').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -eq ''
        } 'Send did not accept and clear the submitted draft.'
    }
    Invoke-Control 'NewChat'
    Wait-Until { (Find-Control $script:window 'AgentStatus').Current.Name -like 'Codex*' } 'The new Codex conversation did not become available.'
    Send-Message 'hello'
    $replyMarker = ([string][char]0x4f60) + [char]0x597d
    Wait-Until { (Latest-IsVisible $replyMarker) -and !(Find-Control $script:window 'Stop').Current.IsEnabled } 'The Codex fixture reply was not displayed.'
    $index = Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $codex = @($index.threads | Where-Object {$_.provider -eq 'codex' -and $_.id -ne $scheduledThread})
    if ($codex.Count -ne 1) { throw 'The Codex conversation was not saved in the index.' }
    $threadFile = Join-Path $data "threads\$($codex[0].id).json"
    $saved = Get-Content $threadFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.messages.Count -ne 2 -or $saved.messages[1].text -notlike "*$replyMarker") { throw 'Streamed and completed items were duplicated or not persisted.' }
    if ($saved.sessions[0].id -ne 'fixture-thread') { throw 'The native Codex session identity was not persisted.' }
    $checks += 'Native Send streams Unicode, reconciles the final item, and saves the session without duplicates'

    Send-Message 'hello'
    Wait-Until { (Latest-IsVisible $replyMarker) -and !(Find-Control $script:window 'Stop').Current.IsEnabled } 'A repeated reply made the window unresponsive.'
    $repeated = Get-Content $threadFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $answers = @($repeated.messages | Where-Object {$_.role -eq 'assistant'})
    if ($repeated.messages.Count -ne 4 -or $answers.Count -ne 2 -or $answers[0].text -ne $answers[1].text) { throw 'Identical replies were merged or lost.' }
    $checks += 'Identical replies keep distinct transcript rows and accessible controls remain responsive'

    Send-Message 'approval'
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'No native approval card appeared.'
    Select-Thread 'Smoke B'
    if ($null -ne (Find-Control $script:window 'DenyApproval')) { throw 'Another thread displayed the Codex approval.' }
    Select-Thread $codex[0].title
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'The pending approval was lost after switching threads.'
    Invoke-Control 'DenyApproval'
    Wait-Until { (Latest-IsVisible 'decline') -and !(Find-Control $script:window 'Stop').Current.IsEnabled } 'The denial did not reach the fixture.'
    $checks += 'Approval remains with its thread and explicit denial reaches the subprocess'

    Send-Message 'approval'
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'No approval appeared for persistence recovery.'
    # Block only this owned fixture transcript's atomic replacement. The runtime may still finish;
    # its later events must remain in memory and completion must recover after storage is available.
    $lockedTranscript = [IO.File]::Open($threadFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Invoke-Control 'DenyApproval'
        Wait-Until { (Latest-IsVisible 'decline') -and (Find-Control $script:window 'Stop').Current.IsEnabled } 'The completed reply was lost during a fixture write failure.'
        Start-Sleep -Milliseconds 500
        if (!(Find-Control $script:window 'Stop').Current.IsEnabled) { throw 'Completion was reported before the blocked transcript was saved.' }
    } finally { $lockedTranscript.Dispose() }
    Wait-Until { !(Find-Control $script:window 'Stop').Current.IsEnabled } 'Completion did not recover after the transcript write lock was released.'
    $recovered = Get-Content $threadFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($recovered.messages[-1].text -ne 'decline') { throw 'Recovered completion did not persist the final reply.' }
    $checks += 'A transient storage failure preserves later events and retries persistence before completion'


    Send-Message 'file-approval'
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'No file-change approval appeared.'
    # Query the exposed detail control directly rather than enumerating the virtualized transcript.
    $detail = Find-Control $script:window 'ApprovalDetails'
    if (!$detail -or $detail.Current.Name -notlike '*fixture.txt*' -or $detail.Current.Name -notlike '*+after*') { throw 'The file-change card omitted its path and diff.' }
    Invoke-Control 'DenyApproval'
    Wait-Until { !(Find-Control $script:window 'Stop').Current.IsEnabled } 'File-change denial did not finish.'
    $checks += 'File-change approval displays the proposed path and diff and requires an explicit decision'

    Send-Message 'question'
    Wait-Until { $null -ne (Find-Control $script:window 'QuestionAnswer') } 'No native question appeared.'
    Set-ControlValue 'QuestionAnswer' 'fixture-ui-answer'
    Invoke-Control 'SubmitAnswer'
    Wait-Until { (Latest-IsVisible 'fixture-ui-answer') -and !(Find-Control $script:window 'Stop').Current.IsEnabled } 'The question answer did not reach the fixture.'
    $checks += 'A native question submits the answer to its original request'

    Send-Message 'wait'
    Wait-Until { (Find-Control $script:window 'AgentStatus').Current.Name -like '*working*' } 'The fixture turn did not start.'
    Set-Message 'next draft'
    Invoke-Control 'Stop'
    Wait-Until { !(Find-Control $script:window 'Stop').Current.IsEnabled } 'Stop did not complete.'
    $box = Find-Control $script:window 'Composer'
    if ($box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -ne 'next draft') { throw 'Stopping lost the draft typed during the turn.' }
    $checks += 'Stop interrupts the active turn and preserves the next draft'

    Invoke-Control 'NewChat'
    Wait-Until { (Find-Control $script:window 'AgentStatus').Current.Name -like 'Codex*' } 'The second untitled conversation did not open.'
    $list = Find-Control $script:window 'Threads'
    $sameTitle = New-Object Windows.Automation.AndCondition(
        (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)),
        (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $codex[0].title)))
    if ($list.FindAll([Windows.Automation.TreeScope]::Descendants, $sameTitle).Count -ne 2) { throw 'Identical conversation titles do not have separate accessible rows.' }
    $checks += 'Identical conversation titles retain separate accessible sidebar rows'

    $scheduledFile = Join-Path $data "threads\$scheduledThread.json"
    Wait-Until {
        $scheduled = Get-Content $scheduledFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $scheduleState = Get-Content (Join-Path $data 'scheduled-tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $scheduled.messages.Count -eq 2 -and $scheduleState.tasks[0].lastOutcome -eq 'completed'
    } 'The persisted scheduled fixture did not dispatch and finish through the real app controller.'
    $scheduled = Get-Content $scheduledFile -Raw -Encoding UTF8 | ConvertFrom-Json
    # Wait-Until invokes its predicate in a child scope; reload the durable outcome for assertions.
    $scheduleState = Get-Content (Join-Path $data 'scheduled-tasks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($scheduled.draft -ne 'Keep this scheduled-thread draft' -or $scheduled.messages[0].text -ne 'hello' -or $scheduled.messages[1].text -notlike "*$replyMarker") { throw 'Scheduled delivery changed the draft or lost its prompt/final reply.' }
    if ($scheduleState.tasks[0].inFlight -or $scheduleState.tasks[0].deliveryID) { throw 'A finished scheduled fixture retained an in-flight delivery token.' }
    $checks += 'A persisted approved schedule dispatches through the app, preserves the draft and records completion'

    $usageFile=Join-Path $data 'usage-history.json'
    Wait-Until {if(!(Test-Path $usageFile)){return $false};$history=Get-Content $usageFile -Raw -Encoding UTF8 | ConvertFrom-Json;@($history.records).Count -ge 8} 'Local usage lifecycle records were not saved for the owned turns.'
    $history=Get-Content $usageFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $usageTurns=@($history.records | Where-Object {$_.thread -eq $codex[0].id})
    if($usageTurns.Count -ne 7 -or @($usageTurns | Where-Object {$_.outcome -eq 'interrupted'}).Count -ne 1){throw 'Usage history lost, duplicated or misclassified an owned conversation turn.'}
    if(@($history.records | Where-Object {$_.thread -eq $scheduledThread -and $_.outcome -eq 'completed'}).Count -ne 1){throw 'Scheduled usage was not scoped to its original thread.'}
    if(@($history.records | Where-Object {($_.usage.PSObject.Properties.Name -contains 'costUSD') -or ($_.usage.PSObject.Properties.Name -contains 'tokens')}).Count){throw 'The app invented billing totals for a fixture that reported no billable usage.'}
    $checks += 'Local usage records preserve thread/delivery ownership, interruption and unavailable billing totals'

    Invoke-Control 'OpenBots'
    Wait-Until { $control=Find-Control $script:window 'BotOpen';$control -and $control.Current.IsEnabled } 'The native bot editor did not open.'
    Invoke-Control 'BotOpen'
    Wait-Until {
        $index=Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($index.threads | Where-Object {$_.botID}).Count -eq 1
    } 'Opening Brulee did not persist its owned conversation.'
    $index=Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $botThread=@($index.threads | Where-Object {$_.botID})[0]
    $botFile=Join-Path $data "threads\$($botThread.id).json"
    $botHistory=Get-Content $botFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if($botHistory.messages.Count -or $botHistory.sessions.Count -or $botHistory.draft -or !$botThread.botFolder){throw 'Opening a bot sent a message, started a provider, or lost its working folder.'}
    $checks += 'Opening the starter bot creates a scoped conversation without sending a greeting or starting a provider'
    Set-Message 'Keep this bot draft'
    Invoke-Control 'BotNewConversation'
    Wait-Until {
        $index=Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        @($index.threads | Where-Object {$_.botID}).Count -eq 2
    } 'New Conversation reused a bot history that contains a draft.'
    $botHistory=Get-Content $botFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if($botHistory.draft -ne 'Keep this bot draft' -or $botHistory.messages.Count -or $botHistory.sessions.Count){throw 'Creating another bot conversation changed the original draft or started a provider.'}
    $checks += 'New bot conversations preserve the original draft and keep separate empty histories'


    }
    if(!$NativePanelsOnly){
        $beforeImmediate=Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $beforeImmediateIDs=@($beforeImmediate.threads | ForEach-Object {$_.id})
        Invoke-Control 'NewChat'
        Wait-Until {(Find-Control $script:window 'AgentStatus').Current.Name -like 'Codex*'} 'The immediate-edit Codex conversation did not become available.'
        Set-Message 'Superseded synthetic draft'
        Wait-Until {(Find-Control $script:window 'Send').Current.IsEnabled} 'The initial synthetic draft was not ready.'
        Set-ControlValue 'Composer' 'Immediate synthetic replacement'
        Invoke-Control 'Send'
        Wait-Until {(Latest-IsVisible $replyMarker) -and !(Find-Control $script:window 'Stop').Current.IsEnabled} 'The immediate replacement turn did not finish.'
        $currentIndex=Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $newCodex=@($currentIndex.threads | Where-Object {$_.provider -eq 'codex' -and $_.id -notin $beforeImmediateIDs})
        if($newCodex.Count -ne 1){throw 'The immediate replacement conversation was not uniquely saved.'}
        $replacement=Get-Content (Join-Path $data "threads\$($newCodex[0].id).json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $sent=@($replacement.messages | Where-Object {$_.role -eq 'user'})
        if($sent.Count -ne 1 -or $sent[0].text -ne 'Immediate synthetic replacement' -or $replacement.draft){throw 'Send used a superseded draft before its deferred text event.'}
        $checks+='An immediate composer edit followed by Send uses the current text rather than a superseded draft'
    }
    if(!$NativePanelsOnly){
        Select-Thread 'Smoke A'
        Invoke-Control 'OpenPasswords'
        Wait-Until { $panel=Find-Control $script:window 'CredentialHelp'; $panel -and !$panel.Current.IsOffscreen } 'The native password settings did not open.'
        Invoke-Control 'CloseTools'
        Invoke-Control 'OpenPullRequests'
        Wait-Until { $panel=Find-Control $script:window 'CodeHostingStatus'; $panel -and !$panel.Current.IsOffscreen } 'The native pull request workspace did not open.'
        Invoke-Control 'CloseTools'
        $current=Get-Content (Join-Path $data "threads\$first.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if($current.draft -ne 'Draft Smoke A'){throw 'Opening password or pull request tools changed the conversation draft.'}
        $checks += 'Password and pull request tools open in the app without changing the conversation draft'
    }
    # These suites need the real user logon session: XAML controls and Credential Manager
    # cannot be accepted from an SSH service session. Each creates and removes only owned fixtures.
    $nativeSuites=if($SkipNativePanels){@()}elseif($NativeSuite){@($NativeSuite)}else{@('question', 'credential', 'schedule-panel', 'preferences-panel', 'instruction-import-panel', 'provider-accounts-panel','voice-panel','computer-use-panel','git-panel','terminal-panel','usage-panel','credentials-panel','persona-panel','browser-tool-panel','credentials-controller-panel','native-user-prompt','code-hosting-panel','browser-library-panel','instruction-git-panel')}
    foreach ($suite in $nativeSuites) {
        $report = Join-Path $Results "$suite-test-result.txt"
        Remove-Item $report -ErrorAction SilentlyContinue
        $fixtureProcess = Start-Process -FilePath $Executable -ArgumentList @("--$suite-tests", "`"$report`"") -PassThru
        if (!$fixtureProcess.WaitForExit(45000)) { $fixtureProcess.Kill(); throw "Native $suite fixture timed out." }
        if (!(Test-Path $report) -or $fixtureProcess.ExitCode -ne 0) {
            $detail = if (Test-Path $report) { Get-Content $report -Raw } else { 'No report produced' }
            throw "Native $suite fixture failed: $detail"
        }
        $checks += (Get-Content $report -Raw).Trim()
    }
    Save-WindowEvidence
    if($HostedRuntime -and !$NativePanelsOnly){
        $hostedCursorBaseline=@(Assert-HostedDurability)
        Close-OwnedPreview
        $finalCursors=@(Assert-HostedDurability)
        Write-JsonFile (Join-Path $Results 'hosted-cursors.json') $finalCursors
        Copy-Item $data (Join-Path $Results ('hosted-durable-state-'+[IO.Path]::GetFileName($data))) -Recurse
        $checks+='Hosted version2 routing and transcript/index cursors survive orderly Quit with no scoped host process remaining'
    }
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$true; checks=$checks; dataDirectory=$data}
} catch {
    Save-WindowEvidence
    $failure=$_
    # Preserve only the owned synthetic workspace so a failed native flow remains diagnosable.
    try {if(Test-Path $data){Copy-Item $data (Join-Path $Results 'failed-fixture-data') -Recurse -Force}} catch { }
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$false; checks=$checks; error=$failure.Exception.Message; scriptStack=$failure.ScriptStackTrace; dataDirectory=$data}
    throw
} finally {
    $closeFailure=$null
    try{Close-OwnedPreview}catch{$closeFailure=$_}
    $env:COINCIDE_DATA_DIR = $previousData
    $env:COINCIDE_DIAGNOSTICS_PATH = $previousDiagnostics
    $env:COINCIDE_FIXTURE_SCHEDULE_EPOCH = $previousFixtureEpoch
    if($preparedPins){foreach($pin in $preparedPins){$pin.Dispose()};$preparedPins=$null}
    # Only this owned synthetic Results/TEMP root is eligible for cleanup.
    if(!$preserveHostedData){Remove-Item -Recurse -Force $data}
    if($closeFailure){Write-JsonFile (Join-Path $Results 'result.json') @{passed=$false;checks=$checks;error=$closeFailure.Exception.Message;dataDirectory=$data};throw $closeFailure}
}
