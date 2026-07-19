// journal.odin — Intent log for crash-consistent metadata transactions.
//
// Before any multi-write allocation or deallocation, the intent log is
// written to a dedicated sector (right after the CME table). After all
// writes complete, it is cleared. A dirty log on mount indicates an
// incomplete transaction from a crash.
#+build linux
package fs

import "core:hash"
import "core:log"
import "core:mem"
import "core:os"

intent_log_sector :: proc(master: ^Master_Record) -> Sector {
	cme_ps := u64(CLUSTER_MAP_ENTRIES_PER_SECTOR)
	cm_secs := (master.cluster_map_size + cme_ps - 1) / cme_ps
	return Sector(master.cluster_map_offset + cm_secs)
}

journal_seq_get :: proc(master: ^Master_Record) -> Journal_Seq {
	seq: Journal_Seq
	mem.copy(&seq, &master.resv[JOURNAL_SEQ_OFFSET], size_of(Journal_Seq))
	return seq
}

journal_seq_set :: proc(master: ^Master_Record, seq: Journal_Seq) {
	s := seq
	mem.copy(&master.resv[JOURNAL_SEQ_OFFSET], &s, size_of(Journal_Seq))
}

journal_seq_init :: proc(master: ^Master_Record) {
	journal_seq_set(master, 1)
}

journal_seq_next :: proc(master: ^Master_Record) -> Journal_Seq {
	seq := journal_seq_get(master)
	if seq == 0 { seq = 1 }
	return seq
}

@private
intent_log_read :: proc(vol: ^Volume) -> (intent_log: Intent_Log, ok: bool) {
	raw: [SECTOR_SIZE]u8
	if !sector_read(vol, intent_log_sector(&vol.master), raw[:]) {
		return {}, false
	}

	intent_log = (^Intent_Log)(&raw[0])^
	if intent_log.magic != 0 && intent_log.magic != JOURNAL_MAGIC {
		return {}, false
	}
	if intent_log.magic == JOURNAL_MAGIC {
		crc := hash.crc32(raw[:SECTOR_SIZE - 4])
		if crc != intent_log.crc {
			log.warnf("intent log CRC mismatch: expected %d, got %d", intent_log.crc, crc)
			return {}, false
		}
	}
	return intent_log, true
}

@private
intent_log_write :: proc(vol: ^Volume, log: ^Intent_Log) -> bool {
	raw: [SECTOR_SIZE]u8
	dst := (^Intent_Log)(&raw[0])
	dst^ = log^
	dst.crc = hash.crc32(raw[:SECTOR_SIZE - 4])
	if !sector_write(vol, intent_log_sector(&vol.master), raw[:]) {
		return false
	}
	os.sync(vol.disk)
	return true
}

intent_log_begin :: proc(vol: ^Volume) -> bool {
	seq := journal_seq_next(&vol.master)
	log := Intent_Log{
		magic = JOURNAL_MAGIC,
		seq   = u64(seq),
		count = 0,
	}
	return intent_log_write(vol, &log)
}

intent_log_commit :: proc(vol: ^Volume, entries: []Intent_Log_Entry) -> bool {
	if entries != nil && len(entries) > 0 {
		seq := journal_seq_get(&vol.master)
		log := Intent_Log{
			magic = JOURNAL_MAGIC,
			seq   = u64(seq),
			count = u16(len(entries)),
		}

		for i in 0 ..< min(len(entries), MAX_JOURNAL_ENTRIES_v6) {
			log.entries[i] = entries[i]
		}
		if !intent_log_write(vol, &log) {
			return false
		}
	}

	zero: [SECTOR_SIZE]u8
	if !sector_write(vol, intent_log_sector(&vol.master), zero[:]) {
		return false
	}

	journal_seq_set(&vol.master, journal_seq_get(&vol.master) + 1)
	if !write_master_record(vol) {
		return false
	}
	return true
}

write_master_record :: proc(vol: ^Volume) -> bool {
	buf: [SECTOR_SIZE]u8
	(^Master_Record)(&buf[0])^ = vol.master
	return sector_write(vol, Sector(0), buf[:])
}

