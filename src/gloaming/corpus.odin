package gloaming

import "core:math"
import "core:mem"
import "core:strings"

/*
The corpus layer: aggregation across documents, the Doc_Attr
read side, and the cross tables — every stats proc before this file
took one Token_Stream, so `Freq_Entry.docs` could never be true and
corpus-wide work (tf·idf ranking, the document × term table,
document-side clustering / MDS, cross-tabulation) had nothing to
run on.

Every proc here takes the caller's population as a Doc_Id list —
`store.docs(ctx)` ascending for the whole corpus, a subset for a group
(the cross tables pass doc_groups slices). Iteration follows the list as given, so
ascending lists make reproducible runs. A duplicate Doc_Id in the list
is .Duplicate (assoc_scores' deterministic duplicate refusal, mapped
onto this vocabulary); a doc the store lacks surfaces the backend's
Store_Err unchanged. Over the disk backend every listed document
decodes once — a whole-corpus pass is a real cost, not hidden; hosts
restricting to groups or fronting with the memory backend keep it
bounded (no cache here by design). Exclusion against store mutation
is the host's. Outputs on `a`, scratch freed by
the call; keys borrow the backend's token strings — the store-read
view discipline (valid until the next mutation on that backend; disk
backends decode onto `a` and own their copies). Every pass that
touches the store takes the optional stop-check (true = stop,
query_match's convention), polled once per document — .Interrupted
returns with scratch freed, so a whole-corpus sweep stays cancellable
for an interactive host.
*/

corpus_freq :: proc(store: Store, docs: []Doc_Id, filter: Freq_Filter,
                    a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil,
                    user: rawptr = nil) -> ([]Freq_Entry, Store_Err) {
	counts, ndocs, err := corpus_count_maps(store, docs, filter, a, check, user)
	if err != .None { return {}, err }
	defer delete(counts)
	defer delete(ndocs)

	out: [dynamic]Freq_Entry = make([dynamic]Freq_Entry, 0, len(counts), a)
	for k, n in counts {
		docs_holding, _ := ndocs[k]
		append(&out, Freq_Entry{lemma = k, count = n, docs = docs_holding})
	}
	entries := out[:]
	sort_with_buffer(entries, freq_less, a)
	apply_min_count(&entries, filter.min_count)
	return entries, .None
}

/*
corpus_freq's counting core: per-key occurrence sums (`counts`) and
per-key document counts (`ndocs`) over one doc list — count sums
occurrences, docs increments once per document holding >= 1. A
duplicate Doc_Id refuses .Duplicate here so every counting caller
(corpus_freq, cross_table's per-group pass) shares the rule. Both maps
are the caller's to delete. One map pass per document merged into the
corpus map. The optional stop-check polls once per document —
.Interrupted leaves both maps deleted.
*/
corpus_count_maps :: proc(store: Store, docs: []Doc_Id, filter: Freq_Filter,
                          a: mem.Allocator,
                          check: proc(user: rawptr) -> bool = nil,
                          user: rawptr = nil) -> (counts: map[string]int,
                          ndocs: map[string]int, err: Store_Err) {
	counts = make(map[string]int, a)
	ndocs = make(map[string]int, a)
	listed := make(map[Doc_Id]bool, a)
	defer delete(listed)
	for d in docs {
		if _, dup := listed[d]; dup {
			delete(counts)
			delete(ndocs)
			return {}, {}, .Duplicate
		}
		listed[d] = true
	}
	for d in docs {
		if check != nil && check(user) {
			delete(counts)
			delete(ndocs)
			return {}, {}, .Interrupted
		}
		toks, terr := store.tokens(store.ctx, d, a)
		if terr != .None {
			delete(counts)
			delete(ndocs)
			return {}, {}, terr
		}
		per := make(map[string]int, a)
		defer delete(per)
		for tok in toks {
			key, keep := filter_key(tok, filter)
			if !keep { continue }
			per[key] += 1
		}
		for k, n in per {
			counts[k] += n
			ndocs[k] += 1
		}
	}
	return counts, ndocs, .None
}

// freq_table's output filter, shared: entries below min_count drop
// after counting (min_count <= 1 keeps everything)
apply_min_count :: proc(entries: ^[]Freq_Entry, min_count: int) {
	if min_count <= 1 { return }
	kept := 0
	for i in 0..<len(entries^) {
		if entries^[i].count >= min_count {
			entries^[kept] = entries^[i]
			kept += 1
		}
	}
	entries^ = entries^[:kept]
}

