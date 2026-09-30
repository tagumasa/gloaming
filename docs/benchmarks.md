# Benchmarks

The measured cross-section and the methodology that produced it. The
harness is `bench/` (`just bench`); the stage tags attribute every
number to the tree that owns it. This is the single home for measured
numbers: the other documents point here, they never copy its figures.

The corpus is 孤島の鬼 (江戸川乱歩, public domain, staged from 青空文庫
per [corpus/README.md](../corpus/README.md)) — 511,840 B, 172.9k
characters, 48 chapters in three part files; 116,557 tokens, 1,671
segments (1,620 paragraphs), 4.39 B/token. The numbers are for this
shape.

## Environment

| Host | CPU | Memory | System | Compiler | Date |
|---|---|---|---|---|---|
| x86 dev box | Ryzen 7 5700U, 8 cores / 16 SMT threads | 15 GiB DDR4-3200 dual-channel, NVMe | Linux (native) | dev-2026-09-nightly `a2fb372`, `-o:speed` | 2026-09-30 |

The same machine as moli's benchmark record
(vendor/moli/docs/benchmarks.md). Dictionaries: ipadic 2.7.0 UTF-8 —
392,126 entries, `entries_hash a7a6b8263474367a`; mecab-jieba 0.1.1 —
584,429 entries, `entries_hash 83dd02da8715e4c3`. The hash prints at
load and in every run's SCALE header — a changed hash means the
dictionary content moved, and the [moli] rows with it.

How to read every table:

- **Wall figures are window measurements.** Counts are identical
  across back-to-back runs; wall-time spread is 0.5–5% on the compute
  rows and up to ~2× on the memory-copy rows (store add, payload
  decompress/decode) when background load creeps in. Compare within a
  window. **Re-measure before treating a regression — or an
  "improvement" — as real**: adjacent same-session runs, doubled when
  ambiguous — cross-day drift exceeds the within-day spread in both
  directions.
- **Deterministic figures do not wobble.** Stability counts print
  beside the timings — a moved count means semantics changed, not
  performance.
- **Seconds-scale load arms are medians, ms-scale arms best-of** (n
  per table; every number a session measurement, not a guarantee).
- **This file is a cross-section, not a diary.** A re-measured
  baseline replaces the tables in place, in the same change as the
  shift that moved them — no measurement histories, no before/after
  progressions, no re-measurement chronicles, no commit-hash
  citations. The run's provenance block (date, toolchain, both trees'
  HEADs, host) stays in the harness log; this file
  carries the standing numbers only.

## Stage attribution

| Tag | Stages | A move means |
|---|---|---|
| moli | load CSV, save/restore qdct, tokenize | the moli tree moved |
| seam | adapt (Morpheme→Token), markdown_segments | the adapter contract moved |
| gloaming | store add, queries, freq/co-occurrence, payload encode/compress/decompress/decode, disk add/reopen/decode, pagerank/traverse | the gloaming tree moved |
| host | the EN arm's fixture tokenizer | the host's own tokenization moved |

Everything moved → toolchain or host. One stage moved → that side.

## [moli] dictionary load

| Stage | best | median | n | notes |
|---|---|---|---|---|
| load CSV (import) | 1.13 s | 1.13 s | 3 | heap, load+free per rep |
| save_qdct (once) | 86.5 ms | — | 1 | 64 MiB snapshot (67,183,848 B) |
| restore qdct (startup) | 72.1 ms | 72.4 ms | 3 | via adapter load_analyzer |

## [moli] tokenize (Viterbi, zero options, arena result sink)

| Input | best | median | n | throughput |
|---|---|---|---|---|
| chapter 168,194 B | 24.35 ms | 24.41 ms | 3 | 1.57 Mtok/s |
| novel 511,840 B (3 files) | 74.16 ms | 74.24 ms | 3 | 1.57 Mtok/s |

## [seam] adapter

| Stage | best | median | n | notes |
|---|---|---|---|---|
| adapt (novel, rebased) | 2.04 ms | 2.07 ms | 5 | 57.15 Mtok/s |
| markdown_segments (novel) | 0.71 ms | 0.72 ms | 5 | 1,671 segments |

## [gloaming] memory store

| Stage | best | median | n | notes |
|---|---|---|---|---|
| store_memory add_document | 9.66 ms | 9.91 ms | 3 | whole novel cloned; fresh store per rep |

## [gloaming] queries (library DSL, novel stream)

| Query | best | median | n | matches |
|---|---|---|---|---|
| `(seq (m pos ^"名詞,"))` | 4.71 ms | 4.92 ms | 5 | 32,966 |
| `(seq (m pos ^"名詞,") (m _ :0-2) (m pos ^"動詞,"))` | 8.52 ms | 8.74 ms | 5 | 9,338 |
| `(seq (m pos ^"名詞," :3-8))` | 4.73 ms | 4.82 ms | 5 | 645 |
| `(seq ^ (m surface "諸戸"))` | 0.62 ms | 0.68 ms | 5 | 104 |
| `(seq (m reading "チョコレート"))` | 1.40 ms | 1.46 ms | 5 | 30 |
| `(seq (alt (m surface "氏") (m surface "さん")) (not! (m pos ^"助詞,")))` | 2.91 ms | 2.98 ms | 5 | 42 |

## [gloaming] stats

| Stage | best | median | n | notes |
|---|---|---|---|---|
| freq_table (nouns, lemma) | 4.62 ms | 4.90 ms | 3 | 4,467 rows |
| co_occurrence (paragraph, cap 20,000) | 40.17 ms | 44.52 ms | 3 | cap-truncated |
| cooc_presence (marginals) | 6.79 ms | 6.95 ms | 3 | 4,467 keys, 1,671 windows |

