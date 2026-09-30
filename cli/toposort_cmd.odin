package main

/*
The directed order over curated relations: Kahn's algorithm on the
selected state's graph (the variant's replayed copy under --variant),
--kind filtering like every graph read. TSV is the default (rank, id,
name per row); json wraps the rows in the provenance envelope with
the cyclic remainder as its extra fragment. A cycle is not an error —
the order is the acyclic prefix and the cyclic entities ride the
extra — but the tsv rendering says so on stderr, the capped-dot
precedent. Reads the selected state like every graph-row read.
*/

import "core:fmt"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

cmd_toposort :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	format := "tsv"
	kinds: [dynamic]string = make([dynamic]string, 0, 4, a)
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--kind" {
			v, ok := flag_value(rest, &i, "--kind")
			if !ok { return EXIT_USAGE }
			append(&kinds, v)
		} else if arg == "--format" {
			v, ok := flag_value(rest, &i, "--format")
			if !ok { return EXIT_USAGE }
			if v != "tsv" && v != "json" {
				return usage_errorf("toposort: --format tsv|json")
			}
			format = v
		} else {
			return unknown_flag_errorf("toposort", arg)
		}
	}
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }
	ds, dh, ocode := open_graph_store(g, dir, &m, a)
	if ocode != 0 { return ocode }
	defer discard_err(gl.disk_store_close(ds))

	res, terr := gl.graph_toposort(&ds.graph, kinds[:], a)
	if terr != .None {
		return analysis_errorf("toposort: %v", terr)
	}

	switch format {
	case "json":
		emit_envelope("toposort", dh, g.variant, false,
			glexport.topo_rows_json(res.order, &ds.graph, a), a,
			glexport.topo_cyclic_json(res.cyclic, &ds.graph, a))
	case "tsv":
		for id, i in res.order {
			b := strings.builder_make(a)
			fmt.sbprintf(&b, "%d\t%d\t", i, int(id))
			tsv_esc(entity_name(&ds.graph, id), &b)
			fmt.println(strings.to_string(b))
		}
		if len(res.cyclic) > 0 && !g.quiet {
			fmt.eprintf("cyclic: %d entities on or downstream of a cycle — json format reports them\n",
				len(res.cyclic))
		}
	}
	return EXIT_OK
}
