/*
The library's fork-join fan-outs (design.md, "Rules" and "API
discipline"): the corpus passes over stores, and the dense-matrix
passes' row splits. A fan-out is a fork-join inside the call — the
caller is worker 0, the rest are spawned and joined before the call
returns, and no thread outlives the call. Workers claim whole units
(documents, matrix rows) off a shared atomic counter, so the split
follows the machine's schedule, never the list's order.
The corpus lanes each own two growing virtual arenas charged to the
call: the per-document decode scratch (reset after every document)
and the partial store (partial tables with cloned keys — what must
outlive the reset). The matrix lanes need none of that: their rows
are disjoint cells of a caller-arena buffer, so no worker allocates
on the caller's allocator at all, and none depends on the spawner's
ambient context — a worker entry pins both context allocators to its
own arenas before any work that allocates — so a single-threaded
test allocator below the call is never touched concurrently.

Output is byte-identical at every width: per-document results land
in slots indexed by list position, partial tables merge as integer
sums in worker order, matrix cells and matvec rows accumulate in the
same index order whatever lane computes them, and every output row
order comes from the deterministic sorts, never from the merge. A
worker refusal (a store error, an interrupt) halts claiming; the
post-join scan walks the slots in list order, so the reported error
is the one the serial run would have hit first. A thread that fails
to spawn leaves its share to the remaining workers through the same
counter — the pass degrades toward serial, it never fails on spawn.
The caller lane is built and checked before any spawn: the serial
fallback returns with no thread started, so the cleanup defers never
free a lane a worker is still running on.
workers <= 1 runs the serial body unchanged (the default; zero
overhead, no thread). The stop-check itself is called from worker
threads — hosts keep it a trivial flag read.
*/

package gloaming

import "base:intrinsics"
import "core:mem"
import mv "core:mem/virtual"
import "core:thread"

Fanout_Jobs :: struct {
	units: int, // claimable units (documents, matrix rows)
	next:  int, // the next unit index to claim — atomically incremented
	stop:  int, // 1 once a worker refused — claimed by nobody after
}

// the next unit index, or -1 when the work is exhausted or halted
fanout_claim :: proc(j: ^Fanout_Jobs) -> int {
	if intrinsics.atomic_load_explicit(&j.stop, .Seq_Cst) != 0 { return -1 }
	n := intrinsics.atomic_add_explicit(&j.next, 1, .Seq_Cst)
	if n >= j.units { return -1 }
	return n
}

// one worker's refusal ends every worker's claiming
fanout_halt :: proc(j: ^Fanout_Jobs) {
	intrinsics.atomic_store_explicit(&j.stop, 1, .Seq_Cst)
}

// the call's arenas: growing virtual memory charged to `a`, no size
// commitment up front — the fan-out's scratch never asks the caller's
// allocator for worker-side growth
fanout_arena_new :: proc(a: mem.Allocator) -> ^mv.Arena {
	ar := new(mv.Arena, a)
	if ar == nil { return nil } // the allocation itself refused
	if mv.arena_init_growing(ar) != .None {
		free(ar, a)
		return nil
	}
	return ar
}

fanout_arena_drop :: proc(ar: ^mv.Arena, a: mem.Allocator) {
	mv.arena_destroy(ar)
	free(ar, a)
}

/*
fanout_spawn starts one worker entry. A nil return is a spawn
failure: the caller proceeds without the thread (the claim counter
gives its share to whoever is left) and destroys only what it
holds.
*/
fanout_spawn :: proc(entry: proc(data: rawptr), data: rawptr) -> ^thread.Thread {
	return thread.create_and_start_with_data(data, entry)
}

fanout_join :: proc(t: ^thread.Thread) {
	thread.join(t)
	thread.destroy(t)
}

// the width rule: at least one lane (the caller's), never more lanes
// than claimable units
fanout_units :: proc(workers: int, units: int) -> int {
	if workers < 1 || units < 1 { return 1 }
	return min(workers, units)
}

fanout_width :: proc(workers: int, docs: []Doc_Id) -> int {
	return fanout_units(workers, len(docs))
}

