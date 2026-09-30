package gloaming

import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

/*
Corpus statistics over frequency vectors — pure core:math, no external
linear algebra. At the bottom of the file: presence
marginals, association measures, Ward clustering, and power-iteration
coordinates. Everything returns data (tables, coordinates, merge-order
trees); text interchange (dot/mermaid/JSON) is the auxiliary glexport
package's, outside this one. Every pass whose cost scales with corpus
size takes an optional stop-check (true = stop, query_match's
convention), polled at the outer iteration and returning .Interrupted
when it fires — an interactive
host stays responsive. Pure transforms over caller-dimensioned inputs
(the word-key matrix builders here — the dimensions are the caller's)
carry no check: their cost is a dimension the caller chose. The doc_*
passes over the corpus document population (corpus.odin) are
corpus-scale and carry the check.
*/

Assoc_Measure :: enum {
	Jaccard,
	Dice,
	Mutual_Information,
	Chi_Square,
	Fisher_Exact,
	// computed under the same contingency validation:
	Simpson,          // n / min(n_a, n_b) — overlap over the smaller marginal; compensates Jaccard's underestimation between words of very different frequencies
	Chi_Square_Yates, // 2×2 continuity correction: |O−E| − 0.5 floored at 0
	Log_Likelihood,   // G² = 2 Σ O·ln(O/E)
}

Freq_Entry :: struct {
	lemma: string,
	count: int, // occurrences
	docs:  int, // documents containing it
}

/*
Aggregation filters shared by frequency tables, KWIC, and co-occurrence:
values, not dialogs — the host passes them, the library applies them.
*/
Freq_Filter :: struct {
	pos_prefixes: []string, // keep only these POS hierarchy prefixes
	stopwords:    []string, // lemma literals to drop
	min_count:    int,
	use_lemma:    bool, // count by lemma rather than surface
	min_len:      int, // counting key rune length >= min_len; 0/1 = off
}

/*
The count table — extraction filters and counting in one call: a
filtered, deterministically ordered pass over one stream — no
measures here; the association layer below owns those.

`scope` selects the sub-corpus: a token belongs to the scope segment
containing its `start` byte (a straddling token counts exactly once,
for the segment holding its start — H1/H2/H3 selection is the host
passing the right segments). Scope segments may repeat and nest: dedup
is by containment, so a chapter listed twice counts its tokens once.
Empty scope = the whole stream. An inverted scope range is the one
failure, Bad_Scope.

`Freq_Entry.docs` is 1 for present entries — one stream in, one
document out. The true cross-document count is the corpus layer's
(`corpus_freq` fills `docs` with documents holding the key);
this proc keeps the single-stream contract.

Filters apply in order: pos_prefixes (any match keeps, empty =
all), stopwords against the counting key (use_lemma → lemma, else
surface; unknown tokens carry their surface as lemma, so lemma
counting never silently skips them), min_len on the counting key's
rune length, then min_count as an output filter after counting.

Output: count descending, then key ascending by code point — UTF-8
byte order is code-point order, so strings.compare is the
deterministic tiebreak. Bounded by vocabulary
size, not matches; hosts slice top-k. Keys in the result are views
into the tokens, not copies. The optional stop-check polls once per
token; a stop (true) poll returns .Interrupted with no table.

Counting runs by dense row: the POS verdict is a per-token prefix scan
(a per-distinct-POS verdict map costs a hash per token and read slower
than the scan it cached), the key probe touches only POS-surviving
tokens — a rejected token never costs key-map maintenance — and the
key-side clauses (filter_key's) are cached per distinct key, so a
host's stopword list length is paid once per vocabulary, not once per
token.
*/
Freq_Err :: enum {
	None,
	Bad_Scope,
	Bad_Window, // co_occurrence: .Tokens with window < 1; assoc_scores: windows < 1
	Bad_Count, // a count outside its contingency, a negative dissimilarity, a duplicate key
	Bad_Budget, // a tolerance or iteration budget out of range
	Interrupted, // the stop-check fired mid-pass (true = stop)
}

freq_table :: proc(stream: Token_Stream, scope: []Segment,
                   filter: Freq_Filter,
                   a: mem.Allocator,
                   check: proc(user: rawptr) -> bool = nil,
                   user: rawptr = nil) -> ([]Freq_Entry, Freq_Err) {
	for seg in scope {
		if seg.span.start > seg.span.end { return {}, .Bad_Scope }
	}
	scoped := len(scope) > 0

	keys: [dynamic]string = make([dynamic]string, 0, 64, a)
	defer delete(keys)
	counts: [dynamic]int = make([dynamic]int, 0, 64, a)
	defer delete(counts)
	keep: [dynamic]bool = make([dynamic]bool, 0, 64, a)
	defer delete(keep)
	ix := make(map[string]int, a)
	defer delete(ix)

	for tok in stream.tokens {
		if check != nil && check(user) { return {}, .Interrupted }
		if scoped && !token_in_scope(tok.start, stream.doc, scope) { continue }
		// the POS verdict runs before the key probe: a rejected token must
		// not cost key-map maintenance (a per-distinct-POS verdict map read
		// slower than this scan — one short-prefix has_prefix per prefix)
		if len(filter.pos_prefixes) > 0 && !pos_listed(tok.pos, filter.pos_prefixes) {
			continue
		}
		key := filter.use_lemma ? tok.lemma : tok.surface
		row, has := ix[key]
		if !has {
			row = len(keys)
			ix[key] = row
			append(&keys, key)
			append(&counts, 0)
			append(&keep, key_keeps(key, filter))
		}
		if !keep[row] { continue }
		counts[row] += 1
	}

	out: [dynamic]Freq_Entry = make([dynamic]Freq_Entry, 0, len(keys), a)
	for k, i in keys {
		if counts[i] == 0 { continue } // every occurrence was pos-rejected
		append(&out, Freq_Entry{lemma = k, count = counts[i], docs = 1})
	}
	entries := out[:]
	sort_with_buffer(entries, freq_less, a)

	if filter.min_count > 1 {
		kept := 0
		for i in 0..<len(entries) {
			if entries[i].count >= filter.min_count {
				entries[kept] = entries[i]
				kept += 1
			}
		}
		entries = entries[:kept]
	}
	return entries, .None
}

token_in_scope :: proc(start: int, doc: Doc_Id, scope: []Segment) -> bool {
	for seg in scope {
		if seg.span.doc == doc && seg.span.start <= start && start < seg.span.end {
			return true
		}
	}
	return false
}

// `^"名詞,"` convention: any listed prefix matches
pos_listed :: proc(pos: string, prefixes: []string) -> bool {
	for p in prefixes {
		if strings.has_prefix(pos, p) { return true }
	}
	return false
}

stopword :: proc(key: string, stopwords: []string) -> bool {
	for s in stopwords {
		if key == s { return true }
	}
	return false
}

/*
The one token-passes-the-filter test every counting surface applies —
freq_table, the co-occurrence walkers, and the corpus layer — so
every table this package emits describes one population for a given
filter. Returns the counting key (use_lemma → lemma, else surface)
and whether the token counts at all. The count tables run the POS
clause per token (a short-prefix scan) and cache the key-side clauses
per distinct key; the clauses below are the shared source of truth.
*/
filter_key :: proc(tok: Token, filter: Freq_Filter) -> (key: string, keep: bool) {
	if len(filter.pos_prefixes) > 0 && !pos_listed(tok.pos, filter.pos_prefixes) {
		return "", false
	}
	key = filter.use_lemma ? tok.lemma : tok.surface
	if !key_keeps(key, filter) { return "", false }
	return key, true
}

// the filter's key-side clauses: stopword literals, then minimum rune
// length — cached once per distinct key by the count tables
key_keeps :: proc(key: string, filter: Freq_Filter) -> bool {
	if len(filter.stopwords) > 0 && stopword(key, filter.stopwords) { return false }
	if filter.min_len > 1 && utf8.rune_count(key) < filter.min_len { return false }
	return true
}

freq_less :: proc(a, b: ^Freq_Entry) -> bool {
	if a.count != b.count { return a.count > b.count }
	return strings.compare(a.lemma, b.lemma) < 0
}

// buffer merge sort shared by the stats tables: stable, and free of
// core:sort's Interface plumbing (a total comparator makes stability
// moot, the buffer sort is just the one a reviewer can check by hand)
buf_merge_sort :: proc(rows: []$T, tmp: []T, less: proc(x, y: ^T) -> bool) {
	n := len(rows)
	width := 1
	for width < n {
		for lo := 0; lo < n; lo += width * 2 {
			mid := min(lo + width, n)
			hi := min(lo + width * 2, n)
			if mid == hi { continue }
			copy(tmp[lo:hi], rows[lo:hi])
			i, j := lo, mid
			for k := lo; k < hi; k += 1 {
				if i >= mid {
					rows[k] = tmp[j]
					j += 1
				} else if j >= hi {
					rows[k] = tmp[i]
					i += 1
				} else if !less(&tmp[j], &tmp[i]) {
					rows[k] = tmp[i] // left run first on ties: stable
					i += 1
				} else {
					rows[k] = tmp[j]
					j += 1
				}
			}
		}
		width *= 2
	}
}

// the calling convention every table sort wants: a scratch buffer the
// call owns and frees (a plain-slice make has no delete — the dynamic
// is the freeable shape, so no sort buffer outlives its call on any
// allocator)
sort_with_buffer :: proc(rows: []$T, less: proc(x, y: ^T) -> bool, a: mem.Allocator) {
	tmp: [dynamic]T = make([dynamic]T, len(rows), len(rows), a)
	buf_merge_sort(rows, tmp[:], less)
	delete(tmp)
}

