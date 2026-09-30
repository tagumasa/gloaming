package gloaming

import "core:mem"
import "core:strings"

/*
The two match projections: KWIC widens a match into
context; compounding shrinks a matched span into one token —
concordance search and morpheme compounding, generalized: any matched
span becomes the unit.

Rendering is the host's: a Kwic_Row carries the center and context as
tokens with spans, never text — how a host lays a row out (line
numbers, markers) is its choice; the cheap summary is query_count.
*/

Kwic_Sort_Key :: enum {
	Position,
	Left_1,
	Left_2,
	Right_1,
	Right_2,
	Surface,
}

Kwic_Row :: struct {
	center: Span, // the match (or a capture's span — caller picks)
	left:   Span, // up to `left_n` tokens before, clamped
	right:  Span, // up to `right_n` tokens after, clamped
	match:  Match, // the source match, captures included
}

/*
Contexts are source slices, not token joins: tokens carry byte
offsets and arrive in order, so a context is a Span the host resolves
against the document text it already owns — zero join-policy
questions, whitespace and all. Row spans stamp `stream.doc`.

Windows clamp to the segment holding the *match* — a chapter's last
match never leaks the next chapter's opening into its context. When
segments nest (a chapter beside its paragraphs), "the" segment is the
first-listed container — the claim order below is list order, the
per-match scan's rule exactly. An empty `segments` means one whole-stream
segment. `center` is a capture def index (-1 = whole match); a match
missing that capture falls back to its whole span. Preconditions,
not runtime checks: matches index into `stream.tokens`, and `left_n`/
`right_n` are >= 0 (negatives behave as zero).

The container resolution runs as one claim pass over start-sorted
matches (query_match's order): each segment claims the unclaimed
matches whose start it holds, found by binary search — first-listed
wins, each match claimed once, and the work is O(segments +
nesting depth × matches) instead of matches × segments. A match list
not sorted by span start falls back to the per-match scan, so the
resolution never depends on an order the caller did not supply.
*/
kwic :: proc(matches: []Match, stream: Token_Stream,
             left_n: int, right_n: int,
             center: int,
             a: mem.Allocator) -> []Kwic_Row {
	toks := stream.tokens
	rows := make([]Kwic_Row, len(matches), a)
	ln := max(left_n, 0)
	rn := max(right_n, 0)

	// the clamp bounds per match: [lo, hi) in token indices, the
	// whole stream until a segment claims the match
	bounds := make([][2]int, len(matches), a)
	defer if len(bounds) > 0 { mem.free(raw_data(bounds), a) }
	for i in 0..<len(matches) { bounds[i] = {0, len(toks)} }

	if len(stream.segments) > 0 && len(matches) > 0 {
		starts_sorted := true
		for i in 1..<len(matches) {
			if matches[i].span.start < matches[i - 1].span.start {
				starts_sorted = false
				break
			}
		}
		if starts_sorted {
			claimed := make([]bool, len(matches), a)
			defer if len(claimed) > 0 { mem.free(raw_data(claimed), a) }
			for seg in stream.segments {
				lo_m := lower_bound(matches, match_span_start, seg.span.start)
				hi_m := lower_bound(matches, match_span_start, seg.span.end)
				for j in lo_m..<hi_m {
					if claimed[j] { continue }
					m := &matches[j]
					if seg.span.doc != m.span.doc { continue }
					claimed[j] = true
					bounds[j] = {
						token_at_or_after(toks, seg.span.start),
						token_at_or_after(toks, seg.span.end),
					}
				}
			}
		} else {
			// unsorted callers keep the per-match scan (the same rule,
			// first-listed container wins)
			for m, i in matches {
				for seg in stream.segments {
					if seg.span.doc == m.span.doc &&
						seg.span.start <= m.span.start && m.span.start < seg.span.end {
						bounds[i] = {
							token_at_or_after(toks, seg.span.start),
							token_at_or_after(toks, seg.span.end),
						}
						break
					}
				}
			}
		}
	}

	for m, i in matches {
		cs, ce := m.start, m.end
		cspan := m.span
		if center >= 0 {
			for cap in m.captures {
				if cap.def == center {
					cs, ce, cspan = cap.start, cap.end, cap.span
					break
				}
			}
		}

		lo, hi := bounds[i][0], bounds[i][1]
		left := Span{doc = stream.doc, start = cspan.start, end = cspan.start}
		if max(lo, cs - ln) < cs {
			left.start = toks[max(lo, cs - ln)].start
		}
		right := Span{doc = stream.doc, start = cspan.end, end = cspan.end}
		if min(hi, ce + rn) > ce {
			right.end = toks[min(hi, ce + rn) - 1].end
		}
		rows[i] = Kwic_Row{center = cspan, left = left, right = right, match = m}
	}
	return rows
}

// the claim pass's seek key: a match's byte start
match_span_start :: proc(m: ^Match) -> int { return m.span.start }

// first token whose byte start is >= `at` (tokens arrive in order)
token_at_or_after :: proc(toks: []Token, at: int) -> int {
	return lower_bound(toks, token_start, at)
}

