package clapprobe

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"

import clap "../../src/clap"

// A headless CLAP host, small enough to read, that loads a .clap and drives it
// the way a real host does: init the entry, ask the factory for the one plugin,
// create it, initialise, activate, read the parameter list, then tear it all
// down. It exits non-zero on the first thing that does not answer.
//
// The point of it is what a build check cannot see. A plugin can compile into a
// perfectly good shared library and still fail the moment a host dlopens it --
// most sharply when a platform does not run the module's global initialisation
// on load, which leaves every non-constant global zero and the first call
// through a vtable a crash. tools/claphost is the Windows editor driver and does
// not build here; this is the portable half, and CI runs it against the Linux
// build so that failure is attached to the commit that caused it rather than
// found in a DAW.
//
// It is not the reference host and makes no attempt to be: it renders no audio
// and opens no window. It proves the module loads and instantiates, which is the
// part that was breaking.

FACTORY_ID: cstring : "clap.plugin-factory"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: clapprobe <path-to.clap>")
		os.exit(2)
	}
	path := os.args[1]

	lib, ok := dynlib.load_library(path)
	if !ok {
		fmt.eprintfln("FAIL: cannot load %s", path)
		os.exit(1)
	}

	sym, found := dynlib.symbol_address(lib, "clap_entry")
	if !found {
		fmt.eprintln("FAIL: no clap_entry symbol")
		os.exit(1)
	}
	entry := (^clap.Plugin_Entry)(sym)

	cpath := strings.clone_to_cstring(path)
	if entry.init != nil && !entry.init(cpath) {
		fmt.eprintln("FAIL: entry.init returned false")
		os.exit(1)
	}

	factory := (^clap.Plugin_Factory)(entry.get_factory(FACTORY_ID))
	if factory == nil {
		fmt.eprintln("FAIL: no plugin factory")
		os.exit(1)
	}

	count := factory.get_plugin_count(factory)
	if count < 1 {
		fmt.eprintln("FAIL: factory reports no plugins")
		os.exit(1)
	}

	desc := factory.get_plugin_descriptor(factory, 0)
	if desc == nil {
		fmt.eprintln("FAIL: null plugin descriptor")
		os.exit(1)
	}
	fmt.printfln("plugin: id=%q name=%q vendor=%q version=%q", desc.id, desc.name, desc.vendor, desc.version)

	host := clap.Host {
		name   = "clapprobe",
		vendor = "quesynth",
	}
	plugin := factory.create_plugin(factory, &host, desc.id)
	if plugin == nil {
		fmt.eprintln("FAIL: create_plugin returned nil")
		os.exit(1)
	}

	if plugin.init != nil && !plugin.init(plugin) {
		fmt.eprintln("FAIL: plugin.init returned false")
		os.exit(1)
	}

	if plugin.activate != nil && !plugin.activate(plugin, 48000, 1, 512) {
		fmt.eprintln("FAIL: plugin.activate returned false")
		os.exit(1)
	}

	params_count := u32(0)
	if plugin.get_extension != nil {
		if ext := plugin.get_extension(plugin, "clap.params"); ext != nil {
			params_count = (^clap.Plugin_Params)(ext).count(plugin)
		}
	}
	fmt.printfln("activated at 48 kHz; params extension reports %d parameters", params_count)

	if plugin.deactivate != nil {
		plugin.deactivate(plugin)
	}
	if plugin.destroy != nil {
		plugin.destroy(plugin)
	}
	if entry.deinit != nil {
		entry.deinit()
	}

	fmt.println("PASS: loaded, instantiated, activated and destroyed")
}
