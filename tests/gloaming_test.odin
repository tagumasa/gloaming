package gloaming_test

import "core:fmt"
import "core:hash"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "core:testing"

import gloaming "gloaming:gloaming"
import glexport "gloaming:glexport"

/*
The query path's golden table lives in tests/fixtures as data:
hand-computed semantics/capture cases, the predicate forms, and the
parse-error taxonomy.

Allocation discipline: the runner's leak gate sees everything still
live when a test returns, so each test owns one arena and nothing
allocates from context allocators — the harness splits fields by hand
(strings.fields would allocate) and the fixture source is arena-owned,
which also exercises the Query clone contract: nothing in a Query borrows
the parse source.
*/

FIXTURE_PATH :: "tests/fixtures/query_golden.txt"

// one shared arena backing buffer: package scope keeps it off the test
// stacks (a 1 MiB local warns), and the serial runner (threads=1)
// means no test sees another's arena
test_arena_buf: [1 << 20]u8

// the memo-cap test's 17k-token stream needs more than the shared
// 1 MiB — same package-scope discipline, sized for its own arena
memo_arena_buf: [4 << 20]u8

// the alt-repetition test's 32k-token stream and the cursor's frame and
// cont stacks need ~33 MB measured (the stacks grow through the arena
// without freeing, so the buffer carries the growth garbage too) — same
// package-scope discipline, sized with headroom for its own arena
deep_arena_buf: [40 << 20]u8

@(test)
fixture_query_golden :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	src_bytes, ferr := os.read_entire_file_from_path(FIXTURE_PATH, a)
	if ferr != nil {
		src_bytes, ferr = os.read_entire_file_from_path("fixtures/query_golden.txt", a)
	}
	if ferr != nil {
		testing.expectf(t, false, "fixture file %s not found (cwd?)", FIXTURE_PATH)
		return
	}
	cases := fixture_parse(t, string(src_bytes), a)
	groups := fixture_groups(a)
	customs := fixture_customs(a)

	for c in cases {
		opts := gloaming.Parse_Options{}
		if c.want_group { opts.groups = &groups }
		if c.want_custom { opts.custom = &customs }

		if c.is_error {
			_, err := gloaming.query_parse(c.query, opts, a)
			want := err_value(c.err_name)
			if err != want {
				testing.expectf(t, false, "%s: got %v, want %v", c.name, err, want)
			}
			continue
		}

		q, err := gloaming.query_parse(c.query, opts, a)
		if err != .None {
			testing.expectf(t, false, "%s: unexpected parse error %v", c.name, err)
			continue
		}
		stream := gloaming.Token_Stream{doc = 0, tokens = c.tokens, segments = c.segments}
		res, merr := gloaming.query_match(&q, stream, 4096, a)
		if merr != .None {
			testing.expectf(t, false, "%s: unexpected match error %v", c.name, merr)
			continue
		}
		fixture_check_matches(t, c, res, q)
		if c.want_kwic { fixture_check_kwic(t, c, stream, res, a) }
		if len(c.compound) > 0 { fixture_check_compound(t, c, res, a) }
	}
}

fixture_check_matches :: proc(t: ^testing.T, c: Fixture_Case, res: gloaming.Query_Result, q: gloaming.Query) {
	if len(res.matches) != len(c.rows) {
		testing.expectf(t, false, "%s: got %d matches, want %d",
			c.name, len(res.matches), len(c.rows))
		return
	}
	for i in 0..<len(res.matches) {
		m := res.matches[i]
		row := c.rows[i]
		if m.start != row.s || m.end != row.e ||
			m.span.start != row.bs || m.span.end != row.be {
			testing.expectf(t, false,
				"%s match %d: got [%d,%d) %d..%d, want [%d,%d) %d..%d",
				c.name, i, m.start, m.end, m.span.start, m.span.end,
				row.s, row.e, row.bs, row.be)
		}
		if len(m.captures) == len(row.caps) {
			for j in 0..<len(m.captures) {
				cp := m.captures[j]
				want := row.caps[j]
				got_name := q.captures[cp.def].name
				if got_name != want.name || cp.start != want.lo || cp.end != want.hi ||
					cp.span.start != want.blo || cp.span.end != want.bhi {
					testing.expectf(t, false,
						"%s match %d capture %d: got @%s [%d,%d) %d..%d, want @%s [%d,%d) %d..%d",
						c.name, i, j,
						got_name, cp.start, cp.end, cp.span.start, cp.span.end,
						want.name, want.lo, want.hi, want.blo, want.bhi)
				}
			}
		} else {
			testing.expectf(t, false, "%s match %d: got %d captures, want %d",
				c.name, i, len(m.captures), len(row.caps))
		}
	}
}

// kwic rows and sort orders (one case per key lives in the fixture)
fixture_check_kwic :: proc(
	t: ^testing.T,
	c: Fixture_Case,
	stream: gloaming.Token_Stream,
	res: gloaming.Query_Result,
	a: mem.Allocator,
) {
	rows := gloaming.kwic(res.matches, stream, c.kwic_left, c.kwic_right, c.kwic_center, a)
	if len(rows) != len(c.kwic_rows) {
		testing.expectf(t, false, "%s kwic: got %d rows, want %d",
			c.name, len(rows), len(c.kwic_rows))
		return
	}
	for row, i in rows {
		w := c.kwic_rows[i]
		if row.left.doc != stream.doc || row.center.doc != stream.doc || row.right.doc != stream.doc ||
			row.left.start != w.ls || row.left.end != w.le ||
			row.center.start != w.cs || row.center.end != w.ce ||
			row.right.start != w.rs || row.right.end != w.re {
			testing.expectf(t, false,
				"%s kwic %d: got L[%d,%d) C[%d,%d) R[%d,%d), want L[%d,%d) C[%d,%d) R[%d,%d)",
				c.name, i,
				row.left.start, row.left.end, row.center.start, row.center.end,
				row.right.start, row.right.end,
				w.ls, w.le, w.cs, w.ce, w.rs, w.re)
		}
	}
	for s in c.kwic_sorts {
		srows := gloaming.kwic(res.matches, stream, c.kwic_left, c.kwic_right, c.kwic_center, a)
		gloaming.kwic_sort(srows, stream, kwic_key(s.key))
		if len(s.order) != len(srows) {
			testing.expectf(t, false, "%s kwic-sort %s: %d rows, %d in order line",
				c.name, s.key, len(srows), len(s.order))
			continue
		}
		for k in 0..<len(s.order) {
			want := res.matches[s.order[k]].start
			if srows[k].match.start != want {
				testing.expectf(t, false, "%s kwic-sort %s pos %d: got match %d, want %d",
					c.name, s.key, k, srows[k].match.start, want)
			}
		}
	}
}

fixture_check_compound :: proc(
	t: ^testing.T,
	c: Fixture_Case,
	res: gloaming.Query_Result,
	a: mem.Allocator,
) {
	out, cerr := gloaming.compound(c.tokens, c.text, res.matches, a)
	if cerr != .None {
		testing.expectf(t, false, "%s compound: unexpected error %v", c.name, cerr)
		return
	}
	if len(out) != len(c.compound) {
		testing.expectf(t, false, "%s compound: got %d tokens, want %d",
			c.name, len(out), len(c.compound))
		return
	}
	for tok, i in out {
		w := c.compound[i]
		if tok.surface != w.surface || tok.lemma != w.lemma || tok.pos != w.pos ||
			tok.reading != w.reading || tok.start != w.start || tok.end != w.end ||
			tok.kind != w.kind || tok.cost != w.cost {
			testing.expectf(t, false,
				"%s compound %d: got %q/%q/%s/%s [%d,%d) u%v c%d, want %q/%q/%s/%s [%d,%d) u%v c%d",
				c.name, i,
				tok.surface, tok.lemma, tok.pos, tok.reading, tok.start, tok.end,
				tok.kind == .Unknown, int(tok.cost),
				w.surface, w.lemma, w.pos, w.reading, w.start, w.end,
				w.kind == .Unknown, int(w.cost))
		}
	}
}

// merge_matches / compound_merge (kwic): the host-curated entry — the
// resolution rule (earliest start, longer on ties, stable duplicates,
// artifacts dropped and counted) and end-to-end equality with
// hand-sorted compound input.
@(test)
merge_matches_resolution :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// span.start doubles as the identity tag the assertions read back
	mk :: proc(s, e, tag: int) -> gloaming.Match {
		return gloaming.Match{start = s, end = e, span = {start = tag, end = tag}}
	}

	// messy curation: a straddler overlapping two keepers, a duplicate
	// range, an empty span, an inverted span
	messy := []gloaming.Match{
		mk(3, 5, 2),
		mk(0, 2, 1), // earliest start wins
		mk(1, 4, 3), // straddles A and B — loser
		mk(0, 2, 4), // duplicate of A's range — earliest input entry (1) survives
		mk(5, 5, 5), // empty — artifact
		mk(4, 3, 6), // inverted — artifact
	}
	kept, dropped := gloaming.merge_matches(messy, a)
	if len(kept) != 2 || dropped != 4 {
		testing.expectf(t, false, "merge messy: kept %d dropped %d — want 2, 4",
			len(kept), dropped)
		return
	}
	if kept[0].span.start != 1 || kept[1].span.start != 2 {
		testing.expectf(t, false, "merge messy: kept tags %d,%d — want 1,2",
			kept[0].span.start, kept[1].span.start)
	}

	// equal starts resolve to the longer span
	tie := []gloaming.Match{mk(2, 4, 7), mk(2, 6, 8)}
	kept2, dropped2 := gloaming.merge_matches(tie, a)
	if len(kept2) != 1 || dropped2 != 1 {
		testing.expectf(t, false, "merge tie: kept %d dropped %d — want 1, 1",
			len(kept2), dropped2)
		return
	}
	if kept2[0].span.start != 8 || kept2[0].end != 6 {
		testing.expectf(t, false, "merge tie: kept tag %d [%d,%d) — want tag 8 [2,6)",
			kept2[0].span.start, kept2[0].end)
	}

	// abutting spans both survive; unsorted input comes back sorted
	abut := []gloaming.Match{mk(4, 6, 9), mk(0, 2, 10), mk(2, 4, 11)}
	kept3, dropped3 := gloaming.merge_matches(abut, a)
	if len(kept3) != 3 || dropped3 != 0 {
		testing.expectf(t, false, "merge abut: kept %d dropped %d — want 3, 0",
			len(kept3), dropped3)
		return
	}
	if kept3[0].start != 0 || kept3[2].start != 4 {
		testing.expectf(t, false, "merge abut: first %d last %d — want sorted 0, 4",
			kept3[0].start, kept3[2].start)
	}

	kept4, dropped4 := gloaming.merge_matches(nil, a)
	if dropped4 != 0 || len(kept4) != 0 {
		testing.expectf(t, false, "merge empty: kept %d dropped %d — want 0, 0",
			len(kept4), dropped4)
	}

	// end-to-end: the curated messy list === compound over hand-sorted spans
	text := "abcdef"
	toks := make([]gloaming.Token, 6, a)
	for i := 0; i < 6; i += 1 {
		toks[i] = gloaming.Token{surface = text[i:i + 1], lemma = text[i:i + 1],
			pos = "名詞,", start = i, end = i + 1}
	}
	sorted := []gloaming.Match{mk(0, 2, 1), mk(3, 5, 2)}
	want, werr := gloaming.compound(toks, text, sorted, a)
	got, gerr := gloaming.compound_merge(toks, text, messy, a)
	if werr != .None || gerr != .None {
		testing.expectf(t, false, "compound_merge e2e: errors want %v got %v", werr, gerr)
		return
	}
	if len(got) != len(want) {
		testing.expectf(t, false, "compound_merge e2e: %d tokens, want %d", len(got), len(want))
		return
	}
	for tok, i in got {
		w := want[i]
		if tok.surface != w.surface || tok.start != w.start || tok.end != w.end ||
			tok.entry_id != w.entry_id {
			testing.expectf(t, false,
				"compound_merge e2e %d: got %q [%d,%d) id%d, want %q [%d,%d) id%d",
				i, tok.surface, tok.start, tok.end, tok.entry_id,
				w.surface, w.start, w.end, w.entry_id)
		}
	}
	if len(got) == 4 && (got[0].surface != "ab" || got[2].surface != "de") {
		testing.expectf(t, false, "compound_merge e2e: merged surfaces %q, %q — want \"ab\", \"de\"",
			got[0].surface, got[2].surface)
	}

	// out-of-stream spans still report Bad_Range — resolution cannot
	// invent validity
	oob := []gloaming.Match{mk(10, 12, 0)}
	_, oerr := gloaming.compound_merge(toks, text, oob, a)
	if oerr != .Bad_Range {
		testing.expectf(t, false, "compound_merge oob: error %v, want Bad_Range", oerr)
	}
}

// Cursor discipline: limit/truncated, query_count
// agreement and saturation, the stop-check, the work budget, and the
// source-length cap (the fixture rows cover the rest of the taxonomy).
@(test)
cursor_discipline :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// 60 alternating noun/verb tokens, byte offsets contiguous
	toks := make([]gloaming.Token, 60, a)
	off := 0
	for i in 0..<60 {
		noun := i % 2 == 0
		surface := noun ? "夜" : "待つ"
		toks[i] = gloaming.Token{
			surface = surface,
			lemma   = surface,
			pos     = noun ? "名詞,一般,*,*,*" : "動詞,自立,五段・タ行,基本形",
			reading = noun ? "ヨル" : "マツ",
			start   = off,
			end     = off + len(surface),
		}
		off += len(surface)
	}
	stream := gloaming.Token_Stream{doc = 7, tokens = toks}

	q, err := gloaming.query_parse(`(seq (m pos ^"名詞,"))`, {}, a)
	if err != .None {
		testing.expectf(t, false, "parse: %v", err)
		return
	}

	// limit + truncated (limit below total, then above it)
	res, rerr := gloaming.query_match(&q, stream, 5, a)
	if rerr != .None || len(res.matches) != 5 || !res.truncated {
		testing.expectf(t, false, "limit 5: got %d matches truncated=%v err=%v",
			len(res.matches), res.truncated, rerr)
	}
	res, rerr = gloaming.query_match(&q, stream, 100, a)
	if rerr != .None || len(res.matches) != 30 || res.truncated {
		testing.expectf(t, false, "limit 100: got %d matches truncated=%v err=%v",
			len(res.matches), res.truncated, rerr)
	}
	if res.matches[0].span.doc != 7 {
		testing.expectf(t, false, "span doc not stamped from the stream: %d",
			int(res.matches[0].span.doc))
	}

	// query_count agrees with query_match totals and saturates at cap
	count, saturated, _ := gloaming.query_count(&q, stream, 100, a)
	if count != 30 || saturated {
		testing.expectf(t, false, "count: got %d saturated=%v", count, saturated)
	}
	count, saturated, _ = gloaming.query_count(&q, stream, 5, a)
	if count != 5 || !saturated {
		testing.expectf(t, false, "count cap: got %d saturated=%v", count, saturated)
	}

	// limit is mandatory — no unbounded materialization
	_, lerr := gloaming.query_match(&q, stream, 0, a)
	if lerr != .Bad_Argument {
		testing.expectf(t, false, "limit 0: got %v, want Bad_Argument", lerr)
	}
	_, _, caperr := gloaming.query_count(&q, stream, 0, a)
	if caperr != .Bad_Argument {
		testing.expectf(t, false, "count cap 0: got %v, want Bad_Argument", caperr)
	}

	// stop-check: abort with Interrupted after two candidate starts
	stops := 0
	stop_after_two :: proc(user: rawptr) -> bool {
		states := cast(^int)user
		states^ += 1
		return states^ > 2
	}
	_, ierr := gloaming.query_match(&q, stream, 100, a, stop_after_two, &stops)
	if ierr != .Interrupted {
		testing.expectf(t, false, "stop-check: got %v, want Interrupted", ierr)
	}

	// work budget: a 40-step noun ladder ending in an impossibility
	// burns past a shrunken budget set directly on the cursor (the
	// library constant stays put; the test-side shrink is the point)
	ladder := make([dynamic]u8, 0, 512, a)
	append_s(&ladder, "(seq ")
	for _ in 0..<40 {
		append_s(&ladder, `(m pos ^"名詞,") `)
	}
	append_s(&ladder, `(m surface "zzz無"))`)
	wq, werr := gloaming.query_parse(string(ladder[:]), {}, a)
	if werr != .None {
		testing.expectf(t, false, "ladder parse: %v", werr)
		return
	}
	nouns := make([]gloaming.Token, 100, a)
	off2 := 0
	for i in 0..<100 {
		nouns[i] = {
			surface = "夜",
			lemma   = "夜",
			pos     = "名詞,一般,*,*,*",
			reading = "ヨル",
			start   = off2,
			end     = off2 + 3,
		}
		off2 += 3
	}
	nstream := gloaming.Token_Stream{doc = 0, tokens = nouns}
	c := gloaming.match_begin(&wq, nstream, a)
	c.work_budget = 500
	for {
		_, ok := gloaming.next_match(&c, a)
		if !ok { break }
	}
	if c.err != .Work_Capped {
		testing.expectf(t, false, "shrunken budget: got %v, want Work_Capped", c.err)
	}
	gloaming.cursor_destroy(&c)

	// the same ladder runs to completion under the library budget
	c2 := gloaming.match_begin(&wq, nstream, a)
	for {
		_, ok := gloaming.next_match(&c2, a)
		if !ok { break }
	}
	if c2.err != .None {
		testing.expectf(t, false, "library budget: got %v, want None", c2.err)
	}
	gloaming.cursor_destroy(&c2)

	// the source-length cap needs a built-up source
	long := make([dynamic]u8, 0, 4300, a)
	for _ in 0..<4200 {
		append(&long, ';')
	}
	append(&long, '\n') // end the comment line or the ws skip eats the query
	append_s(&long, "(seq (m _))")
	_, tlerr := gloaming.query_parse(string(long[:]), {}, a)
	if tlerr != .Too_Long {
		testing.expectf(t, false, "source cap: got %v, want Too_Long", tlerr)
	}
}

@(test)
alt_nesting_and_not_rejected :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// a mixed (any …) m compiles to an alternation
	// step, and an alternation under an alternation leaves the memo
	// key without the outer alt's owed — the silent-loss case; the grammar rejects it
	_, err := gloaming.query_parse(
		`(seq (alt (m surface (any ^"x" "y"):2-) (m surface "z")):3-)`, {}, a)
	if err != .Bad_Syntax {
		testing.expectf(t, false, "nested alternation: got %v, want Bad_Syntax", err)
	}
	// an all-eq (any …) is one set predicate — a plain step, a legal
	// branch
	_, err = gloaming.query_parse(`(seq (alt (m surface (any "x" "y")) (m surface "z")))`, {}, a)
	if err != .None {
		testing.expectf(t, false, "set-any branch: got %v, want None", err)
	}
	// (not m) keeps only predicates; an alternation-carrying m has
	// none, so negation would match every token vacuously — rejected
	// the same way (not takes a plain m)
	_, err = gloaming.query_parse(`(seq (not (m surface (any ^"x" "y"))))`, {}, a)
	if err != .Bad_Syntax {
		testing.expectf(t, false, "not over mixed-any: got %v, want Bad_Syntax", err)
	}
	_, err = gloaming.query_parse(`(seq (not! (m surface (any ^"x" "y"))))`, {}, a)
	if err != .Bad_Syntax {
		testing.expectf(t, false, "not! over mixed-any: got %v, want Bad_Syntax", err)
	}
	_, err = gloaming.query_parse(`(seq (not (m pos ^"助詞,")))`, {}, a)
	if err != .None {
		testing.expectf(t, false, "plain not: got %v, want None", err)
	}

	// the flattened equivalent of the rejected pattern still matches:
	// x x x x z is one 5-token run of the :3- alternation
	toks := make([]gloaming.Token, 5, a)
	off := 0
	for i in 0..<5 {
		s := i < 4 ? "x" : "z"
		toks[i] = {surface = s, start = off, end = off + 1}
		off += 1
	}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks}
	q, perr := gloaming.query_parse(`(seq (alt (m surface "x") (m surface "y") (m surface "z")):3-)`, {}, a)
	if perr != .None {
		testing.expectf(t, false, "flattened alt parse: %v", perr)
		return
	}
	res, merr := gloaming.query_match(&q, stream, 10, a)
	if merr != .None || len(res.matches) != 1 ||
		res.matches[0].start != 0 || res.matches[0].end != 5 {
		testing.expectf(t, false, "flattened alt: err=%v matches=%d, want None/1 [0..5)",
			merr, len(res.matches))
	}
}

@(test)
memo_bitmap_capped :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, memo_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the amplification shape: 15 × 16-member mixed-any
	// alternations :64- plus a wildcard — n_ids 256, owed_dim 64, so
	// 2048 bytes of memo per token; a 17k-token stream passes that over
	// QUERY_MEMO_MAX_BYTES and must refuse before allocating
	src := make([dynamic]u8, 0, 2048, a)
	append_s(&src, "(seq ")
	for _ in 0..<15 {
		append_s(&src, `(m surface (any ^"a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p"):64-) `)
	}
	append_s(&src, "(m _))")
	q, perr := gloaming.query_parse(string(src[:]), {}, a)
	if perr != .None {
		testing.expectf(t, false, "amplification pattern should parse: %v", perr)
		return
	}

	big := make([]gloaming.Token, 17000, a)
	for i in 0..<17000 {
		big[i] = {surface = "a", start = i, end = i + 1}
	}
	bstream := gloaming.Token_Stream{doc = 0, tokens = big}

	res, merr := gloaming.query_match(&q, bstream, 10, a)
	if merr != .Memo_Capped || len(res.matches) != 0 {
		testing.expectf(t, false, "big stream: err=%v matches=%d, want Memo_Capped/0",
			merr, len(res.matches))
	}
	count, sat, cerr := gloaming.query_count(&q, bstream, 10, a)
	if cerr != .Memo_Capped || count != 0 || sat {
		testing.expectf(t, false, "big count: err=%v count=%d sat=%v, want Memo_Capped/0/false",
			cerr, count, sat)
	}
	c := gloaming.match_begin(&q, bstream, a)
	if c.err != .Memo_Capped {
		testing.expectf(t, false, "refused cursor: got %v, want Memo_Capped", c.err)
	}
	if _, ok := gloaming.next_match(&c, a); ok {
		testing.expectf(t, false, "refused cursor yielded a match")
	}
	gloaming.cursor_destroy(&c)

	// the same pattern on a short stream stays far under the cap and
	// completes: no match — 15 alternations × min 64 outrun 100 tokens
	sstream := gloaming.Token_Stream{doc = 0, tokens = big[:100]}
	sres, serr := gloaming.query_match(&q, sstream, 10, a)
	if serr != .None || len(sres.matches) != 0 {
		testing.expectf(t, false, "short stream: err=%v matches=%d, want None/0",
			serr, len(sres.matches))
	}
}

// The deep-repetition regression: `(alt …):*` over a whole stream once
// cost two to three native frames per repetition (the run_cont →
// match_quant → match_fresh cycle); the trampoline holds that state in
// the cursor's frame and cont stacks instead. 32k repetitions sit past
// any native-stack budget the recursive form could rely on (~96k
// frames; the buffer is sized from the measured allocation footprint —
// an under-sized arena fails allocations silently, not loudly), and the
// result must still be the one whole-stream match with the capture
// spanning it.
@(test)
alt_repetition_deep_stream :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, deep_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	q, perr := gloaming.query_parse(`(seq (alt (m surface "w") (m surface "x")) :* @a)`, {}, a)
	if perr != .None {
		testing.expectf(t, false, "parse: %v", perr)
		return
	}

	n := 32000
	toks := make([]gloaming.Token, n, a)
	for i in 0..<n {
		toks[i] = {surface = "w", start = i, end = i + 1}
		if i & 1 == 1 { toks[i].surface = "x" }
	}
	res, merr := gloaming.query_match(&q, gloaming.Token_Stream{doc = 0, tokens = toks}, 4, a)
	if merr != .None || len(res.matches) != 1 {
		testing.expectf(t, false, "err=%v matches=%d, want None/1", merr, len(res.matches))
		return
	}
	m := res.matches[0]
	if m.start != 0 || m.end != n || m.span.start != 0 || m.span.end != n {
		testing.expectf(t, false, "match: [%d,%d) bytes %d..%d, want [0,%d) 0..%d",
			m.start, m.end, m.span.start, m.span.end, n, n)
	}
	if len(m.captures) != 1 {
		testing.expectf(t, false, "captures: %d, want 1", len(m.captures))
		return
	}
	cp := m.captures[0]
	if cp.start != 0 || cp.end != n || cp.span.start != 0 || cp.span.end != n {
		testing.expectf(t, false, "@a: [%d,%d) bytes %d..%d, want [0,%d) 0..%d",
			cp.start, cp.end, cp.span.start, cp.span.end, n, n)
	}
	if res.truncated {
		testing.expectf(t, false, "truncated set on a complete enumeration")
	}
}

// The cursor owns its memo, boundary table, and binding stack:
// match_begin → next_match → cursor_destroy must net zero on the
// tracking allocator (the Query and tokens live in an arena — the
// ownership split).
@(test)
cursor_owns_its_memory :: proc(t: ^testing.T) {
	aarena: mem.Arena
	mem.arena_init(&aarena, test_arena_buf[:])
	aa := mem.arena_allocator(&aarena)
	defer mem.arena_free_all(&aarena)

	q, err := gloaming.query_parse(
		`(seq (alt (m surface "氏") (m surface "さん")) (not! (m pos ^"助詞,")))`,
		{}, aa,
	)
	if err != .None {
		testing.expectf(t, false, "parse: %v", err)
		return
	}
	toks := make([]gloaming.Token, 4, aa)
	toks[0] = gloaming.Token{surface = "氏", pos = "名詞,接尾,一般,*,*", lemma = "氏", reading = "シ", end = 3}
	toks[1] = gloaming.Token{surface = "に", pos = "助詞,格助詞,*,*,*", lemma = "に", reading = "ニ", start = 3, end = 6}
	toks[2] = gloaming.Token{surface = "さん", pos = "名詞,接尾,人名,*,*", lemma = "さん", reading = "サン", start = 6, end = 12}
	toks[3] = gloaming.Token{surface = "。", pos = "記号,句点,*,*,*", lemma = "。", reading = "。", start = 12, end = 15}
	stream := gloaming.Token_Stream{doc = 3, tokens = toks}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	ta := mem.tracking_allocator(&track)

	c := gloaming.match_begin(&q, stream, ta)
	found := 0
	for {
		m, ok := gloaming.next_match(&c, ta)
		if !ok { break }
		found += 1
		if m.start != 2 || m.end != 3 || m.span.doc != 3 || m.span.start != 6 {
			testing.expectf(t, false, "match: [%d,%d) doc %d bytes %d..%d",
				m.start, m.end, int(m.span.doc), m.span.start, m.span.end)
		}
	}
	if c.err != .None {
		testing.expectf(t, false, "cursor run: %v", c.err)
	}
	if found != 1 {
		testing.expectf(t, false, "found %d matches, want 1", found)
	}
	gloaming.cursor_destroy(&c)
	if track.current_memory_allocated != 0 {
		testing.expectf(t, false, "live bytes after cursor_destroy: %d",
			int(track.current_memory_allocated))
	}
	mem.tracking_allocator_destroy(&track)
}

// query_match's truncated peek only asks whether one more match
// exists — it must not build that match's captures on the caller's
// allocator and abandon them there.
@(test)
query_match_peek_owns_nothing :: proc(t: ^testing.T) {
	aarena: mem.Arena
	mem.arena_init(&aarena, test_arena_buf[:])
	aa := mem.arena_allocator(&aarena)
	defer mem.arena_free_all(&aarena)

	q, err := gloaming.query_parse(`(seq (m surface "氏") @a (m surface "さん") @b)`, {}, aa)
	if err != .None {
		testing.expectf(t, false, "parse: %v", err)
		return
	}
	toks := make([]gloaming.Token, 4, aa) // 氏さん氏さん — two captured matches
	for i in 0..<4 {
		sur := i % 2 == 0 ? "氏" : "さん"
		toks[i] = gloaming.Token{
			surface = sur,
			pos     = "名詞,接尾,一般,*,*",
			lemma   = sur,
			reading = i % 2 == 0 ? "シ" : "サン",
			start   = i * 3,
			end     = i * 3 + 3,
		}
	}
	stream := gloaming.Token_Stream{doc = 3, tokens = toks}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	ta := mem.tracking_allocator(&track)

	res, merr := gloaming.query_match(&q, stream, 1, ta)
	if !testing.expectf(t, merr == .None, "query_match: %v", merr) { return }
	if !testing.expect_value(t, len(res.matches), 1) { return }
	testing.expect_value(t, res.truncated, true)
	// the caller owns the returned matches and their captures
	for m in res.matches { delete(m.captures, ta) }
	delete(res.matches, ta)
	if track.current_memory_allocated != 0 {
		testing.expectf(t, false, "live bytes after query_match: %d (the peek's captures)",
			int(track.current_memory_allocated))
	}
	mem.tracking_allocator_destroy(&track)
}

// --- the fixture dialect ---

Fixture_Case :: struct {
	name:         string,
	query:        string,
	text:         string, // `---- text`: the source the token byte offsets view into
	tokens:       []gloaming.Token,
	segments:     []gloaming.Segment,
	rows:         []Expect_Row,
	err_name:     string,
	is_error:     bool,
	want_group:   bool,
	want_custom:  bool,
	want_kwic:    bool,
	kwic_left:    int,
	kwic_right:   int,
	kwic_center:  int,
	kwic_rows:    []Expect_Kwic_Row,
	kwic_sorts:   []Expect_Kwic_Sort,
	compound:     []gloaming.Token,
}

Expect_Cap :: struct {
	name: string,
	lo:   int,
	hi:   int,
	blo:  int,
	bhi:  int,
}

Expect_Row :: struct {
	s:    int,
	e:    int,
	bs:   int,
	be:   int,
	caps: []Expect_Cap,
}

Expect_Kwic_Row :: struct {
	ls, le, cs, ce, rs, re: int,
}

Expect_Kwic_Sort :: struct {
	key:   string,
	order: []int, // original row indices, in sorted order
}

Mode :: enum {
	Header,
	Query,
	Text,
	Tokens,
	Segments,
	Options,
	Expected,
	Kwic,
	KwicSort,
	Compound,
}

// append_s: string append without context allocation (leak gate)
append_s :: proc(arr: ^[dynamic]u8, s: string) {
	for i in 0..<len(s) {
		append(arr, s[i])
	}
}

// split_fields: whitespace split into a fixed buffer, no allocation
split_fields :: proc(s: string, out: []string) -> int {
	n := 0
	start := -1
	for i in 0..<len(s) + 1 {
		at_end := i == len(s)
		space := !at_end && (s[i] == ' ' || s[i] == '\t')
		if !at_end && !space {
			if start < 0 { start = i }
			continue
		}
		if start >= 0 {
			if n < len(out) {
				out[n] = s[start:i]
				n += 1
			} else {
				return n // overflow: caller sized the buffer wrong
			}
			start = -1
		}
	}
	return n
}

fixture_parse :: proc(t: ^testing.T, src: string, a: mem.Allocator) -> []Fixture_Case {
	cases: [dynamic]Fixture_Case = make([dynamic]Fixture_Case, 0, 64, a)
	query_buf: [dynamic]u8 = make([dynamic]u8, 0, 128, a)
	tokens: [dynamic]gloaming.Token = make([dynamic]gloaming.Token, 0, 16, a)
	segments: [dynamic]gloaming.Segment = make([dynamic]gloaming.Segment, 0, 4, a)
	rows: [dynamic]Expect_Row = make([dynamic]Expect_Row, 0, 4, a)
	kwic_rows: [dynamic]Expect_Kwic_Row = make([dynamic]Expect_Kwic_Row, 0, 4, a)
	kwic_sorts: [dynamic]Expect_Kwic_Sort = make([dynamic]Expect_Kwic_Sort, 0, 2, a)
	compound: [dynamic]gloaming.Token = make([dynamic]gloaming.Token, 0, 8, a)
	mode := Mode.Header

	flush :: proc(
		cases: ^[dynamic]Fixture_Case,
		query_buf: ^[dynamic]u8,
		tokens: ^[dynamic]gloaming.Token,
		segments: ^[dynamic]gloaming.Segment,
		rows: ^[dynamic]Expect_Row,
		kwic_rows: ^[dynamic]Expect_Kwic_Row,
		kwic_sorts: ^[dynamic]Expect_Kwic_Sort,
		compound: ^[dynamic]gloaming.Token,
		mode: Mode,
	) {
		if mode == Mode.Header { return } // nothing accumulated
		c := &(cases^)[len(cases^) - 1]
		c.query = string(query_buf[:])
		c.tokens = tokens[:]
		c.segments = segments[:]
		c.rows = rows[:]
		c.kwic_rows = kwic_rows[:]
		c.kwic_sorts = kwic_sorts[:]
		c.compound = compound[:]
	}

	s := src
	for line in strings.split_lines_iterator(&s) {
		ln := strings.trim_space(line)
		if ln == "" { continue }
		if strings.has_prefix(ln, "==== ") && strings.has_suffix(ln, " ====") {
			flush(&cases, &query_buf, &tokens, &segments, &rows,
				&kwic_rows, &kwic_sorts, &compound, mode)
			append(&cases, Fixture_Case{name = ln[5:len(ln) - 5]})
			query_buf = make([dynamic]u8, 0, 128, a)
			tokens = make([dynamic]gloaming.Token, 0, 16, a)
			segments = make([dynamic]gloaming.Segment, 0, 4, a)
			rows = make([dynamic]Expect_Row, 0, 4, a)
			kwic_rows = make([dynamic]Expect_Kwic_Row, 0, 4, a)
			kwic_sorts = make([dynamic]Expect_Kwic_Sort, 0, 2, a)
			compound = make([dynamic]gloaming.Token, 0, 8, a)
			mode = .Query
			continue
		}
		switch mode {
		case .Header:
			testing.expectf(t, false, "line outside any case: %q", ln)
		case .Query:
			if ln == "---- text" { mode = .Text; continue }
			if ln == "---- tokens" { mode = .Tokens; continue }
			if ln == "---- segments" { mode = .Segments; continue }
			if ln == "---- options" { mode = .Options; continue }
			if strings.has_prefix(ln, "---- error ") {
				last := &cases[len(cases) - 1]
				last.is_error = true
				last.err_name = strings.trim_space(ln[len("---- error "):])
				mode = .Expected // error cases carry nothing else
				continue
			}
			if len(query_buf) > 0 { append(&query_buf, '\n') }
			append_s(&query_buf, ln)
		case .Text:
			// one verbatim line: the source text the token byte offsets
			// view into (compound cases only; fixtures keep it free of
			// leading/trailing whitespace so trim_space is harmless)
			cases[len(cases) - 1].text = ln
			mode = .Query
		case .Tokens:
			if ln == "---- segments" { mode = .Segments; continue }
			if ln == "---- options" { mode = .Options; continue }
			if ln == "---- expected" { mode = .Expected; continue }
			append(&tokens, fixture_token(t, ln))
		case .Segments:
			if ln == "---- options" { mode = .Options; continue }
			if ln == "---- expected" { mode = .Expected; continue }
			fields: [3]string
			n := split_fields(ln, fields[:])
			if n != 3 {
				testing.expectf(t, false, "segment row wants 3 fields: %q", ln)
				continue
			}
			kind := gloaming.Segment_Kind.Sentence
			switch fields[0] {
			case "chapter":   kind = .Chapter
			case "paragraph": kind = .Paragraph
			case "sentence":  kind = .Sentence
			case:             testing.expectf(t, false, "segment kind: %q", fields[0])
			}
			ss := parse_i32(t, fields[1])
			se := parse_i32(t, fields[2])
			append(&segments, gloaming.Segment{
				kind = kind,
				span = {doc = 0, start = ss, end = se},
			})
		case .Options:
			if ln == "---- tokens" { mode = .Tokens; continue }
			if ln == "---- segments" { mode = .Segments; continue }
			if ln == "---- expected" { mode = .Expected; continue }
			last := &cases[len(cases) - 1]
			if ln == "group 見る" {
				last.want_group = true
			} else if ln == "custom sys" {
				last.want_custom = true
			} else {
				testing.expectf(t, false, "options row: %q", ln)
			}
		case .Expected:
			if strings.has_prefix(ln, "---- kwic ") {
				fixture_kwic_header(t, ln, &cases[len(cases) - 1])
				mode = .Kwic
				continue
			}
			if ln == "---- compound" { mode = .Compound; continue }
			append(&rows, fixture_row(t, ln, a))
		case .Kwic:
			if strings.has_prefix(ln, "---- kwic-sort ") {
				append(&kwic_sorts, Expect_Kwic_Sort{key = ln[len("---- kwic-sort "):]})
				mode = .KwicSort
				continue
			}
			if ln == "---- compound" { mode = .Compound; continue }
			append(&kwic_rows, fixture_kwic_row(t, ln))
		case .KwicSort:
			if strings.has_prefix(ln, "---- kwic-sort ") {
				append(&kwic_sorts, Expect_Kwic_Sort{key = ln[len("---- kwic-sort "):]})
				continue
			}
			if ln == "---- compound" { mode = .Compound; continue }
			order: [dynamic]int = make([dynamic]int, 0, 8, a)
			fields: [16]string
			n := split_fields(ln, fields[:])
			for i in 0..<n {
				append(&order, parse_i32(t, fields[i]))
			}
			kwic_sorts[len(kwic_sorts) - 1].order = order[:]
		case .Compound:
			append(&compound, fixture_token(t, ln))
		}
	}
	flush(&cases, &query_buf, &tokens, &segments, &rows,
		&kwic_rows, &kwic_sorts, &compound, mode)
	return cases[:]
}

