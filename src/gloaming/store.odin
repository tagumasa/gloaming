package gloaming

import "core:mem"

/*
The store ports, split by mutability:

  - `Store` below — the document port the host holds a corpus with:
    two backends — store_memory (the differential reference) and
    store_disk (GLR1 registry + payloads.glb) — behind
    the same procs.
  - The curation records (entities, relations, mentions, doc attrs)
    live on the disk backend as GLR1 record kinds 16..19, one
    batch-committed row per mutation (store_disk's graph_* writers);
    the in-memory state is the Doc_Graph in graph.odin, rebuilt at open
    by replaying the same records.

The core defines the port types; backends are host-selected. All
caches over either tier are bounded.
*/

Payload_Key :: struct {
	text_hash:    u64, // hash of the (normalized) source text
	dict_version: u64, // dictionary content hash — user dictionaries count
	options:      u32, // tokenize-option bitmask
}

Store_Err :: enum {
	None,
	Duplicate,
	Not_Found,
	Bad_Range,
	Io,
	// Malformed is the payload-format member: a byte stream (or the
	// token stream feeding it) that violates the GLB1 contract — bad
	// magic/version, size identity broken, tail slack, a token whose
	// kind and entry_id disagree (payload.odin)
	Malformed,
	// Stale is the refusal-protocol member: a stored
	// payload whose Payload_Key.dict_version disagrees with the
	// dictionary state the backend resolves against — decoding would
	// resolve entry ids against a renumbered dictionary, silently
	// wrong; the disk backend answers this instead, before decoding
	Stale,
	// Interrupted is the stop-check member: an optional check
	// (corpus passes, store-open replay) fired mid-pass — true = stop
	Interrupted,
}

/*
The document store port. Odin's struct-of-procs
interface; nil procs are caller error — documented precondition, no
runtime check, matching the library's discipline of trusting explicit
state.

Reads (`tokens`/`segments`) may return borrowed views — valid until
the next mutating call on the same backend; the `a` parameter is
where a materializing backend (the disk tier) decodes onto. Hosts assemble
Token_Stream from these reads; the port itself never mentions the
read APIs. Unbounded by design: the reference backend must hold a
whole corpus (160k morphemes ≈ 17 MB of Tokens) — bounding it
would defeat the differential test; disk tiers and caches are the
bounded-cache business.
*/
Store :: struct {
	ctx:             rawptr,
	docs:            proc(ctx: rawptr) -> []Doc_Id,
	has:             proc(ctx: rawptr, doc: Doc_Id) -> bool,
	tokens:          proc(ctx: rawptr, doc: Doc_Id,
	                       a: mem.Allocator) -> ([]Token, Store_Err),
	segments:        proc(ctx: rawptr, doc: Doc_Id,
	                      a: mem.Allocator) -> ([]Segment, Store_Err),
	add_document:    proc(ctx: rawptr, doc: Doc_Id, text: string,
	                      tokens: []Token,
	                      segments: []Segment) -> Store_Err,
	remove_document: proc(ctx: rawptr, doc: Doc_Id) -> Store_Err,
}

Memory_Doc :: struct {
	tokens:    []Token,
	segments:  []Segment,
}

Memory_Store :: struct {
	arena: mem.Allocator,          // owns everything below
	docs:  map[Doc_Id]Memory_Doc,  // u32 keys — no key cloning needed
	ids:   [dynamic]Doc_Id,        // ascending — the maintained document list
}

/*
The port wired to a fresh heap-allocated Memory_Store — the
reference backend, so the constructor is also the only glue. Freeing is the
host's allocator's business (an arena host frees in one call).
*/
store_memory :: proc(a: mem.Allocator) -> (Store, Store_Err) {
	ms := new(Memory_Store, a)
	ms^ = {
		arena = a,
		docs  = make(map[Doc_Id]Memory_Doc, a),
		ids   = make([dynamic]Doc_Id, 0, 0, a),
	}
	return Store{
		ctx             = ms,
		docs            = ms_docs,
		has             = ms_has,
		tokens          = ms_tokens,
		segments        = ms_segments,
		add_document    = ms_add_document,
		remove_document = ms_remove_document,
	}, .None
}

