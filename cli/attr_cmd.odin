package main

/*
The external variables: categorical metadata a
document carries for the cross-tabulation reads. They are corpus
metadata, not dictionary state — `set` targets the base store's
record log and refuses under --variant, and variant stores inherit
the rows at creation, so the group reads answer identically under
either state; `get`/`list` read the selected state like every read.
No attr remove exists: a value of "" already groups as missing, so
clearing is attr set with an empty value.
*/

import "core:fmt"
import "core:mem"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

attr_row_json :: proc(doc: u32, key, val: string, a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"doc\":")
	fmt.sbprintf(&b, "%d", doc)
	strings.write_string(&b, ",\"key\":")
	glexport.json_esc(key, &b)
	strings.write_string(&b, ",\"val\":")
	glexport.json_esc(val, &b)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// one (key, value) pair with the documents carrying it — attr list's row
Attr_Count :: struct {
	key:  string,
	val:  string,
	docs: int,
}

attr_count_less :: proc(x, y: ^Attr_Count) -> bool {
	c := strings.compare(x.key, y.key)
	if c != 0 { return c < 0 }
	return strings.compare(x.val, y.val) < 0
}

attr_key_less :: proc(x, y: ^gl.Doc_Attr) -> bool {
	return strings.compare(x.key, y.key) < 0
}

cmd_attr :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) == 0 {
		return usage_errorf("attr: set <doc> <key> <value> | get <doc> | list")
	}
	sub := rest[0]
	args := rest[1:]
	a := context.allocator

	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }

	switch sub {
	case "set":
		if len(args) != 3 { return usage_errorf("attr set <doc> <key> <value>") }
		if g.variant != "" {
			return base_state_errorf("attr set targets the base state", " (attrs are corpus metadata)")
		}
		id, dcode := resolve_doc(args[0], &m)
		if dcode != 0 { return dcode }
		if _, ok := doc_row(&m, id); !ok {
			return analysis_errorf("no document %d in the manifest", u32(id))
		}
		ds, ocode := open_registry_store(dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		if aerr := gl.graph_attr_put(ds, id, args[1], args[2]); aerr != .None {
			return analysis_errorf("attr set doc %d: %v", u32(id), aerr)
		}
		one := make([]string, 1, a)
		one[0] = attr_row_json(u32(id), args[1], args[2], a)
		emit_envelope("attr", m.dict_hash, "", false, join_rows(one, a), a)
		return EXIT_OK
	case "get":
		if len(args) != 1 { return usage_errorf("attr get <doc>") }
		id, dcode := resolve_doc(args[0], &m)
		if dcode != 0 { return dcode }
		if _, ok := doc_row(&m, id); !ok {
			return analysis_errorf("no document %d in the manifest", u32(id))
		}
		ds, dh, ocode := open_graph_store(g, dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		own: [dynamic]gl.Doc_Attr = make([dynamic]gl.Doc_Attr, 0, 8, a)
		for r in gl.graph_doc_attrs(&ds.graph) {
			if r.doc == id { append(&own, r) }
		}
		gl.sort_with_buffer(own[:], attr_key_less, a)
		rows: [dynamic]string = make([dynamic]string, 0, len(own), a)
		for r in own[:] {
			append(&rows, attr_row_json(u32(id), r.key, r.val, a))
		}
		emit_envelope("attr", dh, g.variant, false, join_rows(rows[:], a), a)
		return EXIT_OK
	case "list":
		if len(args) != 0 { return usage_errorf("attr list takes no arguments") }
		ds, dh, ocode := open_graph_store(g, dir, &m, a)
		if ocode != 0 { return ocode }
		defer discard_err(gl.disk_store_close(ds))
		counts: map[Pair_Key]int = make(map[Pair_Key]int, a)
		for r in gl.graph_doc_attrs(&ds.graph) {
			counts[Pair_Key{a = r.key, b = r.val}] += 1
		}
		inv: [dynamic]Attr_Count = make([dynamic]Attr_Count, 0, len(counts), a)
		for k, n in counts { append(&inv, Attr_Count{key = k.a, val = k.b, docs = n}) }
		gl.sort_with_buffer(inv[:], attr_count_less, a)
		rows: [dynamic]string = make([dynamic]string, 0, len(inv), a)
		for e in inv[:] {
			b := strings.builder_make(a)
			strings.write_string(&b, "{\"key\":")
			glexport.json_esc(e.key, &b)
			strings.write_string(&b, ",\"val\":")
			glexport.json_esc(e.val, &b)
			strings.write_string(&b, ",\"docs\":")
			fmt.sbprintf(&b, "%d", e.docs)
			strings.write_string(&b, "}")
			append(&rows, strings.to_string(b))
		}
		emit_envelope("attr", dh, g.variant, false, join_rows(rows[:], a), a)
		return EXIT_OK
	}
	return usage_errorf("attr: unknown subcommand %s", sub)
}
