// display.odin — Human-readable flag and struct string formatters.
#+build linux
package fs

import "core:strings"

cme_flags_str :: proc(f: Cluster_Map_Flags, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "ALLOCATED"); n += 1
	}
	if .Reserved in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "RESERVED"); n += 1
	}
	if .Full in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "FULL"); n += 1
	}
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

ce_state_str :: proc(s: Cluster_Entry_State, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "ALLOCATED"); n += 1
	}
	if .Cluster_Map in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "CLUSTER_MAP"); n += 1
	}
	if .Directory in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "DIRECTORY"); n += 1
	}
	if .File_Content in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "FILE_CONTENT"); n += 1
	}
	if .LFN in s {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "LFN"); n += 1
	}
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

dir_flags_str :: proc(f: Dir_Flags, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "ALLOCATED"); n += 1
	}
	if .LFN in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "LFN"); n += 1
	}
	if .Directory in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "DIRECTORY"); n += 1
	}
	if .Read_Only in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "READONLY"); n += 1
	}
	if .Link in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "LINK"); n += 1
	}
	if .Exists in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "EXISTS"); n += 1
	}
	if .No_Write in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "NOWRITE"); n += 1
	}
	if .No_Read in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "NOREAD"); n += 1
	}
	if .No_Execute in f {
		if n > 0 { strings.write_byte(&sb, '|') }; strings.write_string(&sb, "NOEXEC"); n += 1
	}
	if n == 0 { return "0" }
	return strings.to_string(sb)
}
