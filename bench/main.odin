package main

// gloaming's quantitative bench. docs/benchmarks.md is the committed record;
// this harness produces the numbers it curates — `just bench` stamps a
// provenance block (date, odin version, both trees' HEADs) above this
// output and tees everything to tmp/bench.log.
//
// Stage tags are the attribution mechanism (docs/benchmarks.md carries the
// rule): [moli] stages move with the analyzer, [seam] with the adapter
// contract, [gloaming] with the library. Every number is a session
// measurement — best + upper median of the stated n; re-run before
// believing a regression. Counts and sizes print alongside the timings:
// a moved count means semantics changed, not performance.
//
// The corpora are local and gitignored: corpus/kotono_oni (孤島の鬼,
// 江戸川乱歩 — public domain, staged from 青空文庫 by
// scripts/stage_aozora.py, `just corpus-ja`) for the JP rows,
// corpus/hlm (紅樓夢) for the ZH arm, corpus/chapdelaine for the EN
// arm; a missing local fact is SKIP, never failure. What must hold for
// EVERY dictionary is adapter_tests' job — this measures the one real
// shape, through the library API the way a host consumes it.

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:time"
import "core:unicode/utf8"

import gl "gloaming:gloaming"
import moli "moli:moli"
import ma "gladapter:moli_adapter"

REAL_DIC  :: "vendor/moli/dict/ipadic-utf8/lex.csv"
REAL_FILES :: []string{
	"corpus/kotono_oni/1.md",
	"corpus/kotono_oni/2.md",
	"corpus/kotono_oni/3.md",
}
QDCT_PATH :: "tmp/bench-ipadic.qdct"
DISK_ROOT :: "tmp/bench-disk"

// The language arms. ZH: moli's jieba dictionary over the
// traditional-character 紅樓夢 — the full [moli]/[seam]/[gloaming] chain
// on a second writing system. EN: no analyzer exists for the language,
// so the host owns tokenization (a [host]-tagged fixture) and gloaming
// runs analyzer-agnostic from there.
ZH_DIC :: "vendor/moli/dict/mecab-jieba-0.1.1/jieba.csv"
ZH_FILE :: "corpus/hlm/1.md"
ZH_QDCT :: "tmp/bench-jieba.qdct"
ZH_PREFIX :: 700 << 10 // the JP novel rows' scale; the shared 512-MiB sink covers a call this size
EN_FILE :: "corpus/chapdelaine/1.md"

// per-rep backing for the memory-store stage: add_document clones the
// whole novel (text + every token's strings + segments), so the reps
// need real headroom. One package-scope buffer (a 96 MiB local warns),
// arena_free_all between reps — nothing escapes a rep.
store_arena_buf: [96 << 20]u8

elapsed_ms :: proc(t0: time.Tick) -> f64 {
	return f64(time.duration_nanoseconds(time.tick_since(t0))) / 1e6
}

hdr :: proc(title: string) {
	fmt.print("\n================================================================\n")
	fmt.printf("%s\n", title)
	fmt.print("----------------------------------------------------------------\n")
}

Times :: struct { best, median: f64 }

Stage_Fn :: proc(user: rawptr)

// run_stage times f n times and returns best + upper median. No warmup
// inside: stages that need one (the first tokenize after a load, the
// first pass over the dictionary's pages) warm themselves explicitly.
// The caller prints the row so stage-specific counts ride along.
run_stage :: proc(n: int, f: Stage_Fn, user: rawptr) -> Times {
	times: [dynamic]f64 = make([dynamic]f64, 0, n, context.temp_allocator)
	defer delete(times)
	for _ in 0..<n {
		t0 := time.tick_now()
		f(user)
		append(&times, elapsed_ms(t0))
	}
	for i in 1..<len(times) { // insertion sort; n is single digits
		x := times[i]
		j := i - 1
		for j >= 0 && times[j] > x { times[j + 1] = times[j]; j -= 1 }
		times[j + 1] = x
	}
	return Times{best = times[0], median = times[len(times) / 2]}
}

row :: proc(tag, name: string, n: int, t: Times, extra: string) {
	fmt.printf("%-8s %-38s n=%d  best %9.2f ms  median %9.2f ms  %s\n",
		tag, name, n, t.best, t.median, extra)
}

fault :: proc(stage: string, err: any) {
	fmt.printf("FAULT   %-38s %v\n", stage, err)
}

// --- [moli] dictionary load ---

load_csv_cb :: proc(_: rawptr) {
	an, lerr := moli.load(.Japanese, REAL_DIC, {}, context.allocator)
	if lerr != nil { fault("load csv", lerr); return }
	moli.free(&an)
}

Load_Path_Ctx :: struct { path: string }

load_qdct_cb :: proc(user: rawptr) {
	ctx := cast(^Load_Path_Ctx)user
	an, lerr := ma.load_analyzer(ctx.path, REAL_DIC, .Japanese, {}, context.allocator)
	if lerr != nil { fault("load qdct", lerr); return }
	moli.free(&an)
}

// --- [moli] tokenize ---

Tok_Ctx :: struct {
	an:    ^moli.Analyzer,
	text:  string, // one file's substring of the concatenated buffer
	arena: ^mem.Arena,
	n:     int, // morphemes of the last rep — the stability check
}

tokenize_cb :: proc(user: rawptr) {
	ctx := cast(^Tok_Ctx)user
	mem.arena_free_all(ctx.arena)
	ms, terr := moli.tokenize(ctx.an, ctx.text, mem.arena_allocator(ctx.arena))
	if terr != nil { fault("tokenize", terr); return }
	ctx.n = len(ms)
}

Novel_Tok_Ctx :: struct {
	an:    ^moli.Analyzer,
	texts: []string,
	arena: ^mem.Arena,
	n:     int,
}

tokenize_novel_cb :: proc(user: rawptr) {
	ctx := cast(^Novel_Tok_Ctx)user
	ctx.n = 0
	for t in ctx.texts {
		mem.arena_free_all(ctx.arena)
		ms, terr := moli.tokenize(ctx.an, t, mem.arena_allocator(ctx.arena))
		if terr != nil { fault("tokenize novel", terr); return }
		ctx.n += len(ms)
	}
}

// --- [seam] adapter ---

Adapt_Ctx :: struct {
	mss:   [][]moli.Morpheme, // retained per-file morphemes (heap)
	bases: []int,
	out:   ^[dynamic]gl.Token,
}

adapt_cb :: proc(user: rawptr) {
	ctx := cast(^Adapt_Ctx)user
	resize(ctx.out, 0)
	for i in 0..<len(ctx.mss) {
		ma.adapt(ctx.mss[i], ctx.bases[i], ctx.out)
	}
}

