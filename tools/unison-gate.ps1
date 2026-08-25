# Reproduce the shared-bank unison gate and its unison-off control.
#
# The selection stays identical to the original gate: every patch under the
# supplied tree with parameter 95 >= 32 and parameter 73 enabled. The copied
# files are flat because `s1probe compare` reads only one directory level.
#
#     odin build tools/s1probe -out:build/s1probe.exe
#     pwsh tools/unison-gate.ps1 -SharedBank path/to/shared-banks
param(
    [string]$SharedBank = "patches/shared",
    [string]$S1Probe = "build/s1probe.exe",
    [string]$Out = "build/unison-gate"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SharedBank)) {
    throw "Shared bank not found: $SharedBank"
}
if (-not (Test-Path -LiteralPath $S1Probe)) {
    throw "Build s1probe first: $S1Probe"
}

function Get-Value([string[]]$Lines, [int]$Index, [int]$Default = 0) {
    $line = $Lines | Where-Object { $_ -match "^$Index,(-?\d+)$" } | Select-Object -First 1
    if ($null -eq $line) { return $Default }
    return [int](($line -split ",", 2)[1])
}

function Set-Value([string[]]$Lines, [int]$Index, [int]$Value) {
    $seen = $false
    $out = foreach ($line in $Lines) {
        if ($line -match "^$Index,-?\d+$") {
            $seen = $true
            "$Index,$Value"
        } else {
            $line
        }
    }
    if (-not $seen) { $out += "$Index,$Value" }
    return @($out)
}

function Invoke-S1Probe([string[]]$Arguments) {
    & $S1Probe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "s1probe $($Arguments -join ' ') exited with code $LASTEXITCODE"
    }
}

# Wrap the pipeline in @(...), since PowerShell otherwise turns a one-item
# result into a scalar and `$active.Count` fails under strict mode.
$active = @(
    Get-ChildItem -LiteralPath $SharedBank -Recurse -File -Filter *.sy1 |
        Sort-Object FullName |
        Where-Object {
            $lines = [IO.File]::ReadAllLines($_.FullName)
            (Get-Value $lines 95) -ge 32 -and (Get-Value $lines 73) -ne 0
        }
)
if ($active.Count -eq 0) {
    throw "No patches with parameter 95 >= 32 and unison enabled were found"
}

if (Test-Path -LiteralPath $Out) {
    Remove-Item -LiteralPath $Out -Recurse -Force
}
$on = Join-Path $Out "on"
$off = Join-Path $Out "unison-off"
New-Item -ItemType Directory -Force -Path $on, $off | Out-Null

$index = [Collections.Generic.List[string]]::new()
$index.Add("name,path")
for ($i = 0; $i -lt $active.Count; $i++) {
    $file = $active[$i]
    $lines = [IO.File]::ReadAllLines($file.FullName)
    $name = "u{0:D3}.sy1" -f $i
    Set-Content -LiteralPath (Join-Path $on $name) -Encoding ascii -Value $lines
    Set-Content -LiteralPath (Join-Path $off $name) -Encoding ascii -Value (Set-Value $lines 73 0)
    $index.Add("$name,`"$($file.FullName)`"")
}
Set-Content -LiteralPath (Join-Path $Out "index.csv") -Encoding ascii -Value $index

$onCsv = Join-Path $Out "on.csv"
$offCsv = Join-Path $Out "unison-off.csv"
Invoke-S1Probe @("compare", $on, "--csv", $onCsv)
Invoke-S1Probe @("summarise", $onCsv)
Invoke-S1Probe @("compare", $off, "--csv", $offCsv)
Invoke-S1Probe @("summarise", $offCsv)
Write-Host "Selected $($active.Count) shared-bank patches"
Write-Host "unison on: $onCsv"
Write-Host "unison off control: $offCsv"
