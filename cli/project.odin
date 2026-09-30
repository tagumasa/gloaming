package main

/*
The project directory's manifest: schema-1 JSON, hand-written and
hand-read. The writer's
field order is the canonical one; the reader accepts that shape
through core:encoding/json. Doc paths are recorded as given at
ingestion — init materializes the project in --project's directory
when given (else the cwd), so they are
project-relative by construction — and reads try project-relative
first, then as-given. Each doc row carries the fnv64a of the text it
was ingested from (the store's own Payload_Key.text_hash formula), so
a host that re-reads a corpus file refuses silently-sliced spans when
the file drifted: the host owns the text, the hash owns its identity.
*/

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

MANIFEST_NAME :: "manifest.json"
CLI_VERSION    :: "0.1.0"

Lang_Kind :: enum {
	Moli,    // analyzer languages: ja, zh-*, de
	Fixture, // id-less schema: en-* ride the CLI's fixture tokenizer
}

Doc_Row :: struct {
	id:        u32,
	path:      string,
	bytes:     int,
	tokens:    int,
	segments:  int,
	text_hash: u64, // fnv64a of the ingested text — Payload_Key's formula; JSON key "thash"
}

Variant_Row :: struct {
	name:      string,
	entries:   string, // project-relative path of the copied TSV
	sha256:    string,
	dict_hash: u64,
}

Manifest :: struct {
	lang:         string,
	kind:         Lang_Kind,
	dict_path:    string,
	dict_hash:    u64,
	dict_entries: int,
	docs:         []Doc_Row,
	variants:     []Variant_Row,
}

// path join that reports failure as "" — every caller treats that as
// an IO refusal; os.join_path's error carries nothing more
pjoin :: proc(parts: []string, a: mem.Allocator) -> string {
	s, err := os.join_path(parts, a)
	if err != nil { return "" }
	return s
}

// the split-side mirror of os.join_path: core:os exposes no public
// separator constant, and the parent walk below needs to cut paths, not
// build them
when ODIN_OS == .Windows {
	PATH_SEP :: 0x5C // '\'
} else {
	PATH_SEP :: 0x2F // '/'
}

// the nearest ancestor (or the cwd itself) holding manifest.json;
// --project short-circuits the walk
discover_project :: proc(g: ^Globals, a: mem.Allocator) -> (string, int) {
	root := g.project
	if root == "" {
		wd, werr := os.get_working_directory(a)
		if werr != nil { return "", io_errorf("cannot read the working directory") }
		root = wd
	}
	dir := root
	for {
		probe := pjoin({dir, MANIFEST_NAME}, context.temp_allocator)
		if probe != "" && os.exists(probe) { return dir, 0 }
		// the lexical parent: strip the last component. Joining ".."
		// instead never shortens the string, so a dir == "/" exit is
		// unreachable — on a tree with no manifest anywhere the walk
		// would loop forever, its probe strings growing without bound
		parent := dir
		for len(parent) > 0 && parent[len(parent) - 1] != PATH_SEP {
			parent = parent[:len(parent) - 1]
		}
		if len(parent) > 1 { parent = parent[:len(parent) - 1] }
		if parent == "" { parent = "." }
		if parent == dir { break }
		dir = parent
	}
	return "", io_errorf("no project found — run inside one or pass --project (walked up from %s)", root)
}