intent_log_recover :: proc(vol: ^Volume) {
	intent_log, ok := intent_log_read(vol)
	if !ok || intent_log.magic != JOURNAL_MAGIC {
		return
	}

	log.warnf("intent log dirty: seq=%d entries=%d — incomplete allocation from crash",
		intent_log.seq, intent_log.count)

	table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
	for i in 0 ..< int(intent_log.count) {
		entry := intent_log.entries[i]
		if !read_cluster_entry_table(vol, Cluster(entry.cluster), &table) {
			log.warnf("  entry %d: cluster %d — CE table not readable (may be corrupted)", i, entry.cluster)
			continue
		}

		ce := table[entry.ce_index]
		if .Allocated not_in ce.state {
			log.warnf("  entry %d: cluster %d ce[%d] — expected Allocated, found free", i, entry.cluster, entry.ce_index)
		}
	}

	log.warnf("clearing intent log — run fsck --fix for full consistency check")
	if !intent_log_commit(vol, nil) {
		log.errorf("failed to clear intent log — mount may be unstable")
	}
}

Journal_Txn :: struct {
	seq:     Journal_Seq,
	entries: [MAX_JOURNAL_ENTRIES_v6]Journal_Entry,
	count:   int,
}

Intent_Txn :: struct {
	entries: [MAX_JOURNAL_ENTRIES_v6]Intent_Log_Entry,
	count:   int,
}

intent_txn_add :: proc(txn: ^Intent_Txn, cluster_idx: u64, free_idx: int, take: u16, state: u8) -> bool {
	if txn.count >= MAX_JOURNAL_ENTRIES_v6 { return false }
	txn.entries[txn.count] = {
		cluster       = cluster_idx,
		sector_offset = 0,
		ce_index      = u8(free_idx),
		alloc_size    = take,
		state         = state,
	}
	txn.count += 1
	return true
}

journal_v2_region_size :: proc(master: ^Master_Record) -> u64 {
	n: u64
	mem.copy(&n, &master.resv[JOURNAL_REGION_OFFSET], size_of(u64))
	if n == 0 { n = 64 }
	return n
}

journal_v2_set_region_size :: proc(master: ^Master_Record, n: u64) {
	s := n
	mem.copy(&master.resv[JOURNAL_REGION_OFFSET], &s, size_of(u64))
}

journal_v2_watermark :: proc(master: ^Master_Record) -> u64 {
	w: u64
	mem.copy(&w, &master.resv[JOURNAL_WATERMARK_OFFSET], size_of(u64))
	return w
}

journal_v2_set_watermark :: proc(master: ^Master_Record, w: u64) {
	s := w
	mem.copy(&master.resv[JOURNAL_WATERMARK_OFFSET], &s, size_of(u64))
}

journal_v2_begin :: proc(master: ^Master_Record, txn: ^Journal_Txn) {
	txn.seq = journal_seq_get(master)
	txn.count = 0
}

journal_v2_add_entry :: proc(txn: ^Journal_Txn, entry: Journal_Entry) -> bool {
	if txn.count >= JOURNAL_ENTRIES_PER_RECORD {
		log.errorf("journal_v2: transaction full (%d entries)", txn.count)
		return false
	}

	txn.entries[txn.count] = entry
	txn.count += 1
	return true
}

