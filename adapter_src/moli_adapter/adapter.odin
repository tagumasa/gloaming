/*
The moli adapter: the bridge
between moli's morphemes and gloaming's Tokens. gloaming's core never
imports moli by rule; this package imports both and lives outside src/
for that reason. Hosts consume it — never the other way around.

Contract summary (verified against moli's final API):

  - adapt is a field copy plus one mapping: moli's is_unknown /
    entry_id pair becomes Token_Kind — .Unknown when is_unknown,
    .Idless for a row-less known morpheme (entry_id -1),
    .Dictionary otherwise. `surface` stays a zero-copy view into the
    tokenized text; start/end are byte offsets into that text.
    Morpheme's locale/char_class/reading_jyutping have no Token
    counterpart and are dropped (JP corpora; a char class is
    recoverable from the surface when a feature wants one).
  - entry_id copies through: the morpheme's dictionary row (index into
    the analyzer's surface-sorted entries), -1 for unknowns. Stable
    across qdct save/restore and moli.clone; add_user_entries re-sorts
    and renumbers, so ids taken before a merge are stale after it —
    detect with dictionary_hash below, re-resolve with moli.entry_info
    (whose lemma is the raw entry value; the "*"→surface fallback is a
    Morpheme rule, not an entry rule). Merge-then-tokenize is the safe
    order; variant_analyzer exists for exactly that shape.
  - Unknown morphemes carry their surface as lemma with reading "*" —
    a moli guarantee (the Morpheme rule), so freq_table's lemma
    counting never silently skips unknowns, with no adapter fix-up.
  - lemma is never "*": moli falls a dictionary "*" back to the
    surface. pos is one comma-joined hierarchy string (the ^"名詞,"
    prefix convention); reading is katakana, "*", or self-named for
    symbol entries (the ipadic convention).
  - Token string fields stay views: surface into the tokenized text,
    lemma/pos/reading into the analyzer's dictionary memory. Tokens
    are valid while BOTH the text and the analyzer live — the store's
    add_document clones the dictionary side and re-points surfaces,
    ending that duty for stored documents.
  - Options policy: the zero Tokenize_Options — normalize_nfc OFF,
    strict_utf8 OFF — is the shape every measured number rests on: with NFC
    off, surfaces index the caller's text; with it on, moli's arena
    copy. Hosts wanting NFC pre-normalize with moli.normalize_nfc and
    own the result (which may be the input itself, zero-copy) before
    feeding this adapter. strict_utf8 passes through for hosts that
    want ingestion to reject malformed bytes with their offsets
    instead of degrading them to unknown morphemes. opts passes
    through verbatim, so moli's later fields ride too:
    unk_cost_bias/unk_cost_per_rune tune the search (never the
    emitted Morpheme costs), and cancel_token aborts a running call
    cross-thread with Cancelled_Error at the byte offset reached —
    moli's own mechanism, distinct from the core's stop-check
    convention, which covers gloaming passes and not host-side
    tokenization.
  - Errors pass through as moli's types; render them with
    moli.tokenize_error_message / moli.load_error_message rather than
    inventing wording here.
*/
package moli_adapter

import "core:mem"
import "core:os"

import gl "gloaming:gloaming"
import moli "moli:moli"

// adapt copies morphemes into Tokens, rebasing byte offsets by `base`
// (a multi-document concatenated feed; the store path passes 0). Appends to
// out — make or clear it beforehand. The zero-copy contract is the
// package header's: nothing here allocates.
adapt :: proc(ms: []moli.Morpheme, base: int, out: ^[dynamic]gl.Token) {
	for m in ms {
		kind := gl.Token_Kind.Dictionary
		if m.is_unknown {
			kind = .Unknown
		} else if m.entry_id < 0 {
			kind = .Idless
		}
		append(out, gl.Token{
			surface  = m.surface,
			lemma    = m.lemma,
			pos      = m.pos,
			reading  = m.reading,
			start    = base + m.start,
			end      = base + m.end,
			kind     = kind,
			cost     = m.cost,
			entry_id = m.entry_id,
		})
	}
}

