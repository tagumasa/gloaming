# gloaming — CLI reference

The CLI is a one-shot host over the library: resolve project, load
dictionary, run one command, emit, exit. No daemon, by design — the
dictionary snapshot restores in milliseconds, and re-analysis only
happens under `init`/`add`/`variant`. Global flags precede the command;
stdout carries only the result, stderr only diagnostics. `gloaming --help`
prints this reference from the binary itself — the binary's usage text is
the source of truth.

```
usage: gloaming [--project <dir>] [--quiet] [--variant <name>] <command> [args]
```

| Global flag | Meaning |
|---|---|
| `--project <dir>` | project directory (default: the cwd) |
| `--quiet` | suppress diagnostics on stderr |
| `--variant <name>` | answer reads from a variant generation instead of the base |

## A worked session

Every output below is real, from a two-file demo corpus ingested
under moli's committed sample dictionary
(`vendor/moli/tests/fixtures/ipadic_sample.csv` — 23 entries, no
`unk.def`, so unknown handling is visible on purpose). The corpus, so
the byte offsets reproduce exactly:

```
corpus/hanami.md                corpus/kaigi.md
毎年さくらをみる。花見の記録。      会議では毎年のはなの話になる。
わたしは東京の公園を歩く。犬もゆきの中を歩く。    東京の会議。わたしがよむ資料は未登録の言葉。
今日はれきしをよむ。
```

Ingest, then the query engine — the capture `@n` binds the noun the
match starts with; spans are decimal byte ranges:

```sh
$ ./gloaming --project demo init corpus/ --lang ja --dict vendor/moli/tests/fixtures/ipadic_sample.csv
{"command":"init","dict":"886182150f302c5f","variant":null,"truncated":false,
 "rows":[{"docs":2,"bytes":260,"tokens":52,"segments":2,"entries":23}]}

$ ./gloaming --project demo query '(seq (m pos ^"名詞,") @n (m _ :1-3) (m pos ^"動詞,"))' --limit 3
{"command":"query","dict":"886182150f302c5f","variant":null,"truncated":false,"rows":[
 {"doc":0,"start":58,"end":82,"surfaces":["東京","の","公園","を","歩く"],
  "captures":[{"name":"n","start":58,"end":64,"surface":"東京"}]},
 {"doc":0,"start":85,"end":112,"surfaces":["犬","もゆきの","中","を","歩く"],
  "captures":[{"name":"n","start":85,"end":88,"surface":"犬"}]},
 {"doc":1,"start":55,"end":82,"surfaces":["会議","。","わたし","が","よむ"],
  "captures":[{"name":"n","start":55,"end":61,"surface":"会議"}]}]}

$ ./gloaming --project demo kwic '(seq (m lemma "歩く"))' --left 4 --right 1
0:76  東京の公園を 【歩く】 。
0:106  犬もゆきの中を 【歩く】 。

$ ./gloaming --project demo freq --lemma --min-len 2 --limit 4 --format tsv
わたし	2	2
会議	2	1
東京	2	2
歩く	2	1
```

(The JSON lines are wrapped for this page; the binary emits one line
per result. The `dict`/`variant`/`truncated` envelope rides every
JSON result; the `tsv` formats print bare rows.)

Unknown suspects — the sample dictionary has no `unk.def` and no
particle entries, so を and は surface as suspects; the fix is a
variant dictionary, not a re-ingest:

