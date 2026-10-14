// logflags.odin — Shared --log-level parsing for the fused CLI tools.
//
// core:flags parses enums by exact variant name, but users type lowercase
// ("debug", ..., plus "warn" for Warning). This package maps those spellings
// onto log.Level in one place, with two entry points:
//
//   - parse_log_level: pure helper for hand-rolled parsing (cmd/mount, whose
//     opaque FUSE passthrough core:flags cannot express).
//   - set_log_level: core:flags custom setter for the other tools; register
//     once per binary before flags.parse_or_exit, and declare the field as
//     log.Level:
//
//     flags.register_type_setter(logflags.set_log_level)
//     ...
//     log_level: log.Level `args:"name=log-level" usage:"..."`
//
// An unset flag keeps the zero value log.Level.Debug. The custom setter
// takes precedence over builtin enum parsing ("the program gets to go
// first"), so lowercase input never reaches it.
#+build linux
package logflags

import "base:runtime"
import "core:log"
import "core:strings"

// parse_log_level maps a level name to log.Level. Accepts lowercase names
// plus "warn"; anything else (including "") is rejected.
parse_log_level :: proc(s: string) -> (lvl: log.Level, ok: bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "debug":
		return .Debug, true
	case "info":
		return .Info, true
	case "warn", "warning":
		return .Warning, true
	case "error":
		return .Error, true
	}
	return .Debug, false
}

// set_log_level is the core:flags custom setter counterpart of
// parse_log_level.
set_log_level :: proc(
	data: rawptr,
	data_type: typeid,
	unparsed_value: string,
	args_tag: string,
) -> (
	error: string,
	handled: bool,
	alloc_error: runtime.Allocator_Error,
) {
	_ = args_tag
	if data_type != log.Level {
		return "", false, .None
	}

	lvl, ok := parse_log_level(unparsed_value)
	if !ok {
		return "expected debug, info, warn or error", true, .None
	}

	(cast(^log.Level)data)^ = lvl
	return "", true, .None
}