fixture_kwic_header :: proc(t: ^testing.T, ln: string, last: ^Fixture_Case) {
	fields: [5]string
	n := split_fields(ln, fields[:])
	if n != 5 {
		testing.expectf(t, false, "kwic header wants `---- kwic <left> <right> <center>`: %q", ln)
		return
	}
	last.want_kwic = true
	last.kwic_left = parse_i32(t, fields[2])
	last.kwic_right = parse_i32(t, fields[3])
	last.kwic_center = parse_i32(t, fields[4])
}

fixture_kwic_row :: proc(t: ^testing.T, ln: string) -> Expect_Kwic_Row {
	fields: [6]string
	n := split_fields(ln, fields[:])
	if n != 6 {
		testing.expectf(t, false, "kwic row wants 6 fields: %q", ln)
		return {}
	}
	return Expect_Kwic_Row{
		ls = parse_i32(t, fields[0]),
		le = parse_i32(t, fields[1]),
		cs = parse_i32(t, fields[2]),
		ce = parse_i32(t, fields[3]),
		rs = parse_i32(t, fields[4]),
		re = parse_i32(t, fields[5]),
	}
}

// token rows split on tabs only — surfaces (compound output especially)
// may contain spaces
split_tabs :: proc(s: string, out: []string) -> int {
	n := 0
	start := -1
	for i := 0; i < len(s) + 1; i += 1 {
		at_end := i == len(s)
		tab := !at_end && s[i] == '\t'
		if !at_end && !tab {
			if start < 0 { start = i }
			continue
		}
		if start >= 0 {
			if n < len(out) {
				out[n] = s[start:i]
				n += 1
			} else {
				return n // overflow: caller sized the buffer wrong
			}
			start = -1
		}
	}
	return n
}

fixture_token :: proc(t: ^testing.T, ln: string) -> gloaming.Token {
	fields: [8]string
	n := split_tabs(ln, fields[:])
	if n < 6 {
		testing.expectf(t, false, "token row wants >= 6 fields: %q", ln)
		return {}
	}
	// column 7: "-" none, "1" unknown, "idless" a synthesized (compound) row
	kind := gloaming.Token_Kind.Dictionary
	rowless := false
	if n > 6 {
		switch fields[6] {
		case "1":       kind, rowless = .Unknown, true
		case "idless":  kind, rowless = .Idless, true
		case "-", "0":
		case:           testing.expectf(t, false, "token kind column: %q", fields[6])
		}
	}
	cost := 0
	if n > 7 && fields[7] != "-" {
		cost = parse_i32(t, fields[7])
	}
	tok := gloaming.Token{
		surface = fields[0],
		pos     = fields[1],
		lemma   = fields[2],
		reading = fields[3],
		start   = parse_i32(t, fields[4]),
		end     = parse_i32(t, fields[5]),
		kind    = kind,
		cost    = i16(cost),
	}
	if rowless { tok.entry_id = -1 } // the -1 payload_encode requires of row-less kinds
	return tok
}

// expected row: `start end byte_start byte_end [@name lo hi blo bhi]…`
fixture_row :: proc(t: ^testing.T, ln: string, a: mem.Allocator) -> Expect_Row {
	fields: [32]string
	n := split_fields(ln, fields[:])
	if n < 4 {
		testing.expectf(t, false, "expected row wants >= 4 fields: %q", ln)
		return {}
	}
	row := Expect_Row{
		s  = parse_i32(t, fields[0]),
		e  = parse_i32(t, fields[1]),
		bs = parse_i32(t, fields[2]),
		be = parse_i32(t, fields[3]),
	}
	caps: [dynamic]Expect_Cap = make([dynamic]Expect_Cap, 0, 4, a)
	i := 4
	for i < n {
		if !strings.has_prefix(fields[i], "@") {
			testing.expectf(t, false, "expected capture wants @name: %q", ln)
			break
		}
		if i + 5 > n {
			testing.expectf(t, false, "expected capture wants 5 fields: %q", ln)
			break
		}
		append(&caps, Expect_Cap{
			name = fields[i][1:],
			lo   = parse_i32(t, fields[i + 1]),
			hi   = parse_i32(t, fields[i + 2]),
			blo  = parse_i32(t, fields[i + 3]),
			bhi  = parse_i32(t, fields[i + 4]),
		})
		i += 5
	}
	row.caps = caps[:]
	return row
}

parse_i32 :: proc(t: ^testing.T, s: string) -> int {
	v, ok := strconv.parse_int(s)
	if !ok {
		testing.expectf(t, false, "bad integer %q", s)
		return 0
	}
	return int(v)
}

err_value :: proc(name: string) -> gloaming.Query_Err {
	switch name {
	case "Bad_Syntax":     return .Bad_Syntax
	case "Bad_Quantifier": return .Bad_Quantifier
	case "Bad_Value":      return .Bad_Value
	case "Bad_Argument":   return .Bad_Argument
	case "Unknown_Field":  return .Unknown_Field
	case "No_Group":       return .No_Group
	case "No_Custom":      return .No_Custom
	case "Too_Long":       return .Too_Long
	case "Interrupted":    return .Interrupted
	case "Work_Capped":    return .Work_Capped
	case "Memo_Capped":    return .Memo_Capped
	case "Set_Capped":     return .Set_Capped
	case:                 return .None
	}
}

kwic_key :: proc(name: string) -> gloaming.Kwic_Sort_Key {
	switch name {
	case "Position": return .Position
	case "Left_1":   return .Left_1
	case "Left_2":   return .Left_2
	case "Right_1":  return .Right_1
	case "Right_2":  return .Right_2
	case "Surface":  return .Surface
	}
	return .Position
}

// the options registration table (the one piece of per-fixture code).
// The group goes through the real loader — the index comes with it,
// which is what the `~` path reads through.
fixture_groups :: proc(a: mem.Allocator) -> gloaming.Lemma_Groups {
	groups, err := gloaming.lemma_groups_parse("見る\t観る\t視る", a)
	if err != .None { return {} }
	return groups
}

sys_reading_prefix :: proc(tok: ^gloaming.Token, user_data: rawptr) -> bool {
	_ = user_data
	return len(tok.reading) >= 6 && tok.reading[:6] == "シス"
}

fixture_customs :: proc(a: mem.Allocator) -> gloaming.Custom_Preds {
	procs := make(map[string]gloaming.Custom_Proc, a)
	procs["sys"] = sys_reading_prefix
	return gloaming.Custom_Preds{procs = procs}
}

// Anchors at misaligned segment edges: a segment
// edge landing inside a token snaps inward to the nearest
// fully-contained token edge — ^ and $ answer symmetrically.
@(test)
anchor_edge_snap :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// 猫犬鳥魚猿 contiguous: [0,3) [3,6) [6,9) [9,12) [12,15)
	text := "猫犬鳥魚猿"
	toks := make([]gloaming.Token, 5, a)
	for i in 0..<5 {
		s := text[i * 3:(i + 1) * 3]
		toks[i] = gloaming.Token{surface = s, lemma = s, start = i * 3, end = i * 3 + 3}
	}
	// the segment [4,10) starts inside 犬 and ends inside 魚: the
	// snapped edges are token 2 (first start ≥ 4) and token 3 (first
	// end > 10) — 鳥 is the one fully-contained token
	stream := gloaming.Token_Stream{
		doc      = 0,
		tokens   = toks,
		segments = []gloaming.Segment{
			{kind = .Paragraph, span = {doc = 0, start = 4, end = 10}},
		},
	}

	run :: proc(t: ^testing.T, src: string, stream: gloaming.Token_Stream,
	            a: mem.Allocator) -> []gloaming.Match {
		q, perr := gloaming.query_parse(src, {}, a)
		if !testing.expectf(t, perr == .None, "parse %s: %v", src, perr) { return nil }
		res, merr := gloaming.query_match(&q, stream, 8, a)
		if !testing.expectf(t, merr == .None, "match %s: %v", src, merr) { return nil }
		return res.matches
	}

	// ^ fires at the snapped start — without the snap no token
	// starts exactly at byte 4
	ms := run(t, `(seq ^ (m surface "鳥"))`, stream, a)
	if testing.expect_value(t, len(ms), 1) {
		testing.expect_value(t, ms[0].start, 2)
	}
	// $ symmetric: the snapped end is after token 2
	ms = run(t, `(seq $ (m surface "鳥"))`, stream, a)
	testing.expect_value(t, len(ms), 1)
	// the straddled tokens are not boundaries: ^犬 and $猫 stay dark
	testing.expect_value(t, len(run(t, `(seq ^ (m surface "犬"))`, stream, a)), 0)
	testing.expect_value(t, len(run(t, `(seq $ (m surface "猫"))`, stream, a)), 0)
}

// The TSV loader: comments, CRLF, single-column groups, sequential ids,
// Duplicate_Lemma/Bad_Syntax, the clone contract (scribbling the source after parse leaves every member and index
// key intact), and the member_index/scan differential.
@(test)
lemma_groups_loader :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	src: [dynamic]u8 = make([dynamic]u8, 0, 128, a)
	append_s(&src, "# 見る family — comment lines are skipped\r\n")
	append_s(&src, "見る\t観る\t視る\r\n")
	append_s(&src, "\r\n")
	append_s(&src, "単独\r\n")

	lg, err := gloaming.lemma_groups_parse(string(src[:]), a)
	if !testing.expectf(t, err == .None, "parse: %v", err) { return }
	if len(lg.groups) != 2 {
		testing.expectf(t, false, "got %d groups, want 2", len(lg.groups))
		return
	}
	testing.expect_value(t, int(lg.groups[0].id), 0)
	testing.expect_value(t, int(lg.groups[1].id), 1)
	testing.expectf(t, lg.groups[0].name == "見る", "name: %q", lg.groups[0].name)
	testing.expect_value(t, len(lg.groups[0].lemmas), 3)
	testing.expect_value(t, len(lg.groups[1].lemmas), 1)

	// the clone contract: destroy the source text, then keep reading
	for i in 0..<len(src) { src[i] = '#' }
	testing.expectf(t, lg.groups[0].lemmas[1] == "観る", "member: %q", lg.groups[0].lemmas[1])
	probes := []string{"見る", "観る", "視る", "単独", "食べる", "夜"}
	for p in probes {
		gid, ok := gloaming.group_of(&lg, p)
		sgid, sok := gloaming.group_of_scan(&lg, p)
		if ok != sok || (ok && gid != sgid) {
			testing.expectf(t, false, "index/scan disagree on %q: (%d,%v) vs (%d,%v)",
				p, int(gid), ok, int(sgid), sok)
		}
	}
	gid, gok := gloaming.group_of(&lg, "視る")
	testing.expect(t, gok && int(gid) == 0)
	_, gok2 := gloaming.group_of(&lg, "食べる")
	testing.expect(t, !gok2)

	_, derr := gloaming.lemma_groups_parse("見る\t観る\n観る\t看る", a)
	testing.expect_value(t, int(derr), int(gloaming.Thesaurus_Err.Duplicate_Lemma))
	_, serr := gloaming.lemma_groups_parse("見る\t\t観る", a)
	testing.expect_value(t, int(serr), int(gloaming.Thesaurus_Err.Bad_Syntax))
}

// the ~ expansion's set bound: the set path's one cap, wherever the
// members came from — an (any …) literal list or a lemma group. The
// group table itself stays unbounded data; the compiled set refuses
@(test)
group_set_cap :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// one group of ANY_EQ_MAX - 1 members: the ~ set is the members
	// plus the literal itself, so this is the last legal expansion
	// (member names "w!".."w_" — unique, tab- and newline-free)
	tsv: [dynamic]u8 = make([dynamic]u8, 0, 512, a)
	for i in 0..<gloaming.ANY_EQ_MAX - 1 {
		if i > 0 { append(&tsv, '\t') }
		append(&tsv, 'w')
		append(&tsv, u8('!' + i))
	}
	lg, lerr := gloaming.lemma_groups_parse(string(tsv[:]), a)
	if !testing.expectf(t, lerr == .None, "loader: %v", lerr) { return }
	_, qerr := gloaming.query_parse(`(seq (m lemma ~"w!"))`, gloaming.Parse_Options{groups = &lg}, a)
	testing.expect_value(t, int(qerr), int(gloaming.Query_Err.None))

	append_s(&tsv, "\tw~")
	lg2, lerr2 := gloaming.lemma_groups_parse(string(tsv[:]), a)
	if !testing.expectf(t, lerr2 == .None, "loader: %v", lerr2) { return }
	_, qerr2 := gloaming.query_parse(`(seq (m lemma ~"w!"))`, gloaming.Parse_Options{groups = &lg2}, a)
	testing.expect_value(t, int(qerr2), int(gloaming.Query_Err.Set_Capped))
}

/*
The parse pool's blocks hand out bytes that never move. A `~` set
clones group bytes far past the source cap (the cap bounds the source,
not the group), so two expansions cross the first block — the
structural check is that no block ever grew past its reserve (a grown
block means a relocation stranded string headers already embedded in
steps), and the content check is that the second expansion's members
read true.
*/
@(test)
pool_blocks_stable_across_expansion :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// 40 distinct members of 110 bytes: one expansion alone crosses
	// POOL_BLOCK (rows vary at bytes 3-4; the literal is row 0's form)
	member := make([]u8, 110, a)
	member[0] = 'm'
	for i in 1..<len(member) { member[i] = 'x' }
	tsv: [dynamic]u8 = make([dynamic]u8, 0, 4600, a)
	for i in 0..<40 {
		member[3] = u8('a' + (i % 26))
		member[4] = u8('a' + (i / 26))
		if i > 0 { append(&tsv, '\t') }
		append_s(&tsv, string(member))
	}
	member[3] = 'a'
	member[4] = 'a'
	member_s := string(member)
	lg, lerr := gloaming.lemma_groups_parse(string(tsv[:]), a)
	if !testing.expectf(t, lerr == .None, "loader: %v", lerr) { return }

	b := strings.builder_make(a)
	strings.write_string(&b, `(seq (m lemma ~"`)
	strings.write_string(&b, member_s)
	strings.write_string(&b, `") (m lemma ~"`)
	strings.write_string(&b, member_s)
	strings.write_string(&b, `"))`)
	q, qerr := gloaming.query_parse(strings.to_string(b), gloaming.Parse_Options{groups = &lg}, a)
	if !testing.expectf(t, qerr == .None, "parse: %v", qerr) { return }

	if !testing.expectf(t, len(q.pool) >= 2, "pool blocks: %d, want >= 2", len(q.pool)) { return }
	for blk in q.pool {
		if cap(blk) > gloaming.POOL_BLOCK {
			testing.expectf(t, false, "block grew past its reserve: len=%d cap=%d",
				len(blk), cap(blk))
		}
	}
	s1, ok1 := q.steps[1].body.(gloaming.And_Body)
	if !testing.expectf(t, ok1, "step 1 is not an and body") { return }
	set, ok2 := s1.predicates[0].match.(gloaming.Set_Match)
	if !testing.expectf(t, ok2, "step 1 holds no set") { return }
	testing.expect_value(t, len(set.members), 41) // the group plus the literal itself
	for l in lg.groups[0].lemmas {
		found := false
		for m in set.members {
			if m == l { found = true; break }
		}
		if !found {
			testing.expectf(t, false, "a group member is missing from the second expansion")
			return
		}
	}
}

/*
The parse refusals allocate nothing net. Every failing pattern and
loader text below runs on the test's tracking allocator — no arena —
so the runner's leak gate is the assertion: anything a refusal strands
surfaces as a leak WARN and fails the suite log. (Success paths are
not here by design: the parsed Query is caller-owned memory, the
parse-arena contract.)
*/
@(test)
parse_refusals_net_zero :: proc(t: ^testing.T) {
	// the groups table lives on its own arena; the parses borrow it
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	ga := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)
	lg, lerr := gloaming.lemma_groups_parse("見る\t観る\t視る", ga)
	if !testing.expectf(t, lerr == .None, "loader: %v", lerr) { return }
	opts := gloaming.Parse_Options{groups = &lg}

	ta := context.allocator
	bad := []string{
		`(seq (m surface "x`,                              // unterminated string, after a clone
		`(seq (m surface "a" surface "b"))`,                 // same field twice, after an Eq clone
		`(seq (m surface (any "a" ~"見る") surface "z"))`,    // mixed-any built, then the field repeats
		`(seq (alt (m surface "a") (m surface "b")) :0-3)`,  // branches built, alt-quant refusal
		`(seq (alt (m _ :0-1) (m _)) :*)`,                   // zero-consuming branch, one step in
		`(seq (m lemma (fuzzy "少ない" :4)))`,                 // fuzzy distance past the cap
		`(seq (m nosuch "x"))`,                              // unknown field, nothing built yet
		`(seq (m reading %"nope"))`,                         // custom lookup miss
		`(seq (m lemma ~"見る" lemma ~"観る"))`,                // sets built, then the field repeats
	}
	for src in bad {
		_, qerr := gloaming.query_parse(src, opts, ta)
		if qerr == .None {
			testing.expectf(t, false, "%q parsed — the case must fail", src)
		}
	}

	// loader refusals on the tracking allocator too: the line in
	// progress and every completed group free before the return
	_, derr := gloaming.lemma_groups_parse("見る\t観る\n観る\t看る", ta)
	testing.expect_value(t, int(derr), int(gloaming.Thesaurus_Err.Duplicate_Lemma))
	_, serr := gloaming.lemma_groups_parse("見る\t観る\n視る\t\t単独", ta)
	testing.expect_value(t, int(serr), int(gloaming.Thesaurus_Err.Bad_Syntax))
}

// the doc×doc joins walk the Doc_Profile order — keys not strictly
// ascending (duplicates included) refuse, not compute a wrong table
@(test)
profiles_out_of_order_refused :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	bad := []gloaming.Doc_Profile{{doc = 1, keys = []string{"b", "a"}, counts = []int{1, 1}}}
	_, werr := gloaming.doc_weights(bad, a)
	testing.expect_value(t, int(werr), int(gloaming.Freq_Err.Bad_Count))
	_, derr := gloaming.doc_distance(bad, .Jaccard, a)
	testing.expect_value(t, int(derr), int(gloaming.Freq_Err.Bad_Count))
	dup := []gloaming.Doc_Profile{{doc = 1, keys = []string{"a", "a"}, counts = []int{2, 1}}}
	df := []gloaming.Freq_Entry{{lemma = "a", count = 3, docs = 1}}
	_, merr := gloaming.doc_matrix(dup, []string{"a"}, df, .Tf, a)
	testing.expect_value(t, int(merr), int(gloaming.Freq_Err.Bad_Count))
}

@(test)
token_view_spans_and_graph_records_carry_the_contract :: proc(t: ^testing.T) {
	tok := gloaming.Token{
		surface = "走った",
		lemma   = "走る",
		pos     = "動詞,自立,五段・タ行,連用形タ接続",
		reading = "ハシッタ",
		start   = 0,
		end     = 9,
		cost    = 4200,
	}
	testing.expect(t, tok.lemma == "走る")
	testing.expect_value(t, tok.end - tok.start, 9)
	testing.expect_value(t, int(tok.cost), 4200)

	chapter := gloaming.Segment{
		kind = .Chapter,
		span = {doc = 1, start = 0, end = 253861},
	}
	testing.expect_value(t, int(chapter.kind), int(gloaming.Segment_Kind.Chapter))

	entity := gloaming.Entity{id = 7, kind = gloaming.KIND_NONE, name = "たそがれ"}
	mention := gloaming.Mention{entity = entity.id, span = chapter.span}
	testing.expect_value(t, int(mention.entity), 7)

	relation := gloaming.Relation{
		kind    = gloaming.KIND_NONE,
		from    = entity.id,
		to      = entity.id,
		derived = true,
	}
	testing.expect(t, relation.derived)
}

// freq_table: filters in application order, scope selection with
// containment dedup, lemma vs surface counting, min_count, the
// deterministic tiebreak, and Bad_Scope.
@(test)
freq_table_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	rows := []string{
		"夜	名詞,一般,*,*,*	夜	ヨル	0	3",
		"更ける	動詞,自立,一段,基本形	更ける	フケル	3	12",
		"夜	名詞,一般,*,*,*	夜	ヨル	12	15",
		"静か	形状詞,*,*,*,*	静か	シズカ	15	21",
		"夜	名詞,一般,*,*,*	夜	ヨル	21	24",
		"の	助詞,連体化,*,*,*	の	ノ	24	27",
		"見た	動詞,自立,一段,連用形た	見る	ミタ	27	33",
		"見る	動詞,自立,一段,基本形	見る	ミル	33	39",
		"。	記号,句点,*,*,*	。	。	39	42",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	ch1 := gloaming.Segment{kind = .Chapter, span = {doc = 0, start = 0, end = 24}}
	ch2 := gloaming.Segment{kind = .Chapter, span = {doc = 0, start = 24, end = 42}}
	stream := gloaming.Token_Stream{
		doc      = 0,
		tokens   = toks,
		segments = []gloaming.Segment{ch1, ch2},
	}

	check :: proc(
		t: ^testing.T,
		got: []gloaming.Freq_Entry,
		want: []string, // "key count" pairs, in expected order
		label: string,
	) {
		if len(got) != len(want) {
			testing.expectf(t, false, "%s: got %d entries, want %d", label, len(got), len(want))
			return
		}
		for e, i in got {
			wkey, wcount := fixture_split2(want[i])
			if e.lemma != wkey || e.count != wcount || e.docs != 1 {
				testing.expectf(t, false, "%s entry %d: got %q x%d docs%d, want %q x%d",
					label, i, e.lemma, e.count, e.docs, wkey, wcount)
			}
		}
	}

	// whole stream, surface counting: 夜 x3 leads; the count-1 ties key
	// ascending by code point (UTF-8 byte order): 。 < の < 更ける < 見た < 見る < 静か
	entries, err := gloaming.freq_table(stream, {}, {}, a)
	if err != .None {
		testing.expectf(t, false, "plain: %v", err)
		return
	}
	check(t, entries, []string{
		"夜 3", "。 1", "の 1", "更ける 1", "見た 1", "見る 1", "静か 1",
	}, "plain")

	entries, err = gloaming.freq_table(stream, {}, {pos_prefixes = []string{"名詞,"}}, a)
	testing.expectf(t, err == .None, "pos filter: %v", err)
	check(t, entries, []string{"夜 3"}, "pos filter")

	entries, err = gloaming.freq_table(stream, {}, {stopwords = []string{"夜"}}, a)
	testing.expectf(t, err == .None, "stopwords: %v", err)
	check(t, entries, []string{"。 1", "の 1", "更ける 1", "見た 1", "見る 1", "静か 1"}, "stopwords")

	// lemma counting folds 見た/見る into 見る
	entries, err = gloaming.freq_table(stream, {}, {use_lemma = true}, a)
	testing.expectf(t, err == .None, "lemma: %v", err)
	check(t, entries, []string{
		"夜 3", "見る 2", "。 1", "の 1", "更ける 1", "静か 1",
	}, "lemma")

	entries, err = gloaming.freq_table(stream, {}, {use_lemma = true, min_count = 2}, a)
	testing.expectf(t, err == .None, "min_count: %v", err)
	check(t, entries, []string{"夜 3", "見る 2"}, "min_count")

	// scope: chapter 1 only (bytes 0..24); listing it twice changes
	// nothing — dedup is by containment
	entries, err = gloaming.freq_table(stream, []gloaming.Segment{ch1}, {}, a)
	testing.expectf(t, err == .None, "scope: %v", err)
	check(t, entries, []string{"夜 3", "更ける 1", "静か 1"}, "scope")

	entries, err = gloaming.freq_table(stream, []gloaming.Segment{ch1, ch1}, {}, a)
	testing.expectf(t, err == .None, "scope dup: %v", err)
	check(t, entries, []string{"夜 3", "更ける 1", "静か 1"}, "scope dup")

	inverted := gloaming.Segment{kind = .Chapter, span = {doc = 0, start = 24, end = 0}}
	_, err = gloaming.freq_table(stream, []gloaming.Segment{inverted}, {}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Scope))
}

// helper: split "key count" at the last space
fixture_split2 :: proc(s: string) -> (string, int) {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == ' ' {
			v, ok := strconv.parse_int(s[i + 1:])
			if !ok { return s, -1 }
			return s[:i], int(v)
		}
	}
	return s, -1
}

// segment_scores: cost sums + unknown runs per scope segment,
// nesting scored literally, the run and span tiebreaks, both empty-
// scope fallbacks (stream outline, whole stream), and Bad_Scope.
@(test)
segment_scores_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	rows := []string{
		"彼	名詞,代名詞,一般,*,*	彼	カレ	0	3	-	10",
		"むむ	名詞,一般,*,*,*	むむ	ムム	3	9	1	0",
		"と	助詞,格助詞,一般,*,*	と	ト	9	12	-	10",
		"暗い	形容詞,自立,*,*,*	暗い	クライ	12	18	-	100",
		"ゾロ	名詞,一般,*,*,*	ゾロ	ゾロ	18	21	1	9000",
		"ガサゴソ	名詞,一般,*,*,*	ガサゴソ	ガサゴソ	21	27	1	8000",
		"音	名詞,一般,*,*,*	音	オト	27	30	-	70",
		"。	記号,句点,*,*,*	。	。	30	33	-	10",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	par1 := gloaming.Segment{kind = .Paragraph, span = {doc = 0, start = 0, end = 12}}
	par2 := gloaming.Segment{kind = .Paragraph, span = {doc = 0, start = 12, end = 30}}
	par3 := gloaming.Segment{kind = .Paragraph, span = {doc = 0, start = 27, end = 33}}
	ch := gloaming.Segment{kind = .Chapter, span = {doc = 0, start = 0, end = 33}}
	w := gloaming.Segment{kind = .Paragraph, span = {doc = 0, start = 3, end = 12}}
	u := gloaming.Segment{kind = .Paragraph, span = {doc = 0, start = 0, end = 3}}
	stream := gloaming.Token_Stream{
		doc      = 0,
		tokens   = toks,
		segments = []gloaming.Segment{par1, par2, par3},
	}

	check :: proc(
		t: ^testing.T,
		got: []gloaming.Segment_Score,
		want: []string, // "cost_sum tokens run start end" rows, in order
		label: string,
	) {
		if len(got) != len(want) {
			testing.expectf(t, false, "%s: got %d rows, want %d", label, len(got), len(want))
			return
		}
		for r, i in got {
			fields: [8]string
			n := split_fields(want[i], fields[:])
			if n < 5 {
				testing.expectf(t, false, "%s row %d: bad want %q", label, i, want[i])
				return
			}
			wcost, _ := strconv.parse_int(fields[0])
			wtok := parse_i32(t, fields[1])
			wrun := parse_i32(t, fields[2])
			wstart := parse_i32(t, fields[3])
			wend := parse_i32(t, fields[4])
			if r.cost_sum != i64(wcost) || r.tokens != wtok || r.unknown_run != wrun ||
			   r.span.start != wstart || r.span.end != wend || u32(r.span.doc) != 0 {
				testing.expectf(t, false,
					"%s row %d: got %d/%d/run %d [%d..%d) doc %d, want %d/%d/run %d [%d..%d)",
					label, i, r.cost_sum, r.tokens, r.unknown_run, r.span.start,
					r.span.end, u32(r.span.doc), wcost, wtok, wrun, wstart, wend)
			}
		}
	}

	// paragraphs: the 17170 spike (two unknowns in a row) leads; 音
	// (start 27) scores for both par2 and par3 by the start rule
	scores, err := gloaming.segment_scores(stream, []gloaming.Segment{par1, par2, par3}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "paragraphs: %v", err)
	check(t, scores, []string{
		"17170 4 2 12 30",
		"80 2 0 27 33",
		"20 3 1 0 12",
	}, "paragraphs")

	// chapter beside its paragraph: both rows, tokens counted in each
	scores, err = gloaming.segment_scores(stream, []gloaming.Segment{ch, par2}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "nested: %v", err)
	check(t, scores, []string{
		"17200 8 2 0 33",
		"17170 4 2 12 30",
	}, "nested")

	// cost tie broken by the unknown run
	scores, err = gloaming.segment_scores(stream, []gloaming.Segment{w, u}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "run tie: %v", err)
	check(t, scores, []string{
		"10 2 1 3 12",
		"10 1 0 0 3",
	}, "run tie")

	// empty scope = the stream's own outline
	scores, err = gloaming.segment_scores(stream, {}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "stream outline: %v", err)
	check(t, scores, []string{
		"17170 4 2 12 30",
		"80 2 0 27 33",
		"20 3 1 0 12",
	}, "stream outline")

	// no outline either = one whole-stream row
	bare := gloaming.Token_Stream{doc = 0, tokens = toks}
	scores, err = gloaming.segment_scores(bare, {}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "whole stream: %v", err)
	check(t, scores, []string{"17200 8 2 0 33"}, "whole stream")

	inverted := gloaming.Segment{kind = .Paragraph, span = {doc = 0, start = 12, end = 0}}
	_, err = gloaming.segment_scores(stream, []gloaming.Segment{inverted}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Scope))
}

// notation_pairs: (reading, POS) groups with divergent lemmas as
// ordered pairs — count-desc / code-point sides, total-desc global
// order, the tie chain, the unknown/"*"-reading/same-reading-other-POS
// exclusions, scope, and Bad_Scope.
@(test)
notation_pairs_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	rows := []string{
		"沢山	名詞,副詞可能,*,*,*	沢山	タクサン	0	6	-	0",
		"たくさん	名詞,副詞可能,*,*,*	たくさん	タクサン	6	15	-	0",
		"沢山	名詞,副詞可能,*,*,*	沢山	タクサン	15	21	-	0",
		"朝	名詞,一般,*,*,*	朝	アサ	21	24	-	0",
		"アサ	名詞,一般,*,*,*	アサ	アサ	24	30	-	0",
		"朝	名詞,一般,*,*,*	朝	アサ	30	33	-	0",
		"あさ	名詞,一般,*,*,*	あさ	アサ	33	39	-	0",
		"アサ	名詞,一般,*,*,*	アサ	アサ	39	45	-	0",
		"頂く	動詞,自立,一段,基本形	頂く	イタダク	45	48	-	0",
		"いただく	動詞,自立,一段,基本形	いただく	イタダク	48	60	-	0",
		"春	名詞,一般,*,*,*	春	ハル	60	63	-	0",
		"張る	動詞,自立,五段,基本形	張る	ハル	63	69	-	0",
		"…	記号,一般,*,*,*	…	*	69	72	-	0",
		"♪	記号,一般,*,*,*	♪	*	72	75	-	0",
		"ムム	名詞,一般,*,*,*	ムム	ムム	75	81	1	0",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks}

	check :: proc(
		t: ^testing.T,
		got: []gloaming.Notation_Pair,
		want: []string, // "reading pos lemma_a count_a lemma_b count_b"
		label: string,
	) {
		if len(got) != len(want) {
			testing.expectf(t, false, "%s: got %d pairs, want %d", label, len(got), len(want))
			return
		}
		for p, i in got {
			fields: [8]string
			n := split_fields(want[i], fields[:])
			if n < 6 {
				testing.expectf(t, false, "%s pair %d: bad want %q", label, i, want[i])
				return
			}
			ca := parse_i32(t, fields[3])
			cb := parse_i32(t, fields[5])
			if p.reading != fields[0] || p.pos != fields[1] ||
			   p.lemma_a != fields[2] || p.count_a != ca ||
			   p.lemma_b != fields[4] || p.count_b != cb {
				testing.expectf(t, false,
					"%s pair %d: got %s %s %q×%d/%q×%d, want %s %s %q×%d/%q×%d",
					label, i, p.reading, p.pos, p.lemma_a, p.count_a, p.lemma_b,
					p.count_b, fields[0], fields[1], fields[2], ca, fields[4], cb)
			}
		}
	}

	// whole stream: the 3-variant アサ group yields C(3,2) pairs; the
	// イタダク tie puts いただく (code point) first; ハル never pairs
	// (same reading, different POS), "*"-readings and the unknown are
	// not notation evidence at all
	pairs, err := gloaming.notation_pairs(stream, {}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "whole: %v", err)
	check(t, pairs, []string{
		"アサ 名詞,一般,*,*,* アサ 2 朝 2",
		"アサ 名詞,一般,*,*,* アサ 2 あさ 1",
		"アサ 名詞,一般,*,*,* 朝 2 あさ 1",
		"タクサン 名詞,副詞可能,*,*,* 沢山 2 たくさん 1",
		"イタダク 動詞,自立,一段,基本形 いただく 1 頂く 1",
	}, "whole")

	// scope [0,21): only the タクサン group is inside
	scope := []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 0, end = 21}},
	}
	pairs, err = gloaming.notation_pairs(stream, scope, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "scope: %v", err)
	check(t, pairs, []string{
		"タクサン 名詞,副詞可能,*,*,* 沢山 2 たくさん 1",
	}, "scope")

	inverted := []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 21, end = 0}},
	}
	_, err = gloaming.notation_pairs(stream, inverted, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Scope))
}

