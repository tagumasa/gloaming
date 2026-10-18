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
| x86 dev box | Ryzen 7 5700U, 8 cores / 16 SMT threads | 15 GiB DDR4-3200 dual-channel, NVMe | Linux (native) | dev-2026-10-nightly `84bc3fc`, `-o:speed` | 2026-10-18 |

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
| load CSV (import) | 0.96 s | 0.98 s | 3 | heap, load+free per rep |
| save_qdct (once) | 66.5 ms | — | 1 | 49 MiB snapshot (51,759,781 B); 66.5–69.7 ms across the two runs |
| restore qdct (startup) | 74.1 ms | 74.7 ms | 3 | via adapter load_analyzer |

## [moli] tokenize (Viterbi, zero options, arena result sink)

| Input | best | median | n | throughput |
|---|---|---|---|---|
| chapter 168,194 B | 24.18 ms | 24.83 ms | 3 | 1.58 Mtok/s |
| novel 511,840 B (3 files) | 73.35 ms | 73.39 ms | 3 | 1.59 Mtok/s |

## [seam] adapter

| Stage | best | median | n | notes |
|---|---|---|---|---|
| adapt (novel, rebased) | 1.78 ms | 1.89 ms | 5 | 65.41 Mtok/s |
| markdown_segments (novel) | 0.72 ms | 0.73 ms | 5 | 1,671 segments |

## [gloaming] memory store

| Stage | best | median | n | notes |
|---|---|---|---|---|
| store_memory add_document | 9.08 ms | 9.20 ms | 3 | whole novel cloned; fresh store per rep |

## [gloaming] queries (library DSL, novel stream)

| Query | best | median | n | matches |
|---|---|---|---|---|
| `(seq (m pos ^"名詞,"))` | 3.45 ms | 3.91 ms | 5 | 32,966 |
| `(seq (m pos ^"名詞,") (m _ :0-2) (m pos ^"動詞,"))` | 6.50 ms | 6.57 ms | 5 | 9,338 |
| `(seq (m pos ^"名詞," :3-8))` | 3.25 ms | 3.31 ms | 5 | 645 |
| `(seq ^ (m surface "諸戸"))` | 0.58 ms | 0.73 ms | 5 | 104 |
| `(seq (m reading "チョコレート"))` | 1.41 ms | 1.48 ms | 5 | 30 |
| `(seq (alt (m surface "氏") (m surface "さん")) (not! (m pos ^"助詞,")))` | 2.73 ms | 2.76 ms | 5 | 42 |

## [gloaming] stats

| Stage | best | median | n | notes |
|---|---|---|---|---|
| freq_table (nouns, lemma) | 3.76 ms | 4.10 ms | 3 | 4,467 rows |
| co_occurrence (paragraph, cap 20,000) | 36.84 ms | 36.85 ms | 3 | cap-truncated |
| cooc_presence (marginals) | 5.59 ms | 5.80 ms | 3 | 4,467 keys, 1,671 windows |

## [gloaming] payload (GLB1)

| Stage | best | median | n | notes |
|---|---|---|---|---|
| payload_encode | 3.13 ms | 3.14 ms | 3 | 16.30 B/token |
| payload_compress (DEFLATE, default knee 8) | 30.49 ms | 30.68 ms | 3 | 2.5:1, 1856→743 KB |
| payload_compress (chain 16 ref) | 41.71 ms | 43.18 ms | 3 | 743 KB |
| payload_compress (chain 32 ref) | 61.78 ms | 65.30 ms | 3 | 747 KB |
| payload_decompress | 11.38 ms | 11.69 ms | 3 | |
| payload_decode (entry_ref) | 8.05 ms | 8.10 ms | 3 | 116,557 tokens |

## [gloaming] disk store

