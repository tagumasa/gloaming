/*
The GLB1 payload format: one
immutable tokenized document version as bytes, content-addressed by
Payload_Key. Tokenization is a pure function of (text, dictionary,
options), so a payload reproduces its token stream exactly and never
needs re-computation — the store tiers treat it as the unit of truth.

The format is the entry_ref design: strings are NOT stored. Each 16-byte
record carries the producing analyzer's dictionary row (`entry_ref`)
plus byte offsets and cost; pos/lemma/reading are resolved through that
row at read time via the caller's Payload_Resolver (the adapter wires
it to the analyzer). Unknown tokens and id-less known
tokens (synthesized — compound merges — that no dictionary row backs)
carry material: their pos string, and for id-less known the reading
too, is inlined in a u16 length-prefixed tail (an unknown's lemma is
the surface by the analyzer's unknown rule and its reading is "*"; an
id-less known token's lemma is the surface by the compound rule);
surfaces are never stored — decode re-slices the caller's text, which
the header's text_len pins.

Records are fixed-width and the header is a fixed 48 bytes, so an
mmapped blob answers random access to any token without a scan — there
is no separate offset table; the record array IS the offset table.

Distribution compression is a separate wrapper (payload_compress): a
GLBZ-framed raw DEFLATE stream. The mmap path stays uncompressed;
compression is for shipping corpora, not for reading them.
*/
package gloaming

import "core:bytes"
import "core:compress/zlib"
import "core:mem"

PAYLOAD_MAGIC       :: "GLB1"
// v2 assigns meta bit 17 and the id-less-known tail entries (below); the
// geometry is unchanged and a v1 encoder could never emit a bit-17 record,
// so readers accept both versions and only writers are pinned to v2.
PAYLOAD_VERSION     :: 2
PAYLOAD_HEADER_SIZE :: 48 // keeps the record table 16-byte aligned
PAYLOAD_REC_SIZE    :: 16

// the v2 meta-bit masks: bit 16 marks an unknown token, bit 17 an
// id-less known one — each implies its tail entries (file header above)
PAYLOAD_META_UNKNOWN_BIT :: u32(1) << 16
PAYLOAD_META_IDLESS_BIT  :: u32(1) << 17

// u32 record offsets cap one document at 4 GiB
PAYLOAD_MAX_TEXT :: int(0xFFFF_FFFF)

// the distribution-compression wrapper around a GLB1 blob
PAYLOAD_Z_MAGIC       :: "GLBZ"
PAYLOAD_Z_HEADER_SIZE :: 8 // magic + u32 raw length, then raw DEFLATE

/*
Payload_Header is the decoded view of the first 48 bytes. `reserved`
stays zero in v1; readers must not enforce it (forward compatibility).
*/
Payload_Header :: struct #packed {
	magic:        [4]u8,
	version:      u32,
	text_hash:    u64, // Payload_Key.text_hash
	dict_version: u64, // Payload_Key.dict_version
	options:      u32, // Payload_Key.options
	token_count:  u32,
	tail_len:     u32, // bytes of unknown-pos tail after the records
	text_len:     u32, // the source text length the offsets index
	reserved:     [8]u8,
}

/*
Payload_Rec is one stored token. meta: bits 0..15 the cost (the i16 bit
pattern), bit 16 is_unknown, bit 17 id-less known (v2), bits 18..31
zero. entry_ref is the dictionary row on the analyzer that produced the
token; unknown tokens store a negative entry_ref, and a known token
either names its row or is id-less — entry_ref -1 with bit 17 set, the
representation for synthesized tokens (compound merges) that no
dictionary row backs: their pos and reading ride the tail and their
lemma is the surface. Encode refuses an unknown that claims a row and
a known token whose entry_ref is below -1 (a payload must be
resolvable, and unknown and id-less are the only row-less shapes).
*/
Payload_Rec :: struct #packed {
	entry_ref: i32,
	start:     u32,
	end:       u32,
	meta:      u32,
}

/*
Payload_Resolver maps an entry_ref back to the strings the producing
tokenizer put on the token — pos, lemma, reading — with every
analyzer-side rule applied (for moli: the "*"→surface lemma fallback,
so the resolver receives the decoded surface). ok=false rejects the id:
an id outside the resolver's dictionary, which for a correctly keyed
payload cannot happen — seeing it means the blob was paired with the
wrong dictionary state (the Payload_Key.dict_version check is how the
host refuses before decoding).
*/
Payload_Resolver :: proc(ctx: rawptr, id: i32, surface: string) ->
		(pos, lemma, reading: string, ok: bool)