/*
One document's profile over the shared filter — the unit both distance
procs and the matrix consume (build once, reuse). `keys` is ascending
by code point, `counts` parallel occurrences; strings borrow the
backend's token views. Profiles come back in list order.
*/

Doc_Profile :: struct {
	doc:    Doc_Id,
	keys:   []string, // counting keys present, ascending by code point
	counts: []int, // parallel occurrences
}

doc_profiles :: proc(store: Store, docs: []Doc_Id, filter: Freq_Filter,
                     a: mem.Allocator,
                     check: proc(user: rawptr) -> bool = nil,
                     user: rawptr = nil) -> ([]Doc_Profile, Store_Err) {
	listed := make(map[Doc_Id]bool, a)
	defer delete(listed)
	for d in docs {
		if _, dup := listed[d]; dup { return {}, .Duplicate }
		listed[d] = true
	}
	out := make([]Doc_Profile, len(docs), a)
	for d, i in docs {
		if check != nil && check(user) {
			// the profiles built so far own their parallel arrays — the
			// same stranding rule as the backend refusal below
			for x in 0..<i {
				if len(out[x].keys) > 0 { mem.free(raw_data(out[x].keys), a) }
				if len(out[x].counts) > 0 { mem.free(raw_data(out[x].counts), a) }
			}
			if len(out) > 0 { mem.free(raw_data(out), a) }
			return {}, .Interrupted
		}
		toks, err := store.tokens(store.ctx, d, a)
		if err != .None {
			// the profiles built so far own their parallel arrays — free
			// them with the slice before refusing, or they would strand
			// on a non-arena caller's allocator
			for x in 0..<i {
				if len(out[x].keys) > 0 { mem.free(raw_data(out[x].keys), a) }
				if len(out[x].counts) > 0 { mem.free(raw_data(out[x].counts), a) }
			}
			if len(out) > 0 { mem.free(raw_data(out), a) }
			return {}, err
		}
		per := make(map[string]int, a)
		defer delete(per)
		for tok in toks {
			key, keep := filter_key(tok, filter)
			if !keep { continue }
			per[key] += 1
		}
		rows: [dynamic]Lemma_Count = make([dynamic]Lemma_Count, 0, len(per), a)
		defer delete(rows)
		for k, n in per { append(&rows, Lemma_Count{k, n}) }
		sort_with_buffer(rows[:], strkey_less, a)
		keys := make([]string, len(rows), a)
		counts := make([]int, len(rows), a)
		for r, j in rows {
			keys[j] = r.lemma
			counts[j] = r.count
		}
		out[i] = Doc_Profile{doc = d, keys = keys, counts = counts}
	}
	return out, .None
}

// profile rows: key ascending — the parallel-arrays sort key
strkey_less :: proc(x, y: ^Lemma_Count) -> bool {
	return strings.compare(x.lemma, y.lemma) < 0
}

/*
doc_weights: doc × doc shared-presence counts — |keys(d) ∩ keys(e)|,
symmetric, zero diagonal, non-negative: exactly the contingency table
power_coords normalizes (S = D^-½ W D^-½), so document-side correspondence-analysis /
MDS-stand-in coordinates are power_coords(doc_weights(...)) with no
new solver. Duplicate keys within one profile — or keys not strictly
ascending, the Doc_Profile order these joins walk — are Bad_Count (the
count-table rule). Row-major k×k, k = len(profiles). Corpus-scale k²
over the document population — the optional stop-check polls once per
row.
*/
profiles_ordered :: proc(profiles: []Doc_Profile) -> bool {
	for p in profiles {
		for i in 1..<len(p.keys) {
			if strings.compare(p.keys[i - 1], p.keys[i]) >= 0 { return false }
		}
	}
	return true
}

// one ordered walk over two profiles: the shared-key count and, over
// the aligned pairs, the count-product sum — everything the doc×doc
// measures need from a pair
profile_join :: proc(pa, pb: Doc_Profile) -> (shared: int, dot: f64) {
	x, y := 0, 0
	for x < len(pa.keys) && y < len(pb.keys) {
		c := strings.compare(pa.keys[x], pb.keys[y])
		if c < 0 {
			x += 1
		} else if c > 0 {
			y += 1
		} else {
			shared += 1
			dot += f64(pa.counts[x]) * f64(pb.counts[y])
			x += 1
			y += 1
		}
	}
	return
}

