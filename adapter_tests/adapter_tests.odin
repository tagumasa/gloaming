package moli_adapter_test

/*
The adapter's own tests. The dictionary is moli's
committed fixture lexicon plus its committed unknown-rule resources —
referenced by path, never copied, so nothing licensed enters this
repo. What must hold for EVERY dictionary is proven here.

Same discipline as tests/: one arena per test, nothing allocates from
context allocators, verdicts from the log. Paths are relative to the
repository root (the justfile recipes' working directory).
*/

import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import gl "gloaming:gloaming"
import moli "moli:moli"
import ma "gladapter:moli_adapter"

FIX_LEX :: "vendor/moli/tests/fixtures/ipadic_sample.csv"
FIX_UNK :: "vendor/moli/tests/fixtures/resources/unk.def"
FIX_CHAR :: "vendor/moli/tests/fixtures/resources/char.def"
FIX_MATRIX :: "vendor/moli/tests/fixtures/resources/matrix.def"
FIX_QPAT :: "vendor/moli/tests/fixtures/resources/patterns.qpat"

// shared arena backing buffer: package scope keeps it off the test
// stacks (a 1 MiB local warns); the serial runner means no test sees
// another's arena. 4 MiB: moli retains a 128 KiB BMP char table per
// analyzer and pulls transient build scratch (256 KiB per load or
// merge) through the same allocator, and the heaviest tests hold
// three analyzers plus two merges in one arena.
test_arena_buf: [1 << 22]u8

fixture_options :: proc() -> moli.Load_Options {
	return {
		unk_def_path    = FIX_UNK,
		char_def_path   = FIX_CHAR,
		matrix_def_path = FIX_MATRIX,
		qpat_path       = FIX_QPAT,
	}
}

find_by_surface :: proc(toks: []gl.Token, surface: string) -> (gl.Token, bool) {
	for t in toks {
		if t.surface == surface { return t, true }
	}
	return {}, false
}

// strings.clone into the arena — the golden snapshot the store
// round-trip compares against after the analyzer and source die
snapshot_tokens :: proc(toks: []gl.Token, a: mem.Allocator) -> []gl.Token {
	out := make([]gl.Token, len(toks), a)
	for t, i in toks {
		out[i] = {
			surface    = strings.clone(t.surface, a),
			lemma      = strings.clone(t.lemma, a),
			pos        = strings.clone(t.pos, a),
			reading    = strings.clone(t.reading, a),
			start      = t.start,
			end        = t.end,
			kind       = t.kind,
			cost       = t.cost,
			entry_id   = t.entry_id,
		}
	}
	return out
}

