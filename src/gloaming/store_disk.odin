/*
The disk backend of the Store port: one directory, two
append-only files — registry.glr (GLR1, reclog.odin) and payloads.glb
(GLB1 payloads concatenated, payload.odin). `core:os` appears here and
nowhere else in the library: a store backend is not an analysis path,
so the os/thread rule on analysis paths does not reach it (moli's
qdct uses core:os the same way).

The refusal protocol is built in: the constructor takes the
dictionary content hash the host will resolve with, and `tokens`
compares every payload header's dict_version against it BEFORE
decoding — a mismatch answers `.Stale` instead of resolving entry ids
against a renumbered dictionary (the silent-wrong-resolution hazard
the adapter demonstrates). Decode materializes onto the caller's `a`
(the port's materializing-backend clause); surfaces view the
registry's text, resolved strings the resolver's storage, unknown pos
strings the caller's blob buffer.
*/
package gloaming

import "core:hash"
import "core:mem"
import "core:os"

DISK_REGISTRY :: "registry.glr"
DISK_PAYLOADS :: "payloads.glb"

Disk_Doc :: struct {
	key:      Payload_Key,
	off:      i64,        // where the payload starts in payloads.glb
	len:      int,
	text:     string,    // log_buf view (reopened) or store-alloc clone (added)
	segments: []Segment, // borrowed views likewise
}

Disk_Store :: struct {
	a:        mem.Allocator, // owns log_buf, the map, added-doc clones
	log_f:    ^os.File,
	pay_f:    ^os.File,
	log_buf:  []u8, // the registry read at open — texts view into it
	log_end:  i64, // committed bytes; appends land here
	pay_end:  i64, // payload file size — appends land here
	docs:     map[Doc_Id]Disk_Doc,
	ids:      [dynamic]Doc_Id, // ascending — the maintained document list
	graph:    Doc_Graph, // curation rows — strings view log_buf or clone on `a`
	resolver:     Payload_Resolver,
	rctx:         rawptr,
	dict_version: u64, // what the resolver resolves against — refusal gate
	options:      u32, // Payload_Key.options for payloads this store writes
}

disk_read_all :: proc(f: ^os.File, dst: []u8, at: i64) -> os.Error {
	n, err := os.read_at(f, dst, at)
	if err != nil { return err }
	if n != len(dst) { return .Invalid_File } // short read — the file shrank
	return nil
}

disk_write_all :: proc(f: ^os.File, src: []u8, at: i64) -> os.Error {
	n, err := os.write_at(f, src, at)
	if err != nil { return err }
	if n != len(src) { return .Invalid_File } // write_at loops; short means damage
	return nil
}