manifest_load :: proc(dir: string, a: mem.Allocator) -> (Manifest, int) {
	m := Manifest{}
	path := pjoin({dir, MANIFEST_NAME}, a)
	data, rerr := os.read_entire_file_from_path(path, a)
	if rerr != nil { return m, io_errorf("cannot read %s", path) }
	v, jerr := json.parse_string(transmute(string)data, json.DEFAULT_SPECIFICATION, true, a)
	if jerr != .None {
		return m, io_errorf("corrupt manifest (%s): %v", path, jerr)
	}

	schema := 0
	_ = jfield_int(v, "schema", &schema)
	if schema != 1 {
		return m, io_errorf("manifest schema %d unsupported (this CLI writes schema 1)", schema)
	}
	_ = jfield_str(v, "lang", &m.lang)
	if m.lang == "" { return m, io_errorf("corrupt manifest: no lang") }

	dv, has_dict := jget(v, "dict")
	if has_dict {
		kind_s := ""
		_ = jfield_str(dv, "kind", &kind_s)
		m.kind = kind_s == "moli" ? .Moli : .Fixture
		_ = jfield_str(dv, "path", &m.dict_path)
		_ = jfield_hex(dv, "hash", &m.dict_hash)
		_ = jfield_int(dv, "entries", &m.dict_entries)
	}

	docs: [dynamic]Doc_Row = make([dynamic]Doc_Row, 0, 8, a)
	if av, has_docs := jget(v, "docs"); has_docs {
		#partial switch arr in av {
		case json.Array:
			for ev in arr {
				if d, ok := parse_doc_row(ev); ok { append(&docs, d) }
			}
		}
	}
	m.docs = docs[:]

	vars: [dynamic]Variant_Row = make([dynamic]Variant_Row, 0, 2, a)
	if av, has_vars := jget(v, "variants"); has_vars {
		#partial switch arr in av {
		case json.Array:
			for ev in arr {
				if r, ok := parse_variant_row(ev); ok { append(&vars, r) }
			}
		}
	}
	m.variants = vars[:]
	return m, 0
}

parse_doc_row :: proc(ev: json.Value) -> (Doc_Row, bool) {
	d := Doc_Row{}
	id := 0
	if !jfield_int(ev, "id", &id) { return d, false }
	d.id = u32(id)
	if !jfield_str(ev, "path", &d.path) || d.path == "" { return d, false }
	n := 0
	if jfield_int(ev, "bytes", &n) { d.bytes = n }
	if jfield_int(ev, "tokens", &n) { d.tokens = n }
	if jfield_int(ev, "segments", &n) { d.segments = n }
	_ = jfield_hex(ev, "thash", &d.text_hash)
	return d, true
}

parse_variant_row :: proc(ev: json.Value) -> (Variant_Row, bool) {
	r := Variant_Row{}
	if !jfield_str(ev, "name", &r.name) || r.name == "" { return r, false }
	_ = jfield_str(ev, "entries", &r.entries)
	_ = jfield_str(ev, "sha256", &r.sha256)
	_ = jfield_hex(ev, "hash", &r.dict_hash)
	return r, true
}

// one line, canonical field order — the shape manifest_load reads
manifest_save :: proc(dir: string, m: ^Manifest, a: mem.Allocator) -> int {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"schema\":1,\"cli\":")
	glexport.json_esc(CLI_VERSION, &b)
	strings.write_string(&b, ",\"lang\":")
	glexport.json_esc(m.lang, &b)
	strings.write_string(&b, ",\"dict\":{\"kind\":")
	glexport.json_esc(m.kind == .Moli ? "moli" : "fixture", &b)
	strings.write_string(&b, ",\"path\":")
	glexport.json_esc(m.dict_path, &b)
	fmt.sbprintf(&b, ",\"hash\":\"%016x\",\"entries\":%d},\"docs\":[", m.dict_hash, m.dict_entries)
	for d, i in m.docs {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"id\":")
		fmt.sbprintf(&b, "%d", d.id)
		strings.write_string(&b, ",\"path\":")
		glexport.json_esc(d.path, &b)
		strings.write_string(&b, ",\"bytes\":")
		fmt.sbprintf(&b, "%d", d.bytes)
		strings.write_string(&b, ",\"tokens\":")
		fmt.sbprintf(&b, "%d", d.tokens)
		strings.write_string(&b, ",\"segments\":")
		fmt.sbprintf(&b, "%d", d.segments)
		strings.write_string(&b, ",\"thash\":\"")
		fmt.sbprintf(&b, "%016x", d.text_hash)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "],\"variants\":[")
	for r, i in m.variants {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"name\":")
		glexport.json_esc(r.name, &b)
		strings.write_string(&b, ",\"entries\":")
		glexport.json_esc(r.entries, &b)
		strings.write_string(&b, ",\"sha256\":")
		glexport.json_esc(r.sha256, &b)
		strings.write_string(&b, ",\"hash\":\"")
		fmt.sbprintf(&b, "%016x", r.dict_hash)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}\n")

	path := pjoin({dir, MANIFEST_NAME}, a)
	if path == "" { return io_errorf("cannot build the manifest path") }
	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); werr != nil {
		return io_errorf("cannot write %s", path)
	}
	return 0
}

