param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64',
    [switch]$CoreOnly
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) { throw 'Install Visual Studio C++ Build Tools, including a Windows 11 SDK, before building.' }
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'No Visual Studio installation with C++ tools was found.' }
$msbuild = Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
$cmake = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (!(Test-Path $cmake)) {
    $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if (!$command) { throw 'CMake is required for the core tests. Add the C++ CMake tools component.' }
    $cmake = $command.Source
}

# Always execute tests rather than reusing a previous test result. A native test binary runs on x64.
$coreBuild = Join-Path $root 'build\core-x64'
& $cmake -S $root -B $coreBuild -A x64
if ($LASTEXITCODE) { throw 'Core test configuration failed.' }
& $cmake --build $coreBuild --config $Configuration
if ($LASTEXITCODE) { throw 'Core test build failed.' }
& (Join-Path $coreBuild "$Configuration\CoincideWorkspaceTests.exe")
if ($LASTEXITCODE) { throw 'Core tests failed.' }
& (Join-Path $coreBuild "$Configuration\CoincideMarkdownTests.exe")
if ($LASTEXITCODE) { throw 'Markdown tests failed.' }
& (Join-Path $coreBuild "$Configuration\CoincideHandoffTests.exe")
if ($LASTEXITCODE) { throw 'Handoff tests failed.' }
& (Join-Path $coreBuild "$Configuration\CoincideTerminalScreenTests.exe")
if ($LASTEXITCODE) { throw 'Terminal screen tests failed.' }
& (Join-Path $coreBuild "$Configuration\CoincideSchedulerTests.exe")
if ($LASTEXITCODE) { throw 'Scheduler tests failed.' }

if (!$CoreOnly) {
    & $msbuild (Join-Path $root 'App\Coincide.vcxproj') /restore /m /verbosity:minimal "/p:Configuration=$Configuration" "/p:Platform=$Architecture"
    if ($LASTEXITCODE) { throw 'The WinUI application build failed.' }
    $executable = Join-Path $root "build\$Architecture\$Configuration\Coincide.exe"
    if (!(Test-Path $executable)) { throw 'MSBuild returned successfully but no Windows application was produced.' }
    $notices=Join-Path (Split-Path $executable) 'Notices'
    New-Item -ItemType Directory -Force $notices | Out-Null
    Copy-Item (Join-Path $root '..\LICENSE') (Join-Path $notices 'Coincide-LICENSE.txt')
    Copy-Item (Join-Path $root 'Notices\T3-Code-LICENSE.txt') $notices
    Write-Output "Built: $executable"
    if ($Architecture -eq 'x64') {
        foreach ($suite in @('store', 'protocol', 'connection', 'session', 'display', 'git', 'provider', 'claude', 'terminal', 'calendar', 'opencode', 'browser', 'preview', 'schedule', 'acp', 'preferences', 'desktop-services', 'instructions', 'imports', 'import-store', 'provider-accounts', 'notifications', 'voice-settings', 'computer-use', 'computer-use-settings', 'git-management', 'tool-context', 'app-tool-bridge', 'schedule-tool', 'usage', 'usage-runtime', 'browser-credential', 'bot', 'bot-workspace', 'host-persistence')) {
            $report = Join-Path $root "build\$suite-test-result.txt"
            Remove-Item $report -ErrorAction SilentlyContinue
            $process = Start-Process -FilePath $executable -ArgumentList @("--$suite-tests", "`"$report`"") -PassThru
            if (!$process.WaitForExit(60000)) { $process.Kill(); throw "Windows $suite tests timed out." }
            if (Test-Path $report) { Get-Content $report }
            if ($process.ExitCode -ne 0 -or !(Test-Path $report)) { throw "Windows $suite tests failed." }
        }
        $report=Join-Path $root 'build\voice-test-result.txt'
        Remove-Item $report -ErrorAction SilentlyContinue
        $fixture=Join-Path $coreBuild "$Configuration\CoincideVoiceFixture.exe"
        $process=Start-Process -FilePath $executable -ArgumentList @('--voice-tests', "`"$report`"", "`"$fixture`"") -PassThru
        if(!$process.WaitForExit(30000)){$process.Kill();throw 'Windows voice fixture timed out.'}
        if(Test-Path $report){Get-Content $report}
        if($process.ExitCode -ne 0 -or !(Test-Path $report)){throw 'Windows offline voice tests failed.'}
        $report=Join-Path $root 'build\computer-use-process-test-result.txt'
        Remove-Item $report -ErrorAction SilentlyContinue
        $fixture=Join-Path $coreBuild "$Configuration\CoincideComputerUseFixture.exe"
        $process=Start-Process -FilePath $executable -ArgumentList @('--computer-use-process-tests', "`"$report`"", "`"$fixture`"") -PassThru
        if(!$process.WaitForExit(30000)){$process.Kill();throw 'Windows Computer Use IPC fixture timed out.'}
        if(Test-Path $report){Get-Content $report}
        if($process.ExitCode -ne 0 -or !(Test-Path $report)){throw 'Windows Computer Use IPC tests failed.'}
        $report=Join-Path $root 'build\computer-use-desktop-lease-test-result.txt'
        Remove-Item $report -ErrorAction SilentlyContinue
        $process=Start-Process -FilePath $executable -ArgumentList @('--computer-use-desktop-lease-tests', "`"$report`"", "`"$fixture`"") -PassThru
        if(!$process.WaitForExit(30000)){$process.Kill();throw 'Windows Computer Use shared lease fixture timed out.'}
        if(Test-Path $report){Get-Content $report}
        if($process.ExitCode -ne 0 -or !(Test-Path $report)){throw 'Windows Computer Use shared lease tests failed.'}
    }
}
