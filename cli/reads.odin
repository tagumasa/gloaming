package main

/*
The loop reads: query, unknown, kwic. All three run against one
opened state — the base store or a variant's — and all three pay
the visible-cap discipline: results are fetched as
offset+limit+1 matches per document, sliced globally in doc order,
and `truncated` in the envelope says whether anything existed past
the cut. `unknown` is the dictionary-growth entry point: a sweep,
not a library surface — count and runs per surface, first_seen as
evidence, and optional KWIC samples clamped to the match's own
segment (the library's window rule) rendered as text rows.

The --threads dial fans each command's per-document loop out
(reads_fanout above): workers decode and render on their own arenas,
the doc-order walk after the join emits — byte-identical at any
width. unknown's --sample arm stays serial by design: sampling is
first-occurrence-in-list-order semantics.
*/

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "core:thread"

import "base:intrinsics"
import mv "core:mem/virtual"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

// ---- the per-document read fan-out (the --threads dial) ----

Read_Jobs :: struct {
	next: int, // the next doc index to claim — atomically incremented
	stop: int, // 1 once a worker refused
}

Read_Fanout :: struct {
	rs:      ^Read_State,
	ids:     []gl.Doc_Id,
	jobs:    ^Read_Jobs,
	scratch: ^mv.Arena, // this worker's decode and render arena — rows live to the caller's emit
	body:    proc(ctx: rawptr, i: int, wa: mem.Allocator),
	bctx:    rawptr,
}

read_fanout_entry :: proc(data: rawptr) {
	w := cast(^Read_Fanout)data
	wa := mv.arena_allocator(w.scratch)
	context.allocator = wa
	context.temp_allocator = wa
	for {
		if intrinsics.atomic_load_explicit(&w.jobs.stop, .Seq_Cst) != 0 { return }
		i := intrinsics.atomic_add_explicit(&w.jobs.next, 1, .Seq_Cst)
		if i >= len(w.ids) { return }
		w.body(w.bctx, i, wa)
	}
}

/*
reads_fanout maps `body` over the doc list at the dial's width:
workers claim doc indices off the shared counter, each with its own
growing scratch arena (context allocators pinned there — the one-shot
process's allocator is not thread-safe), and body writes its results
into caller-given slots indexed by list position — disjoint writes,
no lock anywhere. Workers only read the store (the library's
concurrent-read contract) and no thread outlives the call. The
returned arenas hold what the workers rendered; the caller destroys
them after emitting. threads <= 1 is the caller's serial loop,
untouched.
*/
reads_fanout :: proc(rs: ^Read_State, ids: []gl.Doc_Id, threads: int,
                     body: proc(ctx: rawptr, i: int, wa: mem.Allocator),
                     bctx: rawptr, a: mem.Allocator) -> ([]^mv.Arena, bool) {
	w := threads
	if w > len(ids) { w = len(ids) }
	if w < 1 { w = 1 }
	arenas := make([]^mv.Arena, w, a)
	jobs := Read_Jobs{}
	fw := make([]Read_Fanout, w, a)
	threads_out := make([dynamic]^thread.Thread, 0, w - 1, a)
	ok := true
	for i in 0..<w {
		arenas[i] = new_scratch(a)
		if arenas[i] == nil { ok = false; break }
		fw[i] = Read_Fanout{
			rs = rs, ids = ids, jobs = &jobs,
			scratch = arenas[i], body = body, bctx = bctx,
		}
		if i > 0 {
			if t := thread.create_and_start_with_data(&fw[i], read_fanout_entry); t != nil {
				append(&threads_out, t)
			}
		}
	}
	if ok {
		// the caller is worker 0; the context pin is the worker's, so
		// the ambient returns with the call
		caller_context := context
		read_fanout_entry(&fw[0])
		context = caller_context
	}
	for t in threads_out {
		thread.join(t)
		thread.destroy(t)
	}
	delete(threads_out)
	if len(fw) > 0 { mem.free(raw_data(fw), a) }
	if !ok {
		for ar in arenas {
			if ar != nil { mv.arena_destroy(ar); free(ar, a) }
		}
		if len(arenas) > 0 { mem.free(raw_data(arenas), a) }
		return nil, false
	}
	return arenas, true
}

// ---- query's two fan-out bodies ----

Query_Count_Slot :: struct {
	n:    int,
	sat:  bool,
	serr: gl.Store_Err,
	qerr: gl.Query_Err,
}

Query_Count_Ctx :: struct {
	rs:    ^Read_State,
	ids:   []gl.Doc_Id,
	q:     ^gl.Query,
	cap_n: int,
	slots: []Query_Count_Slot,
}

