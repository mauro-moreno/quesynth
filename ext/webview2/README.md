# WebView2

The Microsoft Edge WebView2 SDK, vendored for the VST3 editor.

    Package  Microsoft.Web.WebView2
    Version  1.0.2903.40
    Source   https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2903.40

Two files are kept out of it:

    x64/WebView2Loader.dll  committed; copied beside the plugin binary by
                            tools/install-vst3.ps1
    include/WebView2.h      not committed; the C API, and the authority for
                            every vtable order transcribed into src/webview2

Only the loader is in the repository. It is a real runtime dependency and the
editor cannot be built without it. The header is 2.5 MB of generated COM
declarations that nothing in the build consumes, so it is ignored like the CLAP
and VST3 headers beside it. To read it again:

    Invoke-WebRequest -Uri https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2903.40 -OutFile wv2.nupkg
    # a .nupkg is a zip; build/native/include/WebView2.h is the file

`WebView2Loader.dll` is a shim, not the browser. It finds the Edge WebView2
runtime the user already has installed and forwards to it, which is why the
plugin ships a 166 KB file rather than a browser. `src/webview2` loads it by
full path at run time instead of importing it, so a machine without the runtime
gets a working instrument with no editor rather than a plugin the host cannot
load at all.

The header is the reason this directory exists rather than a note in a comment.
A vtable is an ordered list of function pointers with no names in it at run
time: a method transcribed into the wrong slot compiles, links, and calls
something else entirely. Every order in `src/webview2/webview2.odin` was read
out of this file, and it is kept so it can be read again.
