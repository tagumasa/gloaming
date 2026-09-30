package main

/*
Relation curation: directed edges between entities — the ordering
vocabulary toposort reads. `add` writes the edge the curator asserts:
curated by default, --derived for a coding-rule row (the pair may
carry both — derived is the only identity difference), with evidence
as byte-span citations (--evidence <doc>:<start>-<end>, validated
against the current text and absorbed as a set, so re-citing is
idempotent). `list` reads the selected state's rows back. Endpoints
resolve by canonical name or alias first, then by decimal entity id —
names are primary because a free-form name may itself be digits.
Writes refuse --variant like every graph-row write.
*/

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

// canonical name or alias → "" when the id resolves to no live row —
// visible rather than refused, the row-emitter rule
entity_name :: proc(g: ^gl.Doc_Graph, id: gl.Entity_Id) -> string {
	i := int(id)
	if i < 0 || i >= len(g.entities) || !g.entities[i].live { return "" }
	return g.entities[i].name
}

// one relation endpoint: the registry's own name resolution, then a
// decimal entity id
resolve_entity :: proc(ds: ^gl.Disk_Store, spec: string) -> (gl.Entity_Id, int) {
	if id, ok := gl.graph_entity_find(&ds.graph, spec); ok { return id, 0 }
	if v, ok := strconv.parse_int(spec, 10); ok {
		id := gl.Entity_Id(v)
		if gl.graph_entity_live(&ds.graph, id) { return id, 0 }
		return {}, analysis_errorf("no live entity %d", v)
	}
	return {}, analysis_errorf("no entity named %s", spec)
}

relation_row_json :: proc(r: ^gl.Relation, g: ^gl.Doc_Graph,
                          a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"id\":")
	fmt.sbprintf(&b, "%d", int(r.id))
	strings.write_string(&b, ",\"kind\":")
	glexport.json_esc(g.kinds[r.kind], &b)
	strings.write_string(&b, ",\"from\":")
	fmt.sbprintf(&b, "%d", int(r.from))
	strings.write_string(&b, ",\"to\":")
	fmt.sbprintf(&b, "%d", int(r.to))
	strings.write_string(&b, ",\"from_name\":")
	glexport.json_esc(entity_name(g, r.from), &b)
	strings.write_string(&b, ",\"to_name\":")
	glexport.json_esc(entity_name(g, r.to), &b)
	strings.write_string(&b, ",\"derived\":")
	fmt.sbprintf(&b, "%v", r.derived)
	strings.write_string(&b, ",\"evidence\":")
	fmt.sbprintf(&b, "%d", len(r.evidence))
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

cmd_relation :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) == 0 {
		return usage_errorf("relation: add <kind> <from> <to> [--evidence <doc>:<s>-<e>]… [--derived] | list")
	}
	sub := rest[0]
	args := rest[1:]
	a := context.allocator

	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }

	switch sub {
	case "add":
		if g.variant != "" {
			return base_state_errorf("relation add targets the base state", " (graph rows are corpus metadata)")
		}
		pos: [dynamic]string = make([dynamic]string, 0, 3, a)
		evspecs: [dynamic]string = make([dynamic]string, 0, 4, a)
		derived := false
		for i := 0; i < len(args); i += 1 {
			arg := args[i]
			if arg == "--derived" {
				derived = true
			} else if arg == "--evidence" {
				v, ok := flag_value(args, &i, "--evidence")
				if !ok { return EXIT_USAGE }
				append(&evspecs, v)
			} else if strings.starts_with(arg, "--") {
				return unknown_flag_errorf("relation add", arg)
			} else if len(pos) < 3 {
				append(&pos, arg)
			} else {
				return usage_errorf("relation add <kind> <from> <to> [--evidence <doc>:<s>-<e>]… [--derived]")
			}
		}
		if len(pos) != 3 {
			return usage_errorf("relation add <kind> <from> <to> [--evidence <doc>:<s>-<e>]… [--derived]")
		}
		ev := make([]gl.Span, len(evspecs), a)
		for es, i in evspecs {
			s, pcode := parse_span_spec(es, dir, &m, a)
			if pcode != 0 { return pcode }
			ev[i] = s
		}
		ds, ocode := open_registry_store(dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		from, fcode := resolve_entity(ds, pos[1])
		if fcode != 0 { return fcode }
		to, tcode := resolve_entity(ds, pos[2])
		if tcode != 0 { return tcode }
		rid, rerr := gl.graph_relation_add(ds, pos[0], from, to, ev, derived)
		if rerr == .Bad_Range {
			return analysis_errorf("relation add %s: an edge from a thing to itself carries no order", pos[0])
		} else if rerr != .None {
			return analysis_errorf("relation add %s: %v", pos[0], rerr)
		}
		one := make([]string, 1, a)
		one[0] = relation_row_json(&ds.graph.relations[int(rid)], &ds.graph, a)
		emit_envelope("relation", m.dict_hash, "", false, join_rows(one, a), a)
		return EXIT_OK
	case "list":
		if len(args) != 0 { return usage_errorf("relation list takes no arguments") }
		ds, dh, ocode := open_graph_store(g, dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		rows: [dynamic]string = make([dynamic]string, 0, len(ds.graph.relations), a)
		for &r in ds.graph.relations {
			if !r.live { continue }
			append(&rows, relation_row_json(&r, &ds.graph, a))
		}
		emit_envelope("relation", dh, g.variant, false, join_rows(rows[:], a), a)
		return EXIT_OK
	}
	return usage_errorf("relation: unknown subcommand %s", sub)
}
