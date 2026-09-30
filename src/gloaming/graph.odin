package gloaming

import "core:math"
import "core:mem"

/*
The document graph: entities and relations over mentions, where every
edge carries the spans it was derived from. Curated edges (a host
judging "these two mentions are the same character") and derived edges
(coding rules: pattern A near pattern B within window W -> code C)
share one mechanism; `derived` is the only difference.

Single-writer shape: `Doc_Graph` below is the state, and the graph_* apply procs
are its single mutation path. The disk writers (store_disk.odin)
serialize a row to a GLR1 record, commit the batch, and only then
apply it here, so memory never runs ahead of the log; the rebuild at
open replays the same records through the same applies. Rows carry
full state, not operations — appending is id == len(rows), rewriting
is the same id again (last wins), and a merge is simply the set of
rows it rewrites landing in one batch. Ids are dense and never reused;
a dead row keeps its slot as a tombstone.
*/

Entity_Id :: distinct int
Relation_Id :: distinct int
Kind_Id :: distinct int

// KIND_NONE is "not a vocabulary member": tombstone rows (whose record
// bodies carry no kind) and filter strings the graph never interned.
KIND_NONE :: Kind_Id(-1)

Entity :: struct {
	id:      Entity_Id,
	live:    bool, // false once a merge absorbed it — the tombstone row
	kind:    Kind_Id, // indexes Doc_Graph.kinds
	name:    string, // canonical display name
	aliases: []string,
}

Relation :: struct {
	id:       Relation_Id,
	live:     bool,
	kind:     Kind_Id, // indexes Doc_Graph.kinds
	from:     Entity_Id,
	to:       Entity_Id,
	evidence: []Span,
	derived:  bool, // coding-rule edge (true) vs curated (false)
}

Mention :: struct {
	entity: Entity_Id,
	span:   Span,
}

/*
External variables: categorical metadata attached
to a document for cross-tabulation.
*/
Doc_Attr :: struct {
	doc: Doc_Id,
	key: string,
	val: string,
}

Doc_Graph :: struct {
	a:         mem.Allocator, // owns the rows and the name index
	entities:  [dynamic]Entity,
	by_name:   map[string]Entity_Id, // canonical names and aliases → live rows
	// the kind vocabulary: one cloned string per distinct kind, dense
	// first-seen ids. Rows carry the id; hosts read the string back by
	// index. Records carry the string; writers intern after the commit
	// and replay between parse and apply — so the applies never touch
	// the vocabulary, and a replayed graph numbers kinds exactly like
	// the graph whose writes produced the log.
	kinds:     [dynamic]string,
	by_kind:   map[string]Kind_Id,
	mentions:  [dynamic]Mention, // row index is the mention id
	relations: [dynamic]Relation, // row index is the relation id
	attrs:     [dynamic]Doc_Attr,
	// the attr upsert's index: (doc, key) → row slot, maintained by
	// graph_apply_attr so writer and replay share it. Map keys view the
	// rows' own strings (writer clones, log views) — the graph never
	// frees row strings, so the keys cannot rot (the by_kind pattern)
	attr_ix:   map[Attr_Key]int,
	// live relations by identity — the graph_relation_add upsert's
	// lookup and the merge's collision fold, without row scans.
	// All-integer keys (the kind arrives interned)
	rel_ix:    map[Rel_Identity]Relation_Id,
}

// the attr rows' upsert key — the one row family without an id
Attr_Key :: struct {
	doc: Doc_Id,
	key: string,
}

Rel_Identity :: struct {
	kind:    Kind_Id,
	from:    Entity_Id,
	to:      Entity_Id,
	derived: bool,
}

graph_init :: proc(g: ^Doc_Graph, a: mem.Allocator) {
	g^ = {
		a         = a,
		entities  = make([dynamic]Entity, 0, 0, a),
		by_name   = make(map[string]Entity_Id, a),
		kinds     = make([dynamic]string, 0, 0, a),
		by_kind   = make(map[string]Kind_Id, a),
		mentions  = make([dynamic]Mention, 0, 0, a),
		relations = make([dynamic]Relation, 0, 0, a),
		attrs     = make([dynamic]Doc_Attr, 0, 0, a),
		attr_ix   = make(map[Attr_Key]int, a),
		rel_ix    = make(map[Rel_Identity]Relation_Id, a),
	}
}

