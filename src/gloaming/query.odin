package gloaming

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

/*
The compiled pattern model, the S-expression front-end, and the
backtracking sequence matcher: the failure memo is a bitmap over
step × position × owed, bounded alternation repetition is rejected
at parse, a branch must consume at least one token, and query_match
runs under a work budget. A Query is immutable after parse; one
query may run on many cursors concurrently. The matcher's
continuation chain is index-linked through a cursor-owned stack —
no pointer-linked structures anywhere in the engine.
*/

// ============================================================
// The compiled form
// ============================================================

Query_Field :: enum {
	Surface,
	Lemma,
	Pos,
	Reading,
	Unknown, // boolean field: `(m unknown)` tests Token_Kind.Unknown
}

// the grammar's field idents as data over the enum: parse_m's ident →
// Query_Field step walks this table, so the field set and the
// seen-parallel's index share one numbering — no hand-maintained
// ladder beside the enum
FIELD_NAMES :: [Query_Field]string{
	.Surface = "surface",
	.Lemma   = "lemma",
	.Pos     = "pos",
	.Reading = "reading",
	.Unknown = "unknown",
}

// Fuzzy flags exist to *disable* folds, not to opt in: a plain
// Levenshtein would hide the two common Japanese typo classes
// (full/half-width, kana register) exactly where they occur.
Fuzzy_Flags :: struct {
	width_fold:    bool, // U+FF01–U+FF5E → ASCII (−0xFEE0), U+3000 → space
	kana_fold:     bool, // katakana → hiragana (U+30A1–U+30F6, −0x60)
	transposition: bool, // adjacent swap counts as one edit (OSA)
}

FUZZY_FLAGS_DEFAULT :: Fuzzy_Flags{
	width_fold    = true,
	kana_fold     = true,
	transposition = true,
}

Custom_Proc :: proc(tok: ^Token, user_data: rawptr) -> bool

/*
A predicate is the token field it tests plus the match form — one
union variant live per predicate, each form owning exactly the data it
needs. The string forms are distinct strings: same representation,
different comparison.
*/
Predicate :: struct {
	field: Query_Field,
	match: Predicate_Match,
}

// `(m unknown)`: the boolean field named by `field` (only .Unknown
// today); every other form reads that field's string
Flag_Match :: struct{}

Eq_Match     :: distinct string // exact literal
Prefix_Match :: distinct string // POS hierarchy: ^"名詞," matches 名詞,一般,*,…
Suffix_Match :: distinct string
Set_Match :: struct {
	members: []string, // any of a literal set (also what `~` expansion compiles to); sorted ascending at parse — membership is a binary search
}
Fuzzy_Match :: struct {
	pattern:  string, // the typo-tolerant form
	distance: int, // max edit distance
	flags:    Fuzzy_Flags,
}
Custom_Match :: struct {
	name:      string, // host-injected proc; regex & friends live in the host
	custom:    Custom_Proc,
	user_data: rawptr,
}

Predicate_Match :: union {
	Flag_Match,
	Eq_Match,
	Prefix_Match,
	Suffix_Match,
	Set_Match,
	Fuzzy_Match,
	Custom_Match,
}

/*
Quantifier: the step consumes min..max tokens; max = -1 is unbounded
(`:?` → {0,1}, `:*` → {0,-1}, `:+` → {1,-1}, `:n-m` as written).
*/
Quantifier :: struct {
	min: int,
	max: int,
}

Alt_Branch :: struct {
	steps: []Query_Step, // declaration order; tried first-declared first
}

/*
The two step bodies: ANDed predicates or alternation branches — the
tag is the discriminator, so the empty-when-the-other-is-set comment
contract of the two-slices form is a type invariant instead. An
And_Body with zero predicates is the `_` wildcard, not the alt form.
A Query_Step straight from its zero value (nil body) is a parse-error
return; only parse products reach the matcher.
*/
And_Body :: struct {
	predicates: []Predicate, // ANDed
}
Alt_Body :: struct {
	alternatives: []Alt_Branch, // (alt …): the matcher manages the branching
}
Step_Body :: union {
	And_Body,
	Alt_Body,
}

Query_Step :: struct {
	body:        Step_Body,
	quant:       Quantifier,
	capture:     int, // index into Query.captures, or -1
	negated:     bool, // (not …): unit matches iff all preds fail
	zero_width:  bool, // (not! …): tested, consumes nothing; no quant, no capture
	depth:       int, // reserved: 0 for sibling (sequence) matching
	id:          int, // global pre-order number, assigned by query_prepare
}

Capture_Def :: struct {
	name: string,
}

Query :: struct {
	steps:        []Query_Step,
	captures:     []Capture_Def,
	anchor_start: bool, // ^ — stream/segment start
	anchor_end:   bool, // $
	// every string the pattern holds — literals, set members, capture
	// names — views this pool's blocks. Blocks are fixed-capacity: a
	// block never relocates once bytes have been handed out (a single
	// growing buffer would move its backing and strand every string
	// header already embedded in steps). Blocks are [dynamic]s made on
	// the parse allocator, so a non-arena caller retiring a Query frees
	// with one delete per block
	pool:         [][dynamic]u8,

	// memo geometry, assigned once by query_prepare at parse: a
	// pre-order numbering over the step tree (nesting means there is
	// no flat len(steps)) and the memo's owed dimension
	n_ids:    int,
	owed_dim: int,
}

Match :: struct {
	start:    int, // token index, inclusive
	end:      int, // token index, exclusive
	span:     Span, // byte evidence, derived from the token range
	captures: []Capture,
}

Capture :: struct {
	def:   int, // index into Query.captures
	start: int, // token indices, inclusive/exclusive
	end:   int,
	span:  Span, // same derivation as Match.span
}

Query_Result :: struct {
	matches:   []Match,
	truncated: bool, // more existed past `limit`
}

Query_Err :: enum {
	None,
	Bad_Syntax,
	Unknown_Field,
	No_Group, // `~"x"` with no lemma group for x — never a silent narrowing
	No_Custom, // `%"name"` with no registered proc
	Bad_Quantifier, // the numeric caps: quant max, the alternation rules, fuzzy distance
	Bad_Value, // bad value form / `_` misuse
	Bad_Argument, // call-argument validation (limit/cap/rule) — not a parse failure
	Too_Long, // source past the parse cap
	Interrupted, // stop-check abort
	Work_Capped, // evaluation budget exhausted
	Memo_Capped, // the failure-memo bitmap over QUERY_MEMO_MAX_BYTES (pattern × stream)
	Set_Capped, // a set predicate over ANY_EQ_MAX members — `~` expansion of an oversized group
}

/*
Parse options: `~` expansion over lemma groups and `%` resolution
through host-registered procs. Both are borrowed for the duration of
the call only — everything the parsed Query retains is cloned into the
parse arena.
*/
Parse_Options :: struct {
	groups: ^Lemma_Groups, // nil → `~` is No_Group
	custom: ^Custom_Preds, // nil → `%` is No_Custom
}

Custom_Preds :: struct {
	procs:     map[string]Custom_Proc,
	user_data: rawptr,
}

// Parse-time caps. Library constants, not
// caller dials — hosts render the typed failure, not a bigger number.
PARSE_SRC_MAX   :: 4096 // bounded parse input
QUANT_MAX       :: 64 // bounded quantifier max; :0-100000 is a typo or an attack
FUZZY_DIST_MAX  :: 3 // distance > 3 is a different word, not a typo
ALT_BRANCH_MAX  :: 16
ANY_EQ_MAX      :: 64 // set path — no branching
ANY_MIXED_MAX   :: 16 // alternation path — same cap, no bypass
QUERY_STEPS_MAX :: 256 // total step occurrences; also the memo bitmap's first dimension

// The evaluation budget for one query_match call: counts
// predicate evaluations and aborts with Work_Capped. The stop-check
// covers cancellation, not runaway work; cap-legal patterns were
// measured eating seconds of CPU before yielding anything. 100M
// evaluations is ~0.3–1 s of CPU — two orders above the heaviest
// realistic pattern at novel scale (1.4M), far below the
// pathological classes the grammar and the memo do not already bound.
QUERY_WORK_BUDGET :: i64(100_000_000)

// The failure-memo bitmap's byte cap for one cursor: the
// bitmap is n_ids × (n+1) × owed_dim bits — each factor parse-capped,
// their product with stream length not. A pattern × stream combination
// over the cap refuses with .Memo_Capped before any allocation or
// predicate work; the work budget bounds evaluation, but the bitmap
// precedes it. 32 MiB is the memory gate at novel scale
// — ~48× the heaviest realistic pattern measured (0.67 MB).
QUERY_MEMO_MAX_BYTES :: 32 * 1024 * 1024

// ============================================================
// Fuzzy: fold and band DP
// ============================================================

FUZZY_INLINE :: 64 // fold-buffer and DP-row width kept inline in the scratch

