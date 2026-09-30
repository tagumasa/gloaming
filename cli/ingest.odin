package main

/*
Corpus ingestion and the project lifecycle: the analyzer wrapper
every command tokenizes through (moli or the fixture), the .md
collector (recursive, hidden entries skipped, the CLI's own
store/variants directories never ingested, deterministic path
order), and init/status/docs/add/remove. Ingestion is ATX-markdown
only — per-corpus shaping is staging done before init, recorded in
the corpus SOURCE.txt, never a CLI loader.
*/

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"
import moli "moli:moli"
import mv "core:mem/virtual"
import ma "gladapter:moli_adapter"

// one loaded dictionary state: the analyzer (or the fixture), its
// dictionary_hash (0 for the id-less schema), and the reusable Viterbi
// scratch arena the adapter's sizing rule asks for — free_all between
// documents, destroyed with the Eng. The scratch is the growing
// virtual arena: no size commitment up front, commit on demand.
Eng :: struct {
	kind:    Lang_Kind,
	an:      ^moli.Analyzer,
	hash:    u64,
	owned:   bool,
	scratch: ^mv.Arena,
}

new_scratch :: proc(a: mem.Allocator) -> ^mv.Arena {
	ar := new(mv.Arena, a)
	if mv.arena_init_growing(ar) != .None {
		free(ar, a)
		return nil
	}
	return ar
}

resolver_for :: proc(e: ^Eng) -> gl.Payload_Resolver {
	if e.kind == .Moli { return ma.payload_resolver }
	return fixture_resolve
}

resolver_ctx :: proc(e: ^Eng) -> rawptr {
	if e.kind == .Moli { return e.an }
	return nil
}

// the serving state for reads: qdct restore through the adapter (the
// CSV import path is init's business only)
eng_load :: proc(dir: string, m: ^Manifest, v: ^Variant_Row,
                 a: mem.Allocator) -> (Eng, int) {
	if m.kind == .Fixture {
		sc := new_scratch(a)
		if sc == nil { return Eng{}, io_errorf("scratch arena init failed") }
		return Eng{kind = .Fixture, scratch = sc}, 0
	}
	qdct := pjoin({dir, "dict.qdct"}, a)
	if v != nil { qdct = pjoin({dir, "variants", v.name, "dict.qdct"}, a) }
	if qdct == "" || !os.exists(qdct) {
		return Eng{}, io_errorf("dictionary snapshot missing: %s", qdct)
	}
	lang, _, _ := lang_of(m.lang)
	an := new(moli.Analyzer, a)
	loaded, lerr := ma.load_analyzer(qdct, "", lang, {}, a)
	if lerr != nil {
		return Eng{}, io_errorf("dictionary load failed: %s",
			moli.load_error_message(lerr, a))
	}
	an^ = loaded
	h, herr := ma.dictionary_hash(an)
	if herr != nil {
		return Eng{}, io_errorf("dictionary hash failed: %s", herr)
	}
	sc := new_scratch(a)
	if sc == nil { return Eng{}, io_errorf("scratch arena init failed") }
	return Eng{kind = .Moli, an = an, hash = h, owned = true,
		scratch = sc}, 0
}

// a borrowed analyzer (variant add's clone — freed by its owner)
eng_wrap :: proc(an: ^moli.Analyzer, hash: u64, scratch: ^mv.Arena) -> Eng {
	return Eng{kind = .Moli, an = an, hash = hash, owned = false, scratch = scratch}
}

eng_destroy :: proc(e: ^Eng, a: mem.Allocator) {
	if e.owned && e.an != nil {
		moli.free(e.an)
		free(e.an, a)
	}
	if e.scratch != nil {
		mv.arena_destroy(e.scratch)
		free(e.scratch, a)
	}
}

// tokenize + outline one document onto the scratch arena; the results
// are valid until the next eng_analyze on the same Eng
eng_analyze :: proc(e: ^Eng, text: string, doc: gl.Doc_Id,
                    a: mem.Allocator) -> (toks: []gl.Token, segs: []gl.Segment, code: int) {
	mv.arena_free_all(e.scratch)
	ta := mv.arena_allocator(e.scratch)
	out: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 64, ta)
	sout: [dynamic]gl.Segment = make([dynamic]gl.Segment, 0, 16, ta)
	if e.kind == .Moli {
		terr := ma.tokenize_document(e.an, text, {}, 0, &out, ta)
		if terr != nil {
			return nil, nil, analysis_errorf("tokenize failed: %s",
				moli.tokenize_error_message(terr, a))
		}
	} else {
		fixture_tokenize(text, &out)
	}
	ma.markdown_segments(text, 0, doc, &sout)
	return out[:], sout[:], 0
}

