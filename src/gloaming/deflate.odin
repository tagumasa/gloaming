/*
Raw DEFLATE (RFC 1951) compressor: LZ77 over a 32 KiB window with
hash-chain match finding, one dynamic-Huffman block per call. The
output is a raw stream — no zlib/gzip wrapper — and the decode side is
core:compress/zlib's inflater in raw mode; this file is encode only.
The GLBZ payload wrapper (payload.odin) uses it for distribution-only
compression; the mmap read path stays uncompressed.
*/
package gloaming

import "core:encoding/endian"
import "core:mem"

DEFLATE_MAX_CHAIN    :: 32
// The shipped effort point (payload_compress's default): chain 8,
// −45% wall against chain 32 at −0.23% ratio — chain 32 itself is
// dominated (16 was both faster and smaller); every value emits a
// valid stream.
DEFLATE_DEFAULT_CHAIN :: 8
DEFLATE_MIN_MATCH    :: 3
DEFLATE_MAX_MATCH    :: 258
DEFLATE_WINDOW_SIZE  :: 32768
DEFLATE_HASH_BITS    :: 15
DEFLATE_HASH_SIZE    :: 1 << DEFLATE_HASH_BITS
DEFLATE_HASH_MASK    :: DEFLATE_HASH_SIZE - 1
DEFLATE_MAX_LIT      :: 286
DEFLATE_MAX_DIST_SYM :: 30
DEFLATE_MAX_CL       :: 19

BLOCK_STORED  :: 0
BLOCK_FIXED   :: 1
BLOCK_DYNAMIC :: 2

LENGTH_EXTRA: [29]u8 = {
	0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0,
}
LENGTH_BASE: [29]u16 = {
	3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258,
}
DIST_EXTRA: [30]u8 = {
	0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,
}
DIST_BASE: [30]u16 = {
	1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577,
}

// Code LUTs for the decision pass: the brackets of the length/distance
// code scans precomputed, built by the same brackets so a lookup returns
// exactly what the linear scan returned. len_lut is u16 — length codes
// run to 285 and do not fit u8 — and covers every length 3..258 (0,1,2
// stay 0 — the decision path only looks up ml >= 3); dist_lut covers
// every distance 1..32768 (d >= 1 whenever a match was taken). Brackets
// are built in DESCENDING code order because they overlap at the top of
// the length table: code 284's 5 extra bits nominally cover 227..258,
// and the first-bracket-wins scan maps 258 to 284 (+31 extra), never to
// 285. The descending build lets the lower code's write land last,
// reproducing that exactly.
build_len_lut :: proc(lut: ^[259]u16) {
	for i in 0..<259 { lut[i] = 0 }
	for i := 28; i >= 0; i -= 1 {
		e := u32(LENGTH_EXTRA[i])
		base := int(LENGTH_BASE[i])
		for v in base ..< base + (1 << e) {
			if v < 259 { lut[v] = u16(257 + i) }
		}
	}
}

build_dist_lut :: proc(lut: []u8) {
	for i := 29; i >= 0; i -= 1 {
		e := u32(DIST_EXTRA[i])
		base := int(DIST_BASE[i])
		hi := min(base + (1 << e), len(lut))
		for v in base..<hi { lut[v] = u8(i) }
	}
}

// --- Bitstream writer ---

/*
The staged bit writer: bits land in the bit cache, whole bytes land in
an inline stage, and the stage flushes into the caller's buffer as one
append per DEFLATE_STAGE bytes — the per-byte path is a plain store,
not an append call (append grows through the dynamic's own stored
allocator, so a staged flush is allocator-correct for any buffer).
*/
DEFLATE_STAGE :: 4096

Deflate_Writer :: struct {
	out:           ^[dynamic]u8, // the caller's buffer — staged flushes append here
	stage:         [DEFLATE_STAGE]u8,
	n:             int, // stage fill
	cache:         u32,
	cache_bits:    int,
	bytes_written: int,
}