doc_weights :: proc(profiles: []Doc_Profile,
                    a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil,
                    user: rawptr = nil) -> ([]f64, Freq_Err) {
	if !profiles_ordered(profiles) { return {}, .Bad_Count }
	k := len(profiles)
	w := make([]f64, k * k, a)
	for i in 0..<k {
		if check != nil && check(user) {
			if len(w) > 0 { mem.free(raw_data(w), a) }
			return {}, .Interrupted
		}
		for j in i + 1..<k {
			shared, _ := profile_join(profiles[i], profiles[j])
			w[i * k + j] = f64(shared)
			w[j * k + i] = f64(shared)
		}
	}
	return w, .None
}

/*
doc_distance: doc × doc dissimilarity for ward_merges — Jaccard over
presence sets, Cosine over count vectors. Symmetric, zero diagonal,
non-negative (cosine caps at 2), finite — the ward_merges input
contract, so document-side clustering is doc_distance →
ward_merges → ward_json, matrix-generic already. Degenerate rules,
pinned: two empty profiles are identical (distance 0); one empty
profile against anything is 1 under either measure (an empty set
shares nothing, a zero vector no direction). Duplicate keys within one
profile — or keys not strictly ascending, the Doc_Profile order the
joins walk — are Bad_Count. Corpus-scale k² over the document
population — the optional stop-check polls once per row.
*/
Doc_Distance :: enum {
	Jaccard,
	Cosine,
}

doc_distance :: proc(profiles: []Doc_Profile, m: Doc_Distance,
                     a: mem.Allocator,
                     check: proc(user: rawptr) -> bool = nil,
                     user: rawptr = nil) -> ([]f64, Freq_Err) {
	if !profiles_ordered(profiles) { return {}, .Bad_Count }
	k := len(profiles)
	norms := make([]f64, k, a)
	defer if len(norms) > 0 { mem.free(raw_data(norms), a) }
	for p, i in profiles {
		s := 0.0
		for n in p.counts { s += f64(n) * f64(n) }
		norms[i] = math.sqrt(s)
	}
	d := make([]f64, k * k, a)
	for i in 0..<k {
		if check != nil && check(user) {
			if len(d) > 0 { mem.free(raw_data(d), a) }
			return {}, .Interrupted
		}
		d[i * k + i] = 0
		for j in i + 1..<k {
			dij := 0.0
			shared, dot := profile_join(profiles[i], profiles[j])
			switch m {
			case .Jaccard:
				either := len(profiles[i].keys) + len(profiles[j].keys) - shared
				if either == 0 {
					dij = 0 // two empty profiles are identical
				} else if shared == 0 {
					dij = 1
				} else {
					dij = 1 - f64(shared) / f64(either)
				}
			case .Cosine:
				if norms[i] == 0 && norms[j] == 0 {
					dij = 0 // two zero vectors are identical
				} else if norms[i] == 0 || norms[j] == 0 {
					dij = 1 // a zero vector shares no direction
				} else {
					dij = 1 - dot / (norms[i] * norms[j])
				}
			}
			d[i * k + j] = dij
			d[j * k + i] = dij
		}
	}
	return d, .None
}

/*
doc_matrix: the doc × key weight matrix, doc-major w[d*len(keys) + i] —
tf·idf ranking and the document × term table are this matrix,
sliced by the host; matrices ship as numbers, hosts serialize (text
interchange is the aux glexport package's). tf = the profile count; tf-idf = tf ·
ln(N / df) with N = len(profiles) and df the key's docs count from
`df` (corpus_freq over the same population — idf >= 0 because
df <= N, so a key present in every doc weighs zero). A key absent from
`df`, a duplicate key or df row, a df docs count outside 1..N, or a
profile whose keys are not strictly ascending (the Doc_Profile order)
is Bad_Count: the population must describe the matrix. Pure profile
arithmetic — no store dependency, Freq_Err's vocabulary.
*/
Tf_Mode :: enum {
	Tf,
	Tf_Idf,
}

