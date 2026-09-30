package main

/*
The variant generations: the loop's write step. A variant is an
immutable record — its own dict.qdct (the clone with the entries
merged), its own copy of the entries file, and its own store
(payloads are keyed by dict_version, so a variant can never share
the base store's blobs — ds_tokens' Stale refusal makes that
structural). Changing a name's entry set is a refusal: remove first.
The entries file is the simplified authoring format — surface, pos,
lemma, reading, optional cost — with the CLI filling what the author
should not have to know: left_id = right_id = 0 and cost = −3000 by
default. −3000 sits mid-plateau: any cost in −1000…−4000 wins the
same entries with identical output, 0 captures compound splits only
partially, and entries at ≥ 2000 never win a contest; the JP
katakana case gains monotonically down to −3000, moli's tested
±3000 boundary. Per-entry cost stays the author's lever.
*/

import "core:crypto/sha2"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"
import moli "moli:moli"
import ma "gladapter:moli_adapter"

DEFAULT_COST :: -3000

// the gains report's headline cut — a hint, not a table
GAINS_TOP :: 10

cmd_variant :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) == 0 {
		return usage_errorf("variant: add <name> <entries.tsv> [--cost C] | list | remove <name> | diff <a> <b> [--top N]")
	}
	sub := rest[0]
	args := rest[1:]
	switch sub {
	case "add":    return variant_add(args, g)
	case "list":   return variant_list(args, g)
	case "remove": return variant_remove(args, g)
	case "diff":   return variant_diff(args, g)
	}
	return usage_errorf("variant: unknown subcommand %s", sub)
}

valid_variant_name :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." { return false }
	for c in name {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		if !ok { return false }
	}
	return true
}

/*
The graph-row replay into a fresh variant store, through the same
public writers any host would use: live entities first (ids remap
dense — the variant reproduces live state, not history; tombstones
and their id gaps stay base-local), then mentions and relations with
remapped endpoints, then attrs. Byte spans and preserved doc ids make
the evidence copy exact; a repeated identity cannot exist in live
state, so each add lands one row identical to its base row.
*/
replay_graph_rows :: proc(base: ^gl.Disk_Store, dst: ^gl.Disk_Store,
                          a: mem.Allocator) -> int {
	remap: map[gl.Entity_Id]gl.Entity_Id = make(map[gl.Entity_Id]gl.Entity_Id, a)
	defer delete(remap)
	for e in base.graph.entities {
		if !e.live { continue }
		id, err := gl.graph_entity_add(dst, base.graph.kinds[e.kind], e.name, e.aliases)
		if err != .None {
			return analysis_errorf("graph replay entity %s: %v", e.name, err)
		}
		remap[e.id] = id
	}
	for m, i in base.graph.mentions {
		if _, err := gl.graph_mention_add(dst, remap[m.entity], m.span); err != .None {
			return analysis_errorf("graph replay mention %d: %v", i, err)
		}
	}
	for r in base.graph.relations {
		if !r.live { continue }
		_, err := gl.graph_relation_add(dst, base.graph.kinds[r.kind],
			remap[r.from], remap[r.to], r.evidence, r.derived)
		if err != .None {
			return analysis_errorf("graph replay relation %d: %v", int(r.id), err)
		}
	}
	for attr in gl.graph_doc_attrs(&base.graph) {
		if err := gl.graph_attr_put(dst, attr.doc, attr.key, attr.val); err != .None {
			return analysis_errorf("attr replay doc %d: %v", u32(attr.doc), err)
		}
	}
	return 0
}

sha_hex :: proc(data: []u8, a: mem.Allocator) -> string {
	ctx256: sha2.Context_256
	sha2.init_256(&ctx256)
	sha2.update(&ctx256, data)
	dig: [32]u8
	sha2.final(&ctx256, dig[:])
	b := strings.builder_make(a)
	for byte in dig { fmt.sbprintf(&b, "%02x", byte) }
	return strings.to_string(b)
}

