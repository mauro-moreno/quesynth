# Assemble the VST3 plugin as a bundle, into a directory of your choosing.
#
# This builds; it does not install. `tools/install-vst3.ps1` is the local
# convenience that calls this and then drops the result into a VST3 folder, and
# the release workflow calls this and then zips it. Both go through here so the
# thing people download is the same thing that was tested locally, assembled by
# the same script -- an artifact laid out only by CI is one nobody has ever run.
#
# A bundle rather than a bare .vst3 file, because the plugin is not only a
# binary: the editor is the interface in ui/, and the WebView2 loader has to sit
# beside the DLL where the plugin can find it by module path. The layout is the
# one the VST3 specification defines for Windows, and hosts/vst3/editor.odin
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
#   pwsh tools/build-vst3.ps1 -Output build/stage

param(
    [string]$Output = "build/stage"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$name = "Quesynth"

$bundle = Join-Path $Output "$name.vst3"
$binDir = Join-Path $bundle "Contents\x86_64-win"
$uiDir = Join-Path $bundle "Contents\Resources\ui"

# Before the editor existed the plugin was a single DLL at exactly this path.
# A directory cannot take the place of a file, so an old one is removed rather
# than left to fail the copy with something unhelpful.
if ((Test-Path $bundle) -and -not (Test-Path $bundle -PathType Container)) {
    Remove-Item -LiteralPath $bundle -Force
}

New-Item -ItemType Directory -Force -Path $binDir, $uiDir | Out-Null

# Emptied rather than copied over. A script that only ever adds files leaves
# whatever an earlier version of it produced: a panel file that has since been
# renamed or moved out to another host goes on being shipped, and the bundle
# stops matching the tree it was built from. This directory is assembled here
# and holds nothing else, so clearing it loses nothing.
Get-ChildItem -Path $uiDir -Force | Remove-Item -Recurse -Force

$dll = Join-Path $binDir "$name.vst3"

# A DAW holds the plugin open for as long as it has it loaded, and the link step
# then fails with LNK1104, which reads like a broken build rather than an open
# window. Asked of the file itself rather than of the process list: what matters
# is whether *this* binary is locked, not whether some host happens to be
# running with a different plugin loaded.
if (Test-Path $dll) {
    try {
        $handle = [System.IO.File]::Open($dll, 'Open', 'Write', 'None')
        $handle.Close()
    } catch {
        $running = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Ableton|reaper|Cubase|FL64|Bitwig|Studio One' } |
            Select-Object -ExpandProperty Name -Unique
        $who = if ($running) { " (" + ($running -join ", ") + " is running)" } else { "" }
        throw "$dll is locked$who -- close the host and run this again."
    }
}

Write-Host "building the plugin..."

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

# The whole panel, which is all ui/ holds: the WebAssembly engine and its glue
# live in hosts/wasm and belong to that host, not to this one.
#
# Note what is *not* copied: host.js. index.html asks for it with an onerror
# guard, and a native host has no page-side glue to load -- the bridge is on
# this side of the wall, in editor.odin. Shipping the browser host's file here
# would be shipping a second engine that must never start.
$panel = @(
    "index.html", "style.css",
    "app.js", "bridge.js", "layout.js", "midi.js", "params.js",
    "patchfile.js", "sy1.js"
)
foreach ($file in $panel) {
    Copy-Item (Join-Path $root "ui\$file") $uiDir -Force
}

# The patch bank, generated rather than copied.
#
# ui/bank.js is not committed: patches/quesynth/factory.json is the bank, and
# the panel's copy is a transcription of it. Generating it here means a bundle
# can never carry a stale one, and that a fresh checkout produces a plugin with
# sounds in it without anybody being told to run a second command first.
$factory = Join-Path $root "patches\quesynth\factory.json"
if (Test-Path $factory) {
    & odin run (Join-Path $root "tools\uibank") -out:(Join-Path $root "build\uibank.exe") -- $factory | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not generate the patch bank" }
}
$bank = Join-Path $root "ui\bank.js"
if (Test-Path $bank) {
    Copy-Item $bank $uiDir -Force
} else {
    Write-Host "  no patch bank; the browser will be empty"
}

Write-Host "assembled $bundle"