query_count_body :: proc(ctx: rawptr, i: int, wa: mem.Allocator) {
	c := cast(^Query_Count_Ctx)ctx
	s := &c.slots[i]
	stream, serr := load_stream(c.rs, c.ids[i], wa)
	if serr != .None { s.serr = serr; return }
	n, sat, qerr := gl.query_count(c.q, stream, c.cap_n, wa)
	s.n, s.sat, s.qerr = n, sat, qerr
}

Query_Rows_Slot :: struct {
	rows:      []string, // rendered match rows, worker-arena
	truncated: bool,
	serr:      gl.Store_Err,
	merr:      gl.Query_Err,
	drow:      bool, // doc_row missing from the manifest
	tcode:     int,  // text_for_doc's refusal
}

Query_Rows_Ctx :: struct {
	rs:    ^Read_State,
	ids:   []gl.Doc_Id,
	q:     ^gl.Query,
	fetch: int,
	slots: []Query_Rows_Slot,
}

query_rows_body :: proc(ctx: rawptr, i: int, wa: mem.Allocator) {
	c := cast(^Query_Rows_Ctx)ctx
	s := &c.slots[i]
	stream, serr := load_stream(c.rs, c.ids[i], wa)
	if serr != .None { s.serr = serr; return }
	res, merr := gl.query_match(c.q, stream, c.fetch, wa)
	if merr != .None { s.merr = merr; return }
	if res.truncated { s.truncated = true }
	row, ok := doc_row(&c.rs.m, c.ids[i])
	if !ok { s.drow = true; return }
	text, tcode := text_for_doc(c.rs.dir, row, wa)
	if tcode != 0 { s.tcode = tcode; return }
	rr: [dynamic]string = make([dynamic]string, 0, len(res.matches), wa)
	for m in res.matches {
		append(&rr, glexport.match_json(m, stream, text, c.q, wa))
	}
	s.rows = rr[:]
}

// ---- kwic's fan-out body ----

Kwic_Rows_Slot :: struct {
	rows:      []string, // rendered kwic rows in the command's format
	truncated: bool,
	serr:      gl.Store_Err,
	merr:      gl.Query_Err,
	drow:      bool,
	tcode:     int,
}

Kwic_Rows_Ctx :: struct {
	rs:        ^Read_State,
	ids:       []gl.Doc_Id,
	q:         ^gl.Query,
	fetch:     int, // offset + limit + 1 — the visible-cap discipline, per document
	left_n:    int,
	right_n:   int,
	center_def: int,
	sort_key:  gl.Kwic_Sort_Key,
	format:    string,
	slots:     []Kwic_Rows_Slot,
}

kwic_rows_body :: proc(ctx: rawptr, i: int, wa: mem.Allocator) {
	c := cast(^Kwic_Rows_Ctx)ctx
	s := &c.slots[i]
	stream, serr := load_stream(c.rs, c.ids[i], wa)
	if serr != .None { s.serr = serr; return }
	res, merr := gl.query_match(c.q, stream, c.fetch, wa)
	if merr != .None { s.merr = merr; return }
	if res.truncated { s.truncated = true }
	if len(res.matches) == 0 { return }
	krows := gl.kwic(res.matches, stream, c.left_n, c.right_n, c.center_def, wa)
	// sorting is per document (kwic_sort reads the row's own stream);
	// documents concatenate in id order
	gl.kwic_sort(krows, stream, c.sort_key)
	row, ok := doc_row(&c.rs.m, c.ids[i])
	if !ok { s.drow = true; return }
	text, tcode := text_for_doc(c.rs.dir, row, wa)
	if tcode != 0 { s.tcode = tcode; return }
	rr: [dynamic]string = make([dynamic]string, 0, len(krows), wa)
	for kr in krows {
		if c.format == "json" {
			b := strings.builder_make(wa)
			glexport.kwic_row_json(kr, text, &b)
			append(&rr, strings.to_string(b))
		} else {
			append(&rr, kwic_text_row(kr, text, wa))
		}
	}
	s.rows = rr[:]
}

// destroys a reads_fanout's arenas after the emit
read_arenas_drop :: proc(arenas: []^mv.Arena, a: mem.Allocator) {
	for ar in arenas {
		if ar != nil { mv.arena_destroy(ar); free(ar, a) }
	}
	if len(arenas) > 0 { mem.free(raw_data(arenas), a) }
}

// ---- unknown's sweep fan-out (the --sample arm stays serial) ----

Unk_Worker :: struct {
	rs:      ^Read_State,
	ids:     []gl.Doc_Id,
	jobs:    ^Read_Jobs,
	scratch: ^mv.Arena,
	// this lane's partial tallies on its own arena — the surfaces
	// borrow the decoded token views there, alive to the merge
	names:       [dynamic]string,
	counts:      [dynamic]int,
	runs:        [dynamic]int,
	first_doc:   [dynamic]u32,
	first_start: [dynamic]int,
	first_end:   [dynamic]int,
	first_pos:   [dynamic]int, // the doc list position of this lane's first sighting — the merge's order key
	ix:          map[string]int,
	fdoc:        int, // the refusing doc's list position, -1 when none
	serr:        gl.Store_Err,
}

