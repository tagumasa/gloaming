package gloaming

/*
The library-side view of one annotated token (one morpheme). gloaming
never imports a morphological analyzer: the host adapts its output into
[]Token (from moli: a field-for-field copy of moli.Morpheme — `surface`
stays a view into the source text).
*/
/*
The token's provenance — exactly one state live per token. A
dictionary row backs it, it was synthesized (a compound merge; lemma =
surface by the compound rule), or the analyzer's unknown rule produced
it (lemma = surface, reading "*"). The GLB1 record's meta bits are
this enum on the wire.
*/
Token_Kind :: enum {
	Dictionary,
	Idless,
	Unknown,
}

Token :: struct {
	surface:  string,
	lemma:    string,
	pos:      string, // comma-joined hierarchy incl. conjugation form
	reading:  string, // katakana (ja) / pinyin (zh) / "*"
	start:    int, // byte offset into the source text
	end:      int,
	cost:     i16, // Viterbi/emission cost; segment sums are the proofreading anomaly signal (0 on id-less schemas)
	kind:     Token_Kind,
	entry_id: i32, // dictionary row on the analyzer that produced it — live only for .Dictionary; the row-less kinds stay negative
}

// the token fields the shared lower_bound seeks on
token_start :: proc(t: ^Token) -> int { return t.start }
token_end   :: proc(t: ^Token) -> int { return t.end }

Doc_Id :: distinct u32

/*
A half-open [start, end) byte range in one document. Spans are the
evidence currency: matches, mentions, and relations all report them,
so anything the engines claim can be shown back in the text it came
from.
*/
Span :: struct {
	doc:   Doc_Id,
	start: int,
	end:   int,
}

/*
Caller-supplied containers: the host outline layer's chapters and
paragraphs, sentences wherever the host decides they come from.
Segments are the co-occurrence windows and the sub-corpus boundaries —
gloaming consumes them, it does not derive them.
*/
Segment_Kind :: enum {
	Chapter,
	Paragraph,
	Sentence,
}

Segment :: struct {
	kind: Segment_Kind,
	span: Span,
}

/*
The stream handle every read API takes instead of a bare
`[]Token` + `[]Segment` pair: the matcher's anchors,
KWIC's clamping, and freq scoping all read segments through it, and
every `Span` those APIs produce stamps `doc` — otherwise the evidence
currency comes back half-filled. Hosts assemble streams from store
reads; empty `segments` means one whole-stream segment.
*/
Token_Stream :: struct {
	doc:      Doc_Id,
	tokens:   []Token,
	segments: []Segment,
}
