package gloaming_test

// The glexport row emitters (src/glexport/rows.odin): exact-string
// goldens — the JSON shapes are the CLI/GUI-facing contract, so
// byte-for-byte is the assertion. Same arena discipline as the query
// goldens: one shared package-scope buffer, nothing on context
// allocators.

import "core:math"
import "core:mem"
import "core:testing"

import gloaming "gloaming:gloaming"
import glexport "gloaming:glexport"

@(test)
envelope_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	got := glexport.envelope_json("freq", 0xa7a6b8263474367a, "", false, "[]", a)
	want := "{\"command\":\"freq\",\"dict\":\"a7a6b8263474367a\",\"variant\":null,\"truncated\":false,\"rows\":[]}\n"
	testing.expectf(t, got == want, "base:\n got %s\nwant %s", got, want)

	got = glexport.envelope_json("query", 0, "names", true, "[{\"x\":1}]", a)
	want = "{\"command\":\"query\",\"dict\":\"0000000000000000\",\"variant\":\"names\",\"truncated\":true,\"rows\":[{\"x\":1}]}\n"
	testing.expectf(t, got == want, "variant+truncated:\n got %s\nwant %s", got, want)
}

// a two-group table the cross goldens share: 中間 is the row the
// occurrence floor will drop, so the row-selection paths have a row
// to lose (file scope, so the slice literals are static storage)
CROSS_GOLDEN :: gloaming.Cross_Table{
	vals  = []string{"前半", "後半"},
	sizes = []int{2, 3},
	keys  = []string{"花子", "中間", "さん"},
	cells = []int{3, 1, 0, 0, 2, 4},
	docs  = []int{2, 1, 0, 0, 1, 3},
}

@(test)
keyness_rows_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	rows := []gloaming.Key_Entry{
		{key = "寶玉", value = 12.5, a = 40, b = 60, c = 2, d = 98},
		{key = "lift", value = math.INF_F64, a = 3, b = 0, c = 0, d = 5},
		{key = "avoid", value = -0.125, a = 1, b = 9, c = 9, d = 1},
	}
	got := glexport.keyness_rows_json(rows, a)
	want := "[{\"key\":\"寶玉\",\"value\":12.500000,\"a\":40,\"b\":60,\"c\":2,\"d\":98},{\"key\":\"lift\",\"value\":null,\"a\":3,\"b\":0,\"c\":0,\"d\":5},{\"key\":\"avoid\",\"value\":-0.125000,\"a\":1,\"b\":9,\"c\":9,\"d\":1}]"
	testing.expectf(t, got == want, "keyness:\n got %s\nwant %s", got, want)
	testing.expectf(t, glexport.keyness_rows_json(nil, a) == "[]", "keyness empty")
}

@(test)
cross_rows_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	table := CROSS_GOLDEN
	// two tests for three keys: 中間's absence-everywhere row is the
	// one cross_chi2 would skip, so the pairing must survive both the
	// skip and the floor dropping the same row
	tests := []gloaming.Cross_Test{
		{key = "花子", chi2 = 4.25, residuals = []f64{1.5, -0.5}},
		{key = "さん", chi2 = 0.5, residuals = []f64{-0.25, 0.25}},
	}
	got, kept := glexport.cross_rows_json(&table, tests, true, 0, 1, a)
	want := "[{\"key\":\"花子\",\"cells\":[3,1],\"docs\":[2,1],\"chi2\":4.250000,\"residuals\":[1.500000,-0.500000]},{\"key\":\"さん\",\"cells\":[2,4],\"docs\":[1,3],\"chi2\":0.500000,\"residuals\":[-0.250000,0.250000]}]"
	testing.expectf(t, got == want, "tests+floor:\n got %s\nwant %s", got, want)
	testing.expect_value(t, kept, 2)

	// no tests asked: the statistic fields are absent, floor still drops
	got, kept = glexport.cross_rows_json(&table, nil, false, 0, 1, a)
	want = "[{\"key\":\"花子\",\"cells\":[3,1],\"docs\":[2,1]},{\"key\":\"さん\",\"cells\":[2,4],\"docs\":[1,3]}]"
	testing.expectf(t, got == want, "no tests:\n got %s\nwant %s", got, want)
	testing.expect_value(t, kept, 2)

	// top slices after the floor; kept counts past the cut
	got, kept = glexport.cross_rows_json(&table, nil, false, 1, 0, a)
	want = "[{\"key\":\"花子\",\"cells\":[3,1],\"docs\":[2,1]}]"
	testing.expectf(t, got == want, "top:\n got %s\nwant %s", got, want)
	testing.expect_value(t, kept, 3)
}

