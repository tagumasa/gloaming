package gloaming_test

/*
The standing concurrency gate (design.md, "API discipline" — the
concurrency table). Four proofs:

1. store_concurrent_reads — four reader threads over one memory
   backend and one cache-warmed disk backend, every read equal to the
   sequential oracle, one shared parsed Query serving concurrent
   cursors, and the disk store's tracking allocator flat across the
   whole concurrent phase (reads never touch store-owned memory —
   the split-plane proof, fuguruma's residency method). One document
   stays unwarmed on purpose: its misses decode on each reader's own
   arena, the pure-read path's other half.
2. corpus_fanout_identity — every fanned corpus pass byte-identical
   at workers 1 and 4, and the refusal vocabulary (.Interrupted via
   the stop-check, .Duplicate) holding at width.
3. corpus_fanout_owns_its_scratch — the frees-only-outputs contract
   at width: freeing the returned rows and their key strings leaves
   the tracking allocator at zero.
4. corpus_fanout_caller_lane_fallback — the caller lane's arena
   refusing (a fail-first allocator) falls back to the serial body
   with no thread started, the outputs equal to the serial
   references.

Thread discipline: each worker entry pins both context allocators to
its own fixed-buffer arena (package scope, the suite's discipline)
before any library call — the runner's per-test tracking allocator is
single-threaded and no worker may touch it. Workers report through
their own struct's flags; the main thread asserts after the joins
(the join is the happens-before edge, moli's concurrent-tokenize
shape).
*/

import "base:runtime"
import "core:mem"
import "core:os"
import mv "core:mem/virtual"
import "core:thread"
import "core:testing"

import gloaming "gloaming:gloaming"

// per-reader arenas: package scope keeps them off the test stacks (a
// 1 MiB local warns), and the serial runner means no test sees
// another's buffers
concurrency_bufs: [4][256 << 10]u8

// the concurrent-reads test's own arena: two stores, three documents,
// the warm cache, and the oracle tables together outrun the shared
// 1 MiB buffer — same package-scope discipline, sized with headroom
conc_arena_buf: [8 << 20]u8

// the dense-matrix tests' arena: k×k tables at the coords dial's
// engaging width (512 keys and up) — weights, dissimilarities, and
// the wide paths' live tables together
matrix_arena_buf: [64 << 20]u8

READERS :: 4

Conc_Reader :: struct {
	kind:    int, // 0,1 disk cache-on reads; 2 memory reads + shared-Query cursors; 3 memory reads + freq
	st:      gloaming.Store,
	docs:    []gloaming.Doc_Id,
	want:    [][]gloaming.Token, // the oracle per doc — borrowed, read-only
	segs:    [][]gloaming.Segment,
	want_ids: []gloaming.Doc_Id,
	q:       ^gloaming.Query, // shared, immutable — concurrent cursors' half
	want_qn: int,
	want_freq: []gloaming.Freq_Entry,
	buf:     []u8,
	ok:       bool,
	stage:    int, // the check that failed, for the assertion message
	errv:     gloaming.Store_Err,
	errdoc:   int,
}

