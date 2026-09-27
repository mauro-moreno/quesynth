#!/usr/bin/env bash
# Assemble the VST3 plugin as a bundle on Linux. The bash counterpart of
# build-vst3.ps1: it builds, it does not install, and the release workflow calls
# it and zips the result, so what people download is the same thing that was
# assembled and tested locally.
#
# The Linux bundle differs from the Windows one only where the platform does.
# The binary is a .so under Contents/x86_64-linux, and there is no WebView2
# loader to carry beside it -- the editor loads the system WebKitGTK (GTK 3) at
# run time, the way audio_alsa loads libasound, so nothing has to ship. A machine
# without WebKitGTK still loads and plays the plugin; the host just draws its own
# controls. Everything else -- the Contents/Resources/ui panel and the generated
# bank -- is the same as the Windows build.
#
#   Quesynth.vst3/
#     Contents/
#       x86_64-linux/
#         Quesynth.so
#       Resources/
#         ui/
#
# Usage: tools/build-vst3.sh [output-dir]   (default build/stage)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="Quesynth"
output="${1:-build/stage}"
case "$output" in /*) stage="$output" ;; *) stage="$root/$output" ;; esac

bundle="$stage/$name.vst3"
bin_dir="$bundle/Contents/x86_64-linux"
ui_dir="$bundle/Contents/Resources/ui"

# A directory cannot take the place of an old bare-file build at this path.
if [ -e "$bundle" ] && [ ! -d "$bundle" ]; then
	rm -f "$bundle"
fi
mkdir -p "$bin_dir" "$ui_dir"
# Emptied, not added to: a panel file renamed or moved to another host must not
# go on being shipped from a stale copy here.
rm -rf "${ui_dir:?}/"* 2>/dev/null || true

echo "building the plugin..."
# -o:speed is not optional for an instrument; see the note in build-vst3.ps1.
odin build "$root/hosts/vst3" -build-mode:dll -target:linux_amd64 -o:speed -out:"$bin_dir/$name.so"

# The panel. Deliberately not host.js or store.js: in a plugin the host owns the
# audio and owns persistence. The rationale is written out in build-vst3.ps1.
panel=(
	index.html style.css
	app.js bridge.js layout.js midi.js params.js
	patchfile.js sy1.js modal.js browser.js
	midimap.js options.js
)
for file in "${panel[@]}"; do
	cp "$root/ui/$file" "$ui_dir/"
done

# The patch bank, generated rather than committed: patches/quesynth/factory.json
# is the bank, and ui/bank.js is a transcription of it, so generating it here
# means a bundle can never carry a stale one.
factory="$root/patches/quesynth/factory.json"
if [ -f "$factory" ]; then
	mkdir -p "$root/build"
	odin run "$root/tools/uibank" -out:"$root/build/uibank" -- "$factory" >/dev/null
fi
if [ -f "$root/ui/bank.js" ]; then
	cp "$root/ui/bank.js" "$ui_dir/"
else
	echo "  no patch bank; the panel will be empty"
fi

echo "assembled $bundle"
