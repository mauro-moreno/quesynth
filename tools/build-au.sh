#!/usr/bin/env bash
# Assemble the Audio Unit as a .component bundle on macOS.
#
# The same shape as tools/build-vst3.sh: it builds, it does not install, and the
# CI job installs the result and runs auval against it. An AU is a bundle whose
# Info.plist names the factory function the system looks up after dlopening the
# binary -- the AudioComponents entry is what registers the type/subtype/
# manufacturer that a host and auval search by:
#
#   Quesynth.component/
#     Contents/
#       MacOS/
#         Quesynth        the dylib, exporting QuesynthAUFactory
#       Info.plist        declares the AudioComponent + factoryFunction
#       PkgInfo
#
# There is no framework to carry and, for now, no panel: the editor is not wired
# into the AU yet, so this is the engine, its parameters and MIDI.
#
# Usage: tools/build-au.sh [output-dir]   (default build/au-stage)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="Quesynth"
output="${1:-build/au-stage}"
case "$output" in /*) stage="$output" ;; *) stage="$root/$output" ;; esac

bundle="$stage/$name.component"
macos_dir="$bundle/Contents"/MacOS

# Emptied, not added to: a stale binary must not be left behind a rebuild.
rm -rf "$bundle"
mkdir -p "$macos_dir"

echo "building the plugin..."
# On macOS, -build-mode:dll appends .dylib to a name without an extension, but a
# bundle's executable is named by CFBundleExecutable with no extension. Build to
# the .dylib name odin will honour, then move it to the bare name the plist points
# at.
odin build "$root/hosts/au" -build-mode:dll -o:speed -out:"$macos_dir/$name.dylib"
mv -f "$macos_dir/$name.dylib" "$macos_dir/$name"

# The AudioComponent registration. The four-character codes match the ones in
# hosts/au/plugin.odin; auval searches by exactly these. `factoryFunction` is the
# exported symbol the system calls to make an instance, and `name` is the
# "manufacturer: plugin" string a host shows. version is major<<16|minor<<8|patch
# = 0.1.0.
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>Quesynth</string>
	<key>CFBundleIdentifier</key>
	<string>com.quesynth.audiounit</string>
	<key>CFBundleName</key>
	<string>Quesynth</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>AudioComponents</key>
	<array>
		<dict>
			<key>type</key>
			<string>aumu</string>
			<key>subtype</key>
			<string>Qsy1</string>
			<key>manufacturer</key>
			<string>QSYT</string>
			<key>name</key>
			<string>quesynth: Quesynth</string>
			<key>description</key>
			<string>Synth1-compatible virtual analogue synthesiser</string>
			<key>version</key>
			<integer>256</integer>
			<key>factoryFunction</key>
			<string>QuesynthAUFactory</string>
			<key>sandboxSafe</key>
			<true/>
		</dict>
	</array>
</dict>
</plist>
PLIST

printf 'BNDL????' > "$bundle/Contents/PkgInfo"

echo "assembled $bundle"