Seg_Ctx :: struct {
	texts: []string,
	bases: []int,
	out:   ^[dynamic]gl.Segment,
}

segments_cb :: proc(user: rawptr) {
	ctx := cast(^Seg_Ctx)user
	resize(ctx.out, 0)
	for i in 0..<len(ctx.texts) {
		ma.markdown_segments(ctx.texts[i], ctx.bases[i], gl.Doc_Id(0), ctx.out)
	}
}

// --- [gloaming] memory store ---

Store_Ctx :: struct {
	arena:    ^mem.Arena,
	text:     string,
	tokens:   []gl.Token,
	segments: []gl.Segment,
}

store_add_cb :: proc(user: rawptr) {
	ctx := cast(^Store_Ctx)user
	mem.arena_free_all(ctx.arena)
	a := mem.arena_allocator(ctx.arena)
	store, serr := gl.store_memory(a)
	if serr != gl.Store_Err.None { fault("store_memory", serr); return }
	if aerr := store.add_document(store.ctx, gl.Doc_Id(0), ctx.text, ctx.tokens,
			ctx.segments); aerr != gl.Store_Err.None {
		fault("add_document", aerr)
	}
}

// --- [gloaming] queries ---

Query_Ctx :: struct {
	q:      ^gl.Query,
	stream: gl.Token_Stream,
	count:  int,
}

query_cb :: proc(user: rawptr) {
	ctx := cast(^Query_Ctx)user
	res, qerr := gl.query_match(ctx.q, ctx.stream, 1 << 30, context.temp_allocator)
	if qerr != gl.Query_Err.None { fault("query_match", qerr); return }
	ctx.count = len(res.matches)
	delete(res.matches, context.temp_allocator)
}

// --- [gloaming] stats ---

Stats_Ctx :: struct {
	stream: gl.Token_Stream,
	n:      int,
}

freq_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	ftab, ferr := gl.freq_table(ctx.stream, {},
		{pos_prefixes = {"名詞,"}, use_lemma = true},
		context.temp_allocator)
	if ferr != gl.Freq_Err.None { fault("freq_table", ferr); return }
	ctx.n = len(ftab)
	delete(ftab, context.temp_allocator)
}

cooc_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	pairs, _, cerr := gl.co_occurrence(ctx.stream, {},
		{unit = .Segments, filter = {pos_prefixes = {"名詞,"}, use_lemma = true},
		 max_pairs = 20000},
		context.temp_allocator)
	if cerr != gl.Freq_Err.None { fault("co_occurrence", cerr); return }
	ctx.n = len(pairs)
	delete(pairs, context.temp_allocator)
}

presence_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	pres, perr := gl.cooc_presence(ctx.stream, {},
		{unit = .Segments, filter = {pos_prefixes = {"名詞,"}, use_lemma = true},
		 max_pairs = 20000},
		context.temp_allocator)
	if perr != gl.Freq_Err.None { fault("cooc_presence", perr); return }
	ctx.n = len(pres.keys)
	delete(pres.keys, context.temp_allocator)
}

// --- [gloaming] payload ---

Payload_Ctx :: struct {
	key:    gl.Payload_Key,
	text:   string,
	tokens: []gl.Token,
}

encode_cb :: proc(user: rawptr) {
	ctx := cast(^Payload_Ctx)user
	blob, berr := gl.payload_encode(ctx.key, ctx.text, ctx.tokens,
		context.temp_allocator)
	if berr != gl.Store_Err.None { fault("payload_encode", berr); return }
	delete(blob, context.temp_allocator)
}

Blob_Ctx :: struct {
	blob:  []u8,
	chain: int, // the DEFLATE effort dial; <= 0 rides payload_compress's default
}

compress_cb :: proc(user: rawptr) {
	ctx := cast(^Blob_Ctx)user
	if ctx.chain > 0 {
		z, zerr := gl.payload_compress(ctx.blob, context.temp_allocator, ctx.chain)
		if zerr != gl.Store_Err.None { fault("payload_compress", zerr); return }
		delete(z, context.temp_allocator)
		return
	}
	z, zerr := gl.payload_compress(ctx.blob, context.temp_allocator)
	if zerr != gl.Store_Err.None { fault("payload_compress", zerr); return }
	delete(z, context.temp_allocator)
}

decompress_cb :: proc(user: rawptr) {
	ctx := cast(^Blob_Ctx)user
	raw, rerr := gl.payload_decompress(ctx.blob, context.temp_allocator)
	if rerr != gl.Store_Err.None { fault("payload_decompress", rerr); return }
	delete(raw, context.temp_allocator)
}

Decode_Ctx :: struct {
	an:   ^moli.Analyzer,
	blob: []u8,
	text: string,
}

decode_cb :: proc(user: rawptr) {
	ctx := cast(^Decode_Ctx)user
	dec, derr := ma.payload_tokens(ctx.an, ctx.blob, ctx.text,
		context.temp_allocator)
	if derr != gl.Store_Err.None { fault("payload decode", derr); return }
	delete(dec, context.temp_allocator)
}

// --- [gloaming] disk store ---

Disk_Add_Ctx :: struct {
	an:        ^moli.Analyzer,
	dv:        u64,
	i:         int, // rep index — its own directory
	text:      string,
	tokens:    []gl.Token,
	segments:  []gl.Segment,
	reg_bytes: i64, // from the last rep — the on-disk footprint
	pay_bytes: i64,
}

disk_add_cb :: proc(user: rawptr) {
	ctx := cast(^Disk_Add_Ctx)user
	dir := fmt.aprintf("%s/rep%d", DISK_ROOT, ctx.i, context.temp_allocator)
	if !os.exists(DISK_ROOT) { _ = os.mkdir(DISK_ROOT) }
	if !os.exists(dir) { _ = os.mkdir(dir) }
	reg, _ := os.join_path({dir, "registry.glr"}, context.temp_allocator)
	pay, _ := os.join_path({dir, "payloads.glb"}, context.temp_allocator)
	_ = os.remove(reg)
	_ = os.remove(pay)
	dstore, ds, serr := gl.store_disk(dir, ma.payload_resolver, ctx.an, ctx.dv, 0,
		context.allocator)
	if serr != gl.Store_Err.None { fault("store_disk", serr); return }
	if aerr := dstore.add_document(dstore.ctx, gl.Doc_Id(0), ctx.text, ctx.tokens,
			ctx.segments); aerr != gl.Store_Err.None {
		fault("disk add_document", aerr)
	}
	ctx.reg_bytes = ds.log_end
	ctx.pay_bytes = ds.pay_end
	gl.disk_store_close(ds)
}

