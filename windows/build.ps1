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

if (!$CoreOnly) {
    & $msbuild (Join-Path $root 'App\Coincide.vcxproj') /restore /m /verbosity:minimal "/p:Configuration=$Configuration" "/p:Platform=$Architecture"
    if ($LASTEXITCODE) { throw 'The WinUI application build failed.' }
    $executable = Join-Path $root "build\$Architecture\$Configuration\Coincide.exe"
    if (!(Test-Path $executable)) { throw 'MSBuild returned successfully but no Windows application was produced.' }
    Write-Output "Built: $executable"
    if ($Architecture -eq 'x64') {
        $report = Join-Path $root 'build\store-test-result.txt'
        Remove-Item $report -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $executable -ArgumentList @('--store-tests', "`"$report`"") -PassThru
        if (!$process.WaitForExit(60000)) { $process.Kill(); throw 'Windows store tests timed out.' }
        if (Test-Path $report) { Get-Content $report }
        if ($process.ExitCode -ne 0 -or !(Test-Path $report)) { throw 'Windows store tests failed.' }
    }
}
