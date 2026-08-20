# Install the CLAP plugin locally, for working on it.
#
# The counterpart to tools/install-vst3.ps1: a convenience for a development
# machine and nothing more. It calls tools/build-clap.ps1 to assemble the plugin
# and then copies it into a CLAP folder. What a *release* ships is the same
# thing zipped, so nothing anybody downloads has been through a path this script
# alone knows about.
#
# One difference from the VST3 installer, and it matters.
#
# A VST3 install is a single self-contained folder -- Quesynth.vst3 -- so that
# installer deletes it and copies a fresh one. A CLAP install is not: the plugin
# is a bare file sharing its directory with every other CLAP on the machine, and
# the panel sits beside it. So this replaces the three things it owns and leaves
# everything else alone. Emptying the destination the way the VST3 script empties
# its bundle would delete somebody else's plugins.
#
# Usage:
#   pwsh tools/install-clap.ps1                       -> D:\VST\CLAP
#   pwsh tools/install-clap.ps1 -Destination <path>

param(
    [string]$Destination = "D:\VST\CLAP"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$name = "Quesynth"

$staging = Join-Path $root "build\clap"
& (Join-Path $PSScriptRoot "build-clap.ps1") -Output $staging
if ($LASTEXITCODE -ne 0) { throw "the build failed" }

$stage = $staging

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# The plugin and the loader: overwritten in place. WebView2Loader.dll is the
# same file every plugin using a web view ships, so replacing it is harmless
# and leaving an older one behind is not.
foreach ($file in @("$name.clap", "WebView2Loader.dll")) {
    $source = Join-Path $stage $file
    if (Test-Path $source) {
        Copy-Item -Path $source -Destination (Join-Path $Destination $file) -Force
    }
}

# The panel, replaced rather than merged: a file that has since been renamed or
# moved out would otherwise go on being loaded, and the installed plugin would
# stop matching the tree it was built from. Only this one directory is removed,
# and it is one this project created.
$uiSource = Join-Path $stage "$name-ui"
$uiTarget = Join-Path $Destination "$name-ui"
if (Test-Path $uiTarget) {
    Remove-Item -LiteralPath $uiTarget -Recurse -Force
}
Copy-Item -Path $uiSource -Destination $uiTarget -Recurse -Force

Write-Host "installed to $Destination"