| Stage | best | median | n | notes |
|---|---|---|---|---|
| disk add_document | 10.2 ms | — | 3×1 | reps 10.15–12.59 ms across the two runs; registry 519 KB + payloads 1855 KB per rep |
| disk reopen (replay registry) | 1.39 ms | 1.44 ms | 3 | |
| disk tokens (decode) | 9.99 ms | 10.07 ms | 3 | |
| disk tokens (bounded cache warm) | 6.46 ms | 6.63 ms | 3 | 64 MiB dial, one lump over the payload; the same read as above on the copy-out hit path |
| disk compact | 9.5 ms | — | 1×1 | full-state rewrite + swap, 9.5–10.8 ms across the two runs; bytes unchanged on this history-free store (531,999 B registry, 1,900,126 B payloads) — reclaimed bytes appear only on stores with write history |
| corpus_freq (8 docs, 1 worker) | 117.3 ms | 119.2 ms | 3 | 4,467 rows — the fan-out's serial reference |
| corpus_freq (8 docs, 4 workers) | 64.9 ms | 76.8 ms | 3 | 4,467 rows — identical rows at every width (the identity gate) |
| corpus_cooc (8 docs, 1 worker) | 389.0 ms | 398.7 ms | 3 | 20,000 pairs (cap), serial reference |
| corpus_cooc (8 docs, 4 workers) | 212.4 ms | 227.3 ms | 3 | 20,000 pairs — identical at every width; 184.7–212.4 ms best-to-best across the two runs |

The fan-out rows run the novel as eight documents through the
store-taking corpus passes; the paired runs behind them agree on every
count, and the 4-worker arms are the pair's most host-sensitive rows
(the cooc 4-worker arm is the one the windows disagree on most). The
width ratios read 1.8× freq on both runs and 1.8–2.3× cooc.

## [gloaming] graph (corpus-shaped: 512 entities, 4,500 edges)

| Stage | best | median | n | notes |
|---|---|---|---|---|
| graph_pagerank | 0.41 ms | 0.46 ms | 3 | 512 scores — the iteration is an O(links) scatter; serial by measurement, no dial |
| graph_traverse (depth 3) | 0.64 ms | 0.65 ms | 3 | 114 visits |

## [gloaming] k×k matrix (corpus keys: cluster/coords tail)

The tail after the pair pass. The wide dial builds its own pair table
at a 200,000 cap (the stats row's 20,000-cap table holds only 254
distinct keys) and caps the sorted network at 1,024 keys; the
default-dial rows ride the CLI's top-60 pair slice. All counts
identical across widths.

| Stage | best | median | n | notes |
|---|---|---|---|---|
| weight_distance (cosine, 1,024 keys, 1 worker) | 445.0 ms | 447.8 ms | 3 | serial reference — the O(k³) pair loop |
| weight_distance (cosine, 1,024 keys, 4 workers) | 140.8 ms | 145.5 ms | 3 | 3.2× — lanes own disjoint triangle cells |
| linkage_merges (ward, 1,024 keys, serial) | 335.3 ms | 360.3 ms | 3 | 1,023 merges — serial at any width: the merge loop is irreducibly sequential and the fanned initial build measured within noise of serial (345.9 → 356.9 ms at width 4 on the pre-adoption run), so the dial was not taken |
| power_coords (1,024 keys, tol 1e-12, iter 256, 1 worker) | 460.7 ms | 461.4 ms | 3 | 1,024 coords |
| power_coords (1,024 keys, tol 1e-12, iter 256, 4 workers) | 256.0 ms | 258.6 ms | 3 | 1.8× — one fork-join per axis iteration; the dial engages only above 512 active keys (`POWER_FAN_MIN_M`) |
| weight_distance (top-60 dial, 20 keys) | 0.00 ms | 0.00 ms | 3 | the default dial's whole tail sits at noise |
| linkage_merges (ward, top-60 dial, 20 keys) | 0.02 ms | 0.03 ms | 3 | 19 merges |
| power_coords (top-60 dial, 20 keys) | 0.13 ms | 0.14 ms | 3 | 20 coords — below the floor, serial by design |

The paired runs agree on every count; the width ratios hold within 5%
(weight_distance 3.16–3.33×, power_coords 1.79–1.80×) while the
second run's absolute walls rode up to ~10% high.

## ZH arm — jieba × 紅樓夢 (second writing system; 700-KiB prefix)

