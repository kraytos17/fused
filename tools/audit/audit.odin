// audit.odin — Audit FUSE callbacks for locking discipline and src hygiene.
//
// Rules:
//   (context) every fused_* proc "c" opens with begin_op() or a context reset.
//   (a) every fused_* proc "c" calls a lock primitive somewhere in its own
//       body (begin_op/begin_read_op, sync.rw_mutex_lock/shared_lock), or
//       carries a `// UNLOCKED:` reason in the 6 lines above its declaration.
//   (g) every begin_op()/begin_read_op() call is immediately followed by
//       context.logger = fsys.logger (the assignment inside begin_op is
//       callee-local, so without the caller's own line the callback's
//       debugf goes nowhere).
//   (b) no os.exit() outside cmd/ and tools/ (binaries own process exit).
//   (c) no panic() in src/ (must not unwind through C callbacks).
//   (d) no (&x[0]) reinterpret casts in src/ (use the raw_data form).
//   (e) no auto_cast in src/ (prototyping-only); cast() only on pointers,
//       values use the T(v) form.
//   (s1) every backend.add() call checks its result (a dropped transaction
//       record must fail the op, never journal a prefix).
//   (s2) sector_write_bulk validates the transferred byte count.
//   (s3) JOURNAL_BACKEND.recover's result is checked (an unknowable
//       committed set or unwritten checkpoint must refuse the mount).
//   (s4) no discarded clone results in src/ (a failed cache insert must
//       fail the op, never cache an empty chain; a failed lookup clone
//       must fail the lookup, never hand back a phantom value).
//   (s5) every #packed struct has a size_of(Named) assert within 25 lines
//       (on-disk and ABI layouts stay pinned).
//   (s6) every ce_find_by_offset() call site checks .Allocated within 3
//       lines (a stale freed slot may share the offset; mutation paths
//       additionally cross-check the table index before journaling).
package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

Flags :: struct {
	strict: bool `args:"name=strict" usage:"Enable strict attribute checks"`,
}
// Unknown flags are rejected by parse_or_exit, matching the check/dump/
// format tools (previously they were silently ignored).

main :: proc() {
	context = runtime.default_context()

	f: Flags
	flags.parse_or_exit(&f, os.args, flags.Parsing_Style.Unix)
	dh, err := os.open("src/mounter")
	if err == nil {
		defer os.close(dh)
		run_audit(dh)
	} else {
		fmt.eprintf("cannot open src/mounter: %v\n", err)
		os.exit(1)
	}

	run_locking_audit()

	run_logger_audit()
	run_storage_audit()
	run_persist_order_audit()
	if audit_src_hygiene() > 0 {
		os.exit(1)
	}
	if !audit_fs_attributes(f.strict) {
		os.exit(1)
	}
}

run_audit :: proc(dh: ^os.File) {
	fis, err := os.read_dir(dh, 0, context.allocator)
	if err != nil {
		fmt.eprintf("cannot list src/mounter: %v\n", err)
		os.exit(1)
	}

	defer os.file_info_slice_delete(fis, context.allocator)
	total_p, total_f := 0, 0
	for fi in fis {
		if !strings.has_suffix(fi.name, ".odin") { continue }

		path, _ := filepath.join([]string{"src/mounter", fi.name})
		p, f := audit_file(path)
		total_p += p
		total_f += f
	}

	fmt.printf("=== Context audit: %d passed, %d failed ===\n", total_p, total_f)
	if total_f > 0 { os.exit(1) }
}