// one reader's whole run on its own arena; returns with the failure
// stage recorded — asserts never run on worker threads
conc_reader_run :: proc(w: ^Conc_Reader, a: mem.Allocator) -> bool {
	ids := w.st.docs(w.st.ctx, a)
	if len(ids) != len(w.want_ids) {
		w.stage = 1
		return false
	}
	for id, i in ids {
		if id != w.want_ids[i] {
			w.stage = 1
			return false
		}
	}
	for d, i in w.docs {
		toks, terr := w.st.tokens(w.st.ctx, d, a)
		if terr != gloaming.Store_Err.None {
			w.stage = 2
			w.errv = terr
			w.errdoc = i
			return false
		}
		if ok, _ := tokens_equal(w.want[i], toks); !ok {
			w.stage = 3
			return false
		}
		sg, serr := w.st.segments(w.st.ctx, d, a)
		if serr != gloaming.Store_Err.None || !segments_equal(w.segs[i], sg) {
			w.stage = 4
			return false
		}
	}
	if w.kind == 2 {
		qn := 0
		for d in w.docs {
			toks, terr := w.st.tokens(w.st.ctx, d, a)
			if terr != gloaming.Store_Err.None {
				w.stage = 5
				return false
			}
			sg, _ := w.st.segments(w.st.ctx, d, a)
			stream := gloaming.Token_Stream{doc = d, tokens = toks, segments = sg}
			c := gloaming.match_begin(w.q, stream, a)
			for {
				_, ok := gloaming.next_match(&c, a)
				if !ok { break }
				qn += 1
			}
			gloaming.cursor_destroy(&c)
		}
		if qn != w.want_qn {
			w.stage = 6
			return false
		}
	}
	if w.kind == 3 {
		entries, err := gloaming.corpus_freq(w.st, w.docs, gloaming.Freq_Filter{}, a)
		if err != gloaming.Store_Err.None {
			w.stage = 7
			return false
		}
		if len(entries) != len(w.want_freq) {
			w.stage = 8
			return false
		}
		for e, i in entries {
			wt := w.want_freq[i]
			if e.lemma != wt.lemma || e.count != wt.count || e.docs != wt.docs {
				w.stage = 8
				return false
			}
		}
	}
	return true
}

conc_reader_entry :: proc(data: rawptr) {
	w := cast(^Conc_Reader)data
	arena: mem.Arena
	mem.arena_init(&arena, w.buf)
	a := mem.arena_allocator(&arena)
	context.allocator = a
	context.temp_allocator = a
	w.ok = conc_reader_run(w, a)
}

// doc 3's fixture: resolvable dictionary ids only (the resolver's
// hand dictionary answers 3/5/7/12), so the cold miss-decode path
// round-trips — 夜 twice over the corpus, 更ける shared with doc 1
conc_doc3 :: proc(a: mem.Allocator) -> (string, []gloaming.Token, []gloaming.Segment) {
	toks := make([]gloaming.Token, 3, a)
	toks[0] = {surface = "夜",     lemma = "夜",     pos = "名詞,一般,*,*,*",       reading = "ヨル",   start = 0,  end = 3,  cost = 100, kind = .Dictionary, entry_id = 7}
	toks[1] = {surface = "が",     lemma = "が",     pos = "助詞,格助詞,一般,*,*", reading = "ガ",     start = 3,  end = 6,  cost = 50,  kind = .Dictionary, entry_id = 3}
	toks[2] = {surface = "更ける", lemma = "更ける", pos = "動詞,自立,一段,基本形", reading = "フケル", start = 6,  end = 15, cost = 300, kind = .Dictionary, entry_id = 12}
	segs := make([]gloaming.Segment, 1, a)
	segs[0] = {kind = .Chapter, span = {doc = 3, start = 0, end = 15}}
	return "夜が更ける", toks, segs
}