```sh
$ ./gloaming --project demo unknown --limit 2
{"command":"unknown",...,"rows":[{"surface":"。","count":8,"runs":8,
  "first_seen":{"doc":0,"start":24,"end":27},"samples":[]},
 {"surface":"\n","count":5,"runs":5,...}]}

$ printf 'を\t助詞,格助詞,一般,*,*,*\tを\tヲ\nは\t助詞,係助詞,*,*,*,*\tは\tワ\n' > entries.tsv
$ ./gloaming --project demo variant add v2 entries.tsv
{"command":"variant","dict":"44b4f5123146f014","variant":"v2","truncated":false,
 "rows":[{"docs":2,"tokens_before":52,"tokens_after":56,"unknown_before":28,
  "unknown_after":23,"top_surfaces_gained":[{"surface":"は","count":4},{"surface":"を","count":4}]}]}

$ ./gloaming --project demo variant diff base v2 --top 3
{"command":"variant",...,"rows":[{"docs":2,"hash_a":"886182150f302c5f",
  "hash_b":"44b4f5123146f014","tokens_a":52,"tokens_b":56,
  "unknown_rate_a":0.5385,"unknown_rate_b":0.4107,
  "top_shifts":[{"key":"は","a":2,"b":4,"delta":2},{"key":"を","a":2,"b":4,"delta":2},...]}]}

$ ./gloaming --project demo --variant v2 kwic '(seq (m pos ^"助詞,"))' --left 2 --right 1 --limit 3
0:15  毎年さくら 【を】 みる
0:33  。花見 【の】 記録
0:55  \nわたし 【は】 東京
```

Graph curation — entities with aliases, mentions anchored to byte
spans, relations carrying evidence, a coding rule deriving edges from
pattern pairs, and toposort treating a cycle as data (the knows pair
below is deliberately mutual, and 東京 lands in `cyclic` with them
because a visit edge makes it downstream of the cycle):

```sh
$ ./gloaming --project demo entity add person すすむ
{"command":"entity",...,"rows":[{"id":0,"kind":"person","name":"すすむ","aliases":[]}]}
$ ./gloaming --project demo entity add person わたし 私
{"command":"entity",...,"rows":[{"id":1,"kind":"person","name":"わたし","aliases":["私"]}]}
$ ./gloaming --project demo entity add place 東京
{"command":"entity",...,"rows":[{"id":2,"kind":"place","name":"東京","aliases":[]}]}

$ ./gloaming --project demo mention add 1 0:46-55
{"command":"mention",...,"rows":[{"id":0,"entity":1,"entity_name":"わたし","doc":0,"start":46,"end":55}]}

$ ./gloaming --project demo relation add visits わたし 東京 --evidence 0:46-64
{"command":"relation",...,"rows":[{"id":0,"kind":"visits","from":1,"to":2,
  "from_name":"わたし","to_name":"東京","derived":false,"evidence":1}]}

$ ./gloaming --project demo relation add knows わたし すすむ
{"command":"relation",...,"rows":[{"id":1,"kind":"knows","from":1,"to":0,
  "from_name":"わたし","to_name":"すすむ","derived":false,"evidence":0}]}
$ ./gloaming --project demo relation add knows すすむ わたし
{"command":"relation",...,"rows":[{"id":2,"kind":"knows","from":0,"to":1,
  "from_name":"すすむ","to_name":"わたし","derived":false,"evidence":0}]}

$ ./gloaming --project demo codes walks_in わたし 東京 '(seq (m lemma "歩く"))' '(seq (m surface "東京"))' --window 6 --dry-run
{"command":"codes",...,"rows":[{"kind":"walks_in","from":1,"to":2,
  "from_name":"わたし","to_name":"東京","derived":true,"pairs":1,"docs":1,"evidence":2}]}

$ ./gloaming --project demo toposort --format json
{"command":"toposort",...,"cyclic":[{"id":0,"name":"すすむ"},{"id":1,"name":"わたし"},
 {"id":2,"name":"東京"}],"rows":[]}
```

Statistics — external variables cross-tabbed, keyness against the
rest of the corpus, the co-occurrence network clustered and laid out
(`graph`/`cluster`/`coords` emit dot/mermaid/JSON for the host to
render):

