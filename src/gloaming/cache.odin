/*
A byte-bounded cache over decoded token payloads — the L3 tier
(design.md, "Storage — three tiers"). A slot owns its payload copy
and its decoded tokens on the given allocator. Slots are immutable
once published: a hit is a pure map probe and the store copies the
struct array onto the caller's arena — a read never mutates the
cache, which is what makes concurrent reads safe (design.md, "API
discipline"). Fill and eviction happen only in the store's
quiescent-point warm call.

The budget rule: one lump covering the documents the host re-reads,
never a per-document slice of it. A budget below the hot set
thrashes, and a thrashing fill path is slower than no cache — off is
a legitimate configuration. The cache serves point reads: a
whole-corpus pass reads each document once and gains nothing from it.
*/
package gloaming

import "core:mem"

Bounded_Cache_Slot :: struct {
	doc:    Doc_Id,
	blob:   []u8, // the payload copy the tail strings view — slot-owned
	tokens: []Token, // decoded against blob; slot-owned struct array
	bytes:  int, // len(blob) + token storage — the budget charge
	prev:   ^Bounded_Cache_Slot, // toward the newest insertion
	next:   ^Bounded_Cache_Slot, // toward the oldest insertion (eviction order)
}

Bounded_Cache :: struct {
	allocator: mem.Allocator,
	budget:    int,
	bytes:     int,
	head:      ^Bounded_Cache_Slot, // newest insertion
	tail:      ^Bounded_Cache_Slot, // oldest insertion — evicted first
	index:     map[Doc_Id]^Bounded_Cache_Slot,
}

bounded_cache_init :: proc(c: ^Bounded_Cache, a: mem.Allocator, budget: int) {
	c^ = {
		allocator = a,
		budget    = budget,
		index     = make(map[Doc_Id]^Bounded_Cache_Slot, a),
	}
}

// frees every slot and the table — the store's destroy path
bounded_cache_destroy :: proc(c: ^Bounded_Cache) {
	s := c.head
	for s != nil {
		nxt := s.next
		bounded_cache_slot_free(c, s)
		s = nxt
	}
	delete(c.index)
}

bounded_cache_slot_free :: proc(c: ^Bounded_Cache, s: ^Bounded_Cache_Slot) {
	delete(s.blob, c.allocator)
	delete(s.tokens, c.allocator)
	mem.free(s, c.allocator)
}

// one document's tokens on a hit — a pure probe: the list is
// insertion order and never rewired, so a hit mutates nothing and
// concurrent probes over a quiescently-filled cache are safe; nil on
// a miss
bounded_cache_get :: proc(c: ^Bounded_Cache, doc: Doc_Id) -> []Token {
	s, ok := c.index[doc]
	if !ok { return nil }
	return s.tokens
}

// whether the document holds a live slot — the warm path's skip test
bounded_cache_has :: proc(c: ^Bounded_Cache, doc: Doc_Id) -> bool {
	_, ok := c.index[doc]
	return ok
}

/*
bounded_cache_put takes ownership of `blob` and `tokens` (both
allocated on the cache's allocator, decode-complete) and publishes
them as the document's slot — the quiescent warm path is the only
caller. A document larger than the whole budget is freed without
insertion: it can never be cached, and evicting the resident entries
for it would gain nothing. A re-put for a live document drops the old
slot first. Eviction drains oldest-first — insertion order, the
deterministic order — until the budget holds.
*/
bounded_cache_put :: proc(c: ^Bounded_Cache, doc: Doc_Id, blob: []u8, tokens: []Token) {
	bytes := len(blob) + len(tokens) * size_of(Token)
	if bytes > c.budget {
		delete(blob, c.allocator)
		delete(tokens, c.allocator)
		return
	}
	if old, ok := c.index[doc]; ok {
		bounded_cache_unlink(c, old)
		c.bytes -= old.bytes
		bounded_cache_slot_free(c, old)
	}
	for c.bytes + bytes > c.budget && c.tail != nil {
		dead := c.tail
		bounded_cache_unlink(c, dead)
		c.bytes -= dead.bytes
		bounded_cache_slot_free(c, dead)
	}
	s := new(Bounded_Cache_Slot, c.allocator)
	s^ = {doc = doc, blob = blob, tokens = tokens, bytes = bytes, next = c.head}
	if c.head != nil { c.head.prev = s }
	c.head = s
	if c.tail == nil { c.tail = s }
	c.index[doc] = s
	c.bytes += bytes
}

// unlink the slot from the recency list and the index; the caller
// adjusts `bytes` and frees the slot
bounded_cache_unlink :: proc(c: ^Bounded_Cache, s: ^Bounded_Cache_Slot) {
	if s.prev != nil { s.prev.next = s.next } else { c.head = s.next }
	if s.next != nil { s.next.prev = s.prev } else { c.tail = s.prev }
	delete_key(&c.index, s.doc)
}

// remove the document's slot and its budget charge (the store calls
// this when a document is removed)
bounded_cache_drop :: proc(c: ^Bounded_Cache, doc: Doc_Id) {
	s, ok := c.index[doc]
	if !ok { return }
	bounded_cache_unlink(c, s)
	c.bytes -= s.bytes
	bounded_cache_slot_free(c, s)
}