@(test)
adapter_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	an, lerr := moli.load(.Japanese, FIX_LEX, fixture_options(), a)
	if !testing.expectf(t, lerr == nil, "fixture load: %v", lerr) { return }
	defer moli.free(&an)

	// the text lives in a buffer the test owns and scribbles later
	text := "わたしがシンボルをみる"
	buf := make([]u8, len(text), a)
	copy(buf, text)
	s := string(buf)

	toks: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 16, a)
	terr := ma.tokenize_document(&an, s, {}, 0, &toks, a)
	if !testing.expectf(t, terr == nil, "tokenize_document: %v", terr) { return }

	// deterministic fixture tokenization: known, known,
	// katakana-unknown, hiragana-unknown — the ladder's two shapes,
	// including grouping (を is out-of-lexicon, so the unknown run
	// swallows even the in-lexicon みる into one morpheme)
	wants := [4]string{"わたし", "が", "シンボル", "をみる"}
	if !testing.expect_value(t, len(toks), len(wants)) { return }
	for tk, i in toks {
		testing.expectf(t, tk.surface == wants[i], "token %d surface %q, want %q",
			i, tk.surface, wants[i])
	}

	// C1: surface == text[start:end] — the borrowed-view contract
	// C2: monotone, non-overlapping
	c1, c2 := 0, 0
	prev_end := -1
	for tk in toks {
		if s[tk.start:tk.end] != tk.surface { c1 += 1 }
		if tk.start < prev_end { c2 += 1 }
		prev_end = tk.end
	}
	testing.expect_value(t, c1, 0)
	testing.expect_value(t, c2, 0)

	// known word: field copy straight through
	w, ok := find_by_surface(toks[:], "わたし")
	if testing.expect(t, ok, "わたし missing") {
		testing.expect_value(t, w.lemma, "わたし")
		testing.expect_value(t, w.pos, "名詞,代名詞,一般")
		testing.expect_value(t, w.reading, "ワタシ")
		testing.expect_value(t, int(w.kind), int(gl.Token_Kind.Dictionary))
		testing.expectf(t, w.entry_id >= 0, "わたし entry_id %d, want >= 0", w.entry_id)
		// the id resolves back to its dictionary row — the GLB1
		// entry_ref read path. Entry_Info.lemma is the raw entry value
		// (the "*"→surface fallback is a Morpheme rule); this fixture
		// row carries わたし verbatim, so raw == adapted here
		info, iok, ierr := moli.entry_info(&an, w.entry_id)
		if testing.expectf(t, ierr == nil, "entry_info: %v", ierr) &&
		   testing.expect(t, iok, "entry_info: id out of range") {
			testing.expect_value(t, info.pos, w.pos)
			testing.expect_value(t, info.reading, w.reading)
			testing.expect_value(t, info.lemma, w.lemma)
		}
	}
	// unknown word: surface as lemma, "*" reading — moli's guarantee,
	// the freq contract's unknown-token rule rides on it
	u, uok := find_by_surface(toks[:], "シンボル")
	if testing.expect(t, uok, "シンボル missing") {
		testing.expect_value(t, int(u.kind), int(gl.Token_Kind.Unknown))
		testing.expect_value(t, u.lemma, "シンボル")
		testing.expect_value(t, u.reading, "*")
		testing.expect_value(t, u.entry_id, i32(-1))
	}
	// the grouped hiragana unknown carries the same guarantee
	u2, u2ok := find_by_surface(toks[:], "をみる")
	if testing.expect(t, u2ok, "をみる missing") {
		testing.expect_value(t, int(u2.kind), int(gl.Token_Kind.Unknown))
		testing.expect_value(t, u2.lemma, "をみる")
		testing.expect_value(t, u2.reading, "*")
		testing.expect_value(t, u2.entry_id, i32(-1))
	}

	// the full ingestion path: store add, then BOTH owners die —
	// analyzer (dictionary views) and source text (surface views) —
	// and every stored field must still read back
	segs: [dynamic]gl.Segment = make([dynamic]gl.Segment, 0, 4, a)
	ma.markdown_segments(s, 0, gl.Doc_Id(3), &segs)

	store, serr := gl.store_memory(a)
	if !testing.expectf(t, serr == gl.Store_Err.None, "store_memory: %v", serr) { return }
	aerr := store.add_document(store.ctx, gl.Doc_Id(3), s, toks[:], segs[:])
	testing.expect_value(t, int(aerr), int(gl.Store_Err.None))

	golden := snapshot_tokens(toks[:], a)
	moli.free(&an)
	for i in 0..<len(buf) { buf[i] = '#' }

	got, gerr := store.tokens(store.ctx, gl.Doc_Id(3), a)
	if !testing.expectf(t, gerr == gl.Store_Err.None, "store read: %v", gerr) { return }
	testing.expect_value(t, len(got), len(golden))
	for g, i in got {
		testing.expectf(t, g.surface == golden[i].surface, "token %d surface %q, want %q",
			i, g.surface, golden[i].surface)
		testing.expectf(t, g.lemma == golden[i].lemma, "token %d lemma %q, want %q",
			i, g.lemma, golden[i].lemma)
		testing.expectf(t, g.pos == golden[i].pos, "token %d pos %q, want %q",
			i, g.pos, golden[i].pos)
		testing.expectf(t, g.reading == golden[i].reading, "token %d reading %q, want %q",
			i, g.reading, golden[i].reading)
		testing.expect_value(t, g.kind == golden[i].kind, true)
		testing.expect_value(t, g.cost, golden[i].cost)
		testing.expect_value(t, g.entry_id, golden[i].entry_id)
	}
	gsegs, gserr := store.segments(store.ctx, gl.Doc_Id(3), a)
	if testing.expectf(t, gserr == gl.Store_Err.None, "store segments: %v", gserr) {
		testing.expect_value(t, len(gsegs), 1) // no newline: one whole-text paragraph
	}
}