// little-endian field access — the format is LE everywhere
pl_u32 :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}
pl_u64 :: proc(b: []u8, off: int) -> u64 {
	return u64(pl_u32(b, off)) | u64(pl_u32(b, off + 4)) << 32
}
pl_put_u32 :: proc(b: []u8, off: int, v: u32) {
	b[off]     = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}
pl_put_u64 :: proc(b: []u8, off: int, v: u64) {
	pl_put_u32(b, off, u32(v))
	pl_put_u32(b, off + 4, u32(v >> 32))
}

/*
One u16 length-prefixed string from the tail, advancing *off; ok=false
means the tail ran out — Malformed at the caller, never a short string.
*/
pl_tail_str :: proc(blob: []u8, off: ^int, tail_end: int) -> (s: string, ok: bool) {
	if off^ + 2 > tail_end { return "", false }
	n := int(blob[off^]) | int(blob[off^ + 1]) << 8 // u16 LE length prefix
	off^ += 2
	if off^ + n > tail_end { return "", false }
	s = string(blob[off^:off^ + n])
	off^ += n
	return s, true
}

/*
payload_header reads and validates the fixed header: magic, version,
and the total-size identity 48 + token_count*16 + tail_len == len(blob).
Everything else (counts, lengths) is taken as written.
*/
payload_header :: proc(blob: []u8) -> (Payload_Header, Store_Err) {
	if len(blob) < PAYLOAD_HEADER_SIZE { return {}, .Malformed }
	if string(blob[0:4]) != PAYLOAD_MAGIC { return {}, .Malformed }
	ver := pl_u32(blob, 4)
	if ver != 1 && ver != PAYLOAD_VERSION { return {}, .Malformed } // readers take v1 and v2
	h := Payload_Header{
		magic        = [4]u8{blob[0], blob[1], blob[2], blob[3]},
		version      = ver,
		text_hash    = pl_u64(blob, 8),
		dict_version = pl_u64(blob, 16),
		options      = pl_u32(blob, 24),
		token_count  = pl_u32(blob, 28),
		tail_len     = pl_u32(blob, 32),
		text_len     = pl_u32(blob, 36),
	}
	want := u64(PAYLOAD_HEADER_SIZE) + u64(h.token_count) * PAYLOAD_REC_SIZE + u64(h.tail_len)
	if u64(len(blob)) != want { return {}, .Malformed }
	return h, .None
}

/*
payload_key extracts the content address from a blob's header — the
host compares it against the live dictionary_hash (and its own text
hash) BEFORE decoding; a mismatch means ids would resolve against a
renumbered dictionary and the refusal happens here, not as garbage
tokens after it.
*/
payload_key :: proc(blob: []u8) -> (Payload_Key, Store_Err) {
	h, err := payload_header(blob)
	if err != .None { return {}, err }
	return Payload_Key{text_hash = h.text_hash, dict_version = h.dict_version, options = h.options}, .None
}