// the graph tests never decode payloads — a resolver that resolves
// nothing stands in for the adapter's
no_resolver :: proc(ctx: rawptr, id: i32, surface: string) ->
              (pos, lemma, reading: string, ok: bool) {
	_ = ctx
	_ = id
	_ = surface
	return "", "", "", false
}

// co_occurrence: segment windows vs tumbling token windows, the
// shared extraction filter, binary co-presence per window, the
// max_pairs dial's deterministic cut, and the two refusals.
@(test)
co_occurrence_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// 猫犬猫鳥犬 | 猫鳥魚犬猫 — 魚 is the one 動詞 among 名詞
	rows := []string{
		"猫	名詞,一般,*,*,*	猫	ネコ	0	3	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	3	6	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	6	9	-	0",
		"鳥	名詞,一般,*,*,*	鳥	トリ	9	12	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	12	15	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	15	18	-	0",
		"鳥	名詞,一般,*,*,*	鳥	トリ	18	21	-	0",
		"魚	動詞,自立,*,*,*	魚	サカナ	21	24	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	24	27	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	27	30	-	0",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	segs := []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 0, end = 15}},
		{kind = .Paragraph, span = {doc = 0, start = 15, end = 30}},
	}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks, segments = segs}

	check :: proc(
		t: ^testing.T,
		got: []gloaming.Co_Pair,
		want: []string, // "a b n"
		label: string,
	) {
		if len(got) != len(want) {
			testing.expectf(t, false, "%s: got %d pairs, want %d", label, len(got), len(want))
			return
		}
		for p, i in got {
			fields: [4]string
			n := split_fields(want[i], fields[:])
			if n < 3 {
				testing.expectf(t, false, "%s pair %d: bad want %q", label, i, want[i])
				return
			}
			wn := parse_i32(t, fields[2])
			if p.a != fields[0] || p.b != fields[1] || p.n != wn {
				testing.expectf(t, false, "%s pair %d: got %q %q ×%d, want %q %q ×%d",
					label, i, p.a, p.b, p.n, fields[0], fields[1], wn)
			}
		}
	}

	opts := gloaming.Cooc_Options{unit = .Segments, filter = {use_lemma = true}}

	// paragraph windows: {猫,犬,鳥} then {猫,鳥,魚,犬}, a pair once per
	// window however often either side repeats
	pairs, trunc, err := gloaming.co_occurrence(stream, {}, opts, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "segments: %v", err)
	if trunc {
		testing.expectf(t, false, "segments: truncated without a cap")
	}
	check(t, pairs, []string{
		"犬 猫 2", "犬 鳥 2", "猫 鳥 2",
		"犬 魚 1", "猫 魚 1", "魚 鳥 1",
	}, "segments")

	// tumbling 3-token windows over the filtered sequence
	pairs, _, err = gloaming.co_occurrence(stream, {},
		{unit = .Tokens, window = 3, filter = {use_lemma = true}}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "tokens: %v", err)
	check(t, pairs, []string{
		"犬 猫 2", "犬 鳥 2", "犬 魚 1", "猫 鳥 1", "魚 鳥 1",
	}, "tokens")

	// the shared filter: 名詞 only drops the 魚 row entirely
	pairs, _, err = gloaming.co_occurrence(stream, {}, {
		unit = .Segments,
		filter = {pos_prefixes = {"名詞,"}, use_lemma = true},
	}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "filtered: %v", err)
	check(t, pairs, []string{
		"犬 猫 2", "犬 鳥 2", "猫 鳥 2",
	}, "filtered")

	// max_pairs: the first two distinct pairs keep counting, later new
	// pairs skip — the deterministic cut, and the flag makes it visible
	cap_trunc: bool
	pairs, cap_trunc, err = gloaming.co_occurrence(stream, {}, {
		unit = .Segments,
		max_pairs = 2,
		filter = {use_lemma = true},
	}, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "capped: %v", err)
	if !cap_trunc {
		testing.expectf(t, false, "capped: truncated flag not set at max_pairs = 2")
	}
	check(t, pairs, []string{"犬 猫 2", "猫 鳥 2"}, "capped")

	// the exact-cap population is not truncation (Code_Result's rule)
	_, exact_trunc, eerr := gloaming.co_occurrence(stream, {}, {
		unit = .Segments,
		max_pairs = 6,
		filter = {use_lemma = true},
	}, a)
	testing.expectf(t, eerr == gloaming.Freq_Err.None, "exact cap: %v", eerr)
	if exact_trunc {
		testing.expectf(t, false, "exact cap: truncated set at max_pairs = 6")
	}

	// a repeated scope segment opens one window, not two (containment
	// dedup — freq_table's rule carried onto windows)
	pairs, _, err = gloaming.co_occurrence(stream, []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 0, end = 15}},
		{kind = .Paragraph, span = {doc = 0, start = 0, end = 15}},
		{kind = .Paragraph, span = {doc = 0, start = 15, end = 30}},
	}, opts, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "repeated: %v", err)
	check(t, pairs, []string{
		"犬 猫 2", "犬 鳥 2", "猫 鳥 2",
		"犬 魚 1", "猫 魚 1", "魚 鳥 1",
	}, "repeated")

	// a scope segment nested inside another listed one is subsumed: one
	// window over the container
	nested := []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 0, end = 15}},
		{kind = .Chapter,   span = {doc = 0, start = 0, end = 30}},
		{kind = .Paragraph, span = {doc = 0, start = 15, end = 30}},
	}
	pairs, _, err = gloaming.co_occurrence(stream, nested, opts, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "nested: %v", err)
	check(t, pairs, []string{
		"犬 猫 1", "犬 魚 1", "犬 鳥 1", "猫 魚 1", "猫 鳥 1", "魚 鳥 1",
	}, "nested")
	pres, perr := gloaming.cooc_presence(stream, nested, opts, a)
	testing.expectf(t, perr == gloaming.Freq_Err.None, "nested presence: %v", perr)
	testing.expect_value(t, pres.windows, 1) // the marginal population too

	_, _, err = gloaming.co_occurrence(stream, {}, {unit = .Tokens, window = 0}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Window))

	inverted := []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 15, end = 0}},
	}
	_, _, err = gloaming.co_occurrence(stream, inverted, opts, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Scope))
}

// A coding rule's pairs become derived relations
// with evidence and round-trip through the disk store — same rows,
// same evidence order — alongside a curated edge and a doc attr on
// the same log.
@(test)
coding_rule_round_trip :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	dir := "tmp/glr-rt"
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, a)
	pay, _ := os.join_path({dir, "payloads.glb"}, a)
	_ = os.remove(reg)
	_ = os.remove(pay)

	// 朝 猫 が 眠い 犬 。 猫 犬 鳥 — 猫×2, 犬×2
	rows := []string{
		"朝	名詞,一般,*,*,*	朝	アサ	0	3	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	3	6	-	0",
		"が	助詞,格助詞,一般,*,*	が	ガ	6	9	-	0",
		"眠い	形容詞,自立,*,*,*	眠い	ネムイ	9	12	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	12	15	-	0",
		"。	記号,句点,*,*,*	。	。	15	18	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	18	21	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	21	24	-	0",
		"鳥	名詞,一般,*,*,*	鳥	トリ	24	27	-	0",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	stream := gloaming.Token_Stream{doc = 7, tokens = toks}

	qa, perr := gloaming.query_parse(`(seq (m lemma "猫"))`, {}, a)
	testing.expectf(t, perr == gloaming.Query_Err.None, "parse a: %v", perr)
	qb, perr2 := gloaming.query_parse(`(seq (m lemma "犬"))`, {}, a)
	testing.expectf(t, perr2 == gloaming.Query_Err.None, "parse b: %v", perr2)

	rule := gloaming.Coding_Rule{code = "near", a = &qa, b = &qb, window = 2, cap = 100}
	res, qerr := gloaming.graph_code_pairs(&rule, stream, a)
	testing.expectf(t, qerr == gloaming.Query_Err.None, "code pairs: %v", qerr)
	if len(res.pairs) != 3 {
		testing.expectf(t, false, "got %d pairs, want 3", len(res.pairs))
		return
	}
	testing.expectf(t, res.pairs[0].a.start == 3 && res.pairs[0].a.end == 6 &&
		res.pairs[0].b.start == 12 && res.pairs[0].b.end == 15,
		"pair 0 spans: %d-%d / %d-%d", res.pairs[0].a.start, res.pairs[0].a.end,
		res.pairs[0].b.start, res.pairs[0].b.end)
	testing.expectf(t, res.pairs[1].a.start == 12 && res.pairs[1].b.start == 18,
		"pair 1: the dog is the earlier span")
	testing.expectf(t, res.pairs[2].a.start == 18 && res.pairs[2].b.start == 21,
		"pair 2: adjacent cat-dog")

	// the pair cap exactly met is not truncation — one more pair must
	// exist for the flag (query_match's peek discipline)
	r2 := gloaming.Coding_Rule{code = "near", a = &qa, b = &qb, window = 2, cap = 2}
	res2, q2err := gloaming.graph_code_pairs(&r2, stream, a)
	testing.expectf(t, q2err == gloaming.Query_Err.None, "cap 2: %v", q2err)
	testing.expectf(t, len(res2.pairs) == 2 && res2.truncated,
		"cap 2: %d pairs, truncated %v", len(res2.pairs), res2.truncated)
	r3 := gloaming.Coding_Rule{code = "near", a = &qa, b = &qb, window = 2, cap = 3}
	res3, q3err := gloaming.graph_code_pairs(&r3, stream, a)
	testing.expectf(t, q3err == gloaming.Query_Err.None, "cap 3: %v", q3err)
	testing.expectf(t, len(res3.pairs) == 3 && !res3.truncated,
		"cap 3 (exact): %d pairs, truncated %v", len(res3.pairs), res3.truncated)

	// the host loop the design names: entities for the matched terms,
	// mentions at the match spans, one relation per code pair
	_, dstore, serr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store_disk: %v", serr)
	cat, ea := gloaming.graph_entity_add(dstore, "term", "猫", {"ネコ"})
	testing.expectf(t, ea == gloaming.Store_Err.None, "entity a: %v", ea)
	dog, eb := gloaming.graph_entity_add(dstore, "term", "犬", nil)
	testing.expectf(t, eb == gloaming.Store_Err.None, "entity b: %v", eb)
	testing.expectf(t, int(cat) == 0 && int(dog) == 1, "ids: %d %d", int(cat), int(dog))

	ma, merr := gloaming.query_match(&qa, stream, 100, a)
	testing.expectf(t, merr == gloaming.Query_Err.None, "match a: %v", merr)
	for m in ma.matches {
		_, e := gloaming.graph_mention_add(dstore, cat, m.span)
		testing.expectf(t, e == gloaming.Store_Err.None, "mention: %v", e)
	}
	mb, merr2 := gloaming.query_match(&qb, stream, 100, a)
	testing.expectf(t, merr2 == gloaming.Query_Err.None, "match b: %v", merr2)
	for m in mb.matches {
		_, e := gloaming.graph_mention_add(dstore, dog, m.span)
		testing.expectf(t, e == gloaming.Store_Err.None, "mention: %v", e)
	}

	for p in res.pairs {
		_, rerr := gloaming.graph_relation_add(dstore, "near", cat, dog, {p.a, p.b}, true)
		testing.expectf(t, rerr == gloaming.Store_Err.None, "relation: %v", rerr)
	}
	// a curated edge on the same pair — derived is the only difference
	_, cerr := gloaming.graph_relation_add(dstore, "same-universe", cat, dog,
		{{doc = 7, start = 0, end = 27}}, false)
	testing.expectf(t, cerr == gloaming.Store_Err.None, "curated: %v", cerr)
	aerr := gloaming.graph_attr_put(dstore, 7, "genre", "novel")
	testing.expectf(t, aerr == gloaming.Store_Err.None, "attr: %v", aerr)

	// refusals: dead entity, self-edge, duplicate name
	_, xerr := gloaming.graph_relation_add(dstore, "x", cat, gloaming.Entity_Id(99), nil, true)
	testing.expect_value(t, int(xerr), int(gloaming.Store_Err.Not_Found))
	_, xerr = gloaming.graph_relation_add(dstore, "x", cat, cat, nil, true)
	testing.expect_value(t, int(xerr), int(gloaming.Store_Err.Bad_Range))
	_, derr := gloaming.graph_entity_add(dstore, "term", "犬", nil)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Duplicate))

	gloaming.disk_store_close(dstore)
	_, ds2, rerr2 := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr2 == gloaming.Store_Err.None, "reopen: %v", rerr2)
	defer gloaming.disk_store_close(ds2)

	found, ok := gloaming.graph_entity_find(&ds2.graph, "ネコ")
	testing.expectf(t, ok && found == cat, "alias find after reopen")
	testing.expect_value(t, len(ds2.graph.entities), 2)
	testing.expect_value(t, len(ds2.graph.mentions), 4) // 2 cats + 2 dogs
	testing.expect_value(t, len(ds2.graph.relations), 2) // near + same-universe

	near: ^gloaming.Relation
	curated: ^gloaming.Relation
	for i in 0..<len(ds2.graph.relations) {
		r := &ds2.graph.relations[i]
		if r.derived { near = r } else { curated = r }
	}
	testing.expectf(t, near != nil && len(near.evidence) == 4,
		"derived evidence: %d spans, want 4 (the distinct spans of 3 pairs)",
		near != nil ? len(near.evidence) : -1)
	if near != nil {
		testing.expectf(t, near.evidence[0].start == 3 && near.evidence[1].start == 12 &&
			near.evidence[2].start == 18 && near.evidence[3].start == 21,
			"evidence order kept: %d %d %d %d",
			near.evidence[0].start, near.evidence[1].start,
			near.evidence[2].start, near.evidence[3].start)
		testing.expectf(t, near.evidence[0].doc == 7, "evidence stamps the stream doc")
	}
	testing.expectf(t, curated != nil && ds2.graph.kinds[curated.kind] == "same-universe" &&
		len(curated.evidence) == 1, "curated row intact")
	testing.expect_value(t, len(ds2.graph.attrs), 1)
	testing.expectf(t, ds2.graph.attrs[0].key == "genre" && ds2.graph.attrs[0].val == "novel",
		"attr round trip")
}

// absorption is set semantics: a span the row already holds is not
// repeated — re-running a rule or re-citing a passage leaves the
// evidence set untouched, first-seen order kept, across a reopen.
@(test)
relation_evidence_set :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	dir := "tmp/glr-ev"
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, a)
	pay, _ := os.join_path({dir, "payloads.glb"}, a)
	_ = os.remove(reg)
	_ = os.remove(pay)

	_, ds, serr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store_disk: %v", serr)
	x, ea := gloaming.graph_entity_add(ds, "term", "x", nil)
	testing.expectf(t, ea == gloaming.Store_Err.None, "entity x: %v", ea)
	y, eb := gloaming.graph_entity_add(ds, "term", "y", nil)
	testing.expectf(t, eb == gloaming.Store_Err.None, "entity y: %v", eb)

	s1 := gloaming.Span{doc = 3, start = 0, end = 2}
	s2 := gloaming.Span{doc = 3, start = 4, end = 6}
	s3 := gloaming.Span{doc = 5, start = 1, end = 3}
	rid, r1 := gloaming.graph_relation_add(ds, "near", x, y, {s1, s2}, true)
	testing.expectf(t, r1 == gloaming.Store_Err.None, "add: %v", r1)
	// the same spans in another order — the set is already complete
	_, r2 := gloaming.graph_relation_add(ds, "near", x, y, {s2, s1}, true)
	testing.expectf(t, r2 == gloaming.Store_Err.None, "re-add: %v", r2)
	testing.expect_value(t, int(r2), int(rid))
	// a new span among repeats appends; the repeats do not
	_, r3 := gloaming.graph_relation_add(ds, "near", x, y, {s1, s3}, true)
	testing.expectf(t, r3 == gloaming.Store_Err.None, "mixed add: %v", r3)
	testing.expect_value(t, int(r3), int(rid))

	testing.expect_value(t, len(ds.graph.relations), 1)
	ev := ds.graph.relations[0].evidence
	testing.expectf(t, len(ev) == 3, "evidence set: %d spans, want 3", len(ev))
	if len(ev) == 3 {
		testing.expectf(t, ev[0].doc == s1.doc && ev[0].start == s1.start && ev[0].end == s1.end, "ev[0] is s1")
		testing.expectf(t, ev[1].doc == s2.doc && ev[1].start == s2.start && ev[1].end == s2.end, "ev[1] is s2")
		testing.expectf(t, ev[2].doc == s3.doc && ev[2].start == s3.start && ev[2].end == s3.end, "ev[2] is s3")
	}

	gloaming.disk_store_close(ds)
	_, ds2, rerr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr == gloaming.Store_Err.None, "reopen: %v", rerr)
	defer gloaming.disk_store_close(ds2)
	testing.expect_value(t, len(ds2.graph.relations), 1)
	ev2 := ds2.graph.relations[0].evidence
	testing.expectf(t, len(ev2) == 3, "reopen evidence set: %d spans, want 3", len(ev2))
	if len(ev2) == 3 {
		testing.expectf(t, ev2[0].start == 0 && ev2[1].start == 4 && ev2[2].start == 1,
			"reopen keeps first-seen order")
	}
}

// graph_entity_merge is one
// record-store transaction — mentions re-point, incident relations
// re-point (self-loops die, identity collisions fold evidence into the
// lower id), names re-map — and a torn merge batch repairs to the
// pre-merge state, never half of it.
@(test)
merge_transactionality :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	dir := "tmp/glr-merge"
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, a)
	pay, _ := os.join_path({dir, "payloads.glb"}, a)
	_ = os.remove(reg)
	_ = os.remove(pay)

	_, ds, serr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store_disk: %v", serr)

	asa, e1 := gloaming.graph_entity_add(ds, "person", "アサ", {"あさ"})
	testing.expectf(t, e1 == gloaming.Store_Err.None, "entity 1: %v", e1)
	asa2, e2 := gloaming.graph_entity_add(ds, "person", "朝", nil)
	testing.expectf(t, e2 == gloaming.Store_Err.None, "entity 2: %v", e2)
	kiri, e3 := gloaming.graph_entity_add(ds, "person", "霧", nil)
	testing.expectf(t, e3 == gloaming.Store_Err.None, "entity 3: %v", e3)

	// alias as its own transaction, and its refusal
	alerr := gloaming.graph_entity_alias(ds, kiri, "きり")
	testing.expectf(t, alerr == gloaming.Store_Err.None, "alias: %v", alerr)
	if fid, ok := gloaming.graph_entity_find(&ds.graph, "きり"); !ok || fid != kiri {
		testing.expectf(t, false, "alias find failed")
	}
	dup := gloaming.graph_entity_alias(ds, asa, "霧")
	testing.expect_value(t, int(dup), int(gloaming.Store_Err.Duplicate))

	mrows := []gloaming.Span{
		{doc = 0, start = 0, end = 3},
		{doc = 0, start = 9, end = 12},
		{doc = 0, start = 3, end = 6},
	}
	for m in mrows {
		owner := m.start == 3 ? asa2 : asa
		_, me := gloaming.graph_mention_add(ds, owner, m)
		testing.expectf(t, me == gloaming.Store_Err.None, "mention: %v", me)
	}

	// r0: アサ–朝 (a self-loop once merged, dies) · r1: アサ–霧 · r2:
	// 朝–霧 (re-points onto r1's identity, folds in) · r3: curated
	_, re0 := gloaming.graph_relation_add(ds, "codes", asa, asa2,
		{{doc = 0, start = 0, end = 3}, {doc = 0, start = 9, end = 12}}, true)
	testing.expectf(t, re0 == gloaming.Store_Err.None, "r0: %v", re0)
	_, re1 := gloaming.graph_relation_add(ds, "codes", asa, kiri,
		{{doc = 0, start = 0, end = 6}}, true)
	testing.expectf(t, re1 == gloaming.Store_Err.None, "r1: %v", re1)
	_, re2 := gloaming.graph_relation_add(ds, "codes", asa2, kiri,
		{{doc = 0, start = 3, end = 9}}, true)
	testing.expectf(t, re2 == gloaming.Store_Err.None, "r2: %v", re2)
	_, re3 := gloaming.graph_relation_add(ds, "codes", asa, kiri,
		{{doc = 0, start = 1, end = 2}}, false)
	testing.expectf(t, re3 == gloaming.Store_Err.None, "r3: %v", re3)
	testing.expect_value(t, len(ds.graph.relations), 4)

	pre_merge := ds.log_end
	merr := gloaming.graph_entity_merge(ds, asa, asa2)
	testing.expectf(t, merr == gloaming.Store_Err.None, "merge: %v", merr)

	// memory state, whole: 朝 answers to アサ, every mention is アサ's,
	// r0 and r2 are dead, r1 holds both derived spans in id order
	if fid, ok := gloaming.graph_entity_find(&ds.graph, "朝"); !ok || fid != asa {
		testing.expectf(t, false, "朝 does not answer to the merged entity")
	}
	testing.expectf(t, !ds.graph.entities[int(asa2)].live, "absorbed entity tombstoned")
	testing.expectf(t, len(ds.graph.mentions) == 3, "mentions kept")
	for m in ds.graph.mentions {
		testing.expectf(t, m.entity == asa, "mention re-pointed")
	}
	testing.expectf(t, !ds.graph.relations[0].live, "r0 self-loop dropped")
	r1 := &ds.graph.relations[1]
	testing.expectf(t, r1.live && len(r1.evidence) == 2 &&
		r1.evidence[0].start == 0 && r1.evidence[1].start == 3,
		"r1 folded r2's evidence in id order")
	testing.expectf(t, !ds.graph.relations[2].live, "r2 folded away")
	r3 := &ds.graph.relations[3]
	testing.expectf(t, r3.live && !r3.derived && len(r3.evidence) == 1, "r3 untouched")

	gloaming.disk_store_close(ds)

	// durability: the committed merge rebuilds identically
	_, ds2, rerr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr == gloaming.Store_Err.None, "reopen: %v", rerr)
	testing.expectf(t, !ds2.graph.entities[int(asa2)].live &&
		len(ds2.graph.relations[1].evidence) == 2, "merge durable")
	gloaming.disk_store_close(ds2)

	// atomicity: a torn merge batch repairs to the pre-merge state —
	// cut mid-frame inside the batch, nothing of the merge survives
	f, oerr := os.open(reg, {.Read, .Write}, os.Permissions_Default_File)
	testing.expectf(t, oerr == nil, "open registry: %v", oerr)
	terr := os.truncate(f, pre_merge + 20)
	testing.expectf(t, terr == nil, "truncate: %v", terr)
	os.close(f)

	_, ds3, rerr3 := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr3 == gloaming.Store_Err.None, "reopen torn: %v", rerr3)
	defer gloaming.disk_store_close(ds3)
	testing.expectf(t, ds3.graph.entities[int(asa2)].live, "朝 live again")
	if fid, ok := gloaming.graph_entity_find(&ds3.graph, "朝"); !ok || fid != asa2 {
		testing.expectf(t, false, "朝 answers to itself again")
	}
	testing.expectf(t, len(ds3.graph.mentions) == 3 &&
		ds3.graph.mentions[2].entity == asa2, "mentions pre-merge")
	testing.expectf(t, ds3.graph.relations[0].live &&
		len(ds3.graph.relations[0].evidence) == 2, "r0 whole")
	testing.expectf(t, ds3.graph.relations[2].live &&
		len(ds3.graph.relations[2].evidence) == 1, "r2 whole")

	// the deeper cut: redo the merge on the repaired store, then tear
	// the batch at its midpoint — inside some record's body, not the
	// shallow first frames the +20 cut hits
	merr2 := gloaming.graph_entity_merge(ds3, asa, asa2)
	testing.expectf(t, merr2 == gloaming.Store_Err.None, "re-merge: %v", merr2)
	mid := pre_merge + (ds3.log_end - pre_merge) / 2
	gloaming.disk_store_close(ds3)
	f2, oerr2 := os.open(reg, {.Read, .Write}, os.Permissions_Default_File)
	testing.expectf(t, oerr2 == nil, "open registry: %v", oerr2)
	terr2 := os.truncate(f2, mid)
	testing.expectf(t, terr2 == nil, "truncate mid: %v", terr2)
	os.close(f2)

	_, ds4, rerr4 := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr4 == gloaming.Store_Err.None, "reopen mid-torn: %v", rerr4)
	defer gloaming.disk_store_close(ds4)
	testing.expectf(t, ds4.graph.entities[int(asa2)].live, "mid-torn: 朝 live again")
	if fid, ok := gloaming.graph_entity_find(&ds4.graph, "朝"); !ok || fid != asa2 {
		testing.expectf(t, false, "mid-torn: 朝 answers to itself again")
	}
	testing.expectf(t, len(ds4.graph.mentions) == 3 &&
		ds4.graph.mentions[2].entity == asa2, "mid-torn: mentions pre-merge")
	testing.expectf(t, ds4.graph.relations[0].live &&
		len(ds4.graph.relations[0].evidence) == 2, "mid-torn: r0 whole")
	testing.expectf(t, ds4.graph.relations[2].live &&
		len(ds4.graph.relations[2].evidence) == 1, "mid-torn: r2 whole")
}

// bounded traversal: depth and frontier caps, kind filters, the
// deterministic cut, the refusals — and the same answers from a
// rebuilt (reopened) graph.
@(test)
graph_traverse_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	dir := "tmp/glr-trav"
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, a)
	pay, _ := os.join_path({dir, "payloads.glb"}, a)
	_ = os.remove(reg)
	_ = os.remove(pay)

	fmt_visits :: proc(v: []gloaming.Visit, a: mem.Allocator) -> string {
		b := strings.builder_make(a)
		for x, i in v {
			if i > 0 { strings.write_string(&b, " ") }
			fmt.sbprintf(&b, "%d:%d", int(x.entity), x.depth)
		}
		return strings.to_string(b)
	}

	_, ds, serr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store_disk: %v", serr)

	n: [5]gloaming.Entity_Id
	names := [5]string{"A", "B", "C", "D", "E"}
	for i in 0..<5 {
		id, e := gloaming.graph_entity_add(ds, "term", names[i], nil)
		testing.expectf(t, e == gloaming.Store_Err.None, "add %s: %v", names[i], e)
		n[i] = id
	}
	ev := []gloaming.Span{{doc = 0, start = 0, end = 1}}
	// link: A–B, B–C, C–D (a chain) and C→E (high→low, for the
	// undirected proof below) · weak: A–E
	_, _ = gloaming.graph_relation_add(ds, "link", n[0], n[1], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "link", n[1], n[2], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "link", n[2], n[3], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "link", n[2], n[4], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "weak", n[0], n[4], ev, true)

	// depth 2 from A: A + (B, E) + C — D sits past the depth cap
	res, terr := gloaming.graph_traverse(&ds.graph, {n[0]}, {}, 2, 10, a)
	testing.expectf(t, terr == gloaming.Graph_Err.None, "traverse: %v", terr)
	testing.expectf(t, !res.truncated && fmt_visits(res.visits, a) == "0:0 1:1 4:1 2:2",
		"visits %s (truncated %v)", fmt_visits(res.visits, a), res.truncated)

	// kind filter: the weak edge stays out
	res, terr = gloaming.graph_traverse(&ds.graph, {n[0]}, {"link"}, 2, 10, a)
	testing.expectf(t, terr == gloaming.Graph_Err.None && !res.truncated &&
		fmt_visits(res.visits, a) == "0:0 1:1 2:2",
		"link-only visits %s", fmt_visits(res.visits, a))

	// depth 0: the start set only
	res, terr = gloaming.graph_traverse(&ds.graph, {n[0], n[1]}, {}, 0, 10, a)
	testing.expectf(t, terr == gloaming.Graph_Err.None &&
		fmt_visits(res.visits, a) == "0:0 1:0", "depth-0 visits %s", fmt_visits(res.visits, a))

	// frontier 2: A, B land, E is reachable but capped — truncated
	res, terr = gloaming.graph_traverse(&ds.graph, {n[0]}, {}, 2, 2, a)
	testing.expectf(t, terr == gloaming.Graph_Err.None && res.truncated &&
		fmt_visits(res.visits, a) == "0:0 1:1",
		"capped visits %s (truncated %v)", fmt_visits(res.visits, a), res.truncated)

	// the C→E edge points INTO the start node: only the undirected
	// reading walks it — a directed BFS would strand E at the start
	res, terr = gloaming.graph_traverse(&ds.graph, {n[4]}, {"link"}, 3, 10, a)
	testing.expectf(t, terr == gloaming.Graph_Err.None && !res.truncated &&
		fmt_visits(res.visits, a) == "4:0 2:1 1:2 3:2 0:3",
		"undirected visits %s", fmt_visits(res.visits, a))

	_, xerr := gloaming.graph_traverse(&ds.graph, {gloaming.Entity_Id(99)}, {}, 2, 10, a)
	testing.expect_value(t, int(xerr), int(gloaming.Graph_Err.Not_Found))
	_, xerr = gloaming.graph_traverse(&ds.graph, {n[0]}, {}, 2, 0, a)
	testing.expect_value(t, int(xerr), int(gloaming.Graph_Err.Bad_Budget))

	gloaming.disk_store_close(ds)
	_, ds2, rerr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr == gloaming.Store_Err.None, "reopen: %v", rerr)
	defer gloaming.disk_store_close(ds2)
	res, terr = gloaming.graph_traverse(&ds2.graph, {n[0]}, {}, 2, 10, a)
	testing.expectf(t, terr == gloaming.Graph_Err.None && !res.truncated &&
		fmt_visits(res.visits, a) == "0:0 1:1 4:1 2:2",
		"rebuilt graph traverses the same: %s", fmt_visits(res.visits, a))
}

// The memory store: the ownership contract (the host may destroy
// the source text after add_document — reads stay valid), borrowed
// reads, duplicate/not-found, the docs list, removal.
@(test)
memory_store_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	store, serr := gloaming.store_memory(a)
	if !testing.expectf(t, serr == .None, "store_memory: %v", serr) { return }

	// the source lives in a scratch slice the test scribbles after add
	text := "夜が更ける。"
	buf := make([]u8, len(text), a)
	copy(buf, text)
	toks := make([]gloaming.Token, 4, a)
	off := 0
	for i in 0..<4 {
		surface := transmute(string)buf[off:off + 3]
		toks[i] = gloaming.Token{
			surface = surface,
			lemma   = surface,
			pos     = i == 0 ? "名詞,一般,*,*,*" : (i == 2 ? "動詞,自立,一段,基本形" : (i == 3 ? "記号,句点,*,*,*" : "助詞,格助詞,一般,*,*")),
			reading = "ヨル",
			start   = off,
			end     = off + 3,
			cost    = i16(100 * (i + 1)),
		}
		off += 3
	}
	segs := []gloaming.Segment{
		{kind = .Chapter, span = {doc = 5, start = 0, end = 12}},
	}

	aerr := store.add_document(store.ctx, 5, text, toks, segs)
	testing.expect_value(t, int(aerr), int(gloaming.Store_Err.None))
	derr := store.add_document(store.ctx, 5, text, toks, segs)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Duplicate))

	// host frees the text and the token slice
	for i in 0..<len(buf) { buf[i] = '#' }

	testing.expect(t, store.has(store.ctx, 5))
	testing.expect(t, !store.has(store.ctx, 6))
	docs := store.docs(store.ctx)
	if len(docs) != 1 || int(docs[0]) != 5 {
		testing.expectf(t, false, "docs: got %d entries", len(docs))
	}

	tk, terr := store.tokens(store.ctx, 5, a)
	if !testing.expectf(t, terr == .None, "tokens: %v", terr) { return }
	if len(tk) != 4 {
		testing.expectf(t, false, "tokens: got %d, want 4", len(tk))
		return
	}
	testing.expectf(t, tk[0].surface == "夜", "surface: %q", tk[0].surface)
	testing.expectf(t, tk[0].lemma == "夜", "lemma: %q", tk[0].lemma)
	testing.expectf(t, tk[0].pos == "名詞,一般,*,*,*", "pos: %q", tk[0].pos)
	testing.expectf(t, tk[2].reading == "ヨル", "reading: %q", tk[2].reading)
	testing.expect_value(t, int(tk[3].cost), 400)

	sg, sgerr := store.segments(store.ctx, 5, a)
	if !testing.expectf(t, sgerr == .None, "segments: %v", sgerr) { return }
	if len(sg) != 1 || int(sg[0].span.doc) != 5 || sg[0].span.end != 12 {
		testing.expectf(t, false, "segments: got %d", len(sg))
	}

	_, nf := store.tokens(store.ctx, 9, a)
	testing.expect_value(t, int(nf), int(gloaming.Store_Err.Not_Found))

	rerr := store.remove_document(store.ctx, 5)
	testing.expect_value(t, int(rerr), int(gloaming.Store_Err.None))
	rerr2 := store.remove_document(store.ctx, 5)
	testing.expect_value(t, int(rerr2), int(gloaming.Store_Err.Not_Found))
	testing.expect(t, !store.has(store.ctx, 5))

	// a refused add strands nothing: ranges are validated before any
	// copy is taken. The second store rides a tracking allocator over
	// the temp allocator — the flat line is the assertion.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.temp_allocator)
	ta := mem.tracking_allocator(&track)
	tstore, tserr := gloaming.store_memory(ta)
	if !testing.expectf(t, tserr == .None, "store_memory(ta): %v", tserr) { return }
	baseline := track.current_memory_allocated

	bad := make([]gloaming.Token, 2, a)
	bad[0] = gloaming.Token{surface = "夜", lemma = "夜", pos = "名詞,一般,*,*,*", reading = "ヨル", start = 0, end = 3}
	bad[1] = gloaming.Token{surface = "!", lemma = "!", pos = "記号,句点,*,*,*", reading = "!", start = 3, end = 99}
	brerr := tstore.add_document(tstore.ctx, 7, "夜が更ける。", bad, {})
	testing.expect_value(t, int(brerr), int(gloaming.Store_Err.Bad_Range))
	testing.expectf(t, track.current_memory_allocated == baseline,
		"stranded bytes after refused add: %d",
		int(track.current_memory_allocated - baseline))
	testing.expect(t, !tstore.has(tstore.ctx, 7))

	// the store stays functional after the refusal
	orerr := tstore.add_document(tstore.ctx, 7, "夜が更ける。", bad[:1], {})
	testing.expect_value(t, int(orerr), int(gloaming.Store_Err.None))
	testing.expect(t, tstore.has(tstore.ctx, 7))
	mem.tracking_allocator_destroy(&track)
}