doc_matrix :: proc(profiles: []Doc_Profile, keys: []string, df: []Freq_Entry,
                   mode: Tf_Mode, a: mem.Allocator,
                   check: proc(user: rawptr) -> bool = nil,
                   user: rawptr = nil) -> ([]f64, Freq_Err) {
	n := len(profiles)
	if !profiles_ordered(profiles) { return {}, .Bad_Count }
	df_by := make(map[string]int, a)
	defer delete(df_by)
	for e in df {
		if e.docs < 1 || e.docs > n { return {}, .Bad_Count }
		if _, dup := df_by[e.lemma]; dup { return {}, .Bad_Count }
		df_by[e.lemma] = e.docs
	}
	// the matrix keys' row slots — the duplicate check and the column
	// index are the same table (the vocabulary rule)
	key_ix := make(map[string]int, len(keys), a)
	defer delete(key_ix)
	for k, i in keys {
		if _, dup := key_ix[k]; dup { return {}, .Bad_Count }
		if _, ok := df_by[k]; !ok { return {}, .Bad_Count }
		key_ix[k] = i
	}
	// idf per column, hoisted out of the d×k loop — one ln per key,
	// not one per cell
	idf := make([]f64, len(keys), a)
	defer if len(idf) > 0 { mem.free(raw_data(idf), a) }
	if mode == .Tf_Idf {
		for k, i in keys {
			docs, _ := df_by[k]
			idf[i] = math.ln(f64(n) / f64(docs))
		}
	}
	w := make([]f64, n * len(keys), a)
	for p, d in profiles {
		if check != nil && check(user) {
			if len(w) > 0 { mem.free(raw_data(w), a) }
			return {}, .Interrupted
		}
		// the profile's own keys carry the counts — one probe per
		// distinct key it holds, columns it lacks stay zero
		for key, x in p.keys {
			i, ok := key_ix[key]
			if !ok { continue }
			tf := p.counts[x]
			if mode == .Tf {
				w[d * len(keys) + i] = f64(tf)
			} else {
				w[d * len(keys) + i] = f64(tf) * idf[i]
			}
		}
	}
	return w, .None
}

/*
The Doc_Attr read side: the population split one attribute's
values make. A doc carrying the attribute lands in its value's group,
a doc without it in the "" group (the "missing" bucket — a
legitimate empty value merges there too, the cost of a
zero-value vocabulary). Groups sort by value ascending (code point),
docs within a group ascending; an attribute value no population doc
holds produces no group. Duplicates in the population list are the
caller's refusal (corpus_freq checks), not re-derived here — the proc
is pure list processing, infallible by construction. Variable × variable
crosstabs compose: doc_groups on two keys, counts from the population
list — host composition over this primitive.
*/

Doc_Group :: struct {
	val:  string, // the value; "" collects docs missing the attribute
	docs: []Doc_Id, // ascending
}

doc_groups :: proc(attrs: []Doc_Attr, key: string, docs: []Doc_Id,
                   a: mem.Allocator) -> []Doc_Group {
	vals: [dynamic]string = make([dynamic]string, 0, 8, a)
	defer delete(vals)
	members: [dynamic][dynamic]Doc_Id = make([dynamic][dynamic]Doc_Id, 0, 8, a)
	defer {
		for m in members { delete(m) }
		delete(members)
	}
	idx := make(map[string]int, a)
	defer delete(idx)
	// the first row per doc holding `key` — integer-keyed, built once;
	// the per-doc lookup below is a probe, not a row scan
	first := make(map[Doc_Id]int, a)
	defer delete(first)
	for r, i in attrs {
		if r.key != key { continue }
		if _, dup := first[r.doc]; dup { continue } // the first row wins
		first[r.doc] = i
	}
	for d in docs {
		val := ""
		if i, ok := first[d]; ok { val = attrs[i].val }
		i, ok := idx[val]
		if !ok {
			i = len(vals)
			idx[val] = i
			append(&vals, val)
			append(&members, make([dynamic]Doc_Id, 0, 4, a))
		}
		append(&members[i], d)
	}
	out := make([]Doc_Group, len(vals), a)
	for v, i in vals {
		gd := make([]Doc_Id, len(members[i]), a)
		copy(gd, members[i][:])
		sort_with_buffer(gd, docid_less, a)
		out[i] = Doc_Group{val = v, docs = gd}
	}
	sort_with_buffer(out, group_less, a)
	return out
}

docid_less :: proc(x, y: ^Doc_Id) -> bool {
	return u32(x^) < u32(y^)
}

group_less :: proc(x, y: ^Doc_Group) -> bool {
	return strings.compare(x.val, y.val) < 0
}