/*
payload_encode serializes one document's token stream. Contract
(adapter's, enforced here): every token's [start,end) lies inside
`text` and is non-empty; kind and entry_id must agree — .Dictionary
carries its dictionary row, .Idless exactly -1, .Unknown a negative.
Strings are not stored — unknown pos strings, and
id-less-known pos and reading strings, go into the tail u16
length-prefixed in token order; everything else re-resolves at read
time. The result is a self-contained GLB1 blob in `a`.
*/
payload_encode :: proc(key: Payload_Key, text: string, tokens: []Token,
                       a: mem.Allocator) -> ([]u8, Store_Err) {
	if len(text) > PAYLOAD_MAX_TEXT { return {}, .Bad_Range }

	tail: [dynamic]u8 = make([dynamic]u8, 0, 64, a)
	defer delete(tail)
	for t in tokens {
		if t.start < 0 || t.end <= t.start || t.end > len(text) { return {}, .Bad_Range }
		switch t.kind {
		case .Dictionary:
			if t.entry_id < 0 { return {}, .Malformed } // a row token cannot claim no row
		case .Idless:
			if t.entry_id != -1 { return {}, .Malformed } // -1 is the only id-less value
		case .Unknown:
			if t.entry_id >= 0 { return {}, .Malformed } // an unknown cannot claim a row
		}
		if t.kind != .Dictionary {
			n := len(t.pos)
			if n > 0xFFFF { return {}, .Malformed } // u16 length prefix
			append(&tail, u8(n & 0xFF), u8(n >> 8))
			for b in transmute([]u8)t.pos {
				append(&tail, b)
			}
			if t.kind == .Idless { // the reading rides the tail too
				n = len(t.reading)
				if n > 0xFFFF { return {}, .Malformed }
				append(&tail, u8(n & 0xFF), u8(n >> 8))
				for b in transmute([]u8)t.reading {
					append(&tail, b)
				}
			}
		}
	}
	if u64(len(tail)) > 0xFFFF_FFFF { return {}, .Malformed }

	blob := make([]u8, PAYLOAD_HEADER_SIZE + len(tokens) * PAYLOAD_REC_SIZE + len(tail), a)
	copy(blob[0:4], PAYLOAD_MAGIC)
	pl_put_u32(blob, 4, PAYLOAD_VERSION)
	pl_put_u64(blob, 8, key.text_hash)
	pl_put_u64(blob, 16, key.dict_version)
	pl_put_u32(blob, 24, key.options)
	pl_put_u32(blob, 28, u32(len(tokens)))
	pl_put_u32(blob, 32, u32(len(tail)))
	pl_put_u32(blob, 36, u32(len(text)))
	// reserved stays zero (make zero-fills)

	off := PAYLOAD_HEADER_SIZE
	for t in tokens {
		meta := u32(cast(u16)t.cost)
		if t.kind == .Unknown { meta |= PAYLOAD_META_UNKNOWN_BIT }
		if t.kind == .Idless { meta |= PAYLOAD_META_IDLESS_BIT }
		pl_put_u32(blob, off, u32(t.entry_id))
		pl_put_u32(blob, off + 4, u32(t.start))
		pl_put_u32(blob, off + 8, u32(t.end))
		pl_put_u32(blob, off + 12, meta)
		off += PAYLOAD_REC_SIZE
	}
	copy(blob[off:], tail[:])
	return blob, .None
}

/*
payload_decode materializes the token stream onto `a`, surfaces
re-sliced from `text` (whose length the header pins — a different text
is a caller bug reported as Bad_Range, never silent garbage). Known
tokens resolve pos/lemma/reading through `resolver`; an id it rejects
is Not_Found — with the payload keyed by dict_version that means the
caller paired the blob with a dictionary state the key never described.
Unknown tokens rebuild by the analyzer's unknown rule: pos from the
tail, lemma = surface, reading = "*". Id-less known tokens (bit 17)
rebuild by the compound rule: pos and reading from the tail,
lemma = surface, entry_id -1.

The returned tokens borrow like the adapter's: surfaces point into
`text`, resolved strings into the resolver's dictionary storage — the
same double lifetime duty, ended by the store's add_document clones.
*/
payload_decode :: proc(blob: []u8, text: string, resolver: Payload_Resolver,
                       ctx: rawptr, a: mem.Allocator) -> ([]Token, Store_Err) {
	h, err := payload_header(blob)
	if err != .None { return {}, err }
	if int(h.text_len) != len(text) { return {}, .Bad_Range }

	toks := make([]Token, h.token_count, a)
	tail := PAYLOAD_HEADER_SIZE + int(h.token_count) * PAYLOAD_REC_SIZE
	tail_off := tail
	tail_end := tail + int(h.tail_len)

	for i in 0..<int(h.token_count) {
		off := PAYLOAD_HEADER_SIZE + i * PAYLOAD_REC_SIZE
		entry_id := cast(i32)pl_u32(blob, off)
		start := int(pl_u32(blob, off + 4))
		end := int(pl_u32(blob, off + 8))
		meta := pl_u32(blob, off + 12)
		if end > len(text) || start >= end { return {}, .Bad_Range }
		surface := text[start:end]

		if meta & PAYLOAD_META_UNKNOWN_BIT != 0 {
			if entry_id >= 0 { return {}, .Malformed }
			pos, ok := pl_tail_str(blob, &tail_off, tail_end)
			if !ok { return {}, .Malformed }
			toks[i] = {
				surface    = surface,
				lemma      = surface,
				pos        = pos,
				reading    = "*",
				start      = start,
				end        = end,
				kind       = .Unknown,
				cost       = cast(i16)u16(meta & 0xFFFF),
				entry_id   = entry_id,
			}
		} else if meta & PAYLOAD_META_IDLESS_BIT != 0 {
			// id-less known: the compound rule — pos and reading from the
			// tail, lemma = surface, no dictionary row to resolve through
			if entry_id >= 0 { return {}, .Malformed }
			pos, pok := pl_tail_str(blob, &tail_off, tail_end)
			reading, rok := pl_tail_str(blob, &tail_off, tail_end)
			if !pok || !rok { return {}, .Malformed }
			toks[i] = {
				surface    = surface,
				lemma      = surface,
				pos        = pos,
				reading    = reading,
				start      = start,
				end        = end,
				kind       = .Idless,
				cost       = cast(i16)u16(meta & 0xFFFF),
				entry_id   = entry_id,
			}
		} else {
			pos, lemma, reading, ok := resolver(ctx, entry_id, surface)
			if !ok { return {}, .Not_Found }
			toks[i] = {
				surface    = surface,
				lemma      = lemma,
				pos        = pos,
				reading    = reading,
				start      = start,
				end        = end,
				kind       = .Dictionary,
				cost       = cast(i16)u16(meta & 0xFFFF),
				entry_id   = entry_id,
			}
		}
	}
	if tail_off != tail_end { return {}, .Malformed } // every tail byte belongs to a token
	return toks, .None
}

