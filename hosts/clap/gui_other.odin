#+build !windows
package synth_clap

// The GUI seam on a platform with no web-view editor.
//
// The counterpart of gui.odin, which is Windows-only because it hosts the panel
// in a WebView2 control. Here there is no editor, so the plugin answers no GUI
// extension and the host draws its generic parameter view from the params
// extension -- a working instrument, which is the point of answering honestly
// rather than offering an editor that cannot open.
//
// plugin.odin calls this by name from get_extension and never learns which half
// it got, the same arrangement hosts/vst3 uses for make_editor.
gui_extension :: proc "c" () -> rawptr {
	return nil
}
