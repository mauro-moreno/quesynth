# Builds the VST3 plugin and assembles it as a bundle.
#
# A bundle rather than a bare .vst3 file, because the plugin is no longer only
# a binary: the editor is the interface in ui/, and the WebView2 loader has to
# sit beside the DLL where the plugin can find it by module path. The layout is
# the one the VST3 specification defines for Windows, and hosts/vst3/editor.odin
# navigates it relative to its own module:
#
#   Quesynth.vst3/
#     Contents/
#       x86_64-win/
#         Quesynth.vst3       the DLL itself
#         WebView2Loader.dll  found by module path, not by search order
#       Resources/
#         ui/                 the panel, served from a virtual host
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

$bundle = Join-Path $Destination "$name.vst3"
$binDir = Join-Path $bundle "Contents\x86_64-win"
$resDir = Join-Path $bundle "Contents\Resources"
$uiDir = Join-Path $resDir "ui"

# Before the editor existed the plugin was a single DLL at exactly this path.
# A directory cannot take the place of a file, so the old install is removed
# rather than left to fail the copy with something unhelpful.
if ((Test-Path $bundle) -and -not (Test-Path $bundle -PathType Container)) {
    Write-Host "replacing the single-file install at $bundle"
    Remove-Item -LiteralPath $bundle -Force
}

New-Item -ItemType Directory -Force -Path $binDir, $uiDir | Out-Null

# Emptied rather than copied over. A script that only ever adds files leaves
# whatever an earlier version of it installed: a panel file that has since been
# renamed or moved out to another host goes on being shipped, and the bundle
# stops matching the tree it was built from. This directory is assembled here
# and holds nothing else, so clearing it loses nothing.
Get-ChildItem -Path $uiDir -Force | Remove-Item -Recurse -Force

Write-Host "building..."
$dll = Join-Path $binDir "$name.vst3"

# A DAW holds the plugin open for as long as it has it loaded, and the link
# step then fails with LNK1104, which reads like a broken build rather than an
# open window. Asked of the file itself rather than of the process list: what
# matters is whether *this* binary is locked, not whether some host happens to
# be running with a different plugin loaded.
if (Test-Path $dll) {
    try {
        $handle = [System.IO.File]::Open($dll, 'Open', 'Write', 'None')
        $handle.Close()
    } catch {
        $hosts = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Ableton|reaper|Cubase|FL64|Bitwig|Studio One' } |
            Select-Object -ExpandProperty Name -Unique
        $who = if ($hosts) { " (" + ($hosts -join ", ") + " is running)" } else { "" }
        throw "$dll is locked$who -- close the host and run this again."
    }
}
# -o:speed is not optional for an instrument. Odin optimises minimally by
# default, and the engine measures 3.1x slower without it -- 13% of a core for
# sixteen voices instead of 41%. The difference it makes to the *output* is
# floating-point reassociation about 150 dB down, which is below 24-bit
# resolution and far below anything the null test can see.
& odin build (Join-Path $root "hosts\vst3") -build-mode:dll -target:windows_amd64 -o:speed -out:"$dll"
if ($LASTEXITCODE -ne 0) { throw "odin build failed" }

# The linker leaves an import library and an exports file beside the DLL. They
# are build output, not part of the plugin, and a host scanning the folder has
# no reason to see them.
Remove-Item (Join-Path $binDir "$name.lib"), (Join-Path $binDir "$name.exp") -Force -ErrorAction SilentlyContinue

Copy-Item (Join-Path $root "ext\webview2\x64\WebView2Loader.dll") $binDir -Force

# The whole panel, which is now all ui/ holds: the WebAssembly engine and its
# glue live in hosts/wasm and belong to that host, not to this one.
#
# Note what is *not* copied: host.js. index.html asks for it with an onerror
# guard, and a native host has no page-side glue to load -- the bridge is on
# this side of the wall, in editor.odin. Shipping the browser host's file here
# would be shipping a second engine that must never start.
$panel = @(
    "index.html", "style.css",
    "app.js", "bridge.js", "layout.js", "midi.js", "params.js"
)
foreach ($file in $panel) {
    Copy-Item (Join-Path $root "ui\$file") $uiDir -Force
}

# The patch bank, if this checkout has one built. It is optional by design --
# index.html loads it with an onerror guard -- because it is generated from
# Synth1's own factory banks and is not part of this repository.
$bank = Join-Path $root "ui\bank.js"
if (Test-Path $bank) {
    Copy-Item $bank $uiDir -Force
    Write-Host "  bank.js included"
} else {
    Write-Host "  bank.js absent, the patch browser will be empty"
}

Write-Host "installed to $bundle"