// ------------------------------------------------------------
// corpus_count_maps: partial (counts, ndocs) per lane, integer-sum
// merge in lane order
// ------------------------------------------------------------

Count_Fanout :: struct {
	store:   Store,
	docs:    []Doc_Id,
	filter:  Freq_Filter,
	jobs:    ^Fanout_Jobs,
	check:   proc(user: rawptr) -> bool,
	user:    rawptr,
	scratch: ^mv.Arena, // the per-document decode — free_all after every doc
	part:    ^mv.Arena, // the partial tables and their cloned keys
	counts:  map[string]int,
	ndocs:   map[string]int,
	errs:    []Store_Err, // one slot per list position — disjoint writes
}

count_fanout_entry :: proc(data: rawptr) {
	w := cast(^Count_Fanout)data
	sa := mv.arena_allocator(w.scratch)
	context.allocator = sa
	context.temp_allocator = sa
	pa := mv.arena_allocator(w.part)
	for {
		i := fanout_claim(w.jobs)
		if i < 0 { return }
		d := w.docs[i]
		if w.check != nil && w.check(w.user) {
			w.errs[i] = .Interrupted
			fanout_halt(w.jobs)
			return
		}
		toks, terr := w.store.tokens(w.store.ctx, d, sa)
		if terr != .None {
			w.errs[i] = terr
			fanout_halt(w.jobs)
			return
		}
		per := make(map[string]int, sa)
		for tok in toks {
			key, keep := filter_key(tok, w.filter)
			if !keep { continue }
			per[key] += 1
		}
		// the partial's keys must outlive this document's scratch —
		// clone on first insert; every later doc only adds
		for k, n in per {
			if _, ok := w.counts[k]; !ok {
				kc := clone_str(k, pa)
				w.counts[kc] = n
				w.ndocs[kc] = 1
			} else {
				w.counts[k] += n
				w.ndocs[k] += 1
			}
		}
		mv.arena_free_all(w.scratch)
	}
}

/*
count_maps_fanout is corpus_count_maps' wide path. `fanned` false
means the caller lane's arenas could not be created — the caller
falls back to the serial body; every other lane's failure only
shrinks the width. On any store error or interrupt the partials die
with the arenas and the first error in list order is reported — the
serial run's rule.
*/
count_maps_fanout :: proc(store: Store, docs: []Doc_Id, filter: Freq_Filter,
                          a: mem.Allocator,
                          check: proc(user: rawptr) -> bool,
                          user: rawptr,
                          workers: int) -> (counts: map[string]int,
                          ndocs: map[string]int, err: Store_Err, fanned: bool) {
	w := fanout_width(workers, docs)
	errs := make([]Store_Err, len(docs), a)
	defer if len(errs) > 0 { mem.free(raw_data(errs), a) }
	jobs := Fanout_Jobs{units = len(docs)}

	fw := make([]Count_Fanout, w, a)
	defer if len(fw) > 0 { mem.free(raw_data(fw), a) }
	threads := make([dynamic]^thread.Thread, 0, w - 1, a)
	defer delete(threads)
	// declared last, runs first: the lanes' arenas go before the
	// arrays that describe them, after the joins above
	defer {
		for i in 0..<w {
			if fw[i].scratch != nil { fanout_arena_drop(fw[i].scratch, a) }
			if fw[i].part != nil { fanout_arena_drop(fw[i].part, a) }
		}
	}
	// lane 0 is built and checked before any spawn: the fallback's
	// defers free these arenas, `fw`, and `errs`, so no worker may be
	// running when fanned comes back false
	fw[0] = Count_Fanout{
		store = store, docs = docs, filter = filter, jobs = &jobs,
		check = check, user = user, errs = errs,
		scratch = fanout_arena_new(a), part = fanout_arena_new(a),
	}
	if fw[0].scratch == nil || fw[0].part == nil {
		return {}, {}, .None, false // no caller lane — the serial body
	}
	pa := mv.arena_allocator(fw[0].part)
	fw[0].counts = make(map[string]int, pa)
	fw[0].ndocs = make(map[string]int, pa)
	for i in 1..<w {
		fw[i] = Count_Fanout{
			store = store, docs = docs, filter = filter, jobs = &jobs,
			check = check, user = user, errs = errs,
			scratch = fanout_arena_new(a), part = fanout_arena_new(a),
		}
		if fw[i].scratch == nil || fw[i].part == nil { continue } // a dead lane
		pa = mv.arena_allocator(fw[i].part)
		fw[i].counts = make(map[string]int, pa)
		fw[i].ndocs = make(map[string]int, pa)
		if t := fanout_spawn(count_fanout_entry, &fw[i]); t != nil {
			append(&threads, t)
		}
	}
	// the caller is worker 0; the context pin is the worker's, so the
	// ambient returns with the call (the boundary guard)
	caller_context := context
	count_fanout_entry(&fw[0])
	context = caller_context
	for t in threads { fanout_join(t) }

	for i in 0..<len(docs) {
		if errs[i] != .None { return {}, {}, errs[i], true } // partials die with the arenas
	}

	counts = make(map[string]int, a)
	ndocs = make(map[string]int, a)
	for i in 0..<w {
		if fw[i].counts == nil { continue }
		for k, n in fw[i].counts {
			if _, has := counts[k]; !has {
				kc := clone_str(k, a)
				counts[kc] = n
				ndocs[kc] = fw[i].ndocs[k]
			} else {
				counts[k] += n
				ndocs[k] += fw[i].ndocs[k]
			}
		}
	}
	return counts, ndocs, .None, true
}

