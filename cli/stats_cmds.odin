package main

/*
The analysis layer: freq, cooc, and the cluster pipeline's shared
front. freq rides the corpus layer (corpus_freq fills the true
cross-document docs count); cooc is per-document co_occurrence merged
host-side — pairs never cross documents — with the cap visible in the
envelope when it bites (any per-document cap or the merged slice);
the default cap is 20,000 pairs. The cluster front below (network
keys, the distance menu) feeds cluster, coords, and graph
--clusters — one pipeline, so the labels agree across all three.
*/

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

load_stopwords :: proc(path: string, a: mem.Allocator) -> ([]string, int) {
	data, err := os.read_entire_file_from_path(path, a)
	if err != nil { return nil, io_errorf("cannot read stopwords file %s", path) }
	s := transmute(string)data
	out: [dynamic]string = make([dynamic]string, 0, 64, a)
	pos := 0
	for pos <= len(s) {
		end := pos
		for end < len(s) && s[end] != '\n' { end += 1 }
		line := s[pos:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		if len(line) > 0 { append(&out, clone_str(line, a)) }
		if end >= len(s) { break }
		pos = end + 1
	}
	return out[:], 0
}

Filter_Spec :: struct {
	pos_prefixes: [dynamic]string,
	stopwords:    []string,
	use_lemma:    bool,
	min_count:    int,
	min_len:      int,
}

build_filter :: proc(fs: ^Filter_Spec) -> gl.Freq_Filter {
	return gl.Freq_Filter{
		pos_prefixes = fs.pos_prefixes[:],
		stopwords = fs.stopwords,
		min_count = fs.min_count,
		use_lemma = fs.use_lemma,
		min_len = fs.min_len,
	}
}

// the shared --pos-prefix…/--lemma/--min-count/--min-len/--stopwords
// family every filter command parses
parse_filter_flags :: proc(rest: []string, i: ^int, fs: ^Filter_Spec,
                           a: mem.Allocator) -> int {
	arg := rest[i^]
	if arg == "--pos-prefix" {
		v, ok := flag_value(rest, i, "--pos-prefix")
		if !ok { return EXIT_USAGE }
		append(&fs.pos_prefixes, v)
	} else if arg == "--lemma" {
		fs.use_lemma = true
	} else if arg == "--min-count" {
		v, ok := flag_int(rest, i, "--min-count", 0)
		if !ok { return EXIT_USAGE }
		fs.min_count = v
	} else if arg == "--min-len" {
		v, ok := flag_int(rest, i, "--min-len", 0)
		if !ok { return EXIT_USAGE }
		fs.min_len = v
	} else if arg == "--stopwords" {
		v, ok := flag_value(rest, i, "--stopwords")
		if !ok { return EXIT_USAGE }
		sw, code := load_stopwords(v, a)
		if code != 0 { return code }
		fs.stopwords = sw
	} else {
		return -1 // not ours
	}
	return 0
}

// the zero-filter count sum over a population — the token total a
// keyness .Tokens basis or a variant diff needs; the scored tables'
// filters never weight it
token_population :: proc(st: gl.Store, ids: []gl.Doc_Id, label: string,
                         a: mem.Allocator) -> (int, int) {
	tot, err := gl.corpus_freq(st, ids, gl.Freq_Filter{}, a)
	if err != .None { return 0, analysis_errorf("corpus_freq (%s): %v", label, err) }
	n := 0
	for e in tot { n += e.count }
	return n, 0
}

cmd_freq :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	doc_sel := ""
	limit := 1000
	format := "json"
	fs := Filter_Spec{pos_prefixes = make([dynamic]string, 0, 4, context.allocator)}
	for i := 0; i < len(rest); i += 1 {
		code := parse_filter_flags(rest, &i, &fs, context.allocator)
		if code == -1 {
			arg := rest[i]
			if arg == "--doc" {
				v, ok := flag_value(rest, &i, "--doc")
				if !ok { return EXIT_USAGE }
				doc_sel = v
			} else if arg == "--limit" {
				v, ok := flag_int(rest, &i, "--limit", 1)
				if !ok { return EXIT_USAGE }
				limit = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if v != "json" && v != "tsv" { return usage_errorf("freq: --format json|tsv") }
				format = v
			} else {
				return unknown_flag_errorf("freq", arg)
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

	entries, serr := gl.corpus_freq(rs.st, ids, build_filter(&fs), a)
	if serr != .None {
		return analysis_errorf("corpus_freq: %v", serr)
	}

	truncated := false
	if len(entries) > limit {
		entries = entries[:limit]
		truncated = true
	}
	if format == "tsv" {
		for e in entries {
			b := strings.builder_make(a)
			tsv_esc(e.lemma, &b)
			fmt.sbprintf(&b, "\t%d\t%d", e.count, e.docs)
			fmt.println(strings.to_string(b))
		}
		return EXIT_OK
	}
	emit_envelope("freq", rs.eng.hash, g.variant, truncated,
		glexport.freq_rows_json(entries, a), a)
	return EXIT_OK
}

Pair_Key :: struct {
	a, b: string,
}

pair_less :: proc(x, y: ^gl.Co_Pair) -> bool {
	if x.n != y.n { return x.n > y.n }
	c := strings.compare(x.a, y.a)
	if c != 0 { return c < 0 }
	return strings.compare(x.b, y.b) < 0
}

// cooc and graph share the merge: per-document co_occurrence over
// the population, accumulated host-side (pairs never cross
// documents) and sorted strongest first. The bool says a
// per-document max_pairs cap bit; the caller's own slice cut is the
// caller's truncated flag.
merged_pairs :: proc(rs: ^Read_State, ids: []gl.Doc_Id, fs: ^Filter_Spec,
                     window: int, cap_n: int,
                     a: mem.Allocator) -> ([]gl.Co_Pair, bool, int) {
	merged: map[Pair_Key]int = make(map[Pair_Key]int, a)
	capped := false
	for id in ids {
		stream, serr := load_stream(rs, id, a)
		if serr != .None {
			return nil, false, analysis_errorf("store read doc %d: %v", u32(id), serr)
		}
		pairs, pairs_truncated, ferr := gl.co_occurrence(stream, nil, gl.Cooc_Options{
			filter = build_filter(fs),
			unit = .Segments,
			window = window,
			max_pairs = cap_n,
		}, a)
		if ferr != .None {
			return nil, false, analysis_errorf("co_occurrence: %s", freq_err_text(ferr))
		}
		if pairs_truncated { capped = true }
		for p in pairs {
			merged[Pair_Key{a = p.a, b = p.b}] += p.n
		}
	}
	out: [dynamic]gl.Co_Pair = make([dynamic]gl.Co_Pair, 0, len(merged), a)
	for k, n in merged {
		append(&out, gl.Co_Pair{a = k.a, b = k.b, n = n})
	}
	gl.sort_with_buffer(out[:], pair_less, a)
	return out[:], capped, 0
}

/*
The cluster pipeline's shared front. network_keys is the distinct
pair endpoints in strings.compare order — the same order glexport's
exporters number nodes by — so a cluster_labels leaf i IS exporter
node n<i>: one labelling colors the table and the picture alike. The
distance menu is five entries: Jaccard over in-table neighborhoods
and Euclid/Cosine over the full weight rows go to the library procs;
Dice/Simpson are the assoc_value composition the library records as
call-site work — n the shared count, n_a/n_b the row sums, windows
the table mass, a zero cell distance 1, the diagonal 0.
*/

Dist_Kind :: enum {
	Jaccard,
	Euclid,
	Cosine,
	Dice,
	Simpson,
}

network_keys :: proc(pairs: []gl.Co_Pair, a: mem.Allocator) -> []string {
	seen := make(map[string]bool, a)
	defer delete(seen)
	keys: [dynamic]string = make([dynamic]string, 0, 2 * len(pairs), a)
	for p in pairs {
		sides := [2]string{p.a, p.b}
		for k in sides {
			if _, dup := seen[k]; dup { continue }
			seen[k] = true
			append(&keys, k)
		}
	}
	gl.sort_with_buffer(keys[:], str_less, a)
	return keys[:]
}

distance_table :: proc(pairs: []gl.Co_Pair, keys: []string, kind: Dist_Kind,
                       a: mem.Allocator) -> ([]f64, int) {
	switch kind {
	case .Jaccard:
		d, err := gl.cooc_distance(pairs, keys, a)
		if err != .None {
			return nil, analysis_errorf("cooc_distance: %s", freq_err_text(err))
		}
		return d, 0
	case .Euclid, .Cosine:
		w, werr := gl.cooc_weights(pairs, keys, a)
		if werr != .None {
			return nil, analysis_errorf("cooc_weights: %s", freq_err_text(werr))
		}
		m := gl.Weight_Distance.Euclid
		if kind == .Cosine { m = .Cosine }
		d, derr := gl.weight_distance(w, len(keys), m, a)
		if derr != .None {
			return nil, analysis_errorf("weight_distance: %s", freq_err_text(derr))
		}
		return d, 0
	case .Dice, .Simpson:
		w, werr := gl.cooc_weights(pairs, keys, a)
		if werr != .None {
			return nil, analysis_errorf("cooc_weights: %s", freq_err_text(werr))
		}
		k := len(keys)
		d := make([]f64, k * k, a)
		rowsum := make([]int, k, a)
		total := 0
		for i in 0..<k {
			s := 0
			for j in 0..<k { s += int(w[i * k + j]) }
			rowsum[i] = s
			total += s
		}
		measure := gl.Assoc_Measure.Dice
		if kind == .Simpson { measure = .Simpson }
		for i in 0..<k {
			d[i * k + i] = 0
			for j in i + 1..<k {
				n := int(w[i * k + j])
				dij := 1.0
				if n > 0 {
					v, aerr := gl.assoc_value(measure, n, rowsum[i], rowsum[j], total)
					if aerr != .None {
						return nil, analysis_errorf("assoc_value: %s", freq_err_text(aerr))
					}
					dij = 1.0 - v
				}
				d[i * k + j] = dij
				d[j * k + i] = dij
			}
		}
		return d, 0
	}
	return nil, 0
}

cmd_cooc :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	doc_sel := ""
	cap_n := 20000
	format := "json"
	fs := Filter_Spec{pos_prefixes = make([dynamic]string, 0, 4, context.allocator)}
	for i := 0; i < len(rest); i += 1 {
		code := parse_filter_flags(rest, &i, &fs, context.allocator)
		if code == -1 {
			arg := rest[i]
			if arg == "--doc" {
				v, ok := flag_value(rest, &i, "--doc")
				if !ok { return EXIT_USAGE }
				doc_sel = v
			} else if arg == "--cap" {
				v, ok := flag_int(rest, &i, "--cap", 1)
				if !ok { return EXIT_USAGE }
				cap_n = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if v != "json" && v != "tsv" { return usage_errorf("cooc: --format json|tsv") }
				format = v
			} else {
				return unknown_flag_errorf("cooc", arg)
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

	pairs_all, capped, mcode := merged_pairs(&rs, ids, &fs, 0, cap_n, a)
	if mcode != 0 { return mcode }
	truncated := capped
	pairs_out := pairs_all
	if len(pairs_all) > cap_n {
		pairs_out = pairs_all[:cap_n]
		truncated = true
	}

	if format == "tsv" {
		for p in pairs_out {
			b := strings.builder_make(a)
			tsv_esc(p.a, &b)
			strings.write_string(&b, "\t")
			tsv_esc(p.b, &b)
			fmt.sbprintf(&b, "\t%d", p.n)
			fmt.println(strings.to_string(b))
		}
		return EXIT_OK
	}
	emit_envelope("cooc", rs.eng.hash, g.variant, truncated,
		glexport.cooc_rows_json(pairs_out, a), a)
	return EXIT_OK
}