@(test)
store_concurrent_reads :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, conc_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(DISK_TEST_DIR) { _ = os.mkdir(DISK_TEST_DIR) }
	disk_test_wipe(a)
	defer disk_test_wipe(a)

	// the corpus, identical in both backends; the disk store rides a
	// tracking allocator — the split plane under proof
	dict := u64(0xBEEF)
	mem_store, merr := gloaming.store_memory(a)
	if !testing.expectf(t, merr == .None, "store_memory: %v", merr) { return }
	dtrk: mem.Tracking_Allocator
	mem.tracking_allocator_init(&dtrk, a)
	defer mem.tracking_allocator_destroy(&dtrk)
	dta := mem.tracking_allocator(&dtrk)
	disk_store, dds, derr := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, dta, cache_max_bytes = 64 * 1024)
	if !testing.expectf(t, derr == .None, "store_disk: %v", derr) { return }

	text1, toks1, segs1 := disk_test_doc(a)
	doc2 := make([]gloaming.Token, 1, a)
	doc2[0] = toks1[1]
	doc2[0].start = 0
	doc2[0].end = 3
	segs2 := make([]gloaming.Segment, 1, a)
	segs2[0] = {kind = .Chapter, span = {doc = 2, start = 0, end = 3}}
	text3, toks3, segs3 := conc_doc3(a)
	stores := [2]gloaming.Store{mem_store, disk_store}
	for st in stores {
		if aer := st.add_document(st.ctx, 1, text1, toks1, segs1); aer != .None {
			testing.expectf(t, false, "add 1: %v", aer)
			return
		}
		if aer := st.add_document(st.ctx, 2, "が", doc2, segs2); aer != .None {
			testing.expectf(t, false, "add 2: %v", aer)
			return
		}
		if aer := st.add_document(st.ctx, 3, text3, toks3, segs3); aer != .None {
			testing.expectf(t, false, "add 3: %v", aer)
			return
		}
	}

	// docs 1 and 2 warm; doc 3 stays cold so half the concurrent
	// reads ride the miss-decode path on each reader's own arena
	warm := []gloaming.Doc_Id{1, 2}
	if werr := gloaming.disk_store_cache_warm(dds, warm); werr != gloaming.Store_Err.None {
		testing.expectf(t, false, "warm: %v", werr)
		return
	}

	// the cold half round-trips on the main thread too — the miss
	// decode is the pure-read path's other half, checked before any
	// thread exists
	all3 := []gloaming.Doc_Id{1, 2, 3}
	for d in all3 {
		_, terr := disk_store.tokens(disk_store.ctx, d, a)
		testing.expectf(t, terr == gloaming.Store_Err.None,
			"serial pre-spawn read doc %d: %v", u32(d), terr)
	}

	// the sequential oracle, from the memory backend (the
	// differential reference)
	docs := []gloaming.Doc_Id{1, 2, 3}
	want := [][]gloaming.Token{toks1, doc2, toks3}
	wsegs := [][]gloaming.Segment{segs1, segs2, segs3}
	want_ids := mem_store.docs(mem_store.ctx, a)
	q, qerr := gloaming.query_parse("(seq (m lemma \"夜\"))", gloaming.Parse_Options{}, a, nil)
	if !testing.expectf(t, qerr == .None, "query_parse: %v", qerr) { return }
	qn := 0
	for d in docs {
		toks, _ := mem_store.tokens(mem_store.ctx, d, a)
		sg, _ := mem_store.segments(mem_store.ctx, d, a)
		stream := gloaming.Token_Stream{doc = d, tokens = toks, segments = sg}
		c := gloaming.match_begin(&q, stream, a)
		for {
			_, ok := gloaming.next_match(&c, a)
			if !ok { break }
			qn += 1
		}
		gloaming.cursor_destroy(&c)
	}
	want_freq, ferr := gloaming.corpus_freq(mem_store, docs, gloaming.Freq_Filter{}, a)
	if !testing.expectf(t, ferr == .None, "corpus_freq oracle: %v", ferr) { return }

	// the split-plane baseline, after every setup allocation
	base_now := dtrk.current_memory_allocated
	base_tot := dtrk.total_memory_allocated

	readers: [READERS]Conc_Reader
	threads: [READERS]^thread.Thread
	for i in 0..<READERS {
		readers[i] = Conc_Reader{
			kind = i, docs = docs, want = want, segs = wsegs,
			want_ids = want_ids, q = &q, want_qn = qn, want_freq = want_freq,
			buf = concurrency_bufs[i][:],
		}
		readers[i].st = i <= 1 ? disk_store : mem_store
		threads[i] = thread.create_and_start_with_data(&readers[i], conc_reader_entry)
	}
	for i in 0..<READERS {
		if threads[i] != nil {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}
	}

	// the split-plane proof: the concurrent phase moved nothing on the
	// store plane — reads never allocate on store-owned memory
	testing.expectf(t, dtrk.current_memory_allocated == base_now,
		"store plane moved during concurrent reads: %d -> %d bytes",
		base_now, dtrk.current_memory_allocated)
	testing.expectf(t, dtrk.total_memory_allocated == base_tot,
		"store plane allocated during concurrent reads: %d -> %d bytes total",
		base_tot, dtrk.total_memory_allocated)

	for i in 0..<READERS {
		testing.expectf(t, readers[i].ok, "reader %d failed at stage %d (tokens err %v, doc %d)",
			i, readers[i].stage, readers[i].errv, readers[i].errdoc)
	}

	testing.expect_value(t, int(gloaming.disk_store_close(dds)), int(gloaming.Store_Err.None))
}