audit_file :: proc(path: string) -> (passed, failed: int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintf("warning: cannot read %s: %v\n", path, err)
		return
	}

	file: ast.File
	file.src = string(data)
	file.fullpath = path
	p := parser.default_parser()
	if !parser.parse_file(&p, &file) {
		fmt.eprintf("warning: parse error in %s\n", path)
		return
	}
	for stmt in file.decls {
		vd: ^ast.Value_Decl
		#partial switch v in stmt.derived_stmt {
		case ^ast.Value_Decl:
			vd = v
		}
		if vd == nil { continue }
		if len(vd.names) == 0 { continue }

		name_ident: ^ast.Ident
		#partial switch v in vd.names[0].derived_expr {
		case ^ast.Ident:
			name_ident = v
		}
		if name_ident == nil || !strings.has_prefix(name_ident.name, "fused_") {
			continue
		}

		name := name_ident.name
		if len(vd.values) == 0 { continue }

		proc_lit: ^ast.Proc_Lit
		#partial switch v in vd.values[0].derived_expr {
		case ^ast.Proc_Lit:
			proc_lit = v
		}
		if proc_lit == nil { continue }

		pt := proc_lit.type
		if pt == nil { continue }

		cc_str := fmt.tprintf("%v", pt.calling_convention)
		if cc_str != "\"c\"" { continue }
		if proc_lit.body == nil {
			fmt.printf("FAIL   %s: no body\n", name)
			failed += 1
			continue
		}

		block: ^ast.Block_Stmt
		#partial switch v in proc_lit.body.derived_stmt {
		case ^ast.Block_Stmt:
			block = v
		}
		if block == nil || len(block.stmts) == 0 {
			fmt.printf("FAIL   %s: empty body\n", name)
			failed += 1
			continue
		}

		first := block.stmts[0]
		if is_begin_op(first) || is_context_reset(first) {
			fmt.printf("PASS   %s\n", name); passed += 1
		} else {
			fmt.printf("FAIL   %s: missing begin_op()\n", name); failed += 1
		}
	}
	return
}

is_begin_op :: proc(s: ^ast.Stmt) -> bool {
	#partial switch a in s.derived_stmt {
	case ^ast.Assign_Stmt:
		if len(a.rhs) != 1 { return false }
		#partial switch c in a.rhs[0].derived_expr {
		case ^ast.Call_Expr:
			#partial switch i in c.expr.derived_expr {
			case ^ast.Ident:
				return i.name == "begin_op"
			}
		}
	case ^ast.Value_Decl:
		// := parses as Value_Decl, not Assign_Stmt (verified by probe:
		// the Assign_Stmt-only shape above never fired). fsys := begin_op().
		if len(a.values) != 1 { return false }
		#partial switch c in a.values[0].derived_expr {
		case ^ast.Call_Expr:
			#partial switch i in c.expr.derived_expr {
			case ^ast.Ident:
				return i.name == "begin_op"
			}
		}
	}
	return false
}

is_context_reset :: proc(s: ^ast.Stmt) -> bool {
	#partial switch a in s.derived_stmt {
	case ^ast.Assign_Stmt:
		if len(a.lhs) != 1 || len(a.rhs) != 1 { return false }
		#partial switch i in a.lhs[0].derived_expr {
		case ^ast.Ident:
			if i.name != "context" { return false }
		}
		#partial switch c in a.rhs[0].derived_expr {
		case ^ast.Call_Expr:
			#partial switch s2 in c.expr.derived_expr {
			case ^ast.Selector_Expr:
				#partial switch p in s2.expr.derived_expr {
				case ^ast.Ident:
					if p.name != "runtime" { return false }
				}
				return s2.field.name == "default_context"
			}
		}
	}
	return false
}

audit_fs_attributes :: proc(strict: bool) -> bool {
	ok := true
	{
		count := 0
		dh, derr := os.open("src/fs")
		if derr == nil {
			defer os.close(dh)
			fis, ferr := os.read_dir(dh, 0, context.temp_allocator)
			if ferr == nil {
				defer os.file_info_slice_delete(fis, context.temp_allocator)
				for fi in fis {
					if !strings.has_suffix(fi.name, ".odin") { continue }

					path, _ := filepath.join([]string{"src/fs", fi.name})
					data, err := os.read_entire_file(path, context.temp_allocator)
					if err != nil { continue }

					nows, _ := strings.remove_all(string(data), " ", context.temp_allocator)
					nows, _ = strings.remove_all(nows, "\t", context.temp_allocator)
					if strings.contains(nows, "private=\"file\"") {
						count += 1
					}
				}
			}
		}
		if count < 3 {
			fmt.printf("WARN   expected >=3 files with @(private=\"file\"), found %d\n", count)
			if strict { ok = false }
		}
	}
	{
		checks_data := []struct {
			path: string,
			sym:  string,
			attr: string,
		} {
			{"src/fs/journal.odin", "journal_recover", "cold"},
			{"src/fs/format.odin", "format_image", "favor_size"},
		}

		checks := checks_data[:]
		for c in checks {
			data, err := os.read_entire_file(c.path, context.temp_allocator)
			if err != nil { continue }

			lines := strings.split(string(data), "\n", context.temp_allocator)
			for i in 0 ..< len(lines) {
				if strings.contains(lines[i], c.sym) && strings.contains(lines[i], ":: proc") {
					has := false
					for k in max(0, i - 2) ..< i + 1 {
						if strings.contains(lines[k], c.attr) {
							has = true
							break
						}
					}
					if !has {
						fmt.printf("WARN   %s:%d %s missing @(%s)\n", c.path, i + 1, c.sym, c.attr)
						if strict { ok = false }
					}
				}
			}
		}
	}

	fmt.printf("=== Attribute audit: done ===\n")
	return ok
}