parse_entries :: proc(data: []u8, path: string, default_cost: i16,
                      a: mem.Allocator) -> ([]moli.User_Entry, int) {
	s := transmute(string)data
	out: [dynamic]moli.User_Entry = make([dynamic]moli.User_Entry, 0, 16, a)
	line_no := 0
	pos := 0
	for pos <= len(s) {
		end := pos
		for end < len(s) && s[end] != '\n' { end += 1 }
		line := s[pos:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		line_no += 1
		pos = end + 1
		if len(line) == 0 || line[0] == '#' { if end >= len(s) { break }; continue }

		fields: [5]string
		nf := 0
		start := 0
		for i := 0; i <= len(line); i += 1 {
			if i == len(line) || line[i] == '\t' {
				if nf < 5 {
					fields[nf] = line[start:i]
					nf += 1
				}
				start = i + 1
			}
		}
		if nf < 4 {
			return nil, usage_errorf("%s:%d: surface<TAB>pos<TAB>lemma<TAB>reading[<TAB>cost]",
				path, line_no)
		}
		if fields[0] == "" {
			return nil, usage_errorf("%s:%d: empty surface", path, line_no)
		}
		cost := default_cost
		if nf >= 5 {
			n, ok := strconv.parse_int(fields[4], 10)
			if !ok || n < -32768 || n > 32767 {
				return nil, usage_errorf("%s:%d: bad cost %s", path, line_no, fields[4])
			}
			cost = i16(n)
		}
		append(&out, moli.User_Entry{
			surface = fields[0],
			left_id = 0,
			right_id = 0,
			cost = cost,
			pos = fields[1],
			lemma = fields[2],
			reading = fields[3],
		})
		if end >= len(s) { break }
	}
	return out[:], 0
}

Gain :: struct {
	surface: string,
	count:   int,
}

gain_less :: proc(x, y: ^Gain) -> bool {
	if x.count != y.count { return x.count > y.count }
	return strings.compare(x.surface, y.surface) < 0
}

variant_add :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	name := ""
	tsv_path := ""
	cost_default: i16 = DEFAULT_COST
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--cost" {
			v, ok := flag_value(rest, &i, "--cost")
			if !ok { return EXIT_USAGE }
			n, pok := strconv.parse_int(v, 10)
			if !pok || n < -32768 || n > 32767 {
				return usage_errorf("variant add: bad --cost %s", v)
			}
			cost_default = i16(n)
		} else if strings.starts_with(arg, "--") {
			return unknown_flag_errorf("variant add", arg)
		} else if name == "" {
			name = arg
		} else if tsv_path == "" {
			tsv_path = arg
		} else {
			return usage_errorf("variant add: <name> <entries.tsv>")
		}
	}
	if name == "" || tsv_path == "" { return usage_errorf("variant add: <name> <entries.tsv>") }
	if !valid_variant_name(name) {
		return usage_errorf("variant add: name chars [A-Za-z0-9._-] only")
	}

	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }
	if _, dup := find_variant(&m, name); dup {
		return analysis_errorf("variant %s exists — variant remove first (variants are immutable records)", name)
	}
	if m.kind == .Fixture {
		return usage_errorf("variant add: fixture-language projects have no dictionary to extend")
	}
	if g.variant != "" {
		return base_state_errorf("variant add builds from the base state", "")
	}

	data, err := os.read_entire_file_from_path(tsv_path, a)
	if err != nil { return io_errorf("cannot read %s", tsv_path) }
	entries, pcode := parse_entries(data, tsv_path, cost_default, a)
	if pcode != 0 { return pcode }
	if len(entries) == 0 { return usage_errorf("%s holds no entries", tsv_path) }

	base, bcode := eng_load(dir, &m, nil, a)
	if bcode != 0 { return bcode }
	defer eng_destroy(&base, a)

	variant_an := new(moli.Analyzer, a)
	defer {
		moli.free(variant_an)
		free(variant_an, a)
	}
	cloned, cerr, uerr := ma.variant_analyzer(base.an, entries, a)
	if cerr != nil { return analysis_errorf("variant clone failed: %s", cerr) }
	if uerr != nil {
		return analysis_errorf("entries rejected: %s", moli.load_error_message(uerr, a))
	}
	variant_an^ = cloned
	vhash, herr := ma.dictionary_hash(variant_an)
	if herr != nil { return io_errorf("dictionary hash failed") }

	vdir := pjoin({dir, "variants"}, a)
	if vdir != "" && !os.exists(vdir) {
		if mkerr := os.mkdir(vdir); mkerr != nil { return io_errorf("cannot create %s", vdir) }
	}
	ndir := pjoin({vdir, name}, a)
	if ndir == "" { return io_errorf("cannot build the variant path") }
	if os.exists(ndir) {
		return analysis_errorf(
			"variants/%s exists without a manifest entry — remove the directory and retry", name)
	}
	if mkerr := os.mkdir(ndir); mkerr != nil { return io_errorf("cannot create %s", ndir) }
	if serr := moli.save_qdct(variant_an, pjoin({ndir, "dict.qdct"}, a), a); serr != nil {
		return analysis_errorf("qdct save failed: %s", serr)
	}
	if werr := os.write_entire_file(pjoin({ndir, "entries.tsv"}, a), data); werr != nil {
		return io_errorf("cannot copy the entries file into the project")
	}

	// pre-flight: every source text must still match its record —
	// past this point the variant store starts filling
	texts := make([]string, len(m.docs), a)
	for d, i in m.docs {
		text, tcode := text_for_doc(dir, d, a)
		if tcode != 0 { return tcode }
		texts[i] = text
	}

	// base store: unknown_before evidence via decode
	base_store, base_ds, serr := gl.store_disk(pjoin({dir, "store"}, a),
		ma.payload_resolver, base.an, base.hash, 0, a)
	if serr != .None { return analysis_errorf("base store open failed: %v", serr) }
	defer discard_err(gl.disk_store_close(base_ds))

	// the variant rides the base's scratch — the base is idle from
	// here, and eng_analyze resets between documents anyway
	variant_eng := eng_wrap(variant_an, vhash, base.scratch)
	variant_store, variant_ds, vserr := gl.store_disk(pjoin({ndir, "store"}, a),
		ma.payload_resolver, variant_an, vhash, 0, a)
	if vserr != .None { return analysis_errorf("variant store open failed: %v", vserr) }
	defer discard_err(gl.disk_store_close(variant_ds))

	unk_before: map[string]int = make(map[string]int, a)
	tokens_before, tokens_after := 0, 0
	unk_before_total, unk_after_total := 0, 0
	gained: map[string]int = make(map[string]int, a)
	for d, i in m.docs {
		id := gl.Doc_Id(d.id)
		btoks, terr := base_store.tokens(base_store.ctx, id, a)
		if terr != .None {
			return analysis_errorf("base store read doc %d: %v", d.id, terr)
		}
		tokens_before += len(btoks)
		for bt in btoks {
			if bt.kind == .Unknown {
				unk_before_total += 1
				unk_before[bt.surface] += 1
			}
		}
		vtoks, vsegs, acode := eng_analyze(&variant_eng, texts[i], id, a)
		if acode != 0 { return acode }
		if serr2 := variant_store.add_document(variant_store.ctx, id, texts[i], vtoks, vsegs); serr2 != .None {
			if serr2 == .Duplicate {
				return analysis_errorf(
					"variant store refused doc %d (duplicate) — remove variants/%s and retry",
					d.id, name)
			}
			return analysis_errorf("variant store refused doc %d: %v", d.id, serr2)
		}
		tokens_after += len(vtoks)
		for vt in vtoks {
			if vt.kind == .Unknown {
				unk_after_total += 1
			} else if _, was := unk_before[vt.surface]; was {
				gained[vt.surface] += 1
			}
		}
		if !g.quiet { fmt.eprintf("re-tokenized doc %d\n", d.id) }
	}

	// corpus metadata is dictionary-independent, and so is every graph
	// row: spans are byte ranges, and the re-tokenization above
	// preserved doc ids and texts, so evidence survives it too
	if rcode := replay_graph_rows(base_ds, variant_ds, a); rcode != 0 { return rcode }

	new_variants: [dynamic]Variant_Row = make([dynamic]Variant_Row, 0, len(m.variants) + 1, a)
	for r in m.variants { append(&new_variants, r) }
	append(&new_variants, Variant_Row{
		name = clone_str(name, a),
		entries = pjoin({"variants", name, "entries.tsv"}, a),
		sha256 = sha_hex(data, a),
		dict_hash = vhash,
	})
	m.variants = new_variants[:]
	if scode := manifest_save(dir, &m, a); scode != 0 { return scode }

	gains: [dynamic]Gain = make([dynamic]Gain, 0, len(gained), a)
	for s, n in gained { append(&gains, Gain{surface = s, count = n}) }
	gl.sort_with_buffer(gains[:], gain_less, a)
	gains_top := gains[:]
	if len(gains) > GAINS_TOP { gains_top = gains[:GAINS_TOP] }

	b := strings.builder_make(a)
	strings.write_string(&b, "[{\"docs\":")
	fmt.sbprintf(&b, "%d", len(m.docs))
	strings.write_string(&b, ",\"tokens_before\":")
	fmt.sbprintf(&b, "%d", tokens_before)
	strings.write_string(&b, ",\"tokens_after\":")
	fmt.sbprintf(&b, "%d", tokens_after)
	strings.write_string(&b, ",\"unknown_before\":")
	fmt.sbprintf(&b, "%d", unk_before_total)
	strings.write_string(&b, ",\"unknown_after\":")
	fmt.sbprintf(&b, "%d", unk_after_total)
	strings.write_string(&b, ",\"top_surfaces_gained\":[")
	for gn, i in gains_top {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"surface\":")
		glexport.json_esc(gn.surface, &b)
		strings.write_string(&b, ",\"count\":")
		fmt.sbprintf(&b, "%d", gn.count)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]}]")
	emit_envelope("variant", vhash, name, false, strings.to_string(b), a)
	return EXIT_OK
}

