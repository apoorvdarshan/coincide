param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\build\x64\Release\Coincide.exe'),
    [string]$Results = (Join-Path $PSScriptRoot '..\build\desktop-smoke')
)
# Physical desktop only. Run explicitly in a reserved interactive Explorer session after a
# desktop-fixture-capable build. Never substitute a normal app launch or run it in SSH Session 0.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
if (!('CoincideDesktopSmokeNative' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CoincideDesktopSmokeNative {
    public delegate bool EnumWindow(IntPtr window, IntPtr state);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiThread { public uint Size, Flags; public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret; public Rect CaretRect; }
    public sealed class RoutingState { public long Target, Foreground, Active, Focus, Capture, Caret; public uint TargetProcess, TargetThread, FocusProcess, Flags; public bool Read, FocusInTarget; public string FocusClass; }
    public sealed class ChildState { public long Handle, Parent; public uint Thread; public bool Visible, Enabled; public string Class; }
    [StructLayout(LayoutKind.Sequential)] public struct MouseInput { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyboardInput Keyboard; }
    [StructLayout(LayoutKind.Sequential)] public struct Input { public uint Type; public InputUnion Value; }
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread, ref GuiThread state);
    [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr window, EnumWindow callback, IntPtr state);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr window, StringBuilder name, int limit);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindow callback, IntPtr state);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint process);
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    public static RoutingState Routing(IntPtr target) {
        uint process; var thread=GetWindowThreadProcessId(target,out process);
        var info=new GuiThread{Size=(uint)Marshal.SizeOf(typeof(GuiThread))};
        var result=new RoutingState{Target=target.ToInt64(),TargetProcess=process,TargetThread=thread,Foreground=GetForegroundWindow().ToInt64()};
        result.Read=thread!=0&&GetGUIThreadInfo(thread,ref info);
        if(result.Read) {result.Active=info.Active.ToInt64();result.Focus=info.Focus.ToInt64();result.Capture=info.Capture.ToInt64();result.Caret=info.Caret.ToInt64();result.Flags=info.Flags;
            uint focusProcess;GetWindowThreadProcessId(info.Focus,out focusProcess);result.FocusProcess=focusProcess;
            result.FocusInTarget=info.Focus==target||IsChild(target,info.Focus);
            if(focusProcess==process){var name=new StringBuilder(256);GetClassName(info.Focus,name,name.Capacity);result.FocusClass=name.ToString();}
        } return result;
    }
    public static ChildState[] Children(IntPtr target) {
        var result=new List<ChildState>();uint process;GetWindowThreadProcessId(target,out process);
        EnumChildWindows(target,(window,state)=>{uint owner;var thread=GetWindowThreadProcessId(window,out owner);
            if(owner==process&&result.Count<128){var name=new StringBuilder(256);GetClassName(window,name,name.Capacity);result.Add(new ChildState{Handle=window.ToInt64(),Parent=GetParent(window).ToInt64(),Thread=thread,Visible=IsWindowVisible(window),Enabled=IsWindowEnabled(window),Class=name.ToString()});}return result.Count<128;},IntPtr.Zero);
        return result.ToArray();
    }
    public static IntPtr[] DesktopHosts(uint process) {
        var found = new List<IntPtr>();
        EnumWindows((window,state) => { uint owner; GetWindowThreadProcessId(window,out owner);
            if(owner==process) { var name=new StringBuilder(256); GetClassName(window,name,name.Capacity);
                if(name.ToString().StartsWith("Coincide.Desktop.",StringComparison.Ordinal)) found.Add(window); }
            return true; },IntPtr.Zero);
        return found.ToArray();
    }
    static Input Key(ushort key, bool up) { return new Input { Type=1, Value=new InputUnion { Keyboard=new KeyboardInput { Key=key, Flags=up?2u:0u } } }; }
    public static void QuitShortcut(IntPtr target) {
        if(GetForegroundWindow()!=target) throw new InvalidOperationException("The owned fixture window is not foreground.");
        foreach(var key in new int[]{0x10,0x11,0x12,0x5b,0x5c}) if((GetAsyncKeyState(key)&0x8000)!=0)
            throw new InvalidOperationException("A modifier key is already held; no fixture input was sent.");
        var inputs=new Input[]{Key(0x11,false),Key(0x51,false),Key(0x51,true),Key(0x11,true)};
        if(SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))!=inputs.Length) {
            var release=new Input[]{Key(0x51,true),Key(0x11,true)};
            SendInput((uint)release.Length,release,Marshal.SizeOf(typeof(Input)));
            throw new InvalidOperationException("The fixture quit shortcut could not be injected completely.");
        }
    }
}
'@
}