// Fuzzy unit side: fold range boundaries and a hand-computed
// distance matrix at n ∈ 1..3, folded with the default flags, plus
// the transposition dial.
@(test)
fuzzy_folds_and_distances :: proc(t: ^testing.T) {
	flags := gloaming.FUZZY_FLAGS_DEFAULT
	buf: [64]rune

	fold_check :: proc(t: ^testing.T, flags: gloaming.Fuzzy_Flags, buf: []rune, s: string, want: string, label: string) {
		got := gloaming.fold_runes(s, buf, flags)
		if !runes_eq(got, want) {
			testing.expectf(t, false, "fold %s: got %d runes, want %q", label, len(got), want)
		}
	}
	fold_check(t, flags, buf[:], "ＡＢＣ", "ABC", "width FF21-FF23")
	fold_check(t, flags, buf[:], "！", "!", "width FF01")
	fold_check(t, flags, buf[:], "～", "~", "width FF5E")
	fold_check(t, flags, buf[:], "　", " ", "U+3000")
	fold_check(t, flags, buf[:], "アブ", "あぶ", "kana 30A2/30D6")
	fold_check(t, flags, buf[:], "ャュョ", "ゃゅょ", "kana 30E3-30E7")
	fold_check(t, flags, buf[:], "ー。", "ー。", "長音 and punctuation unchanged")
	fold_check(t, flags, buf[:], "かな", "かな", "hiragana passes through")

	// (a, b, expected Damerau-OSA distance over folded runes); note
	// シスデモ differs from システム in two positions (テ→デ, ム→モ)
	cases := []struct{a: string, b: string, d: int}{
		{a = "システム",   b = "システム",   d = 0},
		{a = "システム",   b = "システモ",   d = 1},
		{a = "システム",   b = "シスデモ",   d = 2},
		{a = "システム",   b = "シスデモム", d = 2},
		{a = "かな",       b = "カナ",       d = 0}, // kana fold
		{a = "ＡＢＣ",     b = "ABC",       d = 0}, // width fold
		{a = "アブ",       b = "ブア",       d = 1}, // transposition
		{a = "開く",       b = "開いた",     d = 2},
		{a = "夜",         b = "夜鳴く",     d = 2},
		{a = "シス",       b = "システムシステム", d = 6}, // early len exit
	}
	ra: [64]rune
	rb: [64]rune
	for c in cases {
		fa := gloaming.fold_runes(c.a, ra[:], flags)
		fb := gloaming.fold_runes(c.b, rb[:], flags)
		for n in 1..<4 {
			want := c.d <= n
			got := gloaming.fuzzy_within(fa, fb, n, true)
			if got != want {
				testing.expectf(t, false, "within(%q, %q, n=%d, t): got %v, want %v (d=%d)",
					c.a, c.b, n, got, want, c.d)
			}
		}
	}
	// transposition off: アブ/ブア costs 2, not 1
	fa := gloaming.fold_runes("アブ", ra[:], flags)
	fb := gloaming.fold_runes("ブア", rb[:], flags)
	testing.expect(t, !gloaming.fuzzy_within(fa, fb, 1, false))
	testing.expect(t, gloaming.fuzzy_within(fa, fb, 2, false))

	// past the inline width (64): equality must see the whole string, not
	// a shared 64-rune prefix — the scratch grows on its allocator
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// n copies of one rune, as UTF-8 bytes
	rep :: proc(rune_str: string, n: int, a: mem.Allocator) -> string {
		out := make([]u8, n * len(rune_str), a)
		for i in 0..<n { copy(out[i * len(rune_str):(i + 1) * len(rune_str)], rune_str) }
		return string(out)
	}
	val65 := rep("ア", 65, a)
	pat65_bytes := make([]u8, 65 * 3, a)
	for i in 0..<64 { copy(pat65_bytes[i * 3:(i + 1) * 3], "ア") }
	copy(pat65_bytes[64 * 3:], "イ") // differs only past the old truncation point
	pat65 := string(pat65_bytes)

	fs: gloaming.Fuzzy_Scratch
	gloaming.fuzzy_scratch_init(&fs, a)
	defer gloaming.fuzzy_scratch_destroy(&fs)

	fv := gloaming.fold_value(&fs, val65, flags)
	fp := gloaming.fold_pattern(&fs, pat65, flags)
	testing.expect_value(t, len(fv), 65) // the whole string folded, heap-grown
	testing.expect_value(t, len(fp), 65)
	testing.expect(t, !gloaming.fuzzy_within(fv, fp, 0, true)) // distance is 1, not 0
	testing.expect(t, gloaming.fuzzy_within(fv, fp, 1, true))

	// 70 runes vs 65 sharing the prefix: true distance ≥ 5 — within no
	// fuzzy distance (FUZZY_DIST_MAX is 3)
	val70 := rep("ア", 70, a)
	fv70 := gloaming.fold_value(&fs, val70, flags)
	testing.expect(t, !gloaming.fuzzy_within(fv70, fp, 3, true))

	// identical 70-rune strings: the wide DP rows path (past the inline
	// width) still answers exactly
	testing.expect(t, gloaming.fuzzy_within(fv70, fv70, 0, true))
	fb70 := gloaming.fold_pattern(&fs, rep("ア", 69, a), flags)
	testing.expect(t, gloaming.fuzzy_within(fv70, fb70, 1, true))
	testing.expect(t, !gloaming.fuzzy_within(fv70, fb70, 0, true))
}

// compound error taxonomy + a two-merge pass; the projection
// fields live in the fixture table above.
@(test)
compound_errors_and_two_merges :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	text := "アイウエ"
	toks := make([]gloaming.Token, 4, a)
	for i in 0..<4 {
		s := text[i * 3:i * 3 + 3]
		toks[i] = gloaming.Token{
			surface = s,
			lemma   = s,
			pos     = "名詞,一般,*,*,*",
			reading = "x",
			start   = i * 3,
			end     = i * 3 + 3,
			cost    = 10,
		}
	}

	// overlapping
	_, oerr := gloaming.compound(toks, text, []gloaming.Match{
		{start = 1, end = 3},
		{start = 2, end = 4},
	}, a)
	testing.expect_value(t, int(oerr), int(gloaming.Compound_Err.Overlap))

	// interleaved (unsorted but disjoint) is a precondition failure too
	_, ierr := gloaming.compound(toks, text, []gloaming.Match{
		{start = 2, end = 4},
		{start = 0, end = 1},
	}, a)
	testing.expect_value(t, int(ierr), int(gloaming.Compound_Err.Overlap))

	// token range outside the stream; empty range; bytes past the text
	_, rerr := gloaming.compound(toks, text, []gloaming.Match{{start = 0, end = 9}}, a)
	testing.expect_value(t, int(rerr), int(gloaming.Compound_Err.Bad_Range))
	_, eerr := gloaming.compound(toks, text, []gloaming.Match{{start = 1, end = 1}}, a)
	testing.expect_value(t, int(eerr), int(gloaming.Compound_Err.Bad_Range))
	long := []gloaming.Token{
		{surface = "ア", lemma = "ア", start = 0, end = 3},
		{surface = "イ", lemma = "イ", start = 3, end = 12},
	}
	_, terr := gloaming.compound(long, "アイウ", []gloaming.Match{{start = 0, end = 2}}, a)
	testing.expect_value(t, int(terr), int(gloaming.Compound_Err.Bad_Range))

	// two merges in one pass: [0,2) and [2,4) with i16 saturation room
	out, merr := gloaming.compound(toks, text, []gloaming.Match{
		{start = 0, end = 2},
		{start = 2, end = 4},
	}, a)
	if !testing.expectf(t, merr == .None, "two merges: %v", merr) { return }
	if len(out) != 2 {
		testing.expectf(t, false, "two merges: got %d tokens, want 2", len(out))
		return
	}
	testing.expectf(t, out[0].surface == "アイ", "merge 1 surface: %q", out[0].surface)
	testing.expect_value(t, out[0].start, 0)
	testing.expect_value(t, out[0].end, 6)
	testing.expect_value(t, int(out[0].cost), 20)
	testing.expect_value(t, out[0].entry_id, -1) // synthesized: no dictionary row
	testing.expect_value(t, int(out[0].kind), int(gloaming.Token_Kind.Idless))
	testing.expectf(t, out[1].lemma == "ウエ", "merge 2 lemma: %q", out[1].lemma)
	testing.expect_value(t, int(out[1].cost), 20)
	testing.expect_value(t, out[1].entry_id, -1)
}

// fold output vs a UTF-8 literal, no allocation
runes_eq :: proc(runes: []rune, want: string) -> bool {
	i := 0
	for r in runes {
		wr, size := utf8.decode_rune_in_string(want[i:])
		if r != wr { return false }
		i += size
	}
	return i == len(want)
}

// --- GLB1 payload ---

// the hand dictionary behind the GLB1 tests: the resolver returns the
// strings a producing tokenizer would have, applying the surface
// fallback for id 7 (its entry lemma is "*") — the adapter's duty,
// rehearsed here
payload_test_resolver :: proc(ctx: rawptr, id: i32, surface: string) ->
		(pos, lemma, reading: string, ok: bool) {
	_ = ctx
	switch id {
	case 3:  return "助詞,格助詞,一般,*,*",   "が",     "ガ",     true
	case 5:  return "記号,句点,*,*,*",       "。",     "*",      true
	case 7:  return "名詞,一般,*,*,*",       surface,  "ヨル",   true
	case 12: return "動詞,自立,一段,基本形",  "更ける", "フケル", true
	}
	return "", "", "", false
}

payload_test_resolver_none :: proc(ctx: rawptr, id: i32, surface: string) ->
		(pos, lemma, reading: string, ok: bool) {
	_ = ctx
	_ = id
	_ = surface
	return "", "", "", false
}

@(test)
payload_roundtrip :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the on-disk layout constants, asserted where a drift fails loudly
	testing.expect_value(t, int(size_of(gloaming.Payload_Header)), 48)
	testing.expect_value(t, int(size_of(gloaming.Payload_Rec)), 16)

	// 夜[0,3) が[3,6) 更ける[6,15) 。[15,18) ヴュウ[18,27) — four
	// dictionary rows (id 7's entry lemma is "*": the resolver applies
	// the surface fallback), one unknown exercising the tail, and one
	// id-less known token — what compound() emits for 夜が — exercising
	// the bit-17 record and its two tail strings
	text := "夜が更ける。ヴュウ"
	toks := []gloaming.Token{
		{surface = "夜",     lemma = "夜",     pos = "名詞,一般,*,*,*",       reading = "ヨル",   start = 0,  end = 3,  cost = 100, kind = .Dictionary, entry_id = 7},
		{surface = "が",     lemma = "が",     pos = "助詞,格助詞,一般,*,*", reading = "ガ",     start = 3,  end = 6,  cost = 50,  kind = .Dictionary, entry_id = 3},
		{surface = "更ける", lemma = "更ける", pos = "動詞,自立,一段,基本形", reading = "フケル", start = 6,  end = 15, cost = 300, kind = .Dictionary, entry_id = 12},
		{surface = "。",     lemma = "。",     pos = "記号,句点,*,*,*",     reading = "*",      start = 15, end = 18, cost = 20,  kind = .Dictionary, entry_id = 5},
		{surface = "ヴュウ", lemma = "ヴュウ", pos = "名詞,固有名詞,一般,*,*", reading = "*",     start = 18, end = 27, cost = 4000, kind = .Unknown, entry_id = -1},
		{surface = "夜が",   lemma = "夜が",   pos = "名詞,一般,*,*,*",       reading = "ヨルガ", start = 0,  end = 6,  cost = 150, kind = .Idless, entry_id = -1},
	}
	key := gloaming.Payload_Key{text_hash = 0xDEADBEEFCAFEBABE, dict_version = 0x1234567890ABCDEF, options = 7}

	blob, berr := gloaming.payload_encode(key, text, toks, a)
	if !testing.expectf(t, berr == .None, "payload_encode: %v", berr) { return }
	// 48 header + 6 records + unknown pos (2 + 30 B) + id-less pos and
	// reading (2 + 19 B and 2 + 9 B)
	testing.expect_value(t, len(blob), 48 + 6 * 16 + (2 + 30) + (2 + 19) + (2 + 9))

	dec, derr := gloaming.payload_decode(blob, text, payload_test_resolver, nil, a)
	if !testing.expectf(t, derr == .None, "payload_decode: %v", derr) { return }
	if !testing.expect_value(t, len(dec), len(toks)) { return }
	for w, i in toks {
		d := dec[i]
		testing.expectf(t, d.surface == w.surface && d.lemma == w.lemma &&
			d.pos == w.pos && d.reading == w.reading &&
			d.start == w.start && d.end == w.end &&
			d.kind == w.kind && d.cost == w.cost &&
			d.entry_id == w.entry_id,
			"token %d differs: %+v vs %+v", i, d, w)
	}

	// the key survives in the header — the host's refusal path before
	// decoding against a renumbered dictionary
	gk, kerr := gloaming.payload_key(blob)
	if !testing.expectf(t, kerr == .None, "payload_key: %v", kerr) {
		return
	}
	testing.expect_value(t, gk.text_hash, key.text_hash)
	testing.expect_value(t, gk.dict_version, key.dict_version)
	testing.expect_value(t, gk.options, key.options)

	// a different text is a caller bug, reported — never sliced garbage
	_, werr := gloaming.payload_decode(blob, "夜が更ける。ヴュ", payload_test_resolver, nil, a)
	testing.expect_value(t, int(werr), int(gloaming.Store_Err.Bad_Range))

	// malformed: magic, version, and the size identity
	blob[1] = 'X'
	_, merr := gloaming.payload_header(blob)
	testing.expect_value(t, int(merr), int(gloaming.Store_Err.Malformed))
	blob[1] = 'L' // restore
	_, verr := gloaming.payload_decode(blob, text, payload_test_resolver, nil, a)
	testing.expect_value(t, int(verr), int(gloaming.Store_Err.None))
	blob[4] = 1 // v1: same geometry, and its encoders could not emit bit-17 records
	_, v1err := gloaming.payload_header(blob)
	testing.expect_value(t, int(v1err), int(gloaming.Store_Err.None))
	blob[4] = 3
	_, merr2 := gloaming.payload_header(blob)
	testing.expect_value(t, int(merr2), int(gloaming.Store_Err.Malformed))
	blob[4] = 2 // restore the encoder's version
	_, merr3 := gloaming.payload_header(blob[:len(blob) - 1])
	testing.expect_value(t, int(merr3), int(gloaming.Store_Err.Malformed))

	// an id the resolver rejects — the stale/foreign-dictionary shape
	_, nerr := gloaming.payload_decode(blob, text, payload_test_resolver_none, nil, a)
	testing.expect_value(t, int(nerr), int(gloaming.Store_Err.Not_Found))

	// encode contract: ranges inside text; kind and entry_id agree
	bad_range := make([]gloaming.Token, len(toks), a)
	copy(bad_range, toks)
	bad_range[0] = {surface = "夜", start = 0, end = 40, entry_id = 7, cost = 100}
	_, rerr := gloaming.payload_encode(key, text, bad_range, a)
	testing.expect_value(t, int(rerr), int(gloaming.Store_Err.Bad_Range))

	bad_pair := make([]gloaming.Token, len(toks), a)
	copy(bad_pair, toks)
	bad_pair[4].entry_id = 5 // unknown with a dictionary row
	_, perr := gloaming.payload_encode(key, text, bad_pair, a)
	testing.expect_value(t, int(perr), int(gloaming.Store_Err.Malformed))
	bad_pair2 := make([]gloaming.Token, len(toks), a)
	copy(bad_pair2, toks)
	bad_pair2[0].entry_id = -2 // below the id-less sentinel -1 — unresolvable
	_, perr2 := gloaming.payload_encode(key, text, bad_pair2, a)
	testing.expect_value(t, int(perr2), int(gloaming.Store_Err.Malformed))

	// the GLBZ distribution wrapper: byte-exact unwrapping
	z, zerr := gloaming.payload_compress(blob, a)
	if !testing.expectf(t, zerr == .None, "payload_compress: %v", zerr) { return }
	testing.expectf(t, len(z) < len(blob), "wrapper shrank nothing on repetitive records: %d vs %d", len(z), len(blob))
	raw, drerr := gloaming.payload_decompress(z, a)
	if !testing.expectf(t, drerr == .None, "payload_decompress: %v", drerr) { return }
	testing.expectf(t, string(raw) == string(blob), "unwrapped bytes differ")

	// corrupt wrapper: magic, truncation, and a raw-length lie
	z[0] = 'X'
	_, zm := gloaming.payload_decompress(z, a)
	testing.expect_value(t, int(zm), int(gloaming.Store_Err.Malformed))
	z[0] = 'G'
	_, zt := gloaming.payload_decompress(z[:5], a)
	testing.expect_value(t, int(zt), int(gloaming.Store_Err.Malformed))
	z[4] = u8(z[4] + 1) // raw-length lie — decode must refuse, not truncate
	_, zl := gloaming.payload_decompress(z, a)
	testing.expect_value(t, int(zl), int(gloaming.Store_Err.Malformed))
	z[4] -= 1 // restore
}

@(test)
deflate_streams :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the empty stream: the codec's degenerate block survives the wrapper.
	// Compress scratch (~0.5 MiB LZ77 state + ~8 B/input byte, held until
	// arena_free_all) rides the temp allocator so the 1 MiB test arena
	// never has to absorb three rounds of it
	empty, eerr := gloaming.payload_compress([]u8{}, context.temp_allocator)
	if !testing.expectf(t, eerr == .None, "compress empty: %v", eerr) { return }
	back, berr := gloaming.payload_decompress(empty, a)
	if testing.expectf(t, berr == .None, "decompress empty: %v", berr) {
		testing.expect_value(t, len(back), 0)
	}

	// text-like repetition: compresses hard, unwraps byte-exact
	text := strings.repeat("夜が更ける。夜が更ける。夜が更ける。", 60, a)
	z, zerr := gloaming.payload_compress(transmute([]u8)text, context.temp_allocator)
	if !testing.expectf(t, zerr == .None, "compress text: %v", zerr) { return }
	testing.expectf(t, len(z) < len(text) / 4, "repetitive text compressed poorly: %d vs %d", len(z), len(text))
	raw, rerr := gloaming.payload_decompress(z, a)
	if !testing.expectf(t, rerr == .None, "decompress text: %v", rerr) { return }
	testing.expectf(t, string(raw) == text, "text bytes differ after roundtrip")

	// pseudo-random bytes (LCG): no LZ matches, still byte-exact —
	// the literal path and the Kraft repair both get exercised
	rnd := make([]u8, 4096, a)
	x: u32 = 0x1234_5678
	for i in 0..<len(rnd) {
		x = x * 1664525 + 1013904223
		rnd[i] = u8(x >> 24)
	}
	zr, zrerr := gloaming.payload_compress(rnd, context.temp_allocator)
	if !testing.expectf(t, zrerr == .None, "compress random: %v", zrerr) { return }
	rawr, rrerr := gloaming.payload_decompress(zr, a)
	if !testing.expectf(t, rrerr == .None, "decompress random: %v", rrerr) { return }
	testing.expectf(t, string(rawr) == string(rnd), "random bytes differ after roundtrip")

	// length-limited codes must stay canonically valid on adversarial
	// frequency shapes — the exact integer criterion the inflater applies
	// (a tolerance-based Kraft check admits stray 15-bit codes; the
	// integer criterion catches them)
	check_canonical :: proc(lengths: []u8, max_symbol: int) -> bool {
		sizes: [16]int
		for v in lengths { if int(v) <= 15 { sizes[v] += 1 } }
		code := 0
		for i in 1..=15 {
			code += sizes[i]
			if sizes[i] != 0 && code - 1 >= (1 << u32(i)) { return false }
			code <<= 1
		}
		return true
	}
	shapes := [][]int{
		{1 << 20, 1 << 19},                                                             // two giants, the rest 1: the oversubscription shape
		{1, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610}, // Fibonacci skew
		{1 << 10, 1 << 9, 1 << 8, 1 << 7, 1 << 6, 1 << 5, 1 << 4, 1 << 3, 1 << 2, 1 << 1, 1},
		{7, 7, 7, 7}, // uniform small
	}
	for shape in shapes {
		freqs: [286]int
		for j in 0..<286 { freqs[j] = 1 } // no zero frequencies: every symbol active
		for v, j in shape { freqs[j] = v }
		lens := gloaming.huffman_compute_lengths(freqs[:], gloaming.DEFLATE_MAX_LIT, 15)
		testing.expect(t, check_canonical(lens[:], gloaming.DEFLATE_MAX_LIT),
			"adversarial freq shape produced an over-subscribed literal code")
	}
}

// --- GLR1 record log + disk store ---

// cat: exact-size arena concatenation, no context-allocator append
rec_cat :: proc(a: mem.Allocator, parts: []([]u8)) -> []u8 {
	n := 0
	for p in parts { n += len(p) }
	out := make([]u8, n, a)
	off := 0
	for p in parts {
		copy(out[off:], p)
		off += len(p)
	}
	return out
}

rec_copy :: proc(src: []u8, a: mem.Allocator) -> []u8 {
	out := make([]u8, len(src), a)
	copy(out, src)
	return out
}

@(test)
reclog_frames :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	testing.expect_value(t, gloaming.RECLOG_HEADER_SIZE, 8)
	testing.expect_value(t, gloaming.REC_FRAME_FIXED, 13)
	testing.expect_value(t, gloaming.REC_SEG_SIZE, 12)

	// one file, four batches: empty commit, two docs, version+remove,
	// a third doc — exercising every v1 kind a writer can produce
	hdr := make([]u8, 8, a)
	copy(hdr[0:4], "GLR1")
	gloaming.pl_put_u32(hdr, 4, 1)

	segs1 := []gloaming.Segment{
		{kind = .Chapter,   span = {doc = 1, start = 0, end = 9}},
		{kind = .Paragraph, span = {doc = 1, start = 0, end = 9}},
	}
	b1 := gloaming.rec_batch(nil, a) // count-0 commit is a legal no-op
	b2 := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Doc, body = gloaming.rec_doc_body(1,
			{ text_hash = 1, dict_version = 11, options = 0 }, 0, 100, "あいう", segs1)},
		{kind = .Doc, body = gloaming.rec_doc_body(2,
			{ text_hash = 2, dict_version = 11, options = 0 }, 100, 50, "えお", nil)},
	}, a)
	b3 := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Version, body = gloaming.rec_doc_body(1,
			{ text_hash = 3, dict_version = 11, options = 0 }, 150, 90, "あいうえ", nil)},
		{kind = .Remove, body = gloaming.rec_remove_body(2)},
	}, a)
	b4 := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Doc, body = gloaming.rec_doc_body(3,
			{ text_hash = 4, dict_version = 11, options = 0 }, 240, 10, "か", nil)},
	}, a)
	file := rec_cat(a, {hdr, b1, b2, b3, b4})

	scan, serr := gloaming.reclog_scan(file, a)
	if !testing.expectf(t, serr == .None, "clean scan: %v", serr) { return }
	testing.expect_value(t, len(scan.docs), 2) // 1 (versioned) and 3; 2 removed
	testing.expect_value(t, scan.applied, len(file))
	testing.expect(t, !scan.torn, "clean scan must not report a torn tail")

	d1, ok := scan.docs[1]
	if !testing.expect(t, ok, "doc 1 missing") { return }
	testing.expectf(t, d1.text == "あいうえ", "versioned text: %q", d1.text)
	testing.expect_value(t, d1.payload_off, 150)
	testing.expect_value(t, d1.payload_len, 90)
	testing.expect_value(t, int(d1.key.text_hash), 3)

	if _, live := scan.docs[2]; live {
		testing.expect(t, false, "doc 2 must be removed")
	}
	d3, ok3 := scan.docs[3]
	if !testing.expect(t, ok3, "doc 3 missing") { return }
	testing.expectf(t, d3.text == "か", "doc 3 text: %q", d3.text)

	// re-adding a live doc inside a fresh committed batch is damage
	dup := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Doc, body = gloaming.rec_doc_body(1,
			{ text_hash = 9, dict_version = 11, options = 0 }, 0, 1, "x", nil)},
	}, a)
	_, derr := gloaming.reclog_scan(rec_cat(a, {hdr, b2, dup}), a)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Malformed))

	// --- corruption legs: complete-but-wrong frames refuse ---
	bad := rec_copy(file, a)
	bad[0] = 88 // magic
	_, merr := gloaming.reclog_scan(bad, a)
	testing.expect_value(t, int(merr), int(gloaming.Store_Err.Malformed))

	bad = rec_copy(file, a)
	gloaming.pl_put_u32(bad, 4, gloaming.RECLOG_VERSION + 1) // version from the future
	_, verr := gloaming.reclog_scan(bad, a)
	testing.expect_value(t, int(verr), int(gloaming.Store_Err.Malformed))

	bad = rec_copy(file, a)
	bad[len(bad) - 1] = bad[len(bad) - 1] ~ 0xFF // a committed frame's check field
	_, cerr := gloaming.reclog_scan(bad, a)
	testing.expect_value(t, int(cerr), int(gloaming.Store_Err.Malformed))

	bad = rec_copy(file, a)
	bad[80] = bad[80] ~ 0xFF // a byte inside batch 2's first Doc body (check covers it)
	_, ferr := gloaming.reclog_scan(bad, a)
	testing.expect_value(t, int(ferr), int(gloaming.Store_Err.Malformed))

	// kind numbers with a valid check, refused at the kind gate — the
	// reason the check is computed by hand: 6 is unassigned, 20 past
	// the curation block
	res := make([]u8, 13, a)
	res[0] = 6
	gloaming.pl_put_u64(res, 5, hash.fnv64a(res[0:5]))
	_, rerr := gloaming.reclog_scan(rec_cat(a, {file, res}), a)
	testing.expect_value(t, int(rerr), int(gloaming.Store_Err.Malformed))

	res = make([]u8, 13, a)
	res[0] = 20
	gloaming.pl_put_u64(res, 5, hash.fnv64a(res[0:5]))
	_, rerr2 := gloaming.reclog_scan(rec_cat(a, {file, res}), a)
	testing.expect_value(t, int(rerr2), int(gloaming.Store_Err.Malformed))

	// a curation kind (16, Entity's number) outside any batch is still
	// damage — only Begin opens a batch
	res = make([]u8, 13, a)
	res[0] = 16
	gloaming.pl_put_u64(res, 5, hash.fnv64a(res[0:5]))
	_, rerr3 := gloaming.reclog_scan(rec_cat(a, {file, res}), a)
	testing.expect_value(t, int(rerr3), int(gloaming.Store_Err.Malformed))

	// --- replay invariants: what the writers refuse, the replay must
	// refuse too (crafted batches with valid checks, v2 header) ---
	hdr2 := make([]u8, 8, a)
	copy(hdr2[0:4], "GLR1")
	gloaming.pl_put_u32(hdr2, 4, gloaming.RECLOG_VERSION)

	// the allocation bomb: an Entity body declaring ~4e9 aliases for a
	// few bytes of body — the bound check must refuse before any make
	bomb := rec_cat(a, {
		[]u8{0, 0, 0, 0, 1, 0, 0, 0}, // id 0, live
		[]u8{4, 0, 0, 0, 't', 'e', 'r', 'm'}, // kind "term"
		[]u8{3, 0, 0, 0, 'a', 'b', 'c'}, // name "abc"
		[]u8{0xF0, 0xFF, 0xFF, 0xFF}, // alias count 0xFFFFFFF0
	})
	bbomb := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Entity, body = bomb},
	}, a)
	_, bomberr := gloaming.reclog_scan(rec_cat(a, {hdr2, bbomb}), a)
	testing.expect_value(t, int(bomberr), int(gloaming.Store_Err.Malformed))

	// a live relation with from == to: graph_relation_add refuses it
	selfent := gloaming.rec_entity_body(gloaming.Entity{
		id = 0, live = true, name = "X",
	}, "term")
	selfrel := gloaming.rec_relation_body(gloaming.Relation{
		id = 0, live = true, from = 0, to = 0, derived = true,
	}, "codes")
	bself := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Entity, body = selfent},
		{kind = .Relation, body = selfrel},
	}, a)
	_, selferr := gloaming.reclog_scan(rec_cat(a, {hdr2, bself}), a)
	testing.expect_value(t, int(selferr), int(gloaming.Store_Err.Malformed))

	// two live entities claiming one name: the writers' uniqueness
	bdupname := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 0, live = true, name = "X",
		}, "term")},
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 1, live = true, name = "X",
		}, "term")},
	}, a)
	_, dupnerr := gloaming.reclog_scan(rec_cat(a, {hdr2, bdupname}), a)
	testing.expect_value(t, int(dupnerr), int(gloaming.Store_Err.Malformed))

	// a tombstone for a row that never existed mints a dead row — refuse
	bghost := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 7, live = false,
		}, "")},
	}, a)
	_, ghosterr := gloaming.reclog_scan(rec_cat(a, {hdr2, bghost}), a)
	testing.expect_value(t, int(ghosterr), int(gloaming.Store_Err.Malformed))

	// the merge shape is a TRANSFER, not a collision: row 0 absorbs
	// row 1's name in the same batch that tombstones row 1 — the
	// replay must accept it and land the name on the survivor
	bmv := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 0, live = true, name = "X",
		}, "term")},
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 1, live = true, name = "Y",
		}, "term")},
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 0, live = true, name = "X", aliases = []string{"Y"},
		}, "term")},
		{kind = .Entity, body = gloaming.rec_entity_body(gloaming.Entity{
			id = 1, live = false,
		}, "")},
	}, a)
	mv, mverr := gloaming.reclog_scan(rec_cat(a, {hdr2, bmv}), a)
	testing.expectf(t, mverr == gloaming.Store_Err.None, "transfer: %v", mverr)
	if fid, ok := gloaming.graph_entity_find(&mv.graph, "Y"); !ok || int(fid) != 0 {
		testing.expectf(t, false, "transfer: Y must answer to row 0")
	}

	// --- torn legs: the crash shapes, opened at the last commit ---
	torn := rec_copy(file[:len(file) - 7], a) // EOF inside the last batch
	s2, s2err := gloaming.reclog_scan(torn, a)
	testing.expectf(t, s2err == .None, "torn scan: %v", s2err)
	testing.expect(t, s2.torn, "mid-frame EOF must report torn")
	testing.expect_value(t, len(s2.docs), 1) // batch 2 removed 2, batch 3 not reached
	if _, live := s2.docs[3]; live { testing.expect(t, false, "doc 3 must not survive a torn tail") }

	zeros := make([]u8, 24, a)
	s3, s3err := gloaming.reclog_scan(rec_cat(a, {file, zeros}), a)
	testing.expectf(t, s3err == .None, "zero-tail scan: %v", s3err)
	testing.expect(t, s3.torn, "zero tail must report torn")
	testing.expect_value(t, len(s3.docs), 2)

	// an unclosed Begin at EOF — the frame-per-append writer's other tear
	begin := make([]u8, 17, a) // 13 fixed + the 4-byte count body
	begin[0] = 1
	gloaming.pl_put_u32(begin, 1, 4)
	gloaming.pl_put_u32(begin, 5, 1)
	gloaming.pl_put_u64(begin, 9, hash.fnv64a(begin[0:9]))
	s4, s4err := gloaming.reclog_scan(rec_cat(a, {file, begin}), a)
	testing.expectf(t, s4err == .None, "unclosed-begin scan: %v", s4err)
	testing.expect(t, s4.torn, "unclosed Begin must report torn")
	testing.expect_value(t, len(s4.docs), 2)
}

DISK_TEST_DIR :: "tmp/disk-store-test"

disk_test_paths :: proc(a: mem.Allocator) -> (registry, payloads: string) {
	registry, _ = os.join_path({DISK_TEST_DIR, "registry.glr"}, a)
	payloads, _ = os.join_path({DISK_TEST_DIR, "payloads.glb"}, a)
	return
}

disk_test_wipe :: proc(a: mem.Allocator) {
	r, p := disk_test_paths(a)
	_ = os.remove(r)
	_ = os.remove(p)
}

// the payload_roundtrip fixture, reused as the disk store's corpus.
// Built with make + element assignment on the caller's allocator, not
// slice literals: a slice compound literal is backed by the enclosing
// stack frame, so returning one from a proc hands back a dangling
// pointer — the compiler rejects the direct `return []T{…}` shape,
// and routing it through a local escapes that check and still comes
// back garbage. The same literal inline in a
// test body is fine — its frame is live.
disk_test_doc :: proc(a: mem.Allocator) -> (string, []gloaming.Token, []gloaming.Segment) {
	toks := make([]gloaming.Token, 5, a)
	toks[0] = {surface = "夜",     lemma = "夜",     pos = "名詞,一般,*,*,*",       reading = "ヨル",   start = 0,  end = 3,  cost = 100, kind = .Dictionary, entry_id = 7}
	toks[1] = {surface = "が",     lemma = "が",     pos = "助詞,格助詞,一般,*,*", reading = "ガ",     start = 3,  end = 6,  cost = 50,  kind = .Dictionary, entry_id = 3}
	toks[2] = {surface = "更ける", lemma = "更ける", pos = "動詞,自立,一段,基本形", reading = "フケル", start = 6,  end = 15, cost = 300, kind = .Dictionary, entry_id = 12}
	toks[3] = {surface = "。",     lemma = "。",     pos = "記号,句点,*,*,*",     reading = "*",      start = 15, end = 18, cost = 20,  kind = .Dictionary, entry_id = 5}
	toks[4] = {surface = "ヴュウ", lemma = "ヴュウ", pos = "名詞,固有名詞,一般,*,*", reading = "*",     start = 18, end = 27, cost = 4000, kind = .Unknown, entry_id = -1}

	segs := make([]gloaming.Segment, 2, a)
	segs[0] = {kind = .Chapter,   span = {doc = 1, start = 0, end = 27}}
	segs[1] = {kind = .Paragraph, span = {doc = 1, start = 0, end = 18}}
	return "夜が更ける。ヴュウ", toks, segs
}

tokens_equal :: proc(want, got: []gloaming.Token) -> (ok: bool, at: int) {
	if len(want) != len(got) { return false, -1 }
	for w, i in want {
		g := got[i]
		if g.surface != w.surface || g.lemma != w.lemma || g.pos != w.pos ||
			g.reading != w.reading || g.start != w.start || g.end != w.end ||
			g.kind != w.kind || g.cost != w.cost ||
			g.entry_id != w.entry_id {
			return false, i
		}
	}
	return true, -1
}

segments_equal :: proc(want, got: []gloaming.Segment) -> bool {
	if len(want) != len(got) { return false }
	for w, i in want {
		if got[i].kind != w.kind || got[i].span.doc != w.span.doc ||
			got[i].span.start != w.span.start || got[i].span.end != w.span.end {
			return false
		}
	}
	return true
}