// ------------------------------------------------------------
// doc_profiles: one profile per list slot, materialized onto `a`
// after the join
// ------------------------------------------------------------

Profile_Fanout :: struct {
	store:   Store,
	docs:    []Doc_Id,
	filter:  Freq_Filter,
	jobs:    ^Fanout_Jobs,
	check:   proc(user: rawptr) -> bool,
	user:    rawptr,
	scratch: ^mv.Arena,
	part:    ^mv.Arena, // the profiles' key and count arrays
	slots:   []Doc_Profile, // headers per list position — disjoint writes
	errs:    []Store_Err,
}

profile_fanout_entry :: proc(data: rawptr) {
	w := cast(^Profile_Fanout)data
	sa := mv.arena_allocator(w.scratch)
	context.allocator = sa
	context.temp_allocator = sa
	pa := mv.arena_allocator(w.part)
	for {
		i := fanout_claim(w.jobs)
		if i < 0 { return }
		d := w.docs[i]
		if w.check != nil && w.check(w.user) {
			w.errs[i] = .Interrupted
			fanout_halt(w.jobs)
			return
		}
		toks, terr := w.store.tokens(w.store.ctx, d, sa)
		if terr != .None {
			w.errs[i] = terr
			fanout_halt(w.jobs)
			return
		}
		per := make(map[string]int, sa)
		for tok in toks {
			key, keep := filter_key(tok, w.filter)
			if !keep { continue }
			per[key] += 1
		}
		rows: [dynamic]Lemma_Count = make([dynamic]Lemma_Count, 0, len(per), sa)
		for k, n in per { append(&rows, Lemma_Count{k, n}) }
		sort_with_buffer(rows[:], strkey_less, sa)
		keys := make([]string, len(rows), pa) // must outlive the reset
		counts := make([]int, len(rows), pa)
		for r, j in rows {
			keys[j] = clone_str(r.lemma, pa)
			counts[j] = r.count
		}
		w.slots[i] = Doc_Profile{doc = d, keys = keys, counts = counts}
		mv.arena_free_all(w.scratch)
	}
}

