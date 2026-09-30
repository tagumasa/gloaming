package glexport

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

import gloaming "gloaming:gloaming"

/*
Text interchange, outside the library body. gloaming returns data —
spans, tables, trees — and hosts render, cap, and stream it;
nothing in src/gloaming
emits rendering text. A host that does want dot/mermaid for Graphviz
or JSON for interchange imports this auxiliary package, which holds
pure serializations over data the library already returned: dot and
mermaid cover the graphs (the document graph's entity/relation
rows, directed from → to; the word co-occurrence network's Co_Pair
table, undirected, edges labeled with the shared-window count; the
merge-order tree, leaves labeled by word, merge nodes by height) —
dot alone covers the pinned-pos scatter (mermaid cannot pin
coordinates). JSON covers every shape as rows or whole documents
(the power-iteration coordinates and the Ward merge-order tree).
Everything is deterministic — rows emit in row order, nodes take
stable n<id> names, weights print as %.6f — and every string passes
an escaper (dot quotes, mermaid HTML entities, JSON strictly).
Results are allocated on `a`.
*/

graph_export_dot :: proc(g: ^gloaming.Doc_Graph, kinds: []string,
                         a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "digraph gloaming {\n  rankdir=LR;\n")
	for e in g.entities {
		if !e.live { continue }
		fmt.sbprintf(&b, "  n%d [label=", int(e.id))
		dot_esc(e.name, &b)
		strings.write_string(&b, "];\n")
	}
	kids := gloaming.graph_kind_filter(g, kinds, a)
	defer gloaming.kind_set_destroy(kids, a)
	for r in g.relations {
		if !r.live || !gloaming.kind_listed(r.kind, kids) { continue }
		fmt.sbprintf(&b, "  n%d -> n%d [label=", int(r.from), int(r.to))
		dot_esc(g.kinds[r.kind], &b)
		strings.write_string(&b, "];\n")
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

graph_export_mermaid :: proc(g: ^gloaming.Doc_Graph, kinds: []string,
                             a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "graph LR\n")
	for e in g.entities {
		if !e.live { continue }
		fmt.sbprintf(&b, "  n%d[", int(e.id))
		mermaid_esc(e.name, &b)
		strings.write_string(&b, "]\n")
	}
	kids := gloaming.graph_kind_filter(g, kinds, a)
	defer gloaming.kind_set_destroy(kids, a)
	for r in g.relations {
		if !r.live || !gloaming.kind_listed(r.kind, kids) { continue }
		fmt.sbprintf(&b, "  n%d ---|", int(r.from))
		mermaid_esc(g.kinds[r.kind], &b)
		fmt.sbprintf(&b, "| n%d\n", int(r.to))
	}
	return strings.to_string(b)
}