/*
store_disk opens (or initializes) the two-file store in `dir` and
wires the Store port. `resolver`/`rctx` come from the adapter,
`dict_version` is the live dictionary hash (dictionary_hash) — the
store refuses payloads whose key disagrees. Memory is the host
allocator's business (same contract as store_memory); the file handles
close via disk_store_close, which every host calls exactly once.

A torn registry tail (crash mid-append) is repaired at open: the file
truncates to the last committed batch and the store proceeds. Payload
bytes appended without a committed reference are orphans — dead space
until compaction, never wrong. The optional stop-check polls once per
registry frame during the open replay — .Interrupted closes and
frees the half-built store like any open refusal.
*/
store_disk :: proc(dir: string, resolver: Payload_Resolver, rctx: rawptr,
                   dict_version: u64, options: u32,
                   a: mem.Allocator,
                   check: proc(user: rawptr) -> bool = nil,
                   user: rawptr = nil) -> (Store, ^Disk_Store, Store_Err) {
	if !os.exists(dir) {
		if err := os.mkdir(dir); err != nil { return {}, nil, .Io }
	}
	log_path, lerr := os.join_path({dir, DISK_REGISTRY}, context.temp_allocator)
	if lerr != nil { return {}, nil, .Io }
	pay_path, perr := os.join_path({dir, DISK_PAYLOADS}, context.temp_allocator)
	if perr != nil { return {}, nil, .Io }

	ds := new(Disk_Store, a)
	ds^ = {
		a            = a,
		docs         = make(map[Doc_Id]Disk_Doc, a),
		ids          = make([dynamic]Doc_Id, 0, 0, a),
		resolver     = resolver,
		rctx         = rctx,
		dict_version = dict_version,
		options      = options,
	}
	graph_init(&ds.graph, a)
	fail :: proc(ds: ^Disk_Store, e: Store_Err) -> (Store, ^Disk_Store, Store_Err) {
		disk_store_close(ds)
		graph_destroy(&ds.graph)
		delete(ds.docs)
		delete(ds.ids)
		free(ds, ds.a)
		return {}, nil, e
	}

	flags := os.File_Flags{.Read, .Write, .Create}
	log_f, oerr := os.open(log_path, flags, os.Permissions_Default_File)
	if oerr != nil { return fail(ds, .Io) }
	ds.log_f = log_f
	pay_f, perr2 := os.open(pay_path, flags, os.Permissions_Default_File)
	if perr2 != nil { return fail(ds, .Io) }
	ds.pay_f = pay_f

	log_size, fserr := os.file_size(log_f)
	if fserr != nil { return fail(ds, .Io) }
	pay_size, fserr2 := os.file_size(pay_f)
	if fserr2 != nil { return fail(ds, .Io) }
	ds.pay_end = pay_size

	if log_size == 0 {
		hdr := make([]u8, RECLOG_HEADER_SIZE, context.temp_allocator)
		copy(hdr[0:4], RECLOG_MAGIC)
		pl_put_u32(hdr, 4, RECLOG_VERSION)
		if werr := disk_write_all(log_f, hdr, 0); werr != nil { return fail(ds, .Io) }
		if sync_err := os.sync(log_f); sync_err != nil { return fail(ds, .Io) }
		ds.log_end = RECLOG_HEADER_SIZE
	} else {
		buf := make([]u8, log_size, a)
		// success keeps buf (ds.log_buf views into it); every failure in
		// this block strands it otherwise — freed here since the scan's
		// views die with the refusal
		keep_buf := false
		defer if !keep_buf && len(buf) > 0 { mem.free(raw_data(buf), a) }
		if rerr := disk_read_all(log_f, buf, 0); rerr != nil { return fail(ds, .Io) }
		scan, scerr := reclog_scan(buf, a, check, user)
		if scerr != .None { return fail(ds, scerr) }
		for _, rec in scan.docs {
			if rec.payload_off < 0 ||
				rec.payload_off + i64(rec.payload_len) > pay_size {
				return fail(ds, .Malformed)
			}
		}
		for doc, rec in scan.docs {
			ds.docs[doc] = {
				key      = rec.key,
				off      = rec.payload_off,
				len      = rec.payload_len,
				text     = rec.text,
				segments = rec.segments,
			}
		}
		// the document list, sorted once at replay and maintained per
		// mutation from here — docs() is a copy, never a sort
		for doc in scan.docs {
			append(&ds.ids, doc)
		}
		sort_with_buffer(ds.ids[:], docid_less, a)
		delete(scan.docs) // the map table only; segment slices live on in ds.docs
		graph_destroy(&ds.graph) // the empty init — the scan's rebuild takes over
		ds.graph = scan.graph
		ds.log_buf = buf
		ds.log_end = i64(scan.applied)
		keep_buf = true
		if log_size > ds.log_end {
			// torn tail — repair by truncation so appends never
			// chase stale garbage past the committed end
			if terr := os.truncate(log_f, ds.log_end); terr != nil {
				return fail(ds, .Io)
			}
		}
	}

	store := Store{
		ctx             = ds,
		docs            = ds_docs,
		has             = ds_has,
		tokens          = ds_tokens,
		segments        = ds_segments,
		add_document    = ds_add_document,
		remove_document = ds_remove_document,
	}
	return store, ds, .None
}

// closes the two file handles — the one resource that is not the host
// allocator's business. Memory (log_buf, the map, added-doc clones)
// stays the allocator's.
disk_store_close :: proc(ds: ^Disk_Store) -> Store_Err {
	if ds == nil { return .None }
	err: Store_Err = .None
	// both handles get their close attempt — one failing must not
	// strand the other open; the first error is the report
	if ds.log_f != nil {
		if cerr := os.close(ds.log_f); cerr != nil && err == .None { err = .Io }
		ds.log_f = nil
	}
	if ds.pay_f != nil {
		if cerr := os.close(ds.pay_f); cerr != nil && err == .None { err = .Io }
		ds.pay_f = nil
	}
	return err
}

