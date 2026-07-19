// audit.odin — Audit FUSE callbacks for begin_op() usage.
package main

import "core:odin/ast"
import "core:odin/parser"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

main :: proc() {
	dh, err := os.open("src/mounter")
	if err == nil {
		defer os.close(dh)
		run_audit(dh)
	} else {
		fmt.eprintf("cannot open src/mounter: %v\n", err)
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
		case ^ast.Value_Decl: vd = v
		}
		if vd == nil { continue }
		if len(vd.names) == 0 { continue }

		name_ident: ^ast.Ident
		#partial switch v in vd.names[0].derived_expr {
		case ^ast.Ident: name_ident = v
		}
		if name_ident == nil || !strings.has_prefix(name_ident.name, "fused_") {
		 continue
		}

		name := name_ident.name
		if len(vd.values) == 0 { continue }

		proc_lit: ^ast.Proc_Lit
		#partial switch v in vd.values[0].derived_expr {
		case ^ast.Proc_Lit: proc_lit = v
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
		case ^ast.Block_Stmt: block = v
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
