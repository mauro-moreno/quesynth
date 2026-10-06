<#
.SYNOPSIS
Render one patch of a Synth1 bank through the reference Synth1 and through
Quesynth, to compare the two by ear.

.DESCRIPTION
Picks one .sy1 file out of a bank directory and runs `s1probe compare` on that
file alone. The probe reads the file once and renders it through the reference
plugin and through this engine with the same note, velocity and timing, so the
two WAVs differ only in the instrument. The patch file itself is never changed
or copied.

Writes <name>.ref.wav (the reference), <name>.ours.wav (Quesynth) and
<name>.residual.wav (what is left when one is subtracted from the other) into
the output directory, replacing an earlier pair of the same name. A failed run
keeps nothing, so a WAV left over from an earlier run is never reported as new.

The reference plugin is Windows only, so this runs on Windows. build/s1probe.exe
and build/render.exe are built with Odin first if they are missing.

.PARAMETER Bank
The bank directory: a folder of .sy1 files, such as Synth1's soundbank00.

.PARAMETER Patch
Which patch. A number counts the bank's .sy1 files from 1, sorted by file name
-- the order tools/uibank reads a bank in, and for Synth1's own banks the number
in the file name, so 5 is 005.sy1. Anything else is a file: a bare name such as
"005.sy1" is looked up in the bank, and a path such as ".\other\lead.sy1" is used
as given, relative to the current directory. To pick a file whose name is only
digits, give it with its extension.

.PARAMETER Dll
The reference plugin. Defaults to ext/synth1/Synth1/Synth1 VST64.dll in the
repository, the probe's own default.

.PARAMETER OutDir
Where the WAVs go. Defaults to build/compare-patch in the repository; a relative
path given here is relative to the current directory. Created if missing.

.PARAMETER Note
The MIDI note to play, 0 to 127. Defaults to 60, middle C, the probe's default.

.PARAMETER Open
Open the reference and Quesynth WAVs in the default player once both exist.

.EXAMPLE
pwsh tools/compare-patch.ps1 ext/synth1/Synth1/soundbank00 5

The fifth patch of the first factory bank, 005.sy1, at middle C.

.EXAMPLE
pwsh tools/compare-patch.ps1 ext/synth1/Synth1/soundbank00 117.sy1 -Note 48 -Open

Patch 117.sy1 an octave lower, then opens both WAVs.

.EXAMPLE
pwsh tools/compare-patch.ps1 D:\banks\pads "Warm Pad.sy1" -Dll "C:\VST\Synth1 VST64.dll" -OutDir D:\listen
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Bank,
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Patch,
    [string]$Dll,
    [string]$OutDir,
    [ValidateRange(0, 127)]
    [int]$Note = 60,
    [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root "build"

# A path the user typed is relative to where they typed it; the defaults are
# relative to the repository, so the script works from any directory.
function Resolve-UserPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-Tool([string]$Name) {
    $exe = Join-Path $build "$Name.exe"
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        return $exe
    }
    $how = "To build it by hand, from the repository root: New-Item -ItemType Directory -Force build; odin build tools/$Name -out:build/$Name.exe"
    if (-not (Get-Command odin -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "$exe is missing and odin is not on PATH. Install Odin (https://odin-lang.org/docs/install/) and run this again. $how"
    }
    Write-Host "building $exe ..."
    # Odin will not create the directory it writes into, and refuses an -out
    # path with brackets in it, so it is run from that directory and given
    # only the file name.
    [IO.Directory]::CreateDirectory($build) | Out-Null
    Push-Location -LiteralPath $build
    try {
        & odin build (Join-Path (Join-Path $root "tools") $Name) "-out:$Name.exe"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Building $Name failed (odin exited with $LASTEXITCODE). $how"
    }
    return $exe
}

$bankPath = Resolve-UserPath $Bank
if (-not (Test-Path -LiteralPath $bankPath -PathType Container)) {
    throw "Bank directory not found: $bankPath"
}

if ($Patch -match '^[0-9]+$') {
    # Hidden files too (-Force): s1probe and tools/uibank read every file in a
    # bank, and a number should mean the same file whatever the platform hides.
    $names = [string[]]@(
        Get-ChildItem -LiteralPath $bankPath -File -Force |
            Where-Object { $_.Extension -ieq ".sy1" } |
            ForEach-Object { $_.Name }
    )
    if ($names.Count -eq 0) {
        throw "No .sy1 files in $bankPath"
    }
    # Ordinal, so the order does not depend on the machine's culture.
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $index = 0
    if (-not [int]::TryParse($Patch, [ref]$index) -or $index -lt 1 -or $index -gt $names.Count) {
        throw "Patch $Patch is out of range: $bankPath has $($names.Count) .sy1 files, numbered 1 to $($names.Count) by file name"
    }
    $patchPath = [IO.Path]::Combine($bankPath, $names[$index - 1])
    Write-Host "patch $index of $($names.Count): $patchPath"
} else {
    if ([IO.Path]::IsPathRooted($Patch) -or $Patch -match '[\\/]') {
        $patchPath = Resolve-UserPath $Patch
    } else {
        $patchPath = [IO.Path]::Combine($bankPath, $Patch)
    }
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw "Patch not found: $patchPath (a bare name is looked up in the bank; give a path such as .\$Patch for a file elsewhere)"
    }
    # s1probe compare reads any target not ending in .sy1 as a directory.
    if ([IO.Path]::GetExtension($patchPath) -ine ".sy1") {
        throw "Not a .sy1 file: $patchPath"
    }
    Write-Host "patch: $patchPath"
}