// profiles_fanout is doc_profiles' wide path; `fanned` carries the
// same arena-fallback meaning as count_maps_fanout's. The slots hold
// part-arena arrays; success materializes every profile onto `a` (the
// serial contract's ownership) before the arenas go.
profiles_fanout :: proc(store: Store, docs: []Doc_Id, filter: Freq_Filter,
                        a: mem.Allocator,
                        check: proc(user: rawptr) -> bool,
                        user: rawptr,
                        workers: int) -> (out: []Doc_Profile,
                        err: Store_Err, fanned: bool) {
	w := fanout_width(workers, docs)
	errs := make([]Store_Err, len(docs), a)
	defer if len(errs) > 0 { mem.free(raw_data(errs), a) }
	slots := make([]Doc_Profile, len(docs), a)
	defer if len(slots) > 0 { mem.free(raw_data(slots), a) }
	jobs := Fanout_Jobs{units = len(docs)}

	fw := make([]Profile_Fanout, w, a)
	defer if len(fw) > 0 { mem.free(raw_data(fw), a) }
	threads := make([dynamic]^thread.Thread, 0, w - 1, a)
	defer delete(threads)
	defer {
		for i in 0..<w {
			if fw[i].scratch != nil { fanout_arena_drop(fw[i].scratch, a) }
			if fw[i].part != nil { fanout_arena_drop(fw[i].part, a) }
		}
	}
	// lane 0 is built and checked before any spawn — same rule as
	// count_maps_fanout: no worker may be running when fanned comes
	// back false
	fw[0] = Profile_Fanout{
		store = store, docs = docs, filter = filter, jobs = &jobs,
		check = check, user = user, slots = slots, errs = errs,
		scratch = fanout_arena_new(a), part = fanout_arena_new(a),
	}
	if fw[0].scratch == nil || fw[0].part == nil {
		return {}, .None, false // no caller lane — the serial body
	}
	for i in 1..<w {
		fw[i] = Profile_Fanout{
			store = store, docs = docs, filter = filter, jobs = &jobs,
			check = check, user = user, slots = slots, errs = errs,
			scratch = fanout_arena_new(a), part = fanout_arena_new(a),
		}
		if fw[i].scratch == nil || fw[i].part == nil { continue }
		if t := fanout_spawn(profile_fanout_entry, &fw[i]); t != nil {
			append(&threads, t)
		}
	}
	// the caller is worker 0; the context pin is the worker's, so the
	// ambient returns with the call (the boundary guard)
	caller_context := context
	profile_fanout_entry(&fw[0])
	context = caller_context
	for t in threads { fanout_join(t) }

	for i in 0..<len(docs) {
		if errs[i] != .None { return {}, errs[i], true } // slots die with the arenas
	}

	// the slots hold part-arena arrays — materialize onto `a` (the
	// serial contract's ownership) before the arenas go
	out = make([]Doc_Profile, len(docs), a)
	for p, i in slots {
		keys := make([]string, len(p.keys), a)
		for k, j in p.keys { keys[j] = clone_str(k, a) }
		counts := make([]int, len(p.counts), a)
		copy(counts, p.counts)
		out[i] = Doc_Profile{doc = p.doc, keys = keys, counts = counts}
	}
	return out, .None, true
}

// ------------------------------------------------------------
// corpus_cooc: per-lane merged pair maps, integer-sum merge in lane
// order, one sort at the end
// ------------------------------------------------------------

Cooc_Fanout :: struct {
	store:   Store,
	docs:    []Doc_Id,
	opts:    Cooc_Options,
	jobs:    ^Fanout_Jobs,
	check:   proc(user: rawptr) -> bool,
	user:    rawptr,
	scratch: ^mv.Arena,
	part:    ^mv.Arena,
	merged:  map[Co_Pair_Key]int, // cloned keys on the part arena
	capped:  bool, // this lane saw a per-document cap bite
	errs:    []Store_Err,
}