ds_docs :: proc(ctx: rawptr) -> []Doc_Id {
	ds := cast(^Disk_Store)ctx
	// a copy of the maintained ascending list — same ownership as the
	// memory backend, without the per-call rebuild and sort
	out := make([]Doc_Id, len(ds.ids), ds.a)
	copy(out, ds.ids[:])
	return out
}

ds_has :: proc(ctx: rawptr, doc: Doc_Id) -> bool {
	ds := cast(^Disk_Store)ctx
	_, ok := ds.docs[doc]
	return ok
}

// borrowed views — the port's borrow clause; valid until the store closes
ds_segments :: proc(ctx: rawptr, doc: Doc_Id, a: mem.Allocator) -> ([]Segment, Store_Err) {
	_ = a
	ds := cast(^Disk_Store)ctx
	d, ok := ds.docs[doc]
	if !ok { return {}, .Not_Found }
	return d.segments, .None
}

ds_tokens :: proc(ctx: rawptr, doc: Doc_Id, a: mem.Allocator) -> ([]Token, Store_Err) {
	ds := cast(^Disk_Store)ctx
	d, ok := ds.docs[doc]
	if !ok { return {}, .Not_Found }

	blob := make([]u8, d.len, a)
	if rerr := disk_read_all(ds.pay_f, blob, d.off); rerr != nil { return {}, .Io }
	h, herr := payload_header(blob)
	if herr != .None { return {}, .Malformed }
	if h.dict_version != ds.dict_version {
		// the refusal protocol: decoding would resolve entry ids
		// against a dictionary state the key never described
		return {}, .Stale
	}
	return payload_decode(blob, d.text, ds.resolver, ds.rctx, a)
}

/*
add_document keeps the memory backend's ownership contract: after the
call the host may free the text and token slice — the payload encodes
onto the temp allocator and lands in payloads.glb first, the registry
batch lands second (cross-file ordering: a crash between leaves an
orphan payload, never a dangling reference), and only then are the
text/segments cloned onto the store allocator. Payloads and the log
sync at commit; token ranges and the kind/entry_id contract are
payload_encode's to refuse (Bad_Range/Malformed pass through).
*/
ds_add_document :: proc(ctx: rawptr, doc: Doc_Id, text: string,
                        tokens: []Token,
                        segments: []Segment) -> Store_Err {
	ds := cast(^Disk_Store)ctx
	if _, live := ds.docs[doc]; live { return .Duplicate }

	key := Payload_Key{
		text_hash    = hash.fnv64a(transmute([]u8)text),
		dict_version = ds.dict_version,
		options      = ds.options,
	}
	blob, eerr := payload_encode(key, text, tokens, context.temp_allocator)
	if eerr != .None { return eerr }

	off := ds.pay_end
	if werr := disk_write_all(ds.pay_f, blob, off); werr != nil { return .Io }
	if sync_err := os.sync(ds.pay_f); sync_err != nil { return .Io }

	body := rec_doc_body(doc, key, off, len(blob), text, segments)
	recs := [1]Rec_Record{{kind = .Doc, body = body}}
	if err := ds_log_commit(ds, rec_batch(recs[:], context.temp_allocator)); err != nil {
		return err
	}

	ds.pay_end += i64(len(blob))

	text_copy := make([]u8, len(text), ds.a)
	copy(text_copy, text)
	ds.docs[doc] = {
		key      = key,
		off      = off,
		len      = len(blob),
		text     = transmute(string)text_copy,
		segments = clone_segs(segments, doc, ds.a),
	}
	ids_insert(&ds.ids, doc)
	return .None
}

// a tombstone batch; the payload bytes become orphans (compaction business)
ds_remove_document :: proc(ctx: rawptr, doc: Doc_Id) -> Store_Err {
	ds := cast(^Disk_Store)ctx
	if _, live := ds.docs[doc]; !live { return .Not_Found }

	body := rec_remove_body(doc)
	recs := [1]Rec_Record{{kind = .Remove, body = body}}
	if err := ds_log_commit(ds, rec_batch(recs[:], context.temp_allocator)); err != nil {
		return err
	}

	delete_key(&ds.docs, doc)
	ids_remove(&ds.ids, doc)
	return .None
}