// ---- the .md collector ----

collect_dir :: proc(dir: string, files: ^[dynamic]string, a: mem.Allocator) -> int {
	fis, err := os.read_all_directory_by_path(dir, a)
	if err != nil { return io_errorf("cannot read directory %s", dir) }
	for fi in fis {
		if strings.starts_with(fi.name, ".") { continue }
		#partial switch fi.type {
		case .Directory:
			// a project materialized under the corpus root would ingest
			// its own store — the CLI's directory names are not corpus
			if fi.name == "store" || fi.name == "variants" { continue }
			if code := collect_dir(fi.fullpath, files, a); code != 0 { return code }
		case .Regular:
			if strings.has_suffix(fi.name, ".md") { append(files, fi.fullpath) }
		}
	}
	return 0
}

collect_paths :: proc(roots: []string, a: mem.Allocator) -> ([]string, int) {
	files: [dynamic]string = make([dynamic]string, 0, 8, a)
	for r in roots {
		fi, err := os.stat(r, a)
		if err != nil { return nil, io_errorf("cannot stat %s", r) }
		#partial switch fi.type {
		case .Directory:
			if code := collect_dir(r, &files, a); code != 0 { return nil, code }
		case .Regular:
			if !strings.has_suffix(r, ".md") {
				return nil, io_errorf("not a .md file: %s", r)
			}
			append(&files, r)
		case:
			return nil, io_errorf("not a file or directory: %s", r)
		}
	}
	if len(files) == 0 { return nil, 0 }
	gl.sort_with_buffer(files[:], str_less, a)
	// overlapping roots: adjacent dedup after the sort
	w := 0
	for f in files[:] {
		if w == 0 || files[w - 1] != f {
			files[w] = f
			w += 1
		}
	}
	return files[:w], 0
}

ingest_one :: proc(st: gl.Store, eng: ^Eng, doc: gl.Doc_Id, path: string,
                   a: mem.Allocator) -> (Doc_Row, int) {
	data, err := os.read_entire_file_from_path(path, a)
	if err != nil { return {}, io_errorf("cannot read %s", path) }
	text := transmute(string)data
	toks, segs, code := eng_analyze(eng, text, doc, a)
	if code != 0 { return {}, code }
	if serr := st.add_document(st.ctx, doc, text, toks, segs); serr != .None {
		return {}, analysis_errorf("store refused %s: %v", path, serr)
	}
	return Doc_Row{
		id = u32(doc),
		path = clone_str(path, a),
		bytes = len(text),
		tokens = len(toks),
		segments = len(segs),
		text_hash = hash.fnv64a(data),
	}, 0
}

// ---- commands ----

