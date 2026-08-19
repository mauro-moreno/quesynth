# Install the VST3 plugin locally, for working on it.
#
# This is a convenience for a development machine and nothing more: it calls
# `tools/build-vst3.ps1` to assemble the bundle and then copies it into a VST3
# folder. What a *release* ships is the same bundle zipped -- see
# .github/workflows/release.yml -- so nothing anybody downloads has been through
# a path this script alone knows about.
#
# Usage:
#   pwsh tools/install-vst3.ps1                       -> D:\VST\VST 3
#   pwsh tools/install-vst3.ps1 -Destination <path>

param(
    [string]$Destination = "D:\VST\VST 3"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$name = "Quesynth"

$staging = Join-Path $root "build\vst3"
& (Join-Path $PSScriptRoot "build-vst3.ps1") -Output $staging
if ($LASTEXITCODE -ne 0) { throw "the build failed" }

$source = Join-Path $staging "$name.vst3"
$target = Join-Path $Destination "$name.vst3"

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# Replaced rather than merged, for the reason the build script empties its own
# panel directory: copying over an existing install leaves whatever an earlier
# version of it put there, and the installed plugin stops matching the tree it
# was built from.
if (Test-Path $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
Copy-Item -Path $source -Destination $target -Recurse -Force

Write-Host "installed to $target"