@(test)
store_disk_roundtrip :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(DISK_TEST_DIR) { _ = os.mkdir(DISK_TEST_DIR) }
	disk_test_wipe(a)
	defer disk_test_wipe(a)

	dict := u64(0x1234567890ABCDEF)
	store, ds, serr := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 7, a)
	if !testing.expectf(t, serr == .None, "open: %v", serr) { return }

	// arena-owned text so the scribble proof means something
	text, toks, segs := disk_test_doc(a)
	tbuf := make([]u8, len(text), a)
	copy(tbuf, text)
	text = transmute(string)tbuf

	if aerr := store.add_document(store.ctx, 1, text, toks, segs); aerr != .None {
		testing.expectf(t, false, "add: %v", aerr)
		return
	}
	for &b in tbuf { b = 88 } // scribble the caller's copy
	testing.expect_value(t, int(store.add_document(store.ctx, 1, text, toks, segs)),
		int(gloaming.Store_Err.Duplicate))

	doc2 := make([]gloaming.Token, 1, a)
	doc2[0] = toks[1]
	doc2[0].start = 0
	doc2[0].end = 3
	if aerr := store.add_document(store.ctx, 2, "が", doc2, nil); aerr != .None {
		testing.expectf(t, false, "add 2: %v", aerr)
		return
	}

	docs := store.docs(store.ctx)
	if !testing.expect_value(t, len(docs), 2) { return }
	testing.expect_value(t, u32(docs[0]), 1)
	testing.expect_value(t, u32(docs[1]), 2)
	testing.expect(t, store.has(store.ctx, 1), "has 1")
	testing.expect(t, !store.has(store.ctx, 9), "has 9")

	// materialized decode: every field, against the pre-scribble fixture
	_, want_toks, want_segs := disk_test_doc(a)
	got, gerr := store.tokens(store.ctx, 1, a)
	if !testing.expectf(t, gerr == .None, "tokens: %v", gerr) { return }
	ok, at := tokens_equal(want_toks, got)
	testing.expectf(t, ok, "tokens differ at %d", at)

	got_segs, sgserr := store.segments(store.ctx, 1, a)
	if !testing.expectf(t, sgserr == .None, "segments: %v", sgserr) { return }
	testing.expect(t, segments_equal(want_segs, got_segs), "segments differ")

	testing.expect_value(t, int(store.remove_document(store.ctx, 2)),
		int(gloaming.Store_Err.None))
	_, nf := store.tokens(store.ctx, 2, a)
	testing.expect_value(t, int(nf), int(gloaming.Store_Err.Not_Found))
	testing.expect_value(t, int(store.remove_document(store.ctx, 2)),
		int(gloaming.Store_Err.Not_Found))
	testing.expect_value(t, len(store.docs(store.ctx)), 1)

	// persistence: close, reopen, everything still true — and the
	// refusal protocol: a different dict_version answers Stale
	testing.expect_value(t, int(gloaming.disk_store_close(ds)),
		int(gloaming.Store_Err.None))
	store2, ds2, rerr := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 7, a)
	if !testing.expectf(t, rerr == .None, "reopen: %v", rerr) { return }
	docs2 := store2.docs(store2.ctx)
	if !testing.expect_value(t, len(docs2), 1) { return }
	testing.expect_value(t, u32(docs2[0]), 1)
	got2, g2err := store2.tokens(store2.ctx, 1, a)
	if !testing.expectf(t, g2err == .None, "reopen tokens: %v", g2err) { return }
	ok2, at2 := tokens_equal(want_toks, got2)
	testing.expectf(t, ok2, "reopen tokens differ at %d", at2)
	got2_segs, _ := store2.segments(store2.ctx, 1, a)
	testing.expect(t, segments_equal(want_segs, got2_segs), "reopen segments differ")
	testing.expect_value(t, int(gloaming.disk_store_close(ds2)),
		int(gloaming.Store_Err.None))

	store3, ds3, r3err := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict + 1, 7, a)
	if !testing.expectf(t, r3err == .None, "reopen stale: %v", r3err) { return }
	_, stale := store3.tokens(store3.ctx, 1, a)
	testing.expect_value(t, int(stale), int(gloaming.Store_Err.Stale))
	testing.expect_value(t, int(gloaming.disk_store_close(ds3)),
		int(gloaming.Store_Err.None))
}

@(test)
store_disk_recovery :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(DISK_TEST_DIR) { _ = os.mkdir(DISK_TEST_DIR) }
	disk_test_wipe(a)
	reg_path, pay_path := disk_test_paths(a)
	defer disk_test_wipe(a)

	dict := u64(0xFEED)
	text, toks, segs := disk_test_doc(a)
	store, ds, serr := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, a)
	if !testing.expectf(t, serr == .None, "open: %v", serr) { return }
	if aerr := store.add_document(store.ctx, 5, text, toks, segs); aerr != .None {
		testing.expectf(t, false, "add: %v", aerr)
		return
	}
	testing.expect_value(t, int(gloaming.disk_store_close(ds)), int(gloaming.Store_Err.None))

	// torn registry tail — crash mid-append — reopens at the commit
	reg, rerr := os.read_entire_file_from_path(reg_path, a)
	if !testing.expectf(t, rerr == nil, "read registry: %v", rerr) { return }
	torn_file := make([]u8, len(reg) + 9, a)
	copy(torn_file, reg)
	for i in len(reg)..<len(torn_file) { torn_file[i] = u8(i) } // garbage partial frame
	_ = os.write_entire_file_from_bytes(reg_path, torn_file)

	s2, ds2, o2 := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, a)
	if !testing.expectf(t, o2 == .None, "reopen torn: %v", o2) { return }
	testing.expect_value(t, len(s2.docs(s2.ctx)), 1)
	got, gerr := s2.tokens(s2.ctx, 5, a)
	if !testing.expectf(t, gerr == .None, "tokens after torn reopen: %v", gerr) { return }
	ok, at := tokens_equal(toks, got)
	testing.expectf(t, ok, "torn-reopen tokens differ at %d", at)
	// the repair truncated the tail: file size is back at the commit
	testing.expect_value(t, int(gloaming.disk_store_close(ds2)), int(gloaming.Store_Err.None))

	// committed-frame damage refuses to open
	bad := rec_copy(reg, a)
	bad[len(bad) - 1] = bad[len(bad) - 1] ~ 0xFF
	_ = os.write_entire_file_from_bytes(reg_path, bad)
	_, _, m1 := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, a)
	testing.expect_value(t, int(m1), int(gloaming.Store_Err.Malformed))

	// a payload reference beyond the payloads file — refused at open
	// even with every frame check valid (rec_doc_body wrote the lie)
	disk_test_wipe(a)
	store3, ds3, o3 := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, a)
	if !testing.expectf(t, o3 == .None, "open 3: %v", o3) { return }
	_ = store3
	testing.expect_value(t, int(gloaming.disk_store_close(ds3)), int(gloaming.Store_Err.None))
	hdr := make([]u8, 8, a)
	copy(hdr[0:4], "GLR1")
	gloaming.pl_put_u32(hdr, 4, 1)
	lie := gloaming.rec_batch([]gloaming.Rec_Record{
		{kind = .Doc, body = gloaming.rec_doc_body(1,
			{ text_hash = 1, dict_version = dict, options = 0 }, 1 << 40, 4, "あ", nil)},
	}, a)
	_ = os.write_entire_file_from_bytes(reg_path, rec_cat(a, {hdr, lie}))
	_ = os.write_entire_file_from_bytes(pay_path, make([]u8, 0, a))
	_, _, m2 := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, a)
	testing.expect_value(t, int(m2), int(gloaming.Store_Err.Malformed))
}

@(test)
store_disk_differential :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(DISK_TEST_DIR) { _ = os.mkdir(DISK_TEST_DIR) }
	disk_test_wipe(a)
	defer disk_test_wipe(a)

	dict := u64(0xD1F)
	mem_store, merr := gloaming.store_memory(a)
	if !testing.expectf(t, merr == .None, "store_memory: %v", merr) { return }
	disk_store, ds, derr := gloaming.store_disk(DISK_TEST_DIR, payload_test_resolver,
		nil, dict, 0, a)
	if !testing.expectf(t, derr == .None, "store_disk: %v", derr) { return }
	defer _ = gloaming.disk_store_close(ds)

	text, toks, segs := disk_test_doc(a)
	doc2 := make([]gloaming.Token, 1, a)
	doc2[0] = toks[1]
	doc2[0].start = 0
	doc2[0].end = 3
	stores := [2]gloaming.Store{mem_store, disk_store}
	names := [2]string{"memory", "disk"}
	for i in 0..<2 {
		if aerr := stores[i].add_document(stores[i].ctx, 1, text, toks, segs); aerr != .None {
			testing.expectf(t, false, "%s add 1: %v", names[i], aerr)
			return
		}
		if aerr := stores[i].add_document(stores[i].ctx, 2, "が", doc2, nil); aerr != .None {
			testing.expectf(t, false, "%s add 2: %v", names[i], aerr)
			return
		}
	}

	// docs/has agree
	m_docs := mem_store.docs(mem_store.ctx)
	d_docs := disk_store.docs(disk_store.ctx)
	testing.expect_value(t, len(m_docs), len(d_docs))
	for i in 0..<len(m_docs) {
		testing.expect_value(t, u32(m_docs[i]), u32(d_docs[i]))
	}

	// tokens and segments agree field-for-field
	for doc in m_docs {
		mt, _ := mem_store.tokens(mem_store.ctx, doc, a)
		dt, dterr := disk_store.tokens(disk_store.ctx, doc, a)
		if !testing.expectf(t, dterr == .None, "disk tokens %d: %v", doc, dterr) { return }
		ok, at := tokens_equal(mt, dt)
		testing.expectf(t, ok, "doc %d tokens differ at %d", doc, at)
		msg, _ := mem_store.segments(mem_store.ctx, doc, a)
		dsg, _ := disk_store.segments(disk_store.ctx, doc, a)
		testing.expectf(t, segments_equal(msg, dsg), "doc %d segments differ", doc)

		// and through the query engine — the port composes identically
		queries := []string{
			"(seq (m lemma \"夜\"))",
			"(seq (m lemma \"夜\") (m lemma \"が\") @x)",
			"(seq (m pos ^\"名詞\"))",
		}
		for q in queries {
			query, perr := gloaming.query_parse(q, gloaming.Parse_Options{}, a)
			if !testing.expectf(t, perr == .None, "parse %s: %v", q, perr) { return }
			mres, _ := gloaming.query_match(&query, {doc = doc, tokens = mt, segments = msg}, 4096, a)
			dres, _ := gloaming.query_match(&query, {doc = doc, tokens = dt, segments = dsg}, 4096, a)
			if !testing.expect_value(t, len(mres.matches), len(dres.matches)) { return }
			for i in 0..<len(mres.matches) {
				testing.expect_value(t, mres.matches[i].start, dres.matches[i].start)
				testing.expect_value(t, mres.matches[i].end, dres.matches[i].end)
			}
		}
	}
}

// Association measures: the measure family over one co_occurrence
// population — presence marginals, reference values, the symmetry /
// count-identity properties, and the refusals.
@(test)
assoc_measures_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// 猫犬猫鳥犬 | 猫鳥魚犬猫 | 猫 — three paragraph windows, 魚 the lone
	// 動詞; the noun population is 猫×3 犬×2 鳥×2 over 3 windows
	rows := []string{
		"猫	名詞,一般,*,*,*	猫	ネコ	0	3	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	3	6	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	6	9	-	0",
		"鳥	名詞,一般,*,*,*	鳥	トリ	9	12	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	12	15	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	15	18	-	0",
		"鳥	名詞,一般,*,*,*	鳥	トリ	18	21	-	0",
		"魚	動詞,自立,*,*,*	魚	サカナ	21	24	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	24	27	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	27	30	-	0",
		"猫	名詞,一般,*,*,*	猫	ネコ	30	33	-	0",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) { toks[i] = fixture_token(t, rows[i]) }
	segs := []gloaming.Segment{
		{kind = .Paragraph, span = {doc = 0, start = 0, end = 15}},
		{kind = .Paragraph, span = {doc = 0, start = 15, end = 30}},
		{kind = .Paragraph, span = {doc = 0, start = 30, end = 33}},
	}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks, segments = segs}
	opts := gloaming.Cooc_Options{
		unit = .Segments,
		filter = {pos_prefixes = {"名詞,"}, use_lemma = true},
	}

	// presence marginals mirror the pair population exactly
	pres, perr := gloaming.cooc_presence(stream, {}, opts, a)
	testing.expectf(t, perr == gloaming.Freq_Err.None, "presence: %v", perr)
	if !testing.expect_value(t, pres.windows, 3) { return }
	if !testing.expect_value(t, len(pres.keys), 3) { return }
	wants := []string{"猫", "犬", "鳥"}
	counts := []int{3, 2, 2}
	for i in 0..<len(pres.keys) {
		if !testing.expect_value(t, pres.keys[i].lemma, wants[i]) { return }
		if !testing.expect_value(t, pres.keys[i].count, counts[i]) { return }
	}

	pairs, _, cerr := gloaming.co_occurrence(stream, {}, opts, a)
	testing.expectf(t, cerr == gloaming.Freq_Err.None, "pairs: %v", cerr)

	// Dice: 犬鳥 perfect (1.0), then the two 0.8 ties in a-order;
	// marginals travel with the row
	dice, derr := gloaming.assoc_scores(pairs, pres.keys, pres.windows,
		.Dice, a)
	testing.expectf(t, derr == gloaming.Freq_Err.None, "dice: %v", derr)
	if !testing.expect_value(t, len(dice), 3) { return }
	dice_v := []f64{1.0, 0.8, 0.8}
	dice_ab := []string{"犬", "犬", "猫"}
	dice_na := []int{2, 2, 3}
	dice_nb := []int{2, 3, 2}
	for i in 0..<len(dice) {
		if !testing.expectf(t, abs_f64(dice[i].value - dice_v[i]) < 1e-12,
			"dice %d: got %f want %f", i, dice[i].value, dice_v[i]) { return }
		if !testing.expect_value(t, dice[i].a, dice_ab[i]) { return }
		if !testing.expect_value(t, dice[i].na, dice_na[i]) { return }
		if !testing.expect_value(t, dice[i].nb, dice_nb[i]) { return }
	}

	// Jaccard on the same table: 1.0, 2/3, 2/3
	jac, _ := gloaming.assoc_scores(pairs, pres.keys, pres.windows, .Jaccard, a)
	jac_v := []f64{1.0, 2.0 / 3.0, 2.0 / 3.0}
	for i in 0..<len(jac) {
		if !testing.expectf(t, abs_f64(jac[i].value - jac_v[i]) < 1e-12,
			"jaccard %d: got %f want %f", i, jac[i].value, jac_v[i]) { return }
	}

	// MI: log2(3/2) for the perfect pair, 0 for the saturated ones
	mi, _ := gloaming.assoc_scores(pairs, pres.keys, pres.windows,
		.Mutual_Information, a)
	if !testing.expectf(t, abs_f64(mi[0].value - 0.5849625007211562) < 1e-12,
		"mi: got %f", mi[0].value) { return }
	if !testing.expectf(t, abs_f64(mi[1].value) < 1e-12, "mi 1: %f", mi[1].value) {
		return
	}

	// chi-square: the one unsaturated contingency carries all of it
	chi, _ := gloaming.assoc_scores(pairs, pres.keys, pres.windows, .Chi_Square, a)
	if !testing.expectf(t, abs_f64(chi[0].value - 3.0) < 1e-12, "chi: %f", chi[0].value) {
		return
	}
	if !testing.expectf(t, abs_f64(chi[1].value) < 1e-12, "chi 1: %f", chi[1].value) {
		return
	}

	// Fisher sorts ascending: the strong pair's p first
	fish, _ := gloaming.assoc_scores(pairs, pres.keys, pres.windows,
		.Fisher_Exact, a)
	if !testing.expectf(t, abs_f64(fish[0].value - 1.0 / 3.0) < 1e-12,
		"fisher: got %f", fish[0].value) { return }
	if !testing.expectf(t, abs_f64(fish[1].value - 1.0) < 1e-12,
		"fisher 1: %f", fish[1].value) { return
	}

	// single-pair reference values, hand-computed
	ref :: proc(
		t: ^testing.T,
		m: gloaming.Assoc_Measure,
		n, na, nb, windows: int,
		want: f64,
	) {
		got, err := gloaming.assoc_value(m, n, na, nb, windows)
		if !testing.expectf(t, err == gloaming.Freq_Err.None, "%v ref: %v", m, err) {
			return
		}
		testing.expectf(t, abs_f64(got - want) < 1e-12, "%v: got %f want %f",
			m, got, want)
	}
	ref(t, .Jaccard, 3, 4, 5, 10, 0.5)
	ref(t, .Dice, 3, 4, 5, 10, 2.0 / 3.0)
	ref(t, .Mutual_Information, 3, 4, 5, 10, 0.5849625007211562)
	ref(t, .Chi_Square, 3, 4, 5, 10, 5.0 / 3.0)
	ref(t, .Fisher_Exact, 2, 2, 2, 5, 0.1) // C(2,2)C(3,0)/C(5,2) = 1/10
	ref(t, .Fisher_Exact, 2, 3, 3, 8, 2.0 / 7.0) // (3·5+1)/C(8,3) = 16/56

	// the chi-square count identity: the four-cell sum equals the
	// 2×2 shortcut N(O11·O22 − O12·O21)² / (na·nb·(N−na)·(N−nb))
	v, _ := gloaming.assoc_value(.Chi_Square, 3, 4, 5, 10)
	o11, o12, o21, o22 := 3.0, 1.0, 2.0, 4.0
	shortcut := 10.0 * (o11 * o22 - o12 * o21) * (o11 * o22 - o12 * o21) /
		(4.0 * 5.0 * 6.0 * 5.0)
	testing.expectf(t, abs_f64(v - shortcut) < 1e-12, "chi identity: %f vs %f",
		v, shortcut)

	// the symmetry property: every measure is invariant under na ↔ nb,
	// and Dice = 2J/(1+J) holds across the whole valid grid
	measures := []gloaming.Assoc_Measure{
		.Jaccard, .Dice, .Mutual_Information, .Chi_Square, .Fisher_Exact,
	}
	for windows := 3; windows <= 10; windows += 7 {
		for na := 1; na <= windows; na += 1 {
			for nb := 1; nb <= windows; nb += 1 {
				lo := max(1, na + nb - windows)
				for n := lo; n <= min(na, nb); n += 1 {
					for m in measures {
						x, e1 := gloaming.assoc_value(m, n, na, nb, windows)
						y, e2 := gloaming.assoc_value(m, n, nb, na, windows)
						if e1 != .None || e2 != .None {
							testing.expectf(t, false, "grid %v n=%d na=%d nb=%d: %v %v",
								m, n, na, nb, e1, e2)
							return
						}
						if !testing.expectf(t, abs_f64(x - y) < 1e-12,
							"symmetry %v n=%d na=%d nb=%d: %f vs %f", m, n, na, nb, x, y) {
							return
						}
					}
					j, _ := gloaming.assoc_value(.Jaccard, n, na, nb, windows)
					d, _ := gloaming.assoc_value(.Dice, n, na, nb, windows)
					d_of_j := 2 * j / (1 + j)
					if !testing.expectf(t, abs_f64(d - d_of_j) < 1e-12,
						"dice identity n=%d na=%d nb=%d: %f vs %f", n, na, nb, d, d_of_j) {
						return
					}
					if !testing.expectf(t, j >= 0 && j <= d && d <= 1,
						"bounds n=%d na=%d nb=%d: J=%f D=%f", n, na, nb, j, d) {
						return
					}
				}
			}
		}
	}

	// refusals: no population, impossible contingencies, a missing marginal
	_, err := gloaming.assoc_scores(pairs, pres.keys, 0, .Dice, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Window))
	_, err = gloaming.assoc_value(.Dice, 3, 2, 5, 10) // n above a marginal
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.assoc_value(.Dice, 1, 11, 5, 10) // marginal above population
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.assoc_value(.Dice, 1, 9, 9, 10) // union overshoot
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.assoc_scores(pairs, pres.keys[:2], 3, .Dice, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// a duplicate marg key is a malformed table, not last-wins
	dupmarg := []gloaming.Freq_Entry{
		{lemma = "猫", count = 3}, {lemma = "犬", count = 2}, {lemma = "猫", count = 1},
	}
	_, err = gloaming.assoc_scores(pairs, dupmarg, 3, .Dice, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// Fisher underflow at an extreme contingency: the p is below the
	// f64 range and comes back 0.0 — never NaN, never an error
	up, uerr := gloaming.assoc_value(.Fisher_Exact, 1000, 1000, 1000, 1000000)
	testing.expectf(t, uerr == gloaming.Freq_Err.None, "underflow: %v", uerr)
	if !testing.expectf(t, up == 0 && up - up == 0, "underflow p: %f", up) {
		return
	}
}

abs_f64 :: proc(v: f64) -> f64 {
	return v < 0 ? -v : v
}

// free a caller-owned result by its data pointer — plain-slice makes
// and builder-backed strings have no delete, but the tracking
// allocator frees by pointer (stats_owns_its_scratch's broom)
free_slice :: proc(xs: []$T, ta: mem.Allocator) {
	if len(xs) > 0 { mem.free(raw_data(xs), ta) }
}

free_str :: proc(s: string, ta: mem.Allocator) {
	if len(s) > 0 { mem.free(raw_data(s), ta) }
}

// cooc_distance with its refusal surfaced — the tie fixture's helper
gl_cooc_distance_checked :: proc(
	t: ^testing.T,
	pairs: []gloaming.Co_Pair,
	keys: []string,
	a: mem.Allocator,
) -> []f64 {
	d, derr := gloaming.cooc_distance(pairs, keys, a)
	if !testing.expectf(t, derr == gloaming.Freq_Err.None, "tie dist: %v", derr) {
		return {}
	}
	return d
}

// Ward clustering: the Lance–Williams reference, the monotone and
// size identities, the co-occurrence distance matrix, determinism.
@(test)
ward_clustering_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the hand-worked reference: four 1D points, Euclidean dissimilarity
	dist := []f64{
		0, 0.5, 3, 10,
		0.5, 0, 2.5, 9.5,
		3, 2.5, 0, 7,
		10, 9.5, 7, 0,
	}
	merges, err := gloaming.ward_merges(dist, 4, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "ward: %v", err)
	if !testing.expect_value(t, len(merges), 3) { return }
	// (0,1) at 0.5; then {0,1} with 2 at sqrt(30.25/3); then all at
	// sqrt(468.1667/4) — the LW arithmetic worked by hand
	if !testing.expect_value(t, merges[0].a, 0) { return }
	if !testing.expect_value(t, merges[0].b, 1) { return }
	if !testing.expect_value(t, merges[0].size, 2) { return }
	if !testing.expectf(t, abs_f64(merges[0].dist - 0.5) < 1e-12,
		"h0: %f", merges[0].dist) { return }
	if !testing.expect_value(t, merges[1].a, 2) { return } // a < b always
	if !testing.expect_value(t, merges[1].b, 4) { return }
	if !testing.expect_value(t, merges[1].size, 3) { return }
	if !testing.expectf(t, abs_f64(merges[1].dist - 3.1754264805429417) < 1e-12,
		"h1: %f", merges[1].dist) { return }
	if !testing.expect_value(t, merges[2].a, 3) { return }
	if !testing.expect_value(t, merges[2].b, 5) { return }
	if !testing.expect_value(t, merges[2].size, 4) { return }
	if !testing.expectf(t, abs_f64(merges[2].dist - 10.81857969729237) < 1e-12,
		"h2: %f", merges[2].dist) { return }

	// monotone heights, and the size identity (leaves 1, final = n)
	for i in 0..<len(merges) {
		if i > 0 && !testing.expectf(t, merges[i].dist >= merges[i - 1].dist,
			"height inversion at %d", i) { return }
		want := 2 + i // sizes 2, 3, 4 — each merge absorbs one more leaf
		if !testing.expect_value(t, merges[i].size, want) { return }
	}

	// determinism: the same input merges identically
	again, _ := gloaming.ward_merges(dist, 4, a)
	if !testing.expect_value(t, len(again), len(merges)) { return }
	for i in 0..<len(merges) {
		if !testing.expect_value(t, again[i].a, merges[i].a) { return }
		if !testing.expect_value(t, again[i].b, merges[i].b) { return }
		if !testing.expectf(t, abs_f64(again[i].dist - merges[i].dist) < 1e-15,
			"drift at %d", i) { return }
	}

	// the distance matrix off a pair table: profiles are in-table
	// neighborhoods; 空 (in keys, in no pair) is at distance 1 from
	// everything — no shared evidence
	pairs := []gloaming.Co_Pair{
		{a = "犬", b = "猫", n = 2},
		{a = "犬", b = "鳥", n = 2},
		{a = "猫", b = "鳥", n = 2},
		{a = "魚", b = "猫", n = 1},
	}
	keys := []string{"犬", "猫", "鳥", "魚", "空"}
	d, derr := gloaming.cooc_distance(pairs, keys, a)
	testing.expectf(t, derr == gloaming.Freq_Err.None, "distance: %v", derr)
	// symmetric, zero diagonal, 空 isolated at 1
	for i in 0..<5 {
		if !testing.expectf(t, abs_f64(d[i * 5 + i]) < 1e-15, "diag %d", i) { return }
		for j in 0..<5 {
			if !testing.expectf(t, abs_f64(d[i * 5 + j] - d[j * 5 + i]) < 1e-15,
				"symmetry %d %d", i, j) { return }
		}
	}
	if !testing.expectf(t, abs_f64(d[4 * 5 + 0] - 1.0) < 1e-15, "空 dist: %f",
		d[4 * 5 + 0]) { return }
	// 犬 vs 魚: the shared partner is 猫 alone, and the neighborhood
	// union is {猫,鳥} — profiles are neighbor sets, selves excluded
	if !testing.expectf(t, abs_f64(d[0 * 5 + 3] - 0.5) < 1e-15,
		"犬魚: %f", d[0 * 5 + 3]) { return }

	// the weights table: symmetric counts, zero diagonal
	w, werr := gloaming.cooc_weights(pairs, keys, a)
	testing.expectf(t, werr == gloaming.Freq_Err.None, "weights: %v", werr)
	if !testing.expect_value(t, len(w), 25) { return }
	if !testing.expectf(t, w[0 * 5 + 1] == 2 && w[1 * 5 + 0] == 2, "犬猫 w") {
		return
	}
	if !testing.expectf(t, w[3 * 5 + 1] == 1 && w[1 * 5 + 3] == 1, "魚猫 w") {
		return
	}

	// ties and no-evidence pairs: two 3-cliques plus two isolated keys
	// — identical-neighborhood pairs merge at 2/3, isolated keys at 1,
	// and the merge order stays monotone through the tie band
	tpairs := []gloaming.Co_Pair{
		{a = "w0", b = "w1", n = 5}, {a = "w0", b = "w2", n = 5},
		{a = "w1", b = "w2", n = 5}, {a = "w3", b = "w4", n = 3},
		{a = "w3", b = "w5", n = 3}, {a = "w4", b = "w5", n = 3},
	}
	tkeys := []string{"w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7"}
	tdist := gl_cooc_distance_checked(t, tpairs, tkeys, a)
	tmerges, terr := gloaming.ward_merges(tdist, 8, a)
	testing.expectf(t, terr == gloaming.Freq_Err.None, "ties: %v", terr)
	if !testing.expect_value(t, len(tmerges), 7) { return }
	if !testing.expectf(t, abs_f64(tmerges[0].dist - 2.0 / 3.0) < 1e-15,
		"tie h0: %f", tmerges[0].dist) { return }
	if !testing.expect_value(t, tmerges[0].a, 0) { return }
	if !testing.expect_value(t, tmerges[0].b, 1) { return }
	if !testing.expect_value(t, tmerges[len(tmerges) - 1].size, 8) { return }
	for i in 1..<len(tmerges) {
		if !testing.expectf(t, tmerges[i].dist - tmerges[i - 1].dist >= -1e-15,
			"tie band inversion at %d", i) { return }
	}

	// refusals and the trivial sizes
	_, err = gloaming.ward_merges(dist, 5, a) // wrong length
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	bad := []f64{0, -1, -1, 0}
	_, err = gloaming.ward_merges(bad, 2, a) // negative dissimilarity
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	z := 0.0
	nanv := []f64{0, z / z, -1, 0} // NaN fails every comparison — must refuse
	_, err = gloaming.ward_merges(nanv, 2, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	infv := []f64{0, 1.0 / z, -1, 0} // Inf heights are not a dendrogram
	_, err = gloaming.ward_merges(infv, 2, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	none, err2 := gloaming.ward_merges(dist[:1], 1, a)
	testing.expectf(t, err2 == gloaming.Freq_Err.None, "1x1: %v", err2)
	testing.expect_value(t, len(none), 0)
	_, err = gloaming.cooc_distance(pairs, {"犬", "犬"}, a) // duplicate key
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.cooc_weights(pairs, {"犬", "犬"}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
}

// The k-cut: labels over the hand-worked Ward reference above, the
// smallest-leaf ranking rule, determinism, and the malformed-tree refusals
@(test)
cluster_labels_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the same reference tree: (0,1) at 0.5, 2 joins them, 3 joins last
	dist := []f64{
		0, 0.5, 3, 10,
		0.5, 0, 2.5, 9.5,
		3, 2.5, 0, 7,
		10, 9.5, 7, 0,
	}
	merges, err := gloaming.ward_merges(dist, 4, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "ward: %v", err)

	// k=1 keeps all merges; k=4 keeps none. The label is the rank of the
	// component's smallest member leaf — {0,1,2} holds leaf 0, so k=2
	// labels it 0 and leaf 3's singleton 1
	cuts := [4][]int{
		{0, 0, 0, 0}, // k=1
		{0, 0, 0, 1}, // k=2: {0,1,2} | {3}
		{0, 0, 1, 2}, // k=3: {0,1} | {2} | {3}
		{0, 1, 2, 3}, // k=4: singletons
	}
	for k in 1..=4 {
		labels, lerr := gloaming.cluster_labels(merges, 4, k, a)
		testing.expectf(t, lerr == gloaming.Freq_Err.None, "k=%d: %v", k, lerr)
		if !testing.expect_value(t, len(labels), 4) { return }
		for i in 0..<4 {
			if !testing.expectf(t, labels[i] == cuts[k - 1][i],
				"k=%d leaf %d: %d want %d", k, i, labels[i], cuts[k - 1][i]) {
				return
			}
		}
	}

	// determinism: one tree cuts to one labelling
	first, _ := gloaming.cluster_labels(merges, 4, 2, a)
	second, _ := gloaming.cluster_labels(merges, 4, 2, a)
	for i in 0..<4 {
		if !testing.expect_value(t, second[i], first[i]) { return }
	}

	// refusals: k outside 1..n, a merge list whose length is not n−1
	_, err = gloaming.cluster_labels(merges, 4, 0, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.cluster_labels(merges, 4, 5, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.cluster_labels(merges, 5, 2, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// a row naming a later merge (id ≥ n+i), a negative id, and a row
	// re-uniting one component — three malformed trees
	fwd := []gloaming.Ward_Merge{{a = 5, b = 0}, {a = 2, b = 6}, {a = 7, b = 3}}
	_, err = gloaming.cluster_labels(fwd, 4, 1, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	neg := []gloaming.Ward_Merge{{a = -1, b = 1}, {a = 4, b = 2}, {a = 5, b = 3}}
	_, err = gloaming.cluster_labels(neg, 4, 1, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	deg := []gloaming.Ward_Merge{{a = 0, b = 1}, {a = 4, b = 0}, {a = 5, b = 2}}
	_, err = gloaming.cluster_labels(deg, 4, 1, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// the single-leaf tree: zero merges, one label
	solo, serr := gloaming.cluster_labels({}, 1, 1, a)
	testing.expectf(t, serr == gloaming.Freq_Err.None, "solo: %v", serr)
	if !testing.expect_value(t, len(solo), 1) { return }
	testing.expect_value(t, solo[0], 0)
}

// Coordinates: the shifted power iteration's exact star reference,
// the eigenpair residual / orthogonality properties, determinism.
@(test)
power_coords_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// K_{1,3}: with the mass axis removed, x is the λ=−1 factor
	// (√3,−1,−1,−1)/√6 sign-fixed, and sign(λ)·sqrt(|λ|) flips it to
	// (−√3,1,1,1)/√6; the next factor is the degenerate zero
	// eigenvalue, whose scale collapses it to (numerically) nothing
	w := []f64{
		0, 1, 1, 1,
		1, 0, 0, 0,
		1, 0, 0, 0,
		1, 0, 0, 0,
	}
	coords, err := gloaming.power_coords(w, 4, 1e-13, 512, a)
	testing.expectf(t, err == gloaming.Freq_Err.None, "coords: %v", err)
	s2 := 0.7071067811865476 // 1/√2
	s6 := 0.4082482904638631 // 1/√6
	want_x := []f64{-s2, s6, s6, s6}
	for i in 0..<4 {
		if !testing.expectf(t, abs_f64(coords[i].x - want_x[i]) < 1e-9,
			"x[%d]: %f want %f", i, coords[i].x, want_x[i]) { return }
		if !testing.expectf(t, abs_f64(coords[i].y) < 1e-6,
			"y[%d]: %f want ~0", i, coords[i].y) { return }
	}

	// properties on a denser deterministic table: both axes are
	// eigenvectors of the CA-normalized table (Rayleigh-quotient
	// residuals, so the sqrt(|λ|) scaling cancels and a negative
	// leading eigenvalue still passes), orthogonal to each other AND
	// to the mass vector CA removes
	k := 6
	dw := make([]f64, k * k, a)
	for i in 0..<k {
		for j in i + 1..<k {
			v := f64((i * 7 + j * 3) % 5)
			dw[i * k + j] = v
			dw[j * k + i] = v
		}
	}
	dcoords, derr := gloaming.power_coords(dw, k, 1e-13, 512, a)
	testing.expectf(t, derr == gloaming.Freq_Err.None, "dense: %v", derr)
	s := make([]f64, k, a)
	for i in 0..<k { for j in 0..<k { s[i] += dw[i * k + j] } }
	sm := make([]f64, k * k, a)
	for i in 0..<k {
		for j in 0..<k {
			sm[i * k + j] = dw[i * k + j] / math.sqrt(s[i] * s[j])
		}
	}
	mass := make([]f64, k, a)
	{
		mn := 0.0
		for i in 0..<k { mass[i] = math.sqrt(s[i]); mn += mass[i] * mass[i] }
		minv := 1.0 / math.sqrt(mn)
		for i in 0..<k { mass[i] *= minv }
	}
	x := make([]f64, k, a)
	y := make([]f64, k, a)
	for i in 0..<k { x[i], y[i] = dcoords[i].x, dcoords[i].y }
	dmx := 0.0
	dmy := 0.0
	for i in 0..<k { dmx += x[i] * mass[i]; dmy += y[i] * mass[i] }
	if !testing.expectf(t, abs_f64(dmx) < 1e-9, "x not off the mass: %f", dmx) {
		return
	}
	if !testing.expectf(t, abs_f64(dmy) < 1e-9, "y not off the mass: %f", dmy) {
		return
	}
	mux := 0.0
	x2 := 0.0
	for i in 0..<k {
		sv := 0.0
		for j in 0..<k { sv += sm[i * k + j] * x[j] }
		mux += x[i] * sv
		x2 += x[i] * x[i]
	}
	mux /= x2
	rx := make([]f64, k, a)
	for i in 0..<k {
		rx[i] = 0.0
		for j in 0..<k { rx[i] += sm[i * k + j] * x[j] }
		rx[i] -= mux * x[i]
	}
	nrx := 0.0
	for i in 0..<k { nrx += rx[i] * rx[i] }
	if !testing.expectf(t, math.sqrt(nrx) < 1e-8, "x residual: %f", math.sqrt(nrx)) {
		return
	}
	mu := 0.0
	y2 := 0.0
	for i in 0..<k {
		sv := 0.0
		for j in 0..<k { sv += sm[i * k + j] * y[j] }
		mu += y[i] * sv
		y2 += y[i] * y[i]
	}
	mu /= y2 // the Rayleigh quotient: coordinates carry sqrt(|λ|) scaling
	ry := make([]f64, k, a)
	for i in 0..<k {
		ry[i] = 0.0
		for j in 0..<k { ry[i] += sm[i * k + j] * y[j] }
		ry[i] -= mu * y[i]
	}
	nry := 0.0
	for i in 0..<k { nry += ry[i] * ry[i] }
	if !testing.expectf(t, math.sqrt(nry) < 1e-8, "y residual: %f", math.sqrt(nry)) {
		return
	}
	dot := 0.0
	for i in 0..<k { dot += x[i] * y[i] }
	if !testing.expectf(t, abs_f64(dot) < 1e-9, "orthogonal: %f", dot) { return }

	// determinism: the same table draws the same picture, bit for bit
	d2, _ := gloaming.power_coords(dw, k, 1e-13, 512, a)
	for i in 0..<k {
		if !testing.expectf(t, d2[i].x == dcoords[i].x && d2[i].y == dcoords[i].y,
			"drift at %d", i) { return }
	}

	// two active keys: one non-trivial axis is all there is — the
	// second has no room and comes back exactly zero
	t2 := make([]f64, 4, a)
	t2[0 * 2 + 1], t2[1 * 2 + 0] = 3.0, 3.0
	t2c, t2err := gloaming.power_coords(t2, 2, 1e-13, 512, a)
	testing.expectf(t, t2err == gloaming.Freq_Err.None, "k2: %v", t2err)
	if !testing.expectf(t, abs_f64(t2c[0].x) > 0.5 && t2c[0].y == 0 && t2c[1].y == 0,
		"k2 axes: %f %f %f", t2c[0].x, t2c[0].y, t2c[1].y) { return }

	// isolated keys sit at the origin
	iso := make([]f64, 9, a)
	iso[0 * 3 + 1], iso[1 * 3 + 0] = 1.0, 1.0 // 2 isolated
	icoords, ierr := gloaming.power_coords(iso, 3, 1e-13, 512, a)
	testing.expectf(t, ierr == gloaming.Freq_Err.None, "iso: %v", ierr)
	if !testing.expectf(t, icoords[2].x == 0 && icoords[2].y == 0,
		"isolated not at origin") { return }

	// refusals
	_, err = gloaming.power_coords(w, 5, 1e-12, 64, a) // wrong length
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.power_coords(w, 4, 0, 64, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Budget))
	_, err = gloaming.power_coords(w, 4, 1e-12, 0, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Budget))
	neg := make([]f64, 16, a)
	copy(neg, w)
	neg[0 * 4 + 1] = -1
	_, err = gloaming.power_coords(neg, 4, 1e-12, 64, a) // negative weight
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	nn := make([]f64, 16, a)
	copy(nn, w)
	zero := 0.0
	nn[2 * 4 + 3] = zero / zero // NaN
	_, err = gloaming.power_coords(nn, 4, 1e-12, 64, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.power_coords(iso[:1], 1, 0, 0, a) // budget before the k<2 return
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Budget))
	one, oerr := gloaming.power_coords(iso[:1], 1, 1e-12, 64, a)
	testing.expectf(t, oerr == gloaming.Freq_Err.None, "1 key: %v", oerr)
	testing.expect_value(t, len(one), 1)
}

// PageRank: the solved three-node reference (dangling mass and
// all), the sum-to-one identity, link collapsing, and the graph
// wrapper with its kinds filter.
@(test)
pagerank_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// A→B, A→C, B→C with C dangling at d=0.85: the fixed point is
	// exactly (800, 1140, 2109)/4049
	links := []gloaming.Pr_Link{{from = 0, to = 1}, {from = 0, to = 2}, {from = 1, to = 2}}
	pr, err := gloaming.pagerank_links(3, links, 0.85, 200, 1e-12, a)
	testing.expectf(t, err == gloaming.Graph_Err.None, "pr: %v", err)
	if !testing.expect_value(t, len(pr), 3) { return }
	want := []f64{800.0 / 4049.0, 1140.0 / 4049.0, 2109.0 / 4049.0}
	sum := 0.0
	for i in 0..<3 {
		if !testing.expectf(t, abs_f64(pr[i] - want[i]) < 1e-9,
			"pr[%d]: %f want %f", i, pr[i], want[i]) { return }
		sum += pr[i]
	}
	if !testing.expectf(t, abs_f64(sum - 1.0) < 1e-12, "sum: %f", sum) { return }

	// parallel links and self-loops change nothing: the question is
	// whether u links v
	noisy := []gloaming.Pr_Link{
		{from = 0, to = 1}, {from = 0, to = 1}, {from = 1, to = 1},
		{from = 0, to = 2}, {from = 1, to = 2},
	}
	pr2, _ := gloaming.pagerank_links(3, noisy, 0.85, 200, 1e-12, a)
	for i in 0..<3 {
		if !testing.expectf(t, pr2[i] == pr[i], "collapse drift at %d", i) { return }
	}

	// the sum identity on a bigger deterministic graph
	n := 12
	big: [dynamic]gloaming.Pr_Link = make([dynamic]gloaming.Pr_Link, 0, n, a)
	for i in 0..<n {
		append(&big, gloaming.Pr_Link{from = i, to = (i * i + 1) % n})
		if i % 3 == 0 { append(&big, gloaming.Pr_Link{from = i, to = (i + 5) % n}) }
	}
	bpr, berr := gloaming.pagerank_links(n, big[:], 0.85, 200, 1e-12, a)
	testing.expectf(t, berr == gloaming.Graph_Err.None, "big: %v", berr)
	bsum := 0.0
	for v in bpr {
		bsum += v
		if !testing.expectf(t, v > 0, "non-positive score %f", v) { return }
	}
	if !testing.expectf(t, abs_f64(bsum - 1.0) < 1e-9, "big sum: %f", bsum) {
		return
	}

	// refusals
	_, err = gloaming.pagerank_links(3, links, 0, 200, 1e-12, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Bad_Budget))
	_, err = gloaming.pagerank_links(3, links, 1.01, 200, 1e-12, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Bad_Budget))
	_, err = gloaming.pagerank_links(3, links, 0.85, 0, 1e-12, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Bad_Budget))
	_, err = gloaming.pagerank_links(3, links, 0.85, 200, 0, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Bad_Budget))
	_, err = gloaming.pagerank_links(3, {{from = 0, to = 3}}, 0.85, 200, 1e-12, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Not_Found))
	empty, eerr := gloaming.pagerank_links(0, {}, 0.85, 200, 1e-12, a)
	testing.expectf(t, eerr == gloaming.Graph_Err.None, "empty: %v", eerr)
	testing.expect_value(t, len(empty), 0)

	// the document-graph wrapper: same three-node shape plus a weak
	// edge the kinds filter drops
	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	kt := gloaming.graph_kind_intern(&g, "term")
	kc := gloaming.graph_kind_intern(&g, "codes")
	kw := gloaming.graph_kind_intern(&g, "weak")
	names := []string{"A", "B", "C", "D"}
	for name, n_ in names {
		gloaming.graph_apply_entity(&g, gloaming.Entity{
			id = gloaming.Entity_Id(n_), live = true, kind = kt, name = name,
		})
	}
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(0), live = true, kind = kc,
		from = 0, to = 1, derived = true,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(1), live = true, kind = kc,
		from = 0, to = 2, derived = true,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(2), live = true, kind = kc,
		from = 1, to = 2, derived = true,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(3), live = true, kind = kw,
		from = 2, to = 3,
	})
	gpr, gerr := gloaming.graph_pagerank(&g, {}, 0.85, 200, 1e-12, a)
	testing.expectf(t, gerr == gloaming.Graph_Err.None, "gpr: %v", gerr)
	if !testing.expect_value(t, len(gpr), 4) { return }
	// the weak edge is live for D's mass; filtered out, C and D both
	// dangle over four nodes — the fixed point worked by hand:
	// (A, B, C, D) = (2400, 3420, 6327, 2400)/14547
	gfil, _ := gloaming.graph_pagerank(&g, {"codes"}, 0.85, 200, 1e-12, a)
	if !testing.expect_value(t, len(gfil), 4) { return }
	fwant := []f64{
		2400.0 / 14547.0, 3420.0 / 14547.0, 6327.0 / 14547.0, 2400.0 / 14547.0,
	}
	for row in gfil {
		i := int(row.entity)
		if !testing.expectf(t, abs_f64(row.score - fwant[i]) < 1e-9,
			"gfil[%d]: %f want %f", i, row.score, fwant[i]) { return }
	}
	// output order: score descending, id ascending on ties
	for i in 0..<len(gpr) - 1 {
		if !testing.expectf(t, gpr[i].score >= gpr[i + 1].score,
			"order at %d", i) { return }
	}
}

