/*
The GLR1 record log: the registry half of the disk
store — the mutable records (document registry, version pointers, and
the curation rows: entities, relations, mentions, doc attrs) as an
append-only log of hash-checked frames grouped into committed batches.
The immutable half is payloads.glb (payload.odin, GLB1); the store
layer over both is store_disk.odin.

A batch is one positioned write, Commit frame included, so a torn
append is a byte prefix: rebuild applies every batch whose Commit
frame survived whole, ignores a torn tail, and refuses a
complete-but-wrong frame — the qdct discipline, never silently
dropping committed state. Everything little-endian, GLB1 conventions
(pl_* helpers).
*/
package gloaming

import "core:bytes"
import "core:hash"
import "core:mem"

RECLOG_MAGIC :: "GLR1"
RECLOG_VERSION :: 2 // 2 = the curation kinds; readers take 1..2
RECLOG_HEADER_SIZE :: 8
REC_FRAME_FIXED    :: 13 // kind u8 + len u32 + check u64
REC_SEG_SIZE       :: 12 // kind u8 + pad[3] + start u32 + end u32
REC_SPAN_SIZE      :: 12 // evidence span: doc u32 + start u32 + end u32

// the fnv64a offset basis every batch hash starts from — rec_batch
// writing and reclog_scan rebuilding share it
REC_FNV_OFFSET :: u64(0xcbf29ce484222325)

Rec_Kind :: enum u8 {
	Begin   = 1, // body: count u32 — records expected before the Commit
	Doc     = 2, // body: doc record — registers the document
	Version = 3, // body: doc record — replaces the document's version
	Remove  = 4, // body: doc_id u32
	Commit  = 5, // body: count u32 + batch u64
	// the curation records (16..19): one full-state row each, last
	// one wins; a merge or alias is the set of rows it rewrites, in
	// one batch. 6..15 stay unassigned: forward compatibility is a
	// version bump, not a skip policy.
	Entity   = 16,
	Relation = 17,
	Mention  = 18,
	Attr     = 19,
}

Rec_Doc :: struct {
	key:         Payload_Key,
	payload_off: i64,
	payload_len: int,
	text:        string,    // view into the scanned log bytes
	segments:    []Segment, // views while staged; clones on `a` once applied (span.doc reconstructed)
}

Rec_Record :: struct {
	kind: Rec_Kind,
	body: []u8,
}

// fnv64a over (kind ‖ len ‖ body) — the per-frame check. Same trust
// level as GLB1's text_hash: gates structural damage and torn writes,
// not adversarial edits.
rec_check :: proc(data: []u8, at: int, body_len: int) -> u64 {
	return hash.fnv64a(data[at : at + 5 + body_len])
}

rec_frame :: proc(buf: ^bytes.Buffer, kind: Rec_Kind, body: []u8) {
	start := bytes.buffer_length(buf)
	bytes.buffer_write_byte(buf, u8(kind))
	lb: [4]u8
	pl_put_u32(lb[:], 0, u32(len(body)))
	bytes.buffer_write(buf, lb[:])
	if len(body) > 0 { bytes.buffer_write(buf, body) }
	cb: [8]u8
	pl_put_u64(cb[:], 0, rec_check(bytes.buffer_to_bytes(buf), start, len(body)))
	bytes.buffer_write(buf, cb[:])
}

