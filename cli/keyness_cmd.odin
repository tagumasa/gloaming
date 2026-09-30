package main

/*
Keyness — words characteristic of one document population against
another. The group selector is deliberately tiny —
all | rest | doc:… | key=val, no boolean algebra; a union runs the
command twice, so the selector stays memorizable. The command
composes corpus_freq per population with keyness_scores;
populations stay whole whatever the scored tables filtered, so
--min-count drops rows without re-weighting the kept ones. The tsv
rendering opens with a '#' header line — key/value/a/b/c/d are
opaque without one (crosstab's rule).
*/

import "core:fmt"
import "core:mem"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

parse_selector :: proc(sel: string, m: ^Manifest, attrs: []gl.Doc_Attr,
                       all_ids: []gl.Doc_Id,
                       a: mem.Allocator) -> ([]gl.Doc_Id, int) {
	if sel == "all" {
		ids := make([]gl.Doc_Id, len(all_ids), a)
		copy(ids, all_ids)
		return ids, 0
	}
	if strings.starts_with(sel, "doc:") {
		list: [dynamic]gl.Doc_Id = make([dynamic]gl.Doc_Id, 0, 4, a)
		seen: map[u32]bool = make(map[u32]bool, a)
		part := sel[4:]
		pos := 0
		for pos <= len(part) {
			end := pos
			for end < len(part) && part[end] != ',' { end += 1 }
			one := part[pos:end]
			if one == "" { return nil, usage_errorf("selector %s: empty doc element", sel) }
			id, code := resolve_doc(one, m)
			if code != 0 { return nil, code }
			if !seen[u32(id)] {
				seen[u32(id)] = true
				append(&list, id)
			}
			if end >= len(part) { break }
			pos = end + 1
		}
		out := list[:]
		gl.sort_with_buffer(out, gl.docid_less, a)
		return out, 0
	}
	if eq := strings.index(sel, "="); eq >= 0 {
		key, val := sel[:eq], sel[eq + 1:]
		if key == "" { return nil, usage_errorf("selector %s: empty attr key", sel) }
		out: [dynamic]gl.Doc_Id = make([dynamic]gl.Doc_Id, 0, 8, a)
		for id in all_ids {
			for r in attrs {
				if r.doc == id && r.key == key && r.val == val {
					append(&out, id)
					break
				}
			}
		}
		return out[:], 0
	}
	return nil, usage_errorf(
		"selector %s is none of all | doc:<id|suffix>,… | <key>=<value>", sel)
}

// the complement of `of` within all_ids — the default reference
rest_ids :: proc(all_ids: []gl.Doc_Id, of: []gl.Doc_Id,
                 a: mem.Allocator) -> []gl.Doc_Id {
	drop: map[u32]bool = make(map[u32]bool, a)
	for id in of { drop[u32(id)] = true }
	out: [dynamic]gl.Doc_Id = make([dynamic]gl.Doc_Id, 0, len(all_ids), a)
	for id in all_ids {
		if !drop[u32(id)] { append(&out, id) }
	}
	return out[:]
}