deflate_writer_init :: proc(w: ^Deflate_Writer, out: ^[dynamic]u8) {
	w.out = out
	w.n = 0
	w.cache = 0
	w.cache_bits = 0
	w.bytes_written = 0
}

deflate_stage_flush :: proc(w: ^Deflate_Writer) {
	if w.n > 0 {
		append(w.out, ..w.stage[:w.n])
		w.n = 0
	}
}

deflate_put_byte :: proc(w: ^Deflate_Writer, b: u8) {
	if w.n == len(w.stage) { deflate_stage_flush(w) }
	w.stage[w.n] = b
	w.n += 1
	w.bytes_written += 1
}

deflate_write_bits :: proc(w: ^Deflate_Writer, value: u32, count: int) {
	w.cache |= value << u32(w.cache_bits)
	w.cache_bits += count
	for w.cache_bits >= 8 {
		deflate_put_byte(w, u8(w.cache & 0xFF))
		w.cache >>= 8
		w.cache_bits -= 8
	}
}

deflate_flush :: proc(w: ^Deflate_Writer) {
	for w.cache_bits > 0 {
		deflate_put_byte(w, u8(w.cache & 0xFF))
		w.cache >>= 8
		w.cache_bits -= 8
	}
	w.cache = 0
	w.cache_bits = 0
	deflate_stage_flush(w)
}

// --- Huffman ---

Huffman_Table :: struct {
	codes:   [288]u16,
	bits:    [288]u8,
	max_len: u8,
}

huffman_build :: proc(table: ^Huffman_Table, lengths: []u8) {
	counts: [16]int
	for l in lengths {
		if int(l) < len(counts) { counts[l] += 1 }
	}
	counts[0] = 0

	next_code: [16]u16
	code: u16 = 0
	for b in 1..<16 {
		code = (code + u16(counts[b - 1])) << 1
		next_code[b] = code
	}

	table.max_len = 0
	for i in 0..<len(lengths) {
		l := lengths[i]
		table.bits[i] = l
		if l > 0 {
			c := next_code[l]
			next_code[l] += 1
			// codes are stored bit-REVERSED: Huffman symbols go out
			// LSB-first into the DEFLATE bitstream (MSB-first within the
			// code), so the emission paths write them with the plain bit
			// writer and the per-symbol reversal disappears
			rev: u16 = 0
			v := c
			for _ in 0..<l {
				rev = u16(rev << 1) | u16(v & 1)
				v >>= 1
			}
			table.codes[i] = rev
			if l > table.max_len { table.max_len = l }
		} else {
			table.codes[i] = 0
		}
	}
}

Huff_Node :: struct {
	freq:  int,
	sym:   int,
	left:  int,
	right: int,
}

