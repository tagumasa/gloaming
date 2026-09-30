package glexport

import "core:fmt"
import "core:mem"
import "core:strings"

import gloaming "gloaming:gloaming"

/*
The CLI host's JSON row shapes: the analysis tables rendered as
interchange. They live in glexport — not in the CLI — so the shapes
are testable without any host process and shared by every host. Every
emitter is a pure function of its data: one line, field order as
written, ints in decimal, strings through json_esc (quotes,
backslash, control range; UTF-8 raw — the discipline export.odin
set).

Row emitters return a bare JSON array ("[]" when empty); the CLI
composes per-document bodies by joining rows with "," and hands the
result to envelope_json, which wraps it in the provenance header:
command, dictionary hash, variant
name, and the truncated bit the library's visible-cap discipline
produces. Byte spans are half-open [start, end); a span outside the
caller's text slices to "" rather than refusing — the host passed the
wrong text, and an empty field is visible without losing the row.
*/

// freq rows: {key, count, docs} — `key` is whatever was counted by
// (lemma or surface; Freq_Entry.lemma holds both roles)
freq_rows_json :: proc(entries: []gloaming.Freq_Entry,
                       a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for e, i in entries {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"key\":")
		json_esc(e.lemma, &b)
		strings.write_string(&b, ",\"count\":")
		fmt.sbprintf(&b, "%d", e.count)
		strings.write_string(&b, ",\"docs\":")
		fmt.sbprintf(&b, "%d", e.docs)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

// cooc rows: {a, b, n} — Co_Pair's own vocabulary
cooc_rows_json :: proc(pairs: []gloaming.Co_Pair,
                       a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for p, i in pairs {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"a\":")
		json_esc(p.a, &b)
		strings.write_string(&b, ",\"b\":")
		json_esc(p.b, &b)
		strings.write_string(&b, ",\"n\":")
		fmt.sbprintf(&b, "%d", p.n)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

/*
kwic rows: the concordance as data — left/center/right as text slices
beside their byte spans, doc from the row's match. The caller passes
the document text it owns — KWIC rows are source slices only the
host can resolve; one call covers one document's rows. kwic_row_json
is the single-row form hosts join across documents.
*/
kwic_row_json :: proc(r: gloaming.Kwic_Row, text: string,
                      b: ^strings.Builder) {
	// brace-bearing literals go through write_string — fmt reads
	// '{' in a format string as interpolation (export.odin's rule)
	strings.write_string(b, "{\"doc\":")
	fmt.sbprintf(b, "%d", u32(r.match.span.doc))
	strings.write_string(b, ",\"left\":")
	json_esc(span_slice(text, r.left), b)
	strings.write_string(b, ",\"center\":")
	json_esc(span_slice(text, r.center), b)
	strings.write_string(b, ",\"right\":")
	json_esc(span_slice(text, r.right), b)
	strings.write_string(b, ",\"left_span\":[")
	fmt.sbprintf(b, "%d,%d", r.left.start, r.left.end)
	strings.write_string(b, "],\"center_span\":[")
	fmt.sbprintf(b, "%d,%d", r.center.start, r.center.end)
	strings.write_string(b, "],\"right_span\":[")
	fmt.sbprintf(b, "%d,%d", r.right.start, r.right.end)
	strings.write_string(b, "]}")
}

kwic_rows_json :: proc(rows: []gloaming.Kwic_Row, text: string,
                       a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for r, i in rows {
		if i > 0 { strings.write_string(&b, ",") }
		kwic_row_json(r, text, &b)
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

/*
One query-match row: the byte span, the matched token surfaces, and
the named captures with their byte spans and source slices. Capture
names resolve through q.captures[def].name — a Match not produced by
`q` (def out of range) renders its capture name as "", visible rather
than refused, since the row is still true.
*/
match_json :: proc(m: gloaming.Match, stream: gloaming.Token_Stream,
                   text: string, q: ^gloaming.Query,
                   a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"doc\":")
	fmt.sbprintf(&b, "%d", u32(m.span.doc))
	strings.write_string(&b, ",\"start\":")
	fmt.sbprintf(&b, "%d", m.span.start)
	strings.write_string(&b, ",\"end\":")
	fmt.sbprintf(&b, "%d", m.span.end)
	strings.write_string(&b, ",\"surfaces\":[")
	lo := max(m.start, 0)
	hi := min(m.end, len(stream.tokens))
	for i := lo; i < hi; i += 1 {
		if i > lo { strings.write_string(&b, ",") }
		json_esc(stream.tokens[i].surface, &b)
	}
	strings.write_string(&b, "],\"captures\":[")
	for c, i in m.captures {
		if i > 0 { strings.write_string(&b, ",") }
		name := ""
		if c.def >= 0 && c.def < len(q.captures) { name = q.captures[c.def].name }
		strings.write_string(&b, "{\"name\":")
		json_esc(name, &b)
		strings.write_string(&b, ",\"start\":")
		fmt.sbprintf(&b, "%d", c.span.start)
		strings.write_string(&b, ",\"end\":")
		fmt.sbprintf(&b, "%d", c.span.end)
		strings.write_string(&b, ",\"surface\":")
		json_esc(span_slice(text, c.span), &b)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

/*
The provenance envelope every CLI command wraps its rows in: `dict`
is the dictionary_hash of the state that produced them (hex, 16
digits), `variant` the variant name or null, `truncated` the
visible-cap bit. `rows` must be a complete JSON array — "[]" for an
empty result, which is success, not truncation. `extra` splices a
pre-serialized `"key":value,` fragment between `truncated` and
`rows` for the commands whose shape needs header fields beside the
rows (crosstab's columns, keyness's populations); "" keeps the
plain envelope byte-identical.
*/
envelope_json :: proc(command: string, dict: u64, variant: string,
                      truncated: bool, rows: string,
                      a: mem.Allocator, extra: string = "") -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"command\":")
	json_esc(command, &b)
	fmt.sbprintf(&b, ",\"dict\":\"%016x\",\"variant\":", dict)
	if variant != "" {
		json_esc(variant, &b)
	} else {
		strings.write_string(&b, "null")
	}
	fmt.sbprintf(&b, ",\"truncated\":%v,", truncated)
	if extra != "" { strings.write_string(&b, extra) }
	strings.write_string(&b, "\"rows\":")
	strings.write_string(&b, rows)
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// keyness rows: the score with its 2×2 cells — evidence ships with
// every score. `value` renders through fmt_f6, so Lift's +Inf (the
// target-only word) reads as null, not as a broken number
keyness_rows_json :: proc(rows: []gloaming.Key_Entry,
                          a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for r, i in rows {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"key\":")
		json_esc(r.key, &b)
		strings.write_string(&b, ",\"value\":")
		fmt_f6(&b, r.value)
		strings.write_string(&b, ",\"a\":")
		fmt.sbprintf(&b, "%d", r.a)
		strings.write_string(&b, ",\"b\":")
		fmt.sbprintf(&b, "%d", r.b)
		strings.write_string(&b, ",\"c\":")
		fmt.sbprintf(&b, "%d", r.c)
		strings.write_string(&b, ",\"d\":")
		fmt.sbprintf(&b, "%d", r.d)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

/*
Merge-tree and coordinate rows — the cluster pipeline's envelope
shapes. `a`/`b` in a merge row are cluster ids under the tree's
convention (leaves 0..n−1, merge s is n+s); `dist` runs through
fmt_f6 like every other weight. cluster_rows_json pairs keys with
cluster_labels output — a length disagreement is "" (coords_json's
refusal rule), not a silently truncated table.
*/
ward_rows_json :: proc(merges: []gloaming.Ward_Merge,
                       a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for m, i in merges {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"a\":")
		fmt.sbprintf(&b, "%d", m.a)
		strings.write_string(&b, ",\"b\":")
		fmt.sbprintf(&b, "%d", m.b)
		strings.write_string(&b, ",\"dist\":")
		fmt_f6(&b, m.dist)
		strings.write_string(&b, ",\"size\":")
		fmt.sbprintf(&b, "%d", m.size)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

cluster_rows_json :: proc(keys: []string, labels: []int,
                          a: mem.Allocator) -> string {
	if len(keys) != len(labels) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for k, i in keys {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"key\":")
		json_esc(k, &b)
		strings.write_string(&b, ",\"cluster\":")
		fmt.sbprintf(&b, "%d", labels[i])
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

coords_rows_json :: proc(keys: []string, coords: []gloaming.Coord,
                         a: mem.Allocator) -> string {
	if len(keys) != len(coords) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for k, i in keys {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"key\":")
		json_esc(k, &b)
		strings.write_string(&b, ",\"x\":")
		fmt_f6(&b, coords[i].x)
		strings.write_string(&b, ",\"y\":")
		fmt_f6(&b, coords[i].y)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

/*
Crosstab header fields — the fragment the CLI passes as the
envelope's `extra`: the attribute key, the column labels and their
document marginals, and (asked for) the whole-table independence
statistic. A fragment, not an object: envelope_json splices it
between "truncated" and "rows".
*/
cross_header_json :: proc(t: ^gloaming.Cross_Table, attr: string,
                          table_stat: f64, with_stat: bool,
                          a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "\"attr\":")
	json_esc(attr, &b)
	strings.write_string(&b, ",\"columns\":[")
	for v, i in t.vals {
		if i > 0 { strings.write_string(&b, ",") }
		json_esc(v, &b)
	}
	strings.write_string(&b, "],\"sizes\":[")
	for s, i in t.sizes {
		if i > 0 { strings.write_string(&b, ",") }
		fmt.sbprintf(&b, "%d", s)
	}
	strings.write_string(&b, "]")
	if with_stat {
		strings.write_string(&b, ",\"table_chi2\":")
		fmt_f6(&b, table_stat)
	}
	strings.write_string(&b, ",")
	return strings.to_string(b)
}

/*
Cross-table rows: occurrence cells and doc-presence per group, and
(asked for) the per-key independence statistic with its adjusted
residuals. Row selection is the caller's dial — cross_table itself
applies no per-group threshold by design: top 0 = all keys,
min_total 0 = no occurrence floor. Returns the rows and the count
that survived the floor (before the top cut), so the caller's
truncated bit comes from the same walk, not a second one. `tests`
are the table's keys in order minus the absent-everywhere rows
cross_chi2 skips, so a two-cursor walk pairs them without a map.
*/
cross_rows_json :: proc(t: ^gloaming.Cross_Table,
                        tests: []gloaming.Cross_Test, with_tests: bool,
                        top: int, min_total: int,
                        a: mem.Allocator) -> (string, int) {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	emitted := 0
	kept := 0
	ti := 0
	g := len(t.vals)
	for k, i in t.keys {
		cells := t.cells[i * g : i * g + g]
		docs := t.docs[i * g : i * g + g]
		total := 0
		for c in cells { total += c }
		if total < min_total { continue }
		kept += 1
		if top > 0 && emitted >= top { continue }
		if emitted > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"key\":")
		json_esc(k, &b)
		strings.write_string(&b, ",\"cells\":[")
		for c, j in cells {
			if j > 0 { strings.write_string(&b, ",") }
			fmt.sbprintf(&b, "%d", c)
		}
		strings.write_string(&b, "],\"docs\":[")
		for d, j in docs {
			if j > 0 { strings.write_string(&b, ",") }
			fmt.sbprintf(&b, "%d", d)
		}
		strings.write_string(&b, "]")
		if with_tests {
			for ti < len(tests) && tests[ti].key != k { ti += 1 }
			if ti < len(tests) {
				strings.write_string(&b, ",\"chi2\":")
				fmt_f6(&b, tests[ti].chi2)
				strings.write_string(&b, ",\"residuals\":[")
				for r, j in tests[ti].residuals {
					if j > 0 { strings.write_string(&b, ",") }
					fmt_f6(&b, r)
				}
				strings.write_string(&b, "]")
				ti += 1
			}
		}
		strings.write_string(&b, "}")
		emitted += 1
	}
	strings.write_string(&b, "]")
	return strings.to_string(b), kept
}

// guarded source slice for a span; out-of-text spans read as ""
span_slice :: proc(text: string, s: gloaming.Span) -> string {
	if s.start < 0 || s.end > len(text) || s.start > s.end { return "" }
	return text[s.start:s.end]
}

/*
Toposort rows: the partial order as {rank, id, name} — rank is the
emission position, name the entity's canonical name from the graph.
Cyclic entities are not rows (they have no rank); the envelope's
extra fragment carries them. An id that no longer resolves to a live
row renders its name as "" — visible rather than refused, the
capture-name rule match_json applies.
*/
topo_rows_json :: proc(order: []gloaming.Entity_Id, g: ^gloaming.Doc_Graph,
                       a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for id, i in order {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"rank\":")
		fmt.sbprintf(&b, "%d", i)
		strings.write_string(&b, ",\"id\":")
		fmt.sbprintf(&b, "%d", int(id))
		strings.write_string(&b, ",\"name\":")
		json_esc(topo_name(g, id), &b)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

/*
The toposort envelope's extra fragment: the cyclic remainder — nodes
on cycles and everything downstream of them — as {id, name} in the
library's ascending order. A fragment, not an object: envelope_json
splices it between "truncated" and "rows". Always present, an empty
array when the filtered graph is a DAG.
*/
topo_cyclic_json :: proc(cyclic: []gloaming.Entity_Id, g: ^gloaming.Doc_Graph,
                         a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "\"cyclic\":[")
	for id, i in cyclic {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, "{\"id\":")
		fmt.sbprintf(&b, "%d", int(id))
		strings.write_string(&b, ",\"name\":")
		json_esc(topo_name(g, id), &b)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "],")
	return strings.to_string(b)
}

topo_name :: proc(g: ^gloaming.Doc_Graph, id: gloaming.Entity_Id) -> string {
	i := int(id)
	if i < 0 || i >= len(g.entities) || !g.entities[i].live { return "" }
	return g.entities[i].name
}