/*
Fold one string into runes under the flags (the pipeline: width fold,
then kana fold, then compare). `buf` is caller scratch; the result is a
view of it. Folding is rune-for-rune (no fold changes the count), so
the fold fills min(len(buf), rune_count(v)) runes — whole-string
equality needs a buffer of rune_count(v) runes, which fold_value and
fold_pattern reserve exactly.
*/
fold_runes :: proc(v: string, buf: []rune, flags: Fuzzy_Flags) -> []rune {
	n := 0
	i := 0
	for i < len(v) {
		r, size := utf8.decode_rune_in_string(v[i:])
		i += size
		switch {
		case flags.width_fold && r == 0x3000:
			r = 0x20
		case flags.width_fold && r >= 0xFF01 && r <= 0xFF5E:
			r -= 0xFEE0
		case flags.kana_fold && r >= 0x30A1 && r <= 0x30F6:
			r -= 0x60
		}
		if n >= len(buf) { break }
		buf[n] = r
		n += 1
	}
	return buf[:n]
}

/*
Fuzzy scratch, owned by the match cursor: the two fold buffers
start inline — 64 runes covers realistic tokens and patterns — and a
longer fold grows its heap side on the cursor's allocator, kept for the
cursor's life. Equality must never be decided on a truncated prefix,
so the buffer is sized to the whole string before folding (the count
is exact: folds are rune-for-rune).
*/
Fuzzy_Scratch :: struct {
	fold_v_inline: [FUZZY_INLINE]rune,
	fold_p_inline: [FUZZY_INLINE]rune,
	fold_v_heap:   []rune, // non-nil once a value fold exceeded the inline width
	fold_p_heap:   []rune, // non-nil once the pattern fold did
	a:             mem.Allocator,
}

fuzzy_scratch_init :: proc(s: ^Fuzzy_Scratch, a: mem.Allocator) {
	s.fold_v_heap = nil
	s.fold_p_heap = nil
	s.a = a
}

fuzzy_scratch_destroy :: proc(s: ^Fuzzy_Scratch) {
	if s.fold_v_heap != nil { delete(s.fold_v_heap, s.a) }
	if s.fold_p_heap != nil { delete(s.fold_p_heap, s.a) }
}

// Fold into inline-or-heap storage sized to the whole string.
fold_in :: proc(inline_buf: []rune, heap: ^[]rune, a: mem.Allocator,
                v: string, flags: Fuzzy_Flags) -> []rune {
	n := utf8.rune_count(v)
	buf := inline_buf
	if n > len(buf) {
		if len(heap^) < n {
			if heap^ != nil { delete(heap^, a) }
			heap^ = make([]rune, n, a)
		}
		buf = heap^
	}
	return fold_runes(v, buf, flags)
}

fold_value :: proc(s: ^Fuzzy_Scratch, v: string, flags: Fuzzy_Flags) -> []rune {
	return fold_in(s.fold_v_inline[:], &s.fold_v_heap, s.a, v, flags)
}

fold_pattern :: proc(s: ^Fuzzy_Scratch, v: string, flags: Fuzzy_Flags) -> []rune {
	return fold_in(s.fold_p_inline[:], &s.fold_p_heap, s.a, v, flags)
}

// Banded Damerau (optimal string alignment) within distance n — the
// chosen form: no substring re-use, negligible on short tokens at
// n ≤ 3, hand-verifiable. `transposition` lets the OSA swap term be
// switched off by Fuzzy_Flags. The three rows stay inline for patterns
// up to the scratch width; a longer pattern takes one exact-size
// allocation on the temp allocator (rare — fuzzy literals are short —
// but the DP must see every column).
fuzzy_within :: proc(a, b: []rune, n: int, transposition: bool) -> bool {
	if abs(len(a) - len(b)) > n { return false }
	la, m := len(a), len(b)
	if la == 0 { return m <= n }
	if m == 0 { return la <= n }
	w := m + 1
	inline_rows: [3 * FUZZY_INLINE]int
	rows: []int
	if w <= FUZZY_INLINE {
		rows = inline_rows[:]
	} else {
		rows = make([]int, 3 * w, context.temp_allocator)
	}
	defer if w > FUZZY_INLINE { delete(rows, context.temp_allocator) }
	prev2 := rows[0:w]
	prev := rows[w:2 * w]
	cur := rows[2 * w:3 * w]
	for j in 0..<m + 1 {
		prev[j] = j
	}
	for i in 1..<la + 1 {
		lo := max(1, i - n)
		hi := min(m, i + n)
		if lo > 1 {
			cur[lo - 1] = n + 1
		} else {
			cur[0] = i
		}
		if hi < m { cur[hi + 1] = n + 1 }
		for j in lo..<hi + 1 {
			cost := 1
			if a[i - 1] == b[j - 1] { cost = 0 }
			d := min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
			if transposition && i > 1 && j > 1 &&
				a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
				d = min(d, prev2[j - 2] + 1)
			}
			cur[j] = d
		}
		for j in 0..<m + 1 {
			prev2[j] = prev[j]
			prev[j] = cur[j]
		}
	}
	return prev[m] <= n
}

// ============================================================
// The front-end: query_parse
// ============================================================

query_parse :: proc(src: string, opts: Parse_Options, a: mem.Allocator,
                    err_pos: ^int = nil) -> (Query, Query_Err) {
	p := Parse_State{
		src    = src,
		opts   = opts,
		a      = a,
		err_at = -1,
		steps  = make([dynamic]Query_Step, 0, 16, a),
		caps   = make([dynamic]Capture_Def, 0, 4, a),
		cap_ix = make(map[string]int, 8, a),
		pool   = make([dynamic][dynamic]u8, 0, 1, a),
	}
	if len(src) > PARSE_SRC_MAX {
		fail(&p, 0, .Too_Long)
	}

	ps_ws(&p)
	if !ps_expect(&p, '(') { _ = fail(&p, p.pos, .Bad_Syntax) }
	if p.err == .None && !ps_ident_is(&p, "seq") { _ = fail(&p, p.pos, .Bad_Syntax) }
	if p.err == .None {
		ps_ws(&p)
		if ps_byte(&p, '^') {
			p.anchor_s = true
			if ps_byte(&p, '$') { p.anchor_e = true } // ^ first, at most one each
		} else if ps_byte(&p, '$') {
			p.anchor_e = true
		}
	}

	n_elems := 0
	for p.err == .None {
		ps_ws(&p)
		if ps_peek(&p) != '(' { break } // elem+ then ')'
		s, ok := parse_elem(&p)
		if !ok { break }
		append(&p.steps, s)
		n_elems += 1
	}
	if p.err == .None && n_elems == 0 { _ = fail(&p, p.pos, .Bad_Syntax) }
	if p.err == .None { _ = ps_expect(&p, ')') }
	ps_ws(&p)
	if p.err == .None && p.pos != len(p.src) { _ = fail(&p, p.pos, .Bad_Syntax) }

	if p.err != .None {
		if err_pos != nil { err_pos^ = p.err_at }
		parse_scratch_free(&p)
		return {}, p.err
	}
	q := Query{
		steps        = p.steps[:],
		captures     = p.caps[:],
		anchor_start = p.anchor_s,
		anchor_end   = p.anchor_e,
		pool         = p.pool[:],
	}
	delete(p.cap_ix) // the lookup side-table never ships
	query_prepare(&q)
	return q, .None
}

Parse_State :: struct {
	src:      string,
	pos:      int,
	opts:     Parse_Options,
	a:        mem.Allocator,
	steps:    [dynamic]Query_Step,
	caps:     [dynamic]Capture_Def,
	cap_ix:   map[string]int,
	pool:     [dynamic][dynamic]u8, // the parse's string blocks
	n_steps:  int, // total step occurrences incl. alt branches
	anchor_s: bool,
	anchor_e: bool,
	err:      Query_Err,
	err_at:   int, // byte offset of the first failure; -1 while healthy
}

fail :: proc(p: ^Parse_State, at: int, e: Query_Err) -> bool {
	if p.err == .None {
		p.err = e
		p.err_at = at
	}
	return false
}

/*
The error-path reclaim — a refusal allocates nothing net, the same rule
the store layers hold. Every string a failed parse cloned lives in the
pool's blocks, so the block deletes cover them all; every container
that reached a completed step hangs off p.steps (walked here), and the
sub-parsers free on their own error paths what never reached one.
*/
parse_scratch_free :: proc(p: ^Parse_State) {
	for &s in p.steps {
		free_step_scratch(&s, p.a)
	}
	delete(p.steps)
	delete(p.caps) // capture names are pool bytes
	delete(p.cap_ix)
	for blk in p.pool { delete(blk) }
	delete(p.pool)
}

// one completed step's container backings: the predicate/branch/member
// slices the parse made — string bytes themselves are pool views
free_step_scratch :: proc(s: ^Query_Step, a: mem.Allocator) {
	switch b in s.body {
	case And_Body:
		free_members_backings(b.predicates, a)
		if len(b.predicates) > 0 { mem.free(raw_data(b.predicates), a) }
	case Alt_Body:
		free_branch_scratch(b.alternatives, a)
		if len(b.alternatives) > 0 { mem.free(raw_data(b.alternatives), a) }
	}
}