// the word co-occurrence network: undirected, nodes are the distinct
// pair keys in code-point order (so node numbering is stable), edges
// labeled with the shared-window count. `labels` — from
// gloaming.cluster_labels over the same key order (code-point
// ascending, pair_keys' order below) — fills each node with its
// cluster's color; a length that disagrees with the key count, or a
// negative label (the color ring indexes 0.. only), is a refusal
// (""), not a partially colored picture
pairs_export_dot :: proc(pairs: []gloaming.Co_Pair, a: mem.Allocator,
                         labels: []int = nil) -> string {
	keys, idx := pair_keys(pairs, a)
	defer delete(idx)
	defer delete(keys)
	if labels != nil && !labels_ok(labels, len(keys)) { return "" }
	colors := CLUSTER_COLORS
	b := strings.builder_make(a)
	strings.write_string(&b, "graph words {\n  rankdir=LR;\n")
	for k, i in keys {
		fmt.sbprintf(&b, "  n%d [label=", i)
		dot_esc(k, &b)
		if labels != nil {
			fmt.sbprintf(&b, ", style=filled, fillcolor=\"%s\"",
				colors[labels[i] % len(colors)])
		}
		strings.write_string(&b, "];\n")
	}
	for p in pairs {
		fmt.sbprintf(&b, "  n%d -- n%d [label=\"%d\"];\n", idx[p.a], idx[p.b], p.n)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

pairs_export_mermaid :: proc(pairs: []gloaming.Co_Pair, a: mem.Allocator,
                             labels: []int = nil) -> string {
	keys, idx := pair_keys(pairs, a)
	defer delete(idx)
	defer delete(keys)
	if labels != nil && !labels_ok(labels, len(keys)) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "graph LR\n")
	for k, i in keys {
		fmt.sbprintf(&b, "  n%d[", i)
		mermaid_esc(k, &b)
		strings.write_string(&b, "]\n")
	}
	if labels != nil {
		colors := CLUSTER_COLORS
		for i in 0..<len(keys) {
			fmt.sbprintf(&b, "  style n%d fill:%s\n", i,
				colors[labels[i] % len(colors)])
		}
	}
	for p in pairs {
		fmt.sbprintf(&b, "  n%d ---|%d| n%d\n", idx[p.a], p.n, idx[p.b])
	}
	return strings.to_string(b)
}

// a colorblind-safe qualitative 8-color set; a ninth cluster cycles
// back to the first color — a rendering convention, not
// data: the labels themselves are what the library returned
CLUSTER_COLORS :: [8]string{
	"#E69F00", // orange
	"#56B4E9", // sky blue
	"#009E73", // bluish green
	"#F0E442", // yellow
	"#0072B2", // blue
	"#D55E00", // vermillion
	"#CC79A7", // reddish purple
	"#999999", // grey
}

// labels for the colored exporters: one per pair key, every one 0..
// (the ring cycles by modulo — a negative label would index before
// the array, so it refuses like a length mismatch)
labels_ok :: proc(labels: []int, n: int) -> bool {
	if len(labels) != n { return false }
	for l in labels {
		if l < 0 { return false }
	}
	return true
}

/*
The merge-order tree (ward_merges / linkage_merges output) as an
undirected graph: leaf nodes carry word labels, merge nodes the
height the merge happened at — the dendrogram's data, Graphviz's
tree layout doing the drawing. The k-cut needs no flag here: a
front slice of the merge list (merges[:n−k]) is itself a valid
tree — ids only ever name earlier rows — so the caller slices and
this renders the forest. The input contract is ward_json's (ids in
[0, n+i), no more than n−1 rows over len(keys) == n keys); anything
else is "" — a refusal a host can see.
*/

merges_export_dot :: proc(keys: []string, merges: []gloaming.Ward_Merge,
                          a: mem.Allocator) -> string {
	n := len(keys)
	if !merge_tree_ok(keys, merges) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "graph merges {\n  rankdir=LR;\n")
	for k, i in keys {
		fmt.sbprintf(&b, "  n%d [label=", i)
		dot_esc(k, &b)
		strings.write_string(&b, "];\n")
	}
	for m, i in merges {
		fmt.sbprintf(&b, "  n%d [label=\"", n + i)
		fmt_f6(&b, m.dist)
		strings.write_string(&b, "\"];\n")
		fmt.sbprintf(&b, "  n%d -- n%d;\n  n%d -- n%d;\n", n + i, m.a, n + i, m.b)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

merges_export_mermaid :: proc(keys: []string, merges: []gloaming.Ward_Merge,
                              a: mem.Allocator) -> string {
	n := len(keys)
	if !merge_tree_ok(keys, merges) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "graph LR\n")
	for k, i in keys {
		fmt.sbprintf(&b, "  n%d[", i)
		mermaid_esc(k, &b)
		strings.write_string(&b, "]\n")
	}
	for m, i in merges {
		fmt.sbprintf(&b, "  n%d(", n + i)
		fmt_f6(&b, m.dist)
		fmt.sbprintf(&b, ")\n  n%d --- n%d\n  n%d --- n%d\n", n + i, m.a, n + i, m.b)
	}
	return strings.to_string(b)
}

// len(keys) == n, at most n−1 merge rows, every id inside [0, n+i) —
// the shape ward_json, the tree exporters, and a k-cut slice all
// share (a cut slice just has fewer rows)
merge_tree_ok :: proc(keys: []string, merges: []gloaming.Ward_Merge) -> bool {
	n := len(keys)
	if len(merges) > n - 1 { return false }
	for m, i in merges {
		if m.a < 0 || m.b < 0 || m.a >= n + i || m.b >= n + i { return false }
	}
	return true
}

/*
The 2-D coordinate table as a graph for neato: every node pinned at
its (x, y) with pos="…!", no edges — a scatter laid out from the
data. dot would ignore the pins (it draws its own hierarchy), and
mermaid has no position pinning at all, so this export has no dot-
hierarchy or mermaid twin. keys and coords must match in length;
anything else is "".
*/
coords_export_dot :: proc(keys: []string, coords: []gloaming.Coord,
                          a: mem.Allocator) -> string {
	if len(keys) != len(coords) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "graph coords {\n")
	for k, i in keys {
		fmt.sbprintf(&b, "  n%d [label=", i)
		dot_esc(k, &b)
		strings.write_string(&b, ", pos=\"")
		fmt_f6(&b, coords[i].x)
		strings.write_string(&b, ",")
		fmt_f6(&b, coords[i].y)
		strings.write_string(&b, "!\"];\n")
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

/*
The coordinate and merge-order exports (correspondence-analysis/MDS
and cluster-analysis shapes). coords_json needs matching key/coord lengths;
ward_json's merge rows carry cluster ids where a or b >= len(keys)
refers to merges[a - len(keys)] — and only to an EARLIER row. Mismatched,
negative, forward-, or self-referencing input yields an empty string —
a refusal a host can see, not a partial document.
*/

coords_json :: proc(keys: []string, coords: []gloaming.Coord,
                    a: mem.Allocator) -> string {
	if len(keys) != len(coords) { return "" }
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"coords\":[")
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
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

ward_json :: proc(keys: []string, merges: []gloaming.Ward_Merge,
                  a: mem.Allocator) -> string {
	// a merge row may reference a leaf (< len(keys)) or an earlier
	// merge (merges[id - len(keys)], so id < len(keys) + i): a forward
	// or self reference makes the cluster graph cyclic — a refusal,
	// like any other unresolvable id
	n := len(keys)
	for m, i in merges {
		if m.a < 0 || m.b < 0 || m.a >= n + i || m.b >= n + i { return "" }
	}
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"keys\":[")
	for k, i in keys {
		if i > 0 { strings.write_string(&b, ",") }
		json_esc(k, &b)
	}
	strings.write_string(&b, "],\"merges\":[")
	for i in 0..<len(merges) {
		if i > 0 { strings.write_string(&b, ",") }
		m := merges[i]
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
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

// distinct pair keys, code-point ascending; the map is the key → node
// index — built together so every exporter numbers nodes identically
pair_keys :: proc(pairs: []gloaming.Co_Pair, a: mem.Allocator) -> (keys: [dynamic]string,
		idx: map[string]int) {
	seen := make(map[string]bool, a)
	defer delete(seen)
	keys = make([dynamic]string, 0, 2 * len(pairs), a)
	idx = make(map[string]int, a)
	for p in pairs {
		sides := [2]string{p.a, p.b}
		for k in sides {
			if _, dup := seen[k]; dup { continue }
			seen[k] = true
			append(&keys, k)
		}
	}
	gloaming.sort_with_buffer(keys[:], str_less, a)
	for k, i in keys { idx[k] = i }
	return keys, idx
}

str_less :: proc(x, y: ^string) -> bool {
	return strings.compare(x^, y^) < 0
}

// %.6f straight into the target builder. Zeros print unsigned — both
// the exact -0.0 and any negative that rounds away at six decimals —
// and a non-finite value becomes null: coordinates are visual, six
// decimals is finer than any plot, and NaN/Inf would not be JSON
fmt_f6 :: proc(b: ^strings.Builder, v: f64) {
	if v - v != 0 { // only a non-finite value differs from itself
		strings.write_string(b, "null")
		return
	}
	u := v
	if math.abs(u) < 5e-7 { u = 0 }
	fmt.sbprintf(b, "%.6f", u)
}

dot_esc :: proc(s: string, b: ^strings.Builder) {
	strings.write_byte(b, '"')
	for i in 0..<len(s) {
		switch s[i] {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case:
			if s[i] < 0x20 {
				// DOT's octal escape — a NUL or newline must not cut the
				// label or the one-statement-per-line layout
				fmt.sbprintf(b, "\\%03o", int(s[i]))
			} else {
				strings.write_byte(b, s[i])
			}
		}
	}
	strings.write_byte(b, '"')
}

// mermaid labels carry no quoting machinery — HTML entities it is,
// for every byte mermaid would read as shape or line syntax
mermaid_escape :: proc(c: u8) -> string {
	switch c {
	case '&':  return "&amp;"
	case '"':  return "&quot;"
	case '|':  return "&#124;"
	case '<':  return "&lt;"
	case '>':  return "&gt;"
	case '[':  return "&#91;"
	case ']':  return "&#93;"
	case '(':  return "&#40;"
	case ')':  return "&#41;"
	case '{':  return "&#123;"
	case '}':  return "&#125;"
	case ';':  return "&#59;"
	case '#':  return "&#35;"
	case '\n': return "&#10;"
	case '\r': return "&#13;"
	}
	return "" // the passthrough slot
}

mermaid_esc :: proc(s: string, b: ^strings.Builder) {
	for i in 0..<len(s) {
		entity := mermaid_escape(s[i])
		if entity != "" {
			strings.write_string(b, entity)
		} else {
			strings.write_byte(b, s[i])
		}
	}
}

// JSON strings: quotes, backslash, and the control range strictly;
// UTF-8 passes through raw
json_esc :: proc(s: string, b: ^strings.Builder) {
	strings.write_byte(b, '"')
	for i in 0..<len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}
