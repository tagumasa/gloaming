# corpus/ — local-only test data

Nothing under this directory is committed: `corpus/*` is gitignored and
this README is the only tracked file. Local material is linked, copied,
or staged in, never staged-for-commit. Any plain-text or markdown
corpus works; the bench harness (`just bench`) reads whatever is staged
at the paths it guards.

## The development bench

The JP bench corpus is 孤島の鬼 (江戸川乱歩, public domain): staged
from 青空文庫 into `corpus/kotono_oni/` by `scripts/stage_aozora.py`
(`just corpus-ja` needs network access). The stage is the Aozora →
plain-text pass: 底本 header/footer strip, ruby 《…》 and ［＃…］注記
drop, 中見出し → `##` chapter headings — leaving ~173k characters in
48 chapters, split into three part files (~512 KB total).

The shape is the point: large enough to stress the store tiers, small
enough to hold an all-in-memory reference result, which is what makes
the differential test (tiered store vs memory store must return
identical matches) computable at all.

Uses: tiering and payload benchmarks, unknown-word and user-dictionary
work (fiction character names), and entity/graph exercises.

## Public-domain language corpora

Public-domain texts staged for the benches and language arms — 青空文庫
for Japanese (the stage script above), Project Gutenberg for the ZH/EN
arms — carry a `SOURCE.txt` provenance note per corpus directory. PG
credit lines survive the marker strip, and arm loaders skip the leading
credit block.

## Committed fixtures

Committed test data stays synthetic: business-style documents (minutes,
mail), hand-written sentences, and golden DSL → match tables. These live
under `tests/fixtures/`, not here.