cmd_keyness :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	target_s := ""
	ref_s := "rest"
	measure_s, basis_s := "dunning", "tokens"
	top := 40
	format := "json"
	fs := Filter_Spec{pos_prefixes = make([dynamic]string, 0, 4, a)}
	for i := 0; i < len(rest); i += 1 {
		code := parse_filter_flags(rest, &i, &fs, a)
		if code == -1 {
			arg := rest[i]
			if arg == "--target" {
				v, ok := flag_value(rest, &i, "--target")
				if !ok { return EXIT_USAGE }
				target_s = v
			} else if arg == "--reference" {
				v, ok := flag_value(rest, &i, "--reference")
				if !ok { return EXIT_USAGE }
				ref_s = v
			} else if arg == "--measure" {
				v, ok := flag_value(rest, &i, "--measure")
				if !ok { return EXIT_USAGE }
				measure_s = v
			} else if arg == "--basis" {
				v, ok := flag_value(rest, &i, "--basis")
				if !ok { return EXIT_USAGE }
				if v != "docs" && v != "tokens" {
					return usage_errorf("keyness: --basis docs|tokens")
				}
				basis_s = v
			} else if arg == "--top" {
				v, ok := flag_int(rest, &i, "--top", 1)
				if !ok { return EXIT_USAGE }
				top = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if v != "json" && v != "tsv" { return usage_errorf("keyness: --format json|tsv") }
				format = v
			} else {
				return unknown_flag_errorf("keyness", arg)
			}
		} else if code != 0 {
			return code
		}
	}
	if target_s == "" { return usage_errorf("keyness: --target required") }
	if target_s == "rest" { return usage_errorf("keyness: 'rest' is not a target") }
	measure, mok := parse_measure(measure_s)
	if !mok {
		return usage_errorf("keyness: --measure %s", vocab_menu(gl.Key_Measure, KEY_MEASURES[:]))
	}
	basis := gl.Keyness_Basis.Tokens
	if basis_s == "docs" { basis = .Docs }

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, "", a)
	if icode != 0 { return icode }
	attrs := gl.graph_doc_attrs(&rs.ds.graph)

	target, tcode := parse_selector(target_s, &rs.m, attrs, ids, a)
	if tcode != 0 { return tcode }
	if len(target) == 0 {
		return analysis_errorf("keyness: no documents match --target %s", target_s)
	}
	ref: []gl.Doc_Id
	if ref_s == "rest" {
		ref = rest_ids(ids, target, a)
	} else {
		r2, rcode := parse_selector(ref_s, &rs.m, attrs, ids, a)
		if rcode != 0 { return rcode }
		ref = r2
	}
	if len(ref) == 0 {
		return analysis_errorf("keyness: the reference population is empty")
	}

	ttab, terr := gl.corpus_freq(rs.st, target, build_filter(&fs), a)
	if terr != .None { return analysis_errorf("corpus_freq (target): %v", terr) }
	rtab, rerr := gl.corpus_freq(rs.st, ref, build_filter(&fs), a)
	if rerr != .None { return analysis_errorf("corpus_freq (reference): %v", rerr) }

	tpop, rpop := len(target), len(ref)
	if basis == .Tokens {
		// populations stay whole whatever the scored tables filtered,
		// so --min-count drops rows, not weight
		tt, tc := token_population(rs.st, target, "target", a)
		if tc != 0 { return tc }
		rr, rc := token_population(rs.st, ref, "reference", a)
		if rc != 0 { return rc }
		tpop, rpop = tt, rr
	}

	rows, kerr := gl.keyness_scores(ttab, tpop, rtab, rpop,
		gl.Keyness_Options{m = measure, basis = basis}, a)
	if kerr != .None { return analysis_errorf("keyness: %s", freq_err_text(kerr)) }

	rows_out := rows
	truncated := false
	if len(rows) > top {
		rows_out = rows[:top]
		truncated = true
	}

	if format == "tsv" {
		fmt.println("#key\tvalue\ta\tb\tc\td")
		for r in rows_out {
			b := strings.builder_make(a)
			tsv_esc(r.key, &b)
			strings.write_string(&b, "\t")
			glexport.fmt_f6(&b, r.value)
			fmt.sbprintf(&b, "\t%d\t%d\t%d\t%d", r.a, r.b, r.c, r.d)
			fmt.println(strings.to_string(b))
		}
		return EXIT_OK
	}
	extra := strings.builder_make(a)
	strings.write_string(&extra, "\"measure\":")
	glexport.json_esc(measure_s, &extra)
	strings.write_string(&extra, ",\"basis\":")
	glexport.json_esc(basis_s, &extra)
	fmt.sbprintf(&extra, ",\"target_pop\":%d,\"ref_pop\":%d,", tpop, rpop)
	emit_envelope("keyness", rs.eng.hash, g.variant, truncated,
		glexport.keyness_rows_json(rows_out, a), a, strings.to_string(extra))
	return EXIT_OK
}