/*
Sort stably in place. The three concordance keys (1L/2L/1R/2R) compare the
surface of the token at the key's offset from the *match* (the
capture choice affects row spans, not sort neighbors); Surface is the
match's first token. Keys compare surface, then position, so the
order is total; out-of-stream neighbors sort as "" — first. Position
keeps match order. The signature carries no allocator: the sort
allocates nothing (rotation-based symmerge below).
*/
kwic_sort :: proc(rows: []Kwic_Row, stream: Token_Stream, key: Kwic_Sort_Key) {
	kwic_msort(rows, 0, len(rows), stream, key)
}

// the concordance keys as data: each key's comparison token sits at a
// fixed offset from one end of the match
Kwic_Key_Spec :: struct {
	at_end: bool, // anchor at the match's end instead of its start
	delta:  int, // tokens away from the anchor
}

KWIC_KEY_SPECS: [Kwic_Sort_Key]Kwic_Key_Spec = {
	.Position = {at_end = false, delta = 0},
	.Left_1   = {at_end = false, delta = -1},
	.Left_2   = {at_end = false, delta = -2},
	.Right_1  = {at_end = true,  delta = 0},
	.Right_2  = {at_end = true,  delta = 1},
	.Surface  = {at_end = false, delta = 0},
}

kwic_key_index :: proc(key: Kwic_Sort_Key, m: Match) -> int {
	spec := KWIC_KEY_SPECS[key]
	if spec.at_end { return m.end + spec.delta }
	return m.start + spec.delta
}

kwic_key_surface :: proc(stream: Token_Stream, i: int) -> string {
	if i < 0 || i >= len(stream.tokens) { return "" }
	return stream.tokens[i].surface
}

kwic_less :: proc(a, b: ^Kwic_Row, stream: Token_Stream, key: Kwic_Sort_Key) -> bool {
	if key != .Position {
		c := strings.compare(
			kwic_key_surface(stream, kwic_key_index(key, a.match)),
			kwic_key_surface(stream, kwic_key_index(key, b.match)),
		)
		if c != 0 { return c < 0 }
	}
	if a.match.start != b.match.start { return a.match.start < b.match.start }
	return a.match.end < b.match.end
}

kwic_msort :: proc(rows: []Kwic_Row, lo, hi: int, stream: Token_Stream, key: Kwic_Sort_Key) {
	if hi - lo < 2 { return }
	mid := lo + (hi - lo) / 2
	kwic_msort(rows, lo, mid, stream, key)
	kwic_msort(rows, mid, hi, stream, key)
	kwic_merge(rows, lo, mid, hi, stream, key)
}

/*
symmerge — stable in-place merge via rotations (Dudinskyi/Catuogno's
scheme): split the longer run, binary-search the pivot's stable
placement in the other, rotate, recurse. O(n log² n), no allocation.
*/
kwic_merge :: proc(rows: []Kwic_Row, lo, mid, hi: int, stream: Token_Stream, key: Kwic_Sort_Key) {
	if lo >= mid || mid >= hi { return }
	if hi - lo == 2 {
		if kwic_less(&rows[mid], &rows[lo], stream, key) {
			rows[lo], rows[mid] = rows[mid], rows[lo]
		}
		return
	}
	r, p: int
	if mid - lo >= hi - mid {
		r = lo + (mid - lo) / 2
		p = kwic_bound(rows, mid, hi, r, stream, key)
	} else {
		p = mid + (hi - mid) / 2
		r = kwic_bound(rows, lo, mid, p, stream, key)
	}
	kwic_rotate(rows, r, mid, p)
	kwic_merge(rows, lo, r, r + (p - mid), stream, key)
	kwic_merge(rows, r + (p - mid), p, hi, stream, key)
}