// tokenize_document is the one-call path: tokenize into `arena`,
// adapt, then free the morpheme slice — it never escapes. The Token
// views follow the adapt contract; base passes through to it.
// `arena` receives moli's request-scoped Viterbi lattice as well as
// the morphemes, so pass a reusable mem.Arena and free_all between
// documents: an arena sink measured 1.9x end-to-end over a
// default-allocator sink on the bench novel, with a ~64 MiB high-water
// per 240-KiB call (~273 B per input byte) as the sizing rule.
tokenize_document :: proc(an: ^moli.Analyzer, text: string, opts: moli.Tokenize_Options,
                          base: int, out: ^[dynamic]gl.Token,
                          arena: mem.Allocator) -> moli.Tokenize_Err {
	ms: [dynamic]moli.Morpheme = make([dynamic]moli.Morpheme, 0, 64, arena)
	defer delete(ms)
	if terr := moli.tokenize_into_opt(an, text, opts, &ms, arena); terr != nil {
		return terr
	}
	adapt(ms[:], base, out)
	return nil
}

/*
markdown_segments derives Chapter ('#' heading lines, each spanning to
the next heading) and Paragraph (blank-line-separated runs) byte spans
from markdown text — the adapter's outline util. Caller-supplied segments
remain the rule; this is a convenience, not a default. Spans are
rebased by
base and stamped with doc; entries append to out. The chapter-closing
patch only sees entries added by this call, so one `out` may carry
several documents.
*/
markdown_segments :: proc(text: string, base: int, doc: gl.Doc_Id,
                          out: ^[dynamic]gl.Segment) {
	start_len := len(out^)
	n := len(text)
	para_start := -1
	line_start := 0
	// -1 means no paragraph is open; the guard keeps a leading heading
	// from emitting a phantom [-1,0) paragraph
	flush_para :: proc(out: ^[dynamic]gl.Segment, base, s, e: int, doc: gl.Doc_Id) {
		if s >= 0 && e > s {
			append(out, gl.Segment{
				kind = .Paragraph,
				span = {doc = doc, start = base + s, end = base + e},
			})
		}
	}
	for i := 0; i <= n; i += 1 {
		if i == n || text[i] == '\n' {
			line := text[line_start:i]
			blank := true
			for c in line {
				if c != ' ' && c != '\t' && c != '\r' { blank = false }
			}
			if len(line) > 0 && line[0] == '#' { // chapter heading line
				flush_para(out, base, para_start, line_start, doc)
				para_start = -1
				// chapter spans to the next heading — end patched after
				append(out, gl.Segment{
					kind = .Chapter,
					span = {doc = doc, start = base + line_start, end = base + n},
				})
			}
			if blank {
				flush_para(out, base, para_start, line_start, doc)
				para_start = -1
			} else if para_start < 0 {
				para_start = line_start
			}
			line_start = i + 1
		}
		if i == n { break }
	}
	flush_para(out, base, para_start, n, doc)
	// close each chapter at the next chapter this call appended
	for j in start_len..<len(out^) {
		if out^[j].kind != .Chapter { continue }
		for k in j + 1..<len(out^) {
			if out^[k].kind == .Chapter {
				out^[j].span.end = out^[k].span.start
				break
			}
		}
	}
}

/*
load_analyzer is the dictionary-loading policy in one place: restore a
qdct snapshot when one exists (measured 0.07 s restore against a
seconds-scale CSV import), otherwise import the CSV and write the
snapshot for next time. A corrupt or unreadable snapshot degrades to
the CSV path and rewrites it; a failed snapshot write degrades to
importing every time — both are visible as the snapshot file's state,
never as a wrong analyzer.

The snapshot does not carry Load_Options: it restores whatever options
built it. qdct_path must therefore name a snapshot of THIS lex_path
under THESE opts — derive the file name from the load recipe (lexicon
path + Load_Options + user-entry batches), not from the lexicon alone.
Dictionary identity AFTER load is a different question and needs no
naming convention: dictionary_hash is load-path independent, so a
restored analyzer hashes equal to the import that built it (asserted
in adapter_tests). qdct_path == "" skips the snapshot tier entirely.
*/
load_analyzer :: proc(qdct_path: string, lex_path: string, lang: moli.Language,
                      opts: moli.Load_Options, a: mem.Allocator) -> (moli.Analyzer, moli.Load_Err) {
	if qdct_path != "" && os.exists(qdct_path) {
		ran, rlerr := moli.load_qdct_mmap(qdct_path, a)
		if rlerr == nil { return ran, nil }
	}
	an, lerr := moli.load(lang, lex_path, opts, a)
	if lerr != nil { return an, lerr }
	if qdct_path != "" {
		_ = moli.save_qdct(&an, qdct_path, a) // best effort — see above
	}
	return an, nil
}

