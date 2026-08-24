param(
    [string]$SharedBank = "patches/shared",
    [string]$S1Probe = "build/s1probe.exe",
    [string]$Out = "build/unison-gate"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $SharedBank)) {
    throw "Shared bank not found: $SharedBank"
}
if (-not (Test-Path $S1Probe)) {
    throw "Build s1probe first: $S1Probe"
}

function Value([string[]]$Lines, [int]$Index, [int]$Default = 0) {
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
        } else { $line }
    }
    if (-not $seen) { $out += "$Index,$Value" }
    return $out
}

$active = Get-ChildItem $SharedBank -Recurse -File -Filter *.sy1 | Where-Object {
    $lines = Get-Content $_.FullName
    (Value $lines 95) -ge 32 -and (Value $lines 73) -ne 0
}
if ($active.Count -eq 0) { throw "No patches with parameter 95 >= 32 and unison enabled were found" }

$on = Join-Path $Out "on"
$off = Join-Path $Out "unison-off"
New-Item -ItemType Directory -Force $on, $off | Out-Null
foreach ($file in $active) {
    $relative = [IO.Path]::GetRelativePath((Resolve-Path $SharedBank), $file.FullName)
    foreach ($dir in @($on, $off)) {
        $target = Join-Path $dir $relative
        New-Item -ItemType Directory -Force ([IO.Path]::GetDirectoryName($target)) | Out-Null
        $lines = Get-Content $file.FullName
        if ($dir -eq $off) { $lines = Set-Value $lines 73 0 }
        Set-Content -Encoding ascii $target $lines
    }
}

& $S1Probe compare $on --csv (Join-Path $Out "on.csv")
& $S1Probe summarise (Join-Path $Out "on.csv")
& $S1Probe compare $off --csv (Join-Path $Out "off.csv")
& $S1Probe summarise (Join-Path $Out "off.csv")
Write-Host "Selected $($active.Count) shared-bank patches; on and unison-off controls are in $Out"