// an alternation's branch containers — each branch's step containers
// (recursively: a branch is itself a step tree) plus its step slice
free_branch_scratch :: proc(branches: []Alt_Branch, a: mem.Allocator) {
	for &br in branches {
		for i in 0..<len(br.steps) { free_step_scratch(&br.steps[i], a) }
		if len(br.steps) > 0 { mem.free(raw_data(br.steps), a) }
	}
}

// a predicate list's Set members backings — the strings are pool bytes,
// the members slice itself is a plain make
free_members_backings :: proc(preds: []Predicate, a: mem.Allocator) {
	for &pr in preds {
		if m, is_set := pr.match.(Set_Match); is_set && len(m.members) > 0 {
			mem.free(raw_data(m.members), a)
		}
	}
}

// Assign the pre-order step ids and the memo's owed dimension; verify
// the invariants the matcher assumes. Alternation quants were
// already restricted at parse (max = 1 or unbounded), so the bitmap's
// fixed sizing is sound.
query_prepare :: proc(q: ^Query) {
	next := 0
	owed_dim := 1
	walk :: proc(s: ^Query_Step, next: ^int, owed_dim: ^int) {
		s.id = next^
		next^ += 1
		if alts, is_alt := s.body.(Alt_Body); is_alt {
			if s.quant.min >= owed_dim^ {
				owed_dim^ = s.quant.min // owed <= min-1 < dim
			}
			for bi in 0..<len(alts.alternatives) {
				for si in 0..<len(alts.alternatives[bi].steps) {
					walk(&alts.alternatives[bi].steps[si], next, owed_dim)
				}
			}
		}
	}
	for i in 0..<len(q.steps) {
		walk(&q.steps[i], &next, &owed_dim)
	}
	q.n_ids = next
	q.owed_dim = owed_dim
}

// --- cursor primitives ---

ps_peek :: proc(p: ^Parse_State) -> u8 {
	if p.pos < len(p.src) { return p.src[p.pos] }
	return 0
}

ps_peek_at :: proc(p: ^Parse_State, off: int) -> u8 {
	if p.pos + off < len(p.src) { return p.src[p.pos + off] }
	return 0
}

ps_byte :: proc(p: ^Parse_State, c: u8) -> bool {
	if p.pos < len(p.src) && p.src[p.pos] == c {
		p.pos += 1
		return true
	}
	return false
}

ps_expect :: proc(p: ^Parse_State, c: u8) -> bool {
	return ps_byte(p, c) || fail(p, p.pos, .Bad_Syntax)
}

// ws: space/tab/CR/LF; comments run ';' to end of line (so ';' and
// ';;' both work). ws may appear between any
// tokens.
ps_ws :: proc(p: ^Parse_State) {
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			p.pos += 1
		} else if c == ';' {
			for p.pos < len(p.src) && p.src[p.pos] != '\n' { p.pos += 1 }
		} else {
			break
		}
	}
}

ps_is_ident_byte :: proc(c: u8, first: bool) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
		(!first && ((c >= '0' && c <= '9') || c == '-'))
}

ps_ident :: proc(p: ^Parse_State) -> (string, bool) {
	if p.pos >= len(p.src) || !ps_is_ident_byte(p.src[p.pos], true) {
		return "", false
	}
	start := p.pos
	for p.pos < len(p.src) && ps_is_ident_byte(p.src[p.pos], false) { p.pos += 1 }
	return p.src[start:p.pos], true
}

ps_ident_is :: proc(p: ^Parse_State, want: string) -> bool {
	s, ok := ps_ident(p)
	return ok && s == want
}

// STRING: raw bytes between double quotes, no escapes — an
// unterminated quote is Bad_Syntax.
ps_string :: proc(p: ^Parse_State) -> (string, bool) {
	if !ps_byte(p, '"') { return "", false }
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '"' { p.pos += 1 }
	if p.pos >= len(p.src) {
		return "", fail(p, start - 1, .Bad_Syntax)
	}
	s := p.src[start:p.pos]
	p.pos += 1 // closing quote
	return s, true
}

ps_int :: proc(p: ^Parse_State) -> (int, bool) {
	start := p.pos
	v := 0
	for p.pos < len(p.src) && p.src[p.pos] >= '0' && p.src[p.pos] <= '9' {
		v = v * 10 + int(p.src[p.pos] - '0')
		if v > 1 << 20 { break } // scan guard; the caps reject it anyway
		p.pos += 1
	}
	if p.pos == start { return 0, false }
	return v, true
}

clone_str :: proc(s: string, a: mem.Allocator) -> string {
	b := make([]u8, len(s), a)
	copy(b, s)
	return string(b)
}

// the set members' sort order: code point ascending (UTF-8 byte order
// is code point order), the order set_member's binary search assumes
set_member_less :: proc(x, y: ^string) -> bool {
	return strings.compare(x^, y^) < 0
}

/*
Set membership over the sorted members: a set is a membership question,
not a scan — one binary search replaces the per-member string compare,
and ANY_EQ_MAX bounds the sort (at parse) rather than every evaluation
(the matcher evaluates a set once per candidate token).
*/
set_member :: proc(members: []string, v: string) -> bool {
	lo, hi := 0, len(members)
	for lo < hi {
		mid := (lo + hi) / 2
		if strings.compare(members[mid], v) < 0 { lo = mid + 1 } else { hi = mid }
	}
	return lo < len(members) && strings.compare(members[lo], v) == 0
}

// the parse's own string clone: the bytes land in the pool's current
// block, which never grows past its reserve (a would-be overflow opens
// the next block instead), so an error path reclaims every literal with
// one delete per block
POOL_BLOCK :: 4096

pool_str :: proc(p: ^Parse_State, s: string) -> string {
	if len(p.pool) == 0 || len(p.pool[len(p.pool) - 1]) + len(s) > POOL_BLOCK {
		sz := POOL_BLOCK
		if len(s) > sz { sz = len(s) } // one over-long literal, its own block
		append(&p.pool, make([dynamic]u8, 0, sz, p.a))
	}
	blk := &p.pool[len(p.pool) - 1]
	off := len(blk^)
	append(blk, ..transmute([]u8)s)
	return transmute(string)blk^[off:off + len(s)]
}

// --- the grammar ---

parse_elem :: proc(p: ^Parse_State) -> (Query_Step, bool) {
	s, is_not_bang, ok := parse_compound(p)
	if !ok { return s, false }
	ps_ws(p)
	if is_not_bang && ps_peek(p) == '@' {
		return s, fail(p, p.pos, .Bad_Syntax) // a zero-width capture is always empty
	}
		if ps_byte(p, '@') {
			name, nok := ps_ident(p)
			if !nok { return s, fail(p, p.pos, .Bad_Syntax) }
			ix, has := p.cap_ix[name]
			if !has {
				ix = len(p.caps)
				append(&p.caps, Capture_Def{name = pool_str(p, name)})
				p.cap_ix[name] = ix
			}
			s.capture = ix
		}
	if p.err != .None { return s, false }
	return s, true
}

parse_compound :: proc(p: ^Parse_State) -> (Query_Step, bool /*is not!*/, bool) {
	if !ps_expect(p, '(') { return {}, false, false }
	ident, ok := ps_ident(p)
	if !ok { _ = fail(p, p.pos, .Bad_Syntax); return {}, false, false }
	switch ident {
	case "m":
		s, mok := parse_m(p)
		if !mok { return {}, false, false }
		if !ps_expect(p, ')') { return {}, false, false }
		// the quant lives inside the m parens; the grammar offers no
		// second site — `(m _ :0-2) :0-2` is Bad_Syntax
		if ps_peek(p) == ':' { _ = fail(p, p.pos, .Bad_Syntax); return {}, false, false }
		return s, false, true
	case "alt":
		s, aok := parse_alt(p)
		return s, false, aok
	case "not":
		// `!` is not an IDENT byte, so not! lexes as the
		// ident `not` plus a literal bang consumed here
		is_not_bang := false
		if ps_peek(p) == '!' {
			p.pos += 1
			is_not_bang = true
		}
		s, nok2 := parse_not(p, !is_not_bang)
		if !nok2 { return {}, false, false }
		if is_not_bang {
			s.zero_width = true
			s.quant = Quantifier{1, 1}
		}
		return s, is_not_bang, true
	case:
		_ = fail(p, p.pos, .Bad_Syntax)
		return {}, false, false
	}
}