// frees the containers and the kind vocabulary's bytes — the one set
// of strings the graph itself allocated. Row strings were never the
// graph's to free: writer rows clone onto the store allocator, rebuild
// rows view the log
graph_destroy :: proc(g: ^Doc_Graph) {
	for k in g.kinds {
		if len(k) > 0 { mem.free(raw_data(k), g.a) }
	}
	delete(g.entities)
	delete(g.mentions)
	delete(g.relations)
	delete(g.attrs)
	delete(g.by_name)
	delete(g.kinds)
	delete(g.by_kind)
	delete(g.attr_ix)
	delete(g.rel_ix)
}

// intern one kind string: the first sight clones onto the graph
// allocator and takes the next dense id; later sights return the
// existing id. Every row and record that names a kind goes through
// here — one string per distinct kind, integer compares everywhere
// else. The map key views the vocabulary's own copy, so the id outlives
// whichever caller's string introduced it.
graph_kind_intern :: proc(g: ^Doc_Graph, kind: string) -> Kind_Id {
	if id, ok := g.by_kind[kind]; ok { return id }
	owned := clone_str(kind, g.a)
	id := Kind_Id(len(g.kinds))
	append(&g.kinds, owned)
	g.by_kind[owned] = id
	return id
}

/*
The apply procs are infallible BY PRECONDITION: ids arrive validated
(id <= len(rows); a relation's endpoints live — rec_apply checks, the
disk writers validated before committing). Rows own nothing: strings
arrive cloned (writer) or viewing the log bytes (rebuild), both of
which outlive the rows. A row's kind arrives interned — writers intern
before building the row, replay interns between parse and apply — so
the applies never touch the vocabulary.

An entity row re-registers its names (canonical + aliases); a rewrite
first unmaps the names the previous row held — which is also how a
merge re-maps everything the absorbed entity answered to.
*/
graph_apply_entity :: proc(g: ^Doc_Graph, row: Entity) {
	if int(row.id) < len(g.entities) {
		old := g.entities[int(row.id)]
		graph_unmap_names(g, old)
		g.entities[int(row.id)] = row
	} else {
		append(&g.entities, row)
	}
	if row.live {
		g.by_name[row.name] = row.id
		for al in row.aliases {
			g.by_name[al] = row.id
		}
	}
}

graph_unmap_names :: proc(g: ^Doc_Graph, row: Entity) {
	if id, ok := g.by_name[row.name]; ok && id == row.id {
		delete_key(&g.by_name, row.name)
	}
	for al in row.aliases {
		if id, ok := g.by_name[al]; ok && id == row.id {
			delete_key(&g.by_name, al)
		}
	}
}

rel_ident :: proc(r: Relation) -> Rel_Identity {
	return Rel_Identity{kind = r.kind, from = r.from, to = r.to, derived = r.derived}
}

graph_apply_relation :: proc(g: ^Doc_Graph, row: Relation) {
	if int(row.id) < len(g.relations) {
		old := g.relations[int(row.id)]
		if old.live {
			// the identity slot passes to whichever row holds it now —
			// the guard keeps a fold's survivor from unmapping itself
			o := rel_ident(old)
			if id, ok := g.rel_ix[o]; ok && id == row.id {
				delete_key(&g.rel_ix, o)
			}
		}
		g.relations[int(row.id)] = row
	} else {
		append(&g.relations, row)
	}
	if row.live { g.rel_ix[rel_ident(row)] = row.id }
}

graph_apply_mention :: proc(g: ^Doc_Graph, id: int, m: Mention) {
	if id < len(g.mentions) {
		g.mentions[id] = m
	} else {
		append(&g.mentions, m)
	}
}

// upsert by (doc, key) — the one row without an id. The index carries
// the row slot, so the upsert is a probe; a rewrite's equal-content
// key may arrive on new bytes, and the index entry keeps viewing the
// old row's — row strings are never freed, so neither rots
graph_apply_attr :: proc(g: ^Doc_Graph, attr: Doc_Attr) {
	k := Attr_Key{doc = attr.doc, key = attr.key}
	if i, ok := g.attr_ix[k]; ok {
		g.attrs[i] = attr
		return
	}
	g.attr_ix[k] = len(g.attrs)
	append(&g.attrs, attr)
}