Load_Disk_Ctx :: struct {
	dir: string,
	an:  ^moli.Analyzer,
	dv:  u64,
}

disk_reopen_cb :: proc(user: rawptr) {
	ctx := cast(^Load_Disk_Ctx)user
	_, ds, rerr := gl.store_disk(ctx.dir, ma.payload_resolver, ctx.an, ctx.dv, 0,
		context.allocator)
	if rerr != gl.Store_Err.None { fault("store_disk reopen", rerr); return }
	gl.disk_store_close(ds)
}

Disk_Decode_Ctx :: struct {
	store: gl.Store, // one open store for the whole stage
}

disk_decode_cb :: proc(user: rawptr) {
	ctx := cast(^Disk_Decode_Ctx)user
	toks, terr := ctx.store.tokens(ctx.store.ctx, gl.Doc_Id(0),
		context.temp_allocator)
	if terr != gl.Store_Err.None { fault("disk tokens", terr); return }
	delete(toks, context.temp_allocator)
}

// --- [gloaming] graph ---

Graph_Ctx :: struct {
	g: ^gl.Doc_Graph,
	n: int,
}

pagerank_cb :: proc(user: rawptr) {
	ctx := cast(^Graph_Ctx)user
	pr, gerr := gl.graph_pagerank(ctx.g, {"共起"}, 0.85, 100, 1e-9,
		context.temp_allocator)
	if gerr != gl.Graph_Err.None { fault("graph_pagerank", gerr); return }
	ctx.n = len(pr)
	delete(pr, context.temp_allocator)
}

traverse_cb :: proc(user: rawptr) {
	ctx := cast(^Graph_Ctx)user
	res, gerr := gl.graph_traverse(ctx.g, {gl.Entity_Id(0)}, {"共起"}, 3, 1000,
		context.temp_allocator)
	if gerr != gl.Graph_Err.None { fault("graph_traverse", gerr); return }
	ctx.n = len(res.visits)
	delete(res.visits, context.temp_allocator)
}

// --- ZH arm: the 紅樓夢 plain-text loader ---

// The ebook's chapter shape: a 第N回 line (第, chapter numerals, 回,
// then a space or end of line — prose like 第四回中… or 第二回了… has no
// break after 回 and stays prose), usually underlined by a dash run a
// few lines later. zh_shape drops everything before the first heading
// (the PG credit block sits inside the markers and survives the staging
// strip) and rewrites each heading as ATX so markdown_segments derives
// the 120-回 outline; the one dash run right after a heading (blanks
// between) is dropped, farther ones stay as text.
zh_chapter_numeral :: proc(r: rune) -> bool {
	for nr in "零〇一二三四五六七八九十百千0123456789" {
		if nr == r { return true }
	}
	return false
}

zh_is_heading :: proc(l: string) -> bool {
	if len(l) < 6 { return false } // 第 + one numeral + 回, all 3-byte
	if l[0] != 0xE7 || l[1] != 0xAC || l[2] != 0xAC { return false } // 第
	i := 3
	for i < len(l) {
		r, size := utf8.decode_rune_in_string(l[i:])
		if !zh_chapter_numeral(r) { break }
		i += size
	}
	if i >= len(l) { return false }
	r, size := utf8.decode_rune_in_string(l[i:])
	if r != '回' { return false }
	rest := l[i + size:]
	if len(rest) == 0 { return true }
	return rest[0] == ' ' ||
		(len(rest) >= 3 && rest[0] == 0xE3 && rest[1] == 0x80 && rest[2] == 0x80)
}

zh_shape :: proc(text: string, a: mem.Allocator) -> (out: [dynamic]u8, headings: int) {
	out = make([dynamic]u8, 0, len(text) + 512, a)
	started := false
	after_heading := false // the next non-blank line may be the underline
	pending := 0 // blank lines held back after a heading
	n := len(text)
	i := 0
	for i <= n {
		j := i
		for j < n && text[j] != '\n' { j += 1 }
		line := text[i:j]
		if !started {
			if zh_is_heading(line) { started = true } else {
				if j >= n { break }
				i = j + 1
				continue
			}
		}
		blank := true
		dash := len(line) >= 4
		for b in transmute([]u8)line {
			if b != ' ' && b != '\t' && b != '\r' { blank = false }
			if b != '-' { dash = false }
		}
		if zh_is_heading(line) {
			append(&out, '#', ' ')
			for b in transmute([]u8)line { append(&out, b) }
			append(&out, '\n')
			headings += 1
			after_heading = true
			pending = 0
		} else if after_heading && blank {
			pending += 1
		} else if after_heading && dash {
			after_heading = false // the underline: dropped, its blanks with it
			pending = 0
		} else {
			for _ in 0..<pending { append(&out, '\n') }
			pending = 0
			after_heading = false
			for b in transmute([]u8)line { append(&out, b) }
			append(&out, '\n')
		}
		if j >= n { break }
		i = j + 1
	}
	return out, headings
}

zh_load_csv_cb :: proc(_: rawptr) {
	an, lerr := moli.load(.ChineseCN, ZH_DIC, {}, context.allocator)
	if lerr != nil { fault("load csv zh", lerr); return }
	moli.free(&an)
}

zh_restore_cb :: proc(user: rawptr) {
	ctx := cast(^Load_Path_Ctx)user
	an, lerr := ma.load_analyzer(ctx.path, ZH_DIC, .ChineseCN, {}, context.allocator)
	if lerr != nil { fault("restore qdct zh", lerr); return }
	moli.free(&an)
}

zh_freq_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	ftab, ferr := gl.freq_table(ctx.stream, {},
		{pos_prefixes = {"n"}, use_lemma = true},
		context.temp_allocator)
	if ferr != gl.Freq_Err.None { fault("zh freq_table", ferr); return }
	ctx.n = len(ftab)
	delete(ftab, context.temp_allocator)
}

zh_cooc_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	pairs, _, cerr := gl.co_occurrence(ctx.stream, {},
		{unit = .Segments, filter = {pos_prefixes = {"n"}, use_lemma = true},
			max_pairs = 20000},
		context.temp_allocator)
	if cerr != gl.Freq_Err.None { fault("zh co_occurrence", cerr); return }
	ctx.n = len(pairs)
	delete(pairs, context.temp_allocator)
}

// --- EN arm: the [host] fixture tokenizer ---

