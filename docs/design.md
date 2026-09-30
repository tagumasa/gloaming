# gloaming — design

gloaming is a document-intelligence library: a pattern-query engine, an
evidence-bearing document graph, and corpus statistics, all over annotated
token sequences (`[]Token`). It is the middle layer between morphological
analysis and the applications that embed it — deterministic, core-only, and
safe for concurrent embedding. [moli](#the-moli-adapter) is the Japanese
morphological analyzer it was developed against; the library itself is
analyzer-agnostic.

## Layer architecture

```
moli — morphological analysis (Japanese; MeCab-parity)
  │   []moli.Morpheme → []gloaming.Token   (the adapter)
  ▼
gloaming — this library
  │   query (sequence patterns, KWIC)  graph (entities, relations, coding)
  │   stats (frequencies → measures → clustering/coordinates)
  │   store ports (memory / disk: GLR1 record log + binary payloads)
  ▼
host application — whatever embeds gloaming; the first host is the
  standalone CLI (see cli.md). It owns rendering, tools, indexes, and
  curation UX, and — where it has one — a document-outline layer;
  otherwise chapters/paragraphs arrive as caller-supplied segments
```

Rules:

- gloaming core is pure foundation: `core:*` only; no `os`/`thread` on
  analysis paths. Disk backends are host-selected behind port procedures
  (`core:os` appears in store_disk and nowhere else).
- No FFI anywhere in this repository: no `foreign` declarations, no C
  sources (vendored or linked), nothing that makes the build need a C
  toolchain. Pure-Odin external packages are fine — the moli adapter is
  the standing example.
- gloaming never imports moli. The host adapts morphemes into `[]Token`.
- The application surface — UI, protocols, tools — is the host's, not
  gloaming's. gloaming returns data; hosts render, cap, and stream it.
- The auxiliary `glexport` package (src/glexport, outside the library
  body) serializes dot/mermaid/JSON text over returned data for hosts
  that want interchange.

## Scope

**In scope:**

- scm-style S-expression pattern DSL over token fields (surface, lemma,
  pos, reading, the unknown flag), with quantifiers, captures,
  alternation, negation, anchors
- Synonym expansion over lemma groups (`~"見る"`) and typo-tolerant
  fuzzy matching (`(fuzzy "x" :n)`)
- Proofreading suspects: segment cost anomalies, unknown-run lengths,
  notation-variation enumeration
- Sequence matcher with cursor streaming; KWIC context extraction
- Compounding views — pattern-driven resegmentation (adjacent-word
  compounding, generalized: any matched span can be projected to one unit)
- Document graph: entities, relations, mentions, all with evidence spans;
  derived edges (coding rules) and curated edges in one mechanism
- Corpus statistics: frequency tables with filters, association measures,
  co-occurrence construction, Ward clustering, top-k dimensionality,
  centrality — pure `core:math`
- Store ports with two backends: all-in-memory, and disk (a GLR1
  append-only record log + append-only binary payloads — pure Odin, no
  FFI)

**Out of scope:**

- Morphological analysis (moli's job)
- Dependency-parse trees (the step model reserves a `depth`
  field so tree-shaped extensions stay possible; nothing more)
- NER as a brain: mentions arrive from rules (patterns), dictionaries,
  or host judgment — gloaming stores and queries them, it does not
  invent them
- General graph database: no SPARQL/Cypher, bounded traversal only
- Visualization rendering: hosts draw from the adjacency, centrality, and
  coordinate tables gloaming returns
- Stochastic models — LDA topic modeling, SOM training, auto term
  extraction: hosts; every gloaming measure is exact and deterministic
- Document classification (Naive Bayes) and community detection / MST on
  the word network — not built; the count tables they would train or
  rank on exist
- Multi-language taggers — one adapter per language (moli is the ja
  adapter); the core's `Token` stays analyzer-agnostic
- SQL, plugins, PDF/Office import — the host application's stack

## The DSL (scm-style S-expressions)

The compiled form (steps) is the contract; the S-expression front-end is
its surface.

```
;; lemma 走る as a verb, 0–2 anything, then a common noun captured as @obj
(seq (m lemma "走る" pos ^"動詞,") (m _ :0-2) (m pos ^"名詞,一般,") @obj)

;; any of a set, negated step, anchored at segment start
(seq ^ (alt (m surface "氏") (m surface "さん")) (not (m pos ^"助詞,")))

;; host regex through an injected predicate (the engine lives in the host)
(seq (m reading %"シス.*"))

```

The top level must be a `(seq …)` — a bare `(m …)` is not a pattern.

| Element | Meaning |
|---|---|
| `(m field value ...)` | one-token step; predicates ANDed |
| `_` | wildcard value |
| bare `"x"` | equality |
| `^"x"` | prefix (POS hierarchy: `^"名詞,"` matches `名詞,一般,…`) |
| `$"x"` | suffix |
| `%"x"` | host-injected custom predicate (e.g. regex), by name |
| `(any "a" "b")` | set membership |
| `~"x"` | synonym expansion: lemma predicate widened through the lemma-group table (compiles to set) |
| `(fuzzy "x" :n)` | edit-distance match within n — the typo-tolerant form |
| `:n` `:n-m` `:?` `:*` `:+` | quantifier on the preceding step |
| `@name` | capture binding |
| `(alt ...)` | alternation |
| `(not ...)` | negated step (consumes one non-matching token) |
| `(not! ...)` | zero-width negative lookahead — the "not followed by" form |
| `^` / `$` statement-level | stream (or segment) start/end anchors |

## Pattern model (compiled form)

- `Query`: named steps + capture definitions. A step's body is a tagged
  union — the ANDed predicate list, or the alternation branches
  (`alt`) whose branching the matcher manages — alongside a quantifier
  (`min..max`, −1 = unbounded), a capture index, a negation flag, and a
  `depth` field reserved for tree-shaped extensions (sibling matching
  is depth 0).
- Predicates are data: one union variant per match form
  (`eq`/`prefix`/`suffix`/`set`/`fuzzy`/`custom`, plus the value-less
  `unknown` flag test), each variant owning exactly the fields it
  reads. `custom` is an injected `proc(^Token, rawptr) -> bool` — regex
  support lives in the host, so the core stays dependency-free (a
  host-side engine — a pure-Odin regex port, for instance — plugs in
  behind `%"…"` with zero core changes). `~`-marked lemma predicates
  compile to `set` through the lemma-group table; a compiled set —
  from `~` or `(any …)` — holds at most `ANY_EQ_MAX` members, sorted
  ascending at parse so membership is a binary search;
  `fuzzy` carries a max edit distance.
- The matcher is backtracking with a (step, position) memo; its
  continuation chain is an index-linked stack owned by the cursor —
  no pointer-linked structures in the engine. A tagged-NFA
  engine remains a measured upgrade path but is unscheduled: no measured
  need has appeared.
- Iteration is cursor-shaped (`next_match`), results on the caller's
  arena; long CPU loops take an injected stop-check (the API discipline
  below, applied everywhere it binds).

## Graph model

- `Entity` (id, kind, canonical name, aliases), `Relation` (kind, from,
  to, evidence spans, `derived` flag), `Mention` (entity, span). Kinds
  are host-open vocabulary, interned per graph: the `Doc_Graph` owns one
  cloned string per distinct kind with dense `Kind_Id`s, rows carry the
  id, hosts read the string back by index. GLR1 records carry the kind
  string (a record is self-describing full state); interning runs at
  apply, in record order, so a replayed graph numbers kinds exactly
  like the graph that wrote the log. The whole-graph passes intern the
  host's `kinds` filter once per pass and compare ids per relation.
- Curated edges (the host's curator — human or automated — judging
  "these two mentions are the same character") and derived edges (coding
  rules: pattern A near pattern B within window W → code C) share one
  mechanism; `derived` is the only difference. Both carry evidence spans
  back into the text.
- Coding rules are two queries plus a window: `graph_code_pairs`
  enumerates match pairs within `window` tokens (either order, distance
  max(0, later.start − earlier.end), identical spans skipped) with a
  two-pointer sweep over the engines' non-overlapping match lists;
  endpoints are the host's loop.
- Write API: merge/alias are record-store transactions (one committed
  batch — see Storage). Traversal is bounded (max depth, max frontier,
  visible `truncated` flag); no unbounded graph walks.
- `graph_toposort` is Kahn's algorithm over directed from → to rows,
  kinds filtered like the other whole-graph passes. A cycle is data, not
  an error: `order` is the acyclic prefix and `cyclic` the remainder
  (cycle members plus everything downstream), ascending, deterministic
  by row order.
- `Doc_Attr`: external variables for cross-tabulation.

## Statistics

All `core:math`, all returning data (tables, coordinates, trees) — never
rendered images:

- Frequency vectors under `Freq_Filter` (POS prefixes, stopwords, min
  count, lemma-vs-surface counting, min rune length)
- Association measures: Jaccard, Dice, mutual information, chi-square,
  Yates-corrected chi-square, log-likelihood G², Simpson, Fisher exact
  (log-gamma) — one shared 2×2 core (`cont_2x2`)
- Co-occurrence graph construction over segment windows (sentence /
  paragraph / chapter / N tokens), binary co-presence per window, with
  presence marginals (`cooc_presence`) so pairs and marginals describe
  one population and every 2×2 contingency is consistent
- Ward hierarchical clustering (Lance–Williams over squared
  dissimilarities, binary heap with lazy invalidation) plus
  average/complete linkage over the same machinery, and the k-cut over
  any merge tree (`cluster_labels` — union-find over the first n−k
  merges, components ranked by smallest member leaf)
- Top-k dimensionality via power iteration on contingency tables — the
  correspondence-analysis stand-in; classical-MDS coordinates the same
  way. No full SVD.
- PageRank / centrality for the graph engine: distinct targets,
  self-loops skipped, dangling mass redistributed, sum exactly 1
- Corpus tables: true per-document counts (`Freq_Entry.docs`), document
  profiles, tf/tf-idf, document weights and distances
- Keyness — target vs reference, one 2×2 per key
- `Doc_Attr` cross-tab reads (graph_doc_attrs → doc_groups →
  cross_table → cross_chi2) with standardized residuals
- KWIC collocation — neighbor tables over the association engine

## Synonyms and proofreading

Division of labor first: the deterministic side enumerates suspects, the
host (and its human) judges. The enumeration is library territory for a
reason worth recording: curators — human or automated — overlook
notation variation and near-synonyms, and host judgment is not
reproducible — what runs on every query and every corpus pass must
not depend on it.

- **Synonym expansion** — `~"見る"` compiles to a set predicate over the
  lemma-group table; zero new matcher machinery. Data sources: a user
  TSV (one group per line; fiction authors curate character vocabulary
  with it) and — always available — a host writing the expanded set
  literally. Homophone pulling
  (same reading, different-kanji words) comes nearly free from the reading field.
  The set path's one bound applies wherever the members came from: a
  compiled set holds at most 64 members (`ANY_EQ_MAX`, the `(any …)`
  cap) — an oversized group refuses with a typed error, never a
  silently narrowed or unbounded set; the group table itself is
  unbounded data, and a host facing the refusal can split the query.
- **Fuzzy predicates** — `(fuzzy "少ない" :n)` matches within edit
  distance n (bounded-band bit-parallel Myers). This is what makes typos
  themselves searchable: an unknown token within distance 1–2 of a
  lexicon entry is a misspelling candidate.
- **Cost anomalies** — `Token.cost` sums per segment; spikes, together
  with unknown-run lengths, are the classical first-pass suspects for
  typos and omissions.
- **Notation variation** — corpus-wide: group by (reading,
  POS) and enumerate groups where lemmas diverge; a canonical-form
  table decides which form wins.
- **Lint rules** — doubled particles, comma run-on
  length, and kin are pattern queries and segment statistics: a lint pack
  is a collection of queries, not a separate engine.

Honest limit: omissions proper are not deterministically detectable
without a language model (a sentence with a word missing is still a
well-formed token stream). The division above is the answer to that
limit, not a denial of it.

## Storage — three tiers

What explodes is not the graph (hundreds of entities per book) but the
token payloads (~250k characters ≈ 160k morphemes) and, at corpus scale, the
postings. The tier split separates the derived index (L1) from the
immutable payloads (L2) from the hot working set (L3):

| Tier | Contents | Shape |
|---|---|---|
| L1 | postings: lemma/reading → (doc, span); entity → mentions; relation → edges | GLR1 record log, indexes rebuilt in memory at open |
| L2 | tokenized payloads per document version | append-only binary blobs, mmap-friendly |
| L3 | hot token windows + traversal frontier | `Bounded_Cache` |

The mutability split:

- **Immutable → binary.** Tokenization is a pure function of (text,
  dictionary, options), so payloads are keyed by
  `Payload_Key{text_hash, dict_version, options}` — `dict_version` is
  the dictionary's content hash (load-path independent; every
  user-entry merge changes it), so adding one entry invalidates every
  payload it should. Edits append a new payload; garbage collection
  drops versions no document references. The GLB1 format: magic `GLB1`,
  a 48-byte header, then 16-byte records `{entry_ref, start, end,
  meta}` — ~17 B/token at novel scale. Strings are not stored;
  `entry_ref` resolves pos/lemma/reading through the already-loaded (or
  mmap'd) dictionary, with unknown pos strings inlined in a
  length-prefixed tail. Version 2 adds the id-less-known record (meta
  bit 17, `entry_ref` −1, pos and reading in the tail, lemma = surface)
  so synthesized tokens (compound merges) round-trip without claiming a
  dictionary row. DEFLATE (`src/gloaming/deflate.odin`, encode-only)
  compresses blobs for *distribution only* (~2.6:1 measured); the mmap
  path stays uncompressed.
- **Mutable → GLR1.** Entities, relations, mentions, doc attrs, and the
  derived postings live in an append-only record log of hash-checked
  frames grouped into committed batches; indexes are rebuilt in memory
  at open, and a batch commit (write + sync) is the transaction an
  entity merge needs. Postings are derived data — recomputed from
  payloads at open, never persisted: the store holds whole corpora in
  memory by design, so an on-disk index engine would be the expensive
  way to answer questions the rebuilt maps answer faster.
- Store is a port: `memory` (single document, and the differential-test
  reference) and `disk` (store_disk: GLR1 registry + payloads.glb) are
  interchangeable — the differential harness runs the same corpus
  through both and requires zero difference; torn registry tails are
  repaired at reopen. `Store_Err.Stale` is the built-in decode-refusal:
  a payload whose `dict_version` disagrees with the dictionary the
  store was opened with answers Stale before decoding, so the
  silent-wrong-resolution hazard (renumbered ids after a merge) is the
  store's job, not each host's.

Graph rows over the log: full-state rows — append is `id == len`,
rewrite is the same id again, dead rows keep their slot as tombstones.
The `graph_apply_*` procs are the single mutation path: the disk
writers serialize a row to a GLR1 record, commit the batch, then apply,
so memory never runs ahead of the log, and the rebuild at open replays
the same records through the same applies. `graph_entity_merge` lands
its whole plan — re-pointed mentions, re-pointed relations (self-loops
die, identity collisions fold evidence into the lower id), the name
re-map, the tombstone — as one batch, so a torn merge repairs to the
pre-merge state. `graph_relation_add` upserts on (kind, from, to,
derived); evidence absorbs as a set — a span the row already holds is
not repeated, so re-running a rule or re-citing a passage is
idempotent.

## API discipline

- Cursor streaming everywhere; a request's matches live on its arena and
  die with it.
- The caller sizes the request arena for the whole request — parse,
  cursor, and results together — and an under-sized arena is silent:
  in Odin's non-debug runtime an exhausted allocator makes `make`
  return empty collections and drops `append`s without an error, so
  the failure surfaces as wrong results (an empty table, a phantom
  count), never a typed refusal. The library cannot detect this from
  inside; the sizing rule is the host's contract.
- Caps are caller dials with visible flags: match lists take a mandatory
  limit and return `truncated`; the cursor streams the complete set;
  count tables (`freq_table` and its kin) return complete,
  deterministically sorted rows — hosts slice top-k themselves.
- Every pass whose cost scales with corpus size or n² — queries,
  statistics, corpus aggregation, clustering, traversal, store-open
  replay — polls an optional trailing stop-check (`check`/`user`); a
  poll firing (true = stop) returns a typed `.Interrupted` with scratch
  freed. Pure transforms over caller-dimensioned inputs (the word-key
  matrix builders in stats) carry no check: their cost is a dimension
  the caller chose.
- Every cache is bounded. Long-lived map keys are cloned on insert —
  keys own their bytes, never alias caller memory.
- A refusal allocates nothing net: parse and loader errors free their
  scratch before returning, so the parse-arena contract is a
  convenience, not a leak requirement. The strings a parsed `Query`
  holds live in one pool block the result carries.
- No process globals; state is passed explicitly.
- Concurrency: the library never locks — exclusion is the host's, type
  by type. A parsed `Query` (and `Lemma_Groups`) is immutable and
  serves concurrent cursors/lookups; the store and `Doc_Graph` are
  single-writer under host-side exclusion; stats and glexport are
  call-scoped.

## Workflow coverage

| Workflow feature | gloaming |
|---|---|
| Search (KWIC, POS-constrained, regex) | `query` + KWIC output shape (center + N-token windows, sort keys) |
| Frequency table with extraction filters | `Freq_Filter` parameter struct; lemma counting |
| Heading-scoped subcorpora (H1/H2/H3) | caller-supplied `Segment`s from the host outline layer |
| Compounding | compounding views: matched spans projected to single units |
| Coding | coding rules → derived graph edges with evidence |
| External variables | `Doc_Attr` (storage, write path, cross-tab reads) |
| Co-occurrence + Jaccard/MI/χ² | graph construction operator + measures |
| Co-occurrence network | adjacency + centrality — hosts render (dot/mermaid text via glexport, nodes colored by cluster labels) |
| Correspondence analysis / MDS | top-k power-iteration coordinates (a pinned-pos neato scatter via glexport) |
| Ward clustering | merge-order tree + k-cut labels (dot/mermaid tree text via glexport) |
| Keyness / characteristic words | keyness — group comparison, one 2×2 per key |
| Cross / simple tabulation | cross-tab reads over `Doc_Attr` |
| Corpus-wide tables, document clustering/MDS | corpus tables, tf-idf, doc distances |
| Search-word co-occurrence statistics | KWIC neighbor tables over the assoc engine |
| PDF/Office import, GUI | not here — the host application's import/UI stack |

## Testing

- **Committed fixtures**: synthetic business documents (minutes/mail
  style) + hand-written sentences + a golden table of DSL → expected
  matches (`tests/fixtures/query_golden.txt`).
- **Un-committed corpus**: `corpus/` is gitignored except its README.
  The development bench is 孤島の鬼 (江戸川乱歩, public domain): staged
  from 青空文庫 by scripts/stage_aozora.py (`just corpus-ja`) —
  ~173k characters, 48 chapters in three part files. Large enough to
  stress tiers, small enough to hold an all-in-memory reference — so
  the differential test ("tiered store must return exactly what the
  memory store returns") is actually computable.
- **Discipline**: `ODIN_TEST_THREADS=1`; verdicts from the log, never
  the exit status alone; zero leak lines as the gate (see the justfile).
  The full suite is the verdict — never a single-test `-define` build.
- **Quantitative record**: `just bench` (bench/, over the same
  un-committed corpus) measures the whole pipeline stage by stage —
  dictionary load, tokenize, the adapter seam, store/query/stats/
  payload/disk/graph — each tagged moli / seam / gloaming so a moved
  number attributes to a tree; docs/benchmarks.md is the committed
  baseline, re-measured and replaced in place when the baseline moves.
- **Toolchain**: the Odin nightly. Every gate is re-run and re-pinned
  after any compiler update.

## The moli adapter

Implemented as `adapter_src/moli_adapter`: the bridge package imports
gloaming and moli both — the core never imports moli, and the adapter
lives outside src/ for that reason. Hosts and the bench consume it, so
the Morpheme → Token contract has one source of truth.

The conversion is a field copy plus one mapping: `surface` stays a view
into the source text; `cost` carries over; and moli's
is_unknown/entry_id pair becomes `Token_Kind` — `.Dictionary` (the
`entry_id` dictionary row carries over), `.Idless` (a row-less known
morpheme), or `.Unknown`. moli guarantees lemma is never `"*"` (a
dictionary `"*"` falls back to the surface) and unknown morphemes
carry surface as lemma with reading `"*"` — so lemma counting needs no
adapter fix-up. Readings are
katakana for word morphemes, but symbol entries carry their own surface
as the reading (、 reads 、 — the ipadic convention), and hiragana query
folding is a host utility; `pos` is one comma-joined string, hence the
`^"名詞,"` prefix convention. The package also carries the
dictionary-snapshot loading policy (restore-fast, import-and-save
otherwise), the dictionary content hash behind
`Payload_Key.dict_version`, and `variant_analyzer` for user
dictionaries (clone-then-merge — the base's ids and hash stay
untouched).

One rule hosts must know: the analyzer sends its lattice through the
result allocator, so the allocator choice moves cost, never output —
the bench rides a `mem.Arena` reset around every tokenize; counts are
identical either way.