// Locking audit (rule a): every `fused_* proc "c"` must call a lock
// primitive somewhere in its own body — begin_op/begin_read_op idents, or
// sync.rw_mutex_lock/shared_lock selectors — or carry a `// UNLOCKED:`
// reason in the 6 lines above its declaration. Nested proc literals are NOT
// descended into: the rule audits the callback's own discipline. `when`
// blocks are not descended into either (none contain lock calls today).

callee_is_lock :: proc(e: ^ast.Expr) -> bool {
	if e == nil { return false }
	#partial switch x in e.derived_expr {
	case ^ast.Ident:
		return x.name == "begin_op" || x.name == "begin_read_op"
	case ^ast.Selector_Expr:
		if x.field == nil { return false }
		return x.field.name == "rw_mutex_lock" || x.field.name == "rw_mutex_shared_lock"
	}
	return false
}

expr_is_lock_call :: proc(e: ^ast.Expr) -> bool {
	if e == nil { return false }
	#partial switch x in e.derived_expr {
	case ^ast.Call_Expr:
		return callee_is_lock(x.expr)
	case ^ast.Selector_Call_Expr:
		if x.call == nil { return false }
		return callee_is_lock(x.call.expr)
	}
	return false
}

stmt_calls_lock :: proc(s: ^ast.Stmt) -> bool {
	if s == nil { return false }
	#partial switch st in s.derived_stmt {
	case ^ast.Block_Stmt:
		for sub in st.stmts {
			if stmt_calls_lock(sub) { return true }
		}
	case ^ast.If_Stmt:
		if stmt_calls_lock(st.init) { return true }
		if stmt_calls_lock(st.body) { return true }
		if stmt_calls_lock(st.else_stmt) { return true }
	case ^ast.For_Stmt:
		if stmt_calls_lock(st.init) { return true }
		if stmt_calls_lock(st.body) { return true }
	case ^ast.Range_Stmt:
		if stmt_calls_lock(st.body) { return true }
	case ^ast.Switch_Stmt:
		if stmt_calls_lock(st.init) { return true }
		if stmt_calls_lock(st.body) { return true }
	case ^ast.Type_Switch_Stmt:
		if stmt_calls_lock(st.body) { return true }
	case ^ast.Case_Clause:
		for sub in st.body {
			if stmt_calls_lock(sub) { return true }
		}
	case ^ast.Defer_Stmt:
		if stmt_calls_lock(st.stmt) { return true }
	case ^ast.Assign_Stmt:
		for e in st.rhs {
			if expr_is_lock_call(e) { return true }
		}
	case ^ast.Value_Decl:
		for e in st.values {
			if expr_is_lock_call(e) { return true }
		}
	case ^ast.Expr_Stmt:
		if expr_is_lock_call(st.expr) { return true }
	case ^ast.Return_Stmt:
		for e in st.results {
			if expr_is_lock_call(e) { return true }
		}
	}
	return false
}

body_calls_lock :: proc(block: ^ast.Block_Stmt) -> bool {
	for s in block.stmts {
		if stmt_calls_lock(s) { return true }
	}
	return false
}

// unlocked_reason_line finds a proc's declaration line and reports whether a
// `// UNLOCKED:` marker sits in the 6 lines above it. Matches `<name> :: proc`
// with a space after the name so fused_read never matches fused_read_buf.
unlocked_reason_line :: proc(lines: []string, name: string) -> (decl_line: int, ok: bool) {
	for i in 0 ..< len(lines) {
		trimmed := strings.trim_space(lines[i])
		if !strings.has_prefix(trimmed, name) { continue }

		rest := trimmed[len(name):]
		if !strings.has_prefix(rest, " :: proc") { continue }
		for k in max(0, i - 6) ..< i {
			if strings.contains(lines[k], "// UNLOCKED:") {
				return i + 1, true
			}
		}
		return i + 1, false
	}
	return 0, false
}