journal_v2_commit :: proc(vol: ^Volume, txn: ^Journal_Txn) -> bool {
	if txn.count == 0 { return true }

	J := intent_log_sector(&vol.master)
	M := journal_v2_region_size(&vol.master)
	pos := J + Sector(u64(txn.seq) % M)
	rec_secs := u16((txn.count + JOURNAL_ENTRIES_PER_RECORD - 1) / JOURNAL_ENTRIES_PER_RECORD)

	for ri in 0 ..< rec_secs {
		rec_buf: [SECTOR_SIZE]u8
		rec := (^Jv2_Record)(&rec_buf[0])
		base := int(ri) * JOURNAL_ENTRIES_PER_RECORD
		for ei in 0 ..< JOURNAL_ENTRIES_PER_RECORD {
			idx := base + ei
			if idx >= txn.count { break }
			rec.entries[ei] = txn.entries[idx]
		}
		if !sector_write(vol, pos + Sector(ri) + 1, rec_buf[:]) {
			return false
		}
	}

	os.sync(vol.disk)
	hdr := Jv2_Header{
		magic       = Jv2_MAGIC,
		seq         = u64(txn.seq),
		rec_count   = u16(txn.count),
		rec_sectors = rec_secs,
		committed   = 1,
		tail_magic  = Jv2_MAGIC,
	}

	hdr_buf: [SECTOR_SIZE]u8
	(^Jv2_Header)(&hdr_buf[0])^ = hdr
	hdr.header_crc = hash.crc32(hdr_buf[:24])
	(^Jv2_Header)(&hdr_buf[0])^ = hdr
	if !sector_write(vol, pos, hdr_buf[:]) {
		return false
	}
	os.sync(vol.disk)
	return true
}

journal_v2_finish :: proc(vol: ^Volume, seq: Journal_Seq) {
	journal_seq_set(&vol.master, Journal_Seq(u64(seq) + 1))
	journal_v2_set_watermark(&vol.master, u64(seq))
	write_master_record(vol)
}

journal_v2_recover :: proc(vol: ^Volume) {
	if .Journal_V2 not_in vol.master.features { return }

	J := intent_log_sector(&vol.master)
	M := journal_v2_region_size(&vol.master)
	W := journal_v2_watermark(&vol.master)

	replayed: int
	for i: u64; i < M; i += 1 {
		pos := J + Sector(i)
		hdr_buf: [SECTOR_SIZE]u8
		if !sector_read(vol, pos, hdr_buf[:]) { continue }

		hdr := (^Jv2_Header)(&hdr_buf[0])^
		if hdr.magic != Jv2_MAGIC { continue }
		if hdr.tail_magic != Jv2_MAGIC {
			log.warnf("journal: torn header at sector %d — discarding", pos)
			continue
		}
		if hdr.seq < W { continue }
		if hdr.committed != 1 {
			log.warnf("journal: incomplete txn seq=%d at sector %d — discarding", hdr.seq, pos)
			continue
		}

		log.infof("journal: replaying seq=%d (%d entries, %d sectors)",
			hdr.seq, hdr.rec_count, hdr.rec_sectors)

		replay_ok := true
		for ri: u16; ri < hdr.rec_sectors; ri += 1 {
			rec_buf: [SECTOR_SIZE]u8
			if !sector_read(vol, pos + Sector(ri) + 1, rec_buf[:]) {
				log.warnf("journal: can't read record sector %d — aborting replay", ri)
				replay_ok = false
				break
			}

			rec := (^Jv2_Record)(&rec_buf[0])
			for ei in 0 ..< JOURNAL_ENTRIES_PER_RECORD {
				idx := int(ri) * JOURNAL_ENTRIES_PER_RECORD + ei
				if idx >= int(hdr.rec_count) { break }

				je := rec.entries[ei]
				table: [CLUSTER_ENTRIES_PER_SECTOR]Cluster_Entry
				if !read_cluster_entry_table(vol, Cluster(je.cluster), &table) {
					continue
				}
				if int(je.ce_index) >= len(table) {
					continue
				}

				ce := table[je.ce_index]
				if .Allocated in ce.state && transmute(u8)ce.state == je.state {
					continue
				}

				table[je.ce_index] = Cluster_Entry{
					state             = transmute(Cluster_Entry_State)je.state,
					allocation_size   = je.alloc_size,
					sector_start      = je.sector_start,
					next_cluster      = je.next_cluster,
					next_sector_index = je.next_sector_index,
				}
				write_cluster_entry_table(vol, Cluster(je.cluster), &table)
				replayed += 1
			}
		}
		if replay_ok {
			W = hdr.seq + 1
		}
	}
	journal_v2_set_watermark(&vol.master, W)
	if replayed > 0 || W > journal_v2_watermark(&vol.master) {
		write_master_record(vol)
	}
	if replayed > 0 {
		log.infof("journal: replayed %d entries", replayed)
	}
}