$Executable = [IO.Path]::GetFullPath($Executable)
$Results = [IO.Path]::GetFullPath($Results)
New-Item -ItemType Directory -Force -Path $Results | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-JsonFile([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 15 -Compress), $script:utf8)
}
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
$shell = [CoincideDesktopSmokeNative]::GetShellWindow()
$shellProcess = [uint32]0
if ($shell -ne [IntPtr]::Zero) { [CoincideDesktopSmokeNative]::GetWindowThreadProcessId($shell,[ref]$shellProcess) | Out-Null }
$explorer = if ($shellProcess) { Get-Process -Id $shellProcess -ErrorAction SilentlyContinue } else { $null }
if (!$session -or $session -ne [CoincideDesktopSmokeNative]::WTSGetActiveConsoleSessionId() -or ![Environment]::UserInteractive -or !$explorer -or $explorer.ProcessName -ne 'explorer' -or $explorer.SessionId -ne $session) {
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$false; skipped=$true; requiresPhysicalDesktop=$true; reason='An interactive physical Explorer desktop is required; nothing was launched.'}
    exit 77
}
if (!(Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'Build the desktop fixture candidate before this physical test.' }
$run = Join-Path $Results ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $run | Out-Null
$dataA = Join-Path $run 'data-a'
$dataB = Join-Path $run 'data-b'
$owned = New-Object Collections.Generic.List[object]
$agentHandles = @{}
$checks = New-Object Collections.Generic.List[string]
$cleanupErrors = New-Object Collections.Generic.List[string]
$primary = $null
$independent = $null
$mainA = [IntPtr]::Zero
$mainB = [IntPtr]::Zero
$passed = $false
$failure = ''
$routingSequence = 0

function Wait-Until([scriptblock]$Condition,[string]$Failure,[int]$Seconds=20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try { if (& $Condition) { return } }
        catch [Windows.Automation.ElementNotAvailableException] { }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Failure
}
function Assert-OwnedWindow($Owner,[IntPtr]$Window,[switch]$Visible) {
    if (!$Owner -or $Owner.HasExited -or ![CoincideDesktopSmokeNative]::IsWindow($Window)) { throw 'The owned fixture window no longer exists.' }
    $ownerProcess = [uint32]0
    [CoincideDesktopSmokeNative]::GetWindowThreadProcessId($Window,[ref]$ownerProcess) | Out-Null
    if ($ownerProcess -ne $Owner.Id) { throw 'A stale or foreign window handle was rejected.' }
    if ($Visible -and ![CoincideDesktopSmokeNative]::IsWindowVisible($Window)) { throw 'The owned fixture window is hidden.' }
}
function Window-Element($Owner,[IntPtr]$Window) {
    Assert-OwnedWindow $Owner $Window
    [Windows.Automation.AutomationElement]::FromHandle($Window)
}
function Find-Control($Owner,[IntPtr]$Window,[string]$Identity) {
    $root = Window-Element $Owner $Window
    $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$Identity)
    $root.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
}
function Invoke-Control($Owner,[IntPtr]$Window,[string]$Identity) {
    $value = Find-Control $Owner $Window $Identity
    if (!$value -or !$value.Current.IsEnabled) { throw "The owned fixture control '$Identity' is unavailable." }
    $value.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Composer-Value($Owner,[IntPtr]$Window) {
    $value = Find-Control $Owner $Window 'Composer'
    if (!$value) { throw 'The owned fixture composer is missing.' }
    $value.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
}
function Set-Composer($Owner,[IntPtr]$Window,[string]$Text) {
    $value = Find-Control $Owner $Window 'Composer'
    if (!$value) { throw 'The owned fixture composer is missing.' }
    $value.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Text)
}
function Foreground-Owned($Owner,[IntPtr]$Window) {
    Assert-OwnedWindow $Owner $Window
    [CoincideDesktopSmokeNative]::ShowWindowAsync($Window,5) | Out-Null
    [CoincideDesktopSmokeNative]::SetForegroundWindow($Window) | Out-Null
    Wait-Until { [CoincideDesktopSmokeNative]::GetForegroundWindow() -eq $Window } 'The owned fixture could not receive foreground input.' 5
    Assert-OwnedWindow $Owner $Window -Visible
}
function Quit-Owned($Owner,[IntPtr]$Window) {
    Foreground-Owned $Owner $Window
    Save-Routing 'before-quit-shortcut' $Owner $Window
    [CoincideDesktopSmokeNative]::QuitShortcut($Window)
    Save-Routing 'after-quit-shortcut' $Owner $Window
}
function Save-Routing([string]$Phase,$Owner,[IntPtr]$Window) {
    try {
        if(!$Owner) { return }
        $script:routingSequence++
        $value=@{phase=$Phase; processId=$Owner.Id; alive=(!$Owner.HasExited); target=$Window.ToInt64()}
        if(!$Owner.HasExited -and [CoincideDesktopSmokeNative]::IsWindow($Window)) {
            Assert-OwnedWindow $Owner $Window
            $value.native=[CoincideDesktopSmokeNative]::Routing($Window)
            $value.children=@([CoincideDesktopSmokeNative]::Children($Window))
            $focused=[Windows.Automation.AutomationElement]::FocusedElement
            if($focused -and $focused.Current.ProcessId -eq $Owner.Id) { $value.focusedControl=@{id=$focused.Current.AutomationId;type=$focused.Current.ControlType.ProgrammaticName;name=$focused.Current.Name} }
        }
        Write-JsonFile (Join-Path $script:run ('routing-{0:000}-{1}-{2}.json' -f $script:routingSequence,$Owner.Id,$Phase)) $value
    } catch { }
}
function Start-Owned([string]$Directory,[string]$Log) {
    $oldData=$env:COINCIDE_DATA_DIR; $oldLog=$env:COINCIDE_DIAGNOSTICS_PATH
    try {
        $env:COINCIDE_DATA_DIR=$Directory; $env:COINCIDE_DIAGNOSTICS_PATH=$Log
        $value=Start-Process -FilePath $script:Executable -ArgumentList '--desktop-fixture-preview' -PassThru
        $script:owned.Add($value)
        return $value
    } finally { $env:COINCIDE_DATA_DIR=$oldData; $env:COINCIDE_DIAGNOSTICS_PATH=$oldLog }
}
function Seed-Data([string]$Directory,[string]$Title) {
    New-Item -ItemType Directory -Path (Join-Path $Directory 'threads') -Force | Out-Null
    $identity=[Guid]::NewGuid().ToString('B')
    Write-JsonFile (Join-Path $Directory 'workspace.json') @{version=1; projects=@(); threads=@(@{id=$identity; title=$Title; titledByUser=$true; project=''; provider='codex'; model=''; pinned=$false; archived=$false})}
    Write-JsonFile (Join-Path $Directory "threads\$identity.json") @{version=1; id=$identity; draft=''; messages=@(); sessions=@(); draftAttachments=@(); queuedInputs=@()}
    $providers=@{}
    foreach($provider in @('claude','codex','cursor','grok','opencode','antigravity')) {
        # Defense in depth: a broken fixture-mode dispatch can launch only this candidate,
        # never a discovered real provider CLI. The flag itself still must be recognized.
        $providers[$provider]=@{enabled=($provider -eq 'codex'); executable=$script:Executable; favorites=@(); hidden=@(); customModels=@(); defaults=@{model=''; effort=''; serviceTier=''; plan=$false; fullAccess=$false}}
    }
    Write-JsonFile (Join-Path $Directory 'settings.json') @{version=1; format='coincide.windows.settings'; defaultProvider='codex'; background=$true; notifications=$false; keepAwake=$false; awakeOnBattery=$false; keepDisplay=$false; antigravityAcknowledged=$false; providers=$providers}
    return $identity
}
function Capture-Agents($Owner) {
    $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Owner.Id)" -Property ProcessId,ParentProcessId,CreationDate,Name,ExecutablePath,CommandLine)
    if($children.Count -gt 16) { throw 'The fixture unexpectedly owns too many direct children.' }
    $found=@()
    foreach($child in $children) {
        if(!$child.ExecutablePath -or ![string]::Equals([IO.Path]::GetFullPath($child.ExecutablePath),$script:Executable,[StringComparison]::OrdinalIgnoreCase)) { continue }
        if($child.CommandLine -notlike '*--codex-session-fixture*') { throw 'An unexpected candidate child was started instead of the synthetic Codex fixture.' }
        $key=[string]$child.ProcessId
        if(!$script:agentHandles.ContainsKey($key)) {
            $handle=[CoincideDesktopSmokeNative]::OpenProcess(0x00100000,$false,[uint32]$child.ProcessId)
            if($handle -eq [IntPtr]::Zero) { throw 'Could not pin the owned synthetic child for exit verification.' }
            $script:agentHandles[$key]=@{processId=$child.ProcessId; parentProcessId=$child.ParentProcessId; created=$child.CreationDate; handle=$handle}
        }
        $found += $script:agentHandles[$key]
    }
    if(!$found.Count) { throw 'No owned synthetic Codex child is running.' }
    return $found
}
function Save-Evidence([string]$Phase,$Owner,[IntPtr]$Window) {
    if(!$Owner) { return }
    Save-Routing $Phase $Owner $Window
    try {
        $alive=!$Owner.HasExited
        $metadata=@{phase=$Phase; processId=$Owner.Id; alive=$alive; mainHandle=$Window.ToInt64(); visible=($alive -and [CoincideDesktopSmokeNative]::IsWindowVisible($Window)); foreground=([CoincideDesktopSmokeNative]::GetForegroundWindow() -eq $Window)}
        Write-JsonFile (Join-Path $script:run "$Phase-window.json") $metadata
        if(!$metadata.visible) { return }
        $root=Window-Element $Owner $Window
        $elements=$root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
        $tree=@(); foreach($element in $elements) { $value=$element.Current; $tree += @{name=$value.Name; id=$value.AutomationId; type=$value.ControlType.ProgrammaticName; offscreen=$value.IsOffscreen} }
        Write-JsonFile (Join-Path $script:run "$Phase-controls.json") $tree
        # Never capture another application after our window hides or loses foreground.
        if([CoincideDesktopSmokeNative]::GetForegroundWindow() -ne $Window) { return }
        $rectangle=New-Object CoincideDesktopSmokeNative+Rect
        if(![CoincideDesktopSmokeNative]::GetWindowRect($Window,[ref]$rectangle)) { return }
        $width=$rectangle.Right-$rectangle.Left; $height=$rectangle.Bottom-$rectangle.Top
        if($width -le 0 -or $height -le 0 -or $width -gt 5000 -or $height -gt 5000) { return }
        $bitmap=New-Object Drawing.Bitmap($width,$height); $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($rectangle.Left,$rectangle.Top,0,0,$bitmap.Size); $bitmap.Save((Join-Path $script:run "$Phase.png"),[Drawing.Imaging.ImageFormat]::Png) }
        finally { $graphics.Dispose(); $bitmap.Dispose() }
    } catch { }
}
function Send-Wait($Owner,[IntPtr]$Window) {
    Set-Composer $Owner $Window 'wait'
    Wait-Until { (Find-Control $Owner $Window 'Send').Current.IsEnabled } 'Synthetic Send did not enable.'
    Invoke-Control $Owner $Window 'Send'
    Wait-Until { (Composer-Value $Owner $Window) -eq '' -and (Find-Control $Owner $Window 'Stop').Current.IsEnabled -and (Find-Control $Owner $Window 'AgentStatus').Current.Name -like '*working*' } 'The synthetic wait turn did not start.'
}