// huffman_compute_lengths builds code lengths from symbol frequencies:
// a Huffman tree by pairwise minimum extraction, depths clipped to
// max_bits, and a Kraft-inequality repair that pushes one symbol at a
// time from the shallowest over-populated depth down one level until
// the code is decodable again (the clipping above can break Kraft).
huffman_compute_lengths :: proc(freqs: []int, max_symbol: int, max_bits: int) -> [288]u8 {
	lengths: [288]u8

	num_active := 0
	for i in 0..<max_symbol {
		if freqs[i] > 0 { num_active += 1 }
	}
	if num_active == 0 { lengths[0] = 1; return lengths }
	if num_active == 1 {
		for i in 0..<max_symbol {
			if freqs[i] > 0 { lengths[i] = 1; break }
		}
		return lengths
	}

	// nodes[] is append-only; indices are stable
	nodes: [576]Huff_Node
	num_nodes := 0

	for i in 0..<max_symbol {
		if freqs[i] > 0 {
			nodes[num_nodes] = {freqs[i], i, -1, -1}
			num_nodes += 1
		}
	}

	// active[] maps active-list position → stable node index
	active: [576]int
	num_act := num_nodes
	for i in 0..<num_act { active[i] = i }

	for num_act > 1 {
		min1 := 0
		for i in 1..<num_act {
			if nodes[active[i]].freq < nodes[active[min1]].freq { min1 = i }
		}
		idx1 := active[min1]
		active[min1] = active[num_act - 1]
		num_act -= 1

		min2 := 0
		for i in 1..<num_act {
			if nodes[active[i]].freq < nodes[active[min2]].freq { min2 = i }
		}
		idx2 := active[min2]

		nodes[num_nodes] = {nodes[idx1].freq + nodes[idx2].freq, -1, idx1, idx2}
		active[min2] = num_nodes
		num_nodes += 1
	}

	compute_depths :: proc(nodes: []Huff_Node, idx: int, depth: int,
	                       lengths: ^[288]u8, max_bits: int) {
		if idx < 0 { return }
		n := nodes[idx]
		if n.sym >= 0 {
			d := depth
			if d < 1 { d = 1 }
			if d > max_bits { d = max_bits }
			lengths[n.sym] = u8(d)
			return
		}
		compute_depths(nodes, n.left, depth + 1, lengths, max_bits)
		compute_depths(nodes, n.right, depth + 1, lengths, max_bits)
	}

	root_idx := active[0]
	compute_depths(nodes[:num_nodes], root_idx, 0, &lengths, max_bits)

	// Post-process: clipping depths to max_bits can over-subscribe the
	// code, which the inflater rejects when its canonical allocation
	// overflows a depth. The check below is that same integer test (no
	// tolerance — at 15 bits three stray codes hide inside a 1.0001
	// float guard). Repair by moving one symbol at a time from the
	// deepest occupied depth below max_bits one level deeper — the
	// smallest decrement available at each step. The walk is monotone
	// (lengths only grow) and always terminates in a decodable code:
	// every alphabet DEFLATE allows fits under 2^max_bits, where the
	// all-max-bits code is itself valid.
	canonical_valid :: proc(lengths: []u8, max_symbol: int) -> bool {
		sizes: [16]int
		for v in lengths { if int(v) <= 15 { sizes[v] += 1 } }
		code := 0
		for i in 1..=15 {
			code += sizes[i]
			if sizes[i] != 0 && code - 1 >= (1 << u32(i)) { return false }
			code <<= 1
		}
		return true
	}

	for !canonical_valid(lengths[:], max_symbol) {
		deepest := 0
		for cand in 1..<max_bits {
			for i in 0..<max_symbol {
				if int(lengths[i]) == cand { deepest = cand; break }
			}
		}
		if deepest == 0 { break } // everything already at max_bits
		for i in 0..<max_symbol {
			if int(lengths[i]) == deepest {
				lengths[i] = u8(deepest + 1)
				break
			}
		}
	}

	return lengths
}

// --- LZ77 (the chain arrays are ~512 KiB — heap, never stack) ---

// Candidates live by absolute position: head/prev hold window-index
// positions whose distance to lz.pos is the match distance, and the
// bytes themselves are validated straight against src — a separate
// circular window copy of src would be write-only, so there is none.
LZ77_State :: struct {
	pos:  int,
	head: [DEFLATE_HASH_SIZE]int,
	prev: [DEFLATE_WINDOW_SIZE]int,
}

lz77_init :: proc(lz: ^LZ77_State, a := context.allocator) {
	lz.pos = 0
	for i in 0..<DEFLATE_HASH_SIZE { lz.head[i] = -1 }
	for i in 0..<DEFLATE_WINDOW_SIZE { lz.prev[i] = -1 }
}

lz77_hash3 :: proc(a, b, c: u8) -> int {
	return (int(a) | (int(b) << 8) | (int(c) << 16)) & DEFLATE_HASH_MASK
}

lz77_insert :: proc(lz: ^LZ77_State, src: []u8, src_pos: int) {
	if src_pos + 2 >= len(src) { return }
	h := lz77_hash3(src[src_pos], src[src_pos + 1], src[src_pos + 2])
	p := lz.pos & (DEFLATE_WINDOW_SIZE - 1)
	lz.prev[p] = lz.head[h]
	lz.head[h] = p
	lz.pos += 1
}