// An m body: (fieldtest | '_')+ quant? — several fields AND, or the
// bare '_'. A mixed
// `(any ^… …)` turns the m into an alternation step, one branch per
// member carrying the plain preds too.
parse_m :: proc(p: ^Parse_State) -> (Query_Step, bool) {
	quant := Quantifier{1, 1}
	have_quant := false
	preds: [dynamic]Predicate = make([dynamic]Predicate, 0, 4, p.a)
	mixed: [dynamic]Predicate = make([dynamic]Predicate, 0, 4, p.a)
	wildcard := false
	seen: [Query_Field]bool // one test per field — the table ties it to the enum

	for p.err == .None {
		ps_ws(p)
		c := ps_peek(p)
		if have_quant && c != ')' {
			_ = fail(p, p.pos, .Bad_Syntax) // the quant is last inside the parens
			break
		}
		if c == ':' {
			q, qok := parse_quant(p)
			if !qok { break }
			quant = q
			have_quant = true
			continue
		}
		if c == ')' { break }
		if c == '"' || c == '(' {
			_ = fail(p, p.pos, .Bad_Syntax) // a value form where a field must come first
			break
		}
		ident, ok := ps_ident(p)
		if !ok { _ = fail(p, p.pos, .Bad_Syntax); break }
		if ident == "_" {
			if wildcard || len(preds) > 0 || len(mixed) > 0 {
				_ = fail(p, p.pos, .Bad_Syntax) // '_' is the whole body or nothing
				break
			}
			wildcard = true
			continue
		}
		if wildcard { _ = fail(p, p.pos, .Bad_Syntax); break }
		fi := Query_Field(-1)
		for name, f in FIELD_NAMES {
			if name == ident {
				fi = f
				break
			}
		}
		if int(fi) < 0 { _ = fail(p, p.pos, .Unknown_Field) }
		if p.err != .None { break }
		if seen[fi] { _ = fail(p, p.pos, .Bad_Syntax); break } // same field twice
		seen[fi] = true
		if fi == .Unknown { // boolean field; no value forms follow it
			append(&preds, Predicate{field = .Unknown, match = Flag_Match{}})
			continue
		}

		f := fi
		n_values := 0
		for p.err == .None {
			ps_ws(p)
			v := ps_peek(p)
			if v == '"' || v == '^' || v == '$' || v == '~' || v == '%' {
				pred, lok := parse_literal(p, f)
				if !lok { break }
				append(&preds, pred)
				n_values += 1
				continue
			}
			if v == '(' {
				group, is_mixed, gok := parse_group(p, f)
				if !gok { break }
				if is_mixed {
					if len(mixed) > 0 {
						// a second group never reaches a step — reclaim
						// it whole, members included
						free_members_backings(group, p.a)
						if len(group) > 0 { mem.free(raw_data(group), p.a) }
						_ = fail(p, p.pos, .Bad_Syntax); break
					}
					for x in group { append(&mixed, x) }
				} else {
					append(&preds, group[0])
				}
				// the values moved into this m's own containers; the
				// group's wrapper slice is the caller's to free
				if len(group) > 0 { mem.free(raw_data(group), p.a) }
				n_values += 1
				continue
			}
			if v == '_' { _ = fail(p, p.pos, .Bad_Value); break } // (m lemma _) → write (m _)
			break // quant or ')' ends the field's values
		}
		if p.err == .None && n_values == 0 {
			_ = fail(p, p.pos, .Bad_Syntax) // a field must be followed by a value
		}
	}
	if p.err != .None {
		free_members_backings(preds[:], p.a)
		free_members_backings(mixed[:], p.a)
		delete(preds)
		delete(mixed)
		return {}, false
	}

	if len(mixed) > 0 {
		// the (alt …) ban extends here: a synthesized branch step under
		// a bounded quant has the same varying-slack problem
		if quant.max != 1 && quant.max != -1 {
			free_members_backings(preds[:], p.a)
			free_members_backings(mixed[:], p.a)
			delete(preds)
			delete(mixed)
			return {}, fail(p, p.pos, .Bad_Quantifier)
		}
		if len(mixed) > ANY_MIXED_MAX {
			free_members_backings(preds[:], p.a)
			free_members_backings(mixed[:], p.a)
			delete(preds)
			delete(mixed)
			return {}, fail(p, p.pos, .Bad_Syntax)
		}
		branches := make([]Alt_Branch, len(mixed), p.a)
		for m, i in mixed {
			all := make([]Predicate, len(preds) + 1, p.a)
			copy(all, preds[:])
			all[len(preds)] = m
			bs := make([]Query_Step, 1, p.a)
			bs[0] = Query_Step{body = And_Body{predicates = all}, quant = Quantifier{1, 1}, capture = -1}
			branches[i] = Alt_Branch{steps = bs}
		}
		delete(preds)
		delete(mixed)
		if !count_steps(p, 1 + len(branches)) {
			free_branch_scratch(branches, p.a)
			delete(branches)
			return {}, false
		}
		return Query_Step{body = Alt_Body{alternatives = branches}, quant = quant, capture = -1}, true
	}
	delete(mixed)
	if !count_steps(p, 1) {
		free_members_backings(preds[:], p.a)
		delete(preds)
		return {}, false
	}
	out := make([]Predicate, len(preds), p.a)
	copy(out, preds[:])
	delete(preds)
	return Query_Step{body = And_Body{predicates = out}, quant = quant, capture = -1}, true
}

count_steps :: proc(p: ^Parse_State, n: int) -> bool {
	p.n_steps += n
	if p.n_steps > QUERY_STEPS_MAX { return fail(p, p.pos, .Bad_Syntax) }
	return true
}

// ':n' ':n-m' ':n-' ':?' ':*' ':+' — bounded max is capped at QUANT_MAX.
parse_quant :: proc(p: ^Parse_State) -> (Quantifier, bool) {
	at := p.pos
	if !ps_byte(p, ':') { return {}, fail(p, at, .Bad_Syntax) }
	c := ps_peek(p)
	if c == '?' { p.pos += 1; return Quantifier{0, 1}, true }
	if c == '*' { p.pos += 1; return Quantifier{0, -1}, true }
	if c == '+' { p.pos += 1; return Quantifier{1, -1}, true }
	n, ok := ps_int(p)
	if !ok { return {}, fail(p, at, .Bad_Syntax) }
	m := n
	unbounded := false
	if ps_byte(p, '-') {
		if ps_peek(p) >= '0' && ps_peek(p) <= '9' {
			m, ok = ps_int(p)
			if !ok { return {}, fail(p, p.pos, .Bad_Syntax) }
		} else {
			m = -1
			unbounded = true
		}
	}
	if !unbounded && m > QUANT_MAX { return {}, fail(p, at, .Bad_Quantifier) }
	if m != -1 && m < n { return {}, fail(p, at, .Bad_Quantifier) }
	return Quantifier{n, m}, true
}

// A prefixed or bare string literal → one predicate. `~` resolves
// through Parse_Options.groups (members ∪ the literal itself); `%`
// through Parse_Options.custom. Both are No_Group/No_Custom when
// absent — never a silent narrowing.
parse_literal :: proc(p: ^Parse_State, f: Query_Field) -> (Predicate, bool) {
	c := ps_peek(p)
	prefixed := c == '^' || c == '$' || c == '~' || c == '%'
	if prefixed {
		if ps_peek_at(p, 1) != '"' { return {}, fail(p, p.pos, .Bad_Syntax) }
		p.pos += 1
	}
	s, ok := ps_string(p)
	if !ok { return {}, false }
	if !prefixed {
		return Predicate{field = f, match = Eq_Match(pool_str(p, s))}, true
	}
	switch c {
	case '^':
		return Predicate{field = f, match = Prefix_Match(pool_str(p, s))}, true
	case '$':
		return Predicate{field = f, match = Suffix_Match(pool_str(p, s))}, true
	case '~':
		if p.opts.groups == nil { return {}, fail(p, p.pos, .No_Group) }
		gid, has := group_of(p.opts.groups, s)
		if !has { return {}, fail(p, p.pos, .No_Group) }
		members := p.opts.groups.groups[int(gid)].lemmas
		// the set path's one bound, wherever the members came from: an
		// (any …) literal list or a lemma group's expansion both compile
		// to the same Set predicate, and Set evaluation is a binary
		// search over the sorted members — bounded by cap, not by
		// budget. Checked before the make (the parser's bound rule)
		if len(members) + 1 > ANY_EQ_MAX { return {}, fail(p, p.pos, .Set_Capped) }
		set := make([]string, len(members) + 1, p.a)
		set[0] = pool_str(p, s)
		for m, i in members { set[i + 1] = pool_str(p, m) }
		sort_with_buffer(set, set_member_less, p.a)
		return Predicate{field = f, match = Set_Match{members = set}}, true
	case '%':
		if p.opts.custom == nil { return {}, fail(p, p.pos, .No_Custom) }
		proc_, has := p.opts.custom.procs[s]
		if !has { return {}, fail(p, p.pos, .No_Custom) }
		return Predicate{
			field = f,
			match = Custom_Match{
				name      = pool_str(p, s),
				custom    = proc_,
				user_data = p.opts.custom.user_data,
			},
		}, true
	case:
		return {}, fail(p, p.pos, .Bad_Syntax)
	}
	return {}, false
}