cooc_fanout_entry :: proc(data: rawptr) {
	w := cast(^Cooc_Fanout)data
	sa := mv.arena_allocator(w.scratch)
	context.allocator = sa
	context.temp_allocator = sa
	pa := mv.arena_allocator(w.part)
	for {
		i := fanout_claim(w.jobs)
		if i < 0 { return }
		d := w.docs[i]
		if w.check != nil && w.check(w.user) {
			w.errs[i] = .Interrupted
			fanout_halt(w.jobs)
			return
		}
		toks, terr := w.store.tokens(w.store.ctx, d, sa)
		if terr != .None {
			w.errs[i] = terr
			fanout_halt(w.jobs)
			return
		}
		segs, serr := w.store.segments(w.store.ctx, d, sa)
		if serr != .None {
			w.errs[i] = serr
			fanout_halt(w.jobs)
			return
		}
		stream := Token_Stream{doc = d, tokens = toks, segments = segs}
		doc_pairs, doc_trunc, ferr := co_occurrence(stream, nil, w.opts, sa)
		if ferr != .None {
			if ferr == .Interrupted {
				w.errs[i] = .Interrupted
			} else {
				w.errs[i] = .Malformed
			}
			fanout_halt(w.jobs)
			return
		}
		if doc_trunc { w.capped = true }
		// the partial's keys must outlive this document's scratch —
		// clone on first insert; every later doc only adds
		for p in doc_pairs {
			k := Co_Pair_Key{a = p.a, b = p.b}
			if _, ok := w.merged[k]; !ok {
				w.merged[Co_Pair_Key{a = clone_str(p.a, pa), b = clone_str(p.b, pa)}] = p.n
			} else {
				w.merged[k] += p.n
			}
		}
		mv.arena_free_all(w.scratch)
	}
}

// cooc_fanout is corpus_cooc's wide path; `fanned` carries the same
// arena-fallback meaning as count_maps_fanout's.
cooc_fanout :: proc(store: Store, docs: []Doc_Id, opts: Cooc_Options,
                    a: mem.Allocator,
                    check: proc(user: rawptr) -> bool,
                    user: rawptr,
                    workers: int) -> (pairs: []Co_Pair, capped: bool,
                    err: Store_Err, fanned: bool) {
	w := fanout_width(workers, docs)
	errs := make([]Store_Err, len(docs), a)
	defer if len(errs) > 0 { mem.free(raw_data(errs), a) }
	jobs := Fanout_Jobs{units = len(docs)}

	fw := make([]Cooc_Fanout, w, a)
	defer if len(fw) > 0 { mem.free(raw_data(fw), a) }
	threads := make([dynamic]^thread.Thread, 0, w - 1, a)
	defer delete(threads)
	defer {
		for i in 0..<w {
			if fw[i].scratch != nil { fanout_arena_drop(fw[i].scratch, a) }
			if fw[i].part != nil { fanout_arena_drop(fw[i].part, a) }
		}
	}
	// lane 0 is built and checked before any spawn — same rule as
	// count_maps_fanout: no worker may be running when fanned comes
	// back false
	fw[0] = Cooc_Fanout{
		store = store, docs = docs, opts = opts, jobs = &jobs,
		check = check, user = user, errs = errs,
		scratch = fanout_arena_new(a), part = fanout_arena_new(a),
	}
	if fw[0].scratch == nil || fw[0].part == nil {
		return {}, false, .None, false // no caller lane — the serial body
	}
	pa := mv.arena_allocator(fw[0].part)
	fw[0].merged = make(map[Co_Pair_Key]int, pa)
	for i in 1..<w {
		fw[i] = Cooc_Fanout{
			store = store, docs = docs, opts = opts, jobs = &jobs,
			check = check, user = user, errs = errs,
			scratch = fanout_arena_new(a), part = fanout_arena_new(a),
		}
		if fw[i].scratch == nil || fw[i].part == nil { continue }
		pa = mv.arena_allocator(fw[i].part)
		fw[i].merged = make(map[Co_Pair_Key]int, pa)
		if t := fanout_spawn(cooc_fanout_entry, &fw[i]); t != nil {
			append(&threads, t)
		}
	}
	// the caller is worker 0; the context pin is the worker's, so the
	// ambient returns with the call (the boundary guard)
	caller_context := context
	cooc_fanout_entry(&fw[0])
	context = caller_context
	for t in threads { fanout_join(t) }

	for i in 0..<len(docs) {
		if errs[i] != .None { return {}, false, errs[i], true }
	}

	merged := make(map[Co_Pair_Key]int, a)
	for i in 0..<w {
		if fw[i].merged == nil { continue }
		for k, n in fw[i].merged {
			if _, has := merged[k]; !has {
				kc := Co_Pair_Key{a = clone_str(k.a, a), b = clone_str(k.b, a)}
				merged[kc] = n
			} else {
				merged[k] += n
			}
		}
		if fw[i].capped { capped = true }
	}
	out: [dynamic]Co_Pair = make([dynamic]Co_Pair, 0, len(merged), a)
	for k, n in merged {
		append(&out, Co_Pair{a = k.a, b = k.b, n = n})
	}
	delete(merged)
	pairs = out[:]
	sort_with_buffer(pairs, co_pair_less, a)
	return pairs, capped, .None, true
}

