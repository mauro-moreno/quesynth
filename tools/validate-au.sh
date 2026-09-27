#!/usr/bin/env bash
# auval is Apple's AU gate; pluginval adds external lifecycle, threading,
# parameter and render fuzzing against the built component, and by default its
# editor tests: open and close the unit's Cocoa view, and open it while
# processing. PLUGINVAL_GUI=0 skips them, for a runner whose session cannot
# host a WKWebView at all.
set -euo pipefail

component="${1:-build/au-stage/Quesynth.component}"
level="${PLUGINVAL_STRICTNESS:-5}"

if [[ ! -d "$component" ]]; then
  echo "Audio Unit component not found: $component" >&2
  exit 1
fi

if [[ ! "$level" =~ ^(10|[1-9])$ ]]; then
  echo "PLUGINVAL_STRICTNESS must be an integer from 1 to 10: $level" >&2
  exit 1
fi

pluginval_bin="$(command -v pluginval || true)"
if [[ -z "$pluginval_bin" ]]; then
  if [[ -x /Applications/pluginval.app/Contents/MacOS/pluginval ]]; then
    pluginval_bin=/Applications/pluginval.app/Contents/MacOS/pluginval
  elif [[ -x "$HOME/Applications/pluginval.app/Contents/MacOS/pluginval" ]]; then
    pluginval_bin="$HOME/Applications/pluginval.app/Contents/MacOS/pluginval"
  else
    echo "pluginval is not on PATH; installing the Homebrew cask..."
    if ! command -v brew >/dev/null 2>&1 || ! HOMEBREW_NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask pluginval; then
      echo "::warning::pluginval could not be installed on this runner; AU validation needs Homebrew and a macOS app installation"
      exit 0
    fi
    pluginval_bin="$(command -v pluginval || true)"
    if [[ -z "$pluginval_bin" && -x /Applications/pluginval.app/Contents/MacOS/pluginval ]]; then
      pluginval_bin=/Applications/pluginval.app/Contents/MacOS/pluginval
    elif [[ -z "$pluginval_bin" && -x "$HOME/Applications/pluginval.app/Contents/MacOS/pluginval" ]]; then
      pluginval_bin="$HOME/Applications/pluginval.app/Contents/MacOS/pluginval"
    fi
  fi
fi

if [[ -z "$pluginval_bin" ]]; then
  echo "::warning::pluginval was installed but its executable is unavailable on this runner; AU validation could not run"
  exit 0
fi

echo "pluginval version:"
"$pluginval_bin" --version
command=("$pluginval_bin" --strictness-level "$level" --timeout-ms 30000)
if [[ "${PLUGINVAL_GUI:-1}" != 1 ]]; then
  command+=(--skip-gui-tests)
fi
command+=(--validate "$component")
printf 'Running:'
printf ' %q' "${command[@]}"
printf '\n'
"${command[@]}"