/*
dictionary_hash is the content address behind Payload_Key's
dict_version: moli's entries_hash — FNV-1a over
the fields entry_info exposes, in surface-sorted order. It is load-path
independent (CSV import, qdct restore, and clone hash equal), and
add_user_entries always changes it — exactly the invalidation user
dictionaries must carry. A changed hash also means every entry_id
taken earlier is stale (see the package header). moli stamps it once
at every construction path (load, qdct restore, clone, merge) and
stats reads the field, so this wrapper is O(1).
*/
dictionary_hash :: proc(an: ^moli.Analyzer) -> (u64, moli.Save_Err) {
	s, err := moli.stats(an)
	if err != nil { return 0, err }
	return s.entries_hash, nil
}

/*
variant_analyzer is the user-dictionary shape that never produces a
stale id: clone the base, then merge the entries into the private
copy — the base keeps its dictionary state (and hash) untouched, and
the variant is tokenized AFTER its merge, so every morpheme it emits
carries a fresh id. The fiction-corpus workflow (作中人名辞書):
one shared base, one variant per project. On failure nothing needs
freeing — a failed merge frees the clone here; cerr is set when the
clone itself failed (a torn-down or OOM-exhausted base), uerr when
add_user_entries rejected the batch (empty surface rejects it whole).
*/
variant_analyzer :: proc(base: ^moli.Analyzer, entries: []moli.User_Entry,
                         a: mem.Allocator) -> (an: moli.Analyzer,
                                              cerr: moli.Save_Err,
                                              uerr: moli.Load_Err) {
	an, cerr = moli.clone(base, a)
	if cerr != nil { return {}, cerr, nil }
	uerr = moli.add_user_entries(&an, entries)
	if uerr != nil {
		moli.free(&an)
		return {}, nil, uerr
	}
	return an, nil, nil
}

/*
payload_resolver is the GLB1 read path against a live analyzer
(gl.payload_decode's Payload_Resolver): it returns exactly the strings
the producing tokenize put on the token — moli's entry row via
entry_info, with the Morpheme rules re-applied, since Entry_Info is the
raw storage. The lemma falls back to the surface on "*" or empty, the
same rule the Morpheme layer applies; pos and reading pass through
untouched ("*" readings stay "*"). ok=false covers both entry_info
refusals: an id outside the analyzer's range — a stale id, which a
correctly keyed payload (dict_version = dictionary_hash) can never
produce — and a torn-down analyzer (.Unavailable).
*/
payload_resolver :: proc(ctx: rawptr, id: i32, surface: string) ->
	(pos, lemma, reading: string, ok: bool) {
	an := cast(^moli.Analyzer)ctx
	info, iok, ierr := moli.entry_info(an, id)
	if ierr != nil || !iok { return "", "", "", false }
	lemma = info.lemma
	if lemma == "*" || lemma == "" { lemma = surface }
	return info.pos, lemma, info.reading, true
}

/*
payload_tokens is the one-call decode: GLB1 blob + the text it indexes
+ the analyzer whose dictionary the entry_refs point into. Every
decoded Token matches what tokenize_document produced for the same
(text, dictionary, options) — asserted in adapter_tests (and the
bench's payload rows exercise the same path at corpus scale).
The decoded tokens borrow like the adapter's own: surfaces point into
`text`, resolved strings into the analyzer — the store's add_document
ends both duties with its clones.
*/
payload_tokens :: proc(an: ^moli.Analyzer, blob: []u8, text: string,
                       a: mem.Allocator) -> ([]gl.Token, gl.Store_Err) {
	return gl.payload_decode(blob, text, payload_resolver, an, a)
}
