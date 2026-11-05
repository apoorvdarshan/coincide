param(
    [string]$Report = (Join-Path $PSScriptRoot '..\build\prepared-host-guard-test-result.txt'),
    [int]$ExpectedMajor = 0
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$checks = 0
$fixture = $null
$fixtureOwned = $false
$ledger = $null
$pins = $null
$failure = $null
$utf8 = New-Object Text.UTF8Encoding($false)
function Check([bool]$Value, [string]$Reason) {
    $script:checks++
    if (!$Value) { throw $Reason }
}
function Reject([scriptblock]$Action, [string]$Reason) {
    $rejected = $false
    try { $value = & $Action; foreach ($entry in $value) { if ($entry -is [IDisposable]) { $entry.Dispose() } } } catch { $rejected = $true }
    Check $rejected $Reason
}
try {
    if ($ExpectedMajor -ne 0) { Check ($PSVersionTable.PSVersion.Major -eq $ExpectedMajor) 'The requested PowerShell runtime must execute this fixture.' }
    # Only this fixture's freshly created GUID directories receive ACL changes.
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class PreparedHostAclFixture {
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text,uint revision,out IntPtr value,out uint size);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool SetFileSecurity(string path,uint info,IntPtr descriptor);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool GetSecurityDescriptorOwner(IntPtr descriptor,out IntPtr owner,out bool defaulted);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] private static extern uint GetNamedSecurityInfo(string path,uint type,uint requested,out IntPtr owner,out IntPtr group,out IntPtr dacl,out IntPtr sacl,out IntPtr descriptor);
    [DllImport("advapi32.dll",SetLastError=true)] private static extern bool GetAce(IntPtr acl,uint index,out IntPtr ace);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr value);
    public static void Set(string path,string sddl) {
        IntPtr descriptor;uint size;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out descriptor,out size))throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr owner;bool defaulted;
            if(!GetSecurityDescriptorOwner(descriptor,out owner,out defaulted))throw new Win32Exception(Marshal.GetLastWin32Error());
            uint requested=0x80000004u;if(owner!=IntPtr.Zero)requested|=1;
            if(!SetFileSecurity(path,requested,descriptor))throw new Win32Exception(Marshal.GetLastWin32Error());
        }finally{LocalFree(descriptor);}
    }
    public static bool HasSingleInheritedAllow(string path) {
        IntPtr owner,group,dacl,sacl,descriptor;
        var status=GetNamedSecurityInfo(path,1,4,out owner,out group,out dacl,out sacl,out descriptor);
        try {
            IntPtr ace;
            if(status!=0)throw new Win32Exception((int)status);
            return dacl!=IntPtr.Zero&&(ushort)Marshal.ReadInt16(dacl,4)==1&&GetAce(dacl,0,out ace)&&ace!=IntPtr.Zero&&Marshal.ReadByte(ace)==0&&(Marshal.ReadByte(ace,1)&0x10)!=0;
        }finally{if(descriptor!=IntPtr.Zero)LocalFree(descriptor);}
    }
}
'@
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $privateAcl = 'O:' + $sid.Value + 'D:P(A;OICI;FA;;;' + $sid.Value + ')'
    foreach ($spec in @(@('PreviewSmoke.ps1', 'CoincideSmokeWindow'), @('HostedRecoverySmoke.ps1', 'HostedRecoveryNative'))) {
        $scriptPath = Join-Path $PSScriptRoot $spec[0]
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        Check ($errors.Count -eq 0) ($spec[0] + ' must parse completely under this PowerShell runtime.')
        $source = [IO.File]::ReadAllText($scriptPath)
        $code = [regex]::Match($source, "(?s)Add-Type @'\r?\n(.*?)\r?\n'@").Groups[1].Value
        Check (![string]::IsNullOrEmpty($code)) 'The exact embedded native helper must be present.'
        # Compile actual script source. Never dot-source or run either UI harness.
        Add-Type -TypeDefinition $code
        $native = $spec[1] -as [type]
        Check ($null -ne $native) 'The actual embedded C# helper must compile.'
        $temporary = $native::PhysicalDirectory([IO.Path]::GetTempPath())
        $fixture = Join-Path $temporary ('Coincide-Host-Connection-' + [Guid]::NewGuid().ToString('D'))
        $fixtureOwned = $false
        New-Item -ItemType Directory -Path $fixture -ErrorAction Stop | Out-Null
        $fixtureOwned = $true
        $marker = Join-Path $fixture 'synthetic-connection-fixture.txt'
        $markerText = 'COINCIDE_SYNTHETIC_HOST_CONNECTION' + [char]10
        [IO.File]::WriteAllText($marker, $markerText, $utf8)
        $ledger = Join-Path $fixture 'agent-host-windows'
        New-Item -ItemType Directory -Path $ledger -ErrorAction Stop | Out-Null
        [PreparedHostAclFixture]::Set($ledger, $privateAcl)
        $ownerPath = Join-Path $ledger 'host.lock'
        $runtimePath = Join-Path $ledger 'runtime.json'
        [IO.File]::WriteAllText($ownerPath, '{"pid":1,"scope":"synthetic-guard-only"}', $utf8)
        $pins = $native::PinPreparedHostedData($fixture)
        Check ($pins.Count -eq 4) 'A known empty private host must pin root, marker, ledger and ownership metadata.'
        Reject { Move-Item -LiteralPath $fixture -Destination ($fixture + '-moved') -ErrorAction Stop } 'The retained root pin must reject rename.'
        Reject { Move-Item -LiteralPath $ledger -Destination ($ledger + '-moved') -ErrorAction Stop } 'The retained ledger pin must reject rename.'
        foreach ($pin in $pins) { $pin.Dispose() }; $pins = $null
        [IO.File]::WriteAllText($runtimePath, '{}', $utf8)
        $pins = $native::PinPreparedHostedData($fixture)
        Check ($pins.Count -eq 4) 'A bounded replaceable ledger must not add a persistent file pin.'
        Move-Item -LiteralPath $runtimePath -Destination ($runtimePath + '.old') -ErrorAction Stop
        [IO.File]::WriteAllText($runtimePath, '{}', $utf8)
        Remove-Item -LiteralPath ($runtimePath + '.old') -ErrorAction Stop
        Check ([IO.File]::ReadAllText($runtimePath) -ceq '{}') 'Host runtime metadata must remain replaceable while directory pins are held.'
        foreach ($pin in $pins) { $pin.Dispose() }; $pins = $null
        foreach ($name in @('workspace.json', 'threads', 'hosted-client-state-windows', 'unexpected.txt')) {
            $unknown = Join-Path $fixture $name
            [IO.File]::WriteAllText($unknown, 'untouched synthetic sentinel', $utf8)
            Reject { $native::PinPreparedHostedData($fixture) } ('Prepared data must reject ' + $name + '.')
            Check ([IO.File]::ReadAllText($unknown) -ceq 'untouched synthetic sentinel') 'Refusal must preserve unknown data.'
            Remove-Item -LiteralPath $unknown -ErrorAction Stop
        }
        [IO.File]::WriteAllText($marker, 'wrong marker', $utf8)
        Reject { $native::PinPreparedHostedData($fixture) } 'A wrong fixture marker must be refused.'
        [IO.File]::WriteAllText($marker, $markerText, $utf8)
        $unknown = Join-Path $ledger 'unknown.tmp'; [IO.File]::WriteAllText($unknown, 'owned', $utf8)
        Reject { $native::PinPreparedHostedData($fixture) } 'Unknown private host files must be refused.'
        Remove-Item -LiteralPath $unknown -ErrorAction Stop
        [IO.File]::WriteAllText($runtimePath, ('x' * 16385), $utf8)
        Reject { $native::PinPreparedHostedData($fixture) } 'Oversized runtime metadata must be refused.'
        [IO.File]::WriteAllText($runtimePath, '{}', $utf8)
        [IO.File]::WriteAllText($ownerPath, ('x' * 4097), $utf8)
        Reject { $native::PinPreparedHostedData($fixture) } 'Oversized ownership metadata must be refused.'
        [IO.File]::WriteAllText($ownerPath, '{}', $utf8)
        foreach ($case in @(
            @('null DACL', 'D:NO_ACCESS_CONTROL'),
            @('empty DACL', 'D:P'),
            @('extra Allow ACE', ('D:P(A;OICI;FA;;;' + $sid.Value + ')(A;;FR;;;WD)')),
            @('Deny ACE', ('D:P(D;;0x2;;;' + $sid.Value + ')(A;OICI;FA;;;' + $sid.Value + ')')),
            @('wrong Allow SID', 'D:P(A;OICI;FA;;;WD)'),
            @('inherited Allow ACE', ('D:P(A;OICIID;FA;;;' + $sid.Value + ')'))
        )) {
            [PreparedHostAclFixture]::Set($ledger, $case[1])
            if ($case[0] -ceq 'inherited Allow ACE') { Check ([PreparedHostAclFixture]::HasSingleInheritedAllow($ledger)) 'The negative fixture must actually contain one native inherited Allow ACE.' }
            Reject { $native::PinPreparedHostedData($fixture) } ('Prepared host must refuse ' + $case[0] + '.')
            [PreparedHostAclFixture]::Set($ledger, $privateAcl)
        }
        $invalid = New-Object Microsoft.Win32.SafeHandles.SafeFileHandle([IntPtr]::Zero, $false)
        $method = $native.GetMethod('RequirePrivatePreparedAcl', ([Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static))
        Check ($null -ne $method) 'The actual pinned ACL guard must be present.'
        Reject { $method.Invoke($null, @($invalid)) } 'Unavailable pinned security information must fail closed.'
        $invalid.Dispose()
        $nested = Join-Path $fixture ('Coincide-Host-Connection-' + [Guid]::NewGuid().ToString('D'))
        New-Item -ItemType Directory -Path $nested -ErrorAction Stop | Out-Null
        Reject { $native::PinPreparedHostedData($nested) } 'Only immediate physical TEMP children may be prepared.'
        Remove-Item -LiteralPath $nested -ErrorAction Stop
        $pins = $native::PinPreparedHostedData($fixture)
        Check ($pins.Count -eq 4 -and [IO.File]::ReadAllText($marker) -ceq $markerText) 'A valid private fixture must remain intact after all refusals.'
        foreach ($pin in $pins) { $pin.Dispose() }; $pins = $null
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
        $fixture = $null; $ledger = $null; $fixtureOwned = $false
    }
} catch { $failure = $_.Exception.Message }
finally {
    try {
        if ($pins) { foreach ($pin in $pins) { $pin.Dispose() } }
        if ($fixtureOwned -and $fixture -and [IO.Directory]::Exists($fixture)) {
            if ($ledger -and [IO.Directory]::Exists($ledger)) { [PreparedHostAclFixture]::Set($ledger, $privateAcl) }
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
        }
    } catch { $failure = $failure + '; owned fixture cleanup failed: ' + $_.Exception.Message }
}
$Report = [IO.Path]::GetFullPath($Report)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Report)) | Out-Null
$prefix = if ($failure) { 'FAIL after ' } else { 'PASS: ' }
$result = $prefix + $checks + ' prepared-host filesystem/ACL checks; PowerShell ' + $PSVersionTable.PSVersion + '; no UI, process, provider or network launched'
if ($failure) { $result += '; ' + $failure }
[IO.File]::WriteAllText($Report, ($result + [Environment]::NewLine), $utf8)
Write-Output $result
if ($failure) { exit 1 }