## [gloaming] payload (GLB1)

| Stage | best | median | n | notes |
|---|---|---|---|---|
| payload_encode | 2.94 ms | 2.97 ms | 3 | 16.30 B/token |
| payload_compress (DEFLATE, default knee 8) | 42.84 ms | 42.86 ms | 3 | 2.5:1, 1856→734 KB |
| payload_compress (chain 16 ref) | 55.17 ms | 55.46 ms | 3 | 732 KB |
| payload_compress (chain 32 ref) | 79.77 ms | 80.18 ms | 3 | 733 KB |
| payload_decompress | 11.81 ms | 11.82 ms | 3 | |
| payload_decode (entry_ref) | 8.36 ms | 8.65 ms | 3 | 116,557 tokens |

## [gloaming] disk store

| Stage | best | median | n | notes |
|---|---|---|---|---|
| disk add_document | 10.5 ms | — | 3×1 | reps 10.5–11.6 ms across the three runs; registry 519 KB + payloads 1855 KB per rep |
| disk reopen (replay registry) | 1.33 ms | 1.33 ms | 3 | |
| disk tokens (decode) | 9.13 ms | 9.34 ms | 3 | |

## [gloaming] graph (corpus-shaped: 512 entities, 4,500 edges)

| Stage | best | median | n | notes |
|---|---|---|---|---|
| graph_pagerank | 0.40 ms | 0.45 ms | 3 | 512 scores |
| graph_traverse (depth 3) | 0.62 ms | 0.64 ms | 3 | 114 visits |

## ZH arm — jieba × 紅樓夢 (second writing system; 700-KiB prefix)

| Stage | best | median | n | counts |
|---|---|---|---|---|
| load CSV (jieba import) | 1.31 s | 1.37 s | 3 | 584,429 entries, hash 83dd02da8715e4c3 |
| save_qdct zh (once) | 149.3 ms | — | 1 | 100,073,112 bytes |
| restore qdct zh | 96.5 ms | 96.8 ms | 3 | |
| tokenize zh prefix | 44.67 ms | 46.92 ms | 3 | 188,313 morphemes, arena sink |
| adapt (zh prefix, rebased) | 3.17 ms | 3.18 ms | 5 | 59.37 Mtok/s |
| markdown_segments (zh) | 1.12 ms | 1.12 ms | 5 | 105 segments (36 chapters) |
| zh query every noun (pos n) | 5.28 ms | 5.32 ms | 5 | 37,949 |
| zh query person names (pos nr) | 2.44 ms | 2.49 ms | 5 | 9,658 |
| zh query noun gap:0-2 verb | 8.26 ms | 8.66 ms | 5 | 15,285 |
| zh query surface 寶玉 | 2.03 ms | 2.06 ms | 5 | 1,329 |
| zh freq_table (nouns, lemma) | 5.91 ms | 5.94 ms | 3 | 5,764 rows |
| zh co_occurrence (segments, cap 20,000) | 80.70 ms | 88.85 ms | 3 | cap-truncated |

## EN arm — fixture tokenizer × Maria Chapdelaine (id-less schema: entry_id −1, lemma = surface, reading "*", no POS; payload resolver never consulted)

| Stage | best | median | n | counts |
|---|---|---|---|---|
| fixture tokenize [host] | 0.78 ms | 0.80 ms | 3 | 53,959 tokens |
| markdown_segments (en) | 1.08 ms | 1.09 ms | 5 | 798 segments |
| en query surface Maria | 0.95 ms | 1.00 ms | 5 | 202 |
| en query sequence Maria Chapdelaine | 0.94 ms | 1.00 ms | 5 | 5 |
| en query gap in :0-3 the | 1.11 ms | 1.19 ms | 5 | 336 |
| en freq_table (all tokens, surface) | 4.26 ms | 4.38 ms | 3 | 6,415 rows |
| en co_occurrence (segments, cap 20,000) | 22.07 ms | 22.79 ms | 3 | cap-truncated |
| en store_memory add_document | 2.78 ms | 2.78 ms | 3 | fresh store per rep |
| en payload_encode (id-less) | 1.30 ms | 1.32 ms | 3 | 21.00 B/token (string tail carries pos+reading per token; JP entry_ref: 16.30) |
| en payload_compress | 12.49 ms | 12.51 ms | 3 | 5.6:1, 1107→198 KB |
| en payload_decompress | 3.01 ms | 3.19 ms | 3 | |
| en payload_decode (id-less) | 1.14 ms | 1.14 ms | 3 | resolver never called |

Round-trip proof (untimed): compress → decompress restores the blob
byte-identical; decode rebuilds 53,959/53,959 tokens field-identical
with a reject-every-id fixture resolver — a token routed through it
would surface as Not_Found, not silent garbage.

## Band caveat

The three same-session runs behind this record agree on every count
and within 0.5–5% on the compute rows, but the memory-copy rows moved
with the evening's background load: payload_decompress 11.8–18.5 ms,
payload_decode 8.4–16.7 ms, disk tokens 9.1–15.3 ms, store_memory
add_document 9.2–21.4 ms (run 3 was the loaded one). Treat those rows'
bands as wide until a quiet-host re-measure.

## Not covered by this harness

Clustering/coordinates and the glexport exports (the library's
analysis and export surfaces), n-best and proofread enumeration
(correctness-flavored, no harness rows), and fixture-scale behavior
(adapter_tests' domain). Rows are added when the record wants them for
their own sake.