/*
payload_compress wraps a GLB1 blob for distribution: GLBZ magic, the
raw length as u32, then a raw DEFLATE stream (deflate.odin). Reading
paths never go through here — the mmap tier stays uncompressed; this
is for shipping and archiving. Scratch and the output allocate in `a`:
the scratch is ~0.5 MiB of LZ77 state plus ~4 bytes per input byte
(the recorded decisions), so pass a temp or roomy allocator — decode
has no such appetite.

`max_chain` is the DEFLATE effort dial (deflate_compress's doc): lower
is faster with a worse ratio. The GLBZ bytes differ per level and per
writer policy (match interiors are not inserted into the hash chains)
but every stream decodes to the same blob — compressed bytes are
never content-addressed (Payload_Key is hash-based) — so hosts pick
their point freely; the default is DEFLATE_DEFAULT_CHAIN: −45% wall vs
chain 32 at −0.23% ratio, with chain 32 itself dominated (chain 16 is
both faster and smaller).
*/
payload_compress :: proc(blob: []u8, a: mem.Allocator,
                         max_chain := DEFLATE_DEFAULT_CHAIN) -> ([]u8, Store_Err) {
	if u64(len(blob)) > 0xFFFF_FFFF { return {}, .Bad_Range }
	// header first, then the raw stream appends straight into the same
	// buffer (reserved for the typical ratio — about half the input); the
	// exact-size result copies out once at the end
	out_dyn: [dynamic]u8 = make([dynamic]u8, 0, PAYLOAD_Z_HEADER_SIZE + len(blob) / 2 + 1024, a)
	defer delete(out_dyn)
	for b in PAYLOAD_Z_MAGIC { append(&out_dyn, u8(b)) }
	raw := u32(len(blob))
	for i in 0..<4 { append(&out_dyn, u8(raw >> u32(8 * i))) } // little-endian, pl_put_u32's order
	if !deflate_compress(blob, &out_dyn, a, max_chain) { return {}, .Io }
	out := make([]u8, len(out_dyn), a)
	copy(out, out_dyn[:])
	return out, .None
}

/*
payload_decompress unwraps a GLBZ frame, inflating with core's zlib in
raw mode. The raw length in the header is both the exact allocation and
the integrity check: a stream that decodes to any other length is
Malformed, not truncated output. The inflate scratch rides
context.temp_allocator — core's inflater preallocates at least its
COMPRESS_OUTPUT_ALLOCATE_MIN (1 MiB) whatever the real size, and that
must never exhaust the caller's arena; only the exact-length result is
copied onto `a`.
*/
payload_decompress :: proc(data: []u8, a: mem.Allocator) -> ([]u8, Store_Err) {
	if len(data) < PAYLOAD_Z_HEADER_SIZE { return {}, .Malformed }
	if string(data[0:4]) != PAYLOAD_Z_MAGIC { return {}, .Malformed }
	raw_len := pl_u32(data, 4)

	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, int(raw_len), context.temp_allocator)
	defer bytes.buffer_destroy(&buf)
	if ierr := zlib.inflate_from_byte_array_raw(data[PAYLOAD_Z_HEADER_SIZE:],
		&buf, true, int(raw_len)); ierr != nil {
		return {}, .Malformed
	}
	if bytes.buffer_length(&buf) != int(raw_len) { return {}, .Malformed }

	out := make([]u8, raw_len, a)
	copy(out, bytes.buffer_to_bytes(&buf))
	return out, .None
}