// ---- the fan-out identity and refusal proofs ----

freq_rows_equal :: proc(x, y: []gloaming.Freq_Entry) -> bool {
	if len(x) != len(y) { return false }
	for e, i in x {
		if e.lemma != y[i].lemma || e.count != y[i].count || e.docs != y[i].docs {
			return false
		}
	}
	return true
}

profiles_equal :: proc(x, y: []gloaming.Doc_Profile) -> bool {
	if len(x) != len(y) { return false }
	for p, i in x {
		if p.doc != y[i].doc || len(p.keys) != len(y[i].keys) { return false }
		for k, j in p.keys {
			if k != y[i].keys[j] || p.counts[j] != y[i].counts[j] { return false }
		}
	}
	return true
}

f64_bits_equal :: proc(x, y: []f64) -> bool {
	if len(x) != len(y) { return false }
	for f, i in x {
		if transmute(u64)f != transmute(u64)y[i] { return false }
	}
	return true
}

pairs_equal :: proc(x, y: []gloaming.Co_Pair) -> bool {
	if len(x) != len(y) { return false }
	for p, i in x {
		if p.a != y[i].a || p.b != y[i].b || p.n != y[i].n { return false }
	}
	return true
}

cross_equal :: proc(x, y: ^gloaming.Cross_Table) -> bool {
	if len(x.vals) != len(y.vals) || len(x.keys) != len(y.keys) { return false }
	if len(x.cells) != len(y.cells) || len(x.docs) != len(y.docs) { return false }
	for v, i in x.vals {
		if v != y.vals[i] || x.sizes[i] != y.sizes[i] { return false }
	}
	for k, i in x.keys {
		if k != y.keys[i] { return false }
	}
	for c, i in x.cells {
		if c != y.cells[i] || x.docs[i] != y.docs[i] { return false }
	}
	return true
}