try {
    $threadA=Seed-Data $dataA 'Desktop fixture A'; $threadB=Seed-Data $dataB 'Desktop fixture B'
    $primary=Start-Owned $dataA (Join-Path $run 'primary-startup.txt')
    Wait-Until { if($primary.HasExited) { throw 'The primary desktop fixture exited during startup.' }; $primary.Refresh(); $primary.MainWindowHandle -ne [IntPtr]::Zero } 'The primary desktop fixture window did not appear.'
    $mainA=$primary.MainWindowHandle
    if((Window-Element $primary $mainA).Current.Name -notlike '*Fixture*') { throw 'The executable did not acknowledge fixture mode; no message was submitted.' }
    Foreground-Owned $primary $mainA
    Wait-Until { (Find-Control $primary $mainA 'Composer') -and (Find-Control $primary $mainA 'AgentStatus').Current.Name -like 'Codex*' } 'The isolated Codex fixture conversation did not load.'
    $desktopHosts=@([CoincideDesktopSmokeNative]::DesktopHosts([uint32]$primary.Id))
    if(!$desktopHosts.Count) { throw 'Actual DesktopServices did not create its owned singleton/tray host.' }
    $checks.Add('The physical Explorer session starts the isolated synthetic app with actual DesktopServices')
    Send-Wait $primary $mainA
    $activeAgents=@(Capture-Agents $primary)
    Save-Evidence 'working-before-close' $primary $mainA
    $primary.Refresh(); if(!$primary.CloseMainWindow()) { throw 'CloseMainWindow did not target the owned main window.' }
    Wait-Until { !$primary.HasExited -and [CoincideDesktopSmokeNative]::IsWindow($mainA) -and ![CoincideDesktopSmokeNative]::IsWindowVisible($mainA) } 'Closing active work exited the process instead of hiding its main window.'
    for($sample=0;$sample -lt 12;$sample++) {
        if($primary.HasExited -or [CoincideDesktopSmokeNative]::IsWindowVisible($mainA)) { throw 'The close-to-background state did not remain stable.' }
        foreach($agent in $activeAgents) { if([CoincideDesktopSmokeNative]::WaitForSingleObject($agent.handle,0) -ne 258) { throw 'Closing the main window terminated the owned synthetic turn.' } }
        Start-Sleep -Milliseconds 100
    }
    Save-Evidence 'hidden-working' $primary $mainA
    $checks.Add('CloseMainWindow hides the HWND while the app and its owned synthetic turn remain alive')

    $sameData=Start-Owned $dataA (Join-Path $run 'same-data-startup.txt')
    Wait-Until { $sameData.HasExited } 'The second same-data app did not exit after activating the original.' 15
    if($sameData.ExitCode -ne 0) { throw 'The second same-data app reported a startup failure.' }
    Wait-Until { !$primary.HasExited -and [CoincideDesktopSmokeNative]::IsWindowVisible($mainA) -and [CoincideDesktopSmokeNative]::GetForegroundWindow() -eq $mainA } 'The second same-data app did not activate the original HWND.'
    Wait-Until { (Find-Control $primary $mainA 'Stop').Current.IsEnabled -and (Find-Control $primary $mainA 'AgentStatus').Current.Name -like '*working*' } 'Reactivation lost or interrupted the still-active synthetic turn.'
    $reactivatedAgents=@(Capture-Agents $primary)
    $reactivatedIds=(@($reactivatedAgents | ForEach-Object processId | Sort-Object) -join ',')
    $activeIds=(@($activeAgents | ForEach-Object processId | Sort-Object) -join ',')
    if($reactivatedIds -ne $activeIds) { throw 'Same-data activation replaced or duplicated the owned agent child.' }
    $checks.Add('A same-data second launch activates the original process and exits without replacing active work')
    Save-Evidence 'reactivated-working' $primary $mainA

    $independent=Start-Owned $dataB (Join-Path $run 'independent-startup.txt')
    Wait-Until { if($independent.HasExited) { throw 'The independent-data fixture exited during startup.' }; $independent.Refresh(); $independent.MainWindowHandle -ne [IntPtr]::Zero } 'A distinct data directory could not open independently.'
    $mainB=$independent.MainWindowHandle
    if($independent.Id -eq $primary.Id -or $mainB -eq $mainA -or (Window-Element $independent $mainB).Current.Name -notlike '*Fixture*') { throw 'Distinct data did not get its own synthetic fixture process/window.' }
    Foreground-Owned $independent $mainB
    Wait-Until { $null -ne (Find-Control $independent $mainB 'Composer') } 'The independent fixture UI did not initialize.'
    Save-Evidence 'independent-instance' $independent $mainB
    Quit-Owned $independent $mainB
    Wait-Until { $independent.HasExited } 'Ctrl+Q did not quit the independent owned fixture.' 15
    if($primary.HasExited) { throw 'Quitting the independent data directory closed the original app.' }
    foreach($agent in $activeAgents) { if([CoincideDesktopSmokeNative]::WaitForSingleObject($agent.handle,0) -ne 258) { throw 'Independent instance shutdown affected the original synthetic child.' } }
    $checks.Add('Distinct data opens independently and its explicit quit leaves the original work untouched')

    Foreground-Owned $primary $mainA
    $draft='desktop draft preserved '+[char]0x2713
    Set-Composer $primary $mainA $draft
    Invoke-Control $primary $mainA 'Stop'
    Wait-Until { !(Find-Control $primary $mainA 'Stop').Current.IsEnabled } 'Stop did not finish the synthetic turn.'
    if((Composer-Value $primary $mainA) -ne $draft) { throw 'Stop lost the draft typed during active work.' }
    $threadFile=Join-Path $dataA "threads\$threadA.json"
    Wait-Until { (Get-Content -LiteralPath $threadFile -Raw -Encoding UTF8 | ConvertFrom-Json).draft -eq $draft } 'Stop did not durably preserve the next draft.'
    Save-Evidence 'stopped-draft-preserved' $primary $mainA
    $checks.Add('Stop interrupts only the active synthetic turn and preserves the next Unicode draft in memory and on disk')

    Send-Wait $primary $mainA
    $null=Capture-Agents $primary
    Save-Evidence 'working-before-quit' $primary $mainA
    Quit-Owned $primary $mainA
    Wait-Until { $primary.HasExited } 'Explicit Ctrl+Q did not quit the original owned fixture.' 15
    Wait-Until { @($agentHandles.Values | Where-Object { [CoincideDesktopSmokeNative]::WaitForSingleObject($_.handle,0) -ne 0 }).Count -eq 0 } 'Explicit Quit did not stop every pinned owned synthetic child.' 15
    foreach($hostWindow in $desktopHosts) {
        $hostProcess=[uint32]0
        if([CoincideDesktopSmokeNative]::IsWindow($hostWindow)) { [CoincideDesktopSmokeNative]::GetWindowThreadProcessId($hostWindow,[ref]$hostProcess) | Out-Null }
        if($hostProcess -eq $primary.Id) { throw 'Quit left its owned DesktopServices message/tray host alive.' }
    }
    $checks.Add('Explicit Ctrl+Q quits the app, stops every pinned owned child, and destroys its desktop/tray host')
    $passed=$true
} catch {
    $failure=$_.Exception.Message
    Save-Evidence 'failure-primary' $primary $mainA
    Save-Evidence 'failure-independent' $independent $mainB
} finally {
    foreach($entry in $owned) {
        try {
            if(!$entry.HasExited) {
                $entry.Refresh(); $handle=$entry.MainWindowHandle
                if($entry.Id -eq $primary.Id) { $handle=$mainA } elseif($independent -and $entry.Id -eq $independent.Id) { $handle=$mainB }
                if($handle -ne [IntPtr]::Zero -and [CoincideDesktopSmokeNative]::IsWindow($handle)) {
                    try { Quit-Owned $entry $handle; $null=$entry.WaitForExit(5000) } catch { }
                }
                if(!$entry.HasExited) { $entry.Kill(); $null=$entry.WaitForExit(5000) }
                if(!$entry.HasExited) { $cleanupErrors.Add("Owned fixture process $($entry.Id) did not exit.") }
            }
        } catch { $cleanupErrors.Add("Owned fixture process cleanup failed: $($_.Exception.Message)") }
    }
    foreach($agent in $agentHandles.Values) {
        if([CoincideDesktopSmokeNative]::WaitForSingleObject($agent.handle,5000) -ne 0) { $cleanupErrors.Add("Pinned owned synthetic child $($agent.processId) is still alive.") }
        [CoincideDesktopSmokeNative]::CloseHandle($agent.handle) | Out-Null
    }
    $processesAlive=@($owned | Where-Object { !$_.HasExited }).Count -gt 0
    foreach($directory in @($dataA,$dataB)) {
        if(Test-Path -LiteralPath $directory) {
            try {
                $destination=Join-Path $run ((Split-Path -Leaf $directory)+'-evidence')
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                foreach($name in @('workspace.json','settings.json')) { $source=Join-Path $directory $name; if(Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $destination $name) } }
                $transcripts=Join-Path $directory 'threads'; if(Test-Path -LiteralPath $transcripts) { Copy-Item -LiteralPath $transcripts -Destination (Join-Path $destination 'threads') -Recurse }
                if(!$processesAlive -and !$cleanupErrors.Count) { Remove-Item -LiteralPath $directory -Recurse -Force }
            } catch { $cleanupErrors.Add("Owned fixture data cleanup failed: $($_.Exception.Message)") }
        }
    }
    if($cleanupErrors.Count) { $passed=$false; if(!$failure) { $failure='Owned fixture cleanup was incomplete.' } }
    $childEvidence=@($agentHandles.Values | ForEach-Object { @{processId=$_.processId; parentProcessId=$_.parentProcessId; created=$_.created} })
    $result=@{passed=$passed; skipped=$false; requiresPhysicalDesktop=$true; checks=@($checks); error=$failure; cleanupErrors=@($cleanupErrors); artifactDirectory=$run; ownedChildren=$childEvidence; dataDirectories=@($dataA,$dataB)}
    Write-JsonFile (Join-Path $run 'result.json') $result
    Write-JsonFile (Join-Path $Results 'result.json') $result
}
if(!$passed) { throw $failure }