// '(' 'any' literal+ ')' or '(' 'fuzzy' STRING ':' int ')'. All-eq any
// → one Set predicate; any prefixed member → all members returned and
// the caller synthesizes an alternation.
parse_group :: proc(p: ^Parse_State, f: Query_Field) -> (members: []Predicate,
is_mixed: bool, ok: bool) {
	at := p.pos
	if !ps_expect(p, '(') { return nil, false, false }
	ident, got := ps_ident(p)
	if !got { _ = fail(p, p.pos, .Bad_Syntax); return nil, false, false }
	switch ident {
	case "any":
		found: [dynamic]Predicate = make([dynamic]Predicate, 0, 8, p.a)
		any_prefixed := false
		for p.err == .None {
			ps_ws(p)
			v := ps_peek(p)
			if v == ')' { break }
			if v != '"' && v != '^' && v != '$' && v != '~' && v != '%' {
				_ = fail(p, p.pos, .Bad_Syntax) // members are literals
				break
			}
			pred, lok := parse_literal(p, f)
			if !lok { break }
			if _, is_eq := pred.match.(Eq_Match); !is_eq { any_prefixed = true }
			append(&found, pred)
		}
		if p.err == .None && len(found) == 0 {
			_ = fail(p, p.pos, .Bad_Syntax) // (any) with nothing
		}
		if p.err == .None { _ = ps_expect(p, ')') }
		if p.err != .None {
			free_members_backings(found[:], p.a)
			delete(found)
			return nil, false, false
		}
		if any_prefixed {
			if len(found) > ANY_MIXED_MAX {
				free_members_backings(found[:], p.a)
				delete(found)
				return nil, true, fail(p, at, .Bad_Syntax)
			}
			out := make([]Predicate, len(found), p.a)
			copy(out, found[:])
			delete(found)
			return out, true, true
		}
		if len(found) > ANY_EQ_MAX {
			free_members_backings(found[:], p.a)
			delete(found)
			return nil, false, fail(p, at, .Bad_Syntax)
		}
		set := make([]string, len(found), p.a)
		for m, i in found { set[i] = string(m.match.(Eq_Match)) }
		sort_with_buffer(set, set_member_less, p.a)
		delete(found)
		out := make([]Predicate, 1, p.a)
		out[0] = Predicate{field = f, match = Set_Match{members = set}}
		return out, false, true
	case "fuzzy":
		ps_ws(p)
		s, sok := ps_string(p)
		if !sok { return nil, false, false }
		ps_ws(p)
		if !ps_expect(p, ':') { return nil, false, false }
		ps_ws(p)
		n, nok := ps_int(p)
		if !nok { _ = fail(p, p.pos, .Bad_Syntax); return nil, false, false }
		ps_ws(p)
		if !ps_expect(p, ')') { return nil, false, false }
		if n > FUZZY_DIST_MAX {
			return nil, false, fail(p, at, .Bad_Quantifier)
		}
		out := make([]Predicate, 1, p.a)
		out[0] = Predicate{
			field = f,
			match = Fuzzy_Match{
				pattern  = pool_str(p, s),
				distance = n,
				flags    = FUZZY_FLAGS_DEFAULT,
			},
		}
		return out, false, true
	case:
		_ = fail(p, p.pos, .Bad_Syntax)
		return nil, false, false
	}
}

// (alt m+ ')' quant?) — branches are plain m's,
// each branch quant.min >= 1 (the termination
// argument), alt quant max = 1 or unbounded (the memo's slack
// dimension must stay constant).
parse_alt :: proc(p: ^Parse_State) -> (Query_Step, bool) {
	at := p.pos
	branches: [dynamic]Alt_Branch = make([dynamic]Alt_Branch, 0, 4, p.a)
	for p.err == .None {
		ps_ws(p)
		if ps_peek(p) == ')' { break }
		b_at := p.pos // the branch's '('
		if !ps_expect(p, '(') { break }
		if !ps_ident_is(p, "m") {
			_ = fail(p, p.pos, .Bad_Syntax) // no nested alt/not inside alt
			break
		}
		b, bok := parse_m(p) // a bare m: no capture inside alt
		if !bok { break }
		if _, is_alt := b.body.(Alt_Body); is_alt {
			// a branch must be a plain m — a mixed
			// (any …) m compiles to an alternation step, and an
			// alternation under an alternation leaves the memo key
			// without the outer alt's owed
			_ = fail(p, b_at, .Bad_Syntax)
			break
		}
		if !ps_expect(p, ')') { break }
		if b.quant.min < 1 {
			_ = fail(p, p.pos, .Bad_Quantifier) // zero-consuming unit
			break
		}
		bs := make([]Query_Step, 1, p.a)
		bs[0] = b
		append(&branches, Alt_Branch{steps = bs})
		if len(branches) > ALT_BRANCH_MAX {
			_ = fail(p, p.pos, .Bad_Syntax)
			break
		}
	}
	if p.err == .None && len(branches) == 0 { _ = fail(p, p.pos, .Bad_Syntax) }
	if p.err == .None { _ = ps_expect(p, ')') }
	ps_ws(p)
	quant := Quantifier{1, 1}
	if p.err == .None && ps_peek(p) == ':' {
		q, qok2 := parse_quant(p)
		if !qok2 {
			free_branch_scratch(branches[:], p.a)
			delete(branches)
			return {}, false
		}
		quant = q
	}
	if p.err != .None {
		free_branch_scratch(branches[:], p.a)
		delete(branches)
		return {}, false
	}
	if quant.max != 1 && quant.max != -1 {
		free_branch_scratch(branches[:], p.a)
		delete(branches)
		return {}, fail(p, at, .Bad_Quantifier)
	}
	if !count_steps(p, 1 + len(branches)) {
		free_branch_scratch(branches[:], p.a)
		delete(branches)
		return {}, false
	}
	out := make([]Alt_Branch, len(branches), p.a)
	copy(out, branches[:])
	delete(branches)
	return Query_Step{body = Alt_Body{alternatives = out}, quant = quant, capture = -1}, true
}

// '(' 'not' m ')' quant? — consuming negation; not! takes no
// quantifier: a zero-width step cannot advance, so it would not
// terminate.
parse_not :: proc(p: ^Parse_State, allow_quant: bool) -> (Query_Step, bool) {
	ps_ws(p)
	if !ps_expect(p, '(') { return {}, false }
	_ = ps_ident_is(p, "m") || fail(p, p.pos, .Bad_Syntax) // a single m only
	if p.err != .None { return {}, false }
	inner, iok := parse_m(p)
	if !iok { return {}, false }
	and, is_and := inner.body.(And_Body)
	if !is_and {
		// a mixed (any …) m compiles to an alternation, and negation is
		// "all preds fail" — an alternation step has no predicates to
		// fail, so keeping them would match every token (not takes
		// a plain m)
		return {}, fail(p, p.pos, .Bad_Syntax)
	}
	if !ps_expect(p, ')') { return {}, false } // the inner m's close
	if !ps_expect(p, ')') { return {}, false } // the (not …) close
	ps_ws(p)
	quant := Quantifier{1, 1}
	if ps_peek(p) == ':' {
		if !allow_quant { return {}, fail(p, p.pos, .Bad_Syntax) }
		q, qok := parse_quant(p)
		if !qok { return {}, false }
		quant = q
	}
	if !count_steps(p, 1) { return {}, false }
	// keep only the predicates: a negated unit is "all preds fail"
	return Query_Step{
		body     = and,
		quant    = quant,
		capture  = -1,
		negated  = true,
	}, true
}

// ============================================================
// The sequence matcher
// ============================================================

/*
Per-attempt capture state: pushed when a captured
compound starts consuming, `end` stamped at each quantifier exit
attempt (greedy backtrack shrinks it to the accepted exit), discarded
wholesale when the attempt fails — only a committed match's stack is
copied out. Never read by match decisions, which is what keeps capture
state out of the memo key.
*/
Capture_Binding :: struct {
	def:   int,
	start: int,
	end:   int, // -1 until the compound exits its quantifier
}

Cont_Kind :: enum {
	Seq, // match steps[idx:]
	AltLoop, // re-enter the alt step's quantifier at iteration `iter`
}

Cont :: struct {
	kind:  Cont_Kind,
	steps: []Query_Step,
	idx:   int,
	alt:   ^Query_Step,
	iter:  int,
	bidx:  int, // the alt step's capture binding, -1 if none
	up:    int, // index into Match_Cursor.conts; -1 == the commit point
}

/*
The matcher's backtracking state: one entry per suspended choice point.
`conts` names the success path; `frames` holds what the recursive form
kept on the native stack — which branch to try next, which exit
position walks next, what to roll back on failure. Strict LIFO with the
conts stack: every frame is pushed by the matcher step that suspends
into a child and popped when the child's fate is known, so a frame is
exactly the choice state live below it.

Frame counts follow the same bound as bindings (pattern structure ×
stream length), never native stack depth: an alt repetition costs three
frames and one AltLoop cont, all cursor-owned — a repetition-heavy
pattern such as `(alt …):*` over a whole stream grows these arrays
where the recursive form grew the native stack.
*/
Frame_Kind :: enum {
	Seq_Wait, // a seq's step i runs below; failure truncates the step's Seq cont
	Fresh_Wait, // a step attempt runs below; failure rolls bindings back to mark and memos
	Alt_Branch, // an alt quantifier between branches; failure advances bi or takes the bottom exit
	And_Walk, // an and quantifier between exit positions; failure steps at down toward stop
	Quant_Exit, // the quantifier's bottom exit runs below; failure propagates
}

