param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\build\x64\Release\Coincide.exe'),
    [string]$Results = (Join-Path $PSScriptRoot '..\build\ui-smoke')
)
# Run in an interactive Windows desktop session. SSH's service session cannot validate a visible UI.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CoincideSmokeWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@

$Results = [IO.Path]::GetFullPath($Results)
New-Item -ItemType Directory -Force $Results | Out-Null
$data = Join-Path $Results ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force (Join-Path $data 'threads') | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
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
Write-JsonFile (Join-Path $data 'workspace.json') @{version=1; projects=@(); threads=$threads}
$previousData = $env:COINCIDE_DATA_DIR
$previousDiagnostics = $env:COINCIDE_DIAGNOSTICS_PATH
$env:COINCIDE_DATA_DIR = $data
$env:COINCIDE_DIAGNOSTICS_PATH = Join-Path $Results 'startup.txt'
$process = $null
$checks = @()

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
    $process = Start-Process -FilePath $Executable -ArgumentList '--codex-fixture-preview' -PassThru
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
        $control = Find-Control $script:window $id
        if (!$control) { throw "Cannot find $id" }
        $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    function Set-Message([string]$text) {
        $box = Find-Control $script:window 'Composer'
        $box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($text)
    }
    function Send-Message([string]$text) {
        Set-Message $text
        Wait-Until { (Find-Control $script:window 'Send').Current.IsEnabled } 'Send was not enabled for the Codex conversation.'
        Invoke-Control 'Send'
    }
    Invoke-Control 'NewChat'
    Wait-Until { (Find-Control $script:window 'AgentStatus').Current.Name -like 'Codex*' } 'The new Codex conversation did not become available.'
    Send-Message 'hello'
    $replyMarker = ([string][char]0x4f60) + [char]0x597d
    Wait-Until { (Latest-IsVisible $replyMarker) -and !(Find-Control $script:window 'Stop').Current.IsEnabled } 'The Codex fixture reply was not displayed.'
    $index = Get-Content (Join-Path $data 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $codex = @($index.threads | Where-Object {$_.provider -eq 'codex'})
    if ($codex.Count -ne 1) { throw 'The Codex conversation was not saved in the index.' }
    $threadFile = Join-Path $data "threads\$($codex[0].id).json"
    $saved = Get-Content $threadFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.messages.Count -ne 2 -or $saved.messages[1].text -notlike "*$replyMarker") { throw 'Streamed and completed items were duplicated or not persisted.' }
    if ($saved.sessions[0].id -ne 'fixture-thread') { throw 'The native Codex session identity was not persisted.' }
    $checks += 'Native Send streams Unicode, reconciles the final item, and saves the session without duplicates'

    Send-Message 'approval'
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'No native approval card appeared.'
    Select-Thread 'Smoke B'
    if ($null -ne (Find-Control $script:window 'DenyApproval')) { throw 'Another thread displayed the Codex approval.' }
    Select-Thread $codex[0].title
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'The pending approval was lost after switching threads.'
    Invoke-Control 'DenyApproval'
    Wait-Until { (Latest-IsVisible 'decline') -and !(Find-Control $script:window 'Stop').Current.IsEnabled } 'The denial did not reach the fixture.'
    $checks += 'Approval remains with its thread and explicit denial reaches the subprocess'

    Send-Message 'file-approval'
    Wait-Until { $null -ne (Find-Control $script:window 'DenyApproval') } 'No file-change approval appeared.'
    $cards = Find-Control $script:window 'AgentPrompts'
    $details = $cards.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    if (!@($details | Where-Object {$_.Current.Name -like '*fixture.txt*'}).Count) { throw 'The file-change card omitted its path and diff.' }
    Invoke-Control 'DenyApproval'
    Wait-Until { !(Find-Control $script:window 'Stop').Current.IsEnabled } 'File-change denial did not finish.'
    $checks += 'File-change approval displays the proposed path and diff and requires an explicit decision'

    Send-Message 'question'
    Wait-Until { $null -ne (Find-Control $script:window 'QuestionAnswer') } 'No native question appeared.'
    $answer = Find-Control $script:window 'QuestionAnswer'
    $answer.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('fixture-ui-answer')
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

    Save-WindowEvidence
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$true; checks=$checks; dataDirectory=$data}
} catch {
    Save-WindowEvidence
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$false; checks=$checks; error=$_.Exception.Message; dataDirectory=$data}
    throw
} finally {
    if ($process -and !$process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (!$process.WaitForExit(10000)) { $process.Kill() }
    }
    $env:COINCIDE_DATA_DIR = $previousData
    $env:COINCIDE_DIAGNOSTICS_PATH = $previousDiagnostics
    # Test data was created under the results directory, never the user's normal application data.
    Remove-Item -Recurse -Force $data
}
