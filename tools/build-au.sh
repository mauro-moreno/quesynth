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
#       Resources/
#         ui/             the panel the Cocoa view shows
#       Info.plist        declares the AudioComponent + factoryFunction
#       PkgInfo
#
# The editor is the same panel the VST3 bundle carries, in a WKWebView. The unit
# finds it from its own binary as ../Resources/ui, which is the VST3 layout, so
# hosts/panel's search needs no AU case. QUESYNTH_AU_EDITOR=false builds the
# unit without a view and without the panel, for when a host or validator
# cannot live with one.
#
# QUESYNTH_VERSION (a release tag such as v1.2.3, or 1.2.3) is stamped into the
# Info.plist. It has to change from release to release: Logic, and the system's
# AudioUnit cache, key a unit's validation result on its version, so a unit that
# keeps one version keeps whatever result an earlier build of it got.
#
# Usage: tools/build-au.sh [output-dir]   (default build/au-stage)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="Quesynth"
output="${1:-build/au-stage}"
case "$output" in /*) stage="$output" ;; *) stage="$root/$output" ;; esac
editor="${QUESYNTH_AU_EDITOR:-true}"
case "$editor" in
	true | false) ;;
	*)
		echo "QUESYNTH_AU_EDITOR must be true or false: $editor" >&2
		exit 1
		;;
esac

version="${QUESYNTH_VERSION:-0.1.0}"
version="${version#v}"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
	echo "QUESYNTH_VERSION must be major.minor.patch, optionally with a leading v: $version" >&2
	exit 1
fi
major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
if ((major > 65535 || minor > 255 || patch > 255)); then
	echo "QUESYNTH_VERSION does not fit an AudioComponent version: $version" >&2
	exit 1
fi
component_version=$((major << 16 | minor << 8 | patch))

bundle="$stage/$name.component"
macos_dir="$bundle/Contents"/MacOS
ui_dir="$bundle/Contents/Resources/ui"

# Emptied, not added to: a stale binary must not be left behind a rebuild.
rm -rf "$bundle"
mkdir -p "$macos_dir"

echo "building the plugin..."
# On macOS, -build-mode:dll appends .dylib to a name without an extension, but a
# bundle's executable is named by CFBundleExecutable with no extension. Build to
# the .dylib name odin will honour, then move it to the bare name the plist points
# at.
odin build "$root/hosts/au" -build-mode:dll -o:speed "-define:QUESYNTH_AU_EDITOR=$editor" -out:"$macos_dir/$name.dylib"
mv -f "$macos_dir/$name.dylib" "$macos_dir/$name"

if [[ "$editor" == true ]]; then
	# WebKit has to be a load command of the binary, not merely a framework
	# something else might have loaded: Odin resolves WKWebView once, when the
	# image starts, and a nil it finds then is nil for good -- the unit would
	# offer no view in every host. otool ships with the Xcode command-line tools.
	if command -v otool >/dev/null 2>&1; then
		if ! otool -L "$macos_dir/$name" | grep -q 'WebKit.framework'; then
			echo "the AU does not link WebKit; its editor could never open" >&2
			exit 1
		fi
		echo "  links WebKit.framework"
	fi

	# The panel: the same files the VST3 bundle carries, and deliberately not
	# host.js or store.js -- in a plugin the host owns the audio and owns
	# persistence. The rationale is written out in build-vst3.ps1.
	mkdir -p "$ui_dir"
	panel=(
		index.html style.css
		app.js bridge.js layout.js midi.js params.js
		patchfile.js sy1.js modal.js browser.js
		midimap.js options.js
	)
	for file in "${panel[@]}"; do
		cp "$root/ui/$file" "$ui_dir/"
	done

	# The patch bank, generated from patches/quesynth/factory.json as the VST3
	# build does, so the bundle can never carry a stale ui/bank.js.
	factory="$root/patches/quesynth/factory.json"
	if [[ -f "$factory" ]]; then
		mkdir -p "$root/build"
		odin run "$root/tools/uibank" -out:"$root/build/uibank" -- "$factory" >/dev/null
	fi
	if [[ -f "$root/ui/bank.js" ]]; then
		cp "$root/ui/bank.js" "$ui_dir/"
	else
		echo "  no patch bank; the panel will be empty"
	fi

	if [[ ! -f "$ui_dir/index.html" ]]; then
		echo "the panel did not reach $ui_dir" >&2
		exit 1
	fi
	echo "  panel in Contents/Resources/ui ($(ls "$ui_dir" | wc -l | tr -d ' ') files, index.html present)"
fi

# The AudioComponent registration. The four-character codes match the ones in
# hosts/au/plugin.odin; auval searches by exactly these. `factoryFunction` is the
# exported symbol the system calls to make an instance, and `name` is the
# "manufacturer: plugin" string a host shows. version is major<<16|minor<<8|patch
# of QUESYNTH_VERSION.
cat > "$bundle/Contents/Info.plist" <<PLIST
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
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
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
			<integer>$component_version</integer>
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

echo "assembled $bundle (version $version)"