Frame :: struct {
	kind: Frame_Kind,
	s: ^Query_Step, // Fresh_Wait: the attempted step; Alt_Branch: the alt step
	cont: int, // Alt_Branch/And_Walk/Quant_Exit: the quantifier's continuation
	pos: int, // Fresh_Wait/Alt_Branch/Quant_Exit: entry position
	owed: int, // Fresh_Wait: the memo key's owed dimension
	mark: int, // Fresh_Wait: bindings rollback mark
	k: int, // Seq_Wait/Alt_Branch: the conts truncate mark
	iter: int, // Alt_Branch: quantifier entry iteration
	bidx: int, // Alt_Branch/And_Walk/Quant_Exit: capture binding, -1 if none
	bi: int, // Alt_Branch: next branch index (-1 before the first)
	at: int, // And_Walk: next exit position
	stop: int, // And_Walk: exit floor (start + min)
}

Match_Cursor :: struct {
	q:          ^Query,
	stream:     Token_Stream,
	next_start: int,
	ended:      bool, // enumeration finished

	bits:     []u32, // failure memo bitmap, n_ids × (n+1) × owed_dim
	owed_dim: int,
	n1:       int, // len(tokens) + 1 — the memo stride
	bound:    []bool, // token-index segment boundaries, len n+1

	// anchored scans walk the legal start positions directly instead of
	// testing every position (empty when the query has no ^)
	starts: []int,
	bi:     int, // scan index into starts

	bindings:  [dynamic]Capture_Binding,
	// the continuation stack: strict LIFO — the matcher pushes one entry
	// per seq descent and per alt-branch attempt, truncating to its push
	// mark when the attempt dies, so an entry's `up` chain is exactly the
	// live continuations below it. Index-linked, not pointer-linked: the
	// chain is inspectable and owns no lifetimes
	conts: [dynamic]Cont,
	// the backtracking stack: one frame per suspended choice point (the
	// recursive form kept these on the native stack). Same LIFO discipline,
	// same bound as bindings — pattern structure × stream length
	frames: [dynamic]Frame,
	match_end: int,
	count_only: bool, // query_count sets it: enumerate without building captures

	// work budget and stop-check: the budget counts predicate
	// evaluations, the check is polled once per candidate start
	work:        i64,
	work_budget: i64, // initialized from QUERY_WORK_BUDGET; tests shrink it
	check:       proc(user: rawptr) -> bool,
	user:        rawptr,
	err:         Query_Err, // .Interrupted / .Work_Capped after a false next_match

	fuzzy: Fuzzy_Scratch, // fold scratch (per cursor, no globals)

	a: mem.Allocator,
}

// One whole-stream segment boundary table: token index j is a
// boundary when a segment starts at j, ends at j−1, or j == n (the
// anchors fire at any supplied segment boundary). A segment edge
// snaps inward to a fully-contained token edge: the start boundary is
// the first token starting at or after the segment start, the end
// boundary the first token ending past the segment end — a byte edge
// that lands inside a token (or between tokens) still anchors at the
// nearest contained edge, on both sides symmetrically.
segment_boundaries :: proc(tokens: []Token, segments: []Segment,
                           a: mem.Allocator) -> []bool {
	n := len(tokens)
	b := make([]bool, n + 1, a)
	b[n] = true
	for seg in segments {
		// first token with start >= the segment's start
		lo := lower_bound(tokens, token_start, seg.span.start)
		if lo < n { b[lo] = true }
		// first token whose end passes the segment end
		lo2 := lower_bound(tokens, token_end, seg.span.end + 1)
		b[lo2] = true // == n when the segment ends with the stream
	}
	return b
}

/*
match_begin creates a cursor for one (query, stream) pair — the query
and stream are borrowed, the memo, boundary table, and binding stack
are owned (destroy with cursor_destroy). The Query must be the product
of query_parse (ids and memo geometry assigned); cursors on one Query
may run concurrently.
*/
match_begin :: proc(q: ^Query, stream: Token_Stream,
                    a := context.allocator) -> Match_Cursor {
	n := len(stream.tokens)
	total := q.n_ids * (n + 1) * q.owed_dim
	words := (total + 31) / 32
	if words * size_of(u32) > QUERY_MEMO_MAX_BYTES {
		// the refusal cursor: no bitmap, no boundary table, no
		// predicate work — ended at once with the typed error on
		// c.err, which query_match/query_count return and cursor
		// hosts read after match_begin
		c := Match_Cursor{
			q           = q,
			stream      = stream,
			ended       = true,
			work_budget = QUERY_WORK_BUDGET,
			err         = .Memo_Capped,
			a           = a,
		}
		fuzzy_scratch_init(&c.fuzzy, a)
		return c
	}
	c := Match_Cursor{
		q           = q,
		stream      = stream,
		bits        = make([]u32, words, a),
		owed_dim    = q.owed_dim,
		n1          = n + 1,
		bound       = segment_boundaries(stream.tokens, stream.segments, a),
		bindings    = make([dynamic]Capture_Binding, 0, 16, a),
		conts       = make([dynamic]Cont, 0, 32, a),
		frames      = make([dynamic]Frame, 0, 64, a),
		work_budget = QUERY_WORK_BUDGET,
		a           = a,
	}
	if q.anchor_start {
		// the anchor-legal positions, ascending: 0 is always legal (a
		// stream start), plus every boundary flag
		st: [dynamic]int = make([dynamic]int, 0, 64, a)
		append(&st, 0)
		for b, j in c.bound {
			if b && j > 0 { append(&st, j) }
		}
		c.starts = st[:]
	}
	fuzzy_scratch_init(&c.fuzzy, a)
	return c
}

cursor_destroy :: proc(c: ^Match_Cursor) {
	if c.bits != nil { delete(c.bits, c.a) }
	if c.bound != nil { delete(c.bound, c.a) }
	if c.starts != nil { delete(c.starts, c.a) }
	delete(c.bindings)
	delete(c.conts)
	delete(c.frames)
	fuzzy_scratch_destroy(&c.fuzzy)
}

memo_known_failed :: proc(c: ^Match_Cursor, id, pos, owed: int) -> bool {
	idx := ((id * c.n1) + pos) * c.owed_dim + owed
	w := c.bits[idx >> 5]
	if (w >> (u32(idx) & 31)) & 1 != 0 { return true }
	return false
}

memo_record_failed :: proc(c: ^Match_Cursor, id, pos, owed: int) {
	idx := ((id * c.n1) + pos) * c.owed_dim + owed
	c.bits[idx >> 5] |= 1 << (u32(idx) & 31)
}

token_field :: proc(t: ^Token, f: Query_Field) -> string {
	switch f {
	case .Surface: return t.surface
	case .Lemma:   return t.lemma
	case .Pos:     return t.pos
	case .Reading: return t.reading
	case .Unknown: return ""
	}
	return ""
}

pred_holds :: proc(c: ^Match_Cursor, p: ^Predicate, t: ^Token) -> bool {
	switch m in p.match {
	case Flag_Match:
		return t.kind == .Unknown
	case Eq_Match:
		return token_field(t, p.field) == string(m)
	case Prefix_Match:
		return strings.has_prefix(token_field(t, p.field), string(m))
	case Suffix_Match:
		return strings.has_suffix(token_field(t, p.field), string(m))
	case Set_Match:
		return set_member(m.members, token_field(t, p.field))
	case Fuzzy_Match:
		v := fold_value(&c.fuzzy, token_field(t, p.field), m.flags)
		pn := fold_pattern(&c.fuzzy, m.pattern, m.flags)
		return fuzzy_within(v, pn, m.distance, m.flags.transposition)
	case Custom_Match:
		return m.custom != nil && m.custom(t, m.user_data)
	}
	return false
}

// All preds hold with short-circuit; negated inverts to "all fail"
// (the consuming-not unit). Alt bodies never unit-test — the alt
// quantifier's branch loop is their consume path.
unit_matches :: proc(c: ^Match_Cursor, s: ^Query_Step, t: ^Token) -> bool {
	and, is_and := s.body.(And_Body)
	if !is_and { return false }
	if s.negated {
		for i in 0..<len(and.predicates) {
			c.work += 1
			if pred_holds(c, &and.predicates[i], t) { return false }
		}
		return true
	}
	for i in 0..<len(and.predicates) {
		c.work += 1
		if !pred_holds(c, &and.predicates[i], t) { return false }
	}
	return true
}

anchor_end_ok :: proc(c: ^Match_Cursor, j: int) -> bool {
	return j == len(c.stream.tokens) || c.bound[j]
}