@(test)
markdown_segments_spans :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	out: [dynamic]gl.Segment = make([dynamic]gl.Segment, 0, 8, a)
	defer delete(out)

	// hand-computed byte offsets (a heading line opens
	// the paragraph that follows it, chapters close at the next
	// chapter):
	//   "# 一章\n"      [0,8)   heading — starts paragraph 0
	//   "本文。\n"      [9,18)
	//   "\n"            [19,19) blank — closes paragraph 0
	//   "続き。\n"      [20,29) paragraph
	//   "# 二章\n"      [30,38) heading — closes paragraph, starts one
	//   "後書き。"      [39,51)
	ma.markdown_segments("# 一章\n本文。\n\n続き。\n# 二章\n後書き。", 0, gl.Doc_Id(7), &out)

	want := [5]gl.Segment{
		{kind = .Chapter,   span = {doc = gl.Doc_Id(7), start = 0,  end = 30}},
		{kind = .Paragraph, span = {doc = gl.Doc_Id(7), start = 0,  end = 19}},
		{kind = .Paragraph, span = {doc = gl.Doc_Id(7), start = 20, end = 30}},
		{kind = .Chapter,   span = {doc = gl.Doc_Id(7), start = 30, end = 51}},
		{kind = .Paragraph, span = {doc = gl.Doc_Id(7), start = 30, end = 51}},
	}
	if !testing.expect_value(t, len(out), len(want)) { return }
	for s, i in out {
		testing.expectf(t, s.kind == want[i].kind, "segment %d kind %v, want %v",
			i, s.kind, want[i].kind)
		testing.expectf(t, s.span.start == want[i].span.start && s.span.end == want[i].span.end,
			"segment %d span [%d,%d), want [%d,%d)",
			i, s.span.start, s.span.end, want[i].span.start, want[i].span.end)
		testing.expectf(t, u32(s.span.doc) == 7, "segment %d doc %d, want 7", i, u32(s.span.doc))
	}

	// second document into the same out: base rebasing stamps in, and
	// the chapter-closing patch must not touch the first document's
	// chapters (the this-call range guard)
	ma.markdown_segments("# 三章\n本文。\n", 100, gl.Doc_Id(8), &out)
	if !testing.expect_value(t, len(out), len(want) + 2) { return }
	testing.expectf(t, out[5].kind == .Chapter &&
		out[5].span.start == 100 && out[5].span.end == 119 &&
		u32(out[5].span.doc) == 8,
		"doc-2 chapter %+v, want Chapter [100,119) doc 8", out[5])
	testing.expectf(t, out[6].kind == .Paragraph &&
		out[6].span.start == 100 && out[6].span.end == 119 &&
		u32(out[6].span.doc) == 8,
		"doc-2 paragraph %+v, want Paragraph [100,119) doc 8", out[6])
	testing.expectf(t, out[0].span.end == 30,
		"doc-1 chapter re-patched across documents: end %d, want 30", out[0].span.end)
}

@(test)
qdct_roundtrip :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	qdct := "tmp/adapter_fixture.qdct"
	_ = os.remove(qdct) // start clean: force the CSV import path
	defer _ = os.remove(qdct)

	// first load_analyzer imports the CSV and writes the snapshot
	an1, lerr1 := ma.load_analyzer(qdct, FIX_LEX, .Japanese, fixture_options(), a)
	if !testing.expectf(t, lerr1 == nil, "first load_analyzer: %v", lerr1) { return }
	defer moli.free(&an1)
	if !testing.expect(t, os.exists(qdct), "snapshot not written") { return }

	text := "わたしがシンボルをみる"
	toks1: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 16, a)
	if terr := ma.tokenize_document(&an1, text, {}, 0, &toks1, a); terr != nil {
		testing.expectf(t, false, "tokenize (imported): %v", terr)
		return
	}

	// second load_analyzer restores the snapshot — the recommended
	// startup path; tokenization must be identical
	an2, lerr2 := ma.load_analyzer(qdct, FIX_LEX, .Japanese, fixture_options(), a)
	if !testing.expectf(t, lerr2 == nil, "second load_analyzer: %v", lerr2) { return }
	defer moli.free(&an2)
	toks2: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 16, a)
	if terr := ma.tokenize_document(&an2, text, {}, 0, &toks2, a); terr != nil {
		testing.expectf(t, false, "tokenize (restored): %v", terr)
		return
	}

	if !testing.expect_value(t, len(toks2), len(toks1)) { return }
	for t1, i in toks1 {
		testing.expectf(t, t1.surface == toks2[i].surface &&
			t1.lemma == toks2[i].lemma &&
			t1.pos == toks2[i].pos &&
			t1.reading == toks2[i].reading &&
			t1.start == toks2[i].start &&
			t1.end == toks2[i].end &&
			t1.kind == toks2[i].kind &&
			t1.cost == toks2[i].cost &&
			t1.entry_id == toks2[i].entry_id,
			"token %d differs across import/restore: %+v vs %+v", i, t1, toks2[i])
	}

	// entries_hash is load-path independent: the restored analyzer
	// hashes equal to the import that built the snapshot — the
	// dictionary_hash contract across the two load paths, and the
	// Payload_Key.dict_version footing
	h1, he1 := ma.dictionary_hash(&an1)
	h2, he2 := ma.dictionary_hash(&an2)
	if testing.expectf(t, he1 == nil, "hash (imported): %v", he1) &&
	   testing.expectf(t, he2 == nil, "hash (restored): %v", he2) {
		testing.expect_value(t, h2, h1)
	}
}