/*
The attribute reader: a borrowed view of the rows, in row order
(append/upsert order) — the graph's own storage, valid until the next
graph_apply_attr (the store-read borrow pattern). The one addition the
embed surface gains for the cross-tab layer.
*/
graph_doc_attrs :: proc(g: ^Doc_Graph) -> []Doc_Attr {
	return g.attrs[:]
}

graph_entity_live :: proc(g: ^Doc_Graph, id: Entity_Id) -> bool {
	i := int(id)
	return i >= 0 && i < len(g.entities) && g.entities[i].live
}

// canonical name or alias → the live entity holding it
graph_entity_find :: proc(g: ^Doc_Graph, name: string) -> (Entity_Id, bool) {
	id, ok := g.by_name[name]
	if !ok || !g.entities[int(id)].live { return {}, false }
	return id, true
}

// one entity's mentions, ascending row order (the ids they got) — one
// pass appending straight into the shipping buffer (the toposort order
// precedent). A per-entity index is deliberately absent: a mention row
// can be rewritten to another entity, so maintaining one is
// mutation-path complexity no host need has yet paid for
graph_mentions :: proc(g: ^Doc_Graph, id: Entity_Id, a: mem.Allocator) -> []Mention {
	out: [dynamic]Mention = make([dynamic]Mention, 0, 8, a)
	for m in g.mentions {
		if m.entity == id { append(&out, m) }
	}
	return out[:]
}

/*
Bounded traversal. BFS over
live relations treated as undirected (either endpoint leads out);
`kinds` empty means all. `max_depth` caps hops from the start set,
`max_frontier` caps total visits — when the cap stops the walk with
reachable nodes unseen, `truncated` says so. Deterministic: each
node's neighbours arrive in relation row order (the edge index
preserves it), so the queue order and the cap's cut are fixed by the
log; the output is (depth, id) ascending.
*/
Graph_Err :: enum {
	None,
	Bad_Budget, // a dial below its floor: max_depth < 0, max_frontier < 1, node count < 0
	Not_Found, // a start id, or link endpoint, outside the live graph
	Interrupted, // the stop-check fired mid-pass (true = stop)
}

Visit :: struct {
	entity: Entity_Id,
	depth:  int,
}

Traverse_Result :: struct {
	visits:    []Visit,
	truncated: bool,
}

// The traversal's edge index: every live, kind-listed relation filed
// under both endpoints, sorted by (endpoint, row). The row tiebreak
// keeps each node's neighbours in relation order — the subsequence the
// full row scan would have produced — so the queue order (and with it
// the frontier cap's cut) is identical to the unindexed walk.
Trav_Index_Edge :: struct {
	endpoint: Entity_Id,
	row:      int, // g.relations index, the order tiebreak
}

trav_edge_less :: proc(x, y: ^Trav_Index_Edge) -> bool {
	if int(x.endpoint) != int(y.endpoint) { return int(x.endpoint) < int(y.endpoint) }
	return x.row < y.row
}

trav_edge_key :: proc(x: ^Trav_Index_Edge) -> int { return int(x.endpoint) }

trav_lower_bound :: proc(edges: []Trav_Index_Edge, e: Entity_Id) -> int {
	return lower_bound(edges, trav_edge_key, int(e))
}