/*
The curation API: entities, mentions, relations, and doc attrs as
GLR1 records. Every writer follows one discipline — validate against
the in-memory graph, serialize the row(s) as full state, commit ONE
batch (write + sync), then apply to memory — so the durable log is the
commit point and an Io failure leaves the pre-call state untouched.
graph_entity_merge is the merge transaction: its
whole plan lands as one batch, so a torn append repairs to the
pre-merge state by the existing torn-tail rule.
*/

ds_graph_commit :: proc(ds: ^Disk_Store, recs: []Rec_Record) -> Store_Err {
	return ds_log_commit(ds, rec_batch(recs, context.temp_allocator))
}

// the one log-commit path every writer shares: ONE positioned write,
// then the sync. A failed write leaves a torn prefix past log_end that
// the next write overwrites and a reopen discards. A failed sync is
// the dangerous half: the batch bytes are already complete, so a
// normal close would flush them and a reopen would replay a mutation
// the caller was told failed — undo by truncating back to the
// committed end, best effort; if the truncate itself fails the window
// stays open, which nothing short of a working disk can close.
ds_log_commit :: proc(ds: ^Disk_Store, batch: []u8) -> Store_Err {
	if werr := disk_write_all(ds.log_f, batch, ds.log_end); werr != nil { return .Io }
	if sync_err := os.sync(ds.log_f); sync_err != nil {
		if terr := os.truncate(ds.log_f, ds.log_end); terr != nil { return .Io }
		if sync_err2 := os.sync(ds.log_f); sync_err2 != nil { return .Io }
		return .Io
	}
	ds.log_end += i64(len(batch))
	return .None
}

// a duplicate name or alias is refused whole — no partial registration
graph_entity_add :: proc(ds: ^Disk_Store, kind, name: string,
                         aliases: []string) -> (Entity_Id, Store_Err) {
	if _, ok := ds.graph.by_name[name]; ok { return {}, .Duplicate }
	for al in aliases {
		if _, ok := ds.graph.by_name[al]; ok { return {}, .Duplicate }
	}
	id := Entity_Id(len(ds.graph.entities))
	row := Entity{
		id      = id,
		live    = true,
		name    = clone_str(name, ds.a),
		aliases = clone_strs(aliases, ds.a),
	}
	recs := [1]Rec_Record{{kind = .Entity, body = rec_entity_body(row, kind)}}
	if err := ds_graph_commit(ds, recs[:]); err != nil { return {}, err }
	// the vocabulary grows only after the row is durable — the record
	// carried the string, memory catches up to the log
	row.kind = graph_kind_intern(&ds.graph, kind)
	graph_apply_entity(&ds.graph, row)
	return id, .None
}

// one alias, one rewritten entity row — a record-store transaction,
// like merge one batch
graph_entity_alias :: proc(ds: ^Disk_Store, id: Entity_Id, alias: string) -> Store_Err {
	if !graph_entity_live(&ds.graph, id) { return .Not_Found }
	if _, taken := ds.graph.by_name[alias]; taken { return .Duplicate }
	old := ds.graph.entities[int(id)]
	aliases: [dynamic]string = make([dynamic]string, 0, len(old.aliases) + 1, ds.a)
	for al in old.aliases {
		append(&aliases, al)
	}
	append(&aliases, clone_str(alias, ds.a))
	row := Entity{
		id = id, live = true, kind = old.kind, name = old.name,
		aliases = aliases[:],
	}
	recs := [1]Rec_Record{{kind = .Entity,
		body = rec_entity_body(row, ds.graph.kinds[old.kind])}}
	if err := ds_graph_commit(ds, recs[:]); err != nil { return err }
	graph_apply_entity(&ds.graph, row)
	return .None
}