/*
rec_doc_body serializes one doc record (Doc and Version share it):
doc_id, Payload_Key, the payload's offset/length in payloads.glb, the
source text, and the segment table. span.doc is not stored — segments
belong to their document and are reconstructed on parse. Allocated on
the temp allocator; the caller folds it into a batch.
*/
rec_doc_body :: proc(doc: Doc_Id, key: Payload_Key, payload_off: i64,
                     payload_len: int, text: string,
                     segments: []Segment) -> []u8 {
	body := make([]u8, 44 + len(text) + REC_SEG_SIZE * len(segments),
		context.temp_allocator)
	pl_put_u32(body, 0, u32(doc))
	pl_put_u64(body, 4, key.text_hash)
	pl_put_u64(body, 12, key.dict_version)
	pl_put_u32(body, 20, key.options)
	pl_put_u64(body, 24, u64(payload_off))
	pl_put_u32(body, 32, u32(payload_len))
	pl_put_u32(body, 36, u32(len(text)))
	copy(body[40:], transmute([]u8)text)
	off := 40 + len(text)
	pl_put_u32(body, off, u32(len(segments)))
	off += 4
	for s in segments {
		body[off] = u8(s.kind)
		pl_put_u32(body, off + 4, u32(s.span.start))
		pl_put_u32(body, off + 8, u32(s.span.end))
		off += REC_SEG_SIZE
	}
	return body
}

rec_remove_body :: proc(doc: Doc_Id) -> []u8 {
	body := make([]u8, 4, context.temp_allocator)
	pl_put_u32(body, 0, u32(doc))
	return body
}

/*
Curation record bodies: one row per record, full state, the last
record for an id wins. GLB1 conventions throughout — little-endian,
u32 string lengths, evidence spans as (doc, start, end) u32s. A
tombstone is the 8-byte head with the live bit clear and nothing
after it. Allocated on the temp allocator, like rec_doc_body. A kind
travels as its string — a record is self-describing full state; the
graph's kind vocabulary is memory-side, interned at apply.
*/

// The kind rides the record as its string (self-describing full state)
// while the row field holds the graph's Kind_Id — callers hand the
// builder the string: writers have the host's argument pre-intern,
// rewrites have the vocabulary to read the row's id back from.
rec_entity_body :: proc(row: Entity, kind: string) -> []u8 {
	if !row.live {
		body := make([]u8, 8, context.temp_allocator)
		pl_put_u32(body, 0, u32(int(row.id)))
		body[4] = 0
		return body
	}
	n := 8 + rec_str_len(kind) + rec_str_len(row.name) + 4
	for al in row.aliases {
		n += rec_str_len(al)
	}
	body := make([]u8, n, context.temp_allocator)
	pl_put_u32(body, 0, u32(int(row.id)))
	body[4] = 1 // live
	at := rec_put_str(body, 8, kind)
	at = rec_put_str(body, at, row.name)
	pl_put_u32(body, at, u32(len(row.aliases)))
	at += 4
	for al in row.aliases {
		at = rec_put_str(body, at, al)
	}
	return body
}

rec_relation_body :: proc(row: Relation, kind: string) -> []u8 {
	if !row.live {
		body := make([]u8, 8, context.temp_allocator)
		pl_put_u32(body, 0, u32(int(row.id)))
		body[4] = 0
		return body
	}
	n := 16 + rec_str_len(kind) + 4 + REC_SPAN_SIZE * len(row.evidence)
	body := make([]u8, n, context.temp_allocator)
	pl_put_u32(body, 0, u32(int(row.id)))
	body[4] = 1 // live
	body[5] = row.derived ? 1 : 0
	pl_put_u32(body, 8, u32(int(row.from)))
	pl_put_u32(body, 12, u32(int(row.to)))
	at := rec_put_str(body, 16, kind)
	pl_put_u32(body, at, u32(len(row.evidence)))
	at += 4
	for ev in row.evidence {
		pl_put_u32(body, at, u32(ev.doc))
		pl_put_u32(body, at + 4, u32(ev.start))
		pl_put_u32(body, at + 8, u32(ev.end))
		at += REC_SPAN_SIZE
	}
	return body
}

rec_mention_body :: proc(id: int, m: Mention) -> []u8 {
	body := make([]u8, 20, context.temp_allocator)
	pl_put_u32(body, 0, u32(id))
	pl_put_u32(body, 4, u32(int(m.entity)))
	pl_put_u32(body, 8, u32(m.span.doc))
	pl_put_u32(body, 12, u32(m.span.start))
	pl_put_u32(body, 16, u32(m.span.end))
	return body
}