// gloaming's contract consumes []Token whatever produced them, so for a
// language the stack has no analyzer for the host owns tokenization.
// The fixture is deterministic: a word is a maximal run of ASCII
// letters/digits/hyphen or non-ASCII bytes (UTF-8 letters live there),
// any other ASCII byte is its own punctuation token, whitespace
// separates. Every token is id-less (kind .Idless, lemma = surface,
// reading "*", no POS) — the schema a non-morphological pipeline rides.
fixture_tokenize :: proc(text: string, out: ^[dynamic]gl.Token) {
	word_byte :: proc(c: u8) -> bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c >= 0x80
	}
	i, n := 0, len(text)
	for i < n {
		c := text[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' { i += 1; continue }
		j := i + 1
		if word_byte(c) {
			for j < n && word_byte(text[j]) { j += 1 }
		}
		append(out, gl.Token{
			surface = text[i:j], lemma = text[i:j], pos = "", reading = "*",
			start = i, end = j, kind = .Idless, entry_id = -1,
		})
		i = j
	}
}

Fixture_Tok_Ctx :: struct {
	text: string,
	out:  ^[dynamic]gl.Token,
}

fixture_tok_cb :: proc(user: rawptr) {
	ctx := cast(^Fixture_Tok_Ctx)user
	resize(ctx.out, 0)
	fixture_tokenize(ctx.text, ctx.out)
}

// The id-less schema never routes a token through a resolver (payload
// bit 17); rejecting every id makes any attempt a visible Not_Found
// instead of silent garbage — the decode row's proof it never happened.
fixture_resolve :: proc(_: rawptr, _: i32, _: string) ->
		(pos, lemma, reading: string, ok: bool) {
	return "", "", "", false
}

En_Decode_Ctx :: struct {
	blob: []u8,
	text: string,
	n:    int,
}

en_decode_cb :: proc(user: rawptr) {
	ctx := cast(^En_Decode_Ctx)user
	dec, derr := gl.payload_decode(ctx.blob, ctx.text, fixture_resolve, nil,
		context.temp_allocator)
	if derr != gl.Store_Err.None { fault("en payload decode", derr); return }
	ctx.n = len(dec)
	delete(dec, context.temp_allocator)
}

en_freq_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	ftab, ferr := gl.freq_table(ctx.stream, {}, {}, context.temp_allocator)
	if ferr != gl.Freq_Err.None { fault("en freq_table", ferr); return }
	ctx.n = len(ftab)
	delete(ftab, context.temp_allocator)
}

en_cooc_cb :: proc(user: rawptr) {
	ctx := cast(^Stats_Ctx)user
	pairs, _, cerr := gl.co_occurrence(ctx.stream, {},
		{unit = .Segments, max_pairs = 20000}, context.temp_allocator)
	if cerr != gl.Freq_Err.None { fault("en co_occurrence", cerr); return }
	ctx.n = len(pairs)
	delete(pairs, context.temp_allocator)
}

zh_arm :: proc(tok_arena: ^mem.Arena) {
	data, rerr := os.read_entire_file_from_path(ZH_FILE, context.allocator)
	if rerr != nil {
		fmt.printf("BENCH: SKIP ZH arm — %s not readable (%v)\n", ZH_FILE, rerr)
		return
	}
	zout, headings := zh_shape(string(data), context.allocator)
	defer {
		delete(zout)
		delete(data, context.allocator)
	}
	zh_text := string(zout[:])
	if len(zh_text) > ZH_PREFIX { zh_text = zh_text[:ZH_PREFIX] }

	hdr("[moli] ZH arm — jieba × 紅樓夢: dictionary load (CSV import, qdct)")
	fmt.printf("lexicon %s; loader kept %d 回-headings, bench rides a %d-KiB prefix\n",
		ZH_DIC, headings, ZH_PREFIX >> 10)
	t := run_stage(3, zh_load_csv_cb, nil)
	row("moli", "load CSV (jieba import)", 3, t, "")
	zan, zlerr := moli.load(.ChineseCN, ZH_DIC, {}, context.allocator)
	if zlerr != nil { fault("zh load for save", zlerr); return }
	t = run_stage(1, proc(user: rawptr) {
		if serr := moli.save_qdct(cast(^moli.Analyzer)user, ZH_QDCT,
				context.allocator); serr != nil {
			fault("save_qdct zh", serr)
		}
	}, &zan)
	zsize := "qdct size unknown"
	if f, oerr := os.open(ZH_QDCT); oerr == nil {
		if qz, fserr := os.file_size(f); fserr == nil {
			zsize = fmt.aprintf("%d bytes", qz)
		}
		os.close(f)
	}
	row("moli", "save_qdct zh (once)", 1, t, zsize)
	moli.free(&zan)
	zlp := Load_Path_Ctx{path = ZH_QDCT}
	t = run_stage(3, zh_restore_cb, &zlp)
	row("moli", "restore qdct zh (startup path)", 3, t, "via load_analyzer")

	an, alerr := ma.load_analyzer(ZH_QDCT, ZH_DIC, .ChineseCN, {}, context.allocator)
	if alerr != nil { fault("zh serving analyzer", alerr); return }
	defer moli.free(&an)
	st, _ := moli.stats(&an)
	fmt.printf("serving analyzer: %d entries, entries_hash %016x\n",
		st.entries, st.entries_hash)

	hdr("[moli]/[seam]/[gloaming] ZH arm — tokenize → adapt → segments → queries → stats")
	// the shared 512-MiB sink covers this prefix (~273 B/input byte
	// high-water); whole-novel tokenize holds the chapter-scale
	// per-byte rate (the JP rows), so the prefix is a shape choice,
	// not a cliff dodge
	if _, werr := moli.tokenize(&an, zh_text, mem.arena_allocator(tok_arena)); werr != nil {
		fault("zh warmup tokenize", werr)
		return
	}
	mem.arena_free_all(tok_arena)
	tc := Tok_Ctx{an = &an, text = zh_text, arena = tok_arena}
	t = run_stage(3, tokenize_cb, &tc)
	row("moli", fmt.aprintf("tokenize zh prefix (%d B)", len(zh_text)), 3, t,
		fmt.aprintf("%d morphemes, %.2f Mtok/s, arena sink", tc.n,
			f64(tc.n) / (t.best / 1000.0) / 1e6))

	ms, terr := moli.tokenize(&an, zh_text, context.allocator)
	if terr != nil { fault("zh retained tokenize", terr); return }
	defer delete(ms, context.allocator)
	toks: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 1 << 18, context.allocator)
	defer delete(toks)
	// slice literals can live in static/stack storage, so anything a
	// defer will delete is made and filled instead
	zmss := make([][]moli.Morpheme, 1, context.allocator)
	zmss[0] = ms
	defer delete(zmss, context.allocator)
	zbases := make([]int, 1, context.allocator)
	defer delete(zbases, context.allocator)
	ac := Adapt_Ctx{mss = zmss, bases = zbases, out = &toks}
	t = run_stage(5, adapt_cb, &ac)
	row("seam", "adapt (zh prefix, rebased)", 5, t,
		fmt.aprintf("%d tokens, %.2f Mtok/s", len(toks),
			f64(len(toks)) / (t.best / 1000.0) / 1e6))

	segs: [dynamic]gl.Segment = make([dynamic]gl.Segment, 0, 8192, context.allocator)
	defer delete(segs)
	ztexts := make([]string, 1, context.allocator)
	ztexts[0] = zh_text
	defer delete(ztexts, context.allocator)
	sc := Seg_Ctx{texts = ztexts, bases = zbases, out = &segs}
	t = run_stage(5, segments_cb, &sc)
	chapters := 0
	for s in segs {
		if s.kind == .Chapter { chapters += 1 }
	}
	row("seam", "markdown_segments (zh, 回 headings)", 5, t,
		fmt.aprintf("%d segments (%d chapters)", len(segs), chapters))

	stream := gl.Token_Stream{
		doc = gl.Doc_Id(0), tokens = toks[:], segments = segs[:],
	}
	fmt.printf("SCALE — zh stream: %d bytes, %d tokens, %d segments (%d chapters), dict %016x\n",
		len(zh_text), len(toks), len(segs), chapters, st.entries_hash)
	// jieba's POS column has no comma hierarchy — the same ^"prefix"
	// query shape is data-driven, not Japanese-shaped
	queries := [4]struct { src, name: string }{
		{`(seq (m pos ^"n"))`, "every noun (pos n)"},
		{`(seq (m pos ^"nr"))`, "person names (pos nr)"},
		{`(seq (m pos ^"n") (m _ :0-2) (m pos ^"v"))`, "noun gap:0-2 verb"},
		{`(seq (m surface "寶玉"))`, "surface 寶玉"},
	}
	for &q in queries {
		pq, perr := gl.query_parse(q.src, {}, context.temp_allocator)
		if perr != gl.Query_Err.None { fault(q.name, perr); continue }
		qc := Query_Ctx{q = &pq, stream = stream}
		t = run_stage(5, query_cb, &qc)
		row("gloaming", fmt.aprintf("zh query: %s", q.name), 5, t,
			fmt.aprintf("%d matches", qc.count))
	}
	sctx := Stats_Ctx{stream = stream}
	t = run_stage(3, zh_freq_cb, &sctx)
	row("gloaming", "zh freq_table (nouns, lemma)", 3, t,
		fmt.aprintf("%d rows", sctx.n))
	t = run_stage(3, zh_cooc_cb, &sctx)
	row("gloaming", "zh co_occurrence (segments, cap 20000)", 3, t,
		fmt.aprintf("%d pairs", sctx.n))
}