unk_worker_entry :: proc(data: rawptr) {
	w := cast(^Unk_Worker)data
	wa := mv.arena_allocator(w.scratch)
	context.allocator = wa
	context.temp_allocator = wa
	for {
		if intrinsics.atomic_load_explicit(&w.jobs.stop, .Seq_Cst) != 0 { return }
		i := intrinsics.atomic_add_explicit(&w.jobs.next, 1, .Seq_Cst)
		if i >= len(w.ids) { return }
		stream, serr := load_stream(w.rs, w.ids[i], wa)
		if serr != .None {
			w.fdoc = i
			w.serr = serr
			intrinsics.atomic_store_explicit(&w.jobs.stop, 1, .Seq_Cst)
			return
		}
		prev_u, prev_s := false, ""
		for tok in stream.tokens {
			if tok.kind == .Unknown {
				row, has := w.ix[tok.surface]
				if !has {
					row = len(w.names)
					w.ix[tok.surface] = row
					append(&w.names, tok.surface)
					append(&w.counts, 0)
					append(&w.runs, 0)
					append(&w.first_doc, u32(w.ids[i]))
					append(&w.first_start, tok.start)
					append(&w.first_end, tok.end)
					append(&w.first_pos, i)
				}
				w.counts[row] += 1
				// a run is a maximal block of consecutive same-surface
				// unknown tokens
				if !(prev_u && prev_s == tok.surface) { w.runs[row] += 1 }
			}
			prev_u, prev_s = tok.kind == .Unknown, tok.surface
		}
	}
}

/*
unk_sweep_fanout is the unknown sweep's wide path: one partial tally
per lane, merged by the caller in lane order — counts and runs sum,
first_seen is whichever lane saw the surface at the smallest doc
list position, which is the serial run's first-doc-in-list-order
rule. The --sample arm never takes this path: sampling is
first-occurrence semantics, serial by design.
*/
unk_sweep_fanout :: proc(rs: ^Read_State, ids: []gl.Doc_Id, threads: int,
                         a: mem.Allocator) -> (lanes: []Unk_Worker,
                         arenas: []^mv.Arena, ok: bool) {
	w := threads
	if w > len(ids) { w = len(ids) }
	if w < 1 { w = 1 }
	arenas = make([]^mv.Arena, w, a)
	lanes = make([]Unk_Worker, w, a)
	jobs := Read_Jobs{}
	threads_out := make([dynamic]^thread.Thread, 0, w - 1, a)
	ok = true
	for i in 0..<w {
		arenas[i] = new_scratch(a)
		if arenas[i] == nil { ok = false; break }
		wa := mv.arena_allocator(arenas[i])
		lanes[i] = Unk_Worker{
			rs = rs, ids = ids, jobs = &jobs, scratch = arenas[i],
			fdoc = -1,
		}
		lanes[i].ix = make(map[string]int, wa)
		if i > 0 {
			if t := thread.create_and_start_with_data(&lanes[i], unk_worker_entry); t != nil {
				append(&threads_out, t)
			}
		}
	}
	if ok {
		// the caller is worker 0; the context pin is the worker's, so
		// the ambient returns with the call
		caller_context := context
		unk_worker_entry(&lanes[0])
		context = caller_context
	}
	for t in threads_out {
		thread.join(t)
		thread.destroy(t)
	}
	delete(threads_out)
	if !ok {
		unk_lanes_drop(lanes, arenas, a)
		return nil, nil, false
	}
	return lanes, arenas, true
}

// the lanes' tallies borrow the arenas; destroy after the emission
unk_lanes_drop :: proc(lanes: []Unk_Worker, arenas: []^mv.Arena, a: mem.Allocator) {
	read_arenas_drop(arenas, a)
	if len(lanes) > 0 { mem.free(raw_data(lanes), a) }
}

Read_State :: struct {
	dir:  string,
	m:    Manifest,
	eng:  Eng,
	st:   gl.Store,
	ds:   ^gl.Disk_Store,
	vrow: ^Variant_Row, // nil for the base state
}