graph_traverse :: proc(g: ^Doc_Graph, start: []Entity_Id, kinds: []string,
                       max_depth: int, max_frontier: int,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> (Traverse_Result, Graph_Err) {
	if max_depth < 0 || max_frontier < 1 { return {}, .Bad_Budget }
	for s in start {
		if !graph_entity_live(g, s) { return {}, .Not_Found }
	}

	// visit flags over the entity rows — the ids are dense, so the
	// visit set is an array probe, not a hash. Start ids arrive
	// live-validated (in range); an out-of-range endpoint from
	// precondition-violating input skips like the map form's miss
	// would, it does not index wild
	visited := make([]bool, len(g.entities), a)
	defer if len(visited) > 0 { mem.free(raw_data(visited), a) }
	queue: [dynamic]Visit = make([dynamic]Visit, 0, 0, a) // no defer: the buffer ships as the result

	truncated := false

	// the start set: dedup via visited, deterministic via an id sort
	sorted: [dynamic]Entity_Id = make([dynamic]Entity_Id, len(start), len(start), a)
	defer delete(sorted)
	copy(sorted[:], start)
	sort_with_buffer(sorted[:], ent_less, a)
	for s in sorted {
		if visited[int(s)] { continue }
		if len(queue) == max_frontier {
			truncated = true
			break
		}
		visited[int(s)] = true
		append(&queue, Visit{entity = s, depth = 0})
	}

	// the neighbour index: one build replaces the per-dequeued-node scan
	// of the whole relation log (max_depth 0 never reads it, so it is
	// not built at all)
	edges: [dynamic]Trav_Index_Edge = make([dynamic]Trav_Index_Edge, 0, len(g.relations) * 2, a)
	defer delete(edges)
	kids := graph_kind_filter(g, kinds, a)
	defer kind_set_destroy(kids, a)
	if max_depth > 0 {
		for r, i in g.relations {
			if !r.live || !kind_listed(r.kind, kids) { continue }
			append(&edges, Trav_Index_Edge{endpoint = r.from, row = i})
			append(&edges, Trav_Index_Edge{endpoint = r.to, row = i})
		}
		sort_with_buffer(edges[:], trav_edge_less, a)
	}

	for qi := 0; qi < len(queue); qi += 1 {
		if check != nil && check(user) {
			delete(queue) // the would-be result unwinds, pagerank's rule
			return {}, .Interrupted
		}
		cur := queue[qi]
		if cur.depth == max_depth { continue }
		lo := trav_lower_bound(edges[:], cur.entity)
		for k := lo; k < len(edges) && edges[k].endpoint == cur.entity; k += 1 {
			r := &g.relations[edges[k].row]
			other := r.to
			if r.from != cur.entity { other = r.from }
			oi := int(other)
			if oi < 0 || oi >= len(visited) || visited[oi] { continue }
			if len(queue) == max_frontier {
				truncated = true
				continue
			}
			visited[oi] = true
			append(&queue, Visit{entity = other, depth = cur.depth + 1})
		}
	}

	// the queue holds exactly the visits, and (depth, id) totally orders
	// them (each id arrives once), so visit_less sorts it in place — the
	// one buffer ships as the result, the toposort order precedent
	visits := queue[:]
	sort_with_buffer(visits, visit_less, a)
	return Traverse_Result{visits = visits, truncated = truncated}, .None
}

ent_less :: proc(x, y: ^Entity_Id) -> bool {
	return int(x^) < int(y^)
}

visit_less :: proc(x, y: ^Visit) -> bool {
	if x.depth != y.depth { return x.depth < y.depth }
	return int(x.entity) < int(y.entity)
}

/*
The whole-graph passes' kind filter, interned once per pass: the host's
strings become a membership table over the dense kind ids, and the
per-relation test is one array load. An empty filter passes everything
(no table is built). A filter naming a kind the graph never interned
sets no bit — it cannot match any row, and dropping it would turn a
filter that passes nothing into the pass-everything empty list.
*/
Kind_Set :: struct {
	listed: []bool, // indexed by int(Kind_Id); nil = pass everything
}

graph_kind_filter :: proc(g: ^Doc_Graph, kinds: []string, a: mem.Allocator) -> Kind_Set {
	if len(kinds) == 0 { return {} }
	listed := make([]bool, len(g.kinds), a)
	for k in kinds {
		if id, ok := g.by_kind[k]; ok { listed[int(id)] = true }
	}
	return {listed = listed}
}

kind_set_destroy :: proc(f: Kind_Set, a: mem.Allocator) {
	if len(f.listed) > 0 { mem.free(raw_data(f.listed), a) }
}

// `f` passes everything when it holds no table; else the kind id must
// hold a set bit — one array load, no scan
kind_listed :: proc(kind: Kind_Id, f: Kind_Set) -> bool {
	if len(f.listed) == 0 { return true }
	i := int(kind)
	return i >= 0 && i < len(f.listed) && f.listed[i]
}

/*
A coding rule: a match of `a` and a match
of `b` closer than `window` tokens (either order — "near" is
symmetric) produce one code-C edge per match pair. graph_code_pairs
enumerates the pairs; adding them as relations is the host's loop —
the library does not invent endpoints.

Pairing runs over each side's non-overlapping match list (greedy
leftmost, the query engine's order): for one a-match the qualifying
b-matches form a contiguous band (both lists sorted, internally
non-overlapping — a two-pointer sweep is exact). Token distance is
max(0, later.start - earlier.end), so overlapping matches are
distance 0. A span matched identically on both sides is skipped: an
edge from a thing to itself carries no pair. `cap` bounds the pairs
enumerated (and each match list); `truncated` reports a capped side
biting, or one more pair existing past the cap — an exact-cap
population is not truncation (the same peek discipline query_match
applies to its limit). Pair order: a-side scan order, then
b-side order within it; within a pair, the earlier span comes first.
*/
Coding_Rule :: struct {
	code:   string, // the relation kind the host writes on the edge
	a:      ^Query,
	b:      ^Query,
	window: int, // max token gap, >= 0 (0 = adjacent or overlapping)
	cap:    int, // pairs enumerated before stopping, >= 1
}

Code_Pair :: struct {
	a: Span,
	b: Span,
}

Code_Result :: struct {
	pairs:     []Code_Pair,
	truncated: bool,
}

graph_code_pairs :: proc(rule: ^Coding_Rule, stream: Token_Stream,
                         a: mem.Allocator,
                         check: proc(user: rawptr) -> bool = nil,
                         user: rawptr = nil,
                         ) -> (Code_Result, Query_Err) {
	if rule.window < 0 || rule.cap < 1 { return {}, .Bad_Argument }
	// each side's match list is pure scratch — pairs ship spans by
	// value, so the temp allocator carries the lists and nothing
	// outlives the call on a general-purpose `a`
	ra, ea := query_match(rule.a, stream, rule.cap, context.temp_allocator, check, user)
	if ea != .None { return {}, ea }
	rb, eb := query_match(rule.b, stream, rule.cap, context.temp_allocator, check, user)
	if eb != .None { return {}, eb }

	out: [dynamic]Code_Pair = make([dynamic]Code_Pair, 0, 0, a)
	truncated := ra.truncated || rb.truncated
	capped := false // the pair cap hit — one more pair would prove it
	lo := 0
outer:
	for x in ra.matches {
		if check != nil && check(user) {
			delete(out)
			return {}, .Interrupted
		}
		for lo < len(rb.matches) && rb.matches[lo].end + rule.window < x.start {
			lo += 1
		}
		for y in rb.matches[lo:] {
			if y.start > x.end + rule.window { break }
			if y.start == x.start && y.end == x.end { continue }
			if capped {
				// the cap's peek: this pair exists past the cap, and one
				// is all "truncated" claims — an exact-cap population
				// drains the loops with the flag down
				truncated = true
				break outer
			}
			earlier, later := x, y
			if y.start < x.start || (y.start == x.start && y.end < x.end) {
				earlier, later = y, x
			}
			append(&out, Code_Pair{a = earlier.span, b = later.span})
			if len(out) == rule.cap { capped = true }
		}
	}
	return Code_Result{pairs = out[:], truncated = truncated}, .None
}

clone_strs :: proc(src: []string, a: mem.Allocator) -> []string {
	out := make([]string, len(src), a)
	for s, i in src {
		out[i] = clone_str(s, a)
	}
	return out
}

clone_spans :: proc(src: []Span, a: mem.Allocator) -> []Span {
	out := make([]Span, len(src), a)
	copy(out, src)
	return out
}

// the slice header on `a`; the strings stay views (the log outlives rows)
alias_view :: proc(src: []string, a: mem.Allocator) -> []string {
	out := make([]string, len(src), a)
	copy(out, src)
	return out
}

/*
PageRank / centrality: power iteration
over the live entities, relations directed from → to, `kinds` filtered
exactly like graph_traverse. Parallel edges (two kinds between one
pair) collapse — the question is whether u links v, not how many
vocabularies say so — and self-loops are skipped. Dangling entities
(no outgoing link) redistribute their mass uniformly, the standard
fix, so the scores always sum to 1. Starts uniform, stops when the L1
change falls to `tol` or after `max_iter` rounds; every scan is row
order, so the result is deterministic either way. pagerank_links is
the pure core (index-based — the word co-occurrence network feeds it
the same way); graph_pagerank is the document-graph wrapper. Output:
score descending, then entity id ascending. Recommended dials:
damping 0.85, max_iter 200, tol 1e-12 (explicit args — a default
before the mandatory allocator never applied, Odin calls positionally).
*/

Pr_Link :: struct {
	from: int,
	to:   int,
}

Pr_Entry :: struct {
	entity: Entity_Id,
	score:  f64,
}

/*
The distinct-link filter's membership table: open addressing on the
packed (from, to) key, linear probing, multiply-shift hash, load
factor 1/2 (init reserves twice the link count; the filter is
insert-only). The co-occurrence pair table's shape (stats.odin), held
here too because the same per-op argument holds: the setup pass probes
it once per link.
*/
Pr_Seen :: struct {
	keys: []u64,
	mask: u64,
	bits: int, // log2 of the slot count
}

pr_seen_init :: proc(s: ^Pr_Seen, hint: int, a: mem.Allocator) {
	s.bits = 4
	for (1 << u32(s.bits)) < hint * 2 { s.bits += 1 }
	cap := 1 << u32(s.bits)
	s.keys = make([]u64, cap, a) // zeroed — 0 is the empty sentinel
	s.mask = u64(cap - 1)
}

pr_seen_destroy :: proc(s: ^Pr_Seen, a: mem.Allocator) {
	if len(s.keys) > 0 { mem.free(raw_data(s.keys), a) }
}

// insert-and-report: true when the key was already there
pr_seen_insert :: proc(s: ^Pr_Seen, k: u64) -> bool {
	slot := int(((k * 0x9E3779B97F4A7C15) >> u64(64 - s.bits)) & s.mask)
	for s.keys[slot] != 0 {
		if s.keys[slot] == k { return true }
		slot = (slot + 1) & int(s.mask)
	}
	s.keys[slot] = k
	return false
}

/*
The whole-graph passes' common front: live entities as a dense index
(row order — ids are dense and never reused, so the sequence is id
ascending) and the kind-filtered directed links over it. `pos` is the
entity id → dense index table, a position array over the row list
(-1 for dead rows; it arrives make-zeroed and is initialized here) —
the ids are dense by construction, so the probe is an array load. The
endpoint skip is an invariant guard, not a filter: store rows arrive
with live endpoints, so a miss (dead row, or an out-of-range id from
precondition-violating input — it skips like the map form's miss, it
does not index wild) is corruption surviving, not data.
*/
graph_index_links :: proc(g: ^Doc_Graph, kinds: []string, a: mem.Allocator,
                          ids: ^[dynamic]Entity_Id,
                          pos: []int,
                          links: ^[dynamic]Pr_Link) {
	kids := graph_kind_filter(g, kinds, a)
	defer kind_set_destroy(kids, a)
	for i in 0..<len(pos) { pos[i] = -1 }
	for e in g.entities {
		if !e.live { continue }
		pos[int(e.id)] = len(ids^)
		append(ids, e.id)
	}
	for r in g.relations {
		if !r.live || !kind_listed(r.kind, kids) { continue }
		fi := entity_index(pos, r.from)
		ti := entity_index(pos, r.to)
		if fi < 0 || ti < 0 { continue }
		append(links, Pr_Link{from = fi, to = ti})
	}
}

// the dense index of a live entity id, -1 when the row is dead or the
// id out of range
entity_index :: proc(pos: []int, id: Entity_Id) -> int {
	i := int(id)
	if i < 0 || i >= len(pos) { return -1 }
	return pos[i]
}

pagerank_links :: proc(n: int, links: []Pr_Link, damping: f64,
                       max_iter: int, tol: f64,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]f64, Graph_Err) {
	if n < 0 { return {}, .Bad_Budget }
	if damping <= 0 || damping > 1 || max_iter < 1 || tol <= 0 {
		return {}, .Bad_Budget
	}
	for l in links {
		if l.from < 0 || l.from >= n || l.to < 0 || l.to >= n { return {}, .Not_Found }
	}

	// distinct (from, to) targets, kept in first-seen order — the order
	// fixes the floating-point accumulation order in the iteration
	// below, so the membership test runs against an open-addressing u64
	// table (the co-occurrence pair table's shape: one multiply-shift
	// hash and one probe per link, contiguous slots) while `uniq` keeps
	// the sequence (`uniq`, because `distinct` is a keyword). Key 0 is
	// the empty sentinel — a real link packs two DISTINCT indices below
	// 2^31 (the self-loops were skipped first), so it is never zero
	uniq: [dynamic]Pr_Link = make([dynamic]Pr_Link, 0, len(links), a)
	defer delete(uniq)
	seen: Pr_Seen
	pr_seen_init(&seen, len(links), a)
	defer pr_seen_destroy(&seen, a)
	for l in links {
		if l.from == l.to { continue }
		if pr_seen_insert(&seen, (u64(l.from) << 32) | u64(l.to)) { continue }
		append(&uniq, l)
	}
	deg: [dynamic]int = make([dynamic]int, n, n, a)
	defer delete(deg)
	for l in uniq { deg[l.from] += 1 }

	if n == 0 { return {}, .None }
	x: [dynamic]f64 = make([dynamic]f64, n, n, a)
	y: [dynamic]f64 = make([dynamic]f64, n, n, a)
	defer delete(y) // after the swaps below, y is whichever buffer x is not
	inv := 1.0 / f64(n)
	for i in 0..<n { x[i] = inv }
	base := (1.0 - damping) * inv

	for _ in 0..<max_iter {
		// the defer below frees only y (the scratch of the moment); x is
		// the would-be result, aborted here it is just memory
		if check != nil && check(user) { delete(x); return {}, .Interrupted }
		dangling := 0.0
		for i in 0..<n {
			if deg[i] == 0 { dangling += x[i] }
		}
		share := base + damping * dangling * inv
		for i in 0..<n { y[i] = share }
		for l in uniq {
			y[l.to] += damping * x[l.from] / f64(deg[l.from])
		}
		l1 := 0.0
		for i in 0..<n { l1 += math.abs(y[i] - x[i]) }
		x, y = y, x
		if l1 <= tol { break }
	}
	return x[:], .None
}