@(test)
cross_header_and_extra_envelope_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	table := CROSS_GOLDEN
	got := glexport.cross_header_json(&table, "部", 12.5, true, a)
	want := "\"attr\":\"部\",\"columns\":[\"前半\",\"後半\"],\"sizes\":[2,3],\"table_chi2\":12.500000,"
	testing.expectf(t, got == want, "header+stat:\n got %s\nwant %s", got, want)

	got = glexport.cross_header_json(&table, "部", 0, false, a)
	want = "\"attr\":\"部\",\"columns\":[\"前半\",\"後半\"],\"sizes\":[2,3],"
	testing.expectf(t, got == want, "header:\n got %s\nwant %s", got, want)

	// the fragment splices between truncated and rows
	got = glexport.envelope_json("crosstab", 0x83dd02da8715e4c3, "", false, "[]", a,
		glexport.cross_header_json(&table, "部", 12.5, true, a))
	want = "{\"command\":\"crosstab\",\"dict\":\"83dd02da8715e4c3\",\"variant\":null,\"truncated\":false,\"attr\":\"部\",\"columns\":[\"前半\",\"後半\"],\"sizes\":[2,3],\"table_chi2\":12.500000,\"rows\":[]}\n"
	testing.expectf(t, got == want, "envelope extra:\n got %s\nwant %s", got, want)
}

@(test)
freq_cooc_rows_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	entries := []gloaming.Freq_Entry{
		{lemma = "花子", count = 3, docs = 1},
		{lemma = "さん", count = 2, docs = 1},
	}
	got := glexport.freq_rows_json(entries, a)
	want := "[{\"key\":\"花子\",\"count\":3,\"docs\":1},{\"key\":\"さん\",\"count\":2,\"docs\":1}]"
	testing.expectf(t, got == want, "freq:\n got %s\nwant %s", got, want)
	testing.expectf(t, glexport.freq_rows_json(nil, a) == "[]", "freq empty")

	pairs := []gloaming.Co_Pair{{a = "花子", b = "さん", n = 7}}
	got = glexport.cooc_rows_json(pairs, a)
	want = "[{\"a\":\"花子\",\"b\":\"さん\",\"n\":7}]"
	testing.expectf(t, got == want, "cooc:\n got %s\nwant %s", got, want)
}

// the cluster pipeline's rows: merge rows (ids under the tree's
// convention), word→cluster rows, and coordinate rows — plus the
// length-mismatch refusals
@(test)
cluster_rows_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	merges := []gloaming.Ward_Merge{
		{a = 0, b = 1, dist = 0.5, size = 2},
		{a = 2, b = 3, dist = 3.25, size = 3},
	}
	got := glexport.ward_rows_json(merges, a)
	want := "[{\"a\":0,\"b\":1,\"dist\":0.500000,\"size\":2},{\"a\":2,\"b\":3,\"dist\":3.250000,\"size\":3}]"
	testing.expectf(t, got == want, "ward rows:\n got %s\nwant %s", got, want)
	testing.expectf(t, glexport.ward_rows_json(nil, a) == "[]", "ward empty")

	keys := []string{"犬", "猫", "鳥"}
	labels := []int{0, 1, 1}
	got = glexport.cluster_rows_json(keys, labels, a)
	want = "[{\"key\":\"犬\",\"cluster\":0},{\"key\":\"猫\",\"cluster\":1},{\"key\":\"鳥\",\"cluster\":1}]"
	testing.expectf(t, got == want, "cluster rows:\n got %s\nwant %s", got, want)
	testing.expectf(t, glexport.cluster_rows_json(keys, labels[:1], a) == "",
		"cluster length mismatch refuses")

	coords := []gloaming.Coord{{x = 0.5, y = -1.25}, {x = 0, y = 0}, {x = 1e-9, y = 2}}
	got = glexport.coords_rows_json(keys, coords, a)
	want = "[{\"key\":\"犬\",\"x\":0.500000,\"y\":-1.250000},{\"key\":\"猫\",\"x\":0.000000,\"y\":0.000000},{\"key\":\"鳥\",\"x\":0.000000,\"y\":2.000000}]"
	testing.expectf(t, got == want, "coords rows:\n got %s\nwant %s", got, want)
	testing.expectf(t, glexport.coords_rows_json(keys, coords[:1], a) == "",
		"coords length mismatch refuses")
}

@(test)
topo_rows_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// two live rows, one dead: names resolve through the graph, and a
	// dead or out-of-range id renders "" — the row stays true
	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	kt := gloaming.graph_kind_intern(&g, "term")
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 0, live = true, kind = kt, name = "夜",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 1, live = true, kind = kt, name = "明け方",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 2, live = false, kind = gloaming.KIND_NONE, name = "墓碑",
	})

	order := []gloaming.Entity_Id{1, 0, 2, 7}
	got := glexport.topo_rows_json(order, &g, a)
	want := "[{\"rank\":0,\"id\":1,\"name\":\"明け方\"},{\"rank\":1,\"id\":0,\"name\":\"夜\"},{\"rank\":2,\"id\":2,\"name\":\"\"},{\"rank\":3,\"id\":7,\"name\":\"\"}]"
	testing.expectf(t, got == want, "topo rows:\n got %s\nwant %s", got, want)
	testing.expectf(t, glexport.topo_rows_json(nil, &g, a) == "[]", "topo empty")

	got = glexport.topo_cyclic_json([]gloaming.Entity_Id{0, 2}, &g, a)
	want = "\"cyclic\":[{\"id\":0,\"name\":\"夜\"},{\"id\":2,\"name\":\"\"}],"
	testing.expectf(t, got == want, "topo cyclic:\n got %s\nwant %s", got, want)

	// the fragment splices between truncated and rows; an empty
	// remainder keeps the key present — consumers do not branch on it
	got = glexport.envelope_json("toposort", 0x83dd02da8715e4c3, "", false, "[]", a,
		glexport.topo_cyclic_json(nil, &g, a))
	want = "{\"command\":\"toposort\",\"dict\":\"83dd02da8715e4c3\",\"variant\":null,\"truncated\":false,\"cyclic\":[],\"rows\":[]}\n"
	testing.expectf(t, got == want, "topo envelope:\n got %s\nwant %s", got, want)
}