// first index in [x0, x1) whose row is NOT strictly before rows[pivot]
// — equality lands after the pivot, which is what makes the merge
// stable (left-run rows precede their equals in the right run)
kwic_bound :: proc(rows: []Kwic_Row, x0, x1, pivot: int,
                   stream: Token_Stream, key: Kwic_Sort_Key) -> int {
	lo, hi := x0, x1
	for lo < hi {
		mid := (lo + hi) / 2
		if kwic_less(&rows[mid], &rows[pivot], stream, key) { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

kwic_rotate :: proc(rows: []Kwic_Row, lo, mid, hi: int) {
	if lo >= mid || mid >= hi { return }
	kwic_reverse(rows, lo, mid)
	kwic_reverse(rows, mid, hi)
	kwic_reverse(rows, lo, hi)
}

kwic_reverse :: proc(rows: []Kwic_Row, lo, hi: int) { // reverse rows[lo:hi)
	i, j := lo, hi - 1
	for i < j {
		rows[i], rows[j] = rows[j], rows[i]
		i += 1
		j -= 1
	}
}

Compound_Err :: enum {
	None,
	Overlap,
	Bad_Range,
}

/*
Project matched spans to single tokens (morpheme compounding,
generalized): each match's token range becomes one merged token, the
rest pass through in order — then frequency or co-occurrence
runs over the resegmented stream. Any matched span becomes one unit;
that is the whole generalization.

`text` is the source the tokens view into (adapter contract). The
merged surface and lemma are text[t₀.start .. t_last.end) — one view,
so inter-token bytes (spaces, when present) land inside the compound:
correct for compounding of abutting morphemes, honest for spaced ones,
documented rather than papered over. pos and reading are t₀'s (the
head morpheme's features) and stay borrowed from `tokens`, as do the
unmatched tokens' views. cost is the member costs summed in i64 and
saturated back into Token.cost's i16. kind is .Idless, entry_id -1:
the merge is synthesized, no dictionary row backs it (the payload
carries such tokens as id-less known records, GLB1 v2).

Precondition: matches sorted and non-overlapping — query_match output
satisfies both by construction. Interleaved or overlapping ranges
report Overlap; token ranges outside the stream or byte ranges past
`text` report Bad_Range. Host-curated span lists (arbitrary order,
overlaps, duplicates) resolve through merge_matches / compound_merge
below.
*/
compound :: proc(tokens: []Token, text: string, matches: []Match,
                 a: mem.Allocator) -> ([]Token, Compound_Err) {
	prev_end := 0
	out_len := len(tokens)
	for m in matches {
		if m.start < 0 || m.end <= m.start || m.end > len(tokens) { return {}, .Bad_Range }
		if m.start < prev_end { return {}, .Overlap }
		prev_end = m.end
		if tokens[m.start].start > len(text) || tokens[m.end - 1].end > len(text) {
			return {}, .Bad_Range
		}
		out_len -= m.end - m.start - 1
	}

	out: [dynamic]Token = make([dynamic]Token, 0, out_len, a)
	mi := 0
	for i := 0; i < len(tokens); i += 1 {
		if mi < len(matches) && matches[mi].start == i {
			m := matches[mi]
			head := &tokens[m.start]
			last := &tokens[m.end - 1]
			cost := 0
			for k in m.start..<m.end { cost += int(tokens[k].cost) }
			if cost > 32767 { cost = 32767 }
			if cost < -32768 { cost = -32768 }
			append(&out, Token{
				surface    = text[head.start:last.end],
				lemma      = text[head.start:last.end],
				pos        = head.pos,
				reading    = head.reading,
				kind       = .Idless, // no dictionary row backs the merge
				entry_id   = -1,
				cost       = i16(cost),
				start      = head.start,
				end        = last.end,
			})
			i = m.end - 1
			mi += 1
		} else {
			append(&out, tokens[i])
		}
	}
	return out[:], .None
}

/*
merge_matches resolves a host-curated span list — arbitrary order,
overlaps, duplicates — into the sorted, non-overlapping form compound
requires. A curation step (an LLM host reading KWIC rows and
frequency tables, a human annotator) emits decisions, not sorted
arrays; this is that entry point.

Rule (deterministic, total): valid spans order by (start asc,
end desc) and the sweep keeps a span only when it starts at or after
the previous kept end — earliest start wins, equal starts resolve to
the longer span, and exact duplicates keep the earliest input entry
(the sort is stable). Losers return in `dropped`, so a host re-decides
conflicts instead of wondering what vanished. Empty or inverted
ranges (end <= start) are curation artifacts: they drop before
ordering, also counted. Bounds stay compound's to judge — a span
indexing outside the stream passes through and compound reports
Bad_Range; resolution cannot invent validity. Only token ranges
participate: span/captures ride along untouched.

The insertion sort is deliberate: curation lists run tens to
hundreds, and a hand-checkable ordering beats comparator plumbing on
a path that is not hot.
*/
merge_matches :: proc(matches: []Match, a: mem.Allocator) -> (kept: []Match, dropped: int) {
	kept = make([]Match, len(matches), a)
	n := 0
	for m in matches {
		if m.end > m.start {
			kept[n] = m
			n += 1
		}
	}
	dropped = len(matches) - n
	// order by (start asc, end desc); strictly-greater keeps it stable,
	// so exact duplicates keep input order
	for i in 1..<n {
		m := kept[i]
		j := i - 1
		for j >= 0 && (kept[j].start > m.start ||
				(kept[j].start == m.start && kept[j].end < m.end)) {
			kept[j + 1] = kept[j]
			j -= 1
		}
		kept[j + 1] = m
	}
	w, last_end := 0, 0
	for i in 0..<n {
		if kept[i].start >= last_end {
			kept[w] = kept[i]
			w += 1
			last_end = kept[i].end
		} else {
			dropped += 1
		}
	}
	return kept[:w], dropped
}

/*
compound_merge is compound over a host-curated span list: resolve with
merge_matches, then compound. The one-call shape trades away the
dropped count — a host that wants conflict visibility calls
merge_matches itself and feeds `kept` to compound.
*/
compound_merge :: proc(tokens: []Token, text: string, matches: []Match,
                       a: mem.Allocator) -> ([]Token, Compound_Err) {
	kept, _ := merge_matches(matches, a)
	defer delete(kept, a)
	return compound(tokens, text, kept, a)
}