// ------------------------------------------------------------
// doc_matrix: one output row per profile — disjoint writes, no merge
// ------------------------------------------------------------

Matrix_Fanout :: struct {
	profiles: []Doc_Profile,
	keys_n:   int,
	key_ix:   ^map[string]int,
	idf:      []f64,
	mode:     Tf_Mode,
	jobs:     ^Fanout_Jobs,
	check:    proc(user: rawptr) -> bool,
	user:     rawptr,
	w:        []f64, // row-major output — each claimed row is one lane's own
	errs:     []Freq_Err,
}

matrix_fanout_entry :: proc(data: rawptr) {
	w := cast(^Matrix_Fanout)data
	for {
		d := fanout_claim(w.jobs)
		if d < 0 { return }
		if w.check != nil && w.check(w.user) {
			w.errs[d] = .Interrupted
			fanout_halt(w.jobs)
			return
		}
		base := d * w.keys_n
		p := w.profiles[d]
		for key, x in p.keys {
			i, ok := w.key_ix[key]
			if !ok { continue }
			if w.mode == .Tf {
				w.w[base + i] = f64(p.counts[x])
			} else {
				w.w[base + i] = f64(p.counts[x]) * w.idf[i]
			}
		}
	}
}

// matrix_fanout is doc_matrix's wide path over the profile rows. The
// validation and the idf column build stay serial (cheap, ordered);
// the fan-out claims whole rows, whose cells no two lanes share.
matrix_fanout :: proc(profiles: []Doc_Profile, keys: []string,
                      key_ix: ^map[string]int, idf: []f64, mode: Tf_Mode,
                      a: mem.Allocator,
                      check: proc(user: rawptr) -> bool,
                      user: rawptr,
                      workers: int) -> (w: []f64, err: Freq_Err, fanned: bool) {
	units := len(profiles)
	width := 1
	if workers > 1 && units > 0 { width = min(workers, units) }
	w = make([]f64, units * len(keys), a)
	if width <= 1 { return w, .None, false }
	errs := make([]Freq_Err, units, a)
	jobs := Fanout_Jobs{units = units}

	fw := make([]Matrix_Fanout, width, a)
	threads := make([dynamic]^thread.Thread, 0, width - 1, a)
	for i in 0..<width {
		fw[i] = Matrix_Fanout{
			profiles = profiles, keys_n = len(keys), key_ix = key_ix,
			idf = idf, mode = mode, jobs = &jobs,
			check = check, user = user, w = w, errs = errs,
		}
		if i > 0 {
			if t := fanout_spawn(matrix_fanout_entry, &fw[i]); t != nil {
				append(&threads, t)
			}
		}
	}
	// the caller is worker 0; the context pin is the worker's, so the
	// ambient returns with the call (the boundary guard)
	caller_context := context
	matrix_fanout_entry(&fw[0])
	context = caller_context
	for t in threads { fanout_join(t) }
	delete(threads)
	if len(fw) > 0 { mem.free(raw_data(fw), a) }
	for i in 0..<units {
		if errs[i] != .None {
			mem.free(raw_data(errs), a)
			mem.free(raw_data(w), a)
			return {}, errs[i], true
		}
	}
	mem.free(raw_data(errs), a)
	return w, .None, true
}

// ------------------------------------------------------------
// weight_distance: pair rows claimed off the counter, both triangle
// cells of a pair written once — no worker scratch, no merge
// ------------------------------------------------------------