/*
The matcher as one trampolined loop, not a mutual recursion: an
activation is entered by setting the act locals and continuing, and a
child's failure is delivered by resuming the top frame — the exact
suspension points the recursive form's native frames held. Success
propagates only from the commit point (cont < 0): the loop then
truncates conts to the attempt base once (the recursive unwinding
truncated them frame by frame; nothing reads conts during the unwind)
and leaves bindings — the committed captures — for attempt_start to
copy out.

Evaluation order is the depth-first order the recursive form visited:
alt branches left to right, quantifier exits greediest-first, each
alternative retried only after everything below it failed. The work
budget is polled at the same points (every quantifier entry, plus each
token of an and-quantifier's greedy run — except a unit the prefilter
already proved, which the run consumes untested; that evaluation was
counted once, in the prefilter) and memo failures are recorded
with the same keys (step id, position, owed) at the same rollback
points, so cap behavior is unchanged.
*/
Act_Kind :: enum {
	Act_Seq, // enter match steps[i:] under continuation up
	Act_Fresh, // enter one step attempt under continuation cont
	Act_Quant, // enter s's quantifier at iteration iter
	Act_Cont, // run the continuation cont at pos (cont < 0 commits)
	Act_Fail, // a child failed: resume the top frame
}

match_run :: proc(c: ^Match_Cursor, steps0: []Query_Step, pos0: int,
                  skip_first_unit: bool) -> bool {
	base := len(c.conts)

	skip_unit := skip_first_unit // parameters are immutable; the local is consumed
	kind := Act_Kind.Act_Seq
	s: ^Query_Step = nil
	steps := steps0
	i, up := 0, -1
	cont := -1
	pos := pos0
	iter, bidx := 0, -1

	for {
		switch kind {
		case .Act_Seq:
			if i >= len(steps) {
				cont = up
				kind = .Act_Cont
				continue
			}
			if i == len(steps) - 1 {
				// the tail step suspends nothing: its Seq cont could only
				// resume into the i == len hop (success goes straight to
				// up), and its Seq_Wait had no cont of its own to truncate
				// — the Fresh_Wait below rolls the attempt back alone.
				// Every legal pattern owes through this path with cont = up
				// (an AltLoop never sits directly under a multi-step seq:
				// alt branches are one m per branch), so the memo's owed
				// key is the zero it always was here.
				s = &steps[i]
				cont = up
				kind = .Act_Fresh
				continue
			}
			k := len(c.conts)
			append(&c.conts, Cont{kind = .Seq, steps = steps, idx = i + 1, up = up})
			append(&c.frames, Frame{kind = .Seq_Wait, k = k})
			s = &steps[i]
			cont = k
			kind = .Act_Fresh
		case .Act_Fresh:
			owed := 0
			if cont >= 0 && c.conts[cont].kind == .AltLoop {
				a := c.conts[cont].alt
				if a.quant.min > c.conts[cont].iter { owed = a.quant.min - c.conts[cont].iter }
			}
			// slack needs no key slot: the grammar bans bounded alt repetition,
			// so it is constant for every legal pattern
			if memo_known_failed(c, s.id, pos, owed) {
				kind = .Act_Fail
				continue
			}
			mark := len(c.bindings)
			fbidx := -1
			if s.capture >= 0 && !s.zero_width {
				append(&c.bindings, Capture_Binding{def = s.capture, start = pos, end = -1})
				fbidx = len(c.bindings) - 1
			}
			append(&c.frames, Frame{
				kind = .Fresh_Wait, s = s, pos = pos, owed = owed, mark = mark, bidx = fbidx,
			})
			if s.zero_width {
				// (not! …): succeeds iff there is no token or its preds all fail
				andb, _ := s.body.(And_Body)
				fail_all := true
				if pos < len(c.stream.tokens) {
					tok := &c.stream.tokens[pos]
					for pi in 0..<len(andb.predicates) {
						c.work += 1
						if pred_holds(c, &andb.predicates[pi], tok) { fail_all = false; break }
					}
				}
				if !fail_all {
					kind = .Act_Fail
					continue
				}
				kind = .Act_Cont // cont/pos unchanged
				continue
			}
			iter = 0
			bidx = fbidx
			kind = .Act_Quant
		case .Act_Quant:
			if c.work_budget > 0 && c.work > c.work_budget {
				c.err = .Work_Capped
				kind = .Act_Fail
				continue
			}
			skip := skip_unit
			skip_unit = false // the flag is the entry step's only
			can_more := s.quant.max < 0 || iter < s.quant.max
			if can_more {
				if _, is_alt := s.body.(Alt_Body); is_alt {
					append(&c.frames, Frame{
						kind = .Alt_Branch, s = s, cont = cont, pos = pos,
						iter = iter, bidx = bidx, bi = -1, k = len(c.conts),
					})
					// entering the branch loop is resuming it with a failure:
					// the resume path truncates, advances the branch index, and
					// starts branch 0 — hence bi = -1
					kind = .Act_Fail
					continue
				}
				// And_Body: the greedy descent is a loop, not self-recursion: an
				// and-quantifier's run length is bounded by the stream, not
				// the pattern, and the native stack is not a budget
				// dimension (the work budget counts evaluations, not depth)
				start := pos
				cur, rep := pos, iter
				capped := false
				for {
					if skip {
						// the prefilter proved this unit at this position;
						// its budget poll already gated the identical work
						// count at the scan level, so the consume is pure
						skip = false
					} else {
						if cur >= len(c.stream.tokens) { break }
						if c.work_budget > 0 && c.work > c.work_budget {
							capped = true
							break
						}
						if !unit_matches(c, s, &c.stream.tokens[cur]) { break }
					}
					cur += 1
					rep += 1
					if s.quant.max >= 0 && rep >= s.quant.max { break }
				}
				if capped {
					c.err = .Work_Capped
					kind = .Act_Fail
					continue
				}
				// the exits walk deepest-first — greediest position first,
				// the same order the per-token recursion's unwinding
				// visited, none shallower than the min-th repetition
				stop := start + s.quant.min
				if cur < stop {
					kind = .Act_Fail
					continue
				}
				append(&c.frames, Frame{kind = .And_Walk, cont = cont, bidx = bidx, at = cur, stop = stop})
				if bidx >= 0 { c.bindings[bidx].end = cur }
				pos = cur
				kind = .Act_Cont
				continue
			}
			// the quantifier's bottom exit: stop repeating here — each exit
			// attempt re-stamps the binding's end; the accepted exit is the
			// one whose continuation survived
			if iter >= s.quant.min {
				append(&c.frames, Frame{kind = .Quant_Exit, bidx = bidx, cont = cont, pos = pos})
				if bidx >= 0 { c.bindings[bidx].end = pos }
				kind = .Act_Cont
				continue
			}
			kind = .Act_Fail
		case .Act_Cont:
			if cont < 0 {
				// the commit point: the whole match ends here
				if c.q.anchor_end && !anchor_end_ok(c, pos) {
					kind = .Act_Fail
					continue
				}
				c.match_end = pos
				resize(&c.conts, base)
				resize(&c.frames, 0)
				return true
			}
			ck := &c.conts[cont]
			switch ck.kind {
			case .Seq:
				steps = ck.steps
				i = ck.idx
				up = ck.up
				kind = .Act_Seq
			case .AltLoop:
				s = ck.alt
				cont = ck.up
				iter = ck.iter
				bidx = ck.bidx
				kind = .Act_Quant
			}
		case .Act_Fail:
			if len(c.frames) == 0 {
				// every waiter truncated its conts on the way out; the
				// resize is the documented no-op that states the invariant
				resize(&c.conts, base)
				return false
			}
			f := &c.frames[len(c.frames) - 1]
			switch f.kind {
			case .Seq_Wait:
				resize(&c.conts, f.k)
				resize(&c.frames, len(c.frames) - 1)
			case .Fresh_Wait:
				// the attempt (and every binding it pushed) is discarded
				resize(&c.bindings, f.mark)
				memo_record_failed(c, f.s.id, f.pos, f.owed)
				resize(&c.frames, len(c.frames) - 1)
			case .Alt_Branch:
				resize(&c.conts, f.k)
				f.bi += 1
				alts, _ := f.s.body.(Alt_Body)
				if f.bi < len(alts.alternatives) {
					append(&c.conts, Cont{
						kind = .AltLoop, alt = f.s, iter = f.iter + 1, bidx = f.bidx, up = f.cont,
					})
					s = &alts.alternatives[f.bi].steps[0] // one m per branch
					cont = f.k
					pos = f.pos
					kind = .Act_Fresh
					continue
				}
				// branches exhausted: the bottom exit at the entry position,
				// or outright failure below min
				fiter, fmin := f.iter, f.s.quant.min
				fbidx, fcont, fpos := f.bidx, f.cont, f.pos
				resize(&c.frames, len(c.frames) - 1)
				if fiter >= fmin {
					append(&c.frames, Frame{kind = .Quant_Exit, bidx = fbidx, cont = fcont, pos = fpos})
					if fbidx >= 0 { c.bindings[fbidx].end = fpos }
					bidx = fbidx
					cont = fcont
					pos = fpos
					kind = .Act_Cont
					continue
				}
			case .And_Walk:
				f.at -= 1
				if f.at >= f.stop {
					if f.bidx >= 0 { c.bindings[f.bidx].end = f.at }
					cont = f.cont
					pos = f.at
					kind = .Act_Cont
					continue
				}
				resize(&c.frames, len(c.frames) - 1)
			case .Quant_Exit:
				resize(&c.frames, len(c.frames) - 1)
			}
		}
	}
}

