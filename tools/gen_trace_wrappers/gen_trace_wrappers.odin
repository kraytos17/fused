// gen_trace_wrappers.odin — regenerate src/mounter/trace_wrappers.odin.
//
// Parses each fused_* signature verbatim (no transcription drift) and emits
// a traced_* wrapper that fast-paths to the real implementation when tracing
// is off, else records one JSONL event. Hand-authored bits are confined to
// the two-path/no-path tables below and the three special cases in emit
// (init/destroy return shapes, destroy's private_data lookup, and the
// copy_file_range fast-path wrap which stays wrapped below the width).
//
// Usage (from repo root):
//     make gen-trace        # regenerate src/mounter/trace_wrappers.odin
//     make check-trace      # verify it is current (also runs in CI/doctor)
// Raw form without make:
//     odin run tools/gen_trace_wrappers -collection:src=src > /tmp/tw.odin
//     diff /tmp/tw.odin src/mounter/trace_wrappers.odin   # must be empty
//
// fused_destroy is special-cased rather than table-driven: it reads the FS
// from its private_data argument (get_fs() is invalid at teardown, mirroring
// fused_destroy itself).
package main

import "core:fmt"
import "core:os"
import "core:strings"

FILES := [?]string{"create", "lock", "misc", "read", "write", "write_data", "xattr"}

Op :: struct {
	name:   string,
	params: string,
	ret:    string,
}

// Two-path ops combine into "a=>b" after the nil fast-path (zero cost when
// tracing is off) and before the clock starts (formatting time never inflates
// measured latency).
Two_Path :: struct {
	op:     string,
	first:  string,
	second: string,
}

TWO_PATH := [?]Two_Path {
	{"fused_symlink", "target", "linkpath"},
	{"fused_rename", "oldpath", "newpath"},
	{"fused_link", "oldpath", "newpath"},
	{"fused_copy_file_range", "path_in", "path_out"},
}

// MAX_LINE_WIDTH is the odinfmt column width: longer single lines wrap
// one-arg-per-line with a trailing comma.
MAX_LINE_WIDTH :: 100

// EXPECTED_OP_COUNT pins the fused_* callback count the generator covers.
EXPECTED_OP_COUNT :: 43

// NEEDLE marks a fused_* FUSE callback declaration.
NEEDLE :: " :: proc \"c\" ("

// FUSED_PREFIX marks the callback family the generator mirrors.
FUSED_PREFIX :: "fused_"

is_word_char :: proc(c: u8) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_':
		return true
	}
	return false
}

two_path_lookup :: proc(op: string) -> (pair: Two_Path, ok: bool) {
	for candidate in TWO_PATH {
		if candidate.op == op {
			return candidate, true
		}
	}
	return {}, false
}

is_space_byte :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r':
		return true
	}
	return false
}

is_no_path :: proc(name: string) -> bool {
	return name == "fused_init" || name == "fused_destroy"
}

// replace_fi_ignored rewrites a lone `_` parameter name to `fi_ignored`.
replace_fi_ignored :: proc(params: string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(params) {
		if params[i] == '_' {
			prev_ok := i == 0 || !is_word_char(params[i - 1])
			next_ok := i + 1 >= len(params) || !is_word_char(params[i + 1])
			if prev_ok && next_ok {
				j := i + 1
				for j < len(params) && is_space_byte(params[j]) {
					j += 1
				}
				if j < len(params) && params[j] == ':' {
					strings.write_string(&b, "fi_ignored")
					i += 1
					continue
				}
			}
		}

		strings.write_byte(&b, params[i])
		i += 1
	}
	return strings.to_string(b)
}

read_whole :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("gen_trace_wrappers: cannot read %s: %v\n", path, err)
		os.exit(1)
	}
	return string(data)
}

// scan_params returns the parameter list opened at index open, plus the
// index of its matching close paren.
scan_params :: proc(src: string, open: int, op: string) -> (params: string, close: int) {
	depth := 0
	j := open
	for {
		if j >= len(src) {
			fmt.eprintf("gen_trace_wrappers: unbalanced parens for %s\n", op)
			os.exit(1)
		}
		switch src[j] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
			if depth == 0 {
				return src[open + 1:j], j
			}
		}
		j += 1
	}
}

// parse_return takes the text after a signature's closing paren (already
// left-trimmed) and returns the declared return type, or "" when the
// procedure returns nothing.
parse_return :: proc(after: string) -> string {
	if !strings.has_prefix(after, "->") {
		return ""
	}

	segment := after[2:]
	if eol := strings.index_byte(segment, '\n'); eol >= 0 {
		segment = segment[:eol]
	}
	if brace := strings.index_byte(segment, '{'); brace >= 0 {
		segment = segment[:brace]
	}
	return strings.trim_space(segment)
}