```sh
$ ./gloaming --project demo attr set 0 genre 花見
{"command":"attr",...,"rows":[{"doc":0,"key":"genre","val":"花見"}]}
$ ./gloaming --project demo attr set 1 genre 会議
{"command":"attr",...,"rows":[{"doc":1,"key":"genre","val":"会議"}]}

$ ./gloaming --project demo crosstab --attr genre --test
{"command":"crosstab",...,"attr":"genre","columns":["会議","花見"],"sizes":[1,1],
 "table_chi2":26.214087,"rows":[{"key":"を","cells":[0,2],"docs":[0,1],
  "chi2":2.000000,"residuals":[-1.414214,1.414214]},...]}}

$ ./gloaming --project demo keyness --target doc:1 --top 3 --format tsv
#key	value	a	b	c	d
会議	3.186330	2	22	0	28
を	2.544614	0	24	2	26
歩く	2.544614	0	24	2	26

$ ./gloaming --project demo cluster --lemma --min-len 2 --cap 30 --k 2 --top 5 --format tsv
#key	cluster
さくら	0
毎年	0
はれきしをよむ	1
もゆきの	1
わたし	1

$ ./gloaming --project demo coords --lemma --min-len 2 --cap 20 --top 3 --format tsv
#key	x	y
さくら	-0.707107	0.000000
もゆきの	0.353553	0.000000
わたし	0.353553	0.000000
```

The command reference below covers every flag; where it and the
binary's own usage text disagree, the binary wins.



## Project directory

`init` materializes a project directory:

```
<project>/
  manifest.json     schema 1: documents with per-file content hashes
                    (a drifted corpus file refuses on re-read) and the
                    CLI version stamp
  dict.qdct         the base analyzer dictionary snapshot
  store/            the base GLR1 record log + token payloads
  variants/<name>/  immutable variant generations:
                    {dict.qdct, entries.tsv, store}
```

Analyzer-less languages (`en-*`, `de`) ride the fixture tokenizer and
work without any morphological dictionary. Variants are keyed by their
dictionary's content hash: a variant store refuses a payload whose
dictionary disagrees (`.Stale`) rather than silently mis-resolving.

Entry files (`entries.tsv`, one row per user dictionary entry):

```
surface<TAB>pos<TAB>lemma<TAB>reading[<TAB>cost]
```

ids default to 0/0, cost to −3000.

## Commands

### Corpus

```
init <corpus…> --lang <ja|zh-CN|zh-TW|zh-HK|en-GB|en-US|de> [--dict <csv>]
              [--variant-of <project>:<variant>]
status | docs
add <file…> | remove <doc>
```

`init` ingests a corpus directory (recursively) under a language and
dictionary; `--variant-of` promotes an existing variant to a new base,
hash-identical. `status` reports the project state; `docs` lists
documents.

### Query and KWIC

```
query '<dsl>' [--doc D] [--count] [--limit N] [--offset M]
unknown [--min-count N] [--min-len L] [--sample K] [--limit N] [--format tsv]
kwic '<dsl>' [--left N] [--right N] [--center <name>]
      [--sort surface|position] [--limit N] [--offset M] [--format json]
```