@(test)
corpus_fanout_identity :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	store, serr := gloaming.store_memory(a)
	if !testing.expectf(t, serr == .None, "store_memory: %v", serr) { return }
	text1, toks1, segs1 := disk_test_doc(a)
	doc2 := make([]gloaming.Token, 1, a)
	doc2[0] = toks1[1]
	doc2[0].start = 0
	doc2[0].end = 3
	segs2 := make([]gloaming.Segment, 1, a)
	segs2[0] = {kind = .Chapter, span = {doc = 2, start = 0, end = 3}}
	text3, toks3, segs3 := conc_doc3(a)
	if aer := store.add_document(store.ctx, 1, text1, toks1, segs1); aer != .None {
		testing.expectf(t, false, "add 1: %v", aer)
		return
	}
	if aer := store.add_document(store.ctx, 2, "が", doc2, segs2); aer != .None {
		testing.expectf(t, false, "add 2: %v", aer)
		return
	}
	if aer := store.add_document(store.ctx, 3, text3, toks3, segs3); aer != .None {
		testing.expectf(t, false, "add 3: %v", aer)
		return
	}
	docs := []gloaming.Doc_Id{1, 2, 3}
	attrs := []gloaming.Doc_Attr{
		{doc = 1, key = "genre", val = "mystery"},
		{doc = 2, key = "genre", val = "essay"},
		{doc = 3, key = "genre", val = "mystery"},
	}
	groups := gloaming.doc_groups(attrs, "genre", docs, a)

	// corpus_freq at width 1 against width 4
	f1, e1 := gloaming.corpus_freq(store, docs, gloaming.Freq_Filter{}, a)
	if !testing.expectf(t, e1 == .None, "freq w1: %v", e1) { return }
	f4, e4 := gloaming.corpus_freq(store, docs, gloaming.Freq_Filter{}, a, nil, nil, 4)
	if !testing.expectf(t, e4 == .None, "freq w4: %v", e4) { return }
	testing.expect(t, freq_rows_equal(f1, f4), "corpus_freq rows differ across widths")

	// doc_profiles at width, then doc_matrix over the w1 profiles
	p1, pe1 := gloaming.doc_profiles(store, docs, gloaming.Freq_Filter{}, a)
	if !testing.expectf(t, pe1 == .None, "profiles w1: %v", pe1) { return }
	p4, pe4 := gloaming.doc_profiles(store, docs, gloaming.Freq_Filter{}, a, nil, nil, 4)
	if !testing.expectf(t, pe4 == .None, "profiles w4: %v", pe4) { return }
	testing.expect(t, profiles_equal(p1, p4), "doc_profiles differ across widths")
	keys: [dynamic]string = make([dynamic]string, 0, 8, a)
	seen := make(map[string]bool, a)
	defer delete(seen)
	for e in f1 {
		if _, dup := seen[e.lemma]; dup { continue }
		seen[e.lemma] = true
		append(&keys, e.lemma)
	}
	m1, me1 := gloaming.doc_matrix(p1, keys[:], f1, .Tf_Idf, a)
	if !testing.expectf(t, me1 == .None, "matrix w1: %v", me1) { return }
	m4, me4 := gloaming.doc_matrix(p1, keys[:], f1, .Tf_Idf, a, nil, nil, 4)
	if !testing.expectf(t, me4 == .None, "matrix w4: %v", me4) { return }
	testing.expect(t, f64_bits_equal(m1, m4), "doc_matrix cells differ across widths")

	// cross_table at width
	c1, ce1 := gloaming.cross_table(store, groups, gloaming.Freq_Filter{}, a)
	if !testing.expectf(t, ce1 == .None, "cross w1: %v", ce1) { return }
	c4, ce4 := gloaming.cross_table(store, groups, gloaming.Freq_Filter{}, a, nil, nil, 4)
	if !testing.expectf(t, ce4 == .None, "cross w4: %v", ce4) { return }
	testing.expect(t, cross_equal(&c1, &c4), "cross_table differs across widths")

	// corpus_cooc at width
	copts := gloaming.Cooc_Options{unit = .Segments, window = 0, max_pairs = 0}
	o1, cp1, oe1 := gloaming.corpus_cooc(store, docs, copts, a)
	if !testing.expectf(t, oe1 == .None, "cooc w1: %v", oe1) { return }
	o4, cp4, oe4 := gloaming.corpus_cooc(store, docs, copts, a, nil, nil, 4)
	if !testing.expectf(t, oe4 == .None, "cooc w4: %v", oe4) { return }
	testing.expect(t, pairs_equal(o1, o4), "corpus_cooc pairs differ across widths")
	testing.expect_value(t, int(cp4), int(cp1))

	// the refusal vocabulary holds at width: a duplicate list and a
	// stop-check that fires at once
	dup := []gloaming.Doc_Id{1, 1}
	_, derr := gloaming.corpus_freq(store, dup, gloaming.Freq_Filter{}, a, nil, nil, 4)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Duplicate))
	_, _, qerr := gloaming.corpus_cooc(store, dup, copts, a, nil, nil, 4)
	testing.expect_value(t, int(qerr), int(gloaming.Store_Err.Duplicate))
	fire := proc(_: rawptr) -> bool { return true }
	_, ierr := gloaming.corpus_freq(store, docs, gloaming.Freq_Filter{}, a, fire, nil, 4)
	testing.expect_value(t, int(ierr), int(gloaming.Store_Err.Interrupted))
	_, _, ioerr := gloaming.corpus_cooc(store, docs, copts, a, fire, nil, 4)
	testing.expect_value(t, int(ioerr), int(gloaming.Store_Err.Interrupted))
	_, perr := gloaming.doc_profiles(store, docs, gloaming.Freq_Filter{}, a, fire, nil, 4)
	testing.expect_value(t, int(perr), int(gloaming.Store_Err.Interrupted))
	_, merr := gloaming.doc_matrix(p1, keys[:], f1, .Tf_Idf, a, fire, nil, 4)
	testing.expect_value(t, int(merr), int(gloaming.Freq_Err.Interrupted))
}