graph_pagerank :: proc(g: ^Doc_Graph, kinds: []string, damping: f64,
                       max_iter: int, tol: f64,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]Pr_Entry, Graph_Err) {
	ids: [dynamic]Entity_Id = make([dynamic]Entity_Id, 0, len(g.entities), a)
	defer delete(ids)
	pos := make([]int, len(g.entities), a)
	defer if len(pos) > 0 { mem.free(raw_data(pos), a) }
	links: [dynamic]Pr_Link = make([dynamic]Pr_Link, 0, len(g.relations), a)
	defer delete(links)
	graph_index_links(g, kinds, a, &ids, pos, &links)

	scores, err := pagerank_links(len(ids), links[:], damping, max_iter, tol, a,
		check, user)
	if err != .None { return {}, err }
	// pagerank_links' table is scratch here — the entries copy it out,
	// the buffer goes back before the call returns
	defer if len(scores) > 0 { mem.free(raw_data(scores), a) }

	out: [dynamic]Pr_Entry = make([dynamic]Pr_Entry, 0, len(ids), a)
	for i in 0..<len(ids) {
		append(&out, Pr_Entry{entity = ids[i], score = scores[i]})
	}
	entries := out[:]
	sort_with_buffer(entries, pr_less, a)
	return entries, .None
}

