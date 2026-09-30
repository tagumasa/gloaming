# gloaming

A document-intelligence library written in Odin — pattern queries, an
evidence-bearing document graph, and corpus statistics over annotated
token sequences. Deterministic, core-only, built as the middle layer
for the applications that embed it: hosts adapt tokens, render and
stream results, and own the application surface.

**moli** (茉莉) is the jasmine that scents the evening — the
morphological analyzer it was developed against — and **gloaming** is
the Scots word for the twilight that follows. Japanese has the sharper
etymology — 黄昏 *tasogare* writes itself 誰そ彼, "who is she?", the hour
when faces stop being recognizable. This library does the opposite of
that blur: it makes out the shapes hiding in runs of text.

Concretely, over morphemes from an analyzer (or any `[]Token` a host
cares to adapt), gloaming provides:

- **Pattern queries** — an scm-style S-expression DSL over token fields
  (surface, lemma, POS, reading), with quantifiers, captures, and
  negation; KWIC extraction and pattern-driven compounding views come
  with it
- **A document graph** — entities, relations, and mentions where every
  edge carries the text spans it was derived from; coding rules and
  host curation land in the same mechanism
- **Statistics** — frequency tables, association
  measures, co-occurrence, keyness, cross-tabs, clustering, and
  coordinates; pure `core:math`, returning data, never pictures
- **A tiered store** — an append-only GLR1 record log over append-only
  binary token payloads over a bounded hot cache, split by mutability
  so neither memory nor consistency is ever improvised. Pure Odin end
  to end: no FFI, no C, nothing the Odin toolchain can't build alone

The surface, for flavour:

```scheme
;; a verb in dictionary form 走る, up to two tokens of anything,
;; then a common noun — captured as @obj
(seq (m lemma "走る" pos ^"動詞,") (m _ :0-2) (m pos ^"名詞,一般,") @obj)
```

The specification — layer rules, the DSL grammar, the graph and
statistics models, the storage design, API discipline — is
[docs/design.md](docs/design.md).

## Embedding the library

The package is used as an Odin collection
(`-collection:gloaming=src`). One request, one arena: results live on
the caller's arena and die with it, a parsed query is immutable and
serves concurrent cursors, and every span that comes back is byte
evidence into the source text.

```odin
import "core:fmt"
import "core:mem"
import gl "gloaming:gloaming"

main :: proc() {
	// Size the arena for the whole request — parse, cursor, and
	// results together. An exhausted arena fails silently in Odin's
	// non-debug runtime (make returns empty, appends drop), so an
	// under-sized arena surfaces as wrong results, never an error.
	buf: [64 << 10]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	a := mem.arena_allocator(&arena)
	defer mem.arena_free_all(&arena)

	// The host adapts its analyzer's output into []Token — hand-built
	// here; the moli adapter does the same field-for-field from
	// moli.Morpheme. start/end are byte offsets into the source text.
	text := "毎年さくらをみる。"
	toks := []gl.Token{
		{surface = "毎年", lemma = "毎年", pos = "副詞,助詞類接続,*,*,*", reading = "マイトシ", start = 0, end = 6, kind = .Idless, entry_id = -1},
		{surface = "さくら", lemma = "さくら", pos = "名詞,一般,*,*,*", reading = "サクラ", start = 6, end = 15, kind = .Idless, entry_id = -1},
		{surface = "を",   lemma = "を",   pos = "助詞,格助詞,一般,*",   reading = "ヲ",     start = 15, end = 18, kind = .Idless, entry_id = -1},
		{surface = "みる", lemma = "みる", pos = "動詞,自立,一段,基本形", reading = "ミル",   start = 18, end = 24, kind = .Idless, entry_id = -1},
		{surface = "。",   lemma = "。",   pos = "記号,句点,*",          reading = "。",     start = 24, end = 27, kind = .Idless, entry_id = -1},
	}
	// Empty segments = one whole-stream segment; a host with an
	// outline layer passes its chapter/paragraph/sentence spans.
	stream := gl.Token_Stream{doc = 0, tokens = toks}

	// ^"名詞," is the POS-hierarchy prefix convention: 名詞,一般,…,
	// 名詞,固有名詞,… all match.
	q, qerr := gl.query_parse(
		`(seq (m pos ^"名詞,") @n (m _ :1-3) (m pos ^"動詞,"))`, {}, a)
	if qerr != .None { /* switch on the Query_Err vocabulary */ return }

	// Stream the complete match set; each match lands on the arena.
	c := gl.match_begin(&q, stream, a)
	defer gl.cursor_destroy(&c)
	for {
		m, ok := gl.next_match(&c, a)
		if !ok { break }
		n := m.captures[0]
		fmt.printfln("match %q  capture @n %q",
			text[m.span.start:m.span.end], text[n.span.start:n.span.end])
	}
	// → match "さくらをみる"  capture @n "さくら"

	// The same stream straight into a count table — complete rows,
	// deterministically sorted (count desc, key asc); the host
	// slices top-k itself.
	rows, ferr := gl.freq_table(stream, nil, {use_lemma = true, min_len = 2}, a)
	if ferr != .None { return }
	for r in rows { fmt.printfln("%s\t%d", r.lemma, r.count) }
	// → さくら 1 / みる 1 / 毎年 1
}
```