@(test)
corpus_fanout_owns_its_scratch :: proc(t: ^testing.T) {
	// inputs on the plain arena — the store's allocations stay
	// invisible to the tracker; only the call's own work is measured
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	store, serr := gloaming.store_memory(a)
	if !testing.expectf(t, serr == .None, "store_memory: %v", serr) { return }
	text1, toks1, segs1 := disk_test_doc(a)
	text3, toks3, segs3 := conc_doc3(a)
	if aer := store.add_document(store.ctx, 1, text1, toks1, segs1); aer != .None {
		testing.expectf(t, false, "add 1: %v", aer)
		return
	}
	if aer := store.add_document(store.ctx, 3, text3, toks3, segs3); aer != .None {
		testing.expectf(t, false, "add 3: %v", aer)
		return
	}
	docs := []gloaming.Doc_Id{1, 3}

	trk: mem.Tracking_Allocator
	mem.tracking_allocator_init(&trk, context.allocator)
	defer mem.tracking_allocator_destroy(&trk)
	ta := mem.tracking_allocator(&trk)

	// corpus_freq at width 4 on the tracked allocator: freeing the
	// rows and their key strings (clones at width — the merge owns
	// them) leaves the tracker at zero; the lanes' arenas, the
	// per-doc scratch, and the merge tables all died inside the call
	entries, err := gloaming.corpus_freq(store, docs, gloaming.Freq_Filter{}, ta, nil, nil, 4)
	if !testing.expectf(t, err == .None, "freq w4: %v", err) { return }
	for e in entries {
		mem.free(raw_data(transmute([]u8)e.lemma), ta)
	}
	if len(entries) > 0 { mem.free(raw_data(entries), ta) }

	// corpus_cooc at width 4, same discipline
	copts := gloaming.Cooc_Options{unit = .Segments, window = 0, max_pairs = 0}
	pairs, _, perr := gloaming.corpus_cooc(store, docs, copts, ta, nil, nil, 4)
	if !testing.expectf(t, perr == .None, "cooc w4: %v", perr) { return }
	for p in pairs {
		mem.free(raw_data(transmute([]u8)p.a), ta)
		mem.free(raw_data(transmute([]u8)p.b), ta)
	}
	if len(pairs) > 0 { mem.free(raw_data(pairs), ta) }

	// doc_profiles at width 4: the materialized profiles are the
	// outputs — rows, key arrays, key bytes, count arrays
	profs, derr := gloaming.doc_profiles(store, docs, gloaming.Freq_Filter{}, ta, nil, nil, 4)
	if !testing.expectf(t, derr == .None, "profiles w4: %v", derr) { return }
	for p in profs {
		for k in p.keys {
			mem.free(raw_data(transmute([]u8)k), ta)
		}
		if len(p.keys) > 0 { mem.free(raw_data(p.keys), ta) }
		if len(p.counts) > 0 { mem.free(raw_data(p.counts), ta) }
	}
	if len(profs) > 0 { mem.free(raw_data(profs), ta) }

	testing.expectf(t, trk.current_memory_allocated == 0,
		"live bytes after freeing the width-4 outputs: %d", trk.current_memory_allocated)
}

// ---- the dense-matrix fan-outs: identity, refusals, ownership ----

coords_equal :: proc(x, y: []gloaming.Coord) -> bool {
	if len(x) != len(y) { return false }
	for c, i in x {
		if transmute(u64)c.x != transmute(u64)y[i].x { return false }
		if transmute(u64)c.y != transmute(u64)y[i].y { return false }
	}
	return true
}

