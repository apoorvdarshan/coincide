param(
    [Parameter(Mandatory=$true)][string]$Binary,
    [Parameter(Mandatory=$true)][string]$Client,
    [Parameter(Mandatory=$true)][string]$Artifacts
)
# Actual interactive Windows desktop attempt. Missing window/GPU/render/input
# fails this smoke; compilation alone never counts as native UI evidence.
$ErrorActionPreference = 'Stop'
$Binary = (Resolve-Path $Binary).Path
$Client = (Resolve-Path $Client).Path
$Artifacts = [IO.Path]::GetFullPath($Artifacts)
New-Item -ItemType Directory -Force $Artifacts | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
# Retain PowerShell's standard reference set when adding Drawing assemblies.
# Replacing it with Drawing alone hides List/HashSet and fails before app launch.
$CompilerReferences = @(
    Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' |
        Where-Object { $_.BaseName -notin @('System.Drawing','System.Drawing.Common','System.Drawing.Primitives') } |
        ForEach-Object { $_.FullName }
) + @([System.Drawing.Bitmap].Assembly.Location,[System.Drawing.Point].Assembly.Location)
# .NET 10 splits Drawing's public image interfaces into private Windows
# runtime assemblies. Reference those installed transitive dependencies too.
$DrawingQueue = [Collections.Generic.Queue[Reflection.Assembly]]::new()
$DrawingQueue.Enqueue([System.Drawing.Bitmap].Assembly)
$DrawingSeen = [Collections.Generic.HashSet[string]]::new()
while ($DrawingQueue.Count -gt 0) {
    $assembly = $DrawingQueue.Dequeue()
    foreach ($reference in $assembly.GetReferencedAssemblies()) {
        if ($reference.Name.StartsWith('System.Private.Windows.') -and $DrawingSeen.Add($reference.FullName)) {
            $dependency = [Reflection.Assembly]::Load($reference)
            $CompilerReferences += $dependency.Location
            $DrawingQueue.Enqueue($dependency)
        }
    }
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
public static class NativeUiSmoke {
    public delegate bool EnumWindow(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int length);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsHungAppWindow(IntPtr window);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr window,uint message,UIntPtr wparam,IntPtr lparam,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int state);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr window,int x,int y,int width,int height,bool repaint);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window,ref Point point);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count, Input[] input, int size);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Keyboard {public ushort vk,scan;public uint flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Sequential)] struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
    [StructLayout(LayoutKind.Explicit)] struct Union {[FieldOffset(0)] public Keyboard keyboard;[FieldOffset(0)] public Mouse mouse;}
    [StructLayout(LayoutKind.Sequential)] struct Input {public uint type;public Union data;}
    static Input Key(ushort key,bool up) {return new Input {type=1,data=new Union{keyboard=new Keyboard{vk=key,flags=up?2u:0u}}};}
    public static IntPtr Find(uint process,string title) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((window,data)=>{uint owner;GetWindowThreadProcessId(window,out owner);var text=new StringBuilder(1024);GetWindowText(window,text,text.Capacity);if(owner==process && IsWindowVisible(window) && text.ToString()==title){found=window;return false;}return true;},IntPtr.Zero);
        return found;
    }
    static void Owned(IntPtr window,uint process) {
        uint owner;GetWindowThreadProcessId(window,out owner);
        if(window==IntPtr.Zero || owner!=process || !IsWindowVisible(window))throw new Exception("Input/capture target is not the retained process's visible window");
    }
    public static bool Focus(IntPtr window,uint process) {Owned(window,process);if(GetForegroundWindow()==window)return true;ShowWindow(window,9);SetForegroundWindow(window);return GetForegroundWindow()==window;}
    public static string[] Diagnose(IntPtr window,uint process) {
        Owned(window,process);UIntPtr result;
        bool responsive=SendMessageTimeout(window,0,UIntPtr.Zero,IntPtr.Zero,2,1000,out result)!=IntPtr.Zero;
        return new[]{"foreground="+(GetForegroundWindow()==window),"hung="+IsHungAppWindow(window),"wmNullResponsive="+responsive};
    }
    public static void Fit(IntPtr window,uint process,int width,int height) {Owned(window,process);if(!MoveWindow(window,15,15,width,height,true))throw new Exception("Cannot size owned native window");}
    static void Send(IntPtr window,uint process,Input[] input) {
        Owned(window,process);if(GetForegroundWindow()!=window)throw new Exception("Owned window lost foreground; refusing input");
        if(SendInput((uint)input.Length,input,Marshal.SizeOf(typeof(Input)))!=input.Length)throw new Exception("SendInput did not deliver the complete owned-window input batch");
    }
    public static void Chord(IntPtr window,uint process,ushort key) {Send(window,process,new[]{Key(0x11,false),Key(key,false),Key(key,true),Key(0x11,true)});}
    public static void Enter(IntPtr window,uint process) {Send(window,process,new[]{Key(0x0D,false),Key(0x0D,true)});}
    public static void Type(IntPtr window,uint process,string text) {
        // Deliver native characters at keyboard pace, allowing WM_CHAR and
        // the focused GPUI text handler to process each input in order.
        foreach(char c in text){Send(window,process,new[]{new Input{type=1,data=new Union{keyboard=new Keyboard{scan=c,flags=4}}},new Input{type=1,data=new Union{keyboard=new Keyboard{scan=c,flags=6}}}});System.Threading.Thread.Sleep(20);}
    }
    public static int[] ComposerClick(IntPtr window,uint process,string evidence) {
        Owned(window,process);if(GetForegroundWindow()!=window)throw new Exception("Composer target is not the active owned window");
        Rect rect;if(!GetClientRect(window,out rect))throw new Exception("Missing client bounds");
        int width=rect.right-rect.left,height=rect.bottom-rect.top,left=width*4/10,right=width*9/10;
        var origin=new Point(0,0);if(!ClientToScreen(window,ref origin))throw new Exception("Missing client origin");
        var edges=new List<int>();int lastEdgeRow=-1000;
        using(var image=new Bitmap(width,height)) {
            using(var graphics=Graphics.FromImage(image)){graphics.CopyFromScreen(origin,Point.Empty,new Size(width,height));}
            image.Save(evidence,ImageFormat.Png);
            // The private smoke starts with the light native theme. Locate the
            // rounded composer's two long neutral border edges in actual pixels;
            // glyphs/text do not form a long continuous horizontal segment.
            for(int y=height/2;y<height-3;y++) {
                int run=0,longest=0;
                for(int x=left;x<right;x++) {
                    var c=image.GetPixel(x,y);int maximum=Math.Max(c.R,Math.Max(c.G,c.B)),minimum=Math.Min(c.R,Math.Min(c.G,c.B));
                    run=maximum<247 && maximum-minimum<25 ? run+1 : 0;longest=Math.Max(longest,run);
                }
                if(longest >= (right-left)*65/100){if(y>lastEdgeRow+2)edges.Add(y);lastEdgeRow=y;}
            }
        }
        if(edges.Count!=2 || edges[1]-edges[0]<60)throw new Exception("Expected exactly one rendered native composer border pair");
        int top=edges[0],bottom=edges[1];var point=new Point((left+right)/2,top+24);
        if(!ClientToScreen(window,ref point) || !SetCursorPos(point.X,point.Y))throw new Exception("Cannot target observed native composer");
        Send(window,process,new[]{new Input{type=0,data=new Union{mouse=new Mouse{flags=2}}},new Input{type=0,data=new Union{mouse=new Mouse{flags=4}}}});
        return new[]{left,top,right,bottom};
    }
    public static void Capture(IntPtr window,uint process,string path) {
        Owned(window,process);if(GetForegroundWindow()!=window)throw new Exception("Capture target is not the active owned native window");
        Rect rect;if(!GetClientRect(window,out rect))throw new Exception("Cannot inspect client area");int width=rect.right-rect.left,height=rect.bottom-rect.top;if(width<600 || height<400)throw new Exception("Native client area is too small");
        var origin=new Point(0,0);if(!ClientToScreen(window,ref origin))throw new Exception("Cannot locate native client area");
        using(var image=new Bitmap(width,height)){using(var graphics=Graphics.FromImage(image)){graphics.CopyFromScreen(origin,Point.Empty,new Size(width,height));}
            image.Save(path,ImageFormat.Png);var colors=new HashSet<int>();double sum=0,squares=0;int count=0;
            for(int y=0;y<height;y+=3)for(int x=0;x<width;x+=3){var color=image.GetPixel(x,y);colors.Add(color.ToArgb());double light=(color.R+color.G+color.B)/3.0;sum+=light;squares+=light*light;count++;}
            double variance=squares/count-(sum/count)*(sum/count);if(colors.Count<24 || variance<64)throw new Exception("Native client has no meaningful rendered content (blank/locked/unavailable GPU desktop)");
        }
    }
}
'@ -ReferencedAssemblies $CompilerReferences

