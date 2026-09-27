$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
$global:ClaudexBootstrapTestCalls = New-Object 'System.Collections.Generic.List[string]'
$global:ClaudexBootstrapTestArchive = $null
$expectedFailure = 'bootstrap fixture stopped after the checksum download'
$failure = $null

try {
    & {
        function Invoke-RestMethod {
            param([switch] $UseBasicParsing, [hashtable] $Headers, [string] $Uri, [int] $TimeoutSec)
            $global:ClaudexBootstrapTestCalls.Add("api:$Uri")
            return [pscustomobject] @{ tag_name = 'v9.8.7' }
        }

        function Invoke-WebRequest {
            param([switch] $UseBasicParsing, [hashtable] $Headers, [string] $Uri, [string] $OutFile, [int] $TimeoutSec)
            $global:ClaudexBootstrapTestCalls.Add("download:$Uri")
            if ($Uri.EndsWith('/SHA256SUMS', [StringComparison]::Ordinal)) {
                throw 'bootstrap fixture stopped after the checksum download'
            }
            $global:ClaudexBootstrapTestArchive = $OutFile
            [IO.File]::WriteAllText($OutFile, 'fixture')
        }

        & (Join-Path $root 'bootstrap.ps1')
    }
} catch {
    $failure = $_.Exception.Message
}

if ($failure -ne $expectedFailure) { throw "Windows bootstrap fixture failed unexpectedly: $failure" }
$expectedCalls = @(
    'api:https://api.github.com/repos/BeamoTech/Claudex/releases/latest',
    'download:https://github.com/BeamoTech/Claudex/releases/download/v9.8.7/claudex-9.8.7-windows.zip',
    'download:https://github.com/BeamoTech/Claudex/releases/download/v9.8.7/SHA256SUMS'
)
if ($global:ClaudexBootstrapTestCalls.Count -ne $expectedCalls.Count) {
    throw "Windows bootstrap made $($global:ClaudexBootstrapTestCalls.Count) requests, expected $($expectedCalls.Count)"
}
for ($index = 0; $index -lt $expectedCalls.Count; $index += 1) {
    if ($global:ClaudexBootstrapTestCalls[$index] -ne $expectedCalls[$index]) {
        throw "Windows bootstrap request $index was $($global:ClaudexBootstrapTestCalls[$index]), expected $($expectedCalls[$index])"
    }
}
if (-not $global:ClaudexBootstrapTestArchive -or (Test-Path -LiteralPath $global:ClaudexBootstrapTestArchive)) {
    throw 'Windows bootstrap did not clean up the interrupted download'
}

[Console]::WriteLine('Windows bootstrap release lookup and download tests passed')
Remove-Variable -Name ClaudexBootstrapTestCalls, ClaudexBootstrapTestArchive -Scope Global