audit_locking_file :: proc(path: string) -> (checked, failed: int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintf("warning: cannot read %s: %v\n", path, err)
		return
	}

	lines := strings.split(string(data), "\n", context.temp_allocator)
	file: ast.File
	file.src = string(data)
	file.fullpath = path
	p := parser.default_parser()
	if !parser.parse_file(&p, &file) {
		fmt.eprintf("warning: parse error in %s\n", path)
		return
	}
	for stmt in file.decls {
		vd: ^ast.Value_Decl
		#partial switch v in stmt.derived_stmt {
		case ^ast.Value_Decl:
			vd = v
		}
		if vd == nil || len(vd.names) == 0 { continue }

		name_ident: ^ast.Ident
		#partial switch v in vd.names[0].derived_expr {
		case ^ast.Ident:
			name_ident = v
		}
		if name_ident == nil || !strings.has_prefix(name_ident.name, "fused_") { continue }

		name := name_ident.name
		if len(vd.values) == 0 { continue }

		proc_lit: ^ast.Proc_Lit
		#partial switch v in vd.values[0].derived_expr {
		case ^ast.Proc_Lit:
			proc_lit = v
		}
		if proc_lit == nil || proc_lit.type == nil { continue }

		cc_str := fmt.tprintf("%v", proc_lit.type.calling_convention)
		if cc_str != "\"c\"" { continue }
		if proc_lit.body == nil { continue }

		block: ^ast.Block_Stmt
		#partial switch v in proc_lit.body.derived_stmt {
		case ^ast.Block_Stmt:
			block = v
		}
		if block == nil { continue }

		checked += 1
		if body_calls_lock(block) { continue }

		decl_line, has_reason := unlocked_reason_line(lines, name)
		if has_reason { continue }

		fmt.printf(
			"FAIL   %s:%d %s: no lock call and no // UNLOCKED: reason\n",
			path,
			decl_line,
			name,
		)
		failed += 1
	}
	return
}

// _audit_mounter_dir runs audit_file over every .odin file in src/mounter
// and enforces zero failures. Shared by the locking and logger audits,
// which differ only in per-file rule and label.
_audit_mounter_dir :: proc(label: string, audit_file: proc(string) -> (int, int)) {
	total_c, total_f := 0, 0
	dh, derr := os.open("src/mounter")
	if derr != nil {
		fmt.eprintf("cannot open src/mounter: %v\n", derr)
		os.exit(1)
	}
	defer os.close(dh)

	fis, ferr := os.read_dir(dh, 0, context.allocator)
	if ferr != nil {
		fmt.eprintf("cannot list src/mounter: %v\n", ferr)
		os.exit(1)
	}

	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		if !strings.has_suffix(fi.name, ".odin") { continue }

		path, _ := filepath.join([]string{"src/mounter", fi.name})
		c, f := audit_file(path)
		total_c += c
		total_f += f
	}

	fmt.printf("=== %s audit: %d checked, %d failed ===\n", label, total_c, total_f)
	if total_f > 0 { os.exit(1) }
}

run_locking_audit :: proc() {
	_audit_mounter_dir("Locking", audit_locking_file)
}

// audit_logger_lines (rule g): every top-level fsys := begin_op() /
// begin_read_op() call must be followed (next non-blank line) by
// context.logger = fsys.logger. Line-based deliberately: AST matching
// proved unreliable for `context` receivers (a bare `context` does not
// parse as ^ast.Ident, verified by probe), while the enforced shape is a
// fixed two-line idiom. The single-tab prefix restricts the check to
// top-level calls; nested lock acquisition stays out of scope.
audit_logger_lines :: proc(path: string) -> (checked, failed: int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintf("warning: cannot read %s: %v\n", path)
		return
	}
	lines := strings.split(string(data), "\n", context.temp_allocator)
	for i in 0 ..< len(lines) {
		if lines[i] != "\tfsys := begin_op()" && lines[i] != "\tfsys := begin_read_op()" {
			continue
		}
		checked += 1
		j := i + 1
		for j < len(lines) && strings.trim_space(lines[j]) == "" {
			j += 1
		}
		if j >= len(lines) || strings.trim_space(lines[j]) != "context.logger = fsys.logger" {
			fmt.printf("FAIL   %s:%d missing context.logger after begin_op()\n", path, i + 1)
			failed += 1
		}
	}
	return
}