$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('coincide-native-ui-' + [Guid]::NewGuid().ToString('N'))
$HomeDir = Join-Path $Fixture 'home'
$Data = Join-Path $Fixture 'data'
$Project = Join-Path $Fixture 'project'
New-Item -ItemType Directory -Force $Fixture | Out-Null
# Isolate this task-owned synthetic fixture before constructing any Store. No
# account/profile/authority data is ever uploaded with the screenshots.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true,$false)
$inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
Set-Acl -LiteralPath $Fixture -AclObject $acl
foreach ($directory in @($HomeDir,$Data,$Project)) { New-Item -ItemType Directory -Force $directory | Out-Null }
$Environment = @{}
foreach ($name in @('PATH','SystemRoot','WINDIR','TEMP','TMP')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value) { $Environment[$name] = $value }
}
$Environment['HOME']=$HomeDir
$Environment['USERPROFILE']=$HomeDir
$Environment['APPDATA']=(Join-Path $HomeDir 'AppData/Roaming')
$Environment['LOCALAPPDATA']=(Join-Path $HomeDir 'AppData/Local')
$Environment['COINCIDE_RUST_DATA_DIR']=$Data
$Environment['COINCIDE_RUST_GH']=(Join-Path $Fixture 'never-execute/gh.exe')
foreach ($provider in @('CODEX','CLAUDE','CURSOR','GROK','OPENCODE','ANTIGRAVITY')) {
    $Environment["COINCIDE_${provider}_EXECUTABLE"]=(Join-Path $Fixture "never-execute/$provider.exe")
}
$Report = @{scope='Actual Windows native window/input/render/private Store restart attempt';binarySha256=(Get-FileHash $Binary -Algorithm SHA256).Hash;checks=@();passed=$false}
$script:OwnedProcess=$null
$script:PendingClients=[Collections.Generic.List[Diagnostics.Process]]::new()