rec_attr_body :: proc(attr: Doc_Attr) -> []u8 {
	body := make([]u8, 4 + rec_str_len(attr.key) + rec_str_len(attr.val),
		context.temp_allocator)
	pl_put_u32(body, 0, u32(attr.doc))
	at := rec_put_str(body, 4, attr.key)
	rec_put_str(body, at, attr.val)
	return body
}

rec_str_len :: proc(s: string) -> int { return 4 + len(s) }

rec_put_str :: proc(body: []u8, at: int, s: string) -> int {
	pl_put_u32(body, at, u32(len(s)))
	copy(body[at + 4:], transmute([]u8)s)
	return at + 4 + len(s)
}

rec_get_str :: proc(body: []u8, at: int) -> (s: string, next: int, ok: bool) {
	if at + 4 > len(body) { return }
	n := int(pl_u32(body, at))
	if at + 4 + n > len(body) { return }
	return string(body[at + 4 : at + 4 + n]), at + 4 + n, true
}

/*
rec_batch frames one committed batch — Begin, the records, Commit —
and returns the bytes to append at the log's committed end. The batch
hash folds each record frame's (kind ‖ len ‖ body); the Commit frame
carries it plus the record count, so a rebuilt batch is checked twice:
once per frame, once as a whole.
*/
rec_batch :: proc(records: []Rec_Record, a: mem.Allocator) -> []u8 {
	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, 0, context.temp_allocator)
	defer bytes.buffer_destroy(&buf)

	begin := make([]u8, 4, context.temp_allocator)
	pl_put_u32(begin, 0, u32(len(records)))
	rec_frame(&buf, .Begin, begin)

	batch := REC_FNV_OFFSET
	for r in records {
		batch = rec_fold(batch, u8(r.kind), len(r.body), r.body)
		rec_frame(&buf, r.kind, r.body)
	}

	commit := make([]u8, 12, context.temp_allocator)
	pl_put_u32(commit, 0, u32(len(records)))
	pl_put_u64(commit, 4, batch)
	rec_frame(&buf, .Commit, commit)

	out := make([]u8, bytes.buffer_length(&buf), a)
	copy(out, bytes.buffer_to_bytes(&buf))
	return out
}

Rec_Scan :: struct {
	docs:    map[Doc_Id]Rec_Doc, // on `a`; texts view `data`, segments are apply-time clones
	graph:   Doc_Graph, // curation rows; strings/slices view into `data`
	applied: int, // committed bytes — where appends land
	torn:    bool, // a tail was discarded (crash artifact)
}