| Stage | best | median | n | counts |
|---|---|---|---|---|
| load CSV (jieba import) | 1.08 s | 1.14 s | 3 | 584,429 entries, hash 83dd02da8715e4c3 |
| save_qdct zh (once) | 182.7 ms | — | 1 | 92,590,706 bytes; 182.7–217.1 ms across the two runs |
| restore qdct zh | 101.6 ms | 103.4 ms | 3 | |
| tokenize zh prefix | 45.78 ms | 46.70 ms | 3 | 188,313 morphemes, arena sink |
| adapt (zh prefix, rebased) | 3.28 ms | 3.69 ms | 5 | 57.36 Mtok/s |
| markdown_segments (zh) | 1.18 ms | 1.19 ms | 5 | 105 segments (36 chapters) |
| zh query every noun (pos n) | 3.87 ms | 3.98 ms | 5 | 37,949 |
| zh query person names (pos nr) | 2.13 ms | 2.34 ms | 5 | 9,658 |
| zh query noun gap:0-2 verb | 6.15 ms | 6.47 ms | 5 | 15,285 |
| zh query surface 寶玉 | 1.83 ms | 1.98 ms | 5 | 1,329 |
| zh freq_table (nouns, lemma) | 4.47 ms | 4.49 ms | 3 | 5,764 rows |
| zh co_occurrence (segments, cap 20,000) | 76.28 ms | 76.63 ms | 3 | cap-truncated |

## EN arm — fixture tokenizer × Maria Chapdelaine (id-less schema: entry_id −1, lemma = surface, reading "*", no POS; payload resolver never consulted)

| Stage | best | median | n | counts |
|---|---|---|---|---|
| fixture tokenize [host] | 0.78 ms | 0.80 ms | 3 | 53,959 tokens |
| markdown_segments (en) | 1.06 ms | 1.08 ms | 5 | 798 segments |
| en query surface Maria | 0.67 ms | 0.68 ms | 5 | 202 |
| en query sequence Maria Chapdelaine | 0.66 ms | 0.67 ms | 5 | 5 |
| en query gap in :0-3 the | 0.78 ms | 1.00 ms | 5 | 336 |
| en freq_table (all tokens, surface) | 3.02 ms | 3.15 ms | 3 | 6,415 rows |
| en co_occurrence (segments, cap 20,000) | 20.96 ms | 21.38 ms | 3 | cap-truncated |
| en store_memory add_document | 2.91 ms | 2.93 ms | 3 | fresh store per rep |
| en payload_encode (id-less) | 1.51 ms | 1.85 ms | 3 | 21.00 B/token (string tail carries pos+reading per token; JP entry_ref: 16.30) |
| en payload_compress | 8.45 ms | 8.50 ms | 3 | 5.6:1, 1107→199 KB |
| en payload_decompress | 3.24 ms | 3.58 ms | 3 | |
| en payload_decode (id-less) | 1.13 ms | 1.17 ms | 3 | resolver never called |

Round-trip proof (untimed): compress → decompress restores the blob
byte-identical; decode rebuilds 53,959/53,959 tokens field-identical
with a reject-every-id fixture resolver — a token routed through it
would surface as Not_Found, not silent garbage.

## Band caveat

The paired runs behind this record agree on every count. On the
compute rows they sit within 0.5–5% where the host stayed quiet; this
record's second run rode 5–20% high across the board (background
load), and the pair as a whole sat above the preceding quiet window on
the fan-out and matrix arms — which is why those sections quote the
width ratios as the stable figure. The sub-millisecond rows spread
wider between runs (anchored 0.58/0.69 ms best-to-best,
markdown_segments (novel) 0.72/0.83 ms), and disk add_document reps
span 10.15–12.59 ms across the two runs. en payload_decode reads
1.13–1.17 ms in this record.

## Not covered by this harness

The glexport exports (text interchange over returned data), n-best
and proofread enumeration (correctness-flavored, no harness rows),
and fixture-scale behavior (adapter_tests' domain). Rows are added
when the record wants them for their own sake.