en_arm :: proc(store_arena: ^mem.Arena) {
	data, rerr := os.read_entire_file_from_path(EN_FILE, context.allocator)
	if rerr != nil {
		fmt.printf("BENCH: SKIP EN arm — %s not readable (%v)\n", EN_FILE, rerr)
		return
	}
	text := string(data)
	defer delete(data, context.allocator)

	hdr("[host]/[seam]/[gloaming] EN arm — fixture tokenizer × Maria Chapdelaine")
	toks: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 1 << 16, context.allocator)
	defer delete(toks)
	ftc := Fixture_Tok_Ctx{text = text, out = &toks}
	t := run_stage(3, fixture_tok_cb, &ftc)
	row("host", fmt.aprintf("fixture tokenize (%d B)", len(text)), 3, t,
		fmt.aprintf("%d tokens, %.2f Mtok/s", len(toks),
			f64(len(toks)) / (t.best / 1000.0) / 1e6))

	segs: [dynamic]gl.Segment = make([dynamic]gl.Segment, 0, 4096, context.allocator)
	defer delete(segs)
	etexts := make([]string, 1, context.allocator)
	etexts[0] = text
	defer delete(etexts, context.allocator)
	ebases := make([]int, 1, context.allocator)
	defer delete(ebases, context.allocator)
	sc := Seg_Ctx{texts = etexts, bases = ebases, out = &segs}
	t = run_stage(5, segments_cb, &sc)
	row("seam", "markdown_segments (en)", 5, t,
		fmt.aprintf("%d segments", len(segs)))

	stream := gl.Token_Stream{
		doc = gl.Doc_Id(0), tokens = toks[:], segments = segs[:],
	}
	fmt.printf("SCALE — en stream: %d bytes, %d tokens, %d segments, id-less schema\n",
		len(text), len(toks), len(segs))
	queries := [3]struct { src, name: string }{
		{`(seq (m surface "Maria"))`, "surface Maria"},
		{`(seq (m surface "Maria") (m surface "Chapdelaine"))`, "sequence Maria Chapdelaine"},
		{`(seq (m surface "in") (m _ :0-3) (m surface "the"))`, "gap in :0-3 the"},
	}
	for &q in queries {
		pq, perr := gl.query_parse(q.src, {}, context.temp_allocator)
		if perr != gl.Query_Err.None { fault(q.name, perr); continue }
		qc := Query_Ctx{q = &pq, stream = stream}
		t = run_stage(5, query_cb, &qc)
		row("gloaming", fmt.aprintf("en query: %s", q.name), 5, t,
			fmt.aprintf("%d matches", qc.count))
	}
	sctx := Stats_Ctx{stream = stream}
	t = run_stage(3, en_freq_cb, &sctx)
	row("gloaming", "en freq_table (all tokens, surface)", 3, t,
		fmt.aprintf("%d rows", sctx.n))
	t = run_stage(3, en_cooc_cb, &sctx)
	row("gloaming", "en co_occurrence (segments, cap 20000)", 3, t,
		fmt.aprintf("%d pairs", sctx.n))

	stc := Store_Ctx{
		arena = store_arena, text = text, tokens = toks[:], segments = segs[:],
	}
	t = run_stage(3, store_add_cb, &stc)
	mem.arena_free_all(store_arena)
	row("gloaming", "en store_memory add_document", 3, t, "fresh store per rep")

	// dict_version 0: the id-less schema has no dictionary to version
	key := gl.Payload_Key{
		text_hash = hash.fnv64a(transmute([]u8)text), dict_version = 0, options = 0,
	}
	pc := Payload_Ctx{key = key, text = text, tokens = toks[:]}
	t = run_stage(3, encode_cb, &pc)
	blob, berr := gl.payload_encode(key, text, toks[:], context.temp_allocator)
	if berr != gl.Store_Err.None { fault("en payload_encode retained", berr); return }
	row("gloaming", "en payload_encode (id-less)", 3, t,
		fmt.aprintf("%.2f B/token", f64(len(blob)) / f64(len(toks))))
	z, zerr := gl.payload_compress(blob, context.temp_allocator)
	if zerr != gl.Store_Err.None { fault("en payload_compress retained", zerr); return }
	bc := Blob_Ctx{blob = blob}
	t = run_stage(3, compress_cb, &bc)
	row("gloaming", "en payload_compress (DEFLATE)", 3, t,
		fmt.aprintf("%.1f:1 (%.0f→%.0f KB)", f64(len(blob)) / f64(len(z)),
			f64(len(blob)) / 1024.0, f64(len(z)) / 1024.0))
	bc2 := Blob_Ctx{blob = z}
	t = run_stage(3, decompress_cb, &bc2)
	row("gloaming", "en payload_decompress", 3, t, "")
	dc := En_Decode_Ctx{blob = blob, text = text}
	t = run_stage(3, en_decode_cb, &dc)
	row("gloaming", "en payload_decode (id-less)", 3, t,
		fmt.aprintf("%d tokens, resolver never called", dc.n))

	// the round-trip proof: decompress restores the blob byte for byte
	// and decode rebuilds every field through the id-less path — no
	// resolver exists to call (fixture_resolve rejects every id)
	raw, rerr2 := gl.payload_decompress(z, context.temp_allocator)
	if rerr2 != gl.Store_Err.None { fault("en round-trip decompress", rerr2); return }
	bytes_eq := len(raw) == len(blob)
	if bytes_eq {
		for i in 0..<len(raw) {
			if raw[i] != blob[i] { bytes_eq = false }
		}
	}
	dec, derr2 := gl.payload_decode(raw, text, fixture_resolve, nil,
		context.temp_allocator)
	if derr2 != gl.Store_Err.None { fault("en round-trip decode", derr2); return }
	mism := len(dec) + len(toks) + 1 // the length-mismatch case
	if len(dec) == len(toks) {
		mism = 0
		for i in 0..<len(dec) {
			a, b := dec[i], toks[i]
			if a.surface != b.surface || a.lemma != b.lemma || a.pos != b.pos ||
					a.reading != b.reading || a.start != b.start || a.end != b.end ||
					a.kind != b.kind || a.cost != b.cost ||
					a.entry_id != b.entry_id {
				mism += 1
			}
		}
	}
	fmt.printf("round-trip: blob bytes %s, %d/%d tokens field-identical, %d mismatches\n",
		("identical" if bytes_eq else "DIFFER"), len(dec), len(toks), mism)
	delete(dec, context.temp_allocator)
	delete(raw, context.temp_allocator)
	delete(blob, context.temp_allocator)
	delete(z, context.temp_allocator)
}