/*
The word (or code) × group table: per-group corpus counts and
doc-presence merged into one table — strength (occurrence cells) and
breadth (doc cells) without a second pass. Runs the counting core
(corpus_count_maps) per group, so duplicate docs inside a group and missing docs
refuse exactly as corpus_freq does (.Duplicate / the backend's
Store_Err). `vals` and `sizes` mirror the caller's groups (doc_groups
emits value-ascending); a zero-size group stays honestly in the table
— its column is flagged by `sizes`, and cross_chi2 skips it. Rows are
the union vocabulary ordered total occurrences descending then key
ascending — count-table shaped, hosts slice top-k. min_count is NOT
applied here: a per-group threshold would drop union rows a whole
table should keep (a key rare in every group but common in sum) — the
caller slices instead. Codes as rows: a host enumerating derived
relations per document builds a code-presence table through the same
shape (the code × variable table) — that enumeration is the host's loop.
*/
Cross_Table :: struct {
	vals:  []string, // group values — column labels
	sizes: []int, // docs per group — column marginals
	keys:  []string, // counting keys, total occurrences desc then key asc
	cells: []int, // row-major over g = len(vals): cells[i*g + j] — occurrences of key i in group j
	docs:  []int, // same stride: docs[i*g + j] — documents in group j holding key i
}

cross_table :: proc(store: Store, groups: []Doc_Group, filter: Freq_Filter,
                    a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil,
                    user: rawptr = nil) -> (Cross_Table, Store_Err) {
	vals := make([]string, len(groups), a)
	sizes := make([]int, len(groups), a)
	for grp, j in groups {
		vals[j] = grp.val
		sizes[j] = len(grp.docs)
	}
	g := len(groups)

	// dense rows, doc_matrix's shape: the table body is two flat blocks
	// row-major over the g group columns; the map holds each key's build
	// row, a new key's row enters as g zeroes, and this group's column
	// is set below — the per-row make of a map-of-slices build is gone
	row_ix := make(map[string]int, a)
	defer delete(row_ix)
	totals: [dynamic]Lemma_Count = make([dynamic]Lemma_Count, 0, 16, a)
	defer delete(totals)
	cells: [dynamic]int = make([dynamic]int, 0, 16 * g, a)
	defer delete(cells)
	docs: [dynamic]int = make([dynamic]int, 0, 16 * g, a)
	defer delete(docs)
	table_filter := filter
	table_filter.min_count = 0 // the table counts, the host slices (above)
	for grp, j in groups {
		counts, ndocs, err := corpus_count_maps(store, grp.docs, table_filter, a, check, user)
		if err != .None {
			// a refusal allocates nothing net (ms_add_document's rule) —
			// every buffer here owns its delete through a defer except
			// vals and sizes
			if len(vals) > 0 { mem.free(raw_data(vals), a) }
			if len(sizes) > 0 { mem.free(raw_data(sizes), a) }
			return {}, err
		}
		defer delete(counts)
		defer delete(ndocs)
		for k, n in counts {
			ri, ok := row_ix[k]
			if !ok {
				ri = len(totals)
				row_ix[k] = ri
				append(&totals, Lemma_Count{lemma = k})
				for _ in 0..<g {
					append(&cells, 0)
					append(&docs, 0)
				}
			}
			cells[ri * g + j] = n
			hold, _ := ndocs[k]
			docs[ri * g + j] = hold
			totals[ri].count += n
		}
	}

	// freq_table's order over the totals: count desc, then key asc —
	// lemma_more is that comparator on Lemma_Count
	sort_with_buffer(totals[:], lemma_more, a)

	keys := make([]string, len(totals), a)
	out_cells := make([]int, len(totals) * g, a)
	out_docs := make([]int, len(totals) * g, a)
	for r, i in totals { // slice iteration binds value-then-index
		keys[i] = r.lemma
		src, _ := row_ix[r.lemma]
		src *= g
		dst := i * g
		for j in 0..<g {
			out_cells[dst + j] = cells[src + j]
			out_docs[dst + j] = docs[src + j]
		}
	}
	return Cross_Table{
		vals = vals, sizes = sizes, keys = keys, cells = out_cells, docs = out_docs,
	}, .None
}

