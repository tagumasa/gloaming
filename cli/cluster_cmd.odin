package main

/*
The cluster pipeline's two read sides. cluster cuts the merge tree:
the distance menu, then ward/average/complete linkage over it — the
merge rows by default, or the word→cluster table under --k, or the
tree/forest itself as dot/mermaid (the k-cut forest is the first
n−k merge rows, a front slice the exporter takes as-is). coords is
the correspondence-analysis stand-in: power iteration over the same
network's weight table, two axes per word — tsv/json rows, or a dot
file whose nodes are pinned at their coordinates for neato. Both
share graph's front (filters, window, cap, top), so cluster --k and
graph --clusters agree on the labels; like graph, the renderings
print raw and a truncation says so on stderr.
*/

import "core:fmt"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

cmd_cluster :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	doc_sel := ""
	window, cap_n, top := 5, 20000, 60
	method, method_s := gl.Linkage.Ward, "ward"
	distance, distance_s := Dist_Kind.Jaccard, "jaccard"
	k := 0
	format := "tsv"
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
			} else if arg == "--method" {
				v, ok := flag_value(rest, &i, "--method")
				if !ok { return EXIT_USAGE }
				m, mcode := linkage_from_string(v, "cluster")
				if mcode != 0 { return mcode }
				method, method_s = m, v
			} else if arg == "--distance" {
				v, ok := flag_value(rest, &i, "--distance")
				if !ok { return EXIT_USAGE }
				d, dcode := dist_kind_from_string(v, "cluster")
				if dcode != 0 { return dcode }
				distance, distance_s = d, v
			} else if arg == "--k" {
				v, ok := flag_int(rest, &i, "--k", 1)
				if !ok { return EXIT_USAGE }
				k = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if fcode := choice_ok("cluster", "--format", v, FORMAT_CLUSTER); fcode != 0 {
					return fcode
				}
				format = v
			} else {
				return unknown_flag_errorf("cluster", arg)
			}
		} else if code != 0 {
			return code
		}
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

	keys := network_keys(pairs_out, a)
	if len(keys) < 2 {
		return analysis_errorf("cluster: fewer than two words in the network")
	}
	if k > len(keys) {
		return analysis_errorf("cluster: --k %d exceeds the %d words in the network",
			k, len(keys))
	}
	dist, dcode := distance_table(pairs_out, keys, distance, a)
	if dcode != 0 { return dcode }
	merges, merr := gl.linkage_merges(dist, len(keys), method, a)
	if merr != .None {
		return analysis_errorf("cluster: %s", freq_err_text(merr))
	}
	labels: []int
	if k > 0 {
		l, lerr := gl.cluster_labels(merges, len(keys), k, a)
		if lerr != .None {
			return analysis_errorf("cluster: %s", freq_err_text(lerr))
		}
		labels = l
	}

	switch format {
	case "tsv":
		if k > 0 {
			fmt.println("#key\tcluster")
			for key, i in keys {
				b := strings.builder_make(a)
				tsv_esc(key, &b)
				fmt.sbprintf(&b, "\t%d", labels[i])
				fmt.println(strings.to_string(b))
			}
		} else {
			fmt.println("#a\tb\tdist\tsize")
			for m in merges {
				fmt.printf("%d\t%d\t%.6f\t%d\n", m.a, m.b, m.dist, m.size)
			}
		}
	case "json":
		rows := glexport.ward_rows_json(merges, a)
		if k > 0 { rows = glexport.cluster_rows_json(keys, labels, a) }
		eb := strings.builder_make(a)
		fmt.sbprintf(&eb, "\"method\":\"%s\",\"distance\":\"%s\"",
			method_s, distance_s)
		if k > 0 { fmt.sbprintf(&eb, ",\"k\":%d", k) }
		strings.write_string(&eb, ",")
		emit_envelope("cluster", rs.eng.hash, g.variant, truncated, rows, a,
			strings.to_string(eb))
	case "dot":
		tree := merges
		if k > 0 { tree = merges[:len(keys) - k] }
		fmt.print(glexport.merges_export_dot(keys, tree, a))
		if truncated && !g.quiet {
			fmt.eprintf("truncated: more pairs existed past --top %d\n", top)
		}
	case "mermaid":
		tree := merges
		if k > 0 { tree = merges[:len(keys) - k] }
		fmt.print(glexport.merges_export_mermaid(keys, tree, a))
		if truncated && !g.quiet {
			fmt.eprintf("truncated: more pairs existed past --top %d\n", top)
		}
	}
	return EXIT_OK
}

cmd_coords :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	doc_sel := ""
	window, cap_n, top := 5, 20000, 60
	tol, max_iter := 1e-12, 256
	format := "tsv"
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
			} else if arg == "--tol" {
				v, ok := flag_float(rest, &i, "--tol", 0)
				if !ok { return EXIT_USAGE }
				tol = v
			} else if arg == "--max-iter" {
				v, ok := flag_int(rest, &i, "--max-iter", 1)
				if !ok { return EXIT_USAGE }
				max_iter = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if v != "tsv" && v != "json" && v != "dot" {
					return usage_errorf("coords: --format tsv|json|dot")
				}
				format = v
			} else {
				return unknown_flag_errorf("coords", arg)
			}
		} else if code != 0 {
			return code
		}
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

	keys := network_keys(pairs_out, a)
	w, werr := gl.cooc_weights(pairs_out, keys, a)
	if werr != .None {
		return analysis_errorf("cooc_weights: %s", freq_err_text(werr))
	}
	coords, qerr := gl.power_coords(w, len(keys), tol, max_iter, a)
	if qerr != .None {
		return analysis_errorf("power_coords: %s", freq_err_text(qerr))
	}

	switch format {
	case "tsv":
		fmt.println("#key\tx\ty")
		for key, i in keys {
			b := strings.builder_make(a)
			tsv_esc(key, &b)
			fmt.sbprintf(&b, "\t%.6f\t%.6f", coords[i].x, coords[i].y)
			fmt.println(strings.to_string(b))
		}
	case "json":
		eb := strings.builder_make(a)
		fmt.sbprintf(&eb, "\"tol\":%g,\"max_iter\":%d,", tol, max_iter)
		emit_envelope("coords", rs.eng.hash, g.variant, truncated,
			glexport.coords_rows_json(keys, coords, a), a,
			strings.to_string(eb))
	case "dot":
		fmt.print(glexport.coords_export_dot(keys, coords, a))
		if truncated && !g.quiet {
			fmt.eprintf("truncated: more pairs existed past --top %d\n", top)
		}
	}
	return EXIT_OK
}