@(test)
dictionary_hash_and_variants :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	an, lerr := moli.load(.Japanese, FIX_LEX, fixture_options(), a)
	if !testing.expectf(t, lerr == nil, "fixture load: %v", lerr) { return }
	defer moli.free(&an)

	// deterministic on one analyzer state
	h1, e1 := ma.dictionary_hash(&an)
	if !testing.expectf(t, e1 == nil, "dictionary_hash: %v", e1) { return }
	h2, e2 := ma.dictionary_hash(&an)
	if testing.expectf(t, e2 == nil, "dictionary_hash (again): %v", e2) {
		testing.expect_value(t, h2, h1)
	}

	// a fiction character name (花子) and 花見's id before any merge —
	// the entries are surface-sorted and 子 (U+5B50) sorts before 見
	// (U+898B), so the merge below inserts 花子 immediately before 花見
	hanako := []moli.User_Entry{
		{surface = "花子", left_id = 0, right_id = 0, cost = 4000,
			pos = "名詞,固有名詞,人名,名,*,*", lemma = "花子",
			reading = "ハナコ", reading_jyutping = "*"},
	}
	pre: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 4, a)
	defer delete(pre)
	if terr := ma.tokenize_document(&an, "花見", {}, 0, &pre, a); terr != nil {
		testing.expectf(t, false, "tokenize 花見: %v", terr)
		return
	}
	hanami_id := pre[0].entry_id
	if !testing.expectf(t, hanami_id >= 0, "花見 entry_id %d, want >= 0", hanami_id) {
		return
	}

	// a DIRECT merge changes the hash (the dict_version invalidation)
	// and renumbers the entries: 花子 slid into 花見's old index, so the
	// pre-merge id now resolves to 花子 — stale, exactly as the package
	// contract documents
	if uerr := moli.add_user_entries(&an, hanako);
	   testing.expectf(t, uerr == nil, "add_user_entries: %v", uerr) {
		hm, hem := ma.dictionary_hash(&an)
		if testing.expectf(t, hem == nil, "dictionary_hash (merged): %v", hem) {
			testing.expectf(t, hm != h1, "merge did not change the hash")
		}
		info, iok, ierr := moli.entry_info(&an, hanami_id)
		if testing.expectf(t, ierr == nil, "entry_info (merged): %v", ierr) &&
		   testing.expect(t, iok, "pre-merge id out of range after merge") {
			testing.expectf(t, info.surface == "花子",
				"stale id resolves to %q, want 花子 (renumbered one slot)", info.surface)
		}
	}

	// variant_analyzer: clone-then-merge — the base keeps its hash and
	// ids; the variant knows 花子 because it merged before any
	// tokenization (the no-stale-id shape)
	base, blerr := moli.load(.Japanese, FIX_LEX, fixture_options(), a)
	if !testing.expectf(t, blerr == nil, "fixture reload: %v", blerr) { return }
	defer moli.free(&base)
	hb, hbe := ma.dictionary_hash(&base)
	if !testing.expectf(t, hbe == nil, "dictionary_hash (base): %v", hbe) { return }
	testing.expect_value(t, hb, h1) // two independent CSV loads, same content — same hash

	variant, cerr, uverr := ma.variant_analyzer(&base, hanako, a)
	if testing.expectf(t, cerr == nil, "variant clone: %v", cerr) &&
	   testing.expectf(t, uverr == nil, "variant merge: %v", uverr) {
		defer moli.free(&variant)
		hv, hve := ma.dictionary_hash(&variant)
		if testing.expectf(t, hve == nil, "dictionary_hash (variant): %v", hve) {
			testing.expectf(t, hv != hb, "variant hash equals its base")
		}
		hb2, hb2e := ma.dictionary_hash(&base)
		if testing.expectf(t, hb2e == nil, "dictionary_hash (base again): %v", hb2e) {
			testing.expect_value(t, hb2, hb) // the variant's merge never touched the base
		}

		// on the variant 花子 is a dictionary word with a fresh id…
		vt: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 8, a)
		defer delete(vt)
		if terr := ma.tokenize_document(&variant, "花子がみる", {}, 0, &vt, a); terr != nil {
			testing.expectf(t, false, "tokenize on variant: %v", terr)
			return
		}
		hk, hkok := find_by_surface(vt[:], "花子")
		if testing.expect(t, hkok, "花子 missing on variant") {
			testing.expect_value(t, int(hk.kind), int(gl.Token_Kind.Dictionary))
			testing.expect_value(t, hk.reading, "ハナコ")
			testing.expectf(t, hk.entry_id >= 0, "花子 entry_id %d, want >= 0", hk.entry_id)
		}
		// …while the base alone still groups it as a kanji unknown
		bt: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 8, a)
		defer delete(bt)
		if terr := ma.tokenize_document(&base, "花子がみる", {}, 0, &bt, a); terr != nil {
			testing.expectf(t, false, "tokenize on base: %v", terr)
			return
		}
		bk, bkok := find_by_surface(bt[:], "花子")
		if testing.expect(t, bkok, "花子 missing on base") {
			testing.expect_value(t, int(bk.kind), int(gl.Token_Kind.Unknown))
			testing.expect_value(t, bk.entry_id, i32(-1))
		}
	}
}