main :: proc() {
	// local-facts guard (the recipe guards too; a direct odin run gets
	// it here) — missing corpus is SKIP, never failure
	probe, perr := os.read_entire_file_from_path(REAL_FILES[0], context.temp_allocator)
	if perr != nil {
		fmt.printf("BENCH: SKIP — %s not readable (link the local corpus per corpus/README.md)\n",
			REAL_FILES[0])
		return
	}
	delete(probe, context.temp_allocator)
	if !os.exists("tmp") { _ = os.mkdir("tmp") }
	_ = os.remove(QDCT_PATH)

	// the corpus text: files concatenated with '\n' (the real_load
	// shape); per-file substrings for tokenize, bases for rebasing
	parts: [dynamic]string = make([dynamic]string, 0, len(REAL_FILES), context.allocator)
	total := 0
	for path in REAL_FILES {
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			fmt.printf("BENCH: cannot read %s (%v)\n", path, err)
			return
		}
		append(&parts, string(data))
		total += len(data) + 1
	}
	text_buf := make([]u8, total, context.allocator)
	texts := make([]string, len(REAL_FILES), context.allocator)
	bases := make([]int, len(REAL_FILES), context.allocator)
	{
		off := 0
		for p, i in parts {
			copy(text_buf[off:], transmute([]byte)p)
			texts[i] = string(text_buf[off:off + len(p)])
			bases[i] = off
			off += len(p)
			text_buf[off] = '\n'
			off += 1
			delete(p, context.allocator)
		}
	}
	delete(parts)
	text := string(text_buf)

	// ---- [moli] dictionary load ----
	hdr("[moli] dictionary load — CSV import, qdct save, qdct restore")
	fmt.printf("lexicon %s\n", REAL_DIC)
	t := run_stage(3, load_csv_cb, nil)
	row("moli", "load CSV (import)", 3, t, "")
	save_an, slerr := moli.load(.Japanese, REAL_DIC, {}, context.allocator)
	if slerr != nil { fault("load for save", slerr); return }
	t = run_stage(1, proc(user: rawptr) {
		if serr := moli.save_qdct(cast(^moli.Analyzer)user, QDCT_PATH,
				context.allocator); serr != nil {
			fault("save_qdct", serr)
		}
	}, &save_an)
	qsize := "qdct size unknown"
	if f, oerr := os.open(QDCT_PATH); oerr == nil {
		if qz, fserr := os.file_size(f); fserr == nil {
			qsize = fmt.aprintf("%d bytes", qz)
		}
		os.close(f)
	}
	row("moli", "save_qdct (once)", 1, t, qsize)
	moli.free(&save_an)
	lp := Load_Path_Ctx{path = QDCT_PATH}
	t = run_stage(3, load_qdct_cb, &lp)
	row("moli", "restore qdct (startup path)", 3, t, "via load_analyzer")

	// the serving analyzer for every stage below — the recommended
	// startup shape (restored), so all downstream numbers ride it
	an, alerr := ma.load_analyzer(QDCT_PATH, REAL_DIC, .Japanese, {},
		context.allocator)
	if alerr != nil { fault("serving analyzer", alerr); return }
	st, _ := moli.stats(&an)
	fmt.printf("serving analyzer: %d entries, entries_hash %016x\n",
		st.entries, st.entries_hash)

	// the tokenize rows' result sink: one reusable arena, reset per call.
	// moli's tokenize contract sends the request-scoped Viterbi lattice
	// here too (a 240-KiB call high-waters ~64 MiB), and an arena sink
	// measured 1.9x end-to-end over the default allocator on this corpus;
	// 512 MiB covers the 3-file reps with room for shape growth.
	tok_arena_buf := make([]u8, 1 << 29, context.allocator)
	defer delete(tok_arena_buf, context.allocator)
	tok_arena: mem.Arena
	mem.arena_init(&tok_arena, tok_arena_buf[:])

	// warm the dictionary — and the arena's first pages — before the reps
	if _, werr := moli.tokenize(&an, texts[0], mem.arena_allocator(&tok_arena)); werr != nil {
		fault("warmup tokenize", werr)
		return
	}
	mem.arena_free_all(&tok_arena)

	// ---- [moli] tokenize ----
	hdr("[moli] tokenize — Viterbi, chapter (file 1) / novel (3 files), arena result sink")
	tc := Tok_Ctx{an = &an, text = texts[0], arena = &tok_arena}
	t = run_stage(3, tokenize_cb, &tc)
	row("moli", fmt.aprintf("tokenize chapter (%d B)", len(texts[0])), 3, t,
		fmt.aprintf("%d morphemes, %.2f Mtok/s, arena sink", tc.n,
			f64(tc.n) / (t.best / 1000.0) / 1e6))
	nc := Novel_Tok_Ctx{an = &an, texts = texts, arena = &tok_arena}
	t = run_stage(3, tokenize_novel_cb, &nc)
	row("moli", fmt.aprintf("tokenize novel (%d B)", len(text)), 3, t,
		fmt.aprintf("%d morphemes, %.2f Mtok/s, arena sink", nc.n,
			f64(nc.n) / (t.best / 1000.0) / 1e6))

	// retained per-file morphemes — the adapt stage's input
	mss := make([][]moli.Morpheme, len(REAL_FILES), context.allocator)
	for i in 0..<len(texts) {
		ms, terr := moli.tokenize(&an, texts[i], context.allocator)
		if terr != nil { fault("retained tokenize", terr); return }
		mss[i] = ms
	}

	// ---- [seam] adapter ----
	hdr("[seam] adapter — adapt (Morpheme→Token), markdown_segments")
	toks: [dynamic]gl.Token = make([dynamic]gl.Token, 0, 1 << 18, context.allocator)
	ac := Adapt_Ctx{mss = mss, bases = bases, out = &toks}
	t = run_stage(5, adapt_cb, &ac)
	row("seam", "adapt (novel, rebased)", 5, t,
		fmt.aprintf("%d tokens, %.2f Mtok/s", len(toks),
			f64(len(toks)) / (t.best / 1000.0) / 1e6))
	segs: [dynamic]gl.Segment = make([dynamic]gl.Segment, 0, 8192, context.allocator)
	sc := Seg_Ctx{texts = texts, bases = bases, out = &segs}
	t = run_stage(5, segments_cb, &sc)
	row("seam", "markdown_segments (novel)", 5, t,
		fmt.aprintf("%d segments", len(segs)))
	for ms in mss { delete(ms, context.allocator) }
	delete(mss, context.allocator)

	// the last adapt rep left `toks` populated — that IS the novel
	// stream every gloaming stage below consumes
	paragraphs := 0
	for s in segs {
		if s.kind == .Paragraph { paragraphs += 1 }
	}
	stream := gl.Token_Stream{
		doc = gl.Doc_Id(0), tokens = toks[:], segments = segs[:],
	}
	hdr("SCALE — the novel stream every [gloaming] stage consumes")
	fmt.printf("%d bytes, %d tokens, %d segments (%d paragraphs), dict %016x\n",
		len(text), len(toks), len(segs), paragraphs, st.entries_hash)

	// ---- [gloaming] memory store ----
	hdr("[gloaming] memory store — add_document (whole novel, cloned)")
	store_arena: mem.Arena
	mem.arena_init(&store_arena, store_arena_buf[:])
	stc := Store_Ctx{
		arena = &store_arena, text = text, tokens = toks[:], segments = segs[:],
	}
	t = run_stage(3, store_add_cb, &stc)
	mem.arena_free_all(&store_arena)
	row("gloaming", "store_memory add_document", 3, t, "fresh store per rep")

	// ---- [gloaming] queries ----
	hdr("[gloaming] queries — library DSL on the novel stream (best-of-5)")
	queries := [6]struct { src, name: string }{
		{`(seq (m pos ^"名詞,"))`, "every noun"},
		{`(seq (m pos ^"名詞,") (m _ :0-2) (m pos ^"動詞,"))`, "noun gap:0-2 verb"},
		{`(seq (m pos ^"名詞," :3-8))`, "noun run :3-8"},
		{`(seq ^ (m surface "諸戸"))`, "anchored 諸戸"},
		{`(seq (m reading "チョコレート"))`, "reading = チョコレート"},
		{`(seq (alt (m surface "氏") (m surface "さん")) (not! (m pos ^"助詞,")))`,
			"alt 氏/さん sans particle"},
	}
	for &q in queries {
		pq, perr := gl.query_parse(q.src, {}, context.temp_allocator)
		if perr != gl.Query_Err.None { fault(q.name, perr); continue }
		qc := Query_Ctx{q = &pq, stream = stream}
		t = run_stage(5, query_cb, &qc)
		row("gloaming", fmt.aprintf("query: %s", q.name), 5, t,
			fmt.aprintf("%d matches", qc.count))
	}

	// ---- [gloaming] stats ----
	hdr("[gloaming] stats — freq_table, co_occurrence, presence (novel)")
	sctx := Stats_Ctx{stream = stream}
	t = run_stage(3, freq_cb, &sctx)
	row("gloaming", "freq_table (nouns, lemma)", 3, t,
		fmt.aprintf("%d rows", sctx.n))
	t = run_stage(3, cooc_cb, &sctx)
	row("gloaming", "co_occurrence (paragraph, cap 20000)", 3, t,
		fmt.aprintf("%d pairs", sctx.n))
	t = run_stage(3, presence_cb, &sctx)
	row("gloaming", "cooc_presence (marginals)", 3, t,
		fmt.aprintf("%d keys", sctx.n))

	// retained copies (untimed) for the graph stage's shape
	ftab, _ := gl.freq_table(stream, {},
		{pos_prefixes = {"名詞,"}, use_lemma = true}, context.temp_allocator)
	coop, _, _ := gl.co_occurrence(stream, {},
		{unit = .Segments, filter = {pos_prefixes = {"名詞,"}, use_lemma = true},
		 max_pairs = 20000},
		context.temp_allocator)

	// ---- [gloaming] payload ----
	hdr("[gloaming] payload — encode/compress/decompress/decode (novel)")
	dv, dverr := ma.dictionary_hash(&an)
	if dverr != nil { fault("dictionary_hash", dverr); return }
	key := gl.Payload_Key{
		text_hash = hash.fnv64a(transmute([]u8)text), dict_version = dv, options = 0,
	}
	pc := Payload_Ctx{key = key, text = text, tokens = toks[:]}
	t = run_stage(3, encode_cb, &pc)
	blob, berr := gl.payload_encode(key, text, toks[:], context.temp_allocator)
	if berr != gl.Store_Err.None { fault("payload_encode retained", berr); return }
	row("gloaming", "payload_encode", 3, t,
		fmt.aprintf("%.2f B/token", f64(len(blob)) / f64(len(toks))))
	z, zerr := gl.payload_compress(blob, context.temp_allocator)
	if zerr != gl.Store_Err.None { fault("payload_compress retained", zerr); return }
	// the main row rides payload_compress's own default (chain 8, the
	// knee); reference rows show the dial's upward trade-off —
	// slower for a better ratio up to chain 16, dominated past it
	bc := Blob_Ctx{blob = blob, chain = 0}
	t = run_stage(3, compress_cb, &bc)
	row("gloaming", "payload_compress (DEFLATE)", 3, t,
		fmt.aprintf("%.1f:1 (%.0f→%.0f KB)", f64(len(blob)) / f64(len(z)),
			f64(len(blob)) / 1024.0, f64(len(z)) / 1024.0))
	delete(z, context.temp_allocator)
	ref_chains := []int{16, 32}
	for chain in ref_chains {
		zc := Blob_Ctx{blob = blob, chain = chain}
		t = run_stage(3, compress_cb, &zc)
		zz, zzerr := gl.payload_compress(blob, context.temp_allocator, chain)
		if zzerr != gl.Store_Err.None { fault("payload_compress ref", zzerr); return }
		row("gloaming", fmt.aprintf("payload_compress (chain %d ref)", chain), 3, t,
			fmt.aprintf("%.1f:1 (%.0f→%.0f KB)", f64(len(blob)) / f64(len(zz)),
				f64(len(blob)) / 1024.0, f64(len(zz)) / 1024.0))
		delete(zz, context.temp_allocator)
	}
	bc2 := Blob_Ctx{blob = z}
	t = run_stage(3, decompress_cb, &bc2)
	row("gloaming", "payload_decompress", 3, t, "")
	dc := Decode_Ctx{an = &an, blob = blob, text = text}
	t = run_stage(3, decode_cb, &dc)
	row("gloaming", "payload_decode (entry_ref)", 3, t,
		fmt.aprintf("%d tokens", len(toks)))

	// ---- [gloaming] disk store ----
	hdr("[gloaming] disk store — add / reopen / decode (novel)")
	for i in 0..<3 {
		dac := Disk_Add_Ctx{
			an = &an, dv = dv, i = i,
			text = text, tokens = toks[:], segments = segs[:],
		}
		t = run_stage(1, disk_add_cb, &dac)
		row("gloaming", fmt.aprintf("disk add_document (rep %d)", i), 1, t,
			fmt.aprintf("registry %d KB + payloads %d KB",
				dac.reg_bytes / 1024, dac.pay_bytes / 1024))
	}
	keep := fmt.aprintf("%s/keep", DISK_ROOT, context.temp_allocator)
	if !os.exists(keep) { _ = os.mkdir(keep) }
	// populate once (untimed): the reopen/decode stages need a store
	// that actually holds the novel
	pk_store, pk_ds, pkerr := gl.store_disk(keep, ma.payload_resolver, &an, dv, 0,
		context.allocator)
	if pkerr == gl.Store_Err.None {
		if aerr := pk_store.add_document(pk_store.ctx, gl.Doc_Id(0), text, toks[:],
				segs[:]); aerr != gl.Store_Err.None {
			fault("keep add_document", aerr)
		}
	} else {
		fault("store_disk keep", pkerr)
	}
	gl.disk_store_close(pk_ds)
	roc := Load_Disk_Ctx{dir = keep, an = &an, dv = dv}
	t = run_stage(3, disk_reopen_cb, &roc)
	row("gloaming", "disk reopen (replay registry)", 3, t, "")
	dec_store, dec_ds, derr := gl.store_disk(keep, ma.payload_resolver, &an, dv, 0,
		context.allocator)
	if derr != gl.Store_Err.None { fault("store_disk decode", derr); return }
	dec := Disk_Decode_Ctx{store = dec_store}
	t = run_stage(3, disk_decode_cb, &dec)
	gl.disk_store_close(dec_ds)
	row("gloaming", "disk tokens (decode)", 3, t,
		fmt.aprintf("%d tokens", len(toks)))

	// ---- [gloaming] graph ----
	hdr("[gloaming] graph — corpus-shaped: top lemmas + co-occurrence edges")
	// A bench shape, not a curation record: entities are the top-64
	// noun lemmas, edges the co-occurrence pairs between them (no
	// evidence spans — the walk costs do not read them).
	g: gl.Doc_Graph
	gl.graph_init(&g, context.allocator)
	ids: map[string]gl.Entity_Id = make(map[string]gl.Entity_Id, context.temp_allocator)
	term_kind := gl.graph_kind_intern(&g, "term")
	n_ent := min(512, len(ftab))
	for i in 0..<n_ent {
		e := gl.Entity{
			id = gl.Entity_Id(i), live = true, kind = term_kind,
			name = ftab[i].lemma,
		}
		gl.graph_apply_entity(&g, e)
		ids[ftab[i].lemma] = e.id
	}
	cooc_kind := gl.graph_kind_intern(&g, "共起")
	n_edges := 0
	for p in coop {
		ia, aok := ids[p.a]
		ib, bok := ids[p.b]
		if !aok || !bok || ia == ib { continue }
		gl.graph_apply_relation(&g, gl.Relation{
			id = gl.Relation_Id(n_edges), live = true, kind = cooc_kind,
			from = ia, to = ib, derived = true,
		})
		n_edges += 1
	}
	fmt.printf("built: %d entities, %d edges\n", n_ent, n_edges)
	gc := Graph_Ctx{g = &g}
	t = run_stage(3, pagerank_cb, &gc)
	row("gloaming", "graph_pagerank", 3, t, fmt.aprintf("%d scores", gc.n))
	t = run_stage(3, traverse_cb, &gc)
	row("gloaming", "graph_traverse (depth 3)", 3, t,
		fmt.aprintf("%d visits", gc.n))
	gl.graph_destroy(&g)
	delete(ids)
	delete(ftab, context.temp_allocator)
	delete(coop, context.temp_allocator)
	delete(blob, context.temp_allocator)
	delete(z, context.temp_allocator)

	// the language arms (each skip-guarded on its own corpus)
	zh_arm(&tok_arena)
	en_arm(&store_arena)

	moli.free(&an)
	delete(toks)
	delete(segs)
	delete(texts, context.allocator)
	delete(bases, context.allocator)
	delete(text_buf, context.allocator)
	fmt.print("\nBENCH: done\n")
}