/*
reclog_scan rebuilds the registry from raw log bytes. Clean end: every
Begin closed by its Commit, applied == len(data). Torn tail (EOF
mid-frame, an unclosed Begin, or a zero-filled remainder — the
filesystem crash artifact): applied stays at the last commit and
`torn` reports it; the store appends at `applied`, overwriting the
tail on the next write. Anything structurally complete but wrong —
invalid kind, check mismatch, a body violating its kind's layout, a
Commit whose count or batch hash disagrees, an impossible record
transition — is Malformed: the file was damaged after writing and
which committed batches survived is unknowable, so refuse.

Staged records are raw body views into `data`, validated on stage and
re-parsed on apply; segment tables clone onto `a` only for committed
records, so a torn batch leaves nothing behind in the store's
allocator. The optional stop-check polls once per frame —
.Interrupted cleans up like any refusal.
*/
reclog_scan :: proc(data: []u8, a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil,
                    user: rawptr = nil) -> (Rec_Scan, Store_Err) {
	out := Rec_Scan{docs = make(map[Doc_Id]Rec_Doc, a), applied = RECLOG_HEADER_SIZE}
	graph_init(&out.graph, a)
	// error paths return a literal {} — the partial state dies here
	// (committed segment clones are slices, not map-managed: freed by
	// hand before the map itself)
	clean := false
	defer if !clean {
		for _, rec in out.docs {
			if len(rec.segments) > 0 { mem.free(raw_data(rec.segments), a) }
		}
		graph_destroy(&out.graph)
		delete(out.docs)
	}
	if len(data) < RECLOG_HEADER_SIZE { return {}, .Malformed }
	if string(data[0:4]) != RECLOG_MAGIC { return {}, .Malformed }
	// version 1 (documents) and 2 (documents + curation) share the
	// frame layout; the reader takes both, the writer emits 2
	if v := pl_u32(data, 4); v < 1 || v > RECLOG_VERSION { return {}, .Malformed }

	staged: [dynamic]Rec_Record = make([dynamic]Rec_Record, 0, 8,
		context.temp_allocator)
	defer delete(staged)
	expect := 0 // Begin's declared record count
	batch := u64(0)

	pos := RECLOG_HEADER_SIZE
	in_batch := false
	for {
		remaining := len(data) - pos
		if remaining == 0 { break }
		if check != nil && check(user) { return {}, .Interrupted }
		if remaining < REC_FRAME_FIXED {
			out.torn = true // EOF inside the frame header
			break
		}
		kind_u8 := data[pos]
		if kind_u8 == 0 {
			// zero remainder is the extended-with-zeros crash
			// artifact; anything else with a zero kind is damage
			zero := true
			for b in data[pos:] {
				if b != 0 { zero = false; break }
			}
			if zero { out.torn = true; break }
			return {}, .Malformed
		}
		body_len := int(pl_u32(data, pos + 1))
		frame_total := REC_FRAME_FIXED + body_len
		if remaining < frame_total {
			out.torn = true // EOF inside the body or check
			break
		}
		if rec_check(data, pos, body_len) != pl_u64(data, pos + 5 + body_len) {
			return {}, .Malformed
		}
		body := data[pos + 5 : pos + 5 + body_len]

		// kind gate before the cast: unassigned (6..15) and garbage
		// kinds are refused as bytes, never as out-of-range enum values
		if !rec_kind_valid(kind_u8) { return {}, .Malformed }
		switch rec_kind_of(kind_u8) {
		case .Begin:
			if in_batch || len(body) != 4 { return {}, .Malformed }
			in_batch = true
			expect = int(pl_u32(body, 0))
			clear(&staged)
			batch = REC_FNV_OFFSET
		case .Doc, .Version:
			if !in_batch { return {}, .Malformed }
			if _, _, ok := rec_parse_doc(body); !ok { return {}, .Malformed }
			append(&staged, Rec_Record{kind = rec_kind_of(kind_u8), body = body})
			batch = rec_fold(batch, kind_u8, body_len, body)
		case .Remove:
			if !in_batch || len(body) != 4 { return {}, .Malformed }
			append(&staged, Rec_Record{kind = .Remove, body = body})
			batch = rec_fold(batch, kind_u8, body_len, body)
		case .Entity:
			if !in_batch { return {}, .Malformed }
			if _, _, ok := rec_parse_entity(body); !ok { return {}, .Malformed }
			append(&staged, Rec_Record{kind = .Entity, body = body})
			batch = rec_fold(batch, kind_u8, body_len, body)
		case .Relation:
			if !in_batch { return {}, .Malformed }
			if _, _, ok := rec_parse_relation(body); !ok { return {}, .Malformed }
			append(&staged, Rec_Record{kind = .Relation, body = body})
			batch = rec_fold(batch, kind_u8, body_len, body)
		case .Mention:
			if !in_batch { return {}, .Malformed }
			if _, _, ok := rec_parse_mention(body); !ok { return {}, .Malformed }
			append(&staged, Rec_Record{kind = .Mention, body = body})
			batch = rec_fold(batch, kind_u8, body_len, body)
		case .Attr:
			if !in_batch { return {}, .Malformed }
			if _, ok := rec_parse_attr(body); !ok { return {}, .Malformed }
			append(&staged, Rec_Record{kind = .Attr, body = body})
			batch = rec_fold(batch, kind_u8, body_len, body)
		case .Commit:
			if !in_batch || len(body) != 12 { return {}, .Malformed }
			if int(pl_u32(body, 0)) != expect || len(staged) != expect { return {}, .Malformed }
			if pl_u64(body, 4) != batch { return {}, .Malformed }
			if err := rec_apply(&out.docs, &out.graph, staged[:], a); err != .None { return {}, err }
			in_batch = false
			out.applied = pos + frame_total
		}
		pos += frame_total
	}
	if in_batch { out.torn = true } // Begin never closed
	clean = true
	return out, .None
}