// The topological order: Kahn's algorithm over directed relations —
// the emission order and its determinism, the cycle remainder
// (members plus everything downstream), the kinds filter, self-loops
// and parallel edges at the core, the refusals — and the same
// answers from a rebuilt (reopened) graph.
@(test)
toposort_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	fmt_topo :: proc(order, cyclic: []int, a: mem.Allocator) -> string {
		b := strings.builder_make(a)
		strings.write_string(&b, "order:")
		for x in order { fmt.sbprintf(&b, " %d", x) }
		strings.write_string(&b, " cyclic:")
		for x in cyclic { fmt.sbprintf(&b, " %d", x) }
		return strings.to_string(b)
	}
	fmt_etopo :: proc(order, cyclic: []gloaming.Entity_Id, a: mem.Allocator) -> string {
		b := strings.builder_make(a)
		strings.write_string(&b, "order:")
		for x in order { fmt.sbprintf(&b, " %d", int(x)) }
		strings.write_string(&b, " cyclic:")
		for x in cyclic { fmt.sbprintf(&b, " %d", int(x)) }
		return strings.to_string(b)
	}

	// a diamond: 3 feeds 1, 0 and 1 feed 2, then 4 — the two roots
	// (0, 3) enter ascending, 3's edge frees 1, 1's frees 2, 2's
	// frees 4: the whole sequence is fixed
	links := []gloaming.Pr_Link{
		{from = 3, to = 1}, {from = 0, to = 2}, {from = 1, to = 2}, {from = 2, to = 4},
	}
	order, cyclic, err := gloaming.toposort_links(5, links, a)
	testing.expectf(t, err == gloaming.Graph_Err.None, "topo: %v", err)
	testing.expectf(t, fmt_topo(order, cyclic, a) == "order: 0 3 1 2 4 cyclic:",
		"topo %s", fmt_topo(order, cyclic, a))
	pos := [5]int{}
	for v, i in order { pos[v] = i }
	for l in links {
		if !testing.expectf(t, pos[l.from] < pos[l.to], "edge %d→%d backwards",
			l.from, l.to) { return }
	}

	// a cycle over 0-1-2 with 3 downstream: the remainder carries the
	// members AND 3 — everything blocked, never just the loop
	order, cyclic, err = gloaming.toposort_links(5, {
		{from = 0, to = 1}, {from = 1, to = 2}, {from = 2, to = 0}, {from = 2, to = 3},
	}, a)
	testing.expectf(t, err == gloaming.Graph_Err.None, "cyc: %v", err)
	testing.expectf(t, fmt_topo(order, cyclic, a) == "order: 4 cyclic: 0 1 2 3",
		"cyc %s", fmt_topo(order, cyclic, a))

	// a self-loop (the store writer refuses one; the core is where it
	// can appear) never frees its node
	order, cyclic, err = gloaming.toposort_links(3, {
		{from = 0, to = 1}, {from = 1, to = 1},
	}, a)
	testing.expectf(t, err == gloaming.Graph_Err.None, "self: %v", err)
	testing.expectf(t, fmt_topo(order, cyclic, a) == "order: 0 2 cyclic: 1",
		"self %s", fmt_topo(order, cyclic, a))

	// parallel edges: each counts once in the in-degree and once at
	// removal — nothing moves
	p1, c1, _ := gloaming.toposort_links(3, {{from = 0, to = 1}, {from = 1, to = 2}}, a)
	p2, c2, _ := gloaming.toposort_links(3, {
		{from = 0, to = 1}, {from = 0, to = 1}, {from = 0, to = 1}, {from = 1, to = 2},
	}, a)
	if !testing.expect_value(t, len(c1), len(c2)) { return }
	for i in 0..<len(p1) {
		if !testing.expectf(t, p1[i] == p2[i], "parallel drift at %d", i) { return }
	}

	// refusals and the empty graph
	_, _, err = gloaming.toposort_links(-1, {}, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Bad_Budget))
	_, _, err = gloaming.toposort_links(3, {{from = 0, to = 3}}, a)
	testing.expect_value(t, int(err), int(gloaming.Graph_Err.Not_Found))
	eo, ec, eerr := gloaming.toposort_links(0, {}, a)
	testing.expectf(t, eerr == gloaming.Graph_Err.None, "empty: %v", eerr)
	testing.expect_value(t, len(eo) + len(ec), 0)

	// the document-graph wrapper: the same diamond over named
	// entities, a weak edge that closes a cycle under every kind, and
	// a dead row whose relation drops with it (the invariant guard)
	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	kt := gloaming.graph_kind_intern(&g, "term")
	kp := gloaming.graph_kind_intern(&g, "precedes")
	kw := gloaming.graph_kind_intern(&g, "weak")
	names := [6]string{"A", "B", "C", "D", "E", "F"}
	for name, n_ in names {
		gloaming.graph_apply_entity(&g, gloaming.Entity{
			id = gloaming.Entity_Id(n_), live = n_ != 5, kind = kt, name = name,
		})
	}
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(0), live = true, kind = kp,
		from = 3, to = 1,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(1), live = true, kind = kp,
		from = 0, to = 2,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(2), live = true, kind = kp,
		from = 1, to = 2,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(3), live = true, kind = kp,
		from = 2, to = 4,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(4), live = true, kind = kw,
		from = 4, to = 0,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = gloaming.Relation_Id(5), live = true, kind = kp,
		from = 4, to = 5,
	})
	fres, ferr := gloaming.graph_toposort(&g, {"precedes"}, a)
	testing.expectf(t, ferr == gloaming.Graph_Err.None, "filtered: %v", ferr)
	testing.expectf(t, fmt_etopo(fres.order, fres.cyclic, a) == "order: 0 3 1 2 4 cyclic:",
		"filtered %s", fmt_etopo(fres.order, fres.cyclic, a))
	ares, aerr := gloaming.graph_toposort(&g, {}, a)
	testing.expectf(t, aerr == gloaming.Graph_Err.None, "all-kinds: %v", aerr)
	testing.expectf(t, fmt_etopo(ares.order, ares.cyclic, a) == "order: 3 1 cyclic: 0 2 4",
		"all-kinds %s", fmt_etopo(ares.order, ares.cyclic, a))

	// the rebuilt graph: same order and remainder from the log
	dir := "tmp/glr-topo"
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, a)
	pay, _ := os.join_path({dir, "payloads.glb"}, a)
	_ = os.remove(reg)
	_ = os.remove(pay)
	_, ds, serr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store_disk: %v", serr)
	n: [5]gloaming.Entity_Id
	for i in 0..<5 {
		id, e := gloaming.graph_entity_add(ds, "term", names[i], nil)
		testing.expectf(t, e == gloaming.Store_Err.None, "add %d: %v", i, e)
		n[i] = id
	}
	ev := []gloaming.Span{{doc = 0, start = 0, end = 1}}
	// the diamond on link; weak closes 0→2→4→0
	_, _ = gloaming.graph_relation_add(ds, "link", n[3], n[1], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "link", n[0], n[2], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "link", n[1], n[2], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "link", n[2], n[4], ev, true)
	_, _ = gloaming.graph_relation_add(ds, "weak", n[4], n[0], ev, true)

	dres, derr := gloaming.graph_toposort(&ds.graph, {"link"}, a)
	testing.expectf(t, derr == gloaming.Graph_Err.None, "disk filtered: %v", derr)
	testing.expectf(t, fmt_etopo(dres.order, dres.cyclic, a) == "order: 0 3 1 2 4 cyclic:",
		"disk filtered %s", fmt_etopo(dres.order, dres.cyclic, a))
	gloaming.disk_store_close(ds)

	_, ds2, rerr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, rerr == gloaming.Store_Err.None, "reopen: %v", rerr)
	defer gloaming.disk_store_close(ds2)
	rres, rerr2 := gloaming.graph_toposort(&ds2.graph, {"link"}, a)
	testing.expectf(t, rerr2 == gloaming.Graph_Err.None, "rebuilt: %v", rerr2)
	testing.expectf(t, fmt_etopo(rres.order, rres.cyclic, a) == "order: 0 3 1 2 4 cyclic:",
		"rebuilt graph sorts the same: %s", fmt_etopo(rres.order, rres.cyclic, a))
	rall, _ := gloaming.graph_toposort(&ds2.graph, {}, a)
	testing.expectf(t, fmt_etopo(rall.order, rall.cyclic, a) == "order: 3 1 cyclic: 0 2 4",
		"rebuilt all-kinds: %s", fmt_etopo(rall.order, rall.cyclic, a))
}

// Text export: dot/mermaid for the document graph and the word
// network, JSON for coordinates and the merge tree — exact strings,
// escaping, the kinds filter, mismatch refusals.
@(test)
export_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	kt := gloaming.graph_kind_intern(&g, "term")
	kc := gloaming.graph_kind_intern(&g, "codes")
	ku := gloaming.graph_kind_intern(&g, "curated")
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 0, live = true, kind = kt, name = "アサ",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 1, live = true, kind = kt, name = "霧",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 2, live = false, kind = gloaming.KIND_NONE, name = "朝",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 3, live = true, kind = kt, name = "He said \"hi\"",
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = 0, live = true, kind = kc, from = 0, to = 1, derived = true,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = 1, live = true, kind = kc, from = 1, to = 0, derived = true,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = 2, live = false, kind = gloaming.KIND_NONE, from = 2, to = 1, derived = true,
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = 3, live = true, kind = ku, from = 0, to = 3,
	})

	dot := glexport.graph_export_dot(&g, {}, a)
	want_dot := "digraph gloaming {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"アサ\"];\n" +
		"  n1 [label=\"霧\"];\n" +
		"  n3 [label=\"He said \\\"hi\\\"\"];\n" +
		"  n0 -> n1 [label=\"codes\"];\n" +
		"  n1 -> n0 [label=\"codes\"];\n" +
		"  n0 -> n3 [label=\"curated\"];\n" +
		"}\n"
	testing.expect_value(t, dot, want_dot)

	// the kinds filter drops the curated edge, nodes stay
	dotf := glexport.graph_export_dot(&g, {"codes"}, a)
	wantf := "digraph gloaming {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"アサ\"];\n" +
		"  n1 [label=\"霧\"];\n" +
		"  n3 [label=\"He said \\\"hi\\\"\"];\n" +
		"  n0 -> n1 [label=\"codes\"];\n" +
		"  n1 -> n0 [label=\"codes\"];\n" +
		"}\n"
	testing.expect_value(t, dotf, wantf)

	merm := glexport.graph_export_mermaid(&g, {}, a)
	want_merm := "graph LR\n" +
		"  n0[アサ]\n" +
		"  n1[霧]\n" +
		"  n3[He said &quot;hi&quot;]\n" +
		"  n0 ---|codes| n1\n" +
		"  n1 ---|codes| n0\n" +
		"  n0 ---|curated| n3\n"
	testing.expect_value(t, merm, want_merm)

	pairs := []gloaming.Co_Pair{
		{a = "犬", b = "猫", n = 2},
		{a = "犬", b = "鳥", n = 2},
	}
	pdot := glexport.pairs_export_dot(pairs, a)
	want_pdot := "graph words {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"犬\"];\n" +
		"  n1 [label=\"猫\"];\n" +
		"  n2 [label=\"鳥\"];\n" +
		"  n0 -- n1 [label=\"2\"];\n" +
		"  n0 -- n2 [label=\"2\"];\n" +
		"}\n"
	testing.expect_value(t, pdot, want_pdot)

	pmerm := glexport.pairs_export_mermaid(pairs, a)
	want_pmerm := "graph LR\n" +
		"  n0[犬]\n" +
		"  n1[猫]\n" +
		"  n2[鳥]\n" +
		"  n0 ---|2| n1\n" +
		"  n0 ---|2| n2\n"
	testing.expect_value(t, pmerm, want_pmerm)

	// the mermaid kinds filter drops the curated edge, nodes stay
	mermf := glexport.graph_export_mermaid(&g, {"codes"}, a)
	want_mermf := "graph LR\n" +
		"  n0[アサ]\n" +
		"  n1[霧]\n" +
		"  n3[He said &quot;hi&quot;]\n" +
		"  n0 ---|codes| n1\n" +
		"  n1 ---|codes| n0\n"
	testing.expect_value(t, mermf, want_mermf)

	// shape and line bytes must not survive into a mermaid label: ]
	// ends the node shape, ( ) { } change it, ; can end the statement,
	// # starts a character entity, a newline splits the line; dot keeps
	// them (quoted strings) but escapes control bytes octally
	esc: gloaming.Doc_Graph
	gloaming.graph_init(&esc, a)
	defer gloaming.graph_destroy(&esc)
	ekt := gloaming.graph_kind_intern(&esc, "term")
	gloaming.graph_apply_entity(&esc, gloaming.Entity{
		id = 0, live = true, kind = ekt, name = "a[b](c){d};e#f\ng",
	})
	gloaming.graph_apply_entity(&esc, gloaming.Entity{
		id = 1, live = true, kind = ekt, name = "b\\c\td",
	})
	em := glexport.graph_export_mermaid(&esc, {}, a)
	want_em := "graph LR\n" +
		"  n0[a&#91;b&#93;&#40;c&#41;&#123;d&#125;&#59;e&#35;f&#10;g]\n" +
		"  n1[b\\c\td]\n"
	testing.expect_value(t, em, want_em)
	ed := glexport.graph_export_dot(&esc, {}, a)
	want_ed := "digraph gloaming {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"a[b](c){d};e#f\\012g\"];\n" +
		"  n1 [label=\"b\\\\c\\011d\"];\n" +
		"}\n"
	testing.expect_value(t, ed, want_ed)

	// coordinates and the merge tree as JSON, %.6f with negative zero
	// flattened
	keys := []string{"犬", "猫"}
	coords := []gloaming.Coord{{x = 0.5, y = -1.25}, {x = 0, y = 0}}
	cj := glexport.coords_json(keys, coords, a)
	want_cj := "{\"coords\":[" +
		"{\"key\":\"犬\",\"x\":0.500000,\"y\":-1.250000}," +
		"{\"key\":\"猫\",\"x\":0.000000,\"y\":0.000000}" +
		"]}\n"
	testing.expect_value(t, cj, want_cj)

	merges := []gloaming.Ward_Merge{{a = 0, b = 1, dist = 0.5, size = 2}}
	wj := glexport.ward_json(keys, merges, a)
	want_wj := "{\"keys\":[\"犬\",\"猫\"],\"merges\":[" +
		"{\"a\":0,\"b\":1,\"dist\":0.500000,\"size\":2}" +
		"]}\n"
	testing.expect_value(t, wj, want_wj)

	// mismatched / negative input: an empty string, never a partial doc
	testing.expect_value(t, glexport.coords_json(keys, coords[:1], a), "")
	testing.expect_value(t,
		glexport.ward_json(keys, {{a = -1, b = 1, dist = 0.5, size = 2}}, a), "")
	// a merge id past the last merge cannot resolve either
	testing.expect_value(t,
		glexport.ward_json(keys, {{a = 0, b = 99, dist = 0.5, size = 2}}, a), "")
	// forward and self references: cyclic trees are refusals too
	testing.expect_value(t,
		glexport.ward_json(keys, {{a = 0, b = 2, dist = 0.5, size = 2}}, a), "")
	testing.expect_value(t,
		glexport.ward_json(keys, {
			{a = 0, b = 1, dist = 0.5, size = 2},
			{a = 0, b = 3, dist = 0.7, size = 4},
		}, a), "")
	// a later row referencing an earlier merge still exports
	testing.expectf(t,
		glexport.ward_json(keys, {
			{a = 0, b = 1, dist = 0.5, size = 2},
			{a = 2, b = 0, dist = 0.9, size = 3},
		}, a) != "", "legal back-reference must export")

	// non-finite coordinates and negatives that round away at six
	// decimals: null and an unsigned zero, so the JSON stays parseable
	// and no host reads a "-0.000000" label
	z := 0.0
	fcoords := []gloaming.Coord{
		{x = z / z, y = 1.0 / z}, {x = -1e-9, y = 0.25},
	}
	fj := glexport.coords_json(keys, fcoords, a)
	want_fj := "{\"coords\":[" +
		"{\"key\":\"犬\",\"x\":null,\"y\":null}," +
		"{\"key\":\"猫\",\"x\":0.000000,\"y\":0.250000}" +
		"]}\n"
	testing.expect_value(t, fj, want_fj)

	// the merge tree as dot: leaves carry words, merge nodes the height,
	// one edge per child — the dendrogram Graphviz draws
	mkeys := []string{"犬", "猫", "鳥"}
	mmerges := []gloaming.Ward_Merge{
		{a = 0, b = 1, dist = 0.5, size = 2},
		{a = 2, b = 3, dist = 3.25, size = 3},
	}
	mdot := glexport.merges_export_dot(mkeys, mmerges, a)
	want_mdot := "graph merges {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"犬\"];\n" +
		"  n1 [label=\"猫\"];\n" +
		"  n2 [label=\"鳥\"];\n" +
		"  n3 [label=\"0.500000\"];\n" +
		"  n3 -- n0;\n" +
		"  n3 -- n1;\n" +
		"  n4 [label=\"3.250000\"];\n" +
		"  n4 -- n2;\n" +
		"  n4 -- n3;\n" +
		"}\n"
	testing.expect_value(t, mdot, want_mdot)

	// the k-cut forest is the same proc over a front slice: ids only
	// name earlier rows, so the slice is a self-contained tree
	mforest := glexport.merges_export_dot(mkeys, mmerges[:1], a)
	want_mforest := "graph merges {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"犬\"];\n" +
		"  n1 [label=\"猫\"];\n" +
		"  n2 [label=\"鳥\"];\n" +
		"  n3 [label=\"0.500000\"];\n" +
		"  n3 -- n0;\n" +
		"  n3 -- n1;\n" +
		"}\n"
	testing.expect_value(t, mforest, want_mforest)

	mmerm := glexport.merges_export_mermaid(mkeys, mmerges, a)
	want_mmerm := "graph LR\n" +
		"  n0[犬]\n" +
		"  n1[猫]\n" +
		"  n2[鳥]\n" +
		"  n3(0.500000)\n" +
		"  n3 --- n0\n" +
		"  n3 --- n1\n" +
		"  n4(3.250000)\n" +
		"  n4 --- n2\n" +
		"  n4 --- n3\n"
	testing.expect_value(t, mmerm, want_mmerm)
	// malformed trees refuse: more rows than n−1, an id past n+i
	testing.expect_value(t, glexport.merges_export_dot(mkeys[:1], mmerges, a), "")
	testing.expect_value(t,
		glexport.merges_export_mermaid(mkeys, {{a = 0, b = 3, dist = 1, size = 2}}, a), "")

	// cluster-colored network: labels align with the code-point key order
	// (犬 n0, 猫 n1, 鳥 n2), nodes fill with their cluster's color
	cpdot := glexport.pairs_export_dot(pairs, a, {0, 1, 1})
	want_cpdot := "graph words {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"犬\", style=filled, fillcolor=\"#E69F00\"];\n" +
		"  n1 [label=\"猫\", style=filled, fillcolor=\"#56B4E9\"];\n" +
		"  n2 [label=\"鳥\", style=filled, fillcolor=\"#56B4E9\"];\n" +
		"  n0 -- n1 [label=\"2\"];\n" +
		"  n0 -- n2 [label=\"2\"];\n" +
		"}\n"
	testing.expect_value(t, cpdot, want_cpdot)

	// mermaid colors through style statements after the node defs
	cpmerm := glexport.pairs_export_mermaid(pairs, a, {0, 1, 1})
	want_cpmerm := "graph LR\n" +
		"  n0[犬]\n" +
		"  n1[猫]\n" +
		"  n2[鳥]\n" +
		"  style n0 fill:#E69F00\n" +
		"  style n1 fill:#56B4E9\n" +
		"  style n2 fill:#56B4E9\n" +
		"  n0 ---|2| n1\n" +
		"  n0 ---|2| n2\n"
	testing.expect_value(t, cpmerm, want_cpmerm)

	// label 8 cycles back to the first color — the palette is a ring
	cyc := []gloaming.Co_Pair{{a = "あ", b = "い", n = 1}}
	cycdot := glexport.pairs_export_dot(cyc, a, {0, 8})
	want_cycdot := "graph words {\n" +
		"  rankdir=LR;\n" +
		"  n0 [label=\"あ\", style=filled, fillcolor=\"#E69F00\"];\n" +
		"  n1 [label=\"い\", style=filled, fillcolor=\"#E69F00\"];\n" +
		"  n0 -- n1 [label=\"1\"];\n" +
		"}\n"
	testing.expect_value(t, cycdot, want_cycdot)

	// a labels length that disagrees with the key count, or a negative
	// label (the color ring indexes 0.. only), is a refusal — never a
	// partially colored picture
	testing.expect_value(t, glexport.pairs_export_dot(pairs, a, {0, 1}), "")
	testing.expect_value(t, glexport.pairs_export_mermaid(pairs, a, {0, 1}), "")
	testing.expect_value(t, glexport.pairs_export_dot(pairs, a, {-1, 0, 1}), "")
	testing.expect_value(t, glexport.pairs_export_mermaid(pairs, a, {0, 1, -2}), "")

	// the coordinate scatter for neato: every node pinned at its (x, y)
	sdot := glexport.coords_export_dot(keys, coords, a)
	want_sdot := "graph coords {\n" +
		"  n0 [label=\"犬\", pos=\"0.500000,-1.250000!\"];\n" +
		"  n1 [label=\"猫\", pos=\"0.000000,0.000000!\"];\n" +
		"}\n"
	testing.expect_value(t, sdot, want_sdot)
	testing.expect_value(t, glexport.coords_export_dot(keys, coords[:1], a), "")
}

