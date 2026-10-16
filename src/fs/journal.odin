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
	(^Master_Record)(raw_data(buf[:]))^ = vol.master
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

JOURNAL_SLOT_STRIDE ::
	(MAX_JOURNAL_ENTRIES + JOURNAL_ENTRIES_PER_RECORD - 1) / JOURNAL_ENTRIES_PER_RECORD + 1

journal_commit :: proc(vol: ^Volume, txn: ^Journal_Txn) -> bool {
	if txn.count == 0 { return true }
	if txn.count > MAX_JOURNAL_ENTRIES {
		log.errorf("journal: transaction too large (%d entries)", txn.count)
		return false
	}

	J := journal_region_base(&vol.master)
	M := journal_region_size(&vol.master)
	// Each slot reserves one header sector plus the maximum record sectors,
	// so adjacent transactions can never overlap. Recovery still scans every
	// sector (not just slot starts), so journals written by older code stay
	// readable.
	slot_count := M / JOURNAL_SLOT_STRIDE
	if slot_count == 0 {
		log.errorf("journal: region too small (%d sectors)", M)
		return false
	}

	pos := J + Sector((u64(txn.seq) % slot_count) * JOURNAL_SLOT_STRIDE)
	rec_secs := u16((txn.count + JOURNAL_ENTRIES_PER_RECORD - 1) / JOURNAL_ENTRIES_PER_RECORD)
	for ri in 0 ..< rec_secs {
		rec_buf: [SECTOR_SIZE]u8
		rec := (^Journal_Record)(raw_data(rec_buf[:]))
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

	if !volume_sync(vol) { return false }
	hdr := Journal_Header {
		magic       = JOURNAL_WAL_MAGIC,
		seq         = u64(txn.seq),
		rec_count   = u16(txn.count),
		rec_sectors = rec_secs,
		committed   = 1,
		tail_magic  = JOURNAL_WAL_MAGIC,
	}

	hdr_buf: [SECTOR_SIZE]u8
	hdr_ptr := (^Journal_Header)(raw_data(hdr_buf[:]))
	hdr_ptr^ = hdr
	hdr.header_crc = hash.crc32(hdr_buf[:24])
	hdr_ptr^ = hdr
	if sector_write(vol, pos, hdr_buf[:]) != .None {
		return false
	}
	if !volume_sync(vol) { return false }
	return true
}

// journal_finish checkpoints a committed transaction: the sequence always
// advances (preserving the slot even when home-apply failed), while the
// watermark advances only when the home writes landed — recovery then
// completes the chunk instead of skipping it (ADR-001). The write itself
// is unsynced: a lost checkpoint only causes (idempotent) re-replay.
// Safety comes from the home sync BEFORE this write (see flush): the
// watermark must never overtake undurable home tables.
journal_finish :: proc(vol: ^Volume, seq: Journal_Seq, applied: bool) -> bool {
	if applied {
		journal_set_watermark(&vol.master, u64(seq))
	}

	journal_seq_set(&vol.master, Journal_Seq(u64(seq) + 1))
	if write_master_record(vol) != .None { return false }
	return true
}

@(private = "file")
Slot_Entry :: struct {
	pos: Sector,
	hdr: Journal_Header,
}

// _slot_seq_cmp orders journal slots by ascending sequence number for the
// recovery sort: older transactions replay before newer ones that may
// overwrite the same Cluster_Entry.
@(private = "file")
_slot_seq_cmp :: proc(a, b: Slot_Entry) -> int {
	if a.hdr.seq < b.hdr.seq { return -1 }
	if a.hdr.seq > b.hdr.seq { return +1 }
	return 0
}

// _replay_slot replays one committed transaction slot, returning the entry
// count and whether the slot completed. A torn record sector, an invalid
// entry, or any target table I/O failure aborts the slot (completed=false,
// watermark not advanced); the caller must stop at the first incomplete
// slot so later sequences cannot slip past it.
@(private = "file")
_replay_slot :: proc(vol: ^Volume, s: Slot_Entry) -> (replayed: int, completed: bool) {
	for ri: u16; ri < s.hdr.rec_sectors; ri += 1 {
		rec_buf: [SECTOR_SIZE]u8
		if sector_read(vol, s.pos + Sector(ri) + 1, rec_buf[:]) != .None {
			log.warnf("journal: can't read record sector %d — aborting replay", ri)
			return replayed, false
		}

		rec := (^Journal_Record)(raw_data(rec_buf[:]))
		for ei in 0 ..< JOURNAL_ENTRIES_PER_RECORD {
			idx := int(ri) * JOURNAL_ENTRIES_PER_RECORD + ei
			if idx >= int(s.hdr.rec_count) { break }

			je := rec.entries[ei]
			want := Cluster_Entry {
				state             = transmute(Cluster_Entry_State)je.state,
				allocation_size   = je.alloc_size,
				sector_start      = je.sector_start,
				next_cluster      = je.next_cluster,
				next_sector_index = je.next_sector_index,
			}

			table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
			if read_cluster_entry_table(vol, Cluster(je.cluster), &table) != .None {
				log.warnf(
					"journal: can't read table for cluster %d — aborting replay",
					je.cluster,
				)
				return replayed, false
			}
			if int(je.ce_index) >= len(table) {
				log.warnf("journal: bad ce_index %d — aborting replay", je.ce_index)
				return replayed, false
			}
			// Idempotence compares the entire entry: matching only state bits
			// could miss a size/start/link difference with identical flags.
			if table[je.ce_index] == want {
				continue
			}

			table[je.ce_index] = want
			// A failed table write aborts the slot like a torn record
			// sector: the watermark does not advance, so a later recover
			// retries instead of skipping a half-applied transaction.
			if werr := write_cluster_entry_table(vol, Cluster(je.cluster), &table); werr != .None {
				log.warnf(
					"journal: can't write table for cluster %d — aborting replay",
					je.cluster,
				)
				return replayed, false
			}
			replayed += 1
		}
	}
	return replayed, true
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
	valid: [dynamic]Slot_Entry
	delete(valid)

	valid = make([dynamic]Slot_Entry, 0, int(M), context.temp_allocator)
	for i: u64; i < M; i += 1 {
		pos := J + Sector(i)
		hdr_buf: [SECTOR_SIZE]u8
		if sector_read(vol, pos, hdr_buf[:]) != .None { continue }

		hdr := (^Journal_Header)(raw_data(hdr_buf[:]))^
		if hdr.magic != JOURNAL_WAL_MAGIC { continue }
		if hdr.tail_magic != JOURNAL_WAL_MAGIC {
			log.warnf("journal: torn header at sector %d — discarding", pos)
			continue
		}
		if hdr.rec_count == 0 || hdr.rec_count > MAX_JOURNAL_ENTRIES {
			log.warnf("journal: bad rec_count %d at sector %d — discarding", hdr.rec_count, pos)
			continue
		}

		want_secs := u16(
			(u64(hdr.rec_count) + JOURNAL_ENTRIES_PER_RECORD - 1) / JOURNAL_ENTRIES_PER_RECORD,
		)
		if hdr.rec_sectors != want_secs {
			log.warnf(
				"journal: bad rec_sectors %d at sector %d — discarding",
				hdr.rec_sectors,
				pos,
			)
			continue
		}

		crc_buf: [24]u8
		copy(crc_buf[:], hdr_buf[:24])

		crc_buf[22] = 0
		crc_buf[23] = 0
		if hash.crc32(crc_buf[:]) != hdr.header_crc {
			log.warnf("journal: bad header crc at sector %d — discarding", pos)
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
	sort.quick_sort_proc(valid[:], _slot_seq_cmp)
	replayed: int
	for s in valid {
		log.infof(
			"journal: replaying seq=%d (%d entries, %d sectors)",
			s.hdr.seq,
			s.hdr.rec_count,
			s.hdr.rec_sectors,
		)

		n, completed := _replay_slot(vol, s)
		replayed += n
		if !completed {
			log.warnf("journal: seq=%d incomplete — stopping replay", s.hdr.seq)
			break
		}
		W = s.hdr.seq + 1
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
// Semantics (see ADR-001):
//   begin  — open a transaction (always succeeds; nothing is persisted yet).
//   add    — record one CE-table write; returns false when the txn is full.
//   commit — persist records + header and sync (log durable). Home tables
//            are untouched; a commit failure leaves nothing to repair.
//   finish — checkpoint: advance the sequence always (preserving the slot),
//            the watermark only when home-apply succeeded.
//   abort  — discard uncommitted in-memory entries (pre-commit only).
//   recover — replay leftover state from a previous crash, in seq order.
Journal_Backend :: struct {
	begin:   proc(vol: ^Volume, h: ^Journal_Txn_Handle) -> bool,
	add:     proc(vol: ^Volume, h: ^Journal_Txn_Handle, e: Journal_Entry) -> bool,
	commit:  proc(vol: ^Volume, h: ^Journal_Txn_Handle) -> bool,
	finish:  proc(vol: ^Volume, h: ^Journal_Txn_Handle, applied: bool) -> bool,
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
	return journal_commit(vol, &h.v2)
}

@(private = "file")
_j_finish :: proc(vol: ^Volume, h: ^Journal_Txn_Handle, applied: bool) -> bool {
	return journal_finish(vol, h.v2.seq, applied)
}

@(private = "file")
_j_abort :: proc(vol: ^Volume, h: ^Journal_Txn_Handle) {
	// Discards only the uncommitted chunk; already-committed chunks persist
	// and stay replayable. See the backend semantics above.
	_ = h
}

// JOURNAL_BACKEND is the physical redo-log WAL: the only journal.
JOURNAL_BACKEND :: Journal_Backend {
	begin   = _j_begin,
	add     = _j_add,
	commit  = _j_commit,
	finish  = _j_finish,
	abort   = _j_abort,
	recover = journal_recover,
}

// journal_apply_entries writes a committed chunk to its home CE tables,
// grouping by cluster so each table is read and written once. Order
// within a cluster follows plan order (stable first-appearance grouping);
// same-slot repeats overwrite in memory before the single write.
journal_apply_entries :: proc(vol: ^Volume, entries: []Journal_Entry) -> FS_Error {
	seen: [dynamic]u64
	defer delete(seen)
	for i in 0 ..< len(entries) {
		cl := entries[i].cluster
		skip := false
		for d in seen {
			if d == cl { skip = true; break }
		}
		if skip { continue }

		append(&seen, cl)
		table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
		if read_cluster_entry_table(vol, Cluster(cl), &table) != .None {
			return .Sector_Read_Error
		}
		for e in entries {
			if e.cluster != cl { continue }
			if int(e.ce_index) >= len(table) { return .Sector_Write_Error }
			table[e.ce_index] = Cluster_Entry {
				state             = transmute(Cluster_Entry_State)e.state,
				allocation_size   = e.alloc_size,
				sector_start      = e.sector_start,
				next_cluster      = e.next_cluster,
				next_sector_index = e.next_sector_index,
			}
		}
		if write_cluster_entry_table(vol, Cluster(cl), &table) != .None {
			return .Sector_Write_Error
		}
	}
	return .None
}

// journal_flush_chunk commits one bounded plan chunk log-before-home (see
// ADR-001): records + header go durable first; home tables apply after;
// the checkpoint advances only once home is durable. A commit failure
// leaves home untouched; an apply failure holds the watermark so the next
// recover completes the chunk from the committed log.
journal_flush_chunk :: proc(vol: ^Volume, entries: []Journal_Entry) -> FS_Error {
	if len(entries) == 0 { return .None }
	if len(entries) > MAX_JOURNAL_ENTRIES {
		log.errorf("journal: chunk too large (%d entries)", len(entries))
		return .Sector_Write_Error
	}

	backend := JOURNAL_BACKEND
	h: Journal_Txn_Handle
	if !backend.begin(vol, &h) { return .Sector_Write_Error }
	for e in entries {
		// Cannot fail: the chunk fits a fresh transaction by construction.
		if !backend.add(vol, &h, e) {
			backend.abort(vol, &h)
			return .Sector_Write_Error
		}
	}
	if !backend.commit(vol, &h) {
		backend.abort(vol, &h)
		return .Sector_Write_Error
	}
	if aerr := journal_apply_entries(vol, entries); aerr != .None {
		backend.finish(vol, &h, false)
		return aerr
	}
	// Home must be durable before the checkpoint below may persist: if
	// this sync fails, hold the watermark so recovery completes the chunk.
	if !volume_sync(vol) {
		backend.finish(vol, &h, false)
		return .Sector_Write_Error
	}
	if !backend.finish(vol, &h, true) { return .Sector_Write_Error }
	return .None
}