open_read :: proc(g: ^Globals, a: mem.Allocator) -> (rs: Read_State, code: int) {
	rs.dir, code = discover_project(g, a)
	if code != 0 { return }
	rs.m, code = manifest_load(rs.dir, a)
	if code != 0 { return }
	if g.variant != "" {
		ix, ok := find_variant(&rs.m, g.variant)
		if !ok { return {}, io_errorf("unknown variant %s", g.variant) }
		rs.vrow = &rs.m.variants[ix]
	}
	rs.eng, code = eng_load(rs.dir, &rs.m, rs.vrow, a)
	if code != 0 { return }
	store_dir := pjoin({rs.dir, "store"}, a)
	if rs.vrow != nil {
		store_dir = pjoin({rs.dir, "variants", rs.vrow.name, "store"}, a)
	}
	st, ds, serr := gl.store_disk(store_dir,
		resolver_for(&rs.eng), resolver_ctx(&rs.eng), rs.eng.hash, 0, a)
	if serr != .None { return {}, analysis_errorf("store open failed: %v", serr) }
	rs.st = st
	rs.ds = ds
	return rs, 0
}

close_read :: proc(rs: ^Read_State, a: mem.Allocator) {
	discard_err(gl.disk_store_close(rs.ds))
	eng_destroy(&rs.eng, a)
}

load_stream :: proc(rs: ^Read_State, id: gl.Doc_Id,
                    a: mem.Allocator) -> (gl.Token_Stream, gl.Store_Err) {
	toks, terr := rs.st.tokens(rs.st.ctx, id, a)
	if terr != .None { return {}, terr }
	segs, serr := rs.st.segments(rs.st.ctx, id, a)
	if serr != .None { return {}, serr }
	return {doc = id, tokens = toks, segments = segs}, .None
}

// ------------------------------------------------------------
// query
// ------------------------------------------------------------

cmd_query :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	dsl := ""
	doc_sel := ""
	count := false
	limit, offset := 1000, 0
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--doc" {
			v, ok := flag_value(rest, &i, "--doc")
			if !ok { return EXIT_USAGE }
			doc_sel = v
		} else if arg == "--count" {
			count = true
		} else if arg == "--limit" {
			v, ok := flag_int(rest, &i, "--limit", 1)
			if !ok { return EXIT_USAGE }
			limit = v
		} else if arg == "--offset" {
			v, ok := flag_int(rest, &i, "--offset", 0)
			if !ok { return EXIT_USAGE }
			offset = v
		} else if strings.starts_with(arg, "--") {
			return unknown_flag_errorf("query", arg)
		} else if dsl == "" {
			dsl = arg
		} else {
			return usage_errorf("query: exactly one pattern")
		}
	}
	if dsl == "" { return usage_errorf("query: missing pattern") }

	err_pos := -1
	q, qerr := gl.query_parse(dsl, gl.Parse_Options{}, a, &err_pos)
	if qerr != .None { return pattern_errorf(qerr, err_pos) }

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, doc_sel, a)
	if icode != 0 { return icode }

	if count {
		// counting is its own read: exact unless the work bound bites —
		// --limit caps rendered rows, not the count
		cap_n := 1 << 30
		total := 0
		saturated := false
		cc_arenas: []^mv.Arena
		if g.threads > 1 && len(ids) > 0 {
			cc := Query_Count_Ctx{
				rs = &rs, ids = ids, q = &q, cap_n = cap_n,
				slots = make([]Query_Count_Slot, len(ids), a),
			}
			ca, fok := reads_fanout(&rs, ids, g.threads, query_count_body, &cc, a)
			if !fok { return io_errorf("read fan-out arena init failed") }
			cc_arenas = ca
			for i in 0..<len(ids) {
				s := &cc.slots[i]
				if s.serr != .None {
					return analysis_errorf("store read doc %d: %v", u32(ids[i]), s.serr)
				}
				if s.qerr != .None {
					return analysis_errorf("query: %s", query_err_text(s.qerr))
				}
				total += s.n
				if s.sat { saturated = true }
			}
		} else {
			for id in ids {
				stream, serr := load_stream(&rs, id, a)
				if serr != .None {
					return analysis_errorf("store read doc %d: %v", u32(id), serr)
				}
				n, sat, qerr2 := gl.query_count(&q, stream, cap_n, a)
				if qerr2 != .None {
					return analysis_errorf("query: %s", query_err_text(qerr2))
				}
				total += n
				if sat { saturated = true }
			}
		}
		// the drop must outlive the emit — a branch-level defer would
		// fire at the branch's end
		defer if cc_arenas != nil { read_arenas_drop(cc_arenas, a) }
		b := strings.builder_make(a)
		strings.write_string(&b, "[{\"count\":")
		fmt.sbprintf(&b, "%d", total)
		strings.write_string(&b, ",\"saturated\":")
		fmt.sbprintf(&b, "%v", saturated)
		strings.write_string(&b, "}]")
		emit_envelope("query", rs.eng.hash, g.variant, saturated, strings.to_string(b), a)
		return EXIT_OK
	}

	fetch := offset + limit + 1
	rows: [dynamic]string = make([dynamic]string, 0, limit, a)
	truncated := false
	dropped, emitted := 0, 0
	rows_arenas: []^mv.Arena
	if g.threads > 1 && len(ids) > 0 {
		rc := Query_Rows_Ctx{
			rs = &rs, ids = ids, q = &q, fetch = fetch,
			slots = make([]Query_Rows_Slot, len(ids), a),
		}
		ra, fok := reads_fanout(&rs, ids, g.threads, query_rows_body, &rc, a)
		if !fok { return io_errorf("read fan-out arena init failed") }
		rows_arenas = ra
		for i in 0..<len(ids) {
			s := &rc.slots[i]
			if s.serr != .None {
				return analysis_errorf("store read doc %d: %v", u32(ids[i]), s.serr)
			}
			if s.merr != .None {
				return analysis_errorf("query: %s", query_err_text(s.merr))
			}
			if s.drow {
				return analysis_errorf("doc %d missing from the manifest", u32(ids[i]))
			}
			if s.tcode != 0 { return s.tcode }
			if s.truncated { truncated = true }
			for rstr in s.rows {
				if dropped < offset {
					dropped += 1
					continue
				}
				if emitted >= limit {
					truncated = true
					break
				}
				append(&rows, rstr)
				emitted += 1
			}
		}
	} else {
		for id in ids {
			stream, serr := load_stream(&rs, id, a)
			if serr != .None {
				return analysis_errorf("store read doc %d: %v", u32(id), serr)
			}
			res, merr := gl.query_match(&q, stream, fetch, a)
			if merr != .None {
				return analysis_errorf("query: %s", query_err_text(merr))
			}
			if res.truncated { truncated = true }
			row, ok := doc_row(&rs.m, id)
			if !ok { return analysis_errorf("doc %d missing from the manifest", u32(id)) }
			text, tcode := text_for_doc(rs.dir, row, a)
			if tcode != 0 { return tcode }
			for m in res.matches {
				if dropped < offset {
					dropped += 1
					continue
				}
				if emitted >= limit {
					truncated = true
					break
				}
				append(&rows, glexport.match_json(m, stream, text, &q, a))
				emitted += 1
			}
		}
	}
	// the parallel rows reference the workers' render arenas — the drop
	// must outlive the emit, so it sits here at the procedure's scope
	// (a branch-level defer would fire at the branch's end)
	defer if rows_arenas != nil { read_arenas_drop(rows_arenas, a) }
	emit_envelope("query", rs.eng.hash, g.variant, truncated, join_rows(rows[:], a), a)
	return EXIT_OK
}