run_logger_audit :: proc() {
	_audit_mounter_dir("Logger", audit_logger_lines)
}

// Hygiene audit (rules b/c/d/e/f): line scans over src/{fs,fuse3,mounter}.
// Full-line `//` comments are skipped; the matchers are deliberately narrow
// (see has_old_cast) to avoid false positives in legitimate code.
HAS_OLD_CAST_ANCHOR :: ")("

// has_value_cast reports cast() applied to a non-pointer type. Pointer
// casts (cast(^T)) are the one legitimate cast() form; value conversions
// must use T(v). The match requires a non-identifier left boundary so
// words like broadcast( never match.
has_value_cast :: proc(line: string) -> bool {
	from := 0
	for {
		idx := strings.index(line[from:], "cast(")
		if idx < 0 { return false }

		pos := from + idx
		if pos > 0 {
			c := line[pos - 1]
			if (c >= 'a' && c <= 'z') ||
			   (c >= 'A' && c <= 'Z') ||
			   (c >= '0' && c <= '9') ||
			   c == '_' {
				from = pos + len("cast(")
				continue
			}
		}

		after := pos + len("cast(")
		if after < len(line) && line[after] == '^' {
			from = after + 1
			continue
		}
		return true
	}
}

has_old_cast :: proc(line: string) -> bool {
	// Old reinterpret shape: (^T)(&buf[0]) with a bare buffer ident.
	// Field punning (&entry.file_name[0], &master.resv[..]) contains a dot
	// and is idiomatic as-is, so it must NOT match.
	idx := strings.index(line, ")(&")
	if idx < 0 { return false }

	rest := line[idx + len(HAS_OLD_CAST_ANCHOR) + 1:]
	end := strings.index(rest, "[0])")
	if end <= 0 { return false }
	return !strings.contains_any(rest[:end], ".([ \t")
}

audit_hygiene_file :: proc(path: string) -> (failed: int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }

	lines := strings.split(string(data), "\n", context.temp_allocator)
	for i in 0 ..< len(lines) {
		trimmed := strings.trim_space(lines[i])
		if strings.has_prefix(trimmed, "//") { continue }
		if strings.contains(lines[i], "os.exit(") {
			fmt.printf("FAIL   %s:%d os.exit outside cmd/\n", path, i + 1)
			failed += 1
		}
		if strings.contains(lines[i], "panic(") {
			fmt.printf("FAIL   %s:%d panic in src/\n", path, i + 1)
			failed += 1
		}
		if has_old_cast(lines[i]) {
			fmt.printf("FAIL   %s:%d old (&x[0]) cast; use raw_data form\n", path, i + 1)
			failed += 1
		}
		// auto_cast is banned tree-wide (prototyping-only per the language docs).
		if strings.contains(lines[i], "auto_cast") {
			fmt.printf("FAIL   %s:%d auto_cast is banned; use explicit T(v)\n", path, i + 1)
			failed += 1
		}
		// Value casts must use the T(v) form; cast() is for pointer casts.
		if has_value_cast(lines[i]) {
			fmt.printf("FAIL   %s:%d cast() on non-pointer; use the T(v) form\n", path, i + 1)
			failed += 1
		}
		// Private procs must be _-prefixed (structs/enums/vars exempt).
		// The declaration conventionally follows its attribute directly.
		if strings.has_prefix(trimmed, "@(private") {
			for j := i + 1; j < len(lines) && j <= i + 2; j += 1 {
				decl := strings.trim_space(lines[j])
				if decl == "" || strings.has_prefix(decl, "//") { continue }
				space := strings.index(decl, " ")
				if space > 0 && strings.has_prefix(decl[space:], " :: proc") {
					name := decl[:space]
					if !strings.has_prefix(name, "_") {
						fmt.printf(
							"FAIL   %s:%d private proc %s without _ prefix\n",
							path,
							j + 1,
							name,
						)
						failed += 1
					}
				}
				break
			}
		}
	}
	return failed
}