// one manifest doc row as JSON — docs/status rows carry `bytes`;
// add's result rows omit it
doc_row_json :: proc(d: Doc_Row, with_bytes: bool, a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"id\":")
	fmt.sbprintf(&b, "%d", d.id)
	strings.write_string(&b, ",\"path\":")
	glexport.json_esc(d.path, &b)
	if with_bytes {
		strings.write_string(&b, ",\"bytes\":")
		fmt.sbprintf(&b, "%d", d.bytes)
	}
	strings.write_string(&b, ",\"tokens\":")
	fmt.sbprintf(&b, "%d", d.tokens)
	strings.write_string(&b, ",\"segments\":")
	fmt.sbprintf(&b, "%d", d.segments)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// ---- json.Value accessors (the manifest's fixed shapes); the string
// and integer views borrow the parse tree, which lives on the
// command's allocator for the whole one-shot process ----

jget :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	#partial switch o in v {
	case json.Object:
		x, ok := o[key]
		return x, ok
	}
	return {}, false
}

jstr :: proc(v: json.Value) -> (string, bool) {
	#partial switch s in v {
	case json.String: return s, true
	}
	return "", false
}

jint :: proc(v: json.Value) -> (i64, bool) {
	#partial switch n in v {
	case json.Integer: return n, true
	}
	return 0, false
}

jfield_str :: proc(v: json.Value, key: string, dst: ^string) -> bool {
	fv, has := jget(v, key)
	if !has { return false }
	s, ok := jstr(fv)
	if !ok { return false }
	dst^ = s
	return true
}

jfield_int :: proc(v: json.Value, key: string, dst: ^int) -> bool {
	fv, has := jget(v, key)
	if !has { return false }
	n, ok := jint(fv)
	if !ok { return false }
	dst^ = int(n)
	return true
}

jfield_hex :: proc(v: json.Value, key: string, dst: ^u64) -> bool {
	fv, has := jget(v, key)
	if !has { return false }
	s, ok := jstr(fv)
	if !ok { return false }
	u, pok := strconv.parse_u64(s, 16)
	if !pok { return false }
	dst^ = u
	return true
}

// ---- doc selection and text ownership ----

find_variant :: proc(m: ^Manifest, name: string) -> (int, bool) {
	for r, i in m.variants {
		if r.name == name { return i, true }
	}
	return -1, false
}

// "--doc D": a Doc_Id, or a path suffix unique over the manifest
resolve_doc :: proc(sel: string, m: ^Manifest) -> (gl.Doc_Id, int) {
	if n, ok := strconv.parse_int(sel, 10); ok && n >= 0 && n <= 0xFFFFFFFF {
		return gl.Doc_Id(n), 0
	}
	match := -1
	for d, i in m.docs {
		if strings.has_suffix(d.path, sel) {
			if match >= 0 {
				return 0, analysis_errorf("--doc %s is ambiguous (%s, %s)",
					sel, m.docs[match].path, d.path)
			}
			match = i
		}
	}
	if match < 0 { return 0, analysis_errorf("no document matches --doc %s", sel) }
	return gl.Doc_Id(m.docs[match].id), 0
}

doc_ids :: proc(m: ^Manifest, sel: string, a: mem.Allocator) -> ([]gl.Doc_Id, int) {
	if sel == "" {
		ids := make([]gl.Doc_Id, len(m.docs), a)
		for d, i in m.docs { ids[i] = gl.Doc_Id(d.id) }
		return ids, 0
	}
	id, code := resolve_doc(sel, m)
	if code != 0 { return {}, code }
	ids := make([]gl.Doc_Id, 1, a)
	ids[0] = id
	return ids, 0
}

doc_row :: proc(m: ^Manifest, id: gl.Doc_Id) -> (Doc_Row, bool) {
	for d in m.docs {
		if d.id == u32(id) { return d, true }
	}
	return {}, false
}