pr_less :: proc(x, y: ^Pr_Entry) -> bool {
	if x.score != y.score { return x.score > y.score }
	return int(x.entity) < int(y.entity)
}

/*
Topological order: Kahn's algorithm over the directed relations
(from → to), `kinds` filtered exactly like graph_traverse and
graph_pagerank. toposort_links is the pure core (Pr_Link is the
directed-edge row index-based callers share — pagerank's core takes
it the same way); graph_toposort is the document-graph wrapper over
graph_index_links.

Deterministic: in-degree-zero nodes enter the queue in ascending
index and a node's out-edges are removed in link order (the wrapper
passes relation row order), so the emission order is fixed by the
log. Parallel edges each count once in the in-degree and once at
removal — consistent, so they move nothing. A self-loop never frees
its node: the store writer refuses one, and a caller feeding the
core directly sees it in the remainder rather than a skip — unlike
pagerank's arithmetic, an ordering cannot ignore it.

A cycle is data, not an error. `order` is the acyclic prefix — a
valid partial topological order — and `cyclic` the nodes Kahn's
never freed: the members of cycles and everything downstream of
them, ascending. The pass is whole-graph with no cap to bite, so
there is no truncated bit.
*/

Topo_Result :: struct {
	order:  []Entity_Id,
	cyclic: []Entity_Id,
}

