#!/usr/bin/env bash
# Assemble the CLAP plugin, with its interface, on Linux. The bash counterpart of
# build-clap.ps1 and the same shape as tools/build-vst3.sh: it builds, it does not
# install, and the release workflow calls it and zips the result.
#
# The layout is a file plus a folder beside it, and unlike Windows there is no
# loader to carry -- the editor loads the system WebKitGTK at run time:
#
#   Quesynth.clap     the plugin
#   Quesynth-ui/      the panel
#
# hosts/clap/gui.odin looks for Quesynth-ui beside its own module, so the two have
# to travel together. A .clap on its own still loads and plays; it just shows the
# host's generic controls instead of its own panel.
#
# Usage: tools/build-clap.sh [output-dir]   (default build/clap-stage)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="Quesynth"
output="${1:-build/clap-stage}"
case "$output" in /*) stage="$output" ;; *) stage="$root/$output" ;; esac

ui_dir="$stage/$name-ui"
plugin="$stage/$name.clap"

mkdir -p "$stage" "$ui_dir"
# Emptied, not added to; see the note in build-vst3.sh.
rm -rf "${ui_dir:?}/"* 2>/dev/null || true

echo "building the plugin..."
odin build "$root/hosts/clap" -build-mode:dll -target:linux_amd64 -o:speed -out:"$plugin"

# The same panel list the VST3 build copies, and for the same reasons.
panel=(
	index.html style.css
	app.js bridge.js layout.js midi.js params.js
	patchfile.js sy1.js modal.js browser.js
	midimap.js options.js
)
for file in "${panel[@]}"; do
	cp "$root/ui/$file" "$ui_dir/"
done

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

echo "assembled $stage"