// The stats layer owns its scratch: every buffer the stats calls
// allocate internally must be freed by the call itself — only the
// returned data may remain on the allocator, and this test frees
// that, so the tracker reads zero.
@(test)
stats_owns_its_scratch :: proc(t: ^testing.T) {
	aarena: mem.Arena
	mem.arena_init(&aarena, test_arena_buf[:])
	aa := mem.arena_allocator(&aarena)
	defer mem.arena_free_all(&aarena)

	// nine distinct nouns, one whole-stream window: 36 distinct pairs,
	// plenty for the max_pairs cap to bite mid-run
	words := [9]string{"猫", "犬", "鳥", "魚", "空", "雨", "月", "山", "川"}
	toks := make([]gloaming.Token, 9, aa)
	for i in 0..<9 {
		toks[i] = gloaming.Token{
			surface = words[i], pos = "名詞,一般", lemma = words[i],
			reading = "x", start = i * 3, end = i * 3 + 3,
		}
	}
	stream := gloaming.Token_Stream{doc = 1, tokens = toks}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	ta := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	opts := gloaming.Cooc_Options{
		filter = {pos_prefixes = []string{"名詞"}},
		unit   = .Segments,
	}
	pairs, _, perr := gloaming.co_occurrence(stream, {}, opts, ta)
	testing.expectf(t, perr == gloaming.Freq_Err.None, "cooc: %v", perr)
	pres, prerr := gloaming.cooc_presence(stream, {}, opts, ta)
	testing.expectf(t, prerr == gloaming.Freq_Err.None, "presence: %v", prerr)

	cap_opts := opts
	cap_opts.max_pairs = 3
	capped, _, caperr := gloaming.co_occurrence(stream, {}, cap_opts, ta)
	testing.expectf(t, caperr == gloaming.Freq_Err.None, "capped: %v", caperr)

	keys := []string{"猫", "犬", "鳥"}
	wt, werr := gloaming.cooc_weights(pairs, keys, ta)
	testing.expectf(t, werr == gloaming.Freq_Err.None, "weights: %v", werr)
	dt, derr := gloaming.cooc_distance(pairs, keys, ta)
	testing.expectf(t, derr == gloaming.Freq_Err.None, "distance: %v", derr)
	dupk := []string{"猫", "猫"}
	_, dwerr := gloaming.cooc_weights(pairs, dupk, ta)
	testing.expect_value(t, int(dwerr), int(gloaming.Freq_Err.Bad_Count))
	_, dderr := gloaming.cooc_distance(pairs, dupk, ta)
	testing.expect_value(t, int(dderr), int(gloaming.Freq_Err.Bad_Count))

	scores, serr := gloaming.assoc_scores(pairs, pres.keys, pres.windows, .Dice, ta)
	testing.expectf(t, serr == gloaming.Freq_Err.None, "assoc: %v", serr)
	dupm := []gloaming.Freq_Entry{{lemma = "猫", count = 1}, {lemma = "猫", count = 1}}
	_, daerr := gloaming.assoc_scores(pairs, dupm, pres.windows, .Dice, ta)
	testing.expect_value(t, int(daerr), int(gloaming.Freq_Err.Bad_Count))

	merges, merr := gloaming.ward_merges(dt, 3, ta)
	testing.expectf(t, merr == gloaming.Freq_Err.None, "ward: %v", merr)
	labels, laberr := gloaming.cluster_labels(merges, 3, 2, ta)
	testing.expectf(t, laberr == gloaming.Freq_Err.None, "labels: %v", laberr)
	coords, qerr := gloaming.power_coords(wt, 3, 1e-12, 64, ta)
	testing.expectf(t, qerr == gloaming.Freq_Err.None, "coords: %v", qerr)
	_, bberr := gloaming.power_coords(wt, 3, 0, 0, ta)
	testing.expect_value(t, int(bberr), int(gloaming.Freq_Err.Bad_Budget))

	links := []gloaming.Pr_Link{{from = 0, to = 1}, {from = 1, to = 2}}
	pr, prrerr := gloaming.pagerank_links(3, links, 0.85, 200, 1e-12, ta)
	testing.expectf(t, prrerr == gloaming.Graph_Err.None, "pr: %v", prrerr)

	// the remaining stats layers under the same broom — keyness, the weight-table
	// distance, the linkage variants, KWIC collocation, and the corpus
	// layer over a store the arena owns (the store's own allocations
	// are invisible to the tracker; only the calls' scratch matters)
	kv, kerr := gloaming.keyness_scores(pres.keys, pres.windows, pres.keys, pres.windows, {m = .Log_Likelihood}, ta)
	testing.expectf(t, kerr == gloaming.Freq_Err.None, "keyness: %v", kerr)
	wd, wderr := gloaming.weight_distance(wt, 3, .Cosine, ta)
	testing.expectf(t, wderr == gloaming.Freq_Err.None, "weight_distance: %v", wderr)
	lm, lmerr := gloaming.linkage_merges(dt, 3, .Average, ta)
	testing.expectf(t, lmerr == gloaming.Freq_Err.None, "linkage: %v", lmerr)

	krows := make([]gloaming.Kwic_Row, 2, aa)
	krows[0] = {
		left   = {doc = 1, start = 0, end = 0},
		center = {doc = 1, start = 0, end = 3},
		right  = {doc = 1, start = 3, end = 9},
	}
	krows[1] = {
		left   = {doc = 1, start = 9, end = 12},
		center = {doc = 1, start = 12, end = 15},
		right  = {doc = 1, start = 15, end = 24},
	}
	kc, kcerr := gloaming.kwic_colloc(krows, stream, {}, ta)
	testing.expectf(t, kcerr == gloaming.Freq_Err.None, "kwic_colloc: %v", kcerr)

	cstore, cserr := gloaming.store_memory(aa)
	testing.expectf(t, cserr == gloaming.Store_Err.None, "store: %v", cserr)
	testing.expectf(t, mk_store_doc(cstore, 0, {"猫", "犬", "猫"}, aa) == gloaming.Store_Err.None, "doc 0")
	testing.expectf(t, mk_store_doc(cstore, 1, {"猫", "鳥"}, aa) == gloaming.Store_Err.None, "doc 1")
	cdocs := []gloaming.Doc_Id{0, 1}
	cf, cferr := gloaming.corpus_freq(cstore, cdocs, {}, ta)
	testing.expectf(t, cferr == gloaming.Store_Err.None, "corpus_freq: %v", cferr)
	dps, dperr := gloaming.doc_profiles(cstore, cdocs, {}, ta)
	testing.expectf(t, dperr == gloaming.Store_Err.None, "profiles: %v", dperr)
	dw, dwwerr := gloaming.doc_weights(dps, ta)
	testing.expectf(t, dwwerr == gloaming.Freq_Err.None, "doc_weights: %v", dwwerr)
	dd, ddderr := gloaming.doc_distance(dps, .Jaccard, ta)
	testing.expectf(t, ddderr == gloaming.Freq_Err.None, "doc_distance: %v", ddderr)
	dm, dmerr := gloaming.doc_matrix(dps, {"犬", "猫", "鳥"}, cf, .Tf_Idf, ta)
	testing.expectf(t, dmerr == gloaming.Freq_Err.None, "doc_matrix: %v", dmerr)

	cg: gloaming.Doc_Graph
	gloaming.graph_init(&cg, aa)
	gloaming.graph_apply_attr(&cg, {doc = 0, key = "章", val = "夜"})
	gloaming.graph_apply_attr(&cg, {doc = 1, key = "章", val = "朝"})
	dgs := gloaming.doc_groups(gloaming.graph_doc_attrs(&cg), "章", cdocs, ta)
	ct, cterr := gloaming.cross_table(cstore, dgs, {}, ta)
	testing.expectf(t, cterr == gloaming.Store_Err.None, "cross_table: %v", cterr)
	cx, cxerr := gloaming.cross_chi2(&ct, ta)
	testing.expectf(t, cxerr == gloaming.Freq_Err.None, "cross_chi2: %v", cxerr)
	tc, tcerr := gloaming.table_chi2(&ct)
	testing.expectf(t, tcerr == gloaming.Freq_Err.None, "table_chi2: %v", tcerr)
	_ = tc

	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, ta)
	k_term := gloaming.graph_kind_intern(&g, "term")
	k_codes := gloaming.graph_kind_intern(&g, "codes")
	gnames := []string{"アサ", "霧"}
	for name, i in gnames {
		gloaming.graph_apply_entity(&g, gloaming.Entity{
			id = gloaming.Entity_Id(i), live = true, kind = k_term, name = name,
		})
	}
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = 0, live = true, kind = k_codes, from = 0, to = 1, derived = true,
	})
	gpr, gprerr := gloaming.graph_pagerank(&g, {}, 0.85, 200, 1e-12, ta)
	testing.expectf(t, gprerr == gloaming.Graph_Err.None, "gpr: %v", gprerr)
	tr, trerr := gloaming.graph_traverse(&g, {0}, {}, 2, 10, ta)
	testing.expectf(t, trerr == gloaming.Graph_Err.None, "traverse: %v", trerr)

	es := glexport.pairs_export_dot(pairs, ta)
	ges := glexport.graph_export_mermaid(&g, {}, ta)
	cj := glexport.coords_json(keys, coords, ta)
	wj := glexport.ward_json(keys, merges, ta)

	// free every returned buffer — what remains is the leak
	free_slice(pairs, ta)
	free_slice(capped, ta)
	free_slice(pres.keys, ta)
	free_slice(wt, ta)
	free_slice(dt, ta)
	free_slice(scores, ta)
	free_slice(merges, ta)
	free_slice(labels, ta)
	free_slice(coords, ta)
	free_slice(pr, ta)
	free_slice(gpr, ta)
	free_slice(tr.visits, ta)
	free_slice(kv, ta)
	free_slice(wd, ta)
	free_slice(lm, ta)
	free_slice(kc.keys, ta)
	free_slice(cf, ta)
	for p in dps {
		free_slice(p.keys, ta)
		free_slice(p.counts, ta)
	}
	free_slice(dps, ta)
	free_slice(dw, ta)
	free_slice(dd, ta)
	free_slice(dm, ta)
	for grp in dgs { free_slice(grp.docs, ta) }
	free_slice(dgs, ta)
	free_slice(ct.vals, ta)
	free_slice(ct.sizes, ta)
	free_slice(ct.keys, ta)
	free_slice(ct.cells, ta)
	free_slice(ct.docs, ta)
	for x in cx { free_slice(x.residuals, ta) }
	free_slice(cx, ta)
	gloaming.graph_destroy(&cg)
	free_str(es, ta)
	free_str(ges, ta)
	free_str(cj, ta)
	free_str(wj, ta)
	gloaming.graph_destroy(&g)

	if track.current_memory_allocated != 0 {
		testing.expectf(t, false, "live bytes after freeing the outputs: %d",
			int(track.current_memory_allocated))
	}
}

// one store document from a word list: tokens byte-contiguous over a
// builder-backed text, lemma = surface, the shared noun POS — the
// corpus tests' fixture
mk_store_doc :: proc(store: gloaming.Store, doc: gloaming.Doc_Id,
                     words: []string, a: mem.Allocator) -> gloaming.Store_Err {
	b := strings.builder_make(a)
	toks := make([]gloaming.Token, len(words), a)
	off := 0
	for w, i in words {
		strings.write_string(&b, w)
		toks[i] = gloaming.Token{
			surface = w, lemma = w, pos = "名詞,一般", reading = "x",
			start = off, end = off + len(w),
		}
		off += len(w)
	}
	return store.add_document(store.ctx, doc, strings.to_string(b), toks, {})
}

// The assoc engine's additions (Simpson, Yates, G²) against
// hand references, the weight-table distances, the linkage variants,
// and the min_len filter.
@(test)
assoc_variants_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the symmetric reference contingency (n=8, n_a=10, n_b=10,
	// windows=20): observed [8,2,2,8], expected 5 in every cell —
	// χ² = 4·9/5 = 7.2, Yates = 4·2.5²/5 = 5, and
	// G² = 4·(8 ln 1.6 + 2 ln 0.4) = 7.7097902808703
	chi, cerr := gloaming.assoc_value(.Chi_Square, 8, 10, 10, 20)
	testing.expectf(t, cerr == gloaming.Freq_Err.None, "chi: %v", cerr)
	if !testing.expectf(t, abs_f64(chi - 7.2) < 1e-12, "chi: %f", chi) { return }
	yates, yerr := gloaming.assoc_value(.Chi_Square_Yates, 8, 10, 10, 20)
	testing.expectf(t, yerr == gloaming.Freq_Err.None, "yates: %v", yerr)
	if !testing.expectf(t, abs_f64(yates - 5.0) < 1e-12, "yates: %f", yates) {
		return
	}
	g2, gerr := gloaming.assoc_value(.Log_Likelihood, 8, 10, 10, 20)
	testing.expectf(t, gerr == gloaming.Freq_Err.None, "g2: %v", gerr)
	if !testing.expectf(t, abs_f64(g2 - 7.7097902808703) < 1e-9, "g2: %f", g2) {
		return
	}

	// Simpson compensates where Jaccard underestimates: n=5 on
	// marginals 5 and 100 — Jaccard 0.05, Dice 10/105, Simpson exactly 1
	simp, _ := gloaming.assoc_value(.Simpson, 5, 5, 100, 100)
	if !testing.expectf(t, simp == 1.0, "simpson: %f", simp) { return }
	jac, _ := gloaming.assoc_value(.Jaccard, 5, 5, 100, 100)
	if !testing.expectf(t, abs_f64(jac - 0.05) < 1e-12, "jaccard: %f", jac) {
		return
	}
	dice, _ := gloaming.assoc_value(.Dice, 5, 5, 100, 100)
	if !testing.expectf(t, abs_f64(dice - 10.0/105.0) < 1e-12, "dice: %f", dice) {
		return
	}

	// n_a ↔ n_b symmetry for the three additions (the property grid)
	sym := []gloaming.Assoc_Measure{.Simpson, .Chi_Square_Yates, .Log_Likelihood}
	for m in sym {
		x, _ := gloaming.assoc_value(m, 7, 13, 41, 200)
		y, _ := gloaming.assoc_value(m, 7, 41, 13, 200)
		if !testing.expectf(t, x == y, "%v not symmetric: %f %f", m, x, y) {
			return
		}
	}

	// G² ≈ χ² for small relative deviations (second-order agreement):
	// obs [1010, 8990, 8990, 81010] against expected
	// [1000, 9000, 9000, 81000] — a 1% deviation
	lchi, _ := gloaming.assoc_value(.Chi_Square, 1010, 10000, 10000, 100000)
	lg2, _ := gloaming.assoc_value(.Log_Likelihood, 1010, 10000, 10000, 100000)
	if !testing.expectf(t, abs_f64(lg2 - lchi) / lchi < 0.01,
		"g2/chi drift: %f %f", lg2, lchi) { return }

	// the refusal contract is unchanged
	_, err := gloaming.assoc_value(.Log_Likelihood, 0, 10, 10, 20)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.assoc_value(.Simpson, 11, 10, 10, 20)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// weight_distance: profiles are FULL weight rows. p0 = [0,1,0],
	// p1 = [1,0,2], p2 = [0,2,0]: Euclid d01 = sqrt(6), d02 = 1,
	// d12 = 3; cosine p0⊥p1 and p1⊥p2 (distance 1), p0 ∥ p2 (distance 0)
	w := make([]f64, 9, a)
	w[0 * 3 + 1], w[1 * 3 + 0] = 1, 1
	w[1 * 3 + 2], w[2 * 3 + 1] = 2, 2
	euc, eerr := gloaming.weight_distance(w, 3, .Euclid, a)
	testing.expectf(t, eerr == gloaming.Freq_Err.None, "euclid: %v", eerr)
	if !testing.expectf(t, abs_f64(euc[0 * 3 + 1] - math.sqrt(f64(6))) < 1e-12 &&
		abs_f64(euc[0 * 3 + 2] - 1) < 1e-12 &&
		abs_f64(euc[1 * 3 + 2] - 3) < 1e-12,
		"euclid values: %f %f %f", euc[1], euc[2], euc[5]) { return }
	cos, coerr := gloaming.weight_distance(w, 3, .Cosine, a)
	testing.expectf(t, coerr == gloaming.Freq_Err.None, "cosine: %v", coerr)
	if !testing.expectf(t, cos[0 * 3 + 1] == 1 && cos[0 * 3 + 2] == 0 &&
		cos[1 * 3 + 2] == 1,
		"cosine values: %f %f %f", cos[1], cos[2], cos[5]) { return }
	for i in 0..<3 {
		if !testing.expectf(t, euc[i * 3 + i] == 0, "euclid diag %d", i) { return }
		for j in 0..<3 {
			if !testing.expectf(t, euc[i * 3 + j] == euc[j * 3 + i] &&
				cos[i * 3 + j] == cos[j * 3 + i], "symmetry %d %d", i, j) {
				return
			}
		}
	}

	// zero rows: two zero rows are 0; one zero row against a real one
	// is 1 under cosine, the nonzero norm under euclid
	zw := make([]f64, 4, a)
	zw[0 * 2 + 1], zw[1 * 2 + 0] = 3, 3 // rows [0,3] and [3,0] — nonzero
	zz, zzerr := gloaming.weight_distance(make([]f64, 4, a), 2, .Cosine, a)
	testing.expectf(t, zzerr == gloaming.Freq_Err.None, "zz: %v", zzerr)
	if !testing.expectf(t, zz[1] == 0, "two zero rows: %f", zz[1]) { return }
	ow := make([]f64, 4, a)
	ow[0 * 2 + 0] = 2 // row 0 = [2,0], row 1 = [0,0]
	oc, ocerr := gloaming.weight_distance(ow, 2, .Cosine, a)
	testing.expectf(t, ocerr == gloaming.Freq_Err.None, "oc: %v", ocerr)
	oe, oeerr := gloaming.weight_distance(ow, 2, .Euclid, a)
	testing.expectf(t, oeerr == gloaming.Freq_Err.None, "oe: %v", oeerr)
	if !testing.expectf(t, oc[1] == 1 && oe[1] == 2,
		"one zero row: %f %f", oc[1], oe[1]) { return }

	// refusals: wrong length, negative, non-finite
	_, err = gloaming.weight_distance(w, 4, .Euclid, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	neg := make([]f64, 9, a)
	copy(neg, w)
	neg[0 * 3 + 1] = -1
	_, err = gloaming.weight_distance(neg, 3, .Euclid, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	nn := make([]f64, 9, a)
	copy(nn, w)
	zero := 0.0
	nn[2 * 3 + 1] = zero / zero
	_, err = gloaming.weight_distance(nn, 3, .Cosine, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// linkage: .Ward is bit-for-bit ward_merges; the 1-2-3 chain gives
	// average its (2+3)/2 second height and complete its max
	wm, werr2 := gloaming.ward_merges(euc, 3, a)
	testing.expectf(t, werr2 == gloaming.Freq_Err.None, "ward: %v", werr2)
	fw, fwerr := gloaming.linkage_merges(euc, 3, .Ward, a)
	testing.expectf(t, fwerr == gloaming.Freq_Err.None, "fwd ward: %v", fwerr)
	if !testing.expect_value(t, len(fw), len(wm)) { return }
	for i in 0..<len(wm) {
		if !testing.expectf(t, fw[i] == wm[i], "ward drift at %d", i) { return }
	}

	chain := make([]f64, 9, a) // d01 = 1, d02 = 2, d12 = 3
	chain[0 * 3 + 1], chain[1 * 3 + 0] = 1, 1
	chain[0 * 3 + 2], chain[2 * 3 + 0] = 2, 2
	chain[1 * 3 + 2], chain[2 * 3 + 1] = 3, 3
	avg, aerr := gloaming.linkage_merges(chain, 3, .Average, a)
	testing.expectf(t, aerr == gloaming.Freq_Err.None, "avg: %v", aerr)
	if !testing.expect_value(t, len(avg), 2) { return }
	if !testing.expectf(t, avg[0].a == 0 && avg[0].b == 1 && avg[0].dist == 1 &&
		avg[0].size == 2, "avg first: %v", avg[0]) { return }
	if !testing.expectf(t, avg[1].a == 2 && avg[1].b == 3 &&
		abs_f64(avg[1].dist - 2.5) < 1e-12 && avg[1].size == 3,
		"avg second: %v", avg[1]) { return }
	comp, cmperr := gloaming.linkage_merges(chain, 3, .Complete, a)
	testing.expectf(t, cmperr == gloaming.Freq_Err.None, "comp: %v", cmperr)
	if !testing.expectf(t, comp[1].dist == 3, "comp second: %f", comp[1].dist) {
		return
	}
	// monotone heights on both variants
	for i in 0..<1 {
		if !testing.expectf(t, avg[i].dist <= avg[i + 1].dist &&
			comp[i].dist <= comp[i + 1].dist, "height dip at %d", i) { return }
	}

	// small-n and refusal contract
	single := make([]f64, 1, a)
	one, oneerr := gloaming.linkage_merges(single, 1, .Average, a)
	testing.expectf(t, oneerr == gloaming.Freq_Err.None, "one: %v", oneerr)
	testing.expect_value(t, len(one), 0)
	_, err = gloaming.linkage_merges(chain, 4, .Average, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	negd := make([]f64, 9, a)
	copy(negd, chain)
	negd[0 * 3 + 1] = -1
	negd[1 * 3 + 0] = -1
	_, err = gloaming.linkage_merges(negd, 3, .Complete, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// min_len: the length gate applies to the counting key — surface
	// counting drops every 1-rune surface, lemma counting keeps the
	// token whose lemma is 2 runes; 0/1 switch it off
	toks := make([]gloaming.Token, 3, a)
	toks[0] = {surface = "猫", lemma = "猫", pos = "名詞", start = 0, end = 3}
	toks[1] = {surface = "犬", lemma = "いぬ", pos = "名詞", start = 3, end = 6}
	toks[2] = {surface = "空", lemma = "空", pos = "名詞", start = 6, end = 9}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks}

	surf, _ := gloaming.freq_table(stream, {}, {min_len = 2}, a)
	testing.expect_value(t, len(surf), 0)
	lem, _ := gloaming.freq_table(stream, {}, {min_len = 2, use_lemma = true}, a)
	if !testing.expect_value(t, len(lem), 1) { return }
	testing.expectf(t, lem[0].lemma == "いぬ" && lem[0].count == 1,
		"lemma row: %v", lem[0])
	off1, _ := gloaming.freq_table(stream, {}, {min_len = 1}, a)
	testing.expect_value(t, len(off1), 3)
	off0, _ := gloaming.freq_table(stream, {}, {}, a)
	testing.expect_value(t, len(off0), 3)
}

// Keyness against the hand-worked 2×2, the swap symmetries,
// the degenerate pins, both bases, and the refusal contract.
@(test)
keyness_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// a=8, b=2, c=2, d=8: Differential = 0.8−0.2 = 0.6, Lift = 4,
	// Jaccard = 8/12, Ochiai = 8/10, χ² = 7.2, Yates = 5,
	// G² = 7.7097902808703; Fisher is the upper-tail hypergeometric
	// of the same contingency — pinned against assoc_value directly
	target := []gloaming.Freq_Entry{{lemma = "X", count = 8, docs = 8}}
	ref := []gloaming.Freq_Entry{{lemma = "X", count = 2, docs = 2}}
	cases := []struct {
		m:    gloaming.Key_Measure,
		want: f64,
	}{
		{m = .Differential, want = 0.6},
		{m = .Lift, want = 4.0},
		{m = .Jaccard, want = 8.0 / 12.0},
		{m = .Ochiai, want = 0.8},
		{m = .Chi_Square, want = 7.2},
		{m = .Chi_Square_Yates, want = 5.0},
		{m = .Log_Likelihood, want = 7.7097902808703},
	}
	for c in cases {
		rows, err := gloaming.keyness_scores(target, 10, ref, 10, {m = c.m}, a)
		testing.expectf(t, err == gloaming.Freq_Err.None, "%v: %v", c.m, err)
		if !testing.expect_value(t, len(rows), 1) { return }
		if !testing.expectf(t, abs_f64(rows[0].value - c.want) < 1e-9,
			"%v: %f want %f", c.m, rows[0].value, c.want) { return }
		if !testing.expectf(t, rows[0].a == 8 && rows[0].b == 2 &&
			rows[0].c == 2 && rows[0].d == 8,
			"%v cells: %v", c.m, rows[0]) { return }
	}
	// identity with assoc_value through the mapped parameters
	// (n = a, n_a = a+b, n_b = a+c, windows = N)
	id_pairs := []struct {
		km: gloaming.Key_Measure,
		am: gloaming.Assoc_Measure,
	}{
		{km = .Chi_Square, am = .Chi_Square},
		{km = .Chi_Square_Yates, am = .Chi_Square_Yates},
		{km = .Log_Likelihood, am = .Log_Likelihood},
		{km = .Fisher_Exact, am = .Fisher_Exact},
	}
	for p in id_pairs {
		rows, _ := gloaming.keyness_scores(target, 10, ref, 10, {m = p.km}, a)
		av, aerr := gloaming.assoc_value(p.am, 8, 10, 10, 20)
		testing.expectf(t, aerr == gloaming.Freq_Err.None, "av %v: %v", p.am, aerr)
		if !testing.expectf(t, rows[0].value == av,
			"identity %v: %f vs %f", p.am, rows[0].value, av) { return }
	}

	// swap target and reference: the transposed contingency negates
	// Differential, inverts Lift, and leaves the symmetric test
	// statistics (χ², Yates, G²) unchanged — the (O, E) multiset is
	// transpose-invariant. Jaccard and Ochiai are directional (the
	// set ratios read the target's share), and Fisher's one-sided tail
	// flips with the hypothesis; their swapped values are asserted
	// against the transposed cells: a'=2, b'=8, c'=8, d'=2
	fd, _ := gloaming.keyness_scores(target, 10, ref, 10, {m = .Differential}, a)
	rd, _ := gloaming.keyness_scores(ref, 10, target, 10, {m = .Differential}, a)
	if !testing.expectf(t, abs_f64(rd[0].value + fd[0].value) < 1e-12,
		"differential swap: %f %f", fd[0].value, rd[0].value) { return }
	fl2, _ := gloaming.keyness_scores(target, 10, ref, 10, {m = .Lift}, a)
	rl2, _ := gloaming.keyness_scores(ref, 10, target, 10, {m = .Lift}, a)
	if !testing.expectf(t, abs_f64(rl2[0].value * fl2[0].value - 1) < 1e-12,
		"lift swap: %f %f", fl2[0].value, rl2[0].value) { return }
	invariant := []gloaming.Key_Measure{.Chi_Square, .Chi_Square_Yates, .Log_Likelihood}
	for m in invariant {
		f, ferr := gloaming.keyness_scores(target, 10, ref, 10, {m = m}, a)
		testing.expectf(t, ferr == gloaming.Freq_Err.None, "%v: %v", m, ferr)
		r, rerr := gloaming.keyness_scores(ref, 10, target, 10, {m = m}, a)
		testing.expectf(t, rerr == gloaming.Freq_Err.None, "%v swap: %v", m, rerr)
		// mathematically equal; the transposed cell order can differ by
		// an ulp of floating-point summation
		if !testing.expectf(t, abs_f64(r[0].value - f[0].value) < 1e-9,
			"swap %v: %f %f", m, f[0].value, r[0].value) { return }
	}
	sj, _ := gloaming.keyness_scores(ref, 10, target, 10, {m = .Jaccard}, a)
	if !testing.expectf(t, abs_f64(sj[0].value - 2.0/18.0) < 1e-12,
		"jaccard swap: %f", sj[0].value) { return }
	so, _ := gloaming.keyness_scores(ref, 10, target, 10, {m = .Ochiai}, a)
	if !testing.expectf(t, abs_f64(so[0].value - 0.2) < 1e-12,
		"ochiai swap: %f", so[0].value) { return }
	sf, _ := gloaming.keyness_scores(ref, 10, target, 10, {m = .Fisher_Exact}, a)
	if !testing.expectf(t, sf[0].value >= 0 && sf[0].value <= 1,
		"fisher swap: %f", sf[0].value) { return }

	// union vocabulary: a target-only word is the most characteristic
	// (Lift +Inf, first row); a ref-only word is avoidance (negative
	// Differential, Lift 0, last row)
	tt := []gloaming.Freq_Entry{{lemma = "仅", count = 2, docs = 2}, {lemma = "共", count = 6, docs = 6}}
	rr := []gloaming.Freq_Entry{{lemma = "共", count = 3, docs = 3}, {lemma = "両", count = 4, docs = 4}}
	lift, lerr := gloaming.keyness_scores(tt, 8, rr, 8, {m = .Lift}, a)
	testing.expectf(t, lerr == gloaming.Freq_Err.None, "lift: %v", lerr)
	if !testing.expect_value(t, len(lift), 3) { return }
	if !testing.expectf(t, lift[0].key == "仅" && lift[0].value > 1e308,
		"target-only first: %v", lift[0]) { return }
	if !testing.expectf(t, lift[2].key == "両" && lift[2].value == 0,
		"ref-only last: %v", lift[2]) { return }
	dif, _ := gloaming.keyness_scores(tt, 8, rr, 8, {m = .Differential}, a)
	if !testing.expectf(t, dif[2].key == "両" && dif[2].value < 0,
		"avoidance tails: %v", dif[2]) { return }
	// 0 <= Jaccard, Ochiai <= 1 and Fisher <= 1 on the same tables
	ratio_ms := []gloaming.Key_Measure{.Jaccard, .Ochiai, .Fisher_Exact}
	for m in ratio_ms {
		rows, _ := gloaming.keyness_scores(tt, 8, rr, 8, {m = m}, a)
		for r in rows {
			if !testing.expectf(t, r.value >= 0 && r.value <= 1,
				"%v out of [0,1]: %v", m, r) { return }
		}
	}

	// the .Tokens basis takes counts as cells
	tok, _ := gloaming.keyness_scores(
		[]gloaming.Freq_Entry{{lemma = "Y", count = 3, docs = 1}}, 5,
		[]gloaming.Freq_Entry{{lemma = "Y", count = 1, docs = 1}}, 15,
		{m = .Differential, basis = .Tokens}, a)
	if !testing.expect_value(t, len(tok), 1) { return }
	if !testing.expectf(t, abs_f64(tok[0].value - (3.0/5.0 - 1.0/15.0)) < 1e-12,
		"tokens basis: %f", tok[0].value) { return }

	// refusals: population < 1, cell above population, duplicate key
	_, err := gloaming.keyness_scores(target, 0, ref, 10, {}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.keyness_scores(target, 7, ref, 10, {}, a) // cell 8 > 7
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	dup := []gloaming.Freq_Entry{{lemma = "X", count = 1, docs = 1}, {lemma = "X", count = 1, docs = 1}}
	_, err = gloaming.keyness_scores(dup, 10, ref, 10, {}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.keyness_scores(target, 10, dup, 10, {}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))

	// a zero cell is the NaN shape: a=0
	// with c=0 divides 0/0 in Ochiai — refused on either side
	zero := []gloaming.Freq_Entry{{lemma = "零", count = 0, docs = 0}}
	_, err = gloaming.keyness_scores(zero, 10, ref, 10, {m = .Ochiai}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	_, err = gloaming.keyness_scores(target, 10, zero, 10, {m = .Jaccard}, a)
	testing.expect_value(t, int(err), int(gloaming.Freq_Err.Bad_Count))
	// the ref-only row that stays scores exactly 0, never NaN
	zero_ms := []gloaming.Key_Measure{.Jaccard, .Ochiai}
	for m in zero_ms {
		rows, zerr := gloaming.keyness_scores(tt, 8, rr, 8, {m = m}, a)
		testing.expectf(t, zerr == gloaming.Freq_Err.None, "%v: %v", m, zerr)
		last := rows[len(rows) - 1]
		if !testing.expectf(t, last.key == "両" && last.value == 0,
			"%v ref-only: %v", m, last) { return }
	}
}

// Direct coverage for the public read/rewrite surfaces: the
// mention read and row rewrite, the
// live lookup, and the owner-conditional name unmap (the merge remap
// mechanism).
@(test)
graph_read_surfaces :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	kt := gloaming.graph_kind_intern(&g, "term")

	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 0, live = true, kind = kt, name = "アサ",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 1, live = false, kind = gloaming.KIND_NONE, name = "霧",
	})

	// entity_live: in-bounds live, in-bounds dead, out-of-bounds,
	// negative — bounds and the flag, nothing else
	testing.expect_value(t, gloaming.graph_entity_live(&g, 0), true)
	testing.expect_value(t, gloaming.graph_entity_live(&g, 1), false)
	testing.expect_value(t, gloaming.graph_entity_live(&g, 2), false)
	testing.expect_value(t, gloaming.graph_entity_live(&g, -1), false)

	// mentions: the row index is the mention id — append past the
	// end, rewrite in range; the read filters by entity in row order
	gloaming.graph_apply_mention(&g, 0, {entity = 0, span = {doc = 0, start = 0, end = 3}})
	gloaming.graph_apply_mention(&g, 1, {entity = 1, span = {doc = 0, start = 3, end = 6}})
	gloaming.graph_apply_mention(&g, 2, {entity = 0, span = {doc = 0, start = 9, end = 12}})
	zero := gloaming.graph_mentions(&g, 0, a)
	if !testing.expect_value(t, len(zero), 2) { return }
	testing.expectf(t, zero[0].span.start == 0 && zero[1].span.start == 9,
		"mention row order: %v", zero)
	one := gloaming.graph_mentions(&g, 1, a)
	if !testing.expect_value(t, len(one), 1) { return }
	gloaming.graph_apply_mention(&g, 1, {entity = 0, span = {doc = 0, start = 15, end = 18}})
	if !testing.expect_value(t, len(gloaming.graph_mentions(&g, 1, a)), 0) { return }
	if !testing.expect_value(t, len(gloaming.graph_mentions(&g, 0, a)), 3) { return }

	// unmap_names is owner-conditional: a name another row owns stays
	gloaming.graph_unmap_names(&g, gloaming.Entity{
		id = 5, live = true, kind = kt, name = "アサ",
	})
	_, still := g.by_name["アサ"]
	testing.expect_value(t, still, true)
	gloaming.graph_unmap_names(&g, gloaming.Entity{
		id = 0, live = true, kind = kt, name = "アサ",
	})
	_, gone := g.by_name["アサ"]
	testing.expect_value(t, gone, false)

	// the alias path: rewriting a row unmaps the previous row's names
	// (canonical and aliases) and a dead rewrite registers none
	ali := make([]string, 1, a)
	ali[0] = "夜霧"
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 2, live = true, kind = kt, name = "港", aliases = ali,
	})
	_, has_alias := g.by_name["夜霧"]
	testing.expect_value(t, has_alias, true)
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 2, live = false, kind = gloaming.KIND_NONE, name = "港", aliases = ali,
	})
	_, alias_gone := g.by_name["夜霧"]
	testing.expect_value(t, alias_gone, false)
	_, port_gone := g.by_name["港"]
	testing.expect_value(t, port_gone, false)
}

// The helpers underneath the corpus passes, direct:
// cooc_filtered's scope cut and filter drop, token_at_or_after's
// boundaries, corpus_count_maps' counting and duplicate refusal.
@(test)
corpus_helper_surfaces :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	rows := []string{
		"猫	名詞,一般,*,*,*	猫	ネコ	0	3	-	0",
		"犬	名詞,一般,*,*,*	いぬ	イヌ	3	6	-	0",
		"空	名詞,一般,*,*,*	空	ソラ	6	9	-	0",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks}

	// token_at_or_after: the first token starting at or past the byte
	// offset; past the end is len
	testing.expect_value(t, gloaming.token_at_or_after(toks, 0), 0)
	testing.expect_value(t, gloaming.token_at_or_after(toks, 1), 1)
	testing.expect_value(t, gloaming.token_at_or_after(toks, 3), 1)
	testing.expect_value(t, gloaming.token_at_or_after(toks, 6), 2)
	testing.expect_value(t, gloaming.token_at_or_after(toks, 9), 3)

	// cooc_filtered: the whole stream under an open filter
	all_idx, all_keys, aerr := gloaming.cooc_filtered(stream, {}, {}, a, nil, nil)
	testing.expectf(t, aerr == gloaming.Freq_Err.None, "open: %v", aerr)
	if !testing.expect_value(t, len(all_keys), 3) { return }
	testing.expectf(t, all_idx[0] == 0 && all_idx[1] == 1 && all_idx[2] == 2,
		"open idxs: %v", all_idx)
	delete(all_idx)
	delete(all_keys)

	// a scope cut keeps only the tokens whose start falls inside
	sc := make([]gloaming.Segment, 1, a)
	sc[0] = {kind = .Sentence, span = {doc = 0, start = 3, end = 9}}
	s_idx, s_keys, serr := gloaming.cooc_filtered(stream, sc, {}, a, nil, nil)
	testing.expectf(t, serr == gloaming.Freq_Err.None, "scope: %v", serr)
	if !testing.expect_value(t, len(s_keys), 2) { return }
	testing.expectf(t, s_keys[0] == "犬" && s_keys[1] == "空",
		"scope keys: %v", s_keys)
	delete(s_idx)
	delete(s_keys)

	// the filter drop: min_len 2 on lemmas keeps only いぬ (index 1)
	f_idx, f_keys, ferr := gloaming.cooc_filtered(
		stream, {}, {min_len = 2, use_lemma = true}, a, nil, nil)
	testing.expectf(t, ferr == gloaming.Freq_Err.None, "filter: %v", ferr)
	if !testing.expect_value(t, len(f_keys), 1) { return }
	testing.expectf(t, f_keys[0] == "いぬ" && f_idx[0] == 1,
		"filter keys: %v %v", f_keys, f_idx)
	delete(f_idx)
	delete(f_keys)

	// corpus_count_maps: occurrence sums and per-doc presence over a
	// memory store; a duplicate doc refuses .Duplicate
	store, sterr := gloaming.store_memory(a)
	testing.expectf(t, sterr == gloaming.Store_Err.None, "store: %v", sterr)
	testing.expectf(t, mk_store_doc(store, 0, {"猫", "犬"}, a) == gloaming.Store_Err.None, "doc 0")
	testing.expectf(t, mk_store_doc(store, 1, {"猫", "鳥"}, a) == gloaming.Store_Err.None, "doc 1")
	counts, ndocs, merr := gloaming.corpus_count_maps(store, {0, 1}, {}, a)
	testing.expectf(t, merr == gloaming.Store_Err.None, "maps: %v", merr)
	if !testing.expect_value(t, len(counts), 3) { return }
	testing.expectf(t, counts["猫"] == 2 && counts["犬"] == 1 && counts["鳥"] == 1,
		"counts: %v", counts)
	testing.expectf(t, ndocs["猫"] == 2 && ndocs["犬"] == 1 && ndocs["鳥"] == 1,
		"ndocs: %v", ndocs)
	delete(counts)
	delete(ndocs)
	_, _, derr := gloaming.corpus_count_maps(store, {0, 0}, {}, a)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Duplicate))
}

