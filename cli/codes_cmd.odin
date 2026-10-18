package main

/*
The coding-rule host loop the library names but does not run: pattern
A near pattern B within a token window, per document, writes one
derived relation whose evidence is the paired spans — the curator
asserts the endpoints (the library does not invent them), the pairs
cite the text. Patterns ride the same query DSL and parse errors as
`query`. The cap discipline on a write is stricter than a read's: a
capped enumeration refuses the whole write instead of committing a
partial derivation — raise --cap and rerun, which is safe because
evidence absorbs as a set. --dry-run reports the pairs without
writing. Writes the base state, so --variant refuses.
*/

import "core:fmt"
import "core:mem"
import mv "core:mem/virtual"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

codes_row_json :: proc(rid: int, kind: string, from, to: gl.Entity_Id,
                       g: ^gl.Doc_Graph, pairs, docs, evidence: int,
                       a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	if rid >= 0 {
		strings.write_string(&b, "{\"id\":")
		fmt.sbprintf(&b, "%d", rid)
		strings.write_string(&b, ",\"kind\":")
	} else {
		strings.write_string(&b, "{\"kind\":")
	}
	glexport.json_esc(kind, &b)
	strings.write_string(&b, ",\"from\":")
	fmt.sbprintf(&b, "%d", int(from))
	strings.write_string(&b, ",\"to\":")
	fmt.sbprintf(&b, "%d", int(to))
	strings.write_string(&b, ",\"from_name\":")
	glexport.json_esc(entity_name(g, from), &b)
	strings.write_string(&b, ",\"to_name\":")
	glexport.json_esc(entity_name(g, to), &b)
	strings.write_string(&b, ",\"derived\":true,\"pairs\":")
	fmt.sbprintf(&b, "%d", pairs)
	strings.write_string(&b, ",\"docs\":")
	fmt.sbprintf(&b, "%d", docs)
	strings.write_string(&b, ",\"evidence\":")
	fmt.sbprintf(&b, "%d", evidence)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

/*
The enumeration fan-out: one slot per document, the body loads the
stream and enumerates the rule's pairs on the worker's own arena;
the single derived-relation write stays on the main thread after the
join, over evidence assembled in document order — byte-identical to
the serial loop at every width. The rule's parsed patterns are
immutable, and reads never touch store-owned memory, so no lane
shares mutable state with another.
*/

Codes_Slot :: struct {
	spans: []gl.Span, // this doc's evidence (a then b per pair), worker arena
	pairs: int,
	trunc: bool,
	lerr:  gl.Store_Err,
	qerr:  gl.Query_Err,
}

Codes_Ctx :: struct {
	rs:    ^Read_State,
	ids:   []gl.Doc_Id,
	rule:  ^gl.Coding_Rule,
	slots: []Codes_Slot,
}

codes_body :: proc(ctx: rawptr, i: int, wa: mem.Allocator) {
	c := cast(^Codes_Ctx)ctx
	s := &c.slots[i]
	stream, lerr := load_stream(c.rs, c.ids[i], wa)
	if lerr != .None { s.lerr = lerr; return }
	res, qerr := gl.graph_code_pairs(c.rule, stream, wa)
	if qerr != .None { s.qerr = qerr; return }
	if res.truncated { s.trunc = true }
	spans: [dynamic]gl.Span = make([dynamic]gl.Span, 0, 2 * len(res.pairs), wa)
	for p in res.pairs {
		append(&spans, p.a)
		append(&spans, p.b)
	}
	s.spans = spans[:]
	s.pairs = len(res.pairs)
}

cmd_codes :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	window, cap_n, dry := 5, 1000, false
	pos: [dynamic]string = make([dynamic]string, 0, 5, a)
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--window" {
			v, ok := flag_int(rest, &i, "--window", 0)
			if !ok { return EXIT_USAGE }
			window = v
		} else if arg == "--cap" {
			v, ok := flag_int(rest, &i, "--cap", 1)
			if !ok { return EXIT_USAGE }
			cap_n = v
		} else if arg == "--dry-run" {
			dry = true
		} else if strings.starts_with(arg, "--") {
			return unknown_flag_errorf("codes", arg)
		} else if len(pos) < 5 {
			append(&pos, arg)
		} else {
			return usage_errorf("codes <kind> <from> <to> <patternA> <patternB> [--window N] [--cap M] [--dry-run]")
		}
	}
	if len(pos) != 5 {
		return usage_errorf("codes <kind> <from> <to> <patternA> <patternB> [--window N] [--cap M] [--dry-run]")
	}
	if g.variant != "" {
		return base_state_errorf("codes targets the base state", " (graph rows are corpus metadata)")
	}

	err_pos := -1
	qa, perr := gl.query_parse(pos[3], gl.Parse_Options{}, a, &err_pos)
	if perr != .None { return pattern_errorf(perr, err_pos) }
	qb, perr2 := gl.query_parse(pos[4], gl.Parse_Options{}, a, &err_pos)
	if perr2 != .None { return pattern_errorf(perr2, err_pos) }
	rule := gl.Coding_Rule{code = pos[0], a = &qa, b = &qb,
		window = window, cap = cap_n}

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, "", a)
	if icode != 0 { return icode }
	from, fcode := resolve_entity(rs.ds, pos[1])
	if fcode != 0 { return fcode }
	to, tcode := resolve_entity(rs.ds, pos[2])
	if tcode != 0 { return tcode }

	pairs, docs_with, truncated := 0, 0, false
	ev: [dynamic]gl.Span = make([dynamic]gl.Span, 0, 0, a)
	codes_arenas: []^mv.Arena
	if g.threads > 1 && len(ids) > 0 {
		cc := Codes_Ctx{
			rs = &rs, ids = ids, rule = &rule,
			slots = make([]Codes_Slot, len(ids), a),
		}
		ra, fok := reads_fanout(&rs, ids, g.threads, codes_body, &cc, a)
		if !fok { return io_errorf("codes read fan-out arena init failed") }
		codes_arenas = ra
		// refusals report in document order — the serial loop's rule
		for i in 0..<len(ids) {
			if cc.slots[i].lerr != .None {
				return analysis_errorf("codes: doc %d read: %v", u32(ids[i]),
					cc.slots[i].lerr)
			}
			if cc.slots[i].qerr != .None { return pattern_errorf(cc.slots[i].qerr, -1) }
		}
		for i in 0..<len(ids) {
			s := &cc.slots[i]
			if s.trunc { truncated = true }
			if s.pairs > 0 { docs_with += 1 }
			append(&ev, ..s.spans)
			pairs += s.pairs
		}
	} else {
		for id in ids {
			stream, lerr := load_stream(&rs, id, a)
			if lerr != .None {
				return analysis_errorf("codes: doc %d read: %v", u32(id), lerr)
			}
			res, qerr := gl.graph_code_pairs(&rule, stream, a)
			if qerr != .None { return pattern_errorf(qerr, -1) }
			if res.truncated { truncated = true }
			if len(res.pairs) > 0 { docs_with += 1 }
			for p in res.pairs {
				append(&ev, p.a)
				append(&ev, p.b)
				pairs += 1
			}
		}
	}
	// the workers' arenas die at the procedure's scope (a branch-level
	// defer would fire at the branch's end); ev holds span VALUES copied
	// at the merge, so only the slots' slices reference them
	defer if codes_arenas != nil { read_arenas_drop(codes_arenas, a) }
	if truncated && !dry {
		return analysis_errorf("codes %s: pair cap hit (--cap %d) — nothing written; raise --cap and rerun",
			pos[0], cap_n)
	}
	if pairs == 0 {
		return analysis_errorf("codes %s: no pairs in the corpus — nothing written", pos[0])
	}

	rid := -1
	if !dry {
		wid, werr := gl.graph_relation_add(rs.ds, pos[0], from, to, ev[:], true)
		if werr == .Bad_Range {
			return analysis_errorf("codes %s: an edge from a thing to itself carries no order", pos[0])
		} else if werr != .None {
			return analysis_errorf("codes %s: %v", pos[0], werr)
		}
		rid = int(wid)
	}
	one := make([]string, 1, a)
	one[0] = codes_row_json(rid, pos[0], from, to, &rs.ds.graph,
		pairs, docs_with, len(ev), a)
	emit_envelope("codes", rs.eng.hash, g.variant, dry && truncated,
		join_rows(one, a), a)
	return EXIT_OK
}