lz77_find :: proc(lz: ^LZ77_State, src: []u8, src_pos: int,
                  max_chain: int) -> (dist: int, length: int) {
	if src_pos + DEFLATE_MIN_MATCH > len(src) { return 0, 0 }
	h := lz77_hash3(src[src_pos], src[src_pos + 1], src[src_pos + 2])
	best_len := 0
	best_dist := 0
	rem := min(DEFLATE_MAX_MATCH, len(src) - src_pos)
	p := lz.pos & (DEFLATE_WINDOW_SIZE - 1)
	cand := lz.head[h]
	chain := 0

	for cand >= 0 && chain < max_chain {
		d := p - cand
		if d <= 0 { d += DEFLATE_WINDOW_SIZE }
		if d > DEFLATE_WINDOW_SIZE { break }

		// Validate against the SOURCE, not the circular window: for a match
		// longer than its distance the window slots ahead of lz.pos are not
		// yet written (zero-filled), so window comparison silently extends
		// matches through bytes the inflater would fill by repetition —
		// corrupting output. src[lz.pos - d + ml] is exactly the byte the
		// inflater will copy, so it is the only sound reference.
		c_abs := lz.pos - d
		if c_abs >= 0 {
			// quick reject: only a STRICTLY longer match can replace
			// best_len, so the candidate's byte at best_len must already
			// agree — one compare retires most of the chain once any
			// decent match exists
			if best_len >= rem { break }
			if src[c_abs + best_len] != src[src_pos + best_len] {
				cand = lz.prev[cand & (DEFLATE_WINDOW_SIZE - 1)]
				chain += 1
				continue
			}
			// 8-byte chunks first: a chunk advances ml only when all 8
			// bytes agree, so the byte-precise walk below still lands on
			// the same first mismatch — ml is identical to the plain
			// byte loop. unchecked_get_u64le needs 8 readable bytes:
			// c_abs < src_pos and ml + 8 <= rem keep both slices inside
			// src (src_pos + rem <= len(src)); byte order is irrelevant
			// — the loads are only ever compared for equality.
			ml := 0
			for ml + 8 <= rem {
				if endian.unchecked_get_u64le(src[c_abs + ml:]) !=
				endian.unchecked_get_u64le(src[src_pos + ml:]) {
					break
				}
				ml += 8
			}
			for ml < rem {
				if src[c_abs + ml] != src[src_pos + ml] { break }
				ml += 1
			}
			if ml >= DEFLATE_MIN_MATCH && ml > best_len {
				best_len = ml
				best_dist = d
				if ml >= DEFLATE_MAX_MATCH { break }
			}
		}
		cand = lz.prev[cand & (DEFLATE_WINDOW_SIZE - 1)]
		chain += 1
	}
	return best_dist, best_len
}

// --- RLE code-length encoding ---

CL_Run :: struct {
	sym:        u8,
	extra:      u32,
	extra_bits: u8,
}

encode_code_lengths :: proc(lengths: []u8, a := context.allocator) -> ([]CL_Run, int) {
	out := make([dynamic]CL_Run, 0, len(lengths) * 2, a)
	i := 0
	for i < len(lengths) {
		v := lengths[i]
		if v != 0 {
			append(&out, CL_Run{v, 0, 0})
			i += 1
		} else {
			zc := 0
			j := i
			for j < len(lengths) && lengths[j] == 0 && zc < 138 {
				zc += 1; j += 1
			}
			if zc < 3 {
				for _ in 0..<zc {
					append(&out, CL_Run{0, 0, 0})
				}
				i += zc
			} else if zc <= 10 {
				append(&out, CL_Run{17, u32(zc - 3), 3})
				i += zc
			} else {
				append(&out, CL_Run{18, u32(zc - 11), 7})
				i += zc
			}
		}
	}
	return out[:], len(out)
}

// --- Main compress entry point ---
// Compresses src into dst as a raw DEFLATE stream (no zlib/gzip wrapper).