/*
The shared lower-bound binary search: the first index whose key is
>= target, over items ascending by that key. The key arrives as a
proc so the loop is written once; "first end strictly past x" is the
same search with target x+1.
*/
lower_bound :: proc(items: []$T, key: proc(item: ^T) -> $K, target: K) -> int {
	lo, hi := 0, len(items)
	for lo < hi {
		mid := (lo + hi) / 2
		if key(&items[mid]) < target { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

/*
Proofreading aggregates: deterministic suspect locators. Segment
cost sums and unknown-run lengths flag regions where tokenization
struggled; notation-variation pairs fall out of (reading, POS) grouping
when lemmas diverge. Hosts and their curators do the judging — but the
enumeration stays here, because curators, human or automated,
reliably overlook notation variation.
*/

Segment_Score :: struct {
	span:        Span,
	cost_sum:    i64,
	tokens:      int, // the normalizer: cost sums scale with length
	unknown_run: int, // longest unknown-word run, in tokens
}

Notation_Pair :: struct {
	reading: string,
	pos:     string,
	lemma_a: string, // the more frequent side (ties: code point)
	count_a: int,
	lemma_b: string,
	count_b: int,
}

/*
segment_scores (the cost-anomaly table): one row per scope segment —
cost summed in i64, the token count, and the longest unknown run.
`scope` selects the outline level to judge; empty scope scores the
stream's own segments, and a stream with no outline scores one
whole-stream row. Nesting is literal: a chapter listed beside its
paragraphs produces both rows — a score is a property of the segment,
not a sub-corpus sum, so freq_table's count-once dedup does not apply.
A token belongs to the segment holding its `start` byte, freq_table's
rule. Cost sums scale with segment length, hence the `tokens`
normalizer; id-less schemas (all-zero costs) still enumerate rows for
the unknown runs. Tokens must be in stream order, ascending start
(the analyzer and store contracts).

Output: cost_sum descending, unknown_run descending, then span
ascending — suspects first, hosts slice. Rows borrow the stream's
spans. Bad_Scope on an inverted segment, like freq_table. The
optional stop-check polls once per token.
*/
segment_scores :: proc(stream: Token_Stream, scope: []Segment,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]Segment_Score, Freq_Err) {
	for seg in scope {
		if seg.span.start > seg.span.end { return {}, .Bad_Scope }
	}
	segs := scope
	if len(segs) == 0 { segs = stream.segments }
	whole: [1]Segment // kind is filler — only the span reaches the output
	if len(segs) == 0 {
		end := 0
		if len(stream.tokens) > 0 { end = stream.tokens[len(stream.tokens) - 1].end }
		whole[0] = {span = {doc = stream.doc, start = 0, end = end}}
		segs = whole[:]
	}

	out: [dynamic]Segment_Score = make([dynamic]Segment_Score, 0, len(segs), a)
	for seg in segs {
		row := Segment_Score{span = seg.span}
		run := 0
		for j := score_seek(stream.tokens, seg.span.start);
		    j < len(stream.tokens) && stream.tokens[j].start < seg.span.end; j += 1 {
			if check != nil && check(user) { delete(out); return {}, .Interrupted }
			tok := &stream.tokens[j]
			row.cost_sum += i64(tok.cost)
			row.tokens += 1
			if tok.kind == .Unknown {
				run += 1
				if run > row.unknown_run { row.unknown_run = run }
			} else {
				run = 0
			}
		}
		append(&out, row)
	}
	entries := out[:]
	sort_with_buffer(entries, score_less, a)
	return entries, .None
}

// first token index with start >= b; tokens ascending by start
score_seek :: proc(tokens: []Token, b: int) -> int {
	return lower_bound(tokens, token_start, b)
}

score_less :: proc(x, y: ^Segment_Score) -> bool {
	if x.cost_sum != y.cost_sum { return x.cost_sum > y.cost_sum }
	if x.unknown_run != y.unknown_run { return x.unknown_run > y.unknown_run }
	if u32(x.span.doc) != u32(y.span.doc) { return u32(x.span.doc) < u32(y.span.doc) }
	if x.span.start != y.span.start { return x.span.start < y.span.start }
	return x.span.end < y.span.end
}

/*
notation_pairs (the notation-variation table): group the stream by
(reading, POS) and enumerate the groups whose lemmas diverge — the
same word spelled two ways — as unordered lemma pairs, the more
frequent side first (ties by code point). The canonical-form
decision — expected/unexpected lists, which form wins — is the
host's table join; lemma_a is only the more frequent side.
Excluded: unknown tokens
(their lemma is the surface by the analyzer's unknown rule) and any
token whose reading is "*" — no phonetic identity, no notation
evidence. `scope` follows freq_table exactly (empty = the whole
stream; a token belongs to the segment holding its start). Counts are
per-stream: hosts aggregate documents by summing counts and
re-pairing, or read one whole-corpus stream from the store.

Output: combined count descending (most evidence first), then
reading, pos, lemma_a, lemma_b ascending — hosts slice. All strings
borrow the tokens. Bad_Scope on an inverted segment. The optional
stop-check polls once per token in the counting pass and once per
emitted group in the pair enumeration.
*/
notation_pairs :: proc(stream: Token_Stream, scope: []Segment,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]Notation_Pair, Freq_Err) {
	for seg in scope {
		if seg.span.start > seg.span.end { return {}, .Bad_Scope }
	}
	scoped := len(scope) > 0

	// one flat count per (reading, POS, lemma), keyed by borrowed
	// views — no key strings are built, so nothing outlives the call
	// on a non-arena caller's allocator, and no nested-map re-stores
	// ride the per-token path
	Group_Key :: struct {
		reading: string,
		pos:     string,
		lemma:   string,
	}
	counts := make(map[Group_Key]int, a)
	defer delete(counts)
	for tok in stream.tokens {
		if check != nil && check(user) { return {}, .Interrupted }
		if tok.kind == .Unknown || tok.reading == "*" { continue }
		if scoped && !token_in_scope(tok.start, stream.doc, scope) { continue }
		counts[{tok.reading, tok.pos, tok.lemma}] += 1
	}

	// the flat rows, sorted into contiguous (reading, POS) runs with
	// each group's variants most-frequent-first — the runs are the
	// groups; the pair enumeration walks them
	rows: [dynamic]Notation_Row = make([dynamic]Notation_Row, 0, len(counts), a)
	defer delete(rows)
	for k, n in counts {
		append(&rows, Notation_Row{
			reading = k.reading, pos = k.pos, lemma = k.lemma, count = n,
		})
	}
	sort_with_buffer(rows[:], notation_group_less, a)

	// the exact pair count over the runs — a group of v variants emits
	// v(v−1)/2 pairs, so the quadratic emission reserves its buffer
	// once instead of growing through it
	total := 0
	lo := 0
	for lo < len(rows) {
		hi := lo + 1
		for hi < len(rows) &&
		    rows[hi].reading == rows[lo].reading && rows[hi].pos == rows[lo].pos {
			hi += 1
		}
		if hi - lo >= 2 { total += (hi - lo) * (hi - lo - 1) / 2 }
		lo = hi
	}

	out: [dynamic]Notation_Pair = make([dynamic]Notation_Pair, 0, total, a)
	lo = 0
	for lo < len(rows) {
		hi := lo + 1
		for hi < len(rows) &&
		    rows[hi].reading == rows[lo].reading && rows[hi].pos == rows[lo].pos {
			hi += 1
		}
		// a group of one variant is no notation evidence
		if hi - lo >= 2 {
			if check != nil && check(user) { delete(out); return {}, .Interrupted }
			for i in lo..<hi - 1 {
				for j in i + 1..<hi {
					append(&out, Notation_Pair{
						reading = rows[i].reading, pos = rows[i].pos,
						lemma_a = rows[i].lemma, count_a = rows[i].count,
						lemma_b = rows[j].lemma, count_b = rows[j].count,
					})
				}
			}
		}
		lo = hi
	}
	entries := out[:]
	sort_with_buffer(entries, pair_less, a)
	return entries, .None
}

Notation_Row :: struct {
	reading: string,
	pos:     string,
	lemma:   string,
	count:   int,
}

// group rows: reading and POS ascending bring one group contiguous,
// then the variants most-frequent-first (ties by code point) — the
// order the pair enumeration reads
notation_group_less :: proc(x, y: ^Notation_Row) -> bool {
	if c := strings.compare(x.reading, y.reading); c != 0 { return c < 0 }
	if c := strings.compare(x.pos, y.pos); c != 0 { return c < 0 }
	if x.count != y.count { return x.count > y.count }
	return strings.compare(x.lemma, y.lemma) < 0
}

Lemma_Count :: struct {
	lemma: string,
	count: int,
}

// variants within one group: count descending, then lemma ascending
lemma_more :: proc(x, y: ^Lemma_Count) -> bool {
	if x.count != y.count { return x.count > y.count }
	return strings.compare(x.lemma, y.lemma) < 0
}

pair_less :: proc(x, y: ^Notation_Pair) -> bool {
	xt := x.count_a + x.count_b
	yt := y.count_a + y.count_b
	if xt != yt { return xt > yt }
	if c := strings.compare(x.reading, y.reading); c != 0 { return c < 0 }
	if c := strings.compare(x.pos, y.pos); c != 0 { return c < 0 }
	if c := strings.compare(x.lemma_a, y.lemma_a); c != 0 { return c < 0 }
	return strings.compare(x.lemma_b, y.lemma_b) < 0
}

/*
Co-occurrence construction: which keys share a window, and how often. A window is either one
segment (scope, else the stream outline, else the whole stream as a
single window — freq_table's rule; a non-empty scope list is deduped by
containment first, so a repeated or nested selection opens one window,
not two) or a tumbling block of `window` filtered tokens. Tokens pass
the shared Freq_Filter first, so windows are in filtered-token
space: a noun-only co-occurrence filter sees noun next to noun with
everything else invisible.

Co-presence is binary per window (a pair counts once however often
either side appears in it — what Jaccard/Dice will need); `max_pairs`
(0 = unbounded) bounds the DISTINCT pairs tracked, skipping new pairs
past the cap while existing ones keep counting — deterministic, but
order-dependent once it bites, and VISIBLE: the second return says
the cap refused a pair (exactly meeting the cap is not truncation —
Code_Result's rule). Pairs are unordered; `a` is the
lexicographically smaller key (UTF-8 byte order is code-point order).

Output: count descending, then a, b ascending — hosts slice top-k.
Keys view the tokens. Bad_Scope on an inverted segment, Bad_Window on
.Tokens with window < 1. The optional stop-check polls once per token
in the filter pass and once per window.
*/
Cooc_Unit :: enum {
	Segments, // one window per scope/outline segment
	Tokens, // tumbling windows of `window` filtered tokens
}

Cooc_Options :: struct {
	filter:    Freq_Filter, // the shared extraction filter
	unit:      Cooc_Unit,
	window:    int, // .Tokens: tokens per window
	max_pairs: int, // distinct pairs tracked, 0 = unbounded
}

Co_Pair :: struct {
	a: string,
	b: string,
	n: int, // windows the two co-occur in
}

co_occurrence :: proc(stream: Token_Stream, scope: []Segment,
                      opts: Cooc_Options,
                      a: mem.Allocator,
                      check: proc(user: rawptr) -> bool = nil,
                      user: rawptr = nil) -> (pairs: []Co_Pair, truncated: bool,
                      err: Freq_Err) {
	for seg in scope {
		if seg.span.start > seg.span.end { return {}, false, .Bad_Scope }
	}
	if opts.unit == .Tokens && opts.window < 1 { return {}, false, .Bad_Window }

	idxs, keys, ferr := cooc_filtered(stream, scope, opts.filter, a, check, user)
	defer delete(idxs)
	defer delete(keys)
	if ferr != .None { return {}, false, ferr }

	// intern the distinct keys once: pairs key on packed ranks (one
	// integer hash per pair), orientation and the final sort ride the
	// ranks, and the per-window dedup reuses epoch stamps on the table
	// instead of a fresh map per window
	tb := cooc_intern(keys[:], a)
	defer cooc_intern_destroy(&tb, a)

	pt := cooc_pair_table_init(opts.max_pairs, a)
	defer cooc_pair_destroy(&pt)
	capped := false // a pair was refused by the cap (the visible cut)

	switch opts.unit {
	case .Segments:
		segs := scope
		if len(segs) == 0 { segs = stream.segments }
		if len(segs) == 0 {
			cooc_window(tb.kid[:], &tb, &pt, opts.max_pairs, &capped, a)
		} else {
			if len(scope) > 0 {
				segs = scope_windows(scope, a)
				defer delete(segs, a)
			}
			for seg in segs {
				if check != nil && check(user) { return {}, false, .Interrupted }
				if seg.span.doc != stream.doc { continue }
				lo := cooc_seek(stream.tokens, idxs[:], seg.span.start)
				hi := cooc_seek(stream.tokens, idxs[:], seg.span.end)
				cooc_window(tb.kid[lo:hi], &tb, &pt, opts.max_pairs, &capped, a)
			}
		}
	case .Tokens:
		for lo := 0; lo < len(tb.kid); lo += opts.window {
			if check != nil && check(user) { return {}, false, .Interrupted }
			hi := min(lo + opts.window, len(tb.kid))
			cooc_window(tb.kid[lo:hi], &tb, &pt, opts.max_pairs, &capped, a)
		}
	}

	// materialize by rank, sort on integers — the same total order the
	// string comparator defines: n descending, then the lexicographically
	// smaller side, then the larger (rank order IS string order)
	ranked: [dynamic]Cooc_Rank = make([dynamic]Cooc_Rank, 0, pt.used, a)
	defer delete(ranked)
	for i in 0..<len(pt.keys) {
		if pt.keys[i] == 0 { continue }
		pk := pt.keys[i]
		append(&ranked, Cooc_Rank{
			n  = int(pt.counts[i]),
			lo = int(pk >> 32),
			hi = int(pk & 0xFFFF_FFFF),
		})
	}
	sort_with_buffer(ranked[:], cooc_rank_less, a)
	out := make([]Co_Pair, pt.used, a)
	for r, i in ranked {
		out[i] = {a = tb.rank_to_key[r.lo], b = tb.rank_to_key[r.hi], n = r.n}
	}
	return out, capped, .None
}

cooc_pair_table_init :: proc(max_pairs: int, a: mem.Allocator) -> Cooc_Pair_Table {
	pt: Cooc_Pair_Table
	hint := max_pairs
	if hint < 4096 { hint = 4096 } // the unbounded dial still starts roomy
	cooc_pair_init(&pt, hint, a)
	return pt
}

/*
The interned key space both window walkers share: filtered positions
carry dense key ids, ids carry their string-order rank (rank order is
strings.compare order — UTF-8 byte order is code-point order), and the
window dedup reuses one epoch-stamped seen table instead of allocating
per window. All of it is scratch owned by one co_occurrence /
cooc_presence call; `rank_to_key` strings view the token stream.
*/
Cooc_Table :: struct {
	kid:         [dynamic]int, // filtered position → key id
	rank:        []int, // key id → string-order rank
	rank_to_key: []string, // rank → key (borrowed)
	seen_win:    []int, // key id → epoch of the window that last held it
	epoch:       int,
	dk:          [dynamic]int, // one window's distinct ids, first-appearance order
}

Cooc_Key :: struct {
	s:  string,
	id: int,
}

cooc_key_less :: proc(x, y: ^Cooc_Key) -> bool {
	return strings.compare(x.s, y.s) < 0
}

Cooc_Rank :: struct {
	n:  int,
	lo: int, // the lexicographically smaller side's rank
	hi: int,
}

cooc_rank_less :: proc(x, y: ^Cooc_Rank) -> bool {
	if x.n != y.n { return x.n > y.n }
	if x.lo != y.lo { return x.lo < y.lo }
	return x.hi < y.hi
}

cooc_intern :: proc(keys: []string, a: mem.Allocator) -> Cooc_Table {
	tb: Cooc_Table
	key_id := make(map[string]int, a)
	defer delete(key_id)
	uniq: [dynamic]string = make([dynamic]string, 0, 0, a) // id → key
	defer delete(uniq)
	tb.kid = make([dynamic]int, 0, len(keys), a)
	for k in keys {
		id, h := key_id[k]
		if !h {
			id = len(uniq)
			key_id[k] = id
			append(&uniq, k)
		}
		append(&tb.kid, id)
	}
	ord: [dynamic]Cooc_Key = make([dynamic]Cooc_Key, 0, len(uniq), a)
	defer delete(ord)
	for s, id in uniq { append(&ord, Cooc_Key{s = s, id = id}) }
	sort_with_buffer(ord[:], cooc_key_less, a)
	tb.rank = make([]int, len(ord), a)
	tb.rank_to_key = make([]string, len(ord), a)
	for e, r in ord {
		tb.rank[e.id] = r
		tb.rank_to_key[r] = e.s
	}
	tb.seen_win = make([]int, len(ord), a) // zero — epochs start at 1
	tb.dk = make([dynamic]int, 0, 0, a)
	return tb
}

cooc_intern_destroy :: proc(tb: ^Cooc_Table, a: mem.Allocator) {
	delete(tb.kid)
	delete(tb.rank, a)
	delete(tb.rank_to_key, a)
	delete(tb.seen_win, a)
	delete(tb.dk)
}

/*
The pair table: open addressing on the packed rank key, linear probing,
multiply-shift hash, load factor 1/2. A novel-scale call probes it four
million-plus times (the enumeration alone runs at
920M pairs/s; the generic map's per-op cost was the whole stage), so
the table is the one structure here that earns its own shape. Key 0 is
the empty sentinel — a real pair packs two DISTINCT ranks, so it is
never zero.
*/
Cooc_Pair_Table :: struct {
	keys:   [dynamic]u64,
	counts: [dynamic]i32,
	mask:   u64,
	bits:   int, // log2 of the slot count
	used:   int, // slots holding a pair — the distinct-pairs count
}

cooc_pair_init :: proc(t: ^Cooc_Pair_Table, hint: int, a: mem.Allocator) {
	t.bits = 4
	for (1 << u32(t.bits)) < hint * 2 { t.bits += 1 }
	cap := 1 << u32(t.bits)
	t.keys = make([dynamic]u64, cap, cap, a) // make zeroes — 0 is empty
	t.counts = make([dynamic]i32, cap, cap, a)
	t.mask = u64(cap - 1)
	t.used = 0
}

cooc_pair_destroy :: proc(t: ^Cooc_Pair_Table) {
	delete(t.keys)
	delete(t.counts)
}

cooc_pair_slot :: proc(t: ^Cooc_Pair_Table, pk: u64) -> (slot: int, found: bool) {
	slot = int(((pk * 0x9E3779B97F4A7C15) >> u64(64 - t.bits)) & t.mask)
	for t.keys[slot] != 0 {
		if t.keys[slot] == pk { return slot, true }
		slot = (slot + 1) & int(t.mask)
	}
	return slot, false
}

cooc_pair_grow :: proc(t: ^Cooc_Pair_Table, a: mem.Allocator) {
	old_keys := t.keys[:]
	old_counts := t.counts[:]
	t.bits += 1
	cap := 1 << u32(t.bits)
	t.keys = make([dynamic]u64, cap, cap, a)
	t.counts = make([dynamic]i32, cap, cap, a)
	t.mask = u64(cap - 1)
	for k, i in old_keys {
		if k == 0 { continue }
		slot, _ := cooc_pair_slot(t, k)
		t.keys[slot] = k
		t.counts[slot] = old_counts[i]
	}
	delete(old_keys)
	delete(old_counts)
}

// one window: distinct keys in first-appearance order (the order is
// observable — the cap refuses pairs in enumeration sequence), every
// unordered pair counted once (binary co-presence). A brand-new pair at
// a full cap is refused before it is ever inserted, so a refused pair
// allocates nothing; existing pairs keep counting to the end.
cooc_window :: proc(ids: []int, tb: ^Cooc_Table, pt: ^Cooc_Pair_Table,
                    max_pairs: int, capped: ^bool, a: mem.Allocator) {
	if len(ids) < 2 { return }
	tb.epoch += 1
	resize(&tb.dk, 0)
	for id in ids {
		if tb.seen_win[id] == tb.epoch { continue }
		tb.seen_win[id] = tb.epoch
		append(&tb.dk, id)
	}
	for i in 0..<len(tb.dk) - 1 {
		ri := tb.rank[tb.dk[i]]
		for j in i + 1..<len(tb.dk) {
			rj := tb.rank[tb.dk[j]]
			lo, hi := ri, rj
			if lo > hi { lo, hi = hi, lo }
			pk := (u64(lo) << 32) | u64(hi)
			slot, found := cooc_pair_slot(pt, pk)
			if !found {
				if max_pairs > 0 && pt.used >= max_pairs {
					capped^ = true
					continue
				}
				pt.keys[slot] = pk
				pt.counts[slot] = 1
				pt.used += 1
				if pt.used * 2 > 1 << u32(pt.bits) { cooc_pair_grow(pt, a) }
			} else {
				pt.counts[slot] += 1
			}
		}
	}
}

// first filtered position whose token starts at or after `off` — the
// lower_bound search over a projection (the key needs both slices,
// which a proc value cannot capture), so the loop stays here
cooc_seek :: proc(tokens: []Token, idxs: []int, off: int) -> int {
	lo, hi := 0, len(idxs)
	for lo < hi {
		mid := (lo + hi) / 2
		if tokens[idxs[mid]].start < off { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

/*
The scope list's window population, deduped by containment — freq's
rule carried onto windows: a scope list may repeat a segment
or list a segment beside one containing it, and every such duplicate
would open its own window, re-counting its pairs and inflating
`windows`. Only maximal segments open windows: a segment contained in
another listed one is dropped, and of exact duplicates the first is
kept. The stream outline is not passed here — it is flat by the host
contract.

The containment test is one sorted sweep, not the pairwise O(s²)
probe: order by (doc, start asc, end desc), and a segment survives
iff its end passes the running max end of everything before it in
its doc — every earlier same-doc segment starts at or before it, so
passing the max means nothing contains it, and the ix tiebreak keeps
the first of exact duplicates. The kept set emits in input order:
window order is the cap discipline's contract downstream.
*/
Scope_Order :: struct {
	doc:   Doc_Id,
	start: int,
	end:   int,
	ix:    int,
}

scope_order_less :: proc(x, y: ^Scope_Order) -> bool {
	if u32(x.doc) != u32(y.doc) { return u32(x.doc) < u32(y.doc) }
	if x.start != y.start { return x.start < y.start }
	if x.end != y.end { return x.end > y.end }
	return x.ix < y.ix
}

scope_windows :: proc(scope: []Segment, a: mem.Allocator) -> []Segment {
	out: [dynamic]Segment = make([dynamic]Segment, 0, len(scope), a)
	if len(scope) == 0 { return out[:] }

	ord: [dynamic]Scope_Order = make([dynamic]Scope_Order, len(scope), len(scope), a)
	defer delete(ord)
	for s, i in scope { ord[i] = {doc = s.span.doc, start = s.span.start, end = s.span.end, ix = i} }
	sort_with_buffer(ord[:], scope_order_less, a)

	keep: [dynamic]bool = make([dynamic]bool, len(scope), len(scope), a)
	defer delete(keep)
	max_end := -1
	cur_doc := ord[0].doc
	for o in ord {
		if o.doc != cur_doc {
			cur_doc = o.doc
			max_end = -1
		}
		if o.end > max_end {
			max_end = o.end
			keep[o.ix] = true
		}
	}
	for s, i in scope {
		if keep[i] { append(&out, s) }
	}
	return out[:] // caller owns (freq_table's entries discipline)
}

/*
Presence marginals: how many windows each key appears in, binary
per window — the exact counterpart of co_occurrence's binary pairs,
and the marginal table the association measures need. A row-sum of the
pair table is NOT this (a window where a key met three partners sums
it three times); presence counts the window once, which is what makes
every 2×2 contingency below consistent. Window enumeration mirrors
co_occurrence exactly: the same filter, the same .Segments seek (scope
segments, else the stream outline, else the whole stream as one
window; off-doc scope segments are skipped), the same tumbling
.Tokens blocks — so pairs and marginals always describe one
population, and `windows` is that population's size (empty windows
included: a window with nothing in it is still "neither side").

Output: window count descending, then key ascending — freq_table's
order. Keys view the tokens. Bad_Scope / Bad_Window as co_occurrence.
The optional stop-check polls once per token in the filter pass and
once per window.
*/

Cooc_Presence :: struct {
	keys:    []Freq_Entry, // count = windows holding the key
	windows: int, // windows in the population (pairs and marginals share it)
}

cooc_presence :: proc(stream: Token_Stream, scope: []Segment,
                      opts: Cooc_Options,
                      a: mem.Allocator,
                      check: proc(user: rawptr) -> bool = nil,
                      user: rawptr = nil) -> (Cooc_Presence, Freq_Err) {
	for seg in scope {
		if seg.span.start > seg.span.end { return {}, .Bad_Scope }
	}
	if opts.unit == .Tokens && opts.window < 1 { return {}, .Bad_Window }

	idxs, keys, ferr := cooc_filtered(stream, scope, opts.filter, a, check, user)
	defer delete(idxs)
	defer delete(keys)
	if ferr != .None { return {}, ferr }

	tb := cooc_intern(keys[:], a)
	defer cooc_intern_destroy(&tb, a)
	// key id → windows holding it: the ids are dense over the interned
	// vocabulary, so the counter is an id-indexed array, not a map —
	// presence_window's epoch stamps do the per-window dedup
	counts := make([]int, len(tb.rank), a)
	defer if len(counts) > 0 { mem.free(raw_data(counts), a) }
	windows := 0

	switch opts.unit {
	case .Segments:
		segs := scope
		if len(segs) == 0 { segs = stream.segments }
		if len(segs) == 0 {
			windows = 1
			presence_window(tb.kid[:], &tb, counts)
		} else {
			if len(scope) > 0 {
				segs = scope_windows(scope, a)
				defer delete(segs, a)
			}
			for seg in segs {
				if check != nil && check(user) { return {}, .Interrupted }
				if seg.span.doc != stream.doc { continue }
				windows += 1
				lo := cooc_seek(stream.tokens, idxs[:], seg.span.start)
				hi := cooc_seek(stream.tokens, idxs[:], seg.span.end)
				presence_window(tb.kid[lo:hi], &tb, counts)
			}
		}
	case .Tokens:
		for lo := 0; lo < len(tb.kid); lo += opts.window {
			if check != nil && check(user) { return {}, .Interrupted }
			windows += 1
			hi := min(lo + opts.window, len(tb.kid))
			presence_window(tb.kid[lo:hi], &tb, counts)
		}
	}

	// freq's order on ranks (count descending, key ascending — rank order
	// is string order), then the strings view the stream
	rows: [dynamic]Pres_Row = make([dynamic]Pres_Row, 0, len(tb.rank), a)
	defer delete(rows)
	for n, id in counts { // slice iteration binds value-then-index
		if n == 0 { continue } // never present in a counted window
		append(&rows, Pres_Row{n = n, r = tb.rank[id]})
	}
	sort_with_buffer(rows[:], pres_row_less, a)
	out := make([]Freq_Entry, len(rows), a)
	for r, i in rows {
		out[i] = Freq_Entry{lemma = tb.rank_to_key[r.r], count = r.n, docs = 1}
	}
	return Cooc_Presence{keys = out, windows = windows}, .None
}

Pres_Row :: struct {
	n: int,
	r: int, // the key's rank — rank order is string order
}

pres_row_less :: proc(x, y: ^Pres_Row) -> bool {
	if x.n != y.n { return x.n > y.n }
	return x.r < y.r
}

// one window's distinct keys, each counted once — the epoch stamps do
// the dedup, the dense ids do the counting
presence_window :: proc(ids: []int, tb: ^Cooc_Table, counts: []int) {
	tb.epoch += 1
	for id in ids {
		if tb.seen_win[id] == tb.epoch { continue }
		tb.seen_win[id] = tb.epoch
		counts[id] += 1
	}
}

// the filtered token sequence both window walkers run over
cooc_filtered :: proc(stream: Token_Stream, scope: []Segment,
                      filter: Freq_Filter,
                      a: mem.Allocator,
                      check: proc(user: rawptr) -> bool, user: rawptr) -> (idxs: [dynamic]int, keys: [dynamic]string,
	err: Freq_Err) {
	idxs = make([dynamic]int, 0, len(stream.tokens), a)
	keys = make([dynamic]string, 0, len(stream.tokens), a)
	scoped := len(scope) > 0
	for tok, i in stream.tokens {
		if check != nil && check(user) { return idxs, keys, .Interrupted }
		if scoped && !token_in_scope(tok.start, stream.doc, scope) { continue }
		key, keep := filter_key(tok, filter)
		if !keep { continue }
		append(&idxs, i)
		append(&keys, key)
	}
	return idxs, keys, .None
}

/*
Association measures: Jaccard, Dice, mutual
information, chi-square, Fisher's exact p. Each pair is one 2×2
contingency over the window population: n windows holding both sides,
marg[a] / marg[b] windows holding each (cooc_presence's binary counts
— pass the presence table co_occurrence's pairs came from, and the two
describe one population). `windows` < 1 is Bad_Window; a count that
cannot exist in that contingency (n above a marginal, a marginal above
the population, a sum overshooting it) is Bad_Count, as is a pair key
missing from marg or a duplicate marg key.

assoc_scores emits every pair with its marginals and value, strongest
first: value descending, except Fisher_Exact whose p sorts ascending
(smaller p, stronger association); ties by a, then b, code-point
order. The input pairs are the distinct unordered pairs co_occurrence
emits — duplicates would double-count nothing here (marginals come
from marg), but they would double-emit rows. The optional stop-check
polls once per pair.
*/

Assoc_Score :: struct {
	a:     string,
	b:     string,
	n:     int, // shared windows
	na:    int, // windows holding a (marg's count)
	nb:    int, // windows holding b
	value: f64,
}

/*
The string-boundary procs' shared join: the caller's table — marginals,
the chosen key list — becomes sorted Key_Row rows, and a pair side
resolves by binary search over contiguous rows. Pair strings are the
honest interchange (pairs cross the API as data, not as ranks); the
join rebuilds the dense form over exactly the key universe the call
names, one sort per call replacing the per-pair hash probe, and
duplicate keys fall out of the sort's adjacency instead of a
hand-rolled probe loop per proc.
*/
Key_Row :: struct {
	key: string,
	val: int,
}

key_row_less :: proc(x, y: ^Key_Row) -> bool {
	return strings.compare(x.key, y.key) < 0
}

// the row holding `k`, or -1 — one binary search over the sorted rows
key_row_find :: proc(rows: []Key_Row, k: string) -> int {
	lo, hi := 0, len(rows)
	for lo < hi {
		mid := (lo + hi) / 2
		if strings.compare(rows[mid].key, k) < 0 { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(rows) && strings.compare(rows[lo].key, k) == 0 { return lo }
	return -1
}

// adjacent equal keys after the sort — the duplicate refusal three
// procs share
key_row_dups :: proc(rows: []Key_Row) -> bool {
	for i in 1..<len(rows) {
		if strings.compare(rows[i - 1].key, rows[i].key) == 0 { return true }
	}
	return false
}

assoc_scores :: proc(pairs: []Co_Pair, marg: []Freq_Entry, windows: int,
                     m: Assoc_Measure,
                     a: mem.Allocator,
                     check: proc(user: rawptr) -> bool = nil,
                     user: rawptr = nil) -> ([]Assoc_Score, Freq_Err) {
	if windows < 1 { return {}, .Bad_Window }
	rows: [dynamic]Key_Row = make([dynamic]Key_Row, len(marg), len(marg), a)
	defer delete(rows)
	for e, i in marg {
		if e.count < 1 || e.count > windows { return {}, .Bad_Count }
		rows[i] = {key = e.lemma, val = e.count}
	}
	sort_with_buffer(rows[:], key_row_less, a)
	if key_row_dups(rows[:]) { return {}, .Bad_Count }

	out: [dynamic]Assoc_Score = make([dynamic]Assoc_Score, 0, len(pairs), a)
	for p in pairs {
		if check != nil && check(user) { delete(out); return {}, .Interrupted }
		ra := key_row_find(rows[:], p.a)
		rb := key_row_find(rows[:], p.b)
		if ra < 0 || rb < 0 { delete(out); return {}, .Bad_Count }
		na, nb := rows[ra].val, rows[rb].val
		v, verr := assoc_value(m, p.n, na, nb, windows)
		if verr != .None { delete(out); return {}, verr }
		append(&out, Assoc_Score{a = p.a, b = p.b, n = p.n, na = na, nb = nb, value = v})
	}
	entries := out[:]
	sort_with_buffer(entries, m == .Fisher_Exact ? assoc_less_p : assoc_less_v, a)
	return entries, .None
}

assoc_less_v :: proc(x, y: ^Assoc_Score) -> bool {
	if x.value != y.value { return x.value > y.value }
	if c := strings.compare(x.a, y.a); c != 0 { return c < 0 }
	return strings.compare(x.b, y.b) < 0
}

// Fisher: smaller p is stronger, so the sort flips
assoc_less_p :: proc(x, y: ^Assoc_Score) -> bool {
	if x.value != y.value { return x.value < y.value }
	if c := strings.compare(x.a, y.a); c != 0 { return c < 0 }
	return strings.compare(x.b, y.b) < 0
}

/*
The single-pair measure, public because its symmetries and reference
values are the easiest to pin directly: it is a pure function of the
contingency (n, n_a, n_b, windows) with n_a, n_b read symmetrically —
every measure is invariant under n_a ↔ n_b. Jaccard and Dice are set
ratios on the binary window sets; Simpson is the overlap over the
smaller marginal; MI is log2 of the observed/expected ratio;
chi-square sums (O−E)²/E over all four cells (a cell whose expected
count is structurally zero contributes nothing — its observed count is
zero too when the marginals are consistent), Yates applies the 2×2
continuity correction |O−E| − 0.5 floored at 0 before squaring, and
the log-likelihood ratio G² is 2 Σ O·ln(O/E) with 0·ln 0 = 0; Fisher's
exact is the one-sided upper-tail hypergeometric p.
*/
assoc_value :: proc(m: Assoc_Measure, n, n_a, n_b, windows: int) -> (f64, Freq_Err) {
	if windows < 1 || n < 1 || n > n_a || n > n_b ||
	   n_a > windows || n_b > windows || n_a + n_b - n > windows {
		return 0, .Bad_Count
	}
	fn_, fa, fb, fw := f64(n), f64(n_a), f64(n_b), f64(windows)
	switch m {
	case .Jaccard:
		return fn_ / (fa + fb - fn_), .None
	case .Dice:
		return 2 * fn_ / (fa + fb), .None
	case .Simpson:
		return fn_ / math.min(fa, fb), .None
	case .Mutual_Information:
		return math.log2(fw * fn_ / (fa * fb)), .None
	case .Chi_Square:
		chi, _, _ := cont_2x2(n, n_a, n_b, windows)
		return chi, .None
	case .Chi_Square_Yates:
		_, yates, _ := cont_2x2(n, n_a, n_b, windows)
		return yates, .None
	case .Log_Likelihood:
		_, _, g2 := cont_2x2(n, n_a, n_b, windows)
		return g2, .None
	case .Fisher_Exact:
		return fisher_tail(n, n_a, n_b, windows), .None
	}
	return 0, .Bad_Count // an out-of-range measure value refuses
}

/*
The 2×2 test statistics assoc_value and keyness_scores share: observed
and expected from (n, n_a, n_b, windows) — the same contingency
keyness maps its cells onto. n may be zero here (a key one population
never holds is a keyness row, not a refusal); assoc_value applies its
own n >= 1 pair gate before arriving. chi is Pearson's sum, yates the
same with |O−E| − 0.5 floored at 0 (every contingency here is 2×2, so
the correction is always defined), g2 the log-likelihood ratio with
0·ln 0 = 0 and an expected <= 0 cell contributing nothing (χ²'s rule).
*/
cont_2x2 :: proc(n, n_a, n_b, windows: int) -> (chi: f64, yates: f64, g2: f64) {
	obs := [4]f64{
		f64(n),
		f64(n_a - n),
		f64(n_b - n),
		f64(windows - n_a - n_b + n),
	}
	expt := [4]f64{
		f64(n_a) * f64(n_b) / f64(windows),
		f64(n_a) * f64(windows - n_b) / f64(windows),
		f64(n_b) * f64(windows - n_a) / f64(windows),
		f64(windows - n_a) * f64(windows - n_b) / f64(windows),
	}
	for i in 0..<4 {
		if expt[i] <= 0 { continue }
		d := obs[i] - expt[i]
		chi += d * d / expt[i]
		ay := math.abs(d) - 0.5
		if ay < 0 { ay = 0 }
		yates += ay * ay / expt[i]
		if obs[i] > 0 {
			g2 += 2 * obs[i] * math.ln(obs[i] / expt[i])
		}
	}
	return chi, yates, g2
}

/*
Fisher's exact one-sided p: P(X >= n) for X hypergeometric over the
2×2, in log space through core:math's lgamma. One lgamma triple starts the tail's first term;
every later term is the previous times a rational in k (the ratios
strictly decrease), so the loop is multiplication and stops once a
term is negligible against the running sum — the remainder is under
double precision. The clamp at 1.0 only ever trims rounding drift.
Symmetric in (n_a, n_b), the hypergeometric identity. Extreme
contingencies underflow: the strongest real-bench pair's p is far
below the f64 range and comes back 0.0 — the sort still puts it
first; hosts wanting magnitudes take logs of the contingency
themselves.
*/
fisher_tail :: proc(n, n_a, n_b, windows: int) -> f64 {
	lchoose :: proc(nn, kk: int) -> f64 {
		lnn, _ := math.lgamma(f64(nn + 1))
		lk, _ := math.lgamma(f64(kk + 1))
		lm, _ := math.lgamma(f64(nn - kk + 1))
		return lnn - lk - lm
	}
	t := math.exp(lchoose(n_b, n) + lchoose(windows - n_b, n_a - n) -
		lchoose(windows, n_a))
	p := t
	kmax := min(n_a, n_b)
	for k := n; k < kmax; k += 1 {
		r := f64((n_b - k) * (n_a - k)) /
			f64((k + 1) * (windows - n_a - n_b + k + 1))
		t *= r
		p += t
		if r < 1 && t < 1e-18 * p { break }
	}
	if p > 1 { p = 1 }
	return p
}

/*
Keyness — words characteristic
of a target population against a reference, one 2×2 per key,

              key +      key −
    in T        a          b        a + b = |T|
    in R        c          d        c + d = |R|

Inputs are count tables the library already produces: corpus_freq per
group for the .Docs basis (cells from Freq_Entry.docs, pops =
documents — the doc-condition framing), freq_table totals for .Tokens
(cells from count, pops = token counts — the classic Dunning framing).
Per-value catalogues and per-cluster words are this proc called once
per group with the rest of the corpus as reference — composition, not
new API. Pure function of two tables: no store dependency, no state.

A duplicate key within one table, a cell above its population, or a
population < 1 is Bad_Count (assoc_scores' rules, applied to the two
marginals). Every entry carries its cells — hosts render counts beside
scores, and the value is reproducible from the row. Ordering, pinned:
strongest first, key ascending as the tiebreak — Differential, Lift,
Jaccard, Ochiai, χ² (both), G² descending; Fisher's p ascending.
Negative Differential rows are valid (the avoidance side) and tail the
table — the reversed reading is the same table read bottom-up.
Degenerate pins: Lift with p_r = 0 is +Inf (the word exists only in
the target — the most characteristic case; it sorts first and
glexport's fmt_f6 renders it null); Lift with p_t = 0 is 0. Bounded by the union
vocabulary of the two tables — count-table shaped, hosts slice top-k.
The test statistics (χ², Yates, Fisher, G²) run through the same 2×2
core as assoc_value, with ZERO cells allowed: a key one population
never holds is a row here, where a pair that never shares a window is
not a pair there — assoc_value's n >= 1 gate is a pair-table rule,
not a contingency rule. The optional stop-check polls once per key.
*/

Key_Measure :: enum {
	Differential, // p_t − p_r
	Lift, // p_t / p_r
	Jaccard, // a / (a + b + c)
	Ochiai, // a / sqrt((a+b)(a+c)) — cosine on binary sets
	Chi_Square,
	Chi_Square_Yates,
	Fisher_Exact,
	Log_Likelihood,
}

Keyness_Basis :: enum {
	Docs, // cells from Freq_Entry.docs; pops = documents
	Tokens, // cells from Freq_Entry.count; pops = token counts
}

Keyness_Options :: struct {
	m:     Key_Measure,
	basis: Keyness_Basis,
}

Key_Entry :: struct {
	key:   string,
	value: f64,
	a:     int, // the cells — evidence ships with every score
	b:     int,
	c:     int,
	d:     int,
}

// cells are 1..pop on the chosen basis — a table row occurs, so its
// cell is at least one (the doc_matrix df rule). A zero cell is the
// 0/0 Ochiai/Jaccard shape: it refuses like any other population
// violation rather than emitting NaN.
keyness_scores :: proc(target: []Freq_Entry, target_pop: int,
                       ref: []Freq_Entry, ref_pop: int,
                       opts: Keyness_Options,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]Key_Entry, Freq_Err) {
	if target_pop < 1 || ref_pop < 1 { return {}, .Bad_Count }
	tk := make(map[string]int, a)
	defer delete(tk)
	for e in target {
		cell := keyness_cell(e, opts.basis)
		if cell < 1 || cell > target_pop { return {}, .Bad_Count }
		if _, dup := tk[e.lemma]; dup { return {}, .Bad_Count }
		tk[e.lemma] = cell
	}
	rk := make(map[string]int, a)
	defer delete(rk)
	for e in ref {
		cell := keyness_cell(e, opts.basis)
		if cell < 1 || cell > ref_pop { return {}, .Bad_Count }
		if _, dup := rk[e.lemma]; dup { return {}, .Bad_Count }
		rk[e.lemma] = cell
	}

	uni := make(map[string]bool, a)
	defer delete(uni)
	for k in tk { uni[k] = true }
	for k in rk { uni[k] = true }

	out: [dynamic]Key_Entry = make([dynamic]Key_Entry, 0, len(uni), a)
	for k in uni {
		if check != nil && check(user) { delete(out); return {}, .Interrupted }
		ca, _ := tk[k]
		cc, _ := rk[k]
		b := target_pop - ca
		d := ref_pop - cc
		v, verr := key_value(opts.m, ca, b, cc, d)
		if verr != .None { delete(out); return {}, verr }
		append(&out, Key_Entry{key = k, value = v, a = ca, b = b, c = cc, d = d})
	}
	entries := out[:]
	sort_with_buffer(entries, opts.m == .Fisher_Exact ? key_less_p : key_less_v, a)
	return entries, .None
}

keyness_cell :: proc(e: Freq_Entry, basis: Keyness_Basis) -> int {
	return basis == .Docs ? e.docs : e.count
}

// one key's 2×2: the cells carry the contingency, the marginals the
// populations (a + b and c + d) — the association engine's
// (n, n_a, n_b, windows) after the mapping n = a, n_a = a+b, n_b = a+c
key_value :: proc(m: Key_Measure, a, b, c, d: int) -> (f64, Freq_Err) {
	pt := f64(a) / f64(a + b)
	pr := f64(c) / f64(c + d)
	switch m {
	case .Differential:
		return pt - pr, .None
	case .Lift:
		if pr == 0 { return 1.0 / pr, .None } // pr == 0: +Inf — target-only
		return pt / pr, .None
	case .Jaccard:
		return f64(a) / f64(a + b + c), .None
	case .Ochiai:
		return f64(a) / math.sqrt(f64(a + b) * f64(a + c)), .None
	case .Chi_Square:
		chi, _, _ := cont_2x2(a, a + b, a + c, a + b + c + d)
		return chi, .None
	case .Chi_Square_Yates:
		_, yates, _ := cont_2x2(a, a + b, a + c, a + b + c + d)
		return yates, .None
	case .Log_Likelihood:
		_, _, g2 := cont_2x2(a, a + b, a + c, a + b + c + d)
		return g2, .None
	case .Fisher_Exact:
		return fisher_tail(a, a + b, a + c, a + b + c + d), .None
	}
	return 0, .Bad_Count
}

key_less_v :: proc(x, y: ^Key_Entry) -> bool {
	if x.value != y.value { return x.value > y.value }
	return strings.compare(x.key, y.key) < 0
}

// Fisher: smaller p is stronger, so the sort flips (assoc_less_p's rule)
key_less_p :: proc(x, y: ^Key_Entry) -> bool {
	if x.value != y.value { return x.value < y.value }
	return strings.compare(x.key, y.key) < 0
}

/*
KWIC collocation: the hit rows ARE the window population —
each Kwic_Row's materialized context (left + right, the center's whole
token range excluded so a multi-token match is not its own collocate)
is that row's neighbor set, binary per row (presence_window's rule: a
neighbor appearing twice in one context counts once). `windows` =
len(rows) — a row with nothing in its context is still "neither
side". The ±N dial is kwic's left_n/right_n, not a parameter here: the
collocation window is whatever the rows materialized — the common
±5 window is kwic(…, 5, 5, …). `filter` is the shared Freq_Filter — POS-restricted
collocates are the parameter, not a variant proc.

Rows must come from one stream (the `stream` param's tokens index the
spans): a row whose spans fall outside it — wrong doc, negative, past
the last token — is Bad_Count, the ward_json-class input refusal, not
a silent skip. Scoring is the host's single-pair loop through
assoc_value: n = the presence count, n_a = len(rows), n_b / windows
from a reference population the host supplies (cooc_presence over the
same corpus and unit — a reference whose windows cover the row
contexts, e.g. the same colloc table over every-token rows, keeps the
contingency realizable). Output: freq_table's order; keys view the
tokens. Call-scoped, stateless. The optional stop-check polls once
per row.
*/
kwic_colloc :: proc(rows: []Kwic_Row, stream: Token_Stream,
                    filter: Freq_Filter,
                    a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil,
                    user: rawptr = nil) -> (Cooc_Presence, Freq_Err) {
	end := 0
	if len(stream.tokens) > 0 { end = stream.tokens[len(stream.tokens) - 1].end }
	for r in rows {
		sides := [3]Span{r.left, r.center, r.right}
		for s in sides {
			if s.doc != stream.doc || s.start < 0 || s.end > end || s.start > s.end {
				return {}, .Bad_Count
			}
		}
	}

	counts: [dynamic]int = make([dynamic]int, 0, 64, a)
	defer delete(counts)
	keys: [dynamic]string = make([dynamic]string, 0, 64, a)
	defer delete(keys)
	keep: [dynamic]bool = make([dynamic]bool, 0, 64, a)
	defer delete(keep)
	// the row that last counted the key — one int per distinct key
	// instead of a cleared-per-row seen map (presence_window's epoch
	// stamp, row-index form)
	stamp: [dynamic]int = make([dynamic]int, 0, 64, a)
	defer delete(stamp)
	ix := make(map[string]int, a)
	defer delete(ix)

	for r, ri in rows {
		if check != nil && check(user) { return {}, .Interrupted }
		epoch := ri + 1
		for side in 0..<2 {
			s := side == 0 ? r.left : r.right
			if s.start == s.end { continue }
			for i := colloc_seek(stream.tokens, s.start);
			    i < len(stream.tokens) && stream.tokens[i].start < s.end; i += 1 {
				tok := stream.tokens[i]
				if tok.end > r.center.start && tok.start < r.center.end { continue }
				// freq_table's order: the POS scan precedes the key probe,
				// so a rejected token never costs key-map maintenance
				if len(filter.pos_prefixes) > 0 && !pos_listed(tok.pos, filter.pos_prefixes) {
					continue
				}
				key := filter.use_lemma ? tok.lemma : tok.surface
				row, has := ix[key]
				if !has {
					row = len(keys)
					ix[key] = row
					append(&keys, key)
					append(&counts, 0)
					append(&keep, key_keeps(key, filter))
					append(&stamp, 0)
				}
				if !keep[row] { continue }
				if stamp[row] == epoch { continue } // binary per row
				stamp[row] = epoch
				counts[row] += 1
			}
		}
	}

	out: [dynamic]Freq_Entry = make([dynamic]Freq_Entry, 0, len(keys), a)
	for k, i in keys {
		if counts[i] == 0 { continue } // every occurrence was pos-rejected
		append(&out, Freq_Entry{lemma = k, count = counts[i], docs = 1})
	}
	entries := out[:]
	sort_with_buffer(entries, freq_less, a)
	return Cooc_Presence{keys = entries, windows = len(rows)}, .None
}

// first token whose end is past `at` (tokens non-overlapping and
// ascending, so the tokens overlapping a byte span are contiguous)
colloc_seek :: proc(tokens: []Token, at: int) -> int {
	return lower_bound(tokens, token_end, at + 1)
}

/*
The k×k tables the clusterer and the coordinate solver run on, cut
from a Co_Pair list over the host's chosen keys (freq_table top-k is
the usual cut). cooc_weights is the contingency table itself —
shared-window counts, symmetric, zero diagonal; it is what
power_coords takes. cooc_distance is the Jaccard dissimilarity
1 − |N_i ∩ N_j| / |N_i ∪ N_j| over in-table neighborhoods: a word's
profile is the keys it shares a window with, within `keys`, so two
words whose only partners fall outside the key set sit at distance 1 —
no shared evidence, which is the honest reading of a submatrix.
Duplicate keys are Bad_Count; both tables are row-major, len k*k.
*/

cooc_weights :: proc(pairs: []Co_Pair, keys: []string,
                     a: mem.Allocator) -> ([]f64, Freq_Err) {
	k := len(keys)
	rows: [dynamic]Key_Row = make([dynamic]Key_Row, k, k, a)
	defer delete(rows)
	for key, i in keys { rows[i] = {key = key, val = i} }
	sort_with_buffer(rows[:], key_row_less, a)
	if key_row_dups(rows[:]) { return {}, .Bad_Count }
	w := make([]f64, k * k, a)
	for p in pairs {
		ra := key_row_find(rows[:], p.a)
		rb := key_row_find(rows[:], p.b)
		if ra < 0 || rb < 0 { continue }
		ia, ib := rows[ra].val, rows[rb].val
		if ia == ib { continue }
		w[ia * k + ib] += f64(p.n)
		w[ib * k + ia] += f64(p.n)
	}
	return w, .None
}

cooc_distance :: proc(pairs: []Co_Pair, keys: []string,
                      a: mem.Allocator) -> ([]f64, Freq_Err) {
	k := len(keys)
	rows: [dynamic]Key_Row = make([dynamic]Key_Row, k, k, a)
	defer delete(rows)
	for key, i in keys { rows[i] = {key = key, val = i} }
	sort_with_buffer(rows[:], key_row_less, a)
	if key_row_dups(rows[:]) { return {}, .Bad_Count }
	adj: [dynamic]bool = make([dynamic]bool, k * k, k * k, a)
	defer delete(adj)
	for p in pairs {
		ra := key_row_find(rows[:], p.a)
		rb := key_row_find(rows[:], p.b)
		if ra < 0 || rb < 0 { continue }
		ia, ib := rows[ra].val, rows[rb].val
		if ia == ib { continue }
		adj[ia * k + ib] = true
		adj[ib * k + ia] = true
	}
	d := make([]f64, k * k, a)
	for i in 0..<k {
		d[i * k + i] = 0
		for j in i + 1..<k {
			// |N_i ∩ N_j| and |N_i ∪ N_j| over the in-table profiles
			// (`either`, because `union` is a keyword)
			inter := 0
			either := 0
			for b in 0..<k {
				if adj[i * k + b] && adj[j * k + b] { inter += 1 }
				if adj[i * k + b] || adj[j * k + b] { either += 1 }
			}
			dij := 1.0
			if either > 0 { dij = 1.0 - f64(inter) / f64(either) }
			d[i * k + j] = dij
			d[j * k + i] = dij
		}
	}
	return d, .None
}

/*
Cluster distances over the weight table itself: a word's profile
is its FULL cooc_weights row, diagonal zeros included — Euclid is the
row-vector distance, Cosine 1 − the row dot over the row norms.
The cluster-distance menu (Jaccard / Euclid / Cosine / Dice /
Simpson) completes with this beside cooc_distance's Jaccard: Dice and
Simpson dissimilarities are 1 − their assoc values row-paired on the
same table — composition, no new proc. Output is symmetric, zero
diagonal, non-negative and finite (cosine caps at 2) — the
ward_merges input contract. Degenerate pins: two zero rows are
identical (distance 0); a zero row against anything is 1 under
Cosine (a zero vector shares no direction). Weights must be
non-negative and finite, and the length match k — anything else is
Bad_Count.
*/
Weight_Distance :: enum {
	Euclid,
	Cosine,
}

weight_distance :: proc(w: []f64, k: int, m: Weight_Distance,
                        a: mem.Allocator) -> ([]f64, Freq_Err) {
	if k < 0 || len(w) != k * k { return {}, .Bad_Count }
	for v in w {
		// NaN and Inf poison norms and dots — the finiteness gate
		// ward_merges applies to its output, applied here to the input
		if v - v != 0 || v < 0 { return {}, .Bad_Count }
	}
	norms := make([]f64, k, a)
	defer if len(norms) > 0 { mem.free(raw_data(norms), a) }
	for i in 0..<k {
		s := 0.0
		for b in 0..<k { s += w[i * k + b] * w[i * k + b] }
		norms[i] = math.sqrt(s)
	}
	d := make([]f64, k * k, a)
	for i in 0..<k {
		d[i * k + i] = 0
		for j in i + 1..<k {
			dij := 0.0
			switch m {
			case .Euclid:
				s := 0.0
				for b in 0..<k {
					diff := w[i * k + b] - w[j * k + b]
					s += diff * diff
				}
				dij = math.sqrt(s)
			case .Cosine:
				if norms[i] == 0 && norms[j] == 0 {
					dij = 0 // two zero rows are identical
				} else if norms[i] == 0 || norms[j] == 0 {
					dij = 1 // a zero row shares no direction
				} else {
					dot := 0.0
					for b in 0..<k { dot += w[i * k + b] * w[j * k + b] }
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
Ward hierarchical clustering: minimum-variance agglomeration over
a dissimilarity matrix, the merge-order tree a cluster analysis
reads. The design pins the machinery: a distance matrix plus a
priority queue of candidate merges. Squared distances update through
the Lance–Williams recurrence,

    D²(k, i∪j) = ((n_i+n_k)D²(k,i) + (n_j+n_k)D²(k,j) − n_k D²(i,j))
                 / (n_i+n_j+n_k)

so a merge's height is the Ward distance sqrt(D²) — the convention
where two singletons merge at their input dissimilarity. Ties break to
the smallest (i, then j), which with row-order scanning makes the
output deterministic; Ward is monotone, so heights never decrease.
Cluster ids: leaves are 0..n−1, the merge of step s is id n+s, so a
merge row's a or b ≥ n refers to merges[a − n]. `dist` is row-major
n×n, symmetric by precondition (the upper triangle is read),
non-negative and finite — a negative or non-finite entry is Bad_Count,
as is a wrong length.
Heights are non-decreasing in exact arithmetic; at f64 a tie can dip
by an ulp (measured −1.4e-17 on the novel bench) — hosts drawing
dendrograms may clamp. The optional stop-check polls once per row in
the initial heap build and once per merge step.
*/

Ward_Merge :: struct {
	a:    int, // cluster id (leaves 0..n-1, merge s is n+s)
	b:    int,
	dist: f64, // the height this merge happened at
	size: int, // members absorbed so far (the final merge holds n)
}

ward_merges :: proc(dist: []f64, n: int, a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil,
                    user: rawptr = nil) -> ([]Ward_Merge, Freq_Err) {
	if !dist_matrix_ok(dist, n) { return {}, .Bad_Count }
	if n < 2 { return {}, .None }

	m := 2 * n - 1
	sq: [dynamic]f64 = make([dynamic]f64, m * m, m * m, a)
	defer delete(sq)
	sizes: [dynamic]int = make([dynamic]int, m, m, a)
	defer delete(sizes)
	alive: [dynamic]bool = make([dynamic]bool, m, m, a)
	defer delete(alive)
	heap: [dynamic]Ward_Heap_Ent = make([dynamic]Ward_Heap_Ent, 0, n * n, a)
	defer delete(heap)

	for i in 0..<n {
		if check != nil && check(user) { return {}, .Interrupted }
		sizes[i] = 1
		alive[i] = true
		for j in i + 1..<n {
			d2 := dist[i * n + j] * dist[i * n + j]
			sq[i * m + j] = d2
			sq[j * m + i] = d2
			ward_push(&heap, {d2 = d2, i = i, j = j})
		}
	}

	out: [dynamic]Ward_Merge = make([dynamic]Ward_Merge, 0, n - 1, a)
	for step in 0..<n - 1 {
		if check != nil && check(user) { delete(out); return {}, .Interrupted }
		e, ok := ward_pop_live(&heap, alive[:])
		// the live-pair invariant guarantees a full tree; an exhausted
		// heap means it broke — refuse rather than truncate silently
		if !ok { delete(out); return {}, .Bad_Count }
		nid := n + step
		alive[e.i] = false
		alive[e.j] = false
		alive[nid] = true
		sizes[nid] = sizes[e.i] + sizes[e.j]
		append(&out, Ward_Merge{
			a = e.i, b = e.j,
			dist = math.sqrt(max(e.d2, 0)),
			size = sizes[nid],
		})
		si, sj := sizes[e.i], sizes[e.j]
		for k in 0..<nid {
			if !alive[k] { continue }
			sk := sizes[k]
			nd := (f64(si + sk) * sq[k * m + e.i] + f64(sj + sk) * sq[k * m + e.j] -
				f64(sk) * sq[e.i * m + e.j]) / f64(si + sj + sk)
			if nd < 0 { nd = 0 } // Lance–Williams can dip a hair under zero
			sq[nid * m + k] = nd
			sq[k * m + nid] = nd
			ward_push(&heap, {d2 = nd, i = k, j = nid})
		}
	}
	return out[:], .None
}

// heap entries: smallest squared distance, then smallest (i, j) — the
// deterministic tie-break the merge order is fixed by
Ward_Heap_Ent :: struct {
	d2: f64,
	i:  int,
	j:  int,
}

ward_less :: proc(x, y: ^Ward_Heap_Ent) -> bool {
	if x.d2 != y.d2 { return x.d2 < y.d2 }
	if x.i != y.i { return x.i < y.i }
	return x.j < y.j
}

ward_push :: proc(h: ^[dynamic]Ward_Heap_Ent, e: Ward_Heap_Ent) {
	append(h, e)
	i := len(h^) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !ward_less(&h^[i], &h^[p]) { break }
		h^[i], h^[p] = h^[p], h^[i]
		i = p
	}
}

// pop past entries whose clusters a later merge already absorbed
ward_pop_live :: proc(h: ^[dynamic]Ward_Heap_Ent,
                      alive: []bool) -> (Ward_Heap_Ent, bool) {
	for len(h^) > 0 {
		e := h^[0]
		last := pop(h)
		if len(h^) > 0 {
			h^[0] = last
			i := 0
			for {
				l, r := 2 * i + 1, 2 * i + 2
				s := i
				if l < len(h^) && ward_less(&h^[l], &h^[s]) { s = l }
				if r < len(h^) && ward_less(&h^[r], &h^[s]) { s = r }
				if s == i { break }
				h^[i], h^[s] = h^[s], h^[i]
				i = s
			}
		}
		if alive[e.i] && alive[e.j] { return e, true }
	}
	return {}, false
}

/*
The ward_merges input contract, shared by linkage_merges: a
row-major n×n dissimilarity matrix, non-negative and finite in the
upper triangle. NaN fails every comparison and Inf orders above all —
`d - d != 0` is the finiteness gate (only a non-finite value differs
from itself), `< 0` alone would let either through to poison the heap
and the heights.
*/
dist_matrix_ok :: proc(dist: []f64, n: int) -> bool {
	if n < 0 || len(dist) != n * n { return false }
	for i in 0..<n {
		for j in i + 1..<n {
			d := dist[i * n + j]
			if d - d != 0 || d < 0 { return false }
		}
	}
	return true
}

/*
Linkage variants — Ward (default),
average, complete — over one dissimilarity matrix. Same heap
and same (distance, i, j) tie-break as ward_merges; Ward IS
ward_merges (forwarded). Average and Complete
operate on dissimilarities directly: the Lance–Williams α_i =
n_i/(n_i+n_j) forms with no squaring, the merge height the raw
dissimilarity at which the pair met. Both are monotone, so heights
stay non-decreasing up to the same ulp caveat as Ward's. Cluster ids
follow ward_merges: leaves 0..n−1, merge s is n+s.
*/
Linkage :: enum {
	Ward,
	Average,
	Complete,
}

linkage_merges :: proc(dist: []f64, n: int, linkage: Linkage,
                       a: mem.Allocator,
                       check: proc(user: rawptr) -> bool = nil,
                       user: rawptr = nil) -> ([]Ward_Merge, Freq_Err) {
	if linkage == .Ward { return ward_merges(dist, n, a, check, user) }
	if !dist_matrix_ok(dist, n) { return {}, .Bad_Count }
	if n < 2 { return {}, .None }

	m := 2 * n - 1
	// the live dissimilarity table (Ward's squared table, unsquared)
	dd: [dynamic]f64 = make([dynamic]f64, m * m, m * m, a)
	defer delete(dd)
	sizes: [dynamic]int = make([dynamic]int, m, m, a)
	defer delete(sizes)
	alive: [dynamic]bool = make([dynamic]bool, m, m, a)
	defer delete(alive)
	heap: [dynamic]Ward_Heap_Ent = make([dynamic]Ward_Heap_Ent, 0, n * n, a)
	defer delete(heap)

	for i in 0..<n {
		if check != nil && check(user) { return {}, .Interrupted }
		sizes[i] = 1
		alive[i] = true
		for j in i + 1..<n {
			dv := dist[i * n + j]
			dd[i * m + j] = dv
			dd[j * m + i] = dv
			ward_push(&heap, {d2 = dv, i = i, j = j})
		}
	}

	out: [dynamic]Ward_Merge = make([dynamic]Ward_Merge, 0, n - 1, a)
	for step in 0..<n - 1 {
		if check != nil && check(user) { delete(out); return {}, .Interrupted }
		e, ok := ward_pop_live(&heap, alive[:])
		if !ok { delete(out); return {}, .Bad_Count }
		nid := n + step
		alive[e.i] = false
		alive[e.j] = false
		alive[nid] = true
		sizes[nid] = sizes[e.i] + sizes[e.j]
		append(&out, Ward_Merge{a = e.i, b = e.j, dist = e.d2, size = sizes[nid]})
		si, sj := sizes[e.i], sizes[e.j]
		for k in 0..<nid {
			if !alive[k] { continue }
			nd := 0.0
			switch linkage {
			case .Average:
				nd = (f64(si) * dd[k * m + e.i] + f64(sj) * dd[k * m + e.j]) /
					f64(si + sj)
			case .Complete:
				nd = max(dd[k * m + e.i], dd[k * m + e.j])
			case .Ward: // unreachable — forwarded above
				nd = 0
			}
			dd[nid * m + k] = nd
			dd[k * m + nid] = nd
			ward_push(&heap, {d2 = nd, i = k, j = nid})
		}
	}
	return out[:], .None
}

/*
The k-cut over a merge tree: the cluster each leaf sits in once only
the first n−k merges happened. Union-find over those rows (leaves
0..n−1, merge s is id n+s), then a component takes the rank of its
smallest member leaf — labels run 0..k−1 and the component holding
leaf 0 is always 0, so one tree cuts to one labelling whatever the
visit order. Every applied merge must join two live components — a
row that re-unites one component is not a merge tree, and neither is
a row naming a later merge (id ≥ n+i), a negative id, or a list whose
length is not n−1; each refuses with Bad_Count, as does k outside
1..n. A pure transform over caller-dimensioned data — the tree is
already built, so no stop-check.
*/

cluster_labels :: proc(merges: []Ward_Merge, n: int, k: int,
                       a: mem.Allocator) -> ([]int, Freq_Err) {
	if k < 1 || k > n || len(merges) != n - 1 { return {}, .Bad_Count }

	m := 2 * n - 1
	parent: [dynamic]int = make([dynamic]int, m, m, a)
	defer delete(parent)
	for i in 0..<m { parent[i] = i }

	// comps counts live components; a merge that does not reduce it
	// re-unites one component — the tree is malformed
	comps := n
	for i in 0..<n - k {
		mr := merges[i]
		if mr.a < 0 || mr.b < 0 || mr.a >= n + i || mr.b >= n + i {
			return {}, .Bad_Count
		}
		if !uf_union(&parent, n + i, mr.a) { return {}, .Bad_Count }
		if !uf_union(&parent, n + i, mr.b) { return {}, .Bad_Count }
		comps -= 1
	}

	// each component's smallest member leaf, then labels by their rank
	minleaf := make([dynamic]int, m, m, a)
	defer delete(minleaf)
	for &r in minleaf { r = -1 }
	for i in 0..<n {
		r := uf_find(&parent, i)
		if minleaf[r] < 0 || i < minleaf[r] { minleaf[r] = i }
	}
	order := make([dynamic]int, 0, comps, a)
	defer delete(order)
	for id in 0..<m {
		if minleaf[id] >= 0 { append(&order, minleaf[id]) }
	}
	sort_with_buffer(order[:], int_less, a)
	rank_of := make([dynamic]int, n, n, a)
	defer delete(rank_of)
	for r in 0..<n { rank_of[r] = -1 }
	for leaf, j in order { rank_of[leaf] = j }

	out := make([]int, n, a)
	for i in 0..<n {
		out[i] = rank_of[minleaf[uf_find(&parent, i)]]
	}
	return out, .None
}

// path-compression find and a boolean union — false means the two ids
// already shared a root
uf_find :: proc(parent: ^[dynamic]int, id: int) -> int {
	root := id
	for parent^[root] != root { root = parent^[root] }
	cur := id
	for parent^[cur] != root {
		next := parent^[cur]
		parent^[cur] = root
		cur = next
	}
	return root
}

uf_union :: proc(parent: ^[dynamic]int, x, y: int) -> bool {
	rx, ry := uf_find(parent, x), uf_find(parent, y)
	if rx == ry { return false }
	parent^[ry] = rx
	return true
}

int_less :: proc(x, y: ^int) -> bool { return x^ < y^ }

/*
Top-k coordinates by power iteration — the correspondence-
analysis stand-in; no full SVD. The weight table (cooc_weights output)
is normalized symmetrically, S = D^-½ W D^-½ with D the row sums —
the CA normalization of a symmetric contingency table. A non-negative
symmetric S ALWAYS carries the trivial eigenvalue 1 on the mass vector
√s (S is similar to the row-stochastic D^-1 W), so exactly like CA
itself the mass is the first thing removed: both axes are deflated
against it — the first axis is the leading non-trivial factor, the
second the next. Each axis is power iteration on S with sign-aligned
iterates (an iterate that flipped sign is the same axis, so a negative
dominant eigenvalue converges instead of oscillating), re-
orthogonalized against the mass and every earlier axis at the start
and at each step. Eigenvalues are estimated against S (vᵀSv), so a
negative eigenvalue is reported, not lost; coordinates scale by
sign(λ)·sqrt(|λ|) — the classical-MDS convention — and axis signs are
fixed by making each vector's first active component non-negative, so
one table always draws the same picture. A disconnected table carries
one trivial mass vector per component, so a component axis may
legitimately lead; with only two active keys the second axis has no
room and comes back zero, and a degenerate zero eigenvalue scales its
direction to nothing. Zero-row keys (no in-table co-occurrence) sit
at the origin. Deterministic for a fixed (tol, max_iter) —
recommended 1e-12 / 256: iteration
stops at whichever bound bites first. Weights must be non-negative
and finite — anything else is Bad_Count, as is a wrong length or
budget. The optional stop-check polls once per axis iteration.
*/

Coord :: struct {
	x: f64,
	y: f64,
}

power_coords :: proc(w: []f64, k: int, tol: f64, max_iter: int,
                     a: mem.Allocator,
                     check: proc(user: rawptr) -> bool = nil,
                     user: rawptr = nil) -> ([]Coord, Freq_Err) {
	if k < 0 || len(w) != k * k { return {}, .Bad_Count }
	if tol <= 0 || max_iter < 1 { return {}, .Bad_Budget }
	for i in 0..<k * k {
		// `w - w != 0` is the finiteness gate — a NaN or Inf weight
		// must refuse, not silently land its key at the origin
		if w[i] - w[i] != 0 || w[i] < 0 { return {}, .Bad_Count }
	}
	if k < 2 { return make([]Coord, k, a), .None }

	s: [dynamic]f64 = make([dynamic]f64, k, k, a)
	defer delete(s)
	for i in 0..<k {
		for j in 0..<k { s[i] += w[i * k + j] }
	}
	act: [dynamic]int = make([dynamic]int, 0, k, a)
	defer delete(act)
	for i in 0..<k {
		if s[i] > 0 { append(&act, i) }
	}
	m := len(act)
	if m < 2 { return make([]Coord, k, a), .None }

	sm: [dynamic]f64 = make([dynamic]f64, m * m, m * m, a)
	defer delete(sm)
	for u in 0..<m {
		for v in 0..<m {
			sm[u * m + v] = w[act[u] * k + act[v]] / math.sqrt(s[act[u]] * s[act[v]])
		}
	}

	// the trivial axis CA removes: the mass vector √s, unit length
	mass: [dynamic]f64 = make([dynamic]f64, m, m, a)
	defer delete(mass)
	mn := 0.0
	for u in 0..<m {
		mass[u] = math.sqrt(s[act[u]])
		mn += mass[u] * mass[u]
	}
	minv := 1.0 / math.sqrt(mn)
	for u in 0..<m { mass[u] *= minv }

	buf: [dynamic]f64 = make([dynamic]f64, m, m, a)
	defer delete(buf)
	v1: [dynamic]f64 = make([dynamic]f64, m, m, a)
	defer delete(v1)
	v2: [dynamic]f64 = make([dynamic]f64, m, m, a)
	defer delete(v2)
	orth1 := [1][]f64{mass[:]}
	orth2 := [2][]f64{mass[:], v1[:]}
	if !power_axis(sm[:], m, orth1[:], tol, max_iter, buf[:], v1[:], check, user) {
		return {}, .Interrupted
	}
	if !power_axis(sm[:], m, orth2[:], tol, max_iter, buf[:], v2[:], check, user) {
		return {}, .Interrupted
	}
	l1 := power_rayleigh(sm[:], m, v1[:])
	l2 := power_rayleigh(sm[:], m, v2[:])

	sx: f64
	if l1 < 0 { sx = -math.sqrt(-l1) } else { sx = math.sqrt(l1) }
	sy: f64
	if l2 < 0 { sy = -math.sqrt(-l2) } else { sy = math.sqrt(l2) }
	out := make([]Coord, k, a)
	for u in 0..<m {
		out[act[u]] = {x = sx * v1[u], y = sy * v2[u]}
	}
	return out, .None
}

// one axis by power iteration on S, the result landing in `x`; the
// start and every iterate are re-orthogonalized against every vector
// in `orth` (axis 1: the mass; axis 2: the mass and the first axis),
// and iterates are sign-aligned against the previous step — an
// iterate that flipped sign is the same axis, so a negative dominant
// eigenvalue converges instead of oscillating. `buf` is scratch both
// axes share. Returns false the moment the stop-check fires — `x` is
// partial then, and the caller returns .Interrupted.
power_axis :: proc(sm: []f64, m: int, orth: [][]f64, tol: f64,
                   max_iter: int, buf: []f64, x: []f64,
                   check: proc(user: rawptr) -> bool, user: rawptr) -> bool {
	if len(orth) == 0 {
		inv := 1.0 / math.sqrt(f64(m))
		for i in 0..<m { x[i] = inv }
	} else {
		// a start off every deflated axis: the earliest basis vector
		// whose RAW Gram–Schmidt residual survives with room to spare
		// — judged before any normalization, which would otherwise
		// amplify a rounding-level residual into a plausible-looking
		// start that is not orthogonal to anything
		for b in 0..<m {
			for i in 0..<m { x[i] = 0 }
			x[b] = 1
			power_gs(x[:m], orth)
			n2 := 0.0
			for i in 0..<m { n2 += x[i] * x[i] }
			if n2 > 1e-12 {
				power_norm(x[:m])
				break
			}
		}
	}
	for _ in 0..<max_iter {
		if check != nil && check(user) { return false }
		for i in 0..<m {
			sv := 0.0
			for j in 0..<m { sv += sm[i * m + j] * x[j] }
			buf[i] = sv
		}
		// the image of a unit iterate collapsing onto the deflated
		// span is the degenerate case (a zero eigenvalue): the axis
		// carries nothing, and the honest answer is the zero axis —
		// normalizing the rounding noise instead would invent one
		si := 0.0
		for i in 0..<m { si += buf[i] * buf[i] }
		if math.sqrt(si) <= tol {
			for i in 0..<m { x[i] = 0 }
			return true
		}
		power_norm(buf[:m])
		power_orthonorm(buf[:m], orth)
		// an iterate that flipped sign is the same axis: align first
		dot := 0.0
		for i in 0..<m { dot += buf[i] * x[i] }
		if dot < 0 {
			for i in 0..<m { buf[i] = -buf[i] }
		}
		d := 0.0
		for i in 0..<m {
			diff := buf[i] - x[i]
			d += diff * diff
		}
		copy(x, buf[:m])
		if math.sqrt(d) <= tol { break }
	}
	for i in 0..<m {
		if x[i] != 0 {
			if x[i] < 0 { for j in 0..<m { x[j] = -x[j] } }
			break
		}
	}
	return true
}

// v − Σ(v·o)o, no normalization — the caller reads the residual's
// size to decide whether anything survived the projection
power_gs :: proc(v: []f64, orth: [][]f64) {
	for o in orth {
		d := 0.0
		for i in 0..<len(v) { d += v[i] * o[i] }
		for i in 0..<len(v) { v[i] -= d * o[i] }
	}
}

// Gram–Schmidt against every vector in `orth`, then unit length
power_orthonorm :: proc(v: []f64, orth: [][]f64) {
	power_gs(v, orth)
	power_norm(v)
}

power_norm :: proc(v: []f64) {
	n := 0.0
	for c in v { n += c * c }
	if n <= 0 { return }
	inv := 1.0 / math.sqrt(n)
	for i in 0..<len(v) { v[i] *= inv }
}

// the eigenvalue estimate against S (not I + S): vᵀSv
power_rayleigh :: proc(sm: []f64, m: int, v: []f64) -> f64 {
	l := 0.0
	for i in 0..<m {
		sv := 0.0
		for j in 0..<m { sv += sm[i * m + j] * v[j] }
		l += v[i] * sv
	}
	return l
}