audit_src_hygiene :: proc() -> (failed: int) {
	dirs := []string{"src/fs", "src/fuse3", "src/mounter"}
	for dir in dirs {
		dh, derr := os.open(dir)
		if derr != nil {
			fmt.eprintf("warning: cannot open %s: %v\n", dir, derr)
			failed += 1
			continue
		}
		defer os.close(dh)

		fis, ferr := os.read_dir(dh, 0, context.temp_allocator)
		if ferr != nil {
			fmt.eprintf("warning: cannot list %s: %v\n", dir, ferr)
			failed += 1
			continue
		}

		defer os.file_info_slice_delete(fis, context.temp_allocator)
		for fi in fis {
			if !strings.has_suffix(fi.name, ".odin") { continue }
			path, _ := filepath.join([]string{dir, fi.name})
			failed += audit_hygiene_file(path)
		}
	}

	fmt.printf("=== Hygiene audit: %d failed ===\n", failed)
	return failed
}

// Storage audit (rules s1..s5): journal-transaction and cache-ownership
// guardrails from the audit §9 list. Line-based deliberately, like the
// logger audit: every enforced shape is a fixed idiom, and the matchers
// are narrow to avoid false positives.
audit_storage_rules :: proc(path: string, lines: []string) -> (checked, failed: int) {
	for i in 0 ..< len(lines) {
		line := lines[i]
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "//") { continue }

		// s1: backend.add() must be result-checked at the call site.
		if strings.contains(line, "backend.add(") {
			checked += 1
			if !strings.contains(line, "if !") {
				fmt.printf("FAIL   %s:%d backend.add() result unchecked\n", path, i + 1)
				failed += 1
			}
		}

		// s2: sector_write_bulk must validate the byte count.
		if strings.contains(line, "sector_write_bulk :: proc") {
			checked += 1
			found := false
			for k in i ..< min(i + 12, len(lines)) {
				if strings.contains(lines[k], "len(buf)") {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("FAIL   %s:%d sector_write_bulk missing byte-count check\n", path, i + 1)
				failed += 1
			}
		}

		// s3: JOURNAL_BACKEND.recover's result must be checked.
		if strings.contains(line, "JOURNAL_BACKEND.recover") {
			checked += 1
			found := false
			for k in i ..< min(i + 3, len(lines)) {
				if strings.contains(lines[k], "!= .None") {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("FAIL   %s:%d JOURNAL_BACKEND.recover result unchecked\n", path, i + 1)
				failed += 1
			}
		}

		// s4: clone results must not be discarded. Matches any
		// allocator-returning clone call (slice/string/cstring) used
		// with an ignored error, or assigned to a single variable
		// (which silently drops the error). Callers must check the
		// status or use a form whose failure is impossible.
		if strings.contains(line, ".clone(") || strings.contains(line, "clone_to_cstring(") {
			checked += 1
			head := line
			if idx := strings.index(line, "clone("); idx >= 0 {
				head = line[:idx]
			}
			discarded := strings.contains(line, ", _ :=") || strings.contains(line, ", _ =")
			single := (strings.contains(head, ":=") || strings.contains(head, " = ")) && !strings.contains(head, ",")
			if !strings.has_prefix(trimmed, "//") && (discarded || single) {
				fmt.printf("FAIL   %s:%d discarded clone status\n", path, i + 1)
				failed += 1
			}
		}

		// s6: ce_find_by_offset results must be Allocated-checked: a
		// freed slot retains its old offset, so an unchecked match can
		// select a stale slot for mutation.
		if strings.contains(line, "ce_find_by_offset(") && !strings.contains(line, ":: proc") {
			checked += 1
			found := false
			for k in i ..< min(i + 3, len(lines)) {
				if strings.contains(lines[k], ".Allocated") {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("FAIL   %s:%d ce_find_by_offset without .Allocated check\n", path, i + 1)
				failed += 1
			}
		}

		// s5: every #packed struct needs its own size_of(Name) assert.
		if strings.contains(line, "#packed") &&
		   strings.contains(line, "::") &&
		   strings.contains(line, "struct") {
			end := strings.index(line, " ::")
			if end <= 0 { continue }
			name := strings.trim_space(line[:end])
			if name == "" || strings.contains_any(name, " \t") { continue }
			checked += 1
			want := fmt.tprintf("size_of(%s)", name)
			found := false
			for k in max(0, i - 25) ..< min(i + 26, len(lines)) {
				if strings.contains(lines[k], want) {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("FAIL   %s:%d #packed %s missing size_of assert\n", path, i + 1, name)
				failed += 1
			}
		}
	}
	return
}

run_storage_audit :: proc() {
	total_c, total_f := 0, 0
	dirs := []string{"src/fs", "src/fuse3", "src/mounter"}
	for dir in dirs {
		dh, derr := os.open(dir)
		if derr != nil {
			fmt.eprintf("warning: cannot open %s: %v\n", dir, derr)
			total_f += 1
			continue
		}
		fis, ferr := os.read_dir(dh, 0, context.temp_allocator)
		os.close(dh)
		if ferr != nil {
			fmt.eprintf("warning: cannot list %s: %v\n", dir, ferr)
			total_f += 1
			continue
		}
		for fi in fis {
			if !strings.has_suffix(fi.name, ".odin") { continue }
			path, _ := filepath.join([]string{dir, fi.name})
			data, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil { continue }
			lines := strings.split(string(data), "\n", context.temp_allocator)
			c, f := audit_storage_rules(path, lines)
			total_c += c
			total_f += f
		}
	}

	fmt.printf("=== Storage audit: %d checked, %d failed ===\n", total_c, total_f)
	if total_f > 0 { os.exit(1) }
}

// Persist-order audit (rule s7): in commit procedures that persist an
// entry and then reclaim the previous chain, no deallocating call may
// textually precede the persisting write_entry_at call. A crash between
// free and persist would leave the on-disk entry pointing at freed
// sectors; the enforced order reduces every crash to either "nothing
// happened" (pre-persist) or "leaked but valid" (post-persist, the
// checker reclaims). set_entry_name performs no persist itself, so it
// must contain no deallocating call at all (callers free only the
// returned chain after persisting).
//
// xattr_store is deliberately exempt: its single deallocate targets
// only the just-allocated, still unpublished chain on the write-failure
// path, with the entry left untouched.
audit_persist_order_one :: proc(path: string, lines: []string, rule_proc: string, needs_write: bool) -> (checked: int, failed: int) {
	start := -1
	for i in 0 ..< len(lines) {
		if len(lines[i]) > len(rule_proc) && strings.has_prefix(lines[i], rule_proc) && strings.has_prefix(lines[i][len(rule_proc):], " :: proc") {
			start = i
			break
		}
	}
	if start < 0 {
		fmt.printf("FAIL   %s: %s not found\n", path, rule_proc)
		return 1, 1
	}
	end := len(lines)
	for i in start + 1 ..< len(lines) {
		if lines[i] == "}" {
			end = i
			break
		}
	}
	checked = 1
	write_at := -1
	for i in start ..< end {
		trimmed := strings.trim_space(lines[i])
		if strings.has_prefix(trimmed, "//") { continue }
		if strings.contains(lines[i], "write_entry_at(") {
			write_at = i
			break
		}
	}
	for i in start ..< end {
		trimmed := strings.trim_space(lines[i])
		if strings.has_prefix(trimmed, "//") { continue }
		is_free := strings.contains(lines[i], "deallocate_sectors(") ||
			strings.contains(lines[i], "xattr_free_chain(") ||
			strings.contains(lines[i], "free_entry_lfn(")
		if !is_free { continue }
		if !needs_write || write_at < 0 || i < write_at {
			fmt.printf("FAIL   %s:%d %s frees before persisting\n", path, i + 1, rule_proc)
			failed = 1
			return
		}
	}
	return
}

run_persist_order_audit :: proc() {
	total_c, total_f := 0, 0
	targets := []struct {
		path:        string,
		rule:       string,
		needs_write: bool,
	} {
		{"src/mounter/create.odin", "remove_directory_entry", true},
		{"src/mounter/create.odin", "rename_publish", true},
		{"src/mounter/xattr.odin", "xattr_publish", true},
		{"src/mounter/dir.odin", "set_entry_name", false},
	}
	for t in targets {
		data, err := os.read_entire_file(t.path, context.temp_allocator)
		if err != nil {
			fmt.printf("FAIL   %s: cannot read\n", t.path)
			total_c += 1
			total_f += 1
			continue
		}
		lines := strings.split(string(data), "\n", context.temp_allocator)
		c, f := audit_persist_order_one(t.path, lines, t.rule, t.needs_write)
		total_c += c
		total_f += f
	}

	fmt.printf("=== Persist-order audit: %d checked, %d failed ===\n", total_c, total_f)
	if total_f > 0 { os.exit(1) }
}