@(test)
matrix_fanout_identity :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, matrix_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// k at the coords dial's engaging width so every fan path runs:
	// the pair loop and the per-iteration matvec
	k := 512
	w := make([]f64, k * k, a)
	for i in 0..<k {
		for j in i + 1..<k {
			v := f64(((i * 31 + j * 57) % 97) + 1)
			w[i * k + j] = v
			w[j * k + i] = v
		}
	}

	// weight_distance: every pair cell computed by the same kernel in
	// the same j order whatever lane owns it — bit-equal, not close
	d1, derr1 := gloaming.weight_distance(w, k, .Cosine, a)
	if !testing.expectf(t, derr1 == .None, "weight_distance w1: %v", derr1) { return }
	d4, derr4 := gloaming.weight_distance(w, k, .Cosine, a, 4)
	if !testing.expectf(t, derr4 == .None, "weight_distance w4: %v", derr4) { return }
	testing.expect(t, f64_bits_equal(d1, d4), "weight_distance cells differ across widths")

	// power_coords at the engaging width: iterates bit-identical at
	// every step, so the axes are too
	c1, cerr1 := gloaming.power_coords(w, k, 1e-12, 32, a)
	if !testing.expectf(t, cerr1 == .None, "power_coords w1: %v", cerr1) { return }
	c4, cerr4 := gloaming.power_coords(w, k, 1e-12, 32, a, nil, nil, 4)
	if !testing.expectf(t, cerr4 == .None, "power_coords w4: %v", cerr4) { return }
	testing.expect(t, coords_equal(c1, c4), "power_coords axes differ across widths")

	// the refusal vocabulary holds at width: a stop-check that fires
	// at once answers Interrupted, the serial run's rule
	fire := proc(_: rawptr) -> bool { return true }
	_, perr := gloaming.power_coords(w, k, 1e-12, 32, a, fire, nil, 4)
	testing.expect_value(t, int(perr), int(gloaming.Freq_Err.Interrupted))
}