/*
One u32 per LZ77 decision: bit 0 set = match, bits 1..9 the match
length or the literal byte, bits 10..25 the match distance. Lengths
cap at 258 and distances at the 32-KiB window, so both fit; the emit
pass re-derives codes and extra bits from the LUTs, making the packed
word the whole record — 4 B per input byte of scratch.
*/
dec_match_flag :: u32(1)
dec_len_shift :: 1
dec_dist_shift :: 10

/*
deflate_compress emits one dynamic-Huffman block covering all of src,
appending the raw stream to `out` (which must already have its allocator
— reserve roughly half the input plus a kilobyte to skip growth).
Scratch lives on `a` (the LZ77 state alone is ~512 KiB, decisions
another ~4 B per input byte) — pass an arena. Always compresses;
decompression is core:compress/zlib's (raw mode).

`max_chain` is the effort dial: how many hash-chain candidates each
position may consider. Lower walks less chain and finds fewer long
matches — faster, worse ratio; every value emits a valid raw stream
that decodes identically. It is clamped below at 1. The shipped default
lives at payload_compress (DEFLATE_DEFAULT_CHAIN); DEFLATE_MAX_CHAIN
remains the maximum-effort point.
*/
deflate_compress :: proc(src: []u8, out: ^[dynamic]u8, a := context.allocator,
                         max_chain := DEFLATE_MAX_CHAIN) -> bool {
	w: Deflate_Writer
	deflate_writer_init(&w, out)
	mc := max(1, max_chain)

	if len(src) == 0 {
		// Empty block: BFINAL + a minimal dynamic header, end-of-block.
		// No LZ77 state — there is nothing to match against, and the
		// state alone is ~512 KiB
		lit_freq:  [286]int
		dist_freq: [30]int
		lit_freq[256] = 1

		lit_lengths  := huffman_compute_lengths(lit_freq[:], DEFLATE_MAX_LIT, 15)
		dist_lengths := huffman_compute_lengths(dist_freq[:], DEFLATE_MAX_DIST_SYM, 15)

		_emit_dynamic_header_and_block(&w, lit_lengths[:], dist_lengths[:], nil, nil, nil, a)
		deflate_flush(&w)
		return true
	}

	lz := new(LZ77_State, a)
	defer free(lz, a)
	lz77_init(lz, a)

	// Single pass: scan, find matches, record decisions
	decisions := make([dynamic]u32, 0, len(src), a)
	defer delete(decisions)

	len_lut: [259]u16
	build_len_lut(&len_lut)
	dist_lut := make([]u8, DEFLATE_WINDOW_SIZE + 1, a)
	defer delete(dist_lut, a)
	build_dist_lut(dist_lut)

	lit_freq:  [286]int
	dist_freq: [30]int

	pos := 0
	for pos < len(src) {
		d, ml := lz77_find(lz, src, pos, mc)
		lz77_insert(lz, src, pos)

		if ml >= DEFLATE_MIN_MATCH {
			lc := int(len_lut[ml])
			dc := int(dist_lut[d])
			lit_freq[lc] += 1
			dist_freq[dc] += 1
			append(&decisions, dec_match_flag | (u32(ml) << dec_len_shift) | (u32(d) << dec_dist_shift))
			// Match interiors are mostly never inserted: the hash chains
			// carry match starts plus one anchor at pos+1 (the overlapping
			// match finder), and lz.pos advances through the whole interior
			// — window indices stay 1:1 with src positions, only chain
			// membership is omitted. This is a recorded output policy: the
			// emitted bytes differ from an all-insert writer (the stream
			// stays valid raw DEFLATE and round-trips byte-exact), trading
			// a measured slice of ratio for the insert work every consumed
			// position used to pay.
			lz77_insert(lz, src, pos + 1)
			lz.pos += ml - 2
			pos += ml
		} else {
			lit_freq[src[pos]] += 1
			append(&decisions, u32(src[pos]) << dec_len_shift)
			pos += 1
		}
	}
	lit_freq[256] = 1

	// Build Huffman tables from frequencies
	lit_lengths  := huffman_compute_lengths(lit_freq[:], DEFLATE_MAX_LIT, 15)
	dist_lengths := huffman_compute_lengths(dist_freq[:], DEFLATE_MAX_DIST_SYM, 15)

	_emit_dynamic_header_and_block(&w, lit_lengths[:], dist_lengths[:], decisions[:], &len_lut, dist_lut, a)
	deflate_flush(&w)
	return true
}

