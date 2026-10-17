// trace.odin — opt-in FUSE operation tracing (userspace observability).
//
// When enabled (--trace on the mount command), every FUSE callback emits
// one JSONL event (op, path, result, latency) through the traced_*
// wrappers in trace_wrappers.odin. Disabled by default: fsys.trace stays
// nil and each wrapper pays a single nil check before delegating.
// Trace output is a debugging aid, not a stable API: the line schema may
// grow fields without notice (see DESIGN.md).
#+build linux
package mounter

import "core:fmt"
import "core:os"
import "core:sync"

// Trace_Mode selects which FUSE callbacks emit trace events.
Trace_Mode :: enum {
	Off, // no tracing (zero value; the sink stays nil)
	All, // emit an event per callback invocation
	Errors, // emit only invocations that return an error
}

// Trace_Counts aggregates per-op counters for the SIGUSR1 status dump.
Trace_Counts :: struct {
	calls:    u64,
	errors:   u64,
	// ns_total accumulates latency so the dump can report averages.
	ns_total: u64,
}

// Trace_Sink is the shared destination for trace events. Created only
// when tracing is enabled; nil otherwise. All fields are guarded by mu
// (callbacks run on FUSE worker threads). Owns file iff owns_file.
Trace_Sink :: struct {
	mu:        sync.Mutex,
	file:      ^os.File,
	owns_file: bool,
	mode:      Trace_Mode,
	counts:    map[string]Trace_Counts,
}

// trace_sink_open creates a trace sink writing JSONL to path ("-" selects
// stdout, which is never closed by teardown). Returns nil (not an error)
// when mode is .Off so callers need no special case.
trace_sink_open :: proc(
	path: string,
	mode: Trace_Mode,
	allocator := context.allocator,
) -> ^Trace_Sink {
	if mode == .Off {
		return nil
	}

	sink := new(Trace_Sink, allocator)
	sink.mode = mode
	sink.counts = make(map[string]Trace_Counts, 32, allocator)
	if path == "-" || len(path) == 0 {
		sink.file = os.stdout
		sink.owns_file = false
	} else {
		fd, err := os.open(path, {.Write, .Create, .Trunc})
		if err != nil {
			delete(sink.counts)
			free(sink, allocator)
			return nil
		}

		sink.file = fd
		sink.owns_file = true
	}
	return sink
}

// trace_sink_close flushes (writes are unbuffered, so this just closes),
// destroys the counters, and frees the sink. Safe to call with nil.
trace_sink_close :: proc(sink: ^Trace_Sink, allocator := context.allocator) {
	if sink == nil {
		return
	}
	if sink.owns_file {
		os.close(sink.file)
	}

	delete(sink.counts)
	free(sink, allocator)
}

// trace_escape_json copies s into buf with JSON string escaping, and
// returns the bytes written. Truncates (never mid-escape) when buf is
// full; callers size buf for realistic inputs (paths are short).
trace_escape_json :: proc(buf: []u8, s: string) -> (n: int) {
	hex := "0123456789abcdef"
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"', '\\':
			if n + 2 > len(buf) { return n }
			buf[n] = '\\'
			buf[n + 1] = c
			n += 2
		case '\n', '\r', '\t':
			if n + 2 > len(buf) { return n }
			buf[n] = '\\'
			buf[n + 1] = 'n' if c == '\n' else 'r' if c == '\r' else 't'
			n += 2
		case:
			if c < 0x20 {
				if n + 6 > len(buf) { return n }
				buf[n + 0] = '\\'
				buf[n + 1] = 'u'
				buf[n + 2] = '0'
				buf[n + 3] = '0'
				buf[n + 4] = hex[c >> 4]
				buf[n + 5] = hex[c & 0xF]
				n += 6
			} else {
				if n + 1 > len(buf) { return n }
				buf[n] = c
				n += 1
			}
		}
	}
	return n
}

// trace_format_line renders one JSONL event into buf (no heap allocation,
// so it is unit-testable and safe to call with only a stack buffer).
// Braces are doubled: a single { starts an indexed-argument expression.
// Returns the used prefix:
// {"op":"...","path":"...","rc":N,"err":true|false,"dur_us":N}.
trace_format_line :: proc(
	buf: []u8,
	op, path: string,
	rc: i64,
	failed: bool,
	dur_us: i64,
) -> string {
	// op names are ASCII identifiers from the wrapper table: no escaping.
	s := fmt.bprintf(buf, "{{\"op\":\"%s\",\"path\":\"", op)
	rest := buf[len(s):]
	en := trace_escape_json(rest, path)
	mid := fmt.bprintf(rest[en:], "\",\"rc\":%d,\"err\":%v,\"dur_us\":%d}}\n", rc, failed, dur_us)
	return string(buf[:len(s) + en + len(mid)])
}

trace_record :: proc(fsys: ^FS, op, path: string, rc: i64, failed: bool, elapsed_ns: i64) {
	sink := fsys.trace
	if sink == nil {
		return
	}
	if sink.mode == .Errors && !failed {
		return
	}

	sync.mutex_lock(&sink.mu)
	entry := sink.counts[op]
	entry.calls += 1
	if failed {
		entry.errors += 1
	}

	entry.ns_total += u64(max(elapsed_ns, 0))
	sink.counts[op] = entry
	line: [1024]u8
	s := trace_format_line(line[:], op, path, rc, failed, elapsed_ns / 1000)
	os.write(sink.file, transmute([]u8)s)
	sync.mutex_unlock(&sink.mu)
}