cmd_init :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	lang_s := ""
	dict := ""
	variant_of := ""
	roots: [dynamic]string = make([dynamic]string, 0, 4, a)
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		if arg == "--lang" {
			v, ok := flag_value(rest, &i, "--lang")
			if !ok { return EXIT_USAGE }
			lang_s = v
		} else if arg == "--dict" {
			v, ok := flag_value(rest, &i, "--dict")
			if !ok { return EXIT_USAGE }
			dict = v
		} else if arg == "--variant-of" {
			v, ok := flag_value(rest, &i, "--variant-of")
			if !ok { return EXIT_USAGE }
			variant_of = v
		} else if strings.starts_with(arg, "--") {
			return unknown_flag_errorf("init", arg)
		} else {
			append(&roots, arg)
		}
	}
	if lang_s == "" { return usage_errorf("init: --lang required") }
	lang, kind, lok := lang_of(lang_s)
	if !lok {
		return usage_errorf("init: unknown lang %s (%s)", lang_s, vocab_menu(Lang_Spec, LANGS[:]))
	}
	if len(roots) == 0 { return usage_errorf("init: at least one corpus file or directory") }
	if variant_of != "" && dict != "" {
		return usage_errorf("init: --variant-of and --dict are exclusive — the promoted dictionary is the dictionary")
	}
	dict_origin := clone_str(dict, a)
	if variant_of != "" {
		// variant names cannot contain ':' (valid_variant_name), so
		// the last colon is the separator even if the path holds one
		cut := -1
		for c in 0..<len(variant_of) {
			if variant_of[c] == ':' { cut = c }
		}
		if cut <= 0 || cut == len(variant_of) - 1 {
			return usage_errorf("init: --variant-of expects <project>:<variant>")
		}
		src_dir, vname := variant_of[:cut], variant_of[cut + 1:]
		src_m, scode := manifest_load(src_dir, a)
		if scode != 0 { return scode }
		if src_m.lang != lang_s {
			return usage_errorf("init: --lang %s but the source project's lang is %s", lang_s, src_m.lang)
		}
		if src_m.kind == .Fixture {
			return usage_errorf("init: the source project has no dictionary to promote")
		}
		if _, ok := find_variant(&src_m, vname); !ok {
			return io_errorf("unknown variant %s in %s", vname, src_dir)
		}
		dict_origin = pjoin({src_dir, "variants", vname, "dict.qdct"}, a)
		if dict_origin == "" || !os.exists(dict_origin) {
			return io_errorf("variant dictionary missing: variants/%s/dict.qdct in %s", vname, src_dir)
		}
	}
	if kind == .Moli && dict == "" && variant_of == "" {
		return usage_errorf("init: --dict <csv> required for %s", lang_s)
	}

	cwd, werr := os.get_working_directory(a)
	if werr != nil { return io_errorf("cannot read the working directory") }
	// --project names where the project materializes; the cwd is the
	// default, and the manifest-exists guard below moves with it
	root := cwd
	if g.project != "" {
		root = g.project
		if !os.exists(root) {
			if mkerr := os.mkdir(root); mkerr != nil { return io_errorf("cannot create %s", root) }
		}
	}
	if os.exists(pjoin({root, MANIFEST_NAME}, a)) {
		return io_errorf("%s already holds a manifest.json — init elsewhere or remove the project", root)
	}
	if variant_of != "" {
		// promote: the variant's snapshot becomes this project's
		// base dictionary — the entries are already folded into it,
		// and load_analyzer's restore path takes it from here
		qdata, qerr := os.read_entire_file_from_path(dict_origin, a)
		if qerr != nil { return io_errorf("cannot read %s", dict_origin) }
		if werr2 := os.write_entire_file(pjoin({root, "dict.qdct"}, a), qdata); werr2 != nil {
			return io_errorf("cannot write the promoted dictionary snapshot")
		}
	}

	sc := new_scratch(a)
	if sc == nil { return io_errorf("scratch arena init failed") }
	eng := Eng{kind = kind, scratch = sc}
	if kind == .Moli {
		an := new(moli.Analyzer, a)
		loaded, lerr := ma.load_analyzer(pjoin({root, "dict.qdct"}, a), dict, lang, {}, a)
		if lerr != nil {
			return io_errorf("dictionary import failed: %s",
				moli.load_error_message(lerr, a))
		}
		an^ = loaded
		h, herr := ma.dictionary_hash(an)
		if herr != nil { return io_errorf("dictionary hash failed") }
		eng.an = an
		eng.owned = true
		eng.hash = h
	}
	defer eng_destroy(&eng, a)

	st, ds, serr := gl.store_disk(pjoin({root, "store"}, a),
		resolver_for(&eng), resolver_ctx(&eng), eng.hash, 0, a)
	if serr != .None { return analysis_errorf("store open failed: %v", serr) }
	defer discard_err(gl.disk_store_close(ds))

	files, code := collect_paths(roots[:], a)
	if code != 0 { return code }
	if len(files) == 0 { return io_errorf("no .md files under the given roots") }

	docs: [dynamic]Doc_Row = make([dynamic]Doc_Row, 0, len(files), a)
	for f, i in files {
		row, icode := ingest_one(st, &eng, gl.Doc_Id(i), f, a)
		if icode != 0 { return icode }
		append(&docs, row)
		if !g.quiet { fmt.eprintf("ingested %s\n", f) }
	}

	entries := 0
	if kind == .Moli {
		if s2, serr2 := moli.stats(eng.an); serr2 == nil { entries = int(s2.entries) }
	}

	m := Manifest{
		lang = lang_s,
		kind = kind,
		dict_path = dict_origin,
		dict_hash = eng.hash,
		dict_entries = entries,
		docs = docs[:],
		variants = make([]Variant_Row, 0, a),
	}
	if mcode := manifest_save(root, &m, a); mcode != 0 { return mcode }

	total_bytes, total_toks, total_segs := 0, 0, 0
	for d in m.docs {
		total_bytes += d.bytes
		total_toks += d.tokens
		total_segs += d.segments
	}
	b := strings.builder_make(a)
	strings.write_string(&b, "[{\"docs\":")
	fmt.sbprintf(&b, "%d", len(m.docs))
	strings.write_string(&b, ",\"bytes\":")
	fmt.sbprintf(&b, "%d", total_bytes)
	strings.write_string(&b, ",\"tokens\":")
	fmt.sbprintf(&b, "%d", total_toks)
	strings.write_string(&b, ",\"segments\":")
	fmt.sbprintf(&b, "%d", total_segs)
	strings.write_string(&b, ",\"entries\":")
	fmt.sbprintf(&b, "%d", entries)
	strings.write_string(&b, "}]")
	emit_envelope("init", eng.hash, "", false, strings.to_string(b), a)
	return EXIT_OK
}