/*
The GLB1 payload path: tokenize → encode → decode must
reproduce the token stream exactly — the differential-harness kernel
at fixture scale. Also the ownership absorption (decode + store, then
both owners die) and the stale-id hazard that Payload_Key.dict_version
exists to refuse.
*/
@(test)
payload_roundtrip :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	an, lerr := moli.load(.Japanese, FIX_LEX, fixture_options(), a)
	if !testing.expectf(t, lerr == nil, "fixture load: %v", lerr) { return }

	text := "わたしがシンボルをみる"
	buf := make([]u8, len(text), a)
	copy(buf, text)
	s := string(buf)

	toks: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 16, a)
	if terr := ma.tokenize_document(&an, s, {}, 0, &toks, a); terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}

	// the content address: text hash + the analyzer's entries_hash —
	// exactly what the host keys a payload with
	dv, dverr := ma.dictionary_hash(&an)
	if !testing.expectf(t, dverr == nil, "dictionary_hash: %v", dverr) { return }
	key := gl.Payload_Key{text_hash = hash.fnv64a(transmute([]u8)s), dict_version = dv, options = 0}

	blob, berr := gl.payload_encode(key, s, toks[:], a)
	if !testing.expectf(t, berr == gl.Store_Err.None, "payload_encode: %v", berr) { return }

	gk, gkerr := gl.payload_key(blob)
	if testing.expectf(t, gkerr == gl.Store_Err.None, "payload_key: %v", gkerr) {
		testing.expect_value(t, gk.text_hash, key.text_hash)
		testing.expect_value(t, gk.dict_version, dv)
	}

	// decode on the SAME analyzer state: byte-for-byte the same tokens,
	// including the two unknowns whose pos rides the tail in order
	dec, derr := ma.payload_tokens(&an, blob, s, a)
	if !testing.expectf(t, derr == gl.Store_Err.None, "payload_tokens: %v", derr) { return }
	if !testing.expect_value(t, len(dec), len(toks)) { return }
	for w, i in toks {
		d := dec[i]
		testing.expectf(t, d.surface == w.surface && d.lemma == w.lemma &&
			d.pos == w.pos && d.reading == w.reading &&
			d.start == w.start && d.end == w.end &&
			d.kind == w.kind && d.cost == w.cost &&
			d.entry_id == w.entry_id,
			"token %d differs after roundtrip: %+v vs %+v", i, d, w)
	}

	// the distribution wrapper at fixture scale: unwrapping is exact
	z, zerr := gl.payload_compress(blob, context.temp_allocator)
	if !testing.expectf(t, zerr == gl.Store_Err.None, "payload_compress: %v", zerr) { return }
	raw, rerr := gl.payload_decompress(z, a)
	if testing.expectf(t, rerr == gl.Store_Err.None, "payload_decompress: %v", rerr) {
		testing.expectf(t, string(raw) == string(blob), "unwrapped blob differs")
	}

	// the full ingestion path through DECODED tokens: store, then both
	// owners die (analyzer's dictionary views, text's surface views) —
	// the stored document must read back complete
	golden := snapshot_tokens(toks[:], a)
	segs := make([]gl.Segment, 0, a)
	store, serr := gl.store_memory(a)
	if !testing.expectf(t, serr == gl.Store_Err.None, "store_memory: %v", serr) { return }
	aerr := store.add_document(store.ctx, gl.Doc_Id(11), s, dec, segs)
	testing.expect_value(t, int(aerr), int(gl.Store_Err.None))
	moli.free(&an)
	for i in 0..<len(buf) { buf[i] = '#' }

	got, gerr := store.tokens(store.ctx, gl.Doc_Id(11), a)
	if !testing.expectf(t, gerr == gl.Store_Err.None, "store read: %v", gerr) { return }
	if !testing.expect_value(t, len(got), len(golden)) { return }
	for g, i in got {
		testing.expectf(t, g.surface == golden[i].surface && g.lemma == golden[i].lemma &&
			g.pos == golden[i].pos && g.reading == golden[i].reading &&
			g.cost == golden[i].cost && g.entry_id == golden[i].entry_id,
			"stored token %d differs after owner death: %+v vs %+v", i, g, golden[i])
	}

	// the stale-id hazard, deliberately triggered: a payload encoded
	// against the base dictionary, decoded against a merged one. The
	// ids resolve SILENTLY to the wrong rows (花見's slot now holds
	// 花子) — which is why the host refuses first when
	// payload_key(blob).dict_version != dictionary_hash(analyzer)
	base, blerr := moli.load(.Japanese, FIX_LEX, fixture_options(), a)
	if !testing.expectf(t, blerr == nil, "base load: %v", blerr) { return }
	defer moli.free(&base)
	htoks: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 4, a)
	defer delete(htoks)
	if terr := ma.tokenize_document(&base, "花見", {}, 0, &htoks, a); terr != nil {
		testing.expectf(t, false, "tokenize 花見: %v", terr)
		return
	}
	bdv, bdverr := ma.dictionary_hash(&base)
	if !testing.expectf(t, bdverr == nil, "dictionary_hash (base): %v", bdverr) { return }
	htext := "花見"
	hblob, hberr := gl.payload_encode(
		{text_hash = hash.fnv64a(transmute([]u8)htext), dict_version = bdv, options = 0},
		htext, htoks[:], a)
	if !testing.expectf(t, hberr == gl.Store_Err.None, "payload_encode (花見): %v", hberr) {
		return
	}

	merged, merr2 := moli.load(.Japanese, FIX_LEX, fixture_options(), a)
	if !testing.expectf(t, merr2 == nil, "merged load: %v", merr2) { return }
	defer moli.free(&merged)
	hanako := []moli.User_Entry{
		{surface = "花子", left_id = 0, right_id = 0, cost = 4000,
			pos = "名詞,固有名詞,人名,名,*,*", lemma = "花子",
			reading = "ハナコ", reading_jyutping = "*"},
	}
	if uerr2 := moli.add_user_entries(&merged, hanako); uerr2 != nil {
		testing.expectf(t, false, "add_user_entries: %v", uerr2)
		return
	}
	wrong, werr := ma.payload_tokens(&merged, hblob, "花見", a)
	if testing.expectf(t, werr == gl.Store_Err.None, "decode against merged: %v", werr) {
		testing.expectf(t, wrong[0].lemma == "花子",
			"stale id resolved to %q, want the silently-wrong 花子", wrong[0].lemma)
	}
	mv, mverr := ma.dictionary_hash(&merged)
	if testing.expectf(t, mverr == nil, "dictionary_hash (merged): %v", mverr) {
		hk, hkerr := gl.payload_key(hblob)
		if testing.expectf(t, hkerr == gl.Store_Err.None, "payload_key (花見): %v", hkerr) {
			testing.expectf(t, hk.dict_version != mv,
				"merged hash equals the payload's key — refusal impossible")
		}
	}
}
