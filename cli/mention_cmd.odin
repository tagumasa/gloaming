package main

/*
Mention curation: the span-to-entity binding — where in the text a
thing was named. `add` takes the entity by name/alias/id (the
relation-endpoint vocabulary) and one byte-span citation (the
--evidence form, validated against the current text); `list` reads
the selected state's rows back with entity names inline, so a row
reads without a join. No mention remove exists: a merge re-points
them, and the reads tolerate a stray row the way they tolerate any
evidence noise. Writes refuse --variant like every graph-row write.
*/

import "core:fmt"
import "core:mem"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

mention_row_json :: proc(id: int, m: gl.Mention, g: ^gl.Doc_Graph,
                         a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"id\":")
	fmt.sbprintf(&b, "%d", id)
	strings.write_string(&b, ",\"entity\":")
	fmt.sbprintf(&b, "%d", int(m.entity))
	strings.write_string(&b, ",\"entity_name\":")
	glexport.json_esc(entity_name(g, m.entity), &b)
	strings.write_string(&b, ",\"doc\":")
	fmt.sbprintf(&b, "%d", u32(m.span.doc))
	strings.write_string(&b, ",\"start\":")
	fmt.sbprintf(&b, "%d", m.span.start)
	strings.write_string(&b, ",\"end\":")
	fmt.sbprintf(&b, "%d", m.span.end)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

cmd_mention :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) == 0 {
		return usage_errorf("mention: add <entity> <doc>:<start>-<end> | list")
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
		if len(args) != 2 { return usage_errorf("mention add <entity> <doc>:<start>-<end>") }
		if g.variant != "" {
			return base_state_errorf("mention add targets the base state", " (graph rows are corpus metadata)")
		}
		span, pcode := parse_span_spec(args[1], dir, &m, a)
		if pcode != 0 { return pcode }
		ds, ocode := open_registry_store(dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		id, ecode := resolve_entity(ds, args[0])
		if ecode != 0 { return ecode }
		mid, aerr := gl.graph_mention_add(ds, id, span)
		if aerr != .None {
			return analysis_errorf("mention add: %v", aerr)
		}
		one := make([]string, 1, a)
		one[0] = mention_row_json(mid, ds.graph.mentions[mid], &ds.graph, a)
		emit_envelope("mention", m.dict_hash, "", false, join_rows(one, a), a)
		return EXIT_OK
	case "list":
		if len(args) != 0 { return usage_errorf("mention list takes no arguments") }
		ds, dh, ocode := open_graph_store(g, dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		rows: [dynamic]string = make([dynamic]string, 0, len(ds.graph.mentions), a)
		for mm, i in ds.graph.mentions {
			append(&rows, mention_row_json(i, mm, &ds.graph, a))
		}
		emit_envelope("mention", dh, g.variant, false, join_rows(rows[:], a), a)
		return EXIT_OK
	}
	return usage_errorf("mention: unknown subcommand %s", sub)
}