// ------------------------------------------------------------
// unknown
// ------------------------------------------------------------

// the unknown sample's KWIC half-width: enough context to read the
// word in place, and the library clamps to the segment anyway
SAMPLE_CONTEXT :: 5

/*
The sweep's emission key: row index into the parallel totals plus the
two sort fields — count descending, surface ascending, the same order
the per-record pointer list used to sort by. Values in one array, not
one allocation per surface.
*/
Unk_Key :: struct {
	row:     int,
	count:   int,
	surface: string,
}

unkkey_less :: proc(x, y: ^Unk_Key) -> bool {
	if x.count != y.count { return x.count > y.count }
	return strings.compare(x.surface, y.surface) < 0
}

cmd_unknown :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	min_count, min_len := 0, 0
	sample, limit := 0, 200
	format := "json"
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--min-count" {
			v, ok := flag_int(rest, &i, "--min-count", 0)
			if !ok { return EXIT_USAGE }
			min_count = v
		} else if arg == "--min-len" {
			v, ok := flag_int(rest, &i, "--min-len", 0)
			if !ok { return EXIT_USAGE }
			min_len = v
		} else if arg == "--sample" {
			v, ok := flag_int(rest, &i, "--sample", 0)
			if !ok { return EXIT_USAGE }
			sample = v
		} else if arg == "--limit" {
			v, ok := flag_int(rest, &i, "--limit", 1)
			if !ok { return EXIT_USAGE }
			limit = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if code := choice_ok("unknown", "--format", v, FORMAT_UNKNOWN); code != 0 {
					return code
				}
				format = v
			} else {
				return unknown_flag_errorf("unknown", arg)
		}
	}

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, "", a)
	if icode != 0 { return icode }

	// the sweep totals as parallel arrays over interned surface rows —
	// one map probe per token, integer counting, no per-record pointer
	names: [dynamic]string = make([dynamic]string, 0, 64, a)
	counts: [dynamic]int = make([dynamic]int, 0, 64, a)
	runs: [dynamic]int = make([dynamic]int, 0, 64, a)
	first_doc: [dynamic]u32 = make([dynamic]u32, 0, 64, a)
	first_start: [dynamic]int = make([dynamic]int, 0, 64, a)
	first_end: [dynamic]int = make([dynamic]int, 0, 64, a)
	sampled: [dynamic]int = make([dynamic]int, 0, 64, a)
	samples: [dynamic][dynamic]string = make([dynamic][dynamic]string, 0, 64, a)
	// sample bookkeeping, only when --sample asked: occurrences as
	// one-token Matches, the stream and text they need, kept per doc.
	// The inner dynamic headers live in map values — copy, append,
	// write the grown handle back (map values are not addressable)
	occ: map[u32]map[string][dynamic]gl.Match
	streams: map[u32]gl.Token_Stream
	texts: map[u32]string
	if sample > 0 {
		occ = make(map[u32]map[string][dynamic]gl.Match, a)
		streams = make(map[u32]gl.Token_Stream, a)
		texts = make(map[u32]string, a)
	}

	sweep_lanes: []Unk_Worker
	sweep_arenas: []^mv.Arena
	if g.threads > 1 && sample == 0 && len(ids) > 0 {
		// the fanned sweep: per-lane partials merged in lane order —
		// counts and runs sum, first_seen is the smallest doc list
		// position (the serial walk's first-doc-in-list-order rule)
		ul, ua, fok := unk_sweep_fanout(&rs, ids, g.threads, a)
		if !fok { return io_errorf("sweep fan-out arena init failed") }
		sweep_lanes, sweep_arenas = ul, ua
		bad, bpos := -1, -1
		for lane, li in sweep_lanes {
			if lane.fdoc >= 0 && (bpos < 0 || lane.fdoc < bpos) {
				bad, bpos = li, lane.fdoc
			}
		}
		if bad >= 0 {
			return analysis_errorf("store read doc %d: %v", u32(ids[bpos]), sweep_lanes[bad].serr)
		}
		mix := make(map[string]int, a)
		mpos: [dynamic]int = make([dynamic]int, 0, 64, a)
		for lane in sweep_lanes {
			for k in 0..<len(lane.names) {
				surface := lane.names[k]
				mr, has := mix[surface]
				if !has {
					mr = len(names)
					mix[surface] = mr
					append(&names, surface)
					append(&counts, lane.counts[k])
					append(&runs, lane.runs[k])
					append(&first_doc, lane.first_doc[k])
					append(&first_start, lane.first_start[k])
					append(&first_end, lane.first_end[k])
					append(&mpos, lane.first_pos[k])
				} else {
					counts[mr] += lane.counts[k]
					runs[mr] += lane.runs[k]
					if lane.first_pos[k] < mpos[mr] {
						first_doc[mr] = lane.first_doc[k]
						first_start[mr] = lane.first_start[k]
						first_end[mr] = lane.first_end[k]
						mpos[mr] = lane.first_pos[k]
					}
				}
			}
		}
		delete(mix)
		delete(mpos)
	} else {
		ix := make(map[string]int, a)
		defer delete(ix)
		for id in ids {
			stream, serr := load_stream(&rs, id, a)
			if serr != .None {
				return analysis_errorf("store read doc %d: %v", u32(id), serr)
			}
			if sample > 0 {
				streams[u32(id)] = stream
				row, ok := doc_row(&rs.m, id)
				if !ok { return analysis_errorf("doc %d missing from the manifest", u32(id)) }
				text, tcode := text_for_doc(rs.dir, row, a)
				if tcode != 0 { return tcode }
				texts[u32(id)] = text
			}
			prev_u, prev_s := false, ""
			for tok, i in stream.tokens {
				if tok.kind == .Unknown {
					row, has := ix[tok.surface]
					if !has {
						row = len(names)
						ix[tok.surface] = row
						append(&names, tok.surface)
						append(&counts, 0)
						append(&runs, 0)
						append(&first_doc, u32(id))
						append(&first_start, tok.start)
						append(&first_end, tok.end)
						append(&sampled, 0)
						append(&samples, make([dynamic]string, 0, 4, a))
					}
					counts[row] += 1
					// a run is a maximal block of consecutive same-surface
					// unknown tokens
					if !(prev_u && prev_s == tok.surface) { runs[row] += 1 }
					if sample > 0 && sampled[row] < sample {
						dm, has_doc := occ[u32(id)]
						if !has_doc {
							dm = make(map[string][dynamic]gl.Match, a)
							occ[u32(id)] = dm
						}
						mlist, _ := dm[tok.surface]
						append(&mlist, gl.Match{
							start = i,
							end = i + 1,
							span = {doc = id, start = tok.start, end = tok.end},
						})
						dm[tok.surface] = mlist
						sampled[row] += 1
					}
				}
				prev_u, prev_s = tok.kind == .Unknown, tok.surface
			}
		}
	}
	// the merged surfaces borrow the sweep lanes' arenas — the drop
	// must outlive the emission, so it sits here at the procedure's
	// scope (a branch-level defer would fire at the branch's end)
	defer if sweep_arenas != nil { unk_lanes_drop(sweep_lanes, sweep_arenas, a) }

	// emission order over the parallel rows: the sort fields projected
	// into one value array (no re-permutation of eight arrays)
	keys: [dynamic]Unk_Key = make([dynamic]Unk_Key, 0, len(names), a)
	for n, i in names {
		append(&keys, Unk_Key{row = i, count = counts[i], surface = n})
	}
	gl.sort_with_buffer(keys[:], unkkey_less, a)

	rows: [dynamic]string = make([dynamic]string, 0, limit, a)
	truncated := false
	emitted := 0
	for k in keys[:] {
		rec := k.row
		if min_count > 0 && counts[rec] < min_count { continue }
		if min_len >= 2 && utf8.rune_count(names[rec]) < min_len { continue }
		if emitted >= limit {
			truncated = true
			break
		}
		if sample > 0 && format == "json" {
			for id in ids {
				dm, ok := occ[u32(id)]
				if !ok { continue }
				mlist, ok2 := dm[names[rec]]
				if !ok2 || len(mlist) == 0 { continue }
				krows := gl.kwic(mlist[:], streams[u32(id)], SAMPLE_CONTEXT, SAMPLE_CONTEXT, -1, a)
				for kr in krows {
					append(&samples[rec], kwic_text_row(kr, texts[u32(id)], a))
				}
			}
		}
		if format == "json" {
			b := strings.builder_make(a)
			strings.write_string(&b, "{\"surface\":")
			glexport.json_esc(names[rec], &b)
			strings.write_string(&b, ",\"count\":")
			fmt.sbprintf(&b, "%d", counts[rec])
			strings.write_string(&b, ",\"runs\":")
			fmt.sbprintf(&b, "%d", runs[rec])
			strings.write_string(&b, ",\"first_seen\":{\"doc\":")
			fmt.sbprintf(&b, "%d", first_doc[rec])
			strings.write_string(&b, ",\"start\":")
			fmt.sbprintf(&b, "%d", first_start[rec])
			strings.write_string(&b, ",\"end\":")
			fmt.sbprintf(&b, "%d", first_end[rec])
			strings.write_string(&b, "},\"samples\":[")
			for s, i in samples[rec] {
				if i > 0 { strings.write_string(&b, ",") }
				glexport.json_esc(s, &b)
			}
			strings.write_string(&b, "]}")
			append(&rows, strings.to_string(b))
		} else {
			b := strings.builder_make(a)
			tsv_esc(names[rec], &b)
			fmt.sbprintf(&b, "\t%d\t%d\t%d\t%d\t%d", counts[rec], runs[rec], first_doc[rec], first_start[rec], first_end[rec])
			append(&rows, strings.to_string(b))
		}
		emitted += 1
	}

	if format == "tsv" {
		for r in rows[:] { fmt.println(r) }
		return EXIT_OK
	}
	emit_envelope("unknown", rs.eng.hash, g.variant, truncated, join_rows(rows[:], a), a)
	return EXIT_OK
}