Cursor streaming, caller-dial caps with visible `truncated` flags,
bounded caches, and the optional stop-check (`check`/`user` trailing
parameters) are the discipline every read API follows — the rules and
their scope are [docs/design.md](docs/design.md)'s "API discipline"
section.

## The CLI host

The first host is a standalone CLI (`just cli` builds it), a one-shot
process over a project directory: ingest a corpus, query it, curate a
document graph, run the statistics. Every JSON result carries a
provenance envelope (command, dictionary hash, variant, truncated
flag). The transcript below is real output against a two-file demo
corpus and moli's committed sample dictionary
(`vendor/moli/tests/fixtures/ipadic_sample.csv`), exactly as emitted:

```sh
$ ./gloaming --project demo init corpus/ --lang ja --dict vendor/moli/tests/fixtures/ipadic_sample.csv
{"command":"init","dict":"886182150f302c5f","variant":null,"truncated":false,"rows":[{"docs":2,"bytes":260,"tokens":52,"segments":2,"entries":23}]}

$ ./gloaming --project demo query '(seq (m pos ^"名詞,") @n (m _ :1-3) (m pos ^"動詞,"))' --limit 1
{"command":"query","dict":"886182150f302c5f","variant":null,"truncated":true,"rows":[{"doc":0,"start":58,"end":82,"surfaces":["東京","の","公園","を","歩く"],"captures":[{"name":"n","start":58,"end":64,"surface":"東京"}]}]}

$ ./gloaming --project demo kwic '(seq (m lemma "歩く"))' --left 4 --right 1
0:76  東京の公園を 【歩く】 。
0:106  犬もゆきの中を 【歩く】 。

$ ./gloaming --project demo freq --lemma --min-len 2 --limit 4 --format tsv
わたし	2	2
会議	2	1
東京	2	2
歩く	2	1
```

The unknown-suspect → variant-dictionary arc: `unknown` enumerates
tokens the dictionary lacks, a variant
(`variant add v2 entries.tsv`) re-tokenizes the whole corpus under the
merged dictionary and replays the graph rows, and `variant diff`
quantifies the shift (in the demo: unknown rate 0.54 → 0.41). The full
worked session — graph curation with byte-span evidence, coding rules,
toposort with its cyclic remainder, keyness, cross-tabs, clustering —
is [docs/cli.md](docs/cli.md).

## Quick start

```sh
git clone --recurse-submodules https://github.com/tagumasa/gloaming
cd gloaming
just check         # odin check -vet -strict-style over the library
just test          # serial suite; verdicts from the log, zero leak lines
just cli           # build the CLI host to ./gloaming
./gloaming --help  # usage, straight from the binary
```

Those two gates are self-contained: the library and its test suite
build with the Odin toolchain alone — the vendored moli analyzer
(submodule at `vendor/moli`, the public
[github.com/tagumasa/moli](https://github.com/tagumasa/moli) tree) is
no part of them. The adapter, the CLI, and the benchmark gates need
that submodule initialized (`git submodule update --init` if the clone
skipped it); the benchmark additionally needs moli's dictionaries
(fetched per moli's README) and a staged corpus (`just corpus-ja`) —
those recipes skip with a note when their inputs are absent.

## Requirements

- The Odin compiler, nightly `dev-2026-09-nightly:a2fb372` (gates are
  re-run and the pin re-baselined after toolchain updates)
- `just` (any recent version)
- The vendored moli submodule, initialized, for the adapter/CLI/bench
  gates (a `--recurse-submodules` clone has it already)

## Layout

```
src/gloaming/   the library (package gloaming): token view, query model,
                graph records, stats types, store ports, GLB1 payload
                blobs + the DEFLATE distribution codec, the GLR1 record
                log + disk store backend
src/glexport/   auxiliary text-interchange package (dot/mermaid/JSON
                over returned data — outside the library body)
cli/            the CLI host (package main)
adapter_src/    moli adapter (imports both gloaming and moli — the
                core never imports moli)
adapter_tests/  the adapter's fixture-dictionary suite
vendor/moli/    pinned submodule — the public moli repository (the
                adapter's input; src/ never imports it)
tests/          separate test package (imports via -collection:gloaming=src)
bench/          the quantitative benchmark (skip-guarded on its inputs)
scripts/        host-side tooling (the Aozora staging pass for the bench corpus)
docs/           design.md (the specification) + cli.md (the reference)
corpus/         local-only test data (gitignored; see corpus/README.md)
```

## Status

Implemented: the query engine, the storage tier, the document graph
through full curation (alias/merge, evidence and derived relations,
mentions, coding rules, variant replay), corpus statistics through
clustering and coordinates, and the CLI host over all of it. `just
test` and `just test-adapter` run the suites under a tracking
allocator and fail on any leak block in the log. The application
surface beyond the CLI — a GUI included — belongs to the hosts that
embed it.

The committed performance baseline is [docs/benchmarks.md](docs/benchmarks.md) —
re-measured and replaced in place when the baseline moves; corpus
numbers appear there as measurements only, never corpus text.

## Contributing

Bug fixes are welcome against the gates (`just check`, `just test`).
New features need a prior issue — the specification governs the
implementation, so analytical additions start as design discussion.
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
