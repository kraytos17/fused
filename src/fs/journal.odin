// journal.odin — Physical redo-log WAL for crash-consistent
// metadata transactions.
//
// Before any multi-write allocation or deallocation, the transaction's
// Cluster_Entry writes are recorded in a dedicated journal region (right
// after the CME table) keyed by sequence number. After all writes complete,
// the master seq/watermark advance. A crashed transaction is replayed in
// seq order on the next mount.
#+build linux
package fs

import "core:hash"
import "core:log"
import "core:mem"
import "core:os"
import "core:sort"

journal_region_base :: proc(master: ^Master_Record) -> Sector {
	cme_ps := u64(CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_secs := (master.cluster_map_size + cme_ps - 1) / cme_ps
	return Sector(master.cluster_map_offset + cm_secs)
}

journal_seq_get :: proc(master: ^Master_Record) -> Journal_Seq {
	return mem.reinterpret_copy(Journal_Seq, &master.resv[JOURNAL_SEQ_OFFSET])
}

journal_seq_set :: proc(master: ^Master_Record, seq: Journal_Seq) {
	(^Journal_Seq)(&master.resv[JOURNAL_SEQ_OFFSET])^ = seq
}

journal_seq_init :: proc(master: ^Master_Record) {
	journal_seq_set(master, 1)
}

write_master_record :: proc(vol: ^Volume) -> FS_Error {
	buf: [SECTOR_SIZE]u8
	(^Master_Record)(&buf[0])^ = vol.master
	return sector_write(vol, Sector(0), buf[:])
}

Journal_Txn :: struct {
	seq:     Journal_Seq,
	entries: [MAX_JOURNAL_ENTRIES]Journal_Entry,
	count:   int,
}

journal_region_size :: proc(master: ^Master_Record) -> u64 {
	n := mem.reinterpret_copy(u64, &master.resv[JOURNAL_REGION_OFFSET])
	if n == 0 { n = 64 }
	return n
}

journal_set_region_size :: proc(master: ^Master_Record, n: u64) {
	(^u64)(&master.resv[JOURNAL_REGION_OFFSET])^ = n
}

journal_watermark :: proc(master: ^Master_Record) -> u64 {
	return mem.reinterpret_copy(u64, &master.resv[JOURNAL_WATERMARK_OFFSET])
}

journal_set_watermark :: proc(master: ^Master_Record, w: u64) {
	(^u64)(&master.resv[JOURNAL_WATERMARK_OFFSET])^ = w
}

journal_begin :: proc(master: ^Master_Record, txn: ^Journal_Txn) {
	txn.seq = journal_seq_get(master)
	txn.count = 0
}

journal_add_entry :: proc(txn: ^Journal_Txn, entry: Journal_Entry) -> bool {
	if txn.count >= MAX_JOURNAL_ENTRIES {
		log.errorf("journal: transaction full (%d entries)", txn.count)
		return false
	}

	txn.entries[txn.count] = entry
	txn.count += 1
	return true
}

journal_commit :: proc(vol: ^Volume, txn: ^Journal_Txn) -> bool {
	if txn.count == 0 { return true }

	J := journal_region_base(&vol.master)
	M := journal_region_size(&vol.master)
	pos := J + Sector(u64(txn.seq) % M)
	rec_secs := u16((txn.count + JOURNAL_ENTRIES_PER_RECORD - 1) / JOURNAL_ENTRIES_PER_RECORD)
	for ri in 0 ..< rec_secs {
		rec_buf: [SECTOR_SIZE]u8
		rec := (^Journal_Record)(&rec_buf[0])
		base := int(ri) * JOURNAL_ENTRIES_PER_RECORD
		for ei in 0 ..< JOURNAL_ENTRIES_PER_RECORD {
			idx := base + ei
			if idx >= txn.count { break }
			rec.entries[ei] = txn.entries[idx]
		}
		if sector_write(vol, pos + Sector(ri) + 1, rec_buf[:]) != .None {
			return false
		}
	}

	os.sync(vol.disk)
	hdr := Journal_Header {
		magic       = JOURNAL_WAL_MAGIC,
		seq         = u64(txn.seq),
		rec_count   = u16(txn.count),
		rec_sectors = rec_secs,
		committed   = 1,
		tail_magic  = JOURNAL_WAL_MAGIC,
	}

	hdr_buf: [SECTOR_SIZE]u8
	(^Journal_Header)(&hdr_buf[0])^ = hdr
	hdr.header_crc = hash.crc32(hdr_buf[:24])

	(^Journal_Header)(&hdr_buf[0])^ = hdr
	if sector_write(vol, pos, hdr_buf[:]) != .None {
		return false
	}

	os.sync(vol.disk)
	return true
}

journal_finish :: proc(vol: ^Volume, seq: Journal_Seq) {
	journal_seq_set(&vol.master, Journal_Seq(u64(seq) + 1))
	journal_set_watermark(&vol.master, u64(seq))
	write_master_record(vol)
}

@(cold, optimization_mode = "favor_size")
journal_recover :: proc(vol: ^Volume) {
	J := journal_region_base(&vol.master)
	M := journal_region_size(&vol.master)
	W := journal_watermark(&vol.master)

	// Collect valid committed transactions. Each slot carries the sector
	// position and the header so we can replay in seq order — the ring
	// buffer's physical order is not guaranteed to match sequence order
	// after wraparound.
	Slot_Entry :: struct {
		pos: Sector,
		hdr: Journal_Header,
	}

	valid: [dynamic]Slot_Entry
	delete(valid)

	valid = make([dynamic]Slot_Entry, 0, int(M), context.temp_allocator)
	for i: u64; i < M; i += 1 {
		pos := J + Sector(i)
		hdr_buf: [SECTOR_SIZE]u8
		if sector_read(vol, pos, hdr_buf[:]) != .None { continue }

		hdr := (^Journal_Header)(&hdr_buf[0])^
		if hdr.magic != JOURNAL_WAL_MAGIC { continue }
		if hdr.tail_magic != JOURNAL_WAL_MAGIC {
			log.warnf("journal: torn header at sector %d — discarding", pos)
			continue
		}
		if hdr.seq < W { continue }
		if hdr.committed != 1 {
			log.warnf("journal: incomplete txn seq=%d at sector %d — discarding", hdr.seq, pos)
			continue
		}
		append(&valid, Slot_Entry{pos = pos, hdr = hdr})
	}

	// Sort by sequence number ascending so older transactions are replayed
	// before newer ones that may overwrite the same Cluster_Entry.
	sort.quick_sort_proc(valid[:], proc(a, b: Slot_Entry) -> int {
		if a.hdr.seq < b.hdr.seq { return -1 }
		if a.hdr.seq > b.hdr.seq { return +1 }
		return 0
	})

	replayed: int
	for s in valid {
		log.infof(
			"journal: replaying seq=%d (%d entries, %d sectors)",
			s.hdr.seq,
			s.hdr.rec_count,
			s.hdr.rec_sectors,
		)

		replay_ok := true
		for ri: u16; ri < s.hdr.rec_sectors; ri += 1 {
			rec_buf: [SECTOR_SIZE]u8
			if sector_read(vol, s.pos + Sector(ri) + 1, rec_buf[:]) != .None {
				log.warnf("journal: can't read record sector %d — aborting replay", ri)
				replay_ok = false
				break
			}

			rec := (^Journal_Record)(&rec_buf[0])
			for ei in 0 ..< JOURNAL_ENTRIES_PER_RECORD {
				idx := int(ri) * JOURNAL_ENTRIES_PER_RECORD + ei
				if idx >= int(s.hdr.rec_count) { break }

				je := rec.entries[ei]
				table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
				if read_cluster_entry_table(vol, Cluster(je.cluster), &table) != .None {
					continue
				}
				if int(je.ce_index) >= len(table) {
					continue
				}

				ce := table[je.ce_index]
				if .Allocated in ce.state && transmute(u8)ce.state == je.state {
					continue
				}

				table[je.ce_index] = Cluster_Entry {
					state             = transmute(Cluster_Entry_State)je.state,
					allocation_size   = je.alloc_size,
					sector_start      = je.sector_start,
					next_cluster      = je.next_cluster,
					next_sector_index = je.next_sector_index,
				}

				_ = write_cluster_entry_table(vol, Cluster(je.cluster), &table)
				replayed += 1
			}
		}
		if replay_ok {
			W = s.hdr.seq + 1
		}
	}

	old_W := journal_watermark(&vol.master)
	journal_set_watermark(&vol.master, W)
	if replayed > 0 || W > old_W {
		write_master_record(vol)
	}
	if replayed > 0 {
		log.infof("journal: replayed %d entries", replayed)
	}
}

// Journal_Txn_Handle carries the per-transaction state of the journal.
Journal_Txn_Handle :: struct {
	v2: Journal_Txn,
}

// journal_entry_from_cluster_entry builds a full redo Journal_Entry from a
// Cluster_Entry write so allocation/deallocation construct it in one place.
journal_entry_from_cluster_entry :: proc(
	ce: Cluster_Entry,
	cluster: u64,
	ce_index: u8,
) -> Journal_Entry {
	return Journal_Entry {
		cluster = cluster,
		ce_index = ce_index,
		state = transmute(u8)ce.state,
		sector_start = ce.sector_start,
		alloc_size = ce.allocation_size,
		next_cluster = ce.next_cluster,
		next_sector_index = ce.next_sector_index,
	}
}

// Journal_Backend is the physical redo-log WAL behind a procedure table
// so allocation/deallocation journal through one interface. The table is
// kept (rather than direct calls) so a future journal format only adds a
// new backend value.
//
// Semantics:
//   begin  — open a transaction (always succeeds; nothing is persisted yet).
//   add    — record one CE-table write; returns false when the txn is full.
//   commit — persist the transaction and advance the master journal state.
//   abort  — discard the transaction. Nothing was persisted before commit,
//            so it is a no-op. Discards on error.
//   recover — replay leftover state from a previous crash, in seq order.
Journal_Backend :: struct {
	begin:   proc(vol: ^Volume, h: ^Journal_Txn_Handle) -> bool,
	add:     proc(vol: ^Volume, h: ^Journal_Txn_Handle, e: Journal_Entry) -> bool,
	commit:  proc(vol: ^Volume, h: ^Journal_Txn_Handle) -> bool,
	abort:   proc(vol: ^Volume, h: ^Journal_Txn_Handle),
	recover: proc(vol: ^Volume),
}

// Backend adapters — physical redo-log WAL (rev 7+; the only journal).
@(private = "file")
_j_begin :: proc(vol: ^Volume, h: ^Journal_Txn_Handle) -> bool {
	journal_begin(&vol.master, &h.v2)
	return true
}

@(private = "file")
_j_add :: proc(vol: ^Volume, h: ^Journal_Txn_Handle, e: Journal_Entry) -> bool {
	return journal_add_entry(&h.v2, e)
}

@(private = "file")
_j_commit :: proc(vol: ^Volume, h: ^Journal_Txn_Handle) -> bool {
	if !journal_commit(vol, &h.v2) {
		return false
	}
	journal_finish(vol, h.v2.seq)
	return true
}

@(private = "file")
_j_abort :: proc(vol: ^Volume, h: ^Journal_Txn_Handle) {
	// Nothing was persisted before commit; discarding is a no-op.
}

// JOURNAL_BACKEND is the physical redo-log WAL: the only journal.
JOURNAL_BACKEND :: Journal_Backend {
	begin   = _j_begin,
	add     = _j_add,
	commit  = _j_commit,
	abort   = _j_abort,
	recover = journal_recover,
}
