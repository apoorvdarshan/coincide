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
$env:COINCIDE_DATA_DIR = $data
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

try {
    $process = Start-Process -FilePath $Executable -PassThru
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

    $rect = New-Object CoincideSmokeWindow+Rect
    if (![CoincideSmokeWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) { throw 'Cannot locate the preview window.' }
    $bitmap = New-Object Drawing.Bitmap(($rect.Right-$rect.Left), ($rect.Bottom-$rect.Top))
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path $Results 'preview.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$true; checks=$checks; dataDirectory=$data}
} catch {
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$false; checks=$checks; error=$_.Exception.Message; dataDirectory=$data}
    throw
} finally {
    if ($process -and !$process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (!$process.WaitForExit(10000)) { $process.Kill() }
    }
    $env:COINCIDE_DATA_DIR = $previousData
    # Test data was created under the results directory, never the user's normal application data.
    Remove-Item -Recurse -Force $data
}