graph_mention_add :: proc(ds: ^Disk_Store, entity: Entity_Id, span: Span) -> (int, Store_Err) {
	if !graph_entity_live(&ds.graph, entity) { return -1, .Not_Found }
	id := len(ds.graph.mentions)
	m := Mention{entity = entity, span = span}
	recs := [1]Rec_Record{{kind = .Mention, body = rec_mention_body(id, m)}}
	if err := ds_graph_commit(ds, recs[:]); err != nil { return -1, err }
	graph_apply_mention(&ds.graph, id, m)
	return id, .None
}

/*
graph_relation_add upserts on the row identity (kind, from, to,
derived): an existing live row absorbs the evidence and a new identity
takes the next id; the record carries the full post-state, so the
rebuild replays it. Absorption skips a span the row already holds —
evidence is a set, so re-running a rule or re-citing a passage changes
nothing. from == to is Bad_Range: a self-edge carries no pair (merges
drop them for the same reason).
*/
graph_relation_add :: proc(ds: ^Disk_Store, kind: string, from, to: Entity_Id,
                           evidence: []Span, derived: bool) -> (Relation_Id, Store_Err) {
	if !graph_entity_live(&ds.graph, from) || !graph_entity_live(&ds.graph, to) {
		return {}, .Not_Found
	}
	if from == to { return {}, .Bad_Range }

	// a not-yet-interned kind is on no row, so the identity lookup only
	// runs for a known kind — a read-only lookup, the vocabulary still
	// grows after the commit
	kid, known := ds.graph.by_kind[kind]

	row: Relation
	found := false
	if known {
		ident := Rel_Identity{kind = kid, from = from, to = to, derived = derived}
		if rid, ok := ds.graph.rel_ix[ident]; ok {
			r := &ds.graph.relations[int(rid)]
			ev := make([]Span, len(r.evidence) + len(evidence), ds.a)
			copy(ev, r.evidence)
			n := len(r.evidence)
			for s in evidence {
				dup := false
				for i in 0..<n {
					if ev[i] == s { dup = true; break }
				}
				if !dup {
					ev[n] = s
					n += 1
				}
			}
			row = {
				id = r.id, live = true, derived = derived, kind = kid,
				from = from, to = to, evidence = ev[:n],
			}
			found = true
		}
	}
	if !found {
		row = {
			id = Relation_Id(len(ds.graph.relations)), live = true,
			derived = derived, from = from, to = to,
			evidence = clone_spans(evidence, ds.a),
		}
	}
	recs := [1]Rec_Record{{kind = .Relation, body = rec_relation_body(row, kind)}}
	if err := ds_graph_commit(ds, recs[:]); err != nil { return {}, err }
	row.kind = graph_kind_intern(&ds.graph, kind)
	graph_apply_relation(&ds.graph, row)
	return row.id, .None
}

graph_attr_put :: proc(ds: ^Disk_Store, doc: Doc_Id, key, val: string) -> Store_Err {
	attr := Doc_Attr{doc = doc, key = clone_str(key, ds.a), val = clone_str(val, ds.a)}
	recs := [1]Rec_Record{{kind = .Attr, body = rec_attr_body(attr)}}
	if err := ds_graph_commit(ds, recs[:]); err != nil { return err }
	graph_apply_attr(&ds.graph, attr)
	return .None
}