// the adjacency row: the binary-search span of one node's out-edges,
// `row` the links index preserving link order within a node
Topo_Edge :: struct {
	from: int,
	row:  int,
}

topo_edge_less :: proc(x, y: ^Topo_Edge) -> bool {
	if x.from != y.from { return x.from < y.from }
	return x.row < y.row
}

topo_edge_key :: proc(x: ^Topo_Edge) -> int { return x.from }

topo_lower_bound :: proc(edges: []Topo_Edge, from: int) -> int {
	return lower_bound(edges, topo_edge_key, from)
}

toposort_links :: proc(n: int, links: []Pr_Link,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]int, []int, Graph_Err) {
	if n < 0 { return nil, nil, .Bad_Budget }
	for l in links {
		if l.from < 0 || l.from >= n || l.to < 0 || l.to >= n {
			return nil, nil, .Not_Found
		}
	}
	// the stop-check polls per pop, the traverse/pagerank zero-work
	// rule: an empty or all-cyclic graph does no pops and consults
	// nobody — its preprocessing is traverse's edge-index build, also
	// unpollable
	indeg: [dynamic]int = make([dynamic]int, n, n, a)
	defer delete(indeg)
	for l in links { indeg[l.to] += 1 }

	edges: [dynamic]Topo_Edge = make([dynamic]Topo_Edge, len(links), len(links), a)
	defer delete(edges)
	for l, i in links { edges[i] = Topo_Edge{from = l.from, row = i} }
	sort_with_buffer(edges[:], topo_edge_less, a)

	// the queue is reserved to n (a node enters only as its in-degree
	// reaches zero, which happens once), so its one buffer ships as
	// the order directly — the pagerank x[:] precedent
	queue: [dynamic]int = make([dynamic]int, 0, n, a)
	for i in 0..<n {
		if indeg[i] == 0 { append(&queue, i) }
	}
	for qi := 0; qi < len(queue); qi += 1 {
		if check != nil && check(user) {
			delete(queue) // the would-be result unwinds, pagerank's rule
			return nil, nil, .Interrupted
		}
		u := queue[qi]
		lo := topo_lower_bound(edges[:], u)
		for k := lo; k < len(edges) && edges[k].from == u; k += 1 {
			t := links[edges[k].row].to
			indeg[t] -= 1
			if indeg[t] == 0 { append(&queue, t) }
		}
	}

	order := queue[:]
	// ascending indices are ascending ids under graph_index_links, so
	// the remainder lands sorted without a second sort
	cyclic := make([]int, n - len(queue), a)
	ci := 0
	for i in 0..<n {
		if indeg[i] > 0 {
			cyclic[ci] = i
			ci += 1
		}
	}
	return order, cyclic, .None
}

graph_toposort :: proc(g: ^Doc_Graph, kinds: []string,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> (Topo_Result, Graph_Err) {
	ids: [dynamic]Entity_Id = make([dynamic]Entity_Id, 0, len(g.entities), a)
	defer delete(ids)
	pos := make([]int, len(g.entities), a)
	defer if len(pos) > 0 { mem.free(raw_data(pos), a) }
	links: [dynamic]Pr_Link = make([dynamic]Pr_Link, 0, len(g.relations), a)
	defer delete(links)
	graph_index_links(g, kinds, a, &ids, pos, &links)

	oi, cy, err := toposort_links(len(ids), links[:], a, check, user)
	if err != .None { return {}, err }
	// the core's index tables are scratch here — the results copy them
	// out, the buffers go back before the call returns
	defer {
		if len(oi) > 0 { mem.free(raw_data(oi), a) }
		if len(cy) > 0 { mem.free(raw_data(cy), a) }
	}

	order := make([]Entity_Id, len(oi), a)
	for x, i in oi { order[i] = ids[x] }
	cyclic := make([]Entity_Id, len(cy), a)
	for x, i in cy { cyclic[i] = ids[x] }
	return Topo_Result{order = order, cyclic = cyclic}, .None
}