// four-word stream over "alpha beta gamma delta"; doc=2 so every
// emitted doc field is proven to come from the span, not a literal
kwic_rows_json_golden_stream :: proc() -> (gloaming.Token_Stream, string) {
	text := "alpha beta gamma delta"
	words := []string{"alpha", "beta", "gamma", "delta"}
	offsets := [4]int{0, 6, 11, 17}
	toks := make([]gloaming.Token, 4, context.temp_allocator)
	for w, i in words {
		toks[i] = {
			surface = text[offsets[i]:offsets[i] + len(w)],
			lemma = text[offsets[i]:offsets[i] + len(w)],
			start = offsets[i],
			end = offsets[i] + len(w),
			kind = .Idless,
			entry_id = -1,
		}
	}
	return {doc = 2, tokens = toks}, text
}

@(test)
kwic_rows_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	stream, text := kwic_rows_json_golden_stream()
	matches := []gloaming.Match{
		{start = 1, end = 2, span = {doc = 2, start = 6, end = 10}},
	}
	rows := gloaming.kwic(matches, stream, 1, 1, -1, a)
	got := glexport.kwic_rows_json(rows, text, a)
	// left spans [tok0.start, center.start) and right [center.end,
	// tok2.end) — the inter-token space is part of the slice
	want := "[{\"doc\":2,\"left\":\"alpha \",\"center\":\"beta\",\"right\":\" gamma\",\"left_span\":[0,6],\"center_span\":[6,10],\"right_span\":[10,16]}]"
	testing.expectf(t, got == want, "kwic:\n got %s\nwant %s", got, want)

	// the wrong text (too short for the spans) reads as "", not a
	// refusal — the row survives visibly wrong
	got = glexport.kwic_rows_json(rows, "", a)
	want = "[{\"doc\":2,\"left\":\"\",\"center\":\"\",\"right\":\"\",\"left_span\":[0,6],\"center_span\":[6,10],\"right_span\":[10,16]}]"
	testing.expectf(t, got == want, "kwic short text:\n got %s\nwant %s", got, want)
}

@(test)
match_json_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	stream, text := kwic_rows_json_golden_stream()

	// the parse+match path: a plain surface query, one match
	q, qerr := gloaming.query_parse(`(seq (m surface "beta"))`, gloaming.Parse_Options{}, a)
	testing.expectf(t, qerr == .None, "parse: %v", qerr)
	if qerr != .None { return }
	res, merr := gloaming.query_match(&q, stream, 8, a)
	testing.expectf(t, merr == .None && len(res.matches) == 1, "match: %v n=%d",
		merr, len(res.matches))
	if merr != .None || len(res.matches) != 1 { return }
	got := glexport.match_json(res.matches[0], stream, text, &q, a)
	want := "{\"doc\":2,\"start\":6,\"end\":10,\"surfaces\":[\"beta\"],\"captures\":[]}"
	testing.expectf(t, got == want, "plain:\n got %s\nwant %s", got, want)

	// the capture path: names resolve through q.captures; a def the
	// query never declared renders "" (the row stays true)
	q2 := gloaming.Query{}
	q2.captures = []gloaming.Capture_Def{{name = "who"}}
	m := gloaming.Match{
		start = 0,
		end = 2,
		span = {doc = 2, start = 0, end = 10},
		captures = []gloaming.Capture{
			{def = 0, start = 1, end = 2, span = {doc = 2, start = 6, end = 10}},
			{def = 9, start = 0, end = 1, span = {doc = 2, start = 0, end = 5}},
		},
	}
	got = glexport.match_json(m, stream, text, &q2, a)
	want = "{\"doc\":2,\"start\":0,\"end\":10,\"surfaces\":[\"alpha\",\"beta\"],\"captures\":[{\"name\":\"who\",\"start\":6,\"end\":10,\"surface\":\"beta\"},{\"name\":\"\",\"start\":0,\"end\":5,\"surface\":\"alpha\"}]}"
	testing.expectf(t, got == want, "captures:\n got %s\nwant %s", got, want)
}