// the assigned kind numbers: 1..5 (documents) and 16..19 (curation)
rec_kind_valid :: proc(b: u8) -> bool {
	return (b >= u8(Rec_Kind.Begin) && b <= u8(Rec_Kind.Commit)) ||
		(b >= u8(Rec_Kind.Entity) && b <= u8(Rec_Kind.Attr))
}

// rec_kind_of maps a kind byte already range-gated to its enum value.
rec_kind_of :: proc(b: u8) -> Rec_Kind {
	assert(rec_kind_valid(b))
	return cast(Rec_Kind)b
}

// rec_fold continues the batch hash over one record frame's
// (kind ‖ len ‖ body) — rec_batch writing and reclog_scan rebuilding
// both fold through it, so the two sides hash the same bytes.
rec_fold :: proc(batch: u64, kind_u8: u8, body_len: int, body: []u8) -> u64 {
	hdr: [5]u8
	hdr[0] = kind_u8
	pl_put_u32(hdr[:], 1, u32(body_len))
	h := hash.fnv64a(hdr[:], batch)
	if len(body) > 0 { h = hash.fnv64a(body, h) }
	return h
}

// rec_apply replays one committed batch in order against the evolving
// state — the transitions a correct writer produces; anything else is
// damage (Malformed, refuse the file). Curation rows replay through
// the same graph_apply_* the writers use, so a rebuilt graph and the
// in-memory one cannot drift.
rec_apply :: proc(docs: ^map[Doc_Id]Rec_Doc, graph: ^Doc_Graph,
                  staged: []Rec_Record, a: mem.Allocator) -> Store_Err {
	// the batch's tombstone schedule: entity id → the last staged index
	// a record in this batch tombstones it at. The name-transfer check
	// below reads "is this holder killed later than ri" as one probe;
	// the schedule pass reads the tombstone head directly (a tombstone
	// is the 8-byte body with the live bit clear — staged bodies were
	// layout-validated at scan), so no entity body is re-parsed per
	// collision
	last_kill := make(map[Entity_Id]int, context.temp_allocator)
	defer delete(last_kill)
	for r, ri in staged {
		if r.kind != .Entity { continue }
		if len(r.body) == 8 && r.body[4] == 0 {
			last_kill[Entity_Id(pl_u32(r.body, 0))] = ri
		}
	}

	for r, ri in staged {
		#partial switch r.kind {
		case .Doc, .Version:
			doc, rec, ok := rec_parse_doc(r.body)
			if !ok { return .Malformed }
			if r.kind == .Doc {
				if _, live := docs[doc]; live { return .Malformed }
			} else if _, live := docs[doc]; !live { return .Malformed }
			rec.segments = clone_segs(rec.segments, doc, a)
			docs[doc] = rec
		case .Remove:
			if len(r.body) != 4 { return .Malformed }
			doc := Doc_Id(pl_u32(r.body, 0))
			if _, live := docs[doc]; !live { return .Malformed }
			delete_key(docs, doc)
		case .Entity:
			row, kind_s, ok := rec_parse_entity(r.body)
			if !ok { return .Malformed }
			if int(row.id) > len(graph.entities) { return .Malformed }
			if !row.live {
				// a tombstone targets an existing row — it is an undo,
				// not a way to mint dead rows
				if int(row.id) >= len(graph.entities) { return .Malformed }
			} else {
				// a live row's names must not collide with another live
				// entity — the writers' uniqueness, replayed. A name
				// held by an entity this same batch tombstones LATER is
				// a transfer (the merge order), not a collision.
				if held, held_ok := graph.by_name[row.name];
				   held_ok && held != row.id &&
				   !batch_kills_later(last_kill, ri, held) { return .Malformed }
				for al in row.aliases {
					if held, held_ok := graph.by_name[al];
					   held_ok && held != row.id &&
					   !batch_kills_later(last_kill, ri, held) { return .Malformed }
				}
			}
			if row.live {
				// record order is write order, so the replayed vocabulary
				// numbers kinds exactly like the graph that wrote the log
				row.kind = graph_kind_intern(graph, kind_s)
				if len(row.aliases) > 0 {
					row.aliases = alias_view(row.aliases, a)
				}
			} else {
				row.kind = KIND_NONE
			}
			graph_apply_entity(graph, row)
		case .Relation:
			row, kind_s, ok := rec_parse_relation(r.body)
			if !ok { return .Malformed }
			if int(row.id) > len(graph.relations) { return .Malformed }
			if !row.live {
				if int(row.id) >= len(graph.relations) { return .Malformed }
			}
			if row.live {
				if !graph_entity_live(graph, row.from) ||
				   !graph_entity_live(graph, row.to) { return .Malformed }
				if row.from == row.to { return .Malformed }
				row.kind = graph_kind_intern(graph, kind_s)
				if len(row.evidence) > 0 {
					row.evidence = clone_spans(row.evidence, a)
				}
			} else {
				row.kind = KIND_NONE
			}
			graph_apply_relation(graph, row)
		case .Mention:
			id, m, ok := rec_parse_mention(r.body)
			if !ok { return .Malformed }
			if id > len(graph.mentions) { return .Malformed }
			if !graph_entity_live(graph, m.entity) { return .Malformed }
			graph_apply_mention(graph, id, m)
		case .Attr:
			attr, ok := rec_parse_attr(r.body)
			if !ok { return .Malformed }
			graph_apply_attr(graph, attr)
		case:
			return .Malformed
		}
	}
	return .None
}