collect :: proc() -> [dynamic]Op {
	// Concatenate in FILES order so output follows source order.
	sb := strings.builder_make()
	for f in FILES {
		p := fmt.tprintf("src/mounter/%s.odin", f)
		text := read_whole(p)
		strings.write_string(&sb, text)
		strings.write_byte(&sb, '\n')
	}

	src := strings.to_string(sb)
	ops := make([dynamic]Op)
	seen := make(map[string]bool)
	pos := 0
	for pos < len(src) {
		rel := strings.index(src[pos:], FUSED_PREFIX)
		if rel < 0 {
			break
		}

		start := pos + rel
		end := start
		for end < len(src) && is_word_char(src[end]) {
			end += 1
		}

		name := src[start:end]
		rest := src[end:]
		if !strings.has_prefix(rest, NEEDLE) {
			pos = end
			continue
		}

		// i points at '('; scan balanced parens for the parameter list.
		i := end + len(NEEDLE) - 1
		params_raw, j := scan_params(src, i, name)
		after := strings.trim_left_space(src[j + 1:])
		ret := parse_return(after)
		pos = j + 1
		if name in seen {
			continue
		}

		seen[name] = true
		params := replace_fi_ignored(params_raw)
		append(&ops, Op{name = name, params = params, ret = ret})
	}
	return ops
}

// split_params splits a parameter list on commas (no fused_* type contains
// a comma) and trims each segment.
split_params :: proc(params: string) -> []string {
	parts := strings.split(params, ",", context.temp_allocator)
	for i in 0 ..< len(parts) {
		parts[i] = strings.trim_space(parts[i])
	}
	return parts
}

// arg_names_of returns the identifier before each ':' in a parameter list.
arg_names_of :: proc(params: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for part in split_params(params) {
		name := part
		if colon := strings.index_byte(name, ':'); colon >= 0 {
			name = strings.trim_space(name[:colon])
		}
		if len(name) == 0 {
			continue
		}
		append(&out, name)
	}
	return out
}

leading_ws_len :: proc(s: string) -> int {
	return len(s) - len(strings.trim_left(s, " \t"))
}

// emit_one_line writes prefix(elems)suffix as a verbatim single line unless
// it exceeds MAX_LINE_WIDTH; wrapped args go one-per-line with a trailing
// comma (matches the committed style). force_wrap reproduces the
// hand-wrapped copy_file_range fast-path which stays wrapped below the width.
emit_one_line :: proc(
	b: ^strings.Builder,
	prefix: string,
	elems: []string,
	suffix: string,
	force_wrap := false,
) {
	single := strings.builder_make(context.temp_allocator)
	strings.write_string(&single, prefix)
	strings.write_byte(&single, '(')
	strings.write_string(&single, strings.join(elems, ", ", context.temp_allocator))
	strings.write_byte(&single, ')')
	strings.write_string(&single, suffix)
	line := strings.to_string(single)
	if !force_wrap && len(line) <= MAX_LINE_WIDTH {
		strings.write_string(b, line)
		strings.write_byte(b, '\n')
		return
	}

	strings.write_string(b, prefix)
	strings.write_string(b, "(\n")
	indent := prefix[:leading_ws_len(prefix)]
	for e in elems {
		fmt.sbprintf(b, "%s\t%s,\n", indent, e)
	}

	strings.write_string(b, indent)
	strings.write_byte(b, ')')
	strings.write_string(b, suffix)
	strings.write_byte(b, '\n')
}

emit_trace_call :: proc(b: ^strings.Builder, short, path_expr, rc_expr, failed_expr: string) {
	strings.write_string(b, "\ttrace_record(\n")
	strings.write_string(b, "\t\tfsys,\n")
	fmt.sbprintf(b, "\t\t\"%s\",\n", short)
	fmt.sbprintf(b, "\t\t%s,\n", path_expr)
	fmt.sbprintf(b, "\t\t%s,\n", rc_expr)
	fmt.sbprintf(b, "\t\t%s,\n", failed_expr)
	strings.write_string(
		b,
		"\t\ti64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))),\n",
	)
	strings.write_string(b, "\t)\n")
}

