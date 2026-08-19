package synth_clap

import "base:runtime"

import "../../src/clap"

// The shared library's entry point, its factory, and the one descriptor it
// offers.

PLUGIN_ID :: "com.quesynth.quesynth"
PLUGIN_NAME :: "Quesynth"
PLUGIN_VENDOR :: "quesynth"
PLUGIN_VERSION :: "0.1.0"
PLUGIN_DESCRIPTION :: "Synth1-compatible virtual analogue synthesiser"

// clap_plugin_descriptor.features is a null-terminated array of C strings.
FEATURES := [4]cstring {
	clap.PLUGIN_FEATURE_INSTRUMENT,
	clap.PLUGIN_FEATURE_SYNTHESIZER,
	clap.PLUGIN_FEATURE_STEREO,
	nil,
}

DESCRIPTOR := clap.Plugin_Descriptor {
	clap_version = clap.VERSION,
	id           = PLUGIN_ID,
	name         = PLUGIN_NAME,
	vendor       = PLUGIN_VENDOR,
	url          = "",
	manual_url   = "",
	support_url  = "",
	version      = PLUGIN_VERSION,
	description  = PLUGIN_DESCRIPTION,
	features     = &FEATURES[0],
}

FACTORY := clap.Plugin_Factory {
	get_plugin_count = proc "c" (factory: ^clap.Plugin_Factory) -> u32 {
		return 1
	},
	get_plugin_descriptor = proc "c" (
		factory: ^clap.Plugin_Factory,
		index: u32,
	) -> ^clap.Plugin_Descriptor {
		if index != 0 {
			return nil
		}
		return &DESCRIPTOR
	},
	create_plugin = proc "c" (
		factory: ^clap.Plugin_Factory,
		host: ^clap.Host,
		plugin_id: cstring,
	) -> ^clap.Plugin {
		context = runtime.default_context()
		if plugin_id == nil || string(plugin_id) != PLUGIN_ID {
			return nil
		}

		s := new(Synth)
		if s == nil {
			return nil
		}
		s.host = host
		// Every parameter starts on the reference plugin's own default, which
		// is what an empty patch sounds like there.
		for i in 0 ..< PARAM_COUNT {
			s.values[i] = i32(param_default(i))
			s.staged[i] = s.values[i]
		}
		s.plugin = clap.Plugin {
			desc             = &DESCRIPTOR,
			plugin_data      = s,
			init             = plugin_init,
			destroy          = plugin_destroy,
			activate         = plugin_activate,
			deactivate       = plugin_deactivate,
			start_processing = plugin_start_processing,
			stop_processing  = plugin_stop_processing,
			reset            = plugin_reset,
			process          = plugin_process,
			get_extension    = plugin_get_extension,
			on_main_thread   = plugin_on_main_thread,
		}
		return &s.plugin
	},
}

// CLAP 1.2 requires init/deinit to tolerate being called more than once and to
// be matched in pairs, so the calls are counted. There is nothing expensive to
// guard -- the factory and descriptor are static -- so a counter without a
// mutex is enough: the specification forbids concurrent calls to these two.
entry_refcount: int

entry_init :: proc "c" (plugin_path: cstring) -> bool {
	entry_refcount += 1
	return true
}

entry_deinit :: proc "c" () {
	if entry_refcount > 0 {
		entry_refcount -= 1
	}
}

entry_get_factory :: proc "c" (factory_id: cstring) -> rawptr {
	if factory_id == nil {
		return nil
	}
	if string(factory_id) != clap.PLUGIN_FACTORY_ID {
		return nil
	}
	return &FACTORY
}

// The symbol a CLAP host looks for. `link_name` keeps it spelled exactly
// `clap_entry` in the shared library's export table.
@(export, link_name = "clap_entry")
clap_entry := clap.Plugin_Entry {
	clap_version = clap.VERSION,
	init         = entry_init,
	deinit       = entry_deinit,
	get_factory  = entry_get_factory,
}