// ------------------------------------------------------------
// kwic
// ------------------------------------------------------------

cmd_kwic :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	dsl := ""
	doc_sel := ""
	left_n, right_n := 8, 8
	center := ""
	sort_key := gl.Kwic_Sort_Key(.Position)
	limit, offset := 100, 0
	format := "text"
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--doc" {
			v, ok := flag_value(rest, &i, "--doc")
			if !ok { return EXIT_USAGE }
			doc_sel = v
		} else if arg == "--left" {
			v, ok := flag_int(rest, &i, "--left", 0)
			if !ok { return EXIT_USAGE }
			left_n = v
		} else if arg == "--right" {
			v, ok := flag_int(rest, &i, "--right", 0)
			if !ok { return EXIT_USAGE }
			right_n = v
		} else if arg == "--center" {
			v, ok := flag_value(rest, &i, "--center")
			if !ok { return EXIT_USAGE }
			center = v
		} else if arg == "--sort" {
			v, ok := flag_value(rest, &i, "--sort")
			if !ok { return EXIT_USAGE }
			k, code := kwic_sort_from_string(v, "kwic")
			if code != 0 { return code }
			sort_key = k
		} else if arg == "--limit" {
			v, ok := flag_int(rest, &i, "--limit", 1)
			if !ok { return EXIT_USAGE }
			limit = v
		} else if arg == "--offset" {
			v, ok := flag_int(rest, &i, "--offset", 0)
			if !ok { return EXIT_USAGE }
			offset = v
		} else if arg == "--format" {
			v, ok := flag_value(rest, &i, "--format")
			if !ok { return EXIT_USAGE }
			if code := choice_ok("kwic", "--format", v, FORMAT_KWIC); code != 0 {
				return code
			}
			format = v
		} else if strings.starts_with(arg, "--") {
			return unknown_flag_errorf("kwic", arg)
		} else if dsl == "" {
			dsl = arg
		} else {
			return usage_errorf("kwic: exactly one pattern")
		}
	}
	if dsl == "" { return usage_errorf("kwic: missing pattern") }

	err_pos := -1
	q, qerr := gl.query_parse(dsl, gl.Parse_Options{}, a, &err_pos)
	if qerr != .None { return pattern_errorf(qerr, err_pos) }
	center_def := -1
	if center != "" {
		for c, i in q.captures {
			if c.name == center {
				center_def = i
				break
			}
		}
		if center_def < 0 {
			return usage_errorf("kwic: no capture named %s in the pattern", center)
		}
	}

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, doc_sel, a)
	if icode != 0 { return icode }

	fetch := offset + limit + 1
	truncated := false
	dropped, emitted := 0, 0
	rows_json: [dynamic]string = make([dynamic]string, 0, limit, a)
	rows_text: [dynamic]string = make([dynamic]string, 0, limit, a)
	kwic_arenas: []^mv.Arena
	if g.threads > 1 && len(ids) > 0 {
		kc := Kwic_Rows_Ctx{
			rs = &rs, ids = ids, q = &q, fetch = fetch,
			left_n = left_n, right_n = right_n, center_def = center_def,
			sort_key = sort_key, format = format,
			slots = make([]Kwic_Rows_Slot, len(ids), a),
		}
		ka, fok := reads_fanout(&rs, ids, g.threads, kwic_rows_body, &kc, a)
		if !fok { return io_errorf("read fan-out arena init failed") }
		kwic_arenas = ka
		for i in 0..<len(ids) {
			s := &kc.slots[i]
			if s.serr != .None {
				return analysis_errorf("store read doc %d: %v", u32(ids[i]), s.serr)
			}
			if s.merr != .None {
				return analysis_errorf("kwic: %s", query_err_text(s.merr))
			}
			if s.drow {
				return analysis_errorf("doc %d missing from the manifest", u32(ids[i]))
			}
			if s.tcode != 0 { return s.tcode }
			if s.truncated { truncated = true }
			for rstr in s.rows {
				if dropped < offset {
					dropped += 1
					continue
				}
				if emitted >= limit {
					truncated = true
					break
				}
				if format == "json" {
					append(&rows_json, rstr)
				} else {
					append(&rows_text, rstr)
				}
				emitted += 1
			}
		}
	} else {
		for id in ids {
			stream, serr := load_stream(&rs, id, a)
			if serr != .None {
				return analysis_errorf("store read doc %d: %v", u32(id), serr)
			}
			res, merr := gl.query_match(&q, stream, fetch, a)
			if merr != .None {
				return analysis_errorf("kwic: %s", query_err_text(merr))
			}
			if res.truncated { truncated = true }
			if len(res.matches) == 0 { continue }
			krows := gl.kwic(res.matches, stream, left_n, right_n, center_def, a)
			// sorting is per document (kwic_sort reads the row's own
			// stream); documents concatenate in id order
			gl.kwic_sort(krows, stream, sort_key)
			row, ok := doc_row(&rs.m, id)
			if !ok { return analysis_errorf("doc %d missing from the manifest", u32(id)) }
			text, tcode := text_for_doc(rs.dir, row, a)
			if tcode != 0 { return tcode }
			for kr in krows {
				if dropped < offset {
					dropped += 1
					continue
				}
				if emitted >= limit {
					truncated = true
					break
				}
				switch format {
				case "json":
					b := strings.builder_make(a)
					glexport.kwic_row_json(kr, text, &b)
					append(&rows_json, strings.to_string(b))
				case "text":
					append(&rows_text, kwic_text_row(kr, text, a))
				}
				emitted += 1
			}
		}
	}
	// the parallel rows reference the workers' render arenas — the drop
	// must outlive the emit, so it sits here at the procedure's scope
	defer if kwic_arenas != nil { read_arenas_drop(kwic_arenas, a) }

	if format == "text" {
		for r in rows_text[:] { fmt.println(r) }
		if truncated && !g.quiet {
			fmt.eprintf("truncated: more rows existed past --limit %d\n", limit)
		}
		return EXIT_OK
	}
	emit_envelope("kwic", rs.eng.hash, g.variant, truncated, join_rows(rows_json[:], a), a)
	return EXIT_OK
}