if ($PSBoundParameters.ContainsKey("Dll")) {
    $dllPath = Resolve-UserPath $Dll
} else {
    $dllPath = Join-Path $root "ext/synth1/Synth1/Synth1 VST64.dll"
}
# s1probe tells the plugin from the patch by its .dll extension.
if ([IO.Path]::GetExtension($dllPath) -ine ".dll") {
    throw "-Dll must name the plugin's .dll file: $dllPath"
}
if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
    throw "Reference plugin not found: $dllPath. Synth1 is not redistributed here; copy 'Synth1 VST64.dll' from your own Synth1 installation to ext/synth1/Synth1/, or pass -Dll <path>."
}

if ($PSBoundParameters.ContainsKey("OutDir")) {
    $outPath = Resolve-UserPath $OutDir
} else {
    $outPath = Join-Path $build "compare-patch"
}

$s1probe = Get-Tool "s1probe"
# Built too, so both of the repository's renderers are ready, but not used for
# the pair: tools/render plays full velocity on a hold that is not rounded to
# s1probe's blocks, so its file would not line up with the reference's.
$null = Get-Tool "render"

[IO.Directory]::CreateDirectory($outPath) | Out-Null
# The probe writes into a directory of its own, and the WAVs move out of it only
# when the run produced both. A run that fails -- or that prints an error and
# exits 0, which compare does for a patch it cannot read -- leaves the output
# directory as it was.
$stage = Join-Path $outPath (".compare-" + [guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    & $s1probe compare $dllPath $patchPath --wav $stage --note $Note
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "s1probe compare exited with code $code; no WAVs were kept. Some arpeggiator patches crash the reference itself (see docs/null-test.md)."
    }
    # The probe's own naming: the file name up to its last dot, unless that dot
    # is the first character, so ".sy1" writes ".sy1.ref.wav".
    $stem = [IO.Path]::GetFileName($patchPath)
    if ($stem.LastIndexOf(".") -gt 0) {
        $stem = $stem.Substring(0, $stem.LastIndexOf("."))
    }
    $written = [ordered]@{}
    foreach ($kind in "ref", "ours", "residual") {
        $file = Join-Path $stage "$stem.$kind.wav"
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $written[$kind] = $file
        }
    }
    foreach ($kind in "ref", "ours") {
        if (-not $written.Contains($kind) -or (Get-Item -LiteralPath $written[$kind] -Force).Length -eq 0) {
            throw "s1probe compare did not write $stem.$kind.wav; see its output above. No WAVs were kept."
        }
    }
    # A player opened by an earlier -Open can still hold the old pair. Checked
    # before anything moves, the way tools/build-clap.ps1 checks the plugin, so
    # a locked file cannot leave a new reference beside an old Quesynth render.
    foreach ($kind in $written.Keys) {
        $target = Join-Path $outPath "$stem.$kind.wav"
        if (Test-Path -LiteralPath $target) {
            try {
                [IO.File]::Open($target, "Open", "ReadWrite", "None").Close()
            } catch {
                throw "$target is open in another program; close it and run this again. No WAVs were replaced."
            }
        }
    }
    $final = [ordered]@{}
    foreach ($kind in $written.Keys) {
        $target = Join-Path $outPath "$stem.$kind.wav"
        if (Test-Path -LiteralPath $target) {
            [IO.File]::Delete($target)
        }
        [IO.File]::Move($written[$kind], $target)
        $final[$kind] = $target
    }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "reference: $($final['ref'])"
Write-Host "quesynth:  $($final['ours'])"
if ($final.Contains("residual")) {
    Write-Host "residual:  $($final['residual'])"
}

if ($Open) {
    try {
        Invoke-Item -LiteralPath $final["ref"], $final["ours"]
    } catch {
        throw "The WAVs were written, but opening them failed: $($_.Exception.Message)"
    }
}
