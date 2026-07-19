// display.odin — Human-readable flag and struct string formatters.
#+build linux
package fs

import "core:strings"

write_flag :: proc(sb: ^strings.Builder, n: ^int, name: string) {
	if n^ > 0 { strings.write_byte(sb, '|') }
	strings.write_string(sb, name)
	n^ += 1
}

// cme_flags_str formats Cluster_Map_Flags into a human-readable string
cme_flags_str :: proc(f: Cluster_Map_Flags, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in f { write_flag(&sb, &n, "ALLOCATED") }
	if .Reserved in f  { write_flag(&sb, &n, "RESERVED") }
	if .Full in f      { write_flag(&sb, &n, "FULL") }
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

// ce_state_str formats Cluster_Entry_State into a human-readable string
ce_state_str :: proc(s: Cluster_Entry_State, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated   in s { write_flag(&sb, &n, "ALLOCATED") }
	if .Cluster_Map in s { write_flag(&sb, &n, "CLUSTER_MAP") }
	if .Directory   in s { write_flag(&sb, &n, "DIRECTORY") }
	if .File_Content in s { write_flag(&sb, &n, "FILE_CONTENT") }
	if .LFN         in s { write_flag(&sb, &n, "LFN") }
	if n == 0 { return "0" }
	return strings.to_string(sb)
}

// dir_flags_str formats Dir_Flags into a human-readable string
dir_flags_str :: proc(f: Dir_Flags, buf: []byte) -> string {
	sb := strings.builder_from_slice(buf)
	n := 0
	if .Allocated in f { write_flag(&sb, &n, "ALLOCATED") }
	if .LFN       in f { write_flag(&sb, &n, "LFN") }
	if .Directory in f { write_flag(&sb, &n, "DIRECTORY") }
	if .Read_Only in f { write_flag(&sb, &n, "READONLY") }
	if .Link      in f { write_flag(&sb, &n, "LINK") }
	if .Exists    in f { write_flag(&sb, &n, "EXISTS") }
	if .No_Write  in f { write_flag(&sb, &n, "NOWRITE") }
	if .No_Read   in f { write_flag(&sb, &n, "NOREAD") }
	if .No_Execute in f { write_flag(&sb, &n, "NOEXEC") }
	if n == 0 { return "0" }
	return strings.to_string(sb)
}