// The byte span of a token range: offsets from the tokens themselves,
// doc from the stream — callers never re-derive. An empty range
// (a zero-run capture) is the zero-width span at that position.
range_span :: proc(c: ^Match_Cursor, start, end: int) -> Span {
	n := len(c.stream.tokens)
	assert(start <= end && end <= n)
	if start < end {
		return Span{
			doc   = c.stream.doc,
			start = c.stream.tokens[start].start,
			end   = c.stream.tokens[end - 1].end,
		}
	}
	at := start
	if at > n { at = n }
	if at < n {
		b := c.stream.tokens[at].start
		return Span{doc = c.stream.doc, start = b, end = b}
	}
	last := 0
	if n > 0 { last = c.stream.tokens[n - 1].end }
	return Span{doc = c.stream.doc, start = last, end = last}
}

/*
next_match returns the next non-overlapping match after the previous
one (leftmost-greedy candidate scanning in between), or false when the
enumeration is over. `a` owns the returned captures slice. A false
return with cursor.err != .None means the run aborted (Interrupted via
the stop-check, or Work_Capped by the budget); otherwise it is simply
the end of the stream.
*/
next_match :: proc(c: ^Match_Cursor, a := context.allocator) -> (Match, bool) {
	if c.ended { return {}, false }
	n := len(c.stream.tokens)

	// first-step prefilter: when step 0 must consume a matching token,
	// an attempt where it cannot hold is provably dead, so the matcher
	// is never entered there. Plain m (min >= 1): progress needs the
	// unit to hold and exiting needs iter >= min >= 1. An alt step
	// (min >= 1): the exit is likewise unavailable at entry, so success
	// must route through a branch's consume path — and parse_alt's
	// invariants (one plain m per branch, branch min >= 1, no nesting)
	// make that path require unit_matches on the branch's m. The
	// prefilter runs the same units in the same order, and a plain-m
	// pass feeds the attempt (pf_first's `skip`): the proven unit is
	// consumed untested, so each candidate position pays step 0's unit
	// once — in the prefilter. The skipped positions record no memo
	// failures, and none are ever read — no attempt runs there, and
	// AltLoop re-entry always advances because every branch consumes).
	// Zero-width and optional first steps keep the full attempt.
	use_pf := false
	if len(c.q.steps) > 0 {
		s0 := &c.q.steps[0]
		if !s0.zero_width && s0.quant.min >= 1 { use_pf = true }
	}

	if c.q.anchor_start {
		// anchored: only anchor-legal positions are candidate starts,
		// so the scan walks the boundary list
		// instead of testing every position
		for c.bi < len(c.starts) {
			pos := c.starts[c.bi]
			c.bi += 1
			if pos < c.next_start { continue }
			if pos > n { break }
			if c.check != nil && c.check(c.user) {
				c.err = .Interrupted
				c.ended = true
				return {}, false
			}
			if c.work_budget > 0 && c.work > c.work_budget {
				c.err = .Work_Capped
				c.ended = true
				return {}, false
			}
			if use_pf && pos < n {
				ok, skip := pf_first(c, &c.q.steps[0], pos)
				if !ok { continue }
				m, has := attempt_start(c, pos, a, skip)
				if has { return m, true }
				continue
			}
			m, ok := attempt_start(c, pos, a, false)
			if ok { return m, true }
		}
	} else {
		for pos := c.next_start; pos <= n; pos += 1 {
			if c.check != nil && c.check(c.user) {
				c.err = .Interrupted
				c.ended = true
				return {}, false
			}
			if c.work_budget > 0 && c.work > c.work_budget {
				c.err = .Work_Capped
				c.ended = true
				return {}, false
			}
			if use_pf && pos < n {
				ok, skip := pf_first(c, &c.q.steps[0], pos)
				if !ok { continue }
				m, has := attempt_start(c, pos, a, skip)
				if has { return m, true }
				continue
			}
			m, ok := attempt_start(c, pos, a, false)
			if ok { return m, true }
		}
	}
	c.ended = true
	return {}, false
}

// first-step viability at a candidate start, both prefilterable
// shapes: a plain m's unit, or for an alt step any branch's unit
// (branches are single plain m's — the grammar invariant the
// matcher's branch loop already relies on). The plain-m verdict
// carries into the attempt as `skip`: the run's first unit has just
// been proven, so the quantifier consumes it untested and the position
// pays one evaluation, not two. An alt's verdict cannot carry — which
// branch holds is the attempt's own first question, and its branch
// order is its evaluation order.
pf_first :: #force_inline proc(c: ^Match_Cursor, s0: ^Query_Step, pos: int) -> (ok: bool,
skip: bool) {
	if alts, is_alt := s0.body.(Alt_Body); is_alt {
		for bi in 0..<len(alts.alternatives) {
			if unit_matches(c, &alts.alternatives[bi].steps[0], &c.stream.tokens[pos]) {
				return true, false
			}
		}
		return false, false
	}
	return unit_matches(c, s0, &c.stream.tokens[pos]), true
}

// one candidate start: run the pattern attempt and, on success, fix the
// resume point. A false return with c.err == .None means the position
// is dead — the scan continues. `skip_first` says the prefilter already
// proved step 0's plain-m unit at this position; the attempt consumes
// that unit untested (pf_first's rule). Force-inlined: it sits on the
// per-position path, and a real call there costs more than the loop
// saves.
attempt_start :: #force_inline proc(c: ^Match_Cursor, pos: int, a: mem.Allocator,
                                   skip_first: bool) -> (Match, bool) {
	c.match_end = -1
	ok := match_run(c, c.q.steps, pos, skip_first)
	if ok && c.match_end > pos {
		m := Match{
			start = pos,
			end   = c.match_end,
			span  = range_span(c, pos, c.match_end),
		}
		if !c.count_only {
			m.captures = make([]Capture, len(c.bindings), a)
			for b, i in c.bindings {
				m.captures[i] = Capture{
					def   = b.def,
					start = b.start,
					end   = b.end,
					span  = range_span(c, b.start, b.end),
				}
			}
		}
		c.next_start = c.match_end
		resize(&c.bindings, 0)
		resize(&c.conts, 0)
		resize(&c.frames, 0)
		return m, true
	}
	resize(&c.bindings, 0)
	resize(&c.conts, 0)
	resize(&c.frames, 0)
	return {}, false
}

/*
query_match enumerates non-overlapping matches into `a` until `limit`
is reached (mandatory, > 0: no unbounded
materialization; limit < 1 is .Bad_Argument). `truncated` says whether
one more match existed past the limit. `check` is the stop-check,
polled once per candidate start: a true aborts with .Interrupted
(hosts wire it to their cancel tokens). Cap-legal but runaway work
aborts with .Work_Capped under QUERY_WORK_BUDGET, and a pattern ×
stream combination whose failure memo would exceed QUERY_MEMO_MAX_BYTES
refuses before any work with .Memo_Capped.
*/
query_match :: proc(q: ^Query, stream: Token_Stream, limit: int, a: mem.Allocator,
                    check: proc(user: rawptr) -> bool = nil, user: rawptr = nil,
                    ) -> (Query_Result, Query_Err) {
	if limit < 1 { return {}, .Bad_Argument }
	c := match_begin(q, stream, a)
	c.check = check
	c.user = user
	// the list grows to the real count, never the limit — the first
	// allocation rides the stream's scale (a fixture-sized stream
	// reserves almost nothing; a novel-sized one skips its first
	// grow-and-copy cycles)
	hint := min(limit, max(16, len(stream.tokens) / 256))
	matches := make([dynamic]Match, 0, hint, a)
	for len(matches) < limit {
		m, ok := next_match(&c, a)
		if !ok { break }
		append(&matches, m)
	}
	truncated := false
	if len(matches) == limit {
		c.count_only = true // the peek asks only whether one more exists —
		// building its captures on `a` would abandon them there
		_, ok := next_match(&c, a)
		if ok { truncated = true }
	}
	err := c.err
	cursor_destroy(&c)
	return Query_Result{matches = matches[:], truncated = truncated}, err
}

/*
query_count enumerates matches without building Match structs and
stops the moment count == cap: the cap is the work bound, so there is
no stop-check — saturating early *is* the bound.
Scratch lives on `a` like every other public proc. The boolean says
saturation happened (hosts render "≥ cap matches"). A
cancellation-heavy caller drives the cursor itself (`match_begin`,
`count_only`, `Match_Cursor.check`). `err` is .None on a complete or
saturated enumeration; cap < 1 is .Bad_Argument, and the run-time
bounds (.Memo_Capped, .Work_Capped) surface here too — a partial
count with an error is not a population answer.
*/
query_count :: proc(q: ^Query, stream: Token_Stream, cap: int,
                    a: mem.Allocator) -> (count: int, saturated: bool, err: Query_Err) {
	if cap < 1 { return 0, false, .Bad_Argument }
	c := match_begin(q, stream, a)
	c.count_only = true
	for count < cap {
		_, ok := next_match(&c, a)
		if !ok { break }
		count += 1
	}
	saturated = count == cap
	err = c.err
	cursor_destroy(&c)
	return count, saturated, err
}
