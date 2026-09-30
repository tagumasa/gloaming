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
*/

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

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
	ix := make(map[string]int, a)
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