@(test)
matrix_fanout_owns_its_scratch :: proc(t: ^testing.T) {
	// inputs on the plain arena — the tracker sees only the call's work
	arena: mem.Arena
	mem.arena_init(&arena, matrix_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	k := 512 // the coords dial's engaging width
	w := make([]f64, k * k, a)
	for i in 0..<k {
		for j in i + 1..<k {
			v := f64(((i * 31 + j * 57) % 97) + 1)
			w[i * k + j] = v
			w[j * k + i] = v
		}
	}

	trk: mem.Tracking_Allocator
	mem.tracking_allocator_init(&trk, context.allocator)
	defer mem.tracking_allocator_destroy(&trk)
	ta := mem.tracking_allocator(&trk)

	// weight_distance at width 4: the pair lanes touch no allocation,
	// so freeing the matrix is the whole contract
	d, derr := gloaming.weight_distance(w, k, .Cosine, ta, 4)
	if !testing.expectf(t, derr == .None, "weight_distance w4: %v", derr) { return }
	if len(d) > 0 { mem.free(raw_data(d), ta) }

	// power_coords at width 4: the per-iteration fan allocations
	// return before the next iteration, the axis buffers before the
	// call — the coordinates are the only output
	coords, cerr := gloaming.power_coords(w, k, 1e-12, 8, ta, nil, nil, 4)
	if !testing.expectf(t, cerr == .None, "power_coords w4: %v", cerr) { return }
	if len(coords) > 0 { mem.free(raw_data(coords), ta) }

	testing.expectf(t, trk.current_memory_allocated == 0,
		"live bytes after freeing the width-4 outputs: %d", trk.current_memory_allocated)
}

// ---- the caller-lane fallback: lane 0 dead, no thread started ----

/*
A forwarding allocator that refuses exactly the first mv.Arena-sized
allocation and passes everything else through. The lane structs are
the only mv.Arena-sized allocations on the caller's allocator before
any spawn — a small map make issues none, and the bookkeeping slices
have other sizes — so the refusal is the caller lane's arena while
every later lane's succeeds: the one state whose fallback return must
leave no worker running.
*/
Fail_First_Arena :: struct {
	back:    mem.Allocator,
	refused: bool,
}

fail_first_alloc :: proc(data: rawptr, mode: mem.Allocator_Mode, size: int,
                         alignment: int, old_memory: rawptr, old_size: int,
                         loc: runtime.Source_Code_Location) -> ([]u8, mem.Allocator_Error) {
	f := cast(^Fail_First_Arena)data
	if mode == .Alloc && !f.refused && size == size_of(mv.Arena) {
		f.refused = true
		return nil, .Out_Of_Memory
	}
	return f.back.procedure(f.back.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
corpus_fanout_caller_lane_fallback :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	store, serr := gloaming.store_memory(a)
	if !testing.expectf(t, serr == .None, "store_memory: %v", serr) { return }
	text1, toks1, segs1 := disk_test_doc(a)
	doc2 := make([]gloaming.Token, 1, a)
	doc2[0] = toks1[1]
	doc2[0].start = 0
	doc2[0].end = 3
	segs2 := make([]gloaming.Segment, 1, a)
	segs2[0] = {kind = .Chapter, span = {doc = 2, start = 0, end = 3}}
	text3, toks3, segs3 := conc_doc3(a)
	if aer := store.add_document(store.ctx, 1, text1, toks1, segs1); aer != .None {
		testing.expectf(t, false, "add 1: %v", aer)
		return
	}
	if aer := store.add_document(store.ctx, 2, "が", doc2, segs2); aer != .None {
		testing.expectf(t, false, "add 2: %v", aer)
		return
	}
	if aer := store.add_document(store.ctx, 3, text3, toks3, segs3); aer != .None {
		testing.expectf(t, false, "add 3: %v", aer)
		return
	}
	docs := []gloaming.Doc_Id{1, 2, 3}

	// the serial references
	rc, rn, rerr := gloaming.corpus_count_maps(store, docs, gloaming.Freq_Filter{}, a)
	if !testing.expectf(t, rerr == .None, "serial counts: %v", rerr) { return }
	rp, rperr := gloaming.doc_profiles(store, docs, gloaming.Freq_Filter{}, a)
	if !testing.expectf(t, rperr == .None, "serial profiles: %v", rperr) { return }
	copts := gloaming.Cooc_Options{unit = .Segments, window = 0, max_pairs = 0}
	ro, rcap, roerr := gloaming.corpus_cooc(store, docs, copts, a)
	if !testing.expectf(t, roerr == .None, "serial cooc: %v", roerr) { return }

	// one fail-first allocator per call: the caller lane's arena is
	// the refusal, the fallback runs the serial body on the same
	// allocator (now passing), and every output row must match
	fc := Fail_First_Arena{back = a}
	fca := mem.Allocator{data = &fc, procedure = fail_first_alloc}
	gc, gn, gerr := gloaming.corpus_count_maps(store, docs, gloaming.Freq_Filter{}, fca, nil, nil, 4)
	if !testing.expectf(t, gerr == .None, "fallback counts: %v", gerr) { return }
	if !testing.expectf(t, len(gc) == len(rc), "fallback counts rows: %d vs %d",
		len(gc), len(rc)) { return }
	for k, n in rc {
		hn, ok := gc[k]
		if !testing.expectf(t, ok && hn == n && gn[k] == rn[k],
			"fallback count row %s", k) { return }
	}

	fp := Fail_First_Arena{back = a}
	fpa := mem.Allocator{data = &fp, procedure = fail_first_alloc}
	gp, gperr := gloaming.doc_profiles(store, docs, gloaming.Freq_Filter{}, fpa, nil, nil, 4)
	if !testing.expectf(t, gperr == .None, "fallback profiles: %v", gperr) { return }
	testing.expect(t, profiles_equal(rp, gp),
		"fallback profiles differ from the serial reference")

	fo := Fail_First_Arena{back = a}
	foa := mem.Allocator{data = &fo, procedure = fail_first_alloc}
	gpairs, gcapped, gcerr := gloaming.corpus_cooc(store, docs, copts, foa, nil, nil, 4)
	if !testing.expectf(t, gcerr == .None, "fallback cooc: %v", gcerr) { return }
	testing.expect(t, pairs_equal(ro, gpairs),
		"fallback cooc pairs differ from the serial reference")
	testing.expect_value(t, int(gcapped), int(rcap))

	// every refusal was spent — each call actually met its dead lane
	testing.expect(t, fc.refused && fp.refused && fo.refused,
		"a fail-first allocator never refused")
}