// 0 when the path is missing or unstattable — the size fields are a
// footprint hint, not an invariant to fail a read on
file_size_of :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil { return 0 }
	return fi.size
}

cmd_status :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) != 0 { return usage_errorf("status takes no arguments") }
	if g.variant != "" {
		return base_state_errorf("status reads the project record", "")
	}
	a := context.allocator
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }

	toks, bytes := 0, 0
	for d in m.docs {
		toks += d.tokens
		bytes += d.bytes
	}
	b := strings.builder_make(a)
	strings.write_string(&b, "[{\"lang\":")
	glexport.json_esc(m.lang, &b)
	strings.write_string(&b, ",\"docs\":")
	fmt.sbprintf(&b, "%d", len(m.docs))
	strings.write_string(&b, ",\"tokens\":")
	fmt.sbprintf(&b, "%d", toks)
	strings.write_string(&b, ",\"bytes\":")
	fmt.sbprintf(&b, "%d", bytes)
	strings.write_string(&b, ",\"entries\":")
	fmt.sbprintf(&b, "%d", m.dict_entries)
	strings.write_string(&b, ",\"variants\":[")
	for r, i in m.variants {
		if i > 0 { strings.write_string(&b, ",") }
		glexport.json_esc(r.name, &b)
	}
	strings.write_string(&b, "],\"store_registry_bytes\":")
	fmt.sbprintf(&b, "%d", file_size_of(pjoin({dir, "store", "registry.glr"}, a)))
	strings.write_string(&b, ",\"store_payloads_bytes\":")
	fmt.sbprintf(&b, "%d", file_size_of(pjoin({dir, "store", "payloads.glb"}, a)))
	strings.write_string(&b, "}]")
	emit_envelope("status", m.dict_hash, "", false, strings.to_string(b), a)
	return EXIT_OK
}

cmd_docs :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) != 0 { return usage_errorf("docs takes no arguments") }
	if g.variant != "" {
		return base_state_errorf("docs reads the base tokenization", "")
	}
	a := context.allocator
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }

	rows: [dynamic]string = make([dynamic]string, 0, len(m.docs), a)
	for d in m.docs {
		append(&rows, doc_row_json(d, true, a))
	}
	emit_envelope("docs", m.dict_hash, "", false, join_rows(rows[:], a), a)
	return EXIT_OK
}