/*
Per-key independence over the groups: for each key a k×2 table
on document PRESENCE (the docs cells — the unit a crosstab
counts), Pearson's statistic and Haberman's adjusted residual per
group, r_ij = (O_ij − E_ij) / sqrt(E_ij (1 − p_i·) (1 − p_·j)) with
p_i· the key's row share and p_·j group j's column share over the Σ
sizes population. Yates is not applied here — the correction is the
2×2 case, keyness' domain. Zero-size groups contribute no cell
and land a zero residual; a table whose cells or docs blocks are not
len(keys) × len(vals) wide is Bad_Count (hand-built tables refuse,
ward_json's rule).
Expected <= 0 cannot occur through cross_table (marginals positive by
construction) but a hand-built table can force it — such cells
contribute nothing, χ²'s rule. Output follows t.keys order.
*/
Cross_Test :: struct {
	key:       string,
	chi2:      f64, // k×2 Pearson statistic, uncorrected
	residuals: []f64, // adjusted residual per group (Haberman)
}

cross_chi2 :: proc(t: ^Cross_Table, a: mem.Allocator) -> ([]Cross_Test, Freq_Err) {
	g := len(t.vals)
	n := len(t.keys)
	if len(t.sizes) != g || len(t.cells) != n * g || len(t.docs) != n * g {
		return {}, .Bad_Count
	}
	// validation first: a refusal after the residuals start allocating
	// would strand them — from here to the return nothing can fail
	for i in 0..<n {
		for j in 0..<g {
			if t.docs[i * g + j] < 0 || t.docs[i * g + j] > t.sizes[j] {
				return {}, .Bad_Count // a doc cell outside its column
			}
		}
	}
	pop := 0
	for s in t.sizes { pop += s }
	if pop < 1 { return {}, .Bad_Count }

	out: [dynamic]Cross_Test = make([dynamic]Cross_Test, 0, n, a)
	for key, i in t.keys {
		row_total := 0
		for j in 0..<g { row_total += t.docs[i * g + j] }
		if row_total < 1 { continue } // nothing present anywhere: no test
		chi := 0.0
		for j in 0..<g {
			chi += cross_cell(t.docs[i * g + j], row_total, t.sizes[j], pop)
			chi += cross_cell(t.sizes[j] - t.docs[i * g + j], row_total, pop - t.sizes[j], pop)
		}
		res := make([]f64, g, a)
		p_row := f64(row_total) / f64(pop)
		for j in 0..<g {
			e := f64(row_total) * f64(t.sizes[j]) / f64(pop)
			den := math.sqrt(e * (1 - p_row) * (1 - f64(t.sizes[j]) / f64(pop)))
			if e <= 0 || den <= 0 {
				res[j] = 0 // a degenerate cell carries no residual signal
				continue
			}
			res[j] = (f64(t.docs[i * g + j]) - e) / den
		}
		append(&out, Cross_Test{key = key, chi2 = chi, residuals = res})
	}
	return out[:], .None
}

// one cell's (O − E)²/E; an expected <= 0 cell contributes nothing
cross_cell :: proc(o, row_total, col_total, pop: int) -> f64 {
	e := f64(row_total) * f64(col_total) / f64(pop)
	if e <= 0 { return 0 }
	d := f64(o) - e
	return d * d / e
}

/*
The whole-table independence statistic: Pearson once over the
keys×groups occurrence matrix — the headline number of a
crosstab. Expected <= 0 contributes nothing; a table with no
occurrences has no statistic and refuses (Bad_Count), as does a cells
block that is not len(keys) × len(vals) wide. Scratch is call-scoped
on the temp allocator — the proc takes no
`a` because it returns a number.
*/
table_chi2 :: proc(t: ^Cross_Table) -> (f64, Freq_Err) {
	g := len(t.vals)
	n := len(t.keys)
	if len(t.sizes) != g || len(t.cells) != n * g { return 0, .Bad_Count }
	colsum := make([]int, g, context.temp_allocator)
	defer mem.free(raw_data(colsum), context.temp_allocator)
	grand := 0
	for i in 0..<n {
		row := t.cells[i * g : i * g + g]
		for j in 0..<g {
			colsum[j] += row[j]
			grand += row[j]
		}
	}
	if grand < 1 { return 0, .Bad_Count }
	chi := 0.0
	for i in 0..<n {
		row := t.cells[i * g : i * g + g]
		rs := 0
		for j in 0..<g { rs += row[j] }
		for j in 0..<g {
			e := f64(rs) * f64(colsum[j]) / f64(grand)
			if e <= 0 { continue }
			d := f64(row[j]) - e
			chi += d * d / e
		}
	}
	return chi, .None
}