variant_list :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) != 0 { return usage_errorf("variant list takes no arguments") }
	a := context.allocator
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }

	rows: [dynamic]string = make([dynamic]string, 0, len(m.variants), a)
	for r in m.variants {
		b := strings.builder_make(a)
		strings.write_string(&b, "{\"name\":")
		glexport.json_esc(r.name, &b)
		strings.write_string(&b, ",\"hash\":\"")
		fmt.sbprintf(&b, "%016x", r.dict_hash)
		strings.write_string(&b, "\",\"entries\":")
		glexport.json_esc(r.entries, &b)
		strings.write_string(&b, ",\"sha256\":")
		glexport.json_esc(r.sha256, &b)
		strings.write_string(&b, "}")
		append(&rows, strings.to_string(b))
	}
	emit_envelope("variant", m.dict_hash, "", false, join_rows(rows[:], a), a)
	return EXIT_OK
}

variant_remove :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	if len(rest) != 1 { return usage_errorf("variant remove <name>") }
	name := rest[0]
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }
	ix, ok := find_variant(&m, name)
	if !ok { return io_errorf("unknown variant %s", name) }
	target := pjoin({dir, "variants", name}, a)
	if target != "" && os.exists(target) {
		if rerr := os.remove_all(target); rerr != nil {
			return io_errorf("cannot remove %s", target)
		}
	}
	kept: [dynamic]Variant_Row = make([dynamic]Variant_Row, 0, len(m.variants), a)
	for r, i in m.variants {
		if i != ix { append(&kept, r) }
	}
	m.variants = kept[:]
	if rcode := manifest_save(dir, &m, a); rcode != 0 { return rcode }

	b := strings.builder_make(a)
	strings.write_string(&b, "[{\"removed\":")
	glexport.json_esc(name, &b)
	strings.write_string(&b, "}]")
	emit_envelope("variant", m.dict_hash, "", false, strings.to_string(b), a)
	return EXIT_OK
}