emit :: proc(b: ^strings.Builder, op: Op) {
	short := strings.trim_prefix(op.name, FUSED_PREFIX)
	names := arg_names_of(op.params)
	args := strings.join(names[:], ", ", context.temp_allocator)
	suffix_ret := fmt.tprintf(" -> %s", op.ret) if len(op.ret) > 0 else ""
	// Signature: multi-line sources stay verbatim; single-line ones wrap
	// through the shared helper (note the trailing space in the prefix so
	// the single-line form reads `proc "c" (args)`).
	if strings.index_byte(op.params, '\n') >= 0 {
		fmt.sbprintf(b, "traced_%s :: proc \"c\" (%s)%s {{\n", short, op.params, suffix_ret)
	} else {
		emit_one_line(
			b,
			fmt.tprintf("traced_%s :: proc \"c\" ", short),
			split_params(op.params),
			fmt.tprintf("%s {{", suffix_ret),
		)
	}

	if op.name == "fused_destroy" {
		strings.write_string(
			b,
			"\t// Mirrors fused_destroy: the FUSE context may already be torn down,\n" +
			"\t// so the FS comes from private_data, never get_fs().\n",
		)
		strings.write_string(b, "\tfsys := (^FS)(private_data)\n")
	} else {
		strings.write_string(b, "\tfsys := get_fs()\n")
	}

	strings.write_string(b, "\tcontext = runtime.default_context()\n")
	strings.write_string(b, "\tif fsys.trace == nil {\n")
	if len(op.ret) == 0 {
		emit_one_line(b, fmt.tprintf("\t\t%s", op.name), names[:], "")
		strings.write_string(b, "\t\treturn\n")
	} else {
		emit_one_line(
			b,
			fmt.tprintf("\t\treturn %s", op.name),
			names[:],
			"",
			force_wrap = op.name == "fused_copy_file_range",
		)
	}

	strings.write_string(b, "\t}\n")
	path_expr := ""
	if pair, is_two := two_path_lookup(op.name); is_two {
		strings.write_string(b, "\tpair: [1024]u8\n")
		fmt.sbprintf(
			b,
			"\tppath := fmt.bprintf(pair[:], \"%%s=>%%s\", string(%s), string(%s))\n",
			pair.first,
			pair.second,
		)
		path_expr = "ppath"
	} else if is_no_path(op.name) {
		path_expr = "\"\""
	} else {
		path_expr = fmt.tprintf("string(%s)", names[0])
	}

	strings.write_string(b, "\tt0 := time.tick_now()\n")
	if op.name == "fused_destroy" {
		fmt.sbprintf(b, "\t%s(%s)\n", op.name, args)
		emit_trace_call(b, short, path_expr, "0", "false")
	} else if op.ret == "rawptr" {
		fmt.sbprintf(b, "\tcout := %s(%s)\n", op.name, args)
		emit_trace_call(b, short, path_expr, "0", "cout == nil")
		strings.write_string(b, "\treturn cout\n")
	} else {
		fmt.sbprintf(b, "\trc := %s(%s)\n", op.name, args)
		emit_trace_call(b, short, path_expr, "i64(rc)", "rc < 0")
		strings.write_string(b, "\treturn rc\n")
	}
	strings.write_string(b, "}\n")
}

// HEADER is the generated file's preamble; the blank line after the imports
// separates it from the first wrapper.
HEADER ::
	"// trace_wrappers.odin — traced FUSE dispatch wrappers (generated by\n" +
	"// tools/gen_trace_wrappers; do not hand-edit, rerun the generator).\n" +
	"// Each traced_* mirrors its fused_* signature exactly, fast-paths to the\n" +
	"// real implementation when tracing is off (single nil check), and otherwise\n" +
	"// records one JSONL event per call. The ops table (build_operations) points\n" +
	"// here; tests keep calling the real fused_* directly and are unaffected.\n" +
	"#+build linux\n" +
	"package mounter\n" +
	"\n" +
	"import \"base:runtime\"\n" +
	"import \"core:c\"\n" +
	"import \"core:fmt\"\n" +
	"import \"core:sys/posix\"\n" +
	"import \"core:time\"\n" +
	"import \"src:fuse3\"\n" +
	"\n"

main :: proc() {
	ops := collect()
	if len(ops) != EXPECTED_OP_COUNT {
		fmt.eprintf("gen_trace_wrappers: expected %d ops, found %d\n", EXPECTED_OP_COUNT, len(ops))
		os.exit(1)
	}

	b := strings.builder_make()
	strings.write_string(&b, HEADER)
	for op in ops {
		emit(&b, op)
	}

	out := strings.to_string(b)
	if _, err := os.write_string(os.stdout, out); err != nil {
		fmt.eprintf("gen_trace_wrappers: write failed: %v\n", err)
		os.exit(1)
	}
}