/*
graph_entity_merge folds `from` into `into` — the host's "these two
mentions are the same character" judgment, as one transaction: mentions
re-point, incident relations re-point (an edge that becomes a self-loop
is dropped — it carries no pair), rows colliding on identity merge their
evidence into the lower id, every name `from` held re-maps, and `from`
tombstones. The plan lands as ONE batch — one Commit frame — so a torn
append repairs to the pre-merge state; memory follows the durable
write. Deterministic: rows are visited in id order and colliding
evidence concatenates in id order.
*/
graph_entity_merge :: proc(ds: ^Disk_Store, into, from: Entity_Id) -> Store_Err {
	g := &ds.graph
	if !graph_entity_live(g, into) || !graph_entity_live(g, from) { return .Not_Found }
	if into == from { return .Bad_Range }
	into_row := g.entities[int(into)]
	from_row := g.entities[int(from)]

	// into absorbs from's names that are not already its own
	aliases: [dynamic]string = make([dynamic]string, 0,
		len(into_row.aliases) + len(from_row.aliases) + 1, ds.a)
	for al in into_row.aliases {
		append(&aliases, al)
	}
	cands: [dynamic]string = make([dynamic]string, 0, len(from_row.aliases) + 1,
		context.temp_allocator)
	defer delete(cands)
	if len(from_row.name) > 0 {
		append(&cands, from_row.name)
	}
	for al in from_row.aliases {
		append(&cands, al)
	}
	for cand in cands {
		dup := cand == into_row.name
		if !dup {
			for al in aliases {
				if al == cand { dup = true; break }
			}
		}
		if !dup { append(&aliases, cand) }
	}

	mrows: [dynamic]int = make([dynamic]int, 0, 8, context.temp_allocator)
	defer delete(mrows)
	for i in 0..<len(g.mentions) {
		if g.mentions[i].entity == from { append(&mrows, i) }
	}

	// the relation plan: a working copy on the temp allocator, then
	// only changed rows ship (plain slices have no delete — the temp
	// scope reclaims them)
	rows := make([]Relation, len(g.relations), context.temp_allocator)
	copy(rows, g.relations[:])
	flags := make([]bool, len(rows), context.temp_allocator)

	// pass 1: re-point; an edge folding onto itself dies
	for i in 0..<len(rows) {
		r := &rows[i]
		if !r.live { continue }
		nf, nt := r.from, r.to
		if r.from == from { nf = into }
		if r.to == from { nt = into }
		if nf == r.from && nt == r.to { continue }
		if nf == nt {
			r.live = false
			r.kind = KIND_NONE
			r.evidence = nil
			flags[i] = true
			continue
		}
		r.from, r.to = nf, nt
		flags[i] = true
	}

	// pass 2: collisions on identity fold into the lower id — one
	// working-map probe per row, not a scan per row pair. Rows visit in
	// id order and evidence concatenates in id order, the same
	// determinism the pairwise scan had
	by_ident := make(map[Rel_Identity]int, len(rows), context.temp_allocator)
	defer delete(by_ident)
	for i in 0..<len(rows) {
		if !rows[i].live { continue }
		ident := rel_ident(rows[i])
		if k, hit := by_ident[ident]; hit {
			ev := make([]Span, len(rows[k].evidence) + len(rows[i].evidence), ds.a)
			copy(ev, rows[k].evidence)
			copy(ev[len(rows[k].evidence):], rows[i].evidence)
			rows[k].evidence = ev
			rows[i].live = false
			rows[i].kind = KIND_NONE
			rows[i].evidence = nil
			flags[k] = true
			flags[i] = true
		} else {
			by_ident[ident] = i
		}
	}

	into_final := Entity{
		id = into, live = true, kind = into_row.kind, name = into_row.name,
		aliases = aliases[:],
	}
	from_final := Entity{id = from, live = false, kind = KIND_NONE}

	recs: [dynamic]Rec_Record = make([dynamic]Rec_Record, 0,
		2 + len(mrows) + len(rows), context.temp_allocator)
	defer delete(recs)
	// a tombstoned row's record stops at the 8-byte head, so its kind
	// string argument is the unread "" — live rows read the vocabulary
	append(&recs, Rec_Record{kind = .Entity,
		body = rec_entity_body(into_final, g.kinds[into_final.kind])})
	append(&recs, Rec_Record{kind = .Entity, body = rec_entity_body(from_final, "")})
	for i in mrows {
		append(&recs, Rec_Record{
			kind = .Mention,
			body = rec_mention_body(i, Mention{entity = into, span = g.mentions[i].span}),
		})
	}
	for i in 0..<len(rows) {
		if !flags[i] { continue }
		ks := rows[i].live ? g.kinds[rows[i].kind] : ""
		append(&recs, Rec_Record{kind = .Relation, body = rec_relation_body(rows[i], ks)})
	}
	if err := ds_graph_commit(ds, recs[:]); err != nil { return err }

	graph_apply_entity(g, into_final)
	graph_apply_entity(g, from_final)
	for i in mrows {
		graph_apply_mention(g, i, Mention{entity = into, span = g.mentions[i].span})
	}
	for i in 0..<len(rows) {
		if !flags[i] { continue }
		graph_apply_relation(g, rows[i])
	}
	return .None
}