cmd_add :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	if len(rest) == 0 { return usage_errorf("add: at least one file or directory") }
	if g.variant != "" {
		return base_state_errorf("add targets the base state", " (variants are frozen records)")
	}
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }

	files, fcode := collect_paths(rest, a)
	if fcode != 0 { return fcode }
	if len(files) == 0 { return io_errorf("no .md files among the arguments") }
	for f in files {
		for d in m.docs {
			if d.path == f {
				return analysis_errorf("already ingested: %s (doc %d)", f, d.id)
			}
		}
	}

	eng, ecode := eng_load(dir, &m, nil, a)
	if ecode != 0 { return ecode }
	defer eng_destroy(&eng, a)
	st, ds, serr := gl.store_disk(pjoin({dir, "store"}, a),
		resolver_for(&eng), resolver_ctx(&eng), eng.hash, 0, a)
	if serr != .None { return analysis_errorf("store open failed: %v", serr) }
	defer discard_err(gl.disk_store_close(ds))

	// next id never reuses one, even a live store id an older manifest
	// never recorded (a crash between a store add and its manifest row)
	next := u32(0)
	for d in m.docs {
		if d.id >= next { next = d.id + 1 }
	}
	for id in st.docs(st.ctx) {
		if u32(id) >= next { next = u32(id) + 1 }
	}

	docs: [dynamic]Doc_Row = make([dynamic]Doc_Row, 0, len(m.docs) + len(files), a)
	for d in m.docs { append(&docs, d) }
	rows: [dynamic]string = make([dynamic]string, 0, len(files), a)
	for f in files {
		row, icode := ingest_one(st, &eng, gl.Doc_Id(next), f, a)
		if icode != 0 { return icode }
		append(&docs, row)
		next += 1
		if !g.quiet { fmt.eprintf("ingested %s\n", f) }
		append(&rows, doc_row_json(row, false, a))
		m.docs = docs[:]
		if acode := manifest_save(dir, &m, a); acode != 0 { return acode }
	}
	emit_envelope("add", eng.hash, "", false, join_rows(rows[:], a), a)
	return EXIT_OK
}

cmd_remove :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	if len(rest) != 1 { return usage_errorf("remove: exactly one document (id or path suffix)") }
	if g.variant != "" {
		return base_state_errorf("remove targets the base state", "")
	}
	dir, code := discover_project(g, a)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, a)
	if mcode != 0 { return mcode }
	id, dcode := resolve_doc(rest[0], &m)
	if dcode != 0 { return dcode }
	row, ok := doc_row(&m, id)
	if !ok { return analysis_errorf("no document %d in the manifest", u32(id)) }

	// registry-only mutation: no payload decodes, so no dictionary load
	st, ds, serr := gl.store_disk(pjoin({dir, "store"}, a),
		fixture_resolve, nil, m.dict_hash, 0, a)
	if serr != .None { return analysis_errorf("store open failed: %v", serr) }
	defer discard_err(gl.disk_store_close(ds))
	if rerr := st.remove_document(st.ctx, id); rerr != .None {
		return analysis_errorf("store refused removal of doc %d: %v", u32(id), rerr)
	}

	kept: [dynamic]Doc_Row = make([dynamic]Doc_Row, 0, len(m.docs), a)
	for d in m.docs {
		if d.id != u32(id) { append(&kept, d) }
	}
	m.docs = kept[:]
	if rcode := manifest_save(dir, &m, a); rcode != 0 { return rcode }

	b := strings.builder_make(a)
	strings.write_string(&b, "[{\"removed\":")
	fmt.sbprintf(&b, "%d", u32(id))
	strings.write_string(&b, ",\"path\":")
	glexport.json_esc(row.path, &b)
	strings.write_string(&b, "}]")
	emit_envelope("remove", m.dict_hash, "", false, strings.to_string(b), a)
	return EXIT_OK
}

// the close-error sink for deferred teardown: disk_store_close only
// releases the two file handles (writes go straight through
// write_at), so on these one-shot paths its error carries nothing
// worth an exit code
discard_err :: proc(_: gl.Store_Err) {}

// flag_value + parse_int flag helper pair shared by every command
flag_value :: proc(args: []string, i: ^int, name: string) -> (string, bool) {
	if i^ + 1 >= len(args) {
		_ = usage_errorf("%s needs a value", name)
		return "", false
	}
	i^ += 1
	return args[i^], true
}

flag_int :: proc(args: []string, i: ^int, name: string, min: int) -> (int, bool) {
	v, ok := flag_value(args, i, name)
	if !ok { return 0, false }
	n, pok := strconv.parse_int(v, 10)
	if !pok || n < min {
		_ = usage_errorf("bad %s value %s", name, v)
		return 0, false
	}
	return n, true
}

// the float twin; `min` is exclusive — a tolerance passes 0 for
// strictly-positive. Non-finite values refuse: NaN fails every
// comparison and +Inf passes any finite floor, so the range check
// cannot see either — `f - f != 0` is the finiteness gate (only a
// non-finite value differs from itself, the library's rule)
flag_float :: proc(args: []string, i: ^int, name: string, min: f64) -> (f64, bool) {
	v, ok := flag_value(args, i, name)
	if !ok { return 0, false }
	f, pok := strconv.parse_f64(v)
	if !pok || f <= min || f - f != 0 {
		_ = usage_errorf("bad %s value %s", name, v)
		return 0, false
	}
	return f, true
}
