package main

/*
The word co-occurrence network: per-document co_occurrence merged
host-side — pairs never cross documents — strongest edges first,
rendered as Graphviz dot (the default), mermaid, or the pair rows
as JSON. The dot and mermaid renderings print raw: they are the
result, not rows, so the JSON provenance envelope does not wrap
them; a capped rendering says so on stderr. --clusters k colors the
nodes by cutting the merge tree over the same network (cluster's
pipeline verbatim), so the picture and cluster --k agree.
*/

import "core:fmt"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

cmd_graph :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	doc_sel := ""
	window, cap_n, top := 5, 20000, 60
	format := "dot"
	clusters := 0
	method := gl.Linkage.Ward
	distance := Dist_Kind.Jaccard
	fs := Filter_Spec{pos_prefixes = make([dynamic]string, 0, 4, a)}
	for i := 0; i < len(rest); i += 1 {
		code := parse_filter_flags(rest, &i, &fs, a)
		if code == -1 {
			arg := rest[i]
			if arg == "--doc" {
				v, ok := flag_value(rest, &i, "--doc")
				if !ok { return EXIT_USAGE }
				doc_sel = v
			} else if arg == "--window" {
				v, ok := flag_int(rest, &i, "--window", 0)
				if !ok { return EXIT_USAGE }
				window = v
			} else if arg == "--cap" {
				v, ok := flag_int(rest, &i, "--cap", 1)
				if !ok { return EXIT_USAGE }
				cap_n = v
			} else if arg == "--top" {
				v, ok := flag_int(rest, &i, "--top", 1)
				if !ok { return EXIT_USAGE }
				top = v
			} else if arg == "--clusters" {
				v, ok := flag_int(rest, &i, "--clusters", 1)
				if !ok { return EXIT_USAGE }
				clusters = v
			} else if arg == "--method" {
				v, ok := flag_value(rest, &i, "--method")
				if !ok { return EXIT_USAGE }
				m, mcode := linkage_from_string(v, "graph")
				if mcode != 0 { return mcode }
				method = m
			} else if arg == "--distance" {
				v, ok := flag_value(rest, &i, "--distance")
				if !ok { return EXIT_USAGE }
				d, dcode := dist_kind_from_string(v, "graph")
				if dcode != 0 { return dcode }
				distance = d
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if fcode := choice_ok("graph", "--format", v, FORMAT_GRAPH); fcode != 0 {
					return fcode
				}
				format = v
			} else {
				return unknown_flag_errorf("graph", arg)
			}
		} else if code != 0 {
			return code
		}
	}

	if clusters > 0 && format == "json" {
		return usage_errorf("graph: --clusters colors dot/mermaid, not json rows")
	}

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, doc_sel, a)
	if icode != 0 { return icode }

	pairs_all, capped, mcode := merged_pairs(&rs, ids, &fs, window, cap_n, a)
	if mcode != 0 { return mcode }
	truncated := capped
	pairs_out := pairs_all
	if len(pairs_all) > top {
		pairs_out = pairs_all[:top]
		truncated = true
	}

	labels: []int
	if clusters > 0 {
		keys := network_keys(pairs_out, a)
		if len(keys) < 2 {
			return analysis_errorf("graph: fewer than two words to cluster")
		}
		if clusters > len(keys) {
			return analysis_errorf("graph: --clusters %d exceeds the %d words in the network",
				clusters, len(keys))
		}
		dist, dcode := distance_table(pairs_out, keys, distance, a)
		if dcode != 0 { return dcode }
		merges, merr := gl.linkage_merges(dist, len(keys), method, a)
		if merr != .None {
			return analysis_errorf("graph: %s", freq_err_text(merr))
		}
		l, lerr := gl.cluster_labels(merges, len(keys), clusters, a)
		if lerr != .None {
			return analysis_errorf("graph: %s", freq_err_text(lerr))
		}
		labels = l
	}

	switch format {
	case "json":
		emit_envelope("graph", rs.eng.hash, g.variant, truncated,
			glexport.cooc_rows_json(pairs_out, a), a)
	case "dot":
		fmt.print(glexport.pairs_export_dot(pairs_out, a, labels))
		if truncated && !g.quiet {
			fmt.eprintf("truncated: more pairs existed past --top %d\n", top)
		}
	case "mermaid":
		fmt.print(glexport.pairs_export_mermaid(pairs_out, a, labels))
		if truncated && !g.quiet {
			fmt.eprintf("truncated: more pairs existed past --top %d\n", top)
		}
	}
	return EXIT_OK
}