Dist_Fanout :: struct {
	w:     []f64,
	k:     int,
	m:     Weight_Distance,
	norms: []f64, // read-only, complete before any lane starts
	d:     []f64, // row-major output — each pair's cells are one lane's own
	jobs:  ^Fanout_Jobs,
}

dist_fanout_entry :: proc(data: rawptr) {
	fw := cast(^Dist_Fanout)data
	for {
		i := fanout_claim(fw.jobs)
		if i < 0 { return }
		fw.d[i * fw.k + i] = 0
		for j in i + 1..<fw.k {
			dij := weight_pair(fw.w, fw.k, fw.m, fw.norms, i, j)
			fw.d[i * fw.k + j] = dij
			fw.d[j * fw.k + i] = dij
		}
	}
}

// dist_fanout is weight_distance's wide path. The input was validated
// and the norms built before it runs; no lane can refuse, so there is
// no error reporting — only cells.
dist_fanout :: proc(w: []f64, k: int, m: Weight_Distance, norms: []f64,
                    d: []f64, a: mem.Allocator, workers: int) {
	width := fanout_units(workers, k)
	jobs := Fanout_Jobs{units = k}
	fw := make([]Dist_Fanout, width, a)
	threads := make([dynamic]^thread.Thread, 0, width - 1, a)
	for i in 0..<width {
		fw[i] = Dist_Fanout{
			w = w, k = k, m = m, norms = norms, d = d, jobs = &jobs,
		}
		if i > 0 {
			if t := fanout_spawn(dist_fanout_entry, &fw[i]); t != nil {
				append(&threads, t)
			}
		}
	}
	// the caller is worker 0; the boundary guard returns the ambient
	// context with the call even though these lanes never allocate
	caller_context := context
	dist_fanout_entry(&fw[0])
	context = caller_context
	for t in threads { fanout_join(t) }
	delete(threads)
	if len(fw) > 0 { mem.free(raw_data(fw), a) }
}

// ------------------------------------------------------------
// power_coords' matvec: rows claimed off the counter into the shared
// buf — one fork-join per axis iteration, no allocation in any lane
// ------------------------------------------------------------

Matvec_Fanout :: struct {
	sm:   []f64,
	m:    int,
	x:    []f64,   // read-only while the lanes run
	buf:  []f64,   // row-major image — each row is one lane's own
	jobs: ^Fanout_Jobs,
}

matvec_fanout_entry :: proc(data: rawptr) {
	fw := cast(^Matvec_Fanout)data
	for {
		i := fanout_claim(fw.jobs)
		if i < 0 { return }
		sv := 0.0
		for j in 0..<fw.m { sv += fw.sm[i * fw.m + j] * fw.x[j] }
		fw.buf[i] = sv
	}
}

// matvec_fanout is power_axis' iteration body at any width: lanes
// <= 1 is the serial loop with the same j accumulation order, so the
// iterates are bit-identical whenever the wide path engages.
matvec_fanout :: proc(sm: []f64, m: int, x: []f64, buf: []f64,
                      a: mem.Allocator, workers: int) {
	width := fanout_units(workers, m)
	if width <= 1 {
		for i in 0..<m {
			sv := 0.0
			for j in 0..<m { sv += sm[i * m + j] * x[j] }
			buf[i] = sv
		}
		return
	}
	jobs := Fanout_Jobs{units = m}
	fw := make([]Matvec_Fanout, width, a)
	threads := make([dynamic]^thread.Thread, 0, width - 1, a)
	for i in 0..<width {
		fw[i] = Matvec_Fanout{sm = sm, m = m, x = x, buf = buf, jobs = &jobs}
		if i > 0 {
			if t := fanout_spawn(matvec_fanout_entry, &fw[i]); t != nil {
				append(&threads, t)
			}
		}
	}
	caller_context := context
	matvec_fanout_entry(&fw[0])
	context = caller_context
	for t in threads { fanout_join(t) }
	delete(threads)
	if len(fw) > 0 { mem.free(raw_data(fw), a) }
}