function Wait-Condition([string]$Description,[scriptblock]$Condition,[int]$Seconds=30) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    $lastError=''
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $value=& $Condition; if ($value) { return $value } } catch {$lastError=$_.Exception.Message}
        Start-Sleep -Milliseconds 150
    }
    throw "Timed out: $Description; $lastError"
}
function Invoke-Rpc([string]$Method,[hashtable]$Params=@{}) {
    $info=[Diagnostics.ProcessStartInfo]::new($Client)
    $info.ArgumentList.Add('api');$info.UseShellExecute=$false
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment.Clear();foreach($key in $Environment.Keys){$info.Environment[$key]=$Environment[$key]}
    $clientProcess=[Diagnostics.Process]::Start($info)
    $script:PendingClients.Add($clientProcess)
    $clientProcess.StandardInput.WriteLine((@{id=1;method=$Method;params=$Params}|ConvertTo-Json -Depth 30 -Compress));$clientProcess.StandardInput.Close()
    # Local transport already bounds request and owner handshake. Retain any
    # stuck client, report it, and preserve its fixture instead of killing it.
    if(-not $clientProcess.WaitForExit(15000)){throw "Owned local-control client still running: PID $($clientProcess.Id)"}
    $script:PendingClients.Remove($clientProcess) | Out-Null
    $output=$clientProcess.StandardOutput.ReadToEnd();$errors=$clientProcess.StandardError.ReadToEnd()
    if($clientProcess.ExitCode -ne 0){throw "Local-control request failed: $Method; $errors"}
    $reply=$output|ConvertFrom-Json -AsHashtable
    if($reply.ContainsKey('error')){throw "Local-control API error: $Method"}
    return $reply.result
}
function Capture-OwnedAccessibility([IntPtr]$Window,[string]$Stage) {
    # Inspect only the private candidate HWND. This diagnostic grants no click
    # authority and never treats missing UIA support as native workflow proof.
    $query=@'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]__WINDOW__)
if($null -eq $root -or $root.Current.ProcessId -ne __OWNER__){throw 'UIA root owner mismatch'}
$all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
if($all.Count -gt 512){throw 'Owned UIA tree exceeds diagnostic bound'}
$rows=@()
foreach($node in $all){
    $value=$node.Current
    if($value.ProcessId -ne __OWNER__){continue}
    $bounds=$value.BoundingRectangle
    $name=$value.Name;$id=$value.AutomationId
    if($name.Length -gt 256 -or $id.Length -gt 256){throw 'Owned UIA label exceeds diagnostic bound'}
    $rows+=@{name=$name;automationId=$id;controlType=$value.ControlType.ProgrammaticName;bounds=@($bounds.X,$bounds.Y,$bounds.Width,$bounds.Height)}
}
ConvertTo-Json -InputObject $rows -Depth 5 -Compress
'@
    $query=$query.Replace('__WINDOW__',$Window.ToInt64().ToString()).Replace('__OWNER__',$script:OwnedProcess.Id.ToString())
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $Environment.SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($query)))){$info.ArgumentList.Add($arg)}
    $info.Environment.Clear();foreach($key in $Environment.Keys){$info.Environment[$key]=$Environment[$key]}
    $reader=[Diagnostics.Process]::Start($info);$script:PendingClients.Add($reader)
    $outputTask=$reader.StandardOutput.ReadToEndAsync();$errorTask=$reader.StandardError.ReadToEndAsync()
    if(-not $reader.WaitForExit(10000)){throw "Owned accessibility reader still running: PID $($reader.Id)"}
    $script:PendingClients.Remove($reader) | Out-Null
    $output=$outputTask.GetAwaiter().GetResult();$null=$errorTask.GetAwaiter().GetResult()
    if($reader.ExitCode -eq 0){
        $nodes=$output|ConvertFrom-Json
        $nodes|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Artifacts "$Stage-accessibility.json")
        $Report.accessibilityObserved=$true
    } else {
        $Report.accessibilityObserved=$false
        $Report.accessibilityDiagnostic='Owned UIA query unavailable; no semantic locator acceptance claimed'
    }
}
function Start-Owned([string]$Stage) {
    # Start-Process inherits this deliberately restricted temporary environment.
    # Restore the parent without printing any saved environment values.
    $saved=@{};foreach($entry in Get-ChildItem Env:){$saved[$entry.Name]=$entry.Value}
    try {
        foreach($entry in Get-ChildItem Env:){[Environment]::SetEnvironmentVariable($entry.Name,$null,'Process')}
        foreach($key in $Environment.Keys){[Environment]::SetEnvironmentVariable($key,$Environment[$key],'Process')}
        $script:OwnedProcess=Start-Process -FilePath $Binary -WorkingDirectory $Fixture -PassThru -RedirectStandardOutput (Join-Path $Artifacts "$Stage-stdout.log") -RedirectStandardError (Join-Path $Artifacts "$Stage-stderr.log")
    } finally {
        foreach($entry in Get-ChildItem Env:){[Environment]::SetEnvironmentVariable($entry.Name,$null,'Process')}
        foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}
    }
    Wait-Condition 'native app and owner-aware control ready' {if($script:OwnedProcess.HasExited){throw 'Owned app exited before ready'};Invoke-Rpc 'app.status'} | Out-Null
    $window=Wait-Condition 'actual visible Windows GPUI window' {$handle=[NativeUiSmoke]::Find([uint32]$script:OwnedProcess.Id,'Coincide Rust Preview');if($handle -ne [IntPtr]::Zero){$handle}}
    $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    [NativeUiSmoke]::Fit($window,[uint32]$script:OwnedProcess.Id,[Math]::Min(1280,$area.Width-30),[Math]::Min(820,$area.Height-30))
    Wait-Condition 'owned app foreground' {[NativeUiSmoke]::Focus($window,[uint32]$script:OwnedProcess.Id)} | Out-Null
    return $window
}
function Capture-Owned([IntPtr]$Window,[string]$Name) {
    Wait-Condition 'owned capture foreground' {[NativeUiSmoke]::Focus($Window,[uint32]$script:OwnedProcess.Id)} | Out-Null
    Start-Sleep -Milliseconds 500
    [NativeUiSmoke]::Capture($Window,[uint32]$script:OwnedProcess.Id,(Join-Path $Artifacts "$Name.png"))
}
function Quit-Owned([IntPtr]$Window) {
    if((Invoke-Rpc 'app.status').running.Count -ne 0){throw 'Provider work unexpectedly started'}
    Wait-Condition 'owned Quit foreground' {[NativeUiSmoke]::Focus($Window,[uint32]$script:OwnedProcess.Id)} | Out-Null
    [NativeUiSmoke]::Chord($Window,[uint32]$script:OwnedProcess.Id,0x51)
    if(-not $script:OwnedProcess.WaitForExit(30000)){
        # Diagnostics never issue another key or substitute API Quit for the
        # required native action. Preserve the actual failure and owner.
        $Report.quitWindowDiagnostics=@([NativeUiSmoke]::Diagnose($Window,[uint32]$script:OwnedProcess.Id))
        try {$Report.quitControlStatus=Invoke-Rpc 'app.status'} catch {$Report.quitControlError=$_.Exception.Message}
        throw "Normal Ctrl+Q did not drain owned PID $($script:OwnedProcess.Id)"
    }
    if($script:OwnedProcess.ExitCode -ne 0){throw 'Normal Quit returned nonzero'}
    $script:OwnedProcess=$null
}
try {
    $main=Start-Owned 'initial'
    $project=Invoke-Rpc 'projects.create' @{path=$Project;name='Windows native smoke'}
    $thread=Invoke-Rpc 'threads.create' @{projectId=$project.id}
    $threadId=$thread.id
    Invoke-Rpc 'threads.patch' @{threadId=$threadId;patch=@{title='Windows native smoke'}} | Out-Null
    Invoke-Rpc 'threads.open' @{threadId=$threadId} | Out-Null
    Wait-Condition 'native thread became active' {(Invoke-Rpc 'app.status').activeThread -eq $threadId} | Out-Null
    Capture-Owned $main 'conversation'
    $Report.composerInputBounds=@([NativeUiSmoke]::ComposerClick($main,[uint32]$script:OwnedProcess.Id,(Join-Path $Artifacts "composer-locator.png")))
    # A click is not a text-handler readiness acknowledgement. Retain the
    # focused native frame before delivering keyboard input.
    Capture-Owned $main 'focused-composer'
    $draft='Windows native input draft survives restart'
    [NativeUiSmoke]::Type($main,[uint32]$script:OwnedProcess.Id,$draft)
    Capture-Owned $main 'native-input-attempt'
    Wait-Condition 'actual SendInput draft persisted' {(Invoke-Rpc 'threads.read' @{threadId=$threadId}).draft -eq $draft} | Out-Null
    Capture-Owned $main 'typed-draft'
    $Report.checks+='Actual Windows visible native window, nonblank client pixels, SendInput draft verified by private RPC'
    [NativeUiSmoke]::Chord($main,[uint32]$script:OwnedProcess.Id,0x4B)
    [NativeUiSmoke]::Type($main,[uint32]$script:OwnedProcess.Id,'Open settings')
    Start-Sleep -Milliseconds 400
    [NativeUiSmoke]::Enter($main,[uint32]$script:OwnedProcess.Id)
    $settings=Wait-Condition 'separate General Settings window' {$handle=[NativeUiSmoke]::Find([uint32]$script:OwnedProcess.Id,'General');if($handle -ne [IntPtr]::Zero){$handle}}
    Capture-Owned $settings 'settings-general'
    Capture-OwnedAccessibility $settings 'settings-general'
    [NativeUiSmoke]::Chord($settings,[uint32]$script:OwnedProcess.Id,0x57)
    Wait-Condition 'Settings window closed independently' {[NativeUiSmoke]::Find([uint32]$script:OwnedProcess.Id,'General') -eq [IntPtr]::Zero} | Out-Null
    if($script:OwnedProcess.HasExited){throw 'Closing Settings unexpectedly closed the app'}
    if((Invoke-Rpc 'threads.read' @{threadId=$threadId}).draft -ne $draft){throw 'Settings lost native draft'}
    $Report.checks+='Owned Settings window opened/rendered/closed; main native draft preserved'
    $newer=Invoke-Rpc 'threads.create' @{projectId=$project.id}
    Invoke-Rpc 'threads.patch' @{threadId=$newer.id;patch=@{title='Newer unselected Windows conversation'}} | Out-Null
    Invoke-Rpc 'threads.open' @{threadId=$threadId} | Out-Null
    Wait-Condition 'older selected conversation before Quit' {(Invoke-Rpc 'app.status').activeThread -eq $threadId} | Out-Null
    Capture-Owned $main 'older-selected-before-quit'
    Quit-Owned $main
    $main=Start-Owned 'restart'
    Wait-Condition 'last selected older conversation restored automatically' {(Invoke-Rpc 'app.status').activeThread -eq $threadId} | Out-Null
    if((Invoke-Rpc 'threads.read' @{threadId=$threadId}).draft -ne $draft){throw 'Normal Quit/reopen lost native draft'}
    Capture-Owned $main 'reopened-draft'
    $Report.persistedDraftVerified=((Invoke-Rpc 'threads.read' @{threadId=$threadId}).draft -eq $draft)
    $Report.checks+='Normal Ctrl+Q exited zero and reopening preserved private Store draft with rendered native client'
    Quit-Owned $main
    $Report.passed=$true
} catch {
    $Report.error=$_.Exception.Message
    try {
        $Report.failureActiveThread=(Invoke-Rpc 'app.status').activeThread
        if($null -ne $main){Capture-Owned $main 'failure-owned-window'}
    } catch { $Report.failureCaptureError=$_.Exception.Message }
    throw
} finally {
    if($null -ne $script:OwnedProcess -and -not $script:OwnedProcess.HasExited){
        try {Invoke-Rpc 'app.quit' | Out-Null;$null=$script:OwnedProcess.WaitForExit(20000)} catch {}
    }
    $pending=@($script:PendingClients | Where-Object {-not $_.HasExited})
    if($null -ne $script:OwnedProcess -and -not $script:OwnedProcess.HasExited){$pending+= $script:OwnedProcess}
    if($pending.Count -gt 0){
        $Report.pendingOwnedPids=@($pending | ForEach-Object {$_.Id})
        $Report.retainedFixture=$Fixture
        $Report.passed=$false
        # No terminate/kill, key/data upload, or deletion while an owner remains.
    } else {
        Remove-Item -LiteralPath $Fixture -Recurse -Force
    }
    $Report | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8 (Join-Path $Artifacts 'report.json')
}
$Report | ConvertTo-Json -Depth 30