// what variant_diff needs from each side: where its store lives and
// what to call it — the dictionary state itself loads through Eng
Diff_Side :: struct {
	name:      string,
	store_dir: string,
}

resolve_side :: proc(m: ^Manifest, dir: string, name: string,
                     a: mem.Allocator) -> (Diff_Side, int) {
	if name == "base" {
		return {name = "base", store_dir = pjoin({dir, "store"}, a)}, 0
	}
	ix, ok := find_variant(m, name)
	if !ok { return {}, io_errorf("unknown variant %s (or the literal 'base')", name) }
	v := m.variants[ix]
	return {name = v.name, store_dir = pjoin({dir, "variants", v.name, "store"}, a)}, 0
}

Shift :: struct {
	key:   string,
	ca:    int,
	cb:    int,
	delta: int,
}

shift_less :: proc(x, y: ^Shift) -> bool {
	ax, ay := abs(x.delta), abs(y.delta)
	if ax != ay { return ax > ay }
	return strings.compare(x.key, y.key) < 0
}

variant_diff :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	side_a, side_b := "", ""
	top := 20
	fs := Filter_Spec{pos_prefixes = make([dynamic]string, 0, 4, a)}
	for i := 0; i < len(rest); i += 1 {
		code := parse_filter_flags(rest, &i, &fs, a)
		if code == -1 {
			arg := rest[i]
			if arg == "--top" {
				v, ok := flag_int(rest, &i, "--top", 1)
				if !ok { return EXIT_USAGE }
				top = v
			} else if strings.starts_with(arg, "--") {
				return unknown_flag_errorf("variant diff", arg)
			} else if side_a == "" {
				side_a = arg
			} else if side_b == "" {
				side_b = arg
			} else {
				return usage_errorf("variant diff <a> <b>")
			}
		} else if code != 0 {
			return code
		}
	}
	if side_a == "" || side_b == "" {
		return usage_errorf("variant diff <a> <b> — each is a variant name or 'base'")
	}

	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }
	sa, sacode := resolve_side(&m, dir, side_a, a)
	if sacode != 0 { return sacode }
	sb, sbcode := resolve_side(&m, dir, side_b, a)
	if sbcode != 0 { return sbcode }

	// both states live at once: two analyzers, two stores
	trow_a := Variant_Row{name = sa.name}
	eng_a, eacode := eng_load(dir, &m, sa.name != "base" ? &trow_a : nil, a)
	if eacode != 0 { return eacode }
	defer eng_destroy(&eng_a, a)
	trow_b := Variant_Row{name = sb.name}
	eng_b, ebcode := eng_load(dir, &m, sb.name != "base" ? &trow_b : nil, a)
	if ebcode != 0 { return ebcode }
	defer eng_destroy(&eng_b, a)
	st_a, ds_a, serr := gl.store_disk(sa.store_dir,
		resolver_for(&eng_a), resolver_ctx(&eng_a), eng_a.hash, 0, a)
	if serr != .None { return analysis_errorf("store open (%s) failed: %v", sa.name, serr) }
	defer discard_err(gl.disk_store_close(ds_a))
	st_b, ds_b, sberr := gl.store_disk(sb.store_dir,
		resolver_for(&eng_b), resolver_ctx(&eng_b), eng_b.hash, 0, a)
	if sberr != .None { return analysis_errorf("store open (%s) failed: %v", sb.name, sberr) }
	defer discard_err(gl.disk_store_close(ds_b))

	ids, icode := doc_ids(&m, "", a)
	if icode != 0 { return icode }

	// totals: the zero-filter count is the token population per side
	tokens_a, tacode := token_population(st_a, ids, sa.name, a)
	if tacode != 0 { return tacode }
	tokens_b, tbcode := token_population(st_b, ids, sb.name, a)
	if tbcode != 0 { return tbcode }

	unk_a, unk_b := 0, 0
	for id in ids {
		toks_a, aerr := st_a.tokens(st_a.ctx, id, a)
		if aerr != .None { return analysis_errorf("store read (%s) doc %d: %v", sa.name, u32(id), aerr) }
		for t in toks_a {
			if t.kind == .Unknown { unk_a += 1 }
		}
		toks_b, berr := st_b.tokens(st_b.ctx, id, a)
		if berr != .None { return analysis_errorf("store read (%s) doc %d: %v", sb.name, u32(id), berr) }
		for t in toks_b {
			if t.kind == .Unknown { unk_b += 1 }
		}
	}

	fa, faerr := gl.corpus_freq(st_a, ids, build_filter(&fs), a)
	if faerr != .None { return analysis_errorf("corpus_freq (%s): %v", sa.name, faerr) }
	fb, fberr := gl.corpus_freq(st_b, ids, build_filter(&fs), a)
	if fberr != .None { return analysis_errorf("corpus_freq (%s): %v", sb.name, fberr) }
	ca: map[string]int = make(map[string]int, a)
	for e in fa { ca[e.lemma] = e.count }
	cb: map[string]int = make(map[string]int, a)
	for e in fb { cb[e.lemma] = e.count }
	un: map[string]bool = make(map[string]bool, a)
	for k in ca { un[k] = true }
	for k in cb { un[k] = true }

	shifts: [dynamic]Shift = make([dynamic]Shift, 0, len(un), a)
	for k in un {
		xa, _ := ca[k]
		xb, _ := cb[k]
		append(&shifts, Shift{key = k, ca = xa, cb = xb, delta = xb - xa})
	}
	gl.sort_with_buffer(shifts[:], shift_less, a)
	top_shifts := shifts[:]
	if len(shifts) > top { top_shifts = shifts[:top] }

	rate_a := tokens_a > 0 ? f64(unk_a) / f64(tokens_a) : 0.0
	rate_b := tokens_b > 0 ? f64(unk_b) / f64(tokens_b) : 0.0

	b := strings.builder_make(a)
	strings.write_string(&b, "[{\"docs\":")
	fmt.sbprintf(&b, "%d", len(ids))
	strings.write_string(&b, ",\"hash_a\":\"")
	fmt.sbprintf(&b, "%016x", eng_a.hash)
	strings.write_string(&b, "\",\"hash_b\":\"")
	fmt.sbprintf(&b, "%016x", eng_b.hash)
	strings.write_string(&b, "\",\"tokens_a\":")
	fmt.sbprintf(&b, "%d", tokens_a)
	strings.write_string(&b, ",\"tokens_b\":")
	fmt.sbprintf(&b, "%d", tokens_b)
	strings.write_string(&b, ",\"unknown_rate_a\":")
	fmt.sbprintf(&b, "%.4f", rate_a)
	strings.write_string(&b, ",\"unknown_rate_b\":")
	fmt.sbprintf(&b, "%.4f", rate_b)
	strings.write_string(&b, ",\"top_shifts\":[")
	for s, i in top_shifts {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"key\":")
		glexport.json_esc(s.key, &b)
		fmt.sbprintf(&b, ",\"a\":%d,\"b\":%d,\"delta\":%d}", s.ca, s.cb, s.delta)
	}
	strings.write_string(&b, "]}]")
	emit_envelope("variant", eng_b.hash, "", false, strings.to_string(b), a)
	return EXIT_OK
}