// is entity `id` tombstoned by a record later than `at` in this batch?
// — the merge's name transfer reads as a collision until its
// tombstone lands, and transfers are exactly what a same-batch kill
// marks. One probe into the batch's tombstone schedule (built by
// rec_apply's pre-pass): the schedule holds each id's LAST tombstone
// index, so `li > at` says a later one exists
batch_kills_later :: proc(last_kill: map[Entity_Id]int, at: int, id: Entity_Id) -> bool {
	if li, ok := last_kill[id]; ok && li > at { return true }
	return false
}

clone_segs :: proc(segs: []Segment, doc: Doc_Id, a: mem.Allocator) -> []Segment {
	out := make([]Segment, len(segs), a)
	copy(out, segs)
	for &s in out { s.span.doc = doc }
	return out
}

/*
rec_parse_doc reads one doc record body: layout per rec_doc_body, the
segment table must consume the body exactly, kinds must be real. The
returned text/segments view into `body` (temp in a scan) — callers
that keep them must clone onto their own allocator.
*/
rec_parse_doc :: proc(body: []u8) -> (doc: Doc_Id, rec: Rec_Doc, ok: bool) {
	if len(body) < 44 { return }
	text_len := int(pl_u32(body, 36))
	if 44 + text_len > len(body) { return }
	seg_count := int(pl_u32(body, 40 + text_len))
	if 44 + text_len + REC_SEG_SIZE * seg_count != len(body) { return }
	for i in 0..<seg_count {
		if body[44 + text_len + i * REC_SEG_SIZE] >= 3 { return } // Segment_Kind has three members
	}
	doc = Doc_Id(pl_u32(body, 0))
	rec = Rec_Doc{
		key = Payload_Key{
			text_hash    = pl_u64(body, 4),
			dict_version = pl_u64(body, 12),
			options      = pl_u32(body, 20),
		},
		payload_off = cast(i64)pl_u64(body, 24),
		payload_len = int(pl_u32(body, 32)),
		text        = string(body[40 : 40 + text_len]),
	}
	if seg_count > 0 {
		segs := make([]Segment, seg_count, context.temp_allocator)
		base := 44 + text_len
		for i in 0..<seg_count {
			off := base + i * REC_SEG_SIZE
			segs[i] = {
				kind = cast(Segment_Kind)body[off],
				span = {doc = doc,
					start = int(pl_u32(body, off + 4)),
					end   = int(pl_u32(body, off + 8))},
			}
		}
		rec.segments = segs
	}
	return doc, rec, true
}