// The corpus layer over a three-document store — hand-checked
// counts and doc counts, the per-document differential, weights and
// both distances with their degenerate pins, one Ward merge height,
// the tf/tf-idf matrix, and the refusal contract.
@(test)
corpus_tables_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	store, serr := gloaming.store_memory(a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store: %v", serr)
	// doc0: 猫 犬 猫 空; doc1: 猫 鳥 空; doc2: 犬 犬 空
	testing.expectf(t, mk_store_doc(store, 0, {"猫", "犬", "猫", "空"}, a) == gloaming.Store_Err.None, "doc 0")
	testing.expectf(t, mk_store_doc(store, 1, {"猫", "鳥", "空"}, a) == gloaming.Store_Err.None, "doc 1")
	testing.expectf(t, mk_store_doc(store, 2, {"犬", "犬", "空"}, a) == gloaming.Store_Err.None, "doc 2")
	all := []gloaming.Doc_Id{0, 1, 2}

	cf, err := gloaming.corpus_freq(store, all, {}, a)
	testing.expectf(t, err == gloaming.Store_Err.None, "corpus: %v", err)
	// count desc then key asc: 犬(3,2) 猫(3,2) 空(3,3) 鳥(1,1)
	want := []gloaming.Freq_Entry{
		{lemma = "犬", count = 3, docs = 2},
		{lemma = "猫", count = 3, docs = 2},
		{lemma = "空", count = 3, docs = 3},
		{lemma = "鳥", count = 1, docs = 1},
	}
	if !testing.expect_value(t, len(cf), 4) { return }
	for i in 0..<4 {
		if !testing.expectf(t, cf[i].lemma == want[i].lemma && cf[i].count == want[i].count &&
			cf[i].docs == want[i].docs, "row %d: %v", i, cf[i]) { return }
	}

	// differential: the corpus count is the per-document freq_table sum,
	// and docs never exceeds the population
	sums := make(map[string]int, a)
	for d in all {
		toks, terr := store.tokens(store.ctx, d, a)
		testing.expectf(t, terr == gloaming.Store_Err.None, "tokens: %v", terr)
		ft, ferr := gloaming.freq_table({doc = d, tokens = toks}, {}, {}, a)
		testing.expectf(t, ferr == gloaming.Freq_Err.None, "freq: %v", ferr)
		for e in ft {
			sums[e.lemma] += e.count
			if !testing.expectf(t, e.docs == 1, "per-doc docs: %v", e) { return }
		}
	}
	if !testing.expect_value(t, len(sums), len(cf)) { return }
	for e in cf {
		s, ok := sums[e.lemma]
		if !testing.expectf(t, ok && s == e.count, "sum %v: %d vs %d", e.lemma, s, e.count) {
			return
		}
		if !testing.expectf(t, e.docs <= len(all), "docs bound: %v", e) { return }
	}
	// min_count is an output filter here too
	mc, _ := gloaming.corpus_freq(store, all, {min_count = 2}, a)
	if !testing.expect_value(t, len(mc), 3) { return }
	testing.expectf(t, mc[2].lemma == "空", "min_count row: %v", mc[2])

	// refusals: a duplicate doc and a missing doc
	_, derr := gloaming.corpus_freq(store, {0, 0}, {}, a)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Duplicate))
	_, nerr := gloaming.corpus_freq(store, {9}, {}, a)
	testing.expect_value(t, int(nerr), int(gloaming.Store_Err.Not_Found))

	// profiles: keys ascending with parallel counts, list order kept
	ps, perr := gloaming.doc_profiles(store, all, {}, a)
	testing.expectf(t, perr == gloaming.Store_Err.None, "profiles: %v", perr)
	if !testing.expect_value(t, len(ps), 3) { return }
	if !testing.expectf(t, ps[0].doc == 0, "order: %v", ps[0].doc) { return }
	p0k := []string{"犬", "猫", "空"}
	p0c := []int{1, 2, 1}
	if !testing.expect_value(t, len(ps[0].keys), 3) { return }
	for i in 0..<3 {
		if !testing.expectf(t, ps[0].keys[i] == p0k[i] && ps[0].counts[i] == p0c[i],
			"doc0 profile %d: %v %v", i, ps[0].keys[i], ps[0].counts[i]) { return }
	}
	if !testing.expectf(t, ps[1].keys[0] == "猫" && ps[1].keys[1] == "空" && ps[1].keys[2] == "鳥",
		"doc1 profile order") { return }
	if !testing.expectf(t, len(ps[2].keys) == 2 && ps[2].keys[0] == "犬" && ps[2].keys[1] == "空",
		"doc2 profile order") { return }

	// weights: shared-presence counts, symmetric, zero diagonal
	w, werr := gloaming.doc_weights(ps, a)
	testing.expectf(t, werr == gloaming.Freq_Err.None, "weights: %v", werr)
	for i in 0..<3 {
		if !testing.expectf(t, w[i * 3 + i] == 0, "diag %d", i) { return }
		for j in 0..<3 {
			if !testing.expectf(t, w[i * 3 + j] == w[j * 3 + i], "sym %d %d", i, j) {
				return
			}
		}
	}
	if !testing.expectf(t, w[0 * 3 + 1] == 2 && w[0 * 3 + 2] == 2 && w[1 * 3 + 2] == 1,
		"weights: %f %f %f", w[1], w[2], w[5]) { return }

	// Jaccard: 1 − 2/4, 1 − 2/3, 1 − 1/4; the doc-side Ward reference
	jd, jerr := gloaming.doc_distance(ps, .Jaccard, a)
	testing.expectf(t, jerr == gloaming.Freq_Err.None, "jaccard: %v", jerr)
	if !testing.expectf(t, abs_f64(jd[0 * 3 + 1] - 0.5) < 1e-12 &&
		abs_f64(jd[0 * 3 + 2] - (1.0 - 2.0/3.0)) < 1e-12 &&
		abs_f64(jd[1 * 3 + 2] - 0.75) < 1e-12,
		"jaccard values: %f %f %f", jd[1], jd[2], jd[5]) { return }
	wm, wmerr := gloaming.ward_merges(jd, 3, a)
	testing.expectf(t, wmerr == gloaming.Freq_Err.None, "ward: %v", wmerr)
	if !testing.expect_value(t, len(wm), 2) { return }
	if !testing.expectf(t, wm[0].a == 0 && wm[0].b == 2 &&
		abs_f64(wm[0].dist - 1.0/3.0) < 1e-12 && wm[0].size == 2,
		"first merge: %v", wm[0]) { return }
	// second height by the Lance–Williams recurrence:
	// sqrt((2·0.25 + 2·0.5625 − (1/3)²)/3) = sqrt(109/216)
	if !testing.expectf(t, wm[1].a == 1 && wm[1].b == 3 &&
		abs_f64(wm[1].dist - math.sqrt(f64(109.0/216.0))) < 1e-12 && wm[1].size == 3,
		"second merge: %v", wm[1]) { return }

	// Cosine over count vectors: doc0·doc1 = 3 over sqrt(6)·sqrt(3),
	// doc0·doc2 = 3 over sqrt(6)·sqrt(5), doc1·doc2 = 1 over
	// sqrt(3)·sqrt(5)
	cd, cderr := gloaming.doc_distance(ps, .Cosine, a)
	testing.expectf(t, cderr == gloaming.Freq_Err.None, "cosine: %v", cderr)
	if !testing.expectf(t, abs_f64(cd[0 * 3 + 1] - (1 - 3.0/math.sqrt(f64(18.0)))) < 1e-12 &&
		abs_f64(cd[0 * 3 + 2] - (1 - 3.0/math.sqrt(f64(30.0)))) < 1e-12 &&
		abs_f64(cd[1 * 3 + 2] - (1 - 1.0/math.sqrt(f64(15.0)))) < 1e-12,
		"cosine values: %f %f %f", cd[1], cd[2], cd[5]) { return }

	// degenerate pins: two empty profiles are identical (0); one empty
	// against anything is 1 under both measures
	empty := []gloaming.Doc_Profile{
		{doc = 7, keys = {}, counts = {}},
		{doc = 8, keys = {}, counts = {}},
		{doc = 9, keys = {"猫"}, counts = {2}},
	}
	ew, eerr := gloaming.doc_weights(empty, a)
	testing.expectf(t, eerr == gloaming.Freq_Err.None, "empty weights: %v", eerr)
	if !testing.expectf(t, ew[0] == 0 && ew[2] == 0, "empty weights: %v", ew) { return }
	ej, ejerr := gloaming.doc_distance(empty, .Jaccard, a)
	testing.expectf(t, ejerr == gloaming.Freq_Err.None, "empty jaccard: %v", ejerr)
	ec, ecerr := gloaming.doc_distance(empty, .Cosine, a)
	testing.expectf(t, ecerr == gloaming.Freq_Err.None, "empty cosine: %v", ecerr)
	if !testing.expectf(t, ej[0] == 0 && ec[0] == 0 && ej[2] == 1 && ec[2] == 1,
		"empty pins: %f %f", ej[2], ec[2]) { return }

	// the matrix: tf = the profile count, tf-idf = tf·ln(N/df) — 空 is
	// present in every document, so its idf is 0 and its weight with it
	keys := []string{"犬", "猫", "空", "鳥"}
	tf, tferr := gloaming.doc_matrix(ps, keys, cf, .Tf, a)
	testing.expectf(t, tferr == gloaming.Freq_Err.None, "tf: %v", tferr)
	tid, tiderr := gloaming.doc_matrix(ps, keys, cf, .Tf_Idf, a)
	testing.expectf(t, tiderr == gloaming.Freq_Err.None, "tfidf: %v", tiderr)
	tf0 := []f64{1, 2, 1, 0}
	for i in 0..<4 {
		if !testing.expectf(t, tf[0 * 4 + i] == tf0[i],
			"tf row: %f want %f", tf[i], tf0[i]) { return }
		want_id := tf0[i] * math.ln(3.0 / f64(want[i].docs))
		if !testing.expectf(t, abs_f64(tid[0 * 4 + i] - want_id) < 1e-12,
			"tfidf cell %d: %f want %f", i, tid[i], want_id) { return }
	}
	for d_ in 0..<3 {
		if !testing.expectf(t, tid[d_ * 4 + 2] == 0,
			"everywhere-present idf: %f", tid[d_ * 4 + 2]) { return }
	}

	// matrix refusals: key outside df, df above N, duplicate key, dup df
	_, merr2 := gloaming.doc_matrix(ps, {"犬", "無"}, cf, .Tf, a)
	testing.expect_value(t, int(merr2), int(gloaming.Freq_Err.Bad_Count))
	_, merr3 := gloaming.doc_matrix(ps, keys, {{lemma = "犬", count = 3, docs = 4}}, .Tf, a)
	testing.expect_value(t, int(merr3), int(gloaming.Freq_Err.Bad_Count))
	_, merr4 := gloaming.doc_matrix(ps, {"犬", "犬"}, cf, .Tf, a)
	testing.expect_value(t, int(merr4), int(gloaming.Freq_Err.Bad_Count))
	_, merr5 := gloaming.doc_matrix(ps, keys,
		{{lemma = "犬", count = 3, docs = 2}, {lemma = "犬", count = 3, docs = 2}}, .Tf, a)
	testing.expect_value(t, int(merr5), int(gloaming.Freq_Err.Bad_Count))

	// duplicate keys in a hand-built profile refuse both table procs
	bad := []gloaming.Doc_Profile{{doc = 0, keys = {"猫", "猫"}, counts = {1, 1}}}
	_, bwerr := gloaming.doc_weights(bad, a)
	testing.expect_value(t, int(bwerr), int(gloaming.Freq_Err.Bad_Count))
	_, bderr := gloaming.doc_distance(bad, .Cosine, a)
	testing.expect_value(t, int(bderr), int(gloaming.Freq_Err.Bad_Count))
}

// The Doc_Attr read side — the view, doc_groups, the cross
// table with its differential, and the k×2 / whole-table tests against
// a hand-worked two-group fixture.
@(test)
crosstab_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// the graph reader: borrowed rows, upsert is last-wins in place
	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	gloaming.graph_apply_attr(&g, {doc = 0, key = "章", val = "夜"})
	gloaming.graph_apply_attr(&g, {doc = 1, key = "章", val = "夜"})
	gloaming.graph_apply_attr(&g, {doc = 4, key = "章", val = "夜"})
	view := gloaming.graph_doc_attrs(&g)
	if !testing.expect_value(t, len(view), 3) { return }
	testing.expectf(t, view[1].doc == 1 && view[1].key == "章" && view[1].val == "夜",
		"view row: %v", view[1])
	gloaming.graph_apply_attr(&g, {doc = 4, key = "章", val = "朝"})
	view2 := gloaming.graph_doc_attrs(&g)
	if !testing.expect_value(t, len(view2), 3) { return } // upsert, not append
	testing.expectf(t, view2[2].val == "朝", "upsert row: %v", view2[2])

	// the store fixture: eight docs, 章 夜 for 0..3 and 朝 for 4..7;
	// X in docs 0,1,2,4; Y in every doc
	store, serr := gloaming.store_memory(a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store: %v", serr)
	xdocs := [8]bool{true, true, true, false, true, false, false, false}
	for i in 0..<8 {
		words := xdocs[i] ? []string{"X", "Y"} : []string{"Y"}
		testing.expectf(t, mk_store_doc(store, gloaming.Doc_Id(i), words, a) == gloaming.Store_Err.None,
			"doc %d", i)
		gloaming.graph_apply_attr(&g, {
			doc = gloaming.Doc_Id(i), key = "章",
			val = i < 4 ? "夜" : "朝",
		})
	}
	pop := make([]gloaming.Doc_Id, 8, a)
	for i in 0..<8 { pop[i] = gloaming.Doc_Id(i) }

	// doc_groups: value-ascending groups, ascending doc lists
	groups := gloaming.doc_groups(gloaming.graph_doc_attrs(&g), "章", pop, a)
	if !testing.expect_value(t, len(groups), 2) { return }
	if !testing.expectf(t, groups[0].val == "夜" && groups[1].val == "朝",
		"vals: %v %v", groups[0].val, groups[1].val) { return }
	for i in 0..<4 {
		if !testing.expectf(t, groups[0].docs[i] == gloaming.Doc_Id(i) &&
			groups[1].docs[i] == gloaming.Doc_Id(i + 4), "docs %d", i) { return }
	}
	// a doc without the attribute lands in the "" group, which sorts first
	short := gloaming.doc_groups(gloaming.graph_doc_attrs(&g)[:7], "章", pop, a)
	if !testing.expect_value(t, len(short), 3) { return }
	if !testing.expectf(t, short[0].val == "" && len(short[0].docs) == 1 &&
		short[0].docs[0] == 7, "missing group: %v", short[0]) { return }

	// the cross table: Y totals 8 before X's 4; presence cells beside
	// occurrence cells; column sums match per-group corpus_freq
	ct, cterr := gloaming.cross_table(store, groups, {}, a)
	testing.expectf(t, cterr == gloaming.Store_Err.None, "cross: %v", cterr)
	if !testing.expect_value(t, len(ct.keys), 2) { return }
	if !testing.expectf(t, ct.vals[0] == "夜" && ct.vals[1] == "朝" &&
		ct.sizes[0] == 4 && ct.sizes[1] == 4, "columns: %v %v", ct.vals, ct.sizes) {
		return
	}
	if !testing.expectf(t, ct.keys[0] == "Y" && ct.cells[0] == 4 && ct.cells[1] == 4 &&
		ct.docs[0] == 4 && ct.docs[1] == 4, "Y row: %v", ct.cells[0:2]) { return }
	if !testing.expectf(t, ct.keys[1] == "X" && ct.cells[2] == 3 && ct.cells[3] == 1 &&
		ct.docs[2] == 3 && ct.docs[3] == 1, "X row: %v", ct.cells[2:4]) { return }
	for j in 0..<2 {
		gf, gferr := gloaming.corpus_freq(store, groups[j].docs, {}, a)
		testing.expectf(t, gferr == gloaming.Store_Err.None, "group freq: %v", gferr)
		for e in gf {
			row := e.lemma == "Y" ? 0 : 1
			if !testing.expectf(t, ct.cells[row * 2 + j] == e.count,
				"column %d %v: %d vs %d", j, e.lemma, ct.cells[row * 2 + j], e.count) {
				return
			}
		}
	}

	// cross_chi2 hand reference: X is the [[3,1],[1,3]] table —
	// χ² = 2 and residuals ±sqrt(2); Y is everywhere, so p_row = 1 and
	// its residuals are pinned 0 (its χ² comes from the absent cells)
	tests, xerr := gloaming.cross_chi2(&ct, a)
	testing.expectf(t, xerr == gloaming.Freq_Err.None, "cross_chi2: %v", xerr)
	if !testing.expect_value(t, len(tests), 2) { return }
	if !testing.expectf(t, tests[0].key == "Y" && tests[0].chi2 == 8 &&
		tests[0].residuals[0] == 0 && tests[0].residuals[1] == 0,
		"Y test: %v %v", tests[0].chi2, tests[0].residuals) { return }
	if !testing.expectf(t, tests[1].key == "X" &&
		abs_f64(tests[1].chi2 - 2) < 1e-12 &&
		abs_f64(tests[1].residuals[0] - math.sqrt(f64(2))) < 1e-12 &&
		abs_f64(tests[1].residuals[1] + math.sqrt(f64(2))) < 1e-12,
		"X test: %v %v", tests[1].chi2, tests[1].residuals) { return }

	// the whole-table statistic by hand: rows Y[4,4] X[3,1], column
	// sums [7,5], grand 12 — χ² = 24/35
	tchi, terr := gloaming.table_chi2(&ct)
	testing.expectf(t, terr == gloaming.Freq_Err.None, "table_chi2: %v", terr)
	if !testing.expectf(t, abs_f64(tchi - 24.0/35.0) < 1e-12, "table: %f", tchi) {
		return
	}

	// refusals: duplicate docs inside a group, ragged and out-of-range
	// hand tables
	dupg := []gloaming.Doc_Group{{val = "夜", docs = {0, 0}}}
	_, derr := gloaming.cross_table(store, dupg, {}, a)
	testing.expect_value(t, int(derr), int(gloaming.Store_Err.Duplicate))
	ragged := gloaming.Cross_Table{
		vals = {"a"}, sizes = {2}, keys = {"X"},
		cells = {1, 1}, docs = {1, 1},
	}
	_, rerr := gloaming.cross_chi2(&ragged, a)
	testing.expect_value(t, int(rerr), int(gloaming.Freq_Err.Bad_Count))
	oob := gloaming.Cross_Table{
		vals = {"a"}, sizes = {2}, keys = {"X"},
		cells = {2}, docs = {3},
	}
	_, oerr := gloaming.cross_chi2(&oob, a)
	testing.expect_value(t, int(oerr), int(gloaming.Freq_Err.Bad_Count))
	_, ter2 := gloaming.table_chi2(&ragged)
	testing.expect_value(t, int(ter2), int(gloaming.Freq_Err.Bad_Count))

	// composition record: per-column keyness over the same doc cells —
	// group 夜 against 朝 on X gives Differential 3/4 − 1/4
	kc, kerr := gloaming.keyness_scores(
		[]gloaming.Freq_Entry{{lemma = "X", count = 3, docs = 3}}, 4,
		[]gloaming.Freq_Entry{{lemma = "X", count = 1, docs = 1}}, 4,
		{m = .Differential}, a)
	testing.expectf(t, kerr == gloaming.Freq_Err.None, "compose: %v", kerr)
	if !testing.expectf(t, abs_f64(kc[0].value - 0.5) < 1e-12,
		"compose: %f", kc[0].value) { return }
}

// KWIC collocation — hit rows as the window population, the
// center excluded, the every-token differential against cooc_presence,
// and one scored MI/G² reference through assoc_value.
@(test)
kwic_colloc_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// 猫 犬 鳥 猫 魚 猫 犬, whole-stream; 犬 carries a POS the noun
	// filter can drop, the rest share 名詞,一般
	words := [7]string{"猫", "犬", "鳥", "猫", "魚", "猫", "犬"}
	toks := make([]gloaming.Token, 7, a)
	for w, i in words {
		toks[i] = gloaming.Token{
			surface = w, lemma = w, pos = w == "犬" ? "名詞,固有" : "名詞,一般",
			reading = "x", start = i * 3, end = i * 3 + 3,
		}
	}
	stream := gloaming.Token_Stream{doc = 1, tokens = toks}

	q, qerr := gloaming.query_parse(`(seq (m surface "猫"))`, gloaming.Parse_Options{}, a)
	testing.expectf(t, qerr == gloaming.Query_Err.None, "parse: %v", qerr)
	res, merr := gloaming.query_match(&q, stream, 16, a)
	testing.expectf(t, merr == gloaming.Query_Err.None, "match: %v", merr)
	if !testing.expect_value(t, len(res.matches), 3) { return }

	rows := gloaming.kwic(res.matches, stream, 2, 2, -1, a)
	pres, cerr := gloaming.kwic_colloc(rows, stream, {}, a)
	testing.expectf(t, cerr == gloaming.Freq_Err.None, "colloc: %v", cerr)
	// contexts: {犬,鳥}, {犬,鳥,魚,猫}, {猫,魚,犬} — presence over rows
	if !testing.expect_value(t, pres.windows, 3) { return }
	if !testing.expect_value(t, len(pres.keys), 4) { return }
	// count desc then key asc: 犬3, then 猫 魚 鳥 at 2 (魚 E9AD sorts
	// before 鳥 E9B3)
	if !testing.expectf(t, pres.keys[0].lemma == "犬" && pres.keys[0].count == 3 &&
		pres.keys[1].lemma == "猫" && pres.keys[1].count == 2 &&
		pres.keys[2].lemma == "魚" && pres.keys[2].count == 2 &&
		pres.keys[3].lemma == "鳥" && pres.keys[3].count == 2,
		"presence: %v", pres.keys) { return }
	// the center is never its own collocate: 猫 appears in 2 of 3 rows
	if !testing.expectf(t, pres.keys[1].count < pres.windows, "center self-count") {
		return
	}

	// the filter drops 犬 (POS-restricted collocates)
	nres, _ := gloaming.query_match(&q, stream, 16, a)
	nrows := gloaming.kwic(nres.matches, stream, 2, 2, -1, a)
	noun := gloaming.Freq_Filter{pos_prefixes = {"名詞,一"}}
	npres, nerr := gloaming.kwic_colloc(nrows, stream, noun, a)
	testing.expectf(t, nerr == gloaming.Freq_Err.None, "noun: %v", nerr)
	if !testing.expect_value(t, len(npres.keys), 3) { return }
	for e in npres.keys {
		if !testing.expectf(t, e.lemma != "犬" && e.count == 2,
			"noun row: %v", e) { return }
	}

	// row-order invariance: reversed rows give the same table
	rev := make([]gloaming.Kwic_Row, len(rows), a)
	for r, i in rows { rev[len(rows) - 1 - i] = r }
	rpres, rerr := gloaming.kwic_colloc(rev, stream, {}, a)
	testing.expectf(t, rerr == gloaming.Freq_Err.None, "rev: %v", rerr)
	if !testing.expect_value(t, len(rpres.keys), len(pres.keys)) { return }
	for i in 0..<len(rpres.keys) {
		if !testing.expectf(t, rpres.keys[i].lemma == pres.keys[i].lemma &&
			rpres.keys[i].count == pres.keys[i].count, "rev row %d", i) { return }
	}

	// the reference population: every-token rows, hand-built (the
	// host's all-positions table). Contexts by hand — each token
	// centers its own row once, so a word's presence tops out at 6:
	// 猫6 犬5 魚4 鳥4 over 7 rows
	am: [dynamic]gloaming.Match = make([dynamic]gloaming.Match, 0, 7, a)
	for i in 0..<7 {
		append(&am, gloaming.Match{
			start = i, end = i + 1,
			span = {doc = 1, start = toks[i].start, end = toks[i].end},
		})
	}
	arows := gloaming.kwic(am[:], stream, 2, 2, -1, a)
	ref, rerr2 := gloaming.kwic_colloc(arows, stream, {}, a)
	testing.expectf(t, rerr2 == gloaming.Freq_Err.None, "ref: %v", rerr2)
	if !testing.expect_value(t, ref.windows, 7) { return }
	refwant := [4]struct {
		k: string,
		n: int,
	}{{k = "猫", n = 6}, {k = "犬", n = 5}, {k = "魚", n = 4}, {k = "鳥", n = 4}}
	for i in 0..<4 {
		if !testing.expectf(t, ref.keys[i].lemma == refwant[i].k && ref.keys[i].count == refwant[i].n,
			"ref row %d: %v", i, ref.keys[i]) { return }
	}

	// the scored pair for 犬 against that reference: n = 3 hit rows,
	// n_a = 3, n_b = 5, windows = 7 — MI = log2(7/5) and
	// G² = 2·(3 ln 1.4 + 2 ln 0.7 + 2 ln 1.75)
	mi, mierr := gloaming.assoc_value(.Mutual_Information, 3, 3, 5, 7)
	testing.expectf(t, mierr == gloaming.Freq_Err.None, "mi: %v", mierr)
	if !testing.expectf(t, abs_f64(mi - 0.4854268272) < 1e-9, "mi: %f", mi) {
		return
	}
	g2, g2err := gloaming.assoc_value(.Log_Likelihood, 3, 3, 5, 7)
	testing.expectf(t, g2err == gloaming.Freq_Err.None, "g2: %v", g2err)
	if !testing.expectf(t, abs_f64(g2 - 2.8305967957) < 1e-9, "g2: %f", g2) {
		return
	}

	// differential: three noun-verb-noun sentences, the verb centers
	// filtered out of the collocate set — the colloc table over the
	// verb rows equals cooc_presence over the same segments
	swords := [9]string{"猫", "動", "鳥", "魚", "動", "犬", "空", "動", "月"}
	stoks := make([]gloaming.Token, 9, a)
	for w, i in swords {
		stoks[i] = gloaming.Token{
			surface = w, lemma = w, pos = w == "動" ? "動詞,自立" : "名詞,一般",
			reading = "x", start = i * 3, end = i * 3 + 3,
		}
	}
	segs := make([]gloaming.Segment, 3, a)
	for i in 0..<3 {
		segs[i] = {kind = .Sentence, span = {doc = 2, start = i * 9, end = i * 9 + 9}}
	}
	stream2 := gloaming.Token_Stream{doc = 2, tokens = stoks, segments = segs}
	qv, qverr := gloaming.query_parse(`(seq (m surface "動"))`, gloaming.Parse_Options{}, a)
	testing.expectf(t, qverr == gloaming.Query_Err.None, "verb parse: %v", qverr)
	vres, vmerr := gloaming.query_match(&qv, stream2, 16, a)
	testing.expectf(t, vmerr == gloaming.Query_Err.None, "verb match: %v", vmerr)
	if !testing.expect_value(t, len(vres.matches), 3) { return }
	vrows := gloaming.kwic(vres.matches, stream2, 5, 5, -1, a)
	sfilter := gloaming.Freq_Filter{pos_prefixes = {"名詞"}}
	vpres, verr := gloaming.kwic_colloc(vrows, stream2, sfilter, a)
	testing.expectf(t, verr == gloaming.Freq_Err.None, "verb colloc: %v", verr)
	spres, serr := gloaming.cooc_presence(stream2, {},
		{filter = sfilter, unit = .Segments}, a)
	testing.expectf(t, serr == gloaming.Freq_Err.None, "presence: %v", serr)
	if !testing.expect_value(t, vpres.windows, 3) { return }
	if !testing.expect_value(t, spres.windows, vpres.windows) { return }
	if !testing.expect_value(t, len(spres.keys), len(vpres.keys)) { return }
	for i in 0..<len(spres.keys) {
		if !testing.expectf(t, spres.keys[i].lemma == vpres.keys[i].lemma &&
			spres.keys[i].count == vpres.keys[i].count,
			"diff row %d: %v vs %v", i, vpres.keys[i], spres.keys[i]) { return }
	}

	// a row whose spans fall outside the stream refuses, never skips
	bad := make([]gloaming.Kwic_Row, 1, a)
	bad[0] = {
		left   = {doc = 9, start = 0, end = 0},
		center = {doc = 9, start = 0, end = 3},
		right  = {doc = 9, start = 3, end = 6},
	}
	_, berr := gloaming.kwic_colloc(bad, stream, {}, a)
	testing.expect_value(t, int(berr), int(gloaming.Freq_Err.Bad_Count))
}

// The stop-check contract: every pass
// whose cost scales with corpus size or n² polls an optional check at
// its outer iteration (true = stop, query_match's convention) and
// answers a typed .Interrupted — an interactive host stays responsive.
// The check fires on its first poll everywhere here, so each pass
// refuses before any output; an interrupted call returns no outputs,
// so what the tracking allocator still holds at the end is exactly
// what an interrupt path stranded — the leak gate is the assertion.
// The store-reopen case fires mid-replay instead, after one committed
// batch: its segment clones must unwind too.
@(test)
interrupt_contract :: proc(t: ^testing.T) {
	arena: mem.Arena
	mem.arena_init(&arena, test_arena_buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	stop_now :: proc(user: rawptr) -> bool { return true }

	rows := []string{
		"猫	名詞,一般,*,*,*	猫	ネコ	0	3	-	0",
		"犬	名詞,一般,*,*,*	犬	イヌ	3	6	-	0",
		"鳥	名詞,一般,*,*,*	鳥	トリ	6	9	-	0",
	}
	toks := make([]gloaming.Token, len(rows), a)
	for i in 0..<len(rows) {
		toks[i] = fixture_token(t, rows[i])
	}
	stream := gloaming.Token_Stream{doc = 0, tokens = toks}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	ta := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	// statistics passes
	_, ferr := gloaming.freq_table(stream, {}, {}, ta, stop_now, nil)
	testing.expect_value(t, int(ferr), int(gloaming.Freq_Err.Interrupted))
	_, _, cerr := gloaming.co_occurrence(stream, {}, {unit = .Segments}, ta,
		stop_now, nil)
	testing.expect_value(t, int(cerr), int(gloaming.Freq_Err.Interrupted))

	// clustering and coordinates (n² and iteration-shaped)
	dist := make([]f64, 9, ta)
	_, werr := gloaming.ward_merges(dist, 3, ta, stop_now, nil)
	testing.expect_value(t, int(werr), int(gloaming.Freq_Err.Interrupted))
	free_slice(dist, ta)
	w := make([]f64, 9, ta)
	w[1] = 1
	w[3] = 1 // rows 0 and 1 carry mass, so the solver reaches its iterations
	_, perr := gloaming.power_coords(w, 3, 1e-12, 256, ta, stop_now, nil)
	testing.expect_value(t, int(perr), int(gloaming.Freq_Err.Interrupted))
	free_slice(w, ta)

	// corpus passes over a populated memory store
	store, serr := gloaming.store_memory(a)
	testing.expectf(t, serr == gloaming.Store_Err.None, "store: %v", serr)
	testing.expectf(t, mk_store_doc(store, 0, {"猫", "犬"}, a) == gloaming.Store_Err.None, "doc 0")
	testing.expectf(t, mk_store_doc(store, 1, {"猫", "鳥"}, a) == gloaming.Store_Err.None, "doc 1")
	_, cferr := gloaming.corpus_freq(store, {0, 1}, {}, ta, stop_now, nil)
	testing.expect_value(t, int(cferr), int(gloaming.Store_Err.Interrupted))
	_, dperr := gloaming.doc_profiles(store, {0, 1}, {}, ta, stop_now, nil)
	testing.expect_value(t, int(dperr), int(gloaming.Store_Err.Interrupted))

	// the doc-side matrices are corpus-scale k² too: both
	// poll once per row and refuse before row 0's work
	dk := make([]string, 2, a)
	dk[0] = "猫"
	dk[1] = "犬"
	dc := make([]int, 2, a)
	dc[0] = 1
	dc[1] = 1
	profs := make([]gloaming.Doc_Profile, 2, ta)
	profs[0] = {doc = 0, keys = dk[:1], counts = dc[:1]}
	profs[1] = {doc = 1, keys = dk[1:], counts = dc[1:]}
	_, dwerr := gloaming.doc_weights(profs, ta, stop_now, nil)
	testing.expect_value(t, int(dwerr), int(gloaming.Freq_Err.Interrupted))
	_, dderr := gloaming.doc_distance(profs, .Jaccard, ta, stop_now, nil)
	testing.expect_value(t, int(dderr), int(gloaming.Freq_Err.Interrupted))
	free_slice(profs, ta)

	// graph surfaces — rows reach the applies with their kinds interned,
	// the writer/replay contract
	g: gloaming.Doc_Graph
	gloaming.graph_init(&g, a)
	defer gloaming.graph_destroy(&g)
	kt := gloaming.graph_kind_intern(&g, "term")
	kc := gloaming.graph_kind_intern(&g, "codes")
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 0, live = true, kind = kt, name = "アサ",
	})
	gloaming.graph_apply_entity(&g, gloaming.Entity{
		id = 1, live = true, kind = kt, name = "霧",
	})
	gloaming.graph_apply_relation(&g, gloaming.Relation{
		id = 0, live = true, kind = kc, from = 0, to = 1, derived = true,
	})
	_, trerr := gloaming.graph_traverse(&g, {0}, {}, 2, 10, ta, stop_now, nil)
	testing.expect_value(t, int(trerr), int(gloaming.Graph_Err.Interrupted))
	_, prerr := gloaming.graph_pagerank(&g, {}, 0.85, 200, 1e-12, ta, stop_now, nil)
	testing.expect_value(t, int(prerr), int(gloaming.Graph_Err.Interrupted))
	_, toerr := gloaming.graph_toposort(&g, {}, ta, stop_now, nil)
	testing.expect_value(t, int(toerr), int(gloaming.Graph_Err.Interrupted))

	// store-open replay: reopen a two-batch registry with the check
	// firing mid-replay — after batch 1 commits (its segment clones
	// must unwind), inside batch 2
	dir := "tmp/glr-intr"
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, a)
	pay, _ := os.join_path({dir, "payloads.glb"}, a)
	_ = os.remove(reg)
	_ = os.remove(pay)
	dstore, ds, derr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, a)
	testing.expectf(t, derr == gloaming.Store_Err.None, "store_disk: %v", derr)
	testing.expectf(t, mk_store_doc(dstore, 0, {"猫", "犬"}, a) == gloaming.Store_Err.None, "disk doc 0")
	testing.expectf(t, mk_store_doc(dstore, 1, {"猫", "鳥"}, a) == gloaming.Store_Err.None, "disk doc 1")
	testing.expect_value(t, int(gloaming.disk_store_close(ds)), int(gloaming.Store_Err.None))
	polls := 0
	stop_after_four :: proc(user: rawptr) -> bool {
		p := cast(^int)user
		p^ += 1
		return p^ > 4
	}
	_, _, oerr := gloaming.store_disk(dir, no_resolver, nil, 0, 0, ta,
		stop_after_four, &polls)
	testing.expect_value(t, int(oerr), int(gloaming.Store_Err.Interrupted))

	if track.current_memory_allocated != 0 {
		testing.expectf(t, false, "live bytes after interrupted calls: %d",
			int(track.current_memory_allocated))
	}
}
