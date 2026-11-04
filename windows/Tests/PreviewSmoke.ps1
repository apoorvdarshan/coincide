param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\build\x64\Release\Coincide.exe'),
    [string]$Results = (Join-Path $PSScriptRoot '..\build\ui-smoke'),
    [ValidateRange(0,30)][int]$FixtureStartupDelaySeconds = 0,
    [switch]$NativePanelsOnly,
    [ValidateSet('question','credential','schedule-panel','preferences-panel','instruction-import-panel','provider-accounts-panel','voice-panel','computer-use-panel','git-panel','terminal-panel','usage-panel','credentials-panel','persona-panel')][string]$NativeSuite
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
$scheduledThread = [Guid]::NewGuid().ToString('B')
$scheduledTask = [Guid]::NewGuid().ToString('B')
$fixtureEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$due = $fixtureEpoch + 10
$threads += @{id=$scheduledThread; title='Schedule target'; project=''; provider='codex'; model=''; pinned=$false; archived=$false}
Write-JsonFile (Join-Path $data "threads\$scheduledThread.json") @{version=1; id=$scheduledThread; draft='Keep this scheduled-thread draft'; messages=@(); sessions=@()}
# An isolated, previously approved fixture task. --codex-fixture-preview forces every provider
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
# Only --codex-fixture-preview reads this clock. The real schedule store/controller/timer
# still dispatches the persisted task; cold process startup cannot consume its occurrence.
$env:COINCIDE_FIXTURE_SCHEDULE_EPOCH = [string]$fixtureEpoch
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
    if (!$NativePanelsOnly) {
    if($FixtureStartupDelaySeconds){Start-Sleep -Seconds $FixtureStartupDelaySeconds}
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
    # These suites need the real user logon session: XAML controls and Credential Manager
    # cannot be accepted from an SSH service session. Each creates and removes only owned fixtures.
    $nativeSuites=if($NativeSuite){@($NativeSuite)}else{@('question', 'credential', 'schedule-panel', 'preferences-panel', 'instruction-import-panel', 'provider-accounts-panel','voice-panel','computer-use-panel','git-panel','terminal-panel','usage-panel','credentials-panel','persona-panel')}
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
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$true; checks=$checks; dataDirectory=$data}
} catch {
    Save-WindowEvidence
    $failure=$_
    # Preserve only the owned synthetic workspace so a failed native flow remains diagnosable.
    try {if(Test-Path $data){Copy-Item $data (Join-Path $Results 'failed-fixture-data') -Recurse -Force}} catch { }
    Write-JsonFile (Join-Path $Results 'result.json') @{passed=$false; checks=$checks; error=$failure.Exception.Message; scriptStack=$failure.ScriptStackTrace; dataDirectory=$data}
    throw
} finally {
    if ($process -and !$process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (!$process.WaitForExit(10000)) { $process.Kill() }
    }
    $env:COINCIDE_DATA_DIR = $previousData
    $env:COINCIDE_DIAGNOSTICS_PATH = $previousDiagnostics
    $env:COINCIDE_FIXTURE_SCHEDULE_EPOCH = $previousFixtureEpoch
    # Test data was created under the results directory, never the user's normal application data.
    Remove-Item -Recurse -Force $data
}