/*
Curation body parsers, the rec_parse_doc discipline: strict layout
(the body must consume exactly), views into `body` — slices come back
on the temp allocator and rec_apply clones the ones that stay onto the
store allocator. A body that violates its kind's shape is `ok ==
false`, which the scan turns into Malformed.
*/
// The kind comes back beside the row: the field is a Kind_Id the graph
// interns, the record carries the string, and rec_apply bridges the two.
rec_parse_entity :: proc(body: []u8) -> (row: Entity, kind: string, ok: bool) {
	if len(body) < 8 { return }
	row.id = Entity_Id(pl_u32(body, 0))
	row.live = body[4] == 1
	if !row.live { return row, "", len(body) == 8 }
	if body[5] != 0 || body[6] != 0 || body[7] != 0 { return }
	at := 8
	kind, at, ok = rec_get_str(body, at)
	if !ok { return }
	row.name, at, ok = rec_get_str(body, at)
	if !ok { return }
	if at + 4 > len(body) { return }
	n := int(pl_u32(body, at))
	at += 4
	// each alias needs at least its u32 length field — the bound check
	// precedes the make, so a corrupted count cannot demand a giant
	// allocation for a few bytes of body (rec_parse_relation's rule)
	if n * 4 > len(body) - at { return row, "", false }
	if n > 0 {
		aliases := make([]string, n, context.temp_allocator)
		for i in 0..<n {
			aliases[i], at, ok = rec_get_str(body, at)
			if !ok { return }
		}
		row.aliases = aliases
	}
	return row, kind, at == len(body)
}

rec_parse_relation :: proc(body: []u8) -> (row: Relation, kind: string, ok: bool) {
	if len(body) < 8 { return }
	row.id = Relation_Id(pl_u32(body, 0))
	row.live = body[4] == 1
	row.derived = body[5] == 1
	if !row.live { return row, "", len(body) == 8 }
	if body[6] != 0 || body[7] != 0 { return }
	if len(body) < 16 { return }
	row.from = Entity_Id(pl_u32(body, 8))
	row.to = Entity_Id(pl_u32(body, 12))
	at := 16
	kind, at, ok = rec_get_str(body, at)
	if !ok { return }
	if at + 4 > len(body) { return }
	n := int(pl_u32(body, at))
	at += 4
	if at + REC_SPAN_SIZE * n != len(body) { return }
	if n > 0 {
		ev := make([]Span, n, context.temp_allocator)
		for i in 0..<n {
			off := at + i * REC_SPAN_SIZE
			ev[i] = {
				doc   = Doc_Id(pl_u32(body, off)),
				start = int(pl_u32(body, off + 4)),
				end   = int(pl_u32(body, off + 8)),
			}
		}
		row.evidence = ev
	}
	return row, kind, true
}

rec_parse_mention :: proc(body: []u8) -> (id: int, m: Mention, ok: bool) {
	if len(body) != 20 { return }
	id = int(pl_u32(body, 0))
	m = {
		entity = Entity_Id(pl_u32(body, 4)),
		span = {
			doc   = Doc_Id(pl_u32(body, 8)),
			start = int(pl_u32(body, 12)),
			end   = int(pl_u32(body, 16)),
		},
	}
	return id, m, true
}

rec_parse_attr :: proc(body: []u8) -> (attr: Doc_Attr, ok: bool) {
	if len(body) < 4 { return }
	attr.doc = Doc_Id(pl_u32(body, 0))
	at := 4
	attr.key, at, ok = rec_get_str(body, at)
	if !ok { return }
	attr.val, at, ok = rec_get_str(body, at)
	if !ok { return }
	return attr, at == len(body)
}