`query` runs a [pattern DSL](design.md#the-dsl-scm-style-s-expressions)
over the token stream; `unknown` enumerates unknown-token suspects;
`kwic` extracts center + window concordances.

### Frequency and co-occurrence

```
freq [--pos-prefix P]… [--lemma] [--min-count N] [--min-len L]
     [--stopwords <file>] [--doc D] [--limit N] [--format tsv]
cooc [--pos-prefix P]… [--lemma] [--cap N] [--doc D] [--format tsv]
```

### Variants

```
variant add <name> <entries.tsv> [--cost C]
        | variant list | variant remove <name>
        | variant diff <a> <b> [--top N] [--lemma] [--pos-prefix P]…
```

`variant add` re-tokenizes under the merged dictionary and replays the
graph rows (entities dense-remapped, evidence spans copied exactly).

### Attributes

```
attr set <doc> <key> <value> | attr get <doc> | attr list
```

External variables for cross-tabulation; variant
stores inherit base attrs.

### Graph curation

```
entity add <kind> <name> [alias…] | entity alias <entity> <alias>…
          | entity merge <into> <from> | entity list
relation add <kind> <from> <to> [--evidence <doc>:<s>-<e>]… [--derived]
            | relation list
mention add <entity> <doc>:<start>-<end> | mention list
codes <kind> <from> <to> <patA> <patB> [--window N] [--cap M] [--dry-run]
toposort [--kind K]… [--format tsv|json]
```

Endpoints resolve by name or alias first, then decimal id. `entity
merge` is the tombstone mechanism — re-pointed mentions and relations
land as one committed batch. `relation add --evidence` validates byte
spans against the current text; curated and derived rows on one pair are
separate identities. `codes` is the coding-rule loop: pattern A near
pattern B within `--window` tokens → one derived relation per pair, both
spans as evidence; a capped enumeration refuses the whole write
(partial evidence must not pose as complete), `--dry-run` reports only,
and reruns are idempotent because evidence absorbs as a set.
`toposort` prints the acyclic order; with `--format json` the envelope
carries the cyclic remainder as its `extra` fragment.

### Statistics

```
keyness --target <all|doc:D,…|key=val> [--reference <sel>]
        [--measure M] [--basis docs|tokens] [filter flags…] [--top N] [--format tsv]
crosstab --attr <key> [--test] [filter flags…] [--top N] [--format tsv]
graph [filter flags…] [--window N] [--cap N] [--top N] [--clusters N]
      [--method ward|average|complete] [--distance jaccard|euclid|cosine|dice|simpson]
      [--doc D] [--format dot|mermaid|json]
cluster [filter flags…] [--doc D] [--window N] [--cap N] [--top N]
        [--method ward|average|complete]
        [--distance jaccard|euclid|cosine|dice|simpson]
        [--k N] [--format tsv|json|dot|mermaid]
coords [filter flags…] [--doc D] [--window N] [--cap N] [--top N]
       [--tol F] [--max-iter N] [--format tsv|json|dot]
```

`keyness --reference` defaults to rest (the corpus minus the target).
Measures: `differential lift jaccard ochiai chi2 chi2-yates fisher
dunning` (default `dunning`); basis `docs|tokens`. `crosstab --test`
adds standardized residuals and the χ².

The three network commands (`graph`, `cluster`, `coords`) share one
front: `--window` (default 5) is the co-occurrence window, `--cap`
(default 20000) the enumeration safety bound, and `--top` (default
60) how many ranked pairs form the network. `--top` bounds pairs, not
output rows — a pair-count slice that changes which words are in the
network at all, hence the clustering and the coordinates — and a
truncation past it or the cap says so on stderr.

`graph` emits the word
co-occurrence network as dot, mermaid, or JSON; `--clusters k` colors
the nodes by cutting the merge tree over the same network, so the
picture and `cluster --k k` agree on the labels (coloring is a
dot/mermaid rendering — `--clusters` with `--format json` is a usage
error).

`cluster` cuts the same network's merge tree: one of the five
distances, then `ward` (default), `average`, or `complete` linkage.
Without `--k` it prints the merge rows (`a`/`b` are cluster ids —
leaves `0..n−1`, merge *s* is `n+s`); `--k` cuts the tree into word →
cluster rows; `--format dot|mermaid` draws the dendrogram — with
`--k` a forest of k trees — through Graphviz (`… | dot -Tsvg`).
`coords` lays the network out by power iteration (defaults `--tol
1e-12 --max-iter 256`); `--format dot` pins every word at its (x, y)
for neato (`… | neato -Tsvg` — dot would ignore the pins, and
mermaid cannot pin positions, so those forms do not exist).

## Conventions

`--doc` accepts a document id or a unique path suffix. Evidence spans
(`<doc>:<start>-<end>`) are decimal byte ranges. JSON output rows ride
the provenance envelope — `{command, dict hash, variant, truncated}`
plus command-specific `extra` fragments (crosstab columns/sizes/χ²,
keyness measure/basis/populations, the toposort cyclic remainder,
cluster method/distance/k, coords tol/max_iter).

Exit codes: `0` ok, `1` usage, `2` pattern, `3` analysis refusal,
`4` project/IO.
