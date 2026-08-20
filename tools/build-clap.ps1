# Assemble the CLAP plugin, with its interface, into a directory.
#
# The same shape as tools/build-vst3.ps1 and for the same reasons -- it builds,
# it does not install, and the release workflow calls this and zips the result
# so what people download is what was tested locally.
#
# The layout is not a bundle, because a CLAP plugin on Windows is a single file
# with nothing inside it:
#
#   Quesynth.clap         the plugin
#   WebView2Loader.dll    found by module path, beside the plugin
#   Quesynth-ui/          the panel
#
# hosts/clap/gui.odin looks for those two beside its own module, so the three
# have to travel together. A .clap on its own still loads and plays; it just
# shows the host's generic controls instead of its own panel, which is the same
# bargain the VST3 build makes when its Resources folder is missing.
#
# Usage:
#   pwsh tools/build-clap.ps1 -Output build/clap-stage

param(
    [string]$Output = "build/clap-stage"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$name = "Quesynth"

$stage = Join-Path $root $Output
$uiDir = Join-Path $stage "$name-ui"

New-Item -ItemType Directory -Force -Path $stage, $uiDir | Out-Null

# Emptied rather than copied over, for the reason the VST3 script gives: a
# script that only ever adds files goes on shipping one that has since been
# renamed, and the result stops matching the tree it was built from.
Get-ChildItem -Path $uiDir -Force | Remove-Item -Recurse -Force

$plugin = Join-Path $stage "$name.clap"

# A DAW holds the plugin open for as long as it has it loaded, and the link step
# then fails with LNK1104, which reads like a broken build rather than an open
# window.
if (Test-Path $plugin) {
    try {
        $handle = [System.IO.File]::Open($plugin, 'Open', 'Write', 'None')
        $handle.Close()
    } catch {
        throw "$plugin is locked -- close the host and run this again."
    }
}

Write-Host "building the plugin..."

# -o:speed is not optional for an instrument; see the note in build-vst3.ps1.
& odin build (Join-Path $root "hosts\clap") -build-mode:dll -target:windows_amd64 -o:speed -out:"$plugin"
if ($LASTEXITCODE -ne 0) { throw "odin build failed" }

Remove-Item (Join-Path $stage "$name.lib"), (Join-Path $stage "$name.exp") -Force -ErrorAction SilentlyContinue

Copy-Item (Join-Path $root "ext\webview2\x64\WebView2Loader.dll") $stage -Force

# The panel. The same list the VST3 build copies, and not host.js or store.js --
# in a plugin the host owns the audio and the host owns persistence. See the
# note in build-vst3.ps1.
$panel = @(
    "index.html", "style.css",
    "app.js", "bridge.js", "layout.js", "midi.js", "params.js",
    "patchfile.js", "sy1.js", "modal.js", "browser.js",
    "midimap.js", "options.js"
)
foreach ($file in $panel) {
    Copy-Item (Join-Path $root "ui\$file") $uiDir -Force
}

# The patch bank, generated rather than committed; see build-vst3.ps1.
$factory = Join-Path $root "patches\quesynth\factory.json"
if (Test-Path $factory) {
    & odin run (Join-Path $root "tools\uibank") -out:(Join-Path $root "build\uibank.exe") -- $factory | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not generate the patch bank" }
}
$bank = Join-Path $root "ui\bank.js"
if (Test-Path $bank) {
    Copy-Item $bank $uiDir -Force
} else {
    Write-Host "  no patch bank; the panel will be empty"
}

Write-Host "assembled $stage"
