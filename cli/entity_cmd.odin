package main

/*
Entity curation over the base store's record log: registration,
aliases, merge, listing. `alias` validates every alias before the
first write — one rejected alias must not leave the earlier ones
registered — then lands one rewritten row per alias, the writer's
granularity. `merge` is the graph's own tombstone mechanism (no
entity remove exists): mentions and incident relations re-point, and
the emitted row shows the absorbed names. Writes refuse --variant
like every graph-row write; `list` follows the selected state like
every read.
*/

import "core:fmt"
import "core:mem"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

entity_row_json :: proc(e: ^gl.Entity, g: ^gl.Doc_Graph, a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"id\":")
	fmt.sbprintf(&b, "%d", int(e.id))
	strings.write_string(&b, ",\"kind\":")
	glexport.json_esc(g.kinds[e.kind], &b)
	strings.write_string(&b, ",\"name\":")
	glexport.json_esc(e.name, &b)
	strings.write_string(&b, ",\"aliases\":[")
	for al, i in e.aliases {
		if i > 0 { strings.write_string(&b, ",") }
		glexport.json_esc(al, &b)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

cmd_entity :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) == 0 {
		return usage_errorf("entity: add <kind> <name> [alias…] | alias <entity> <alias>… | merge <into> <from> | list")
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
		if len(args) < 2 { return usage_errorf("entity add <kind> <name> [alias…]") }
		if g.variant != "" {
			return base_state_errorf("entity add targets the base state", " (graph rows are corpus metadata)")
		}
		ds, ocode := open_registry_store(dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		id, aerr := gl.graph_entity_add(ds, args[0], args[1], args[2:])
		if aerr == .Duplicate {
			return analysis_errorf("entity add %s: name or alias already registered", args[1])
		} else if aerr != .None {
			return analysis_errorf("entity add %s: %v", args[1], aerr)
		}
		one := make([]string, 1, a)
		one[0] = entity_row_json(&ds.graph.entities[int(id)], &ds.graph, a)
		emit_envelope("entity", m.dict_hash, "", false, join_rows(one, a), a)
		return EXIT_OK
	case "alias":
		if len(args) < 2 { return usage_errorf("entity alias <entity> <alias> [alias…]") }
		if g.variant != "" {
			return base_state_errorf("entity alias targets the base state", " (graph rows are corpus metadata)")
		}
		ds, ocode := open_registry_store(dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		id, ecode := resolve_entity(ds, args[0])
		if ecode != 0 { return ecode }
		for i := 1; i < len(args); i += 1 {
			if _, taken := gl.graph_entity_find(&ds.graph, args[i]); taken {
				return analysis_errorf("entity alias %s: name or alias already registered", args[i])
			}
			for j := 1; j < i; j += 1 {
				if args[j] == args[i] {
					return analysis_errorf("entity alias %s: given twice", args[i])
				}
			}
		}
		for i := 1; i < len(args); i += 1 {
			if aerr := gl.graph_entity_alias(ds, id, args[i]); aerr != .None {
				return analysis_errorf("entity alias %s: %v", args[i], aerr)
			}
		}
		one := make([]string, 1, a)
		one[0] = entity_row_json(&ds.graph.entities[int(id)], &ds.graph, a)
		emit_envelope("entity", m.dict_hash, "", false, join_rows(one, a), a)
		return EXIT_OK
	case "merge":
		if len(args) != 2 { return usage_errorf("entity merge <into> <from>") }
		if g.variant != "" {
			return base_state_errorf("entity merge targets the base state", " (graph rows are corpus metadata)")
		}
		ds, ocode := open_registry_store(dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		into, icode := resolve_entity(ds, args[0])
		if icode != 0 { return icode }
		from, fcode := resolve_entity(ds, args[1])
		if fcode != 0 { return fcode }
		if into == from {
			return analysis_errorf("entity merge: an entity cannot merge into itself")
		}
		if merr := gl.graph_entity_merge(ds, into, from); merr != .None {
			return analysis_errorf("entity merge: %v", merr)
		}
		one := make([]string, 1, a)
		one[0] = entity_row_json(&ds.graph.entities[int(into)], &ds.graph, a)
		emit_envelope("entity", m.dict_hash, "", false, join_rows(one, a), a)
		return EXIT_OK
	case "list":
		if len(args) != 0 { return usage_errorf("entity list takes no arguments") }
		ds, dh, ocode := open_graph_store(g, dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		rows: [dynamic]string = make([dynamic]string, 0, len(ds.graph.entities), a)
		for &e in ds.graph.entities {
			if !e.live { continue }
			append(&rows, entity_row_json(&e, &ds.graph, a))
		}
		emit_envelope("entity", dh, g.variant, false, join_rows(rows[:], a), a)
		return EXIT_OK
	}
	return usage_errorf("entity: unknown subcommand %s", sub)
}