/*
The maintained ascending list both backends keep: binary search plus
one shift per mutation, so `docs()` is a plain copy and never a sort.
Unbounded by the stores' own rule.
*/
ids_insert :: proc(ids: ^[dynamic]Doc_Id, doc: Doc_Id) {
	lo, hi := 0, len(ids^)
	for lo < hi {
		mid := (lo + hi) / 2
		if u32(ids^[mid]) < u32(doc) { lo = mid + 1 } else { hi = mid }
	}
	append(ids, doc)
	for i := len(ids^) - 1; i > lo; i -= 1 {
		ids^[i] = ids^[i - 1]
	}
	ids^[lo] = doc
}

ids_remove :: proc(ids: ^[dynamic]Doc_Id, doc: Doc_Id) {
	lo, hi := 0, len(ids^)
	for lo < hi {
		mid := (lo + hi) / 2
		if u32(ids^[mid]) < u32(doc) { lo = mid + 1 } else { hi = mid }
	}
	if lo >= len(ids^) || ids^[lo] != doc { return }
	for i := lo; i < len(ids^) - 1; i += 1 {
		ids^[i] = ids^[i + 1]
	}
	resize(ids, len(ids^) - 1)
}

ms_docs :: proc(ctx: rawptr) -> []Doc_Id {
	ms := cast(^Memory_Store)ctx
	// a copy of the maintained ascending list — map iteration is
	// unordered, the list makes the order stable without a sort
	out := make([]Doc_Id, len(ms.ids), ms.arena)
	copy(out, ms.ids[:])
	return out
}

ms_has :: proc(ctx: rawptr, doc: Doc_Id) -> bool {
	ms := cast(^Memory_Store)ctx
	_, ok := ms.docs[doc]
	return ok
}

// borrowed views — the memory backend ignores `a` (the port contract
// lets it; a materializing backend would not)
ms_tokens :: proc(ctx: rawptr, doc: Doc_Id, a: mem.Allocator) -> ([]Token, Store_Err) {
	_ = a
	ms := cast(^Memory_Store)ctx
	d, ok := ms.docs[doc]
	if !ok { return {}, .Not_Found }
	return d.tokens, .None
}

ms_segments :: proc(ctx: rawptr, doc: Doc_Id, a: mem.Allocator) -> ([]Segment, Store_Err) {
	_ = a
	ms := cast(^Memory_Store)ctx
	d, ok := ms.docs[doc]
	if !ok { return {}, .Not_Found }
	return d.segments, .None
}

/*
add_document takes the source text explicitly: it copies the text
once into its own storage and re-points every `surface` view into the
copy; `lemma`/`pos`/`reading` point into the dictionary by adapter
contract, so those
are cloned per string — plain arena clones, measured faster than an
intern table (a bump allocation beats a hash probe per field). After the call the host may free the text
and the token slice — the same ownership contract query_parse gives.
Re-adding a live Doc_Id is Duplicate; removal drops the entry.
Token byte ranges must lie inside `text` (adapter contract — a
violation here would mis-slice, so it is Bad_Range rather than a
crash).
*/
ms_add_document :: proc(ctx: rawptr, doc: Doc_Id, text: string,
                        tokens: []Token,
                        segments: []Segment) -> Store_Err {
	ms := cast(^Memory_Store)ctx
	if _, live := ms.docs[doc]; live { return .Duplicate }

	// ranges first: the store's arena never frees per-item, so a
	// refusal after the copies start would strand them — from here to
	// the commit nothing can fail
	for t in tokens {
		if t.start < 0 || t.end > len(text) || t.start > t.end { return .Bad_Range }
	}

	text_copy := make([]u8, len(text), ms.arena)
	copy(text_copy, text)

	tk := make([]Token, len(tokens), ms.arena)
	for t, i in tokens {
		tk[i] = {
			surface    = transmute(string)text_copy[t.start:t.end],
			lemma      = clone_str(t.lemma, ms.arena),
			pos        = clone_str(t.pos, ms.arena),
			reading    = clone_str(t.reading, ms.arena),
			start      = t.start,
			end        = t.end,
			kind       = t.kind,
			cost       = t.cost,
			entry_id   = t.entry_id,
		}
	}
	sg := make([]Segment, len(segments), ms.arena)
	copy(sg, segments)

	ms.docs[doc] = Memory_Doc{tokens = tk, segments = sg}
	ids_insert(&ms.ids, doc)
	return .None
}

ms_remove_document :: proc(ctx: rawptr, doc: Doc_Id) -> Store_Err {
	ms := cast(^Memory_Store)ctx
	if _, live := ms.docs[doc]; !live { return .Not_Found }
	delete_key(&ms.docs, doc)
	ids_remove(&ms.ids, doc)
	return .None
}