_emit_dynamic_header_and_block :: proc(w: ^Deflate_Writer, lit_lengths, dist_lengths: []u8,
                                       decisions: []u32, len_lut: ^[259]u16,
                                       dist_lut: []u8, a: mem.Allocator) {
	nlit := len(lit_lengths)
	for nlit > 257 && lit_lengths[nlit - 1] == 0 { nlit -= 1 }
	ndist := len(dist_lengths)
	for ndist > 1 && dist_lengths[ndist - 1] == 0 { ndist -= 1 }

	all_cl := make([]u8, nlit + ndist, a)
	defer delete(all_cl, a)
	for i in 0..<nlit { all_cl[i] = lit_lengths[i] }
	for i in 0..<ndist { all_cl[nlit + i] = dist_lengths[i] }

	cl_runs, cl_run_count := encode_code_lengths(all_cl, a)
	defer delete(cl_runs, a)

	cl_freq: [19]int
	for i in 0..<cl_run_count { cl_freq[cl_runs[i].sym] += 1 }
	cl_lengths := huffman_compute_lengths(cl_freq[:], DEFLATE_MAX_CL, 7)
	cl_tbl: Huffman_Table
	huffman_build(&cl_tbl, cl_lengths[:])

	// Block header: BFINAL, type, then the code-length alphabet
	deflate_write_bits(w, 1, 1) // BFINAL
	deflate_write_bits(w, BLOCK_DYNAMIC, 2)

	deflate_write_bits(w, u32(nlit - 257), 5)
	deflate_write_bits(w, u32(ndist - 1), 5)

	// Code length code order permutation
	cl_perm: [19]int = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
	hcrlen := 19
	for hcrlen > 4 && cl_lengths[cl_perm[hcrlen - 1]] == 0 { hcrlen -= 1 }
	deflate_write_bits(w, u32(hcrlen - 4), 4)

	for i in 0..<hcrlen {
		deflate_write_bits(w, u32(cl_lengths[cl_perm[i]]), 3)
	}

	// Emit code length symbols; each run carries its extra-bit width
	for i in 0..<cl_run_count {
		r := cl_runs[i]
		deflate_write_bits(w, u32(cl_tbl.codes[r.sym]), int(cl_tbl.bits[r.sym]))
		if r.extra_bits > 0 {
			deflate_write_bits(w, r.extra, int(r.extra_bits))
		}
	}

	// Build emission tables and emit data from recorded decisions
	lit_tbl:  Huffman_Table
	dist_tbl: Huffman_Table
	huffman_build(&lit_tbl, lit_lengths[:])
	huffman_build(&dist_tbl, dist_lengths[:])

	for d in decisions {
		if d & dec_match_flag != 0 {
			ml := int(d >> dec_len_shift) & 0x1FF
			dist := int(d >> dec_dist_shift)
			lc := int(len_lut[ml])
			dc := int(dist_lut[dist])
			deflate_write_bits(w, u32(lit_tbl.codes[lc]), int(lit_tbl.bits[lc]))
			if lc >= 265 && lc <= 284 {
				deflate_write_bits(w, u32(ml - int(LENGTH_BASE[lc - 257])),
				                   int(LENGTH_EXTRA[lc - 257]))
			}
			deflate_write_bits(w, u32(dist_tbl.codes[dc]), int(dist_tbl.bits[dc]))
			if dc >= 4 {
				deflate_write_bits(w, u32(dist - int(DIST_BASE[dc])), int(DIST_EXTRA[dc]))
			}
		} else {
			b := int(d >> dec_len_shift)
			deflate_write_bits(w, u32(lit_tbl.codes[b]), int(lit_tbl.bits[b]))
		}
	}

	// End of block
	deflate_write_bits(w, u32(lit_tbl.codes[256]), int(lit_tbl.bits[256]))
}