// the document text the host owns: project-relative first, then
// as-given; bytes and fnv64a must match the ingestion record
text_for_doc :: proc(dir: string, d: Doc_Row, a: mem.Allocator) -> (string, int) {
	candidates := [2]string{
		pjoin({dir, d.path}, context.temp_allocator),
		d.path,
	}
	data: []u8
	ok := false
	for c in candidates {
		if c == "" { continue }
		x, err := os.read_entire_file_from_path(c, a)
		if err == nil { data = x; ok = true; break }
	}
	if !ok { return "", io_errorf("corpus file unreadable: %s", d.path) }
	if len(data) != d.bytes || hash.fnv64a(data) != d.text_hash {
		return "", io_errorf(
			"corpus file changed since ingestion: %s — remove and re-add the document", d.path)
	}
	return transmute(string)data, 0
}

clone_str :: proc(s: string, a: mem.Allocator) -> string {
	out := make([]u8, len(s), a)
	copy(out, transmute([]u8)s)
	return transmute(string)out
}

/*
"<doc>:<start>-<end>" — one byte-range citation, the evidence
currency relations and mentions carry. The doc resolves like --doc
(decimal id or unique path suffix); start/end are decimal byte
offsets, because a Span is a byte range — checked against the current
text through text_for_doc's identity rule, so a drifted corpus file
refuses the citation instead of silently pointing nowhere.
*/
parse_span_spec :: proc(spec: string, dir: string, m: ^Manifest,
                        a: mem.Allocator) -> (gl.Span, int) {
	colon := strings.last_index(spec, ":")
	if colon <= 0 || colon == len(spec) - 1 {
		return {}, usage_errorf("span expects <doc>:<start>-<end>, got %s", spec)
	}
	rpart := spec[colon + 1:]
	dash := strings.index(rpart, "-")
	if dash <= 0 || dash == len(rpart) - 1 {
		return {}, usage_errorf("span expects <doc>:<start>-<end>, got %s", spec)
	}
	start, sok := strconv.parse_int(rpart[:dash], 10)
	end, eok := strconv.parse_int(rpart[dash + 1:], 10)
	if !sok || !eok || start < 0 || end <= start {
		return {}, usage_errorf("span expects decimal byte offsets with start < end, got %s", spec)
	}
	id, dcode := resolve_doc(spec[:colon], m)
	if dcode != 0 { return {}, dcode }
	row, dok := doc_row(m, id)
	if !dok { return {}, analysis_errorf("no document %d in the manifest", u32(id)) }
	text, tcode := text_for_doc(dir, row, a)
	if tcode != 0 { return {}, tcode }
	if end > len(text) {
		return {}, analysis_errorf("span %s: end %d runs past the text (%d bytes)",
			spec, end, len(text))
	}
	return gl.Span{doc = id, start = start, end = end}, 0
}

/*
Registry-only open for the graph-row commands (attr, entity,
relation, toposort): their rows live in the base store's record log,
so no dictionary load and no decode — the fixture resolver is passed
for the open signature but never routes one.
*/
open_registry_store :: proc(dir: string, m: ^Manifest,
                            a: mem.Allocator) -> (^gl.Disk_Store, int) {
	_, ds, serr := gl.store_disk(pjoin({dir, "store"}, a),
		fixture_resolve, nil, m.dict_hash, 0, a)
	if serr != .None {
		return nil, analysis_errorf("store open failed: %v", serr)
	}
	return ds, 0
}

/*
The graph-row read open: the same registry-only store, but the
SELECTED state's — the base log, or the variant's replayed copy.
Graph-row writes stay base-only (their --variant refusals); reads
follow the selected state like every analysis read. The returned hash
is the selected side's, for the envelope.
*/
open_graph_store :: proc(g: ^Globals, dir: string, m: ^Manifest,
                         a: mem.Allocator) -> (^gl.Disk_Store, u64, int) {
	store_dir := pjoin({dir, "store"}, a)
	dh := m.dict_hash
	if g.variant != "" {
		ix, ok := find_variant(m, g.variant)
		if !ok { return nil, 0, io_errorf("unknown variant %s", g.variant) }
		vrow := &m.variants[ix]
		store_dir = pjoin({dir, "variants", vrow.name, "store"}, a)
		dh = vrow.dict_hash
	}
	_, ds, serr := gl.store_disk(store_dir, fixture_resolve, nil, dh, 0, a)
	if serr != .None {
		return nil, 0, analysis_errorf("store open failed: %v", serr)
	}
	return ds, dh, 0
}
