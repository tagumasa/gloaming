#!/usr/bin/env python3
"""Stage the JP bench corpus (孤島の鬼, 江戸川乱歩) from 青空文庫.

The development bench reads a public-domain Japanese novel at
corpus/kotono_oni/{1,2,3}.md (bench/main.odin REAL_FILES). This
script fetches 図書カード 57849 (新字新仮名 ruby
edition), strips the Aozora markup down to plain markdown, and splits
the chapter sequence into part files at byte-nearest chapter
boundaries — a corpus shape comparable to the tiers the store benches
stress. Everything it drops or rewrites is listed in the SOURCE.txt it
writes beside the files; corpus/README.md carries the reproducibility
note.

Stdlib only, deterministic: no timestamps or tool versions inside the
staged text itself. Fails loudly (assert) on any markup shape it does
not recognize — a changed upstream file wants human eyes, not silent
mis-staging.

Staging rules:
  header    everything through the second dashed rule (title, author,
            the 記号説明 block) is dropped;
  footer    everything from the first 底本： line on is dropped;
  見出し     ［＃１字下げ］T［＃「T」は中見出し］ becomes a '## T'
            heading line — markdown_segments reads '#' lines as
            chapters;
  ruby      《…》 readings and the ｜ start marker are dropped (base
            text keeps);
  注記      ［＃…］ notes (indent, 傍点, gaiji) are dropped, a ※
            directly prefixed to one goes with it;
  lines     each original non-empty line becomes its own paragraph
            block (blank line after) with leading indent stripped —
            the adapter's outline treats blank-line-separated runs as
            one paragraph, and in an Aozora text every line is one
            paragraph.
"""

import argparse
import io
import pathlib
import re
import sys
import urllib.request
import zipfile

CARD_URL = "https://www.aozora.gr.jp/cards/001779/files/57849_ruby_71883.zip"
TITLE = "孤島の鬼"
PART_NAMES = ["一", "二", "三", "四", "五"]

DASH_RULE = re.compile(r"^-{20,}$")
# a chapter title may itself carry quotes and ruby (「弥陀《みだ》の利益」),
# so both spans match lazily between their fixed markers
MIDASHI = re.compile(r"［＃１字下げ］\s*(.*?)\s*［＃「.*?」は中見出し］", re.S)
RUBY = re.compile(r"《[^》]*》")
NOTE = re.compile(r"※?［＃[^］]*］")
RUBY_MARK = "｜"


def fetch_zip(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def stage(text: str) -> tuple[list[str], dict]:
    """Strip Aozora markup; return (staged lines, drop counts)."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")

    rules = [i for i, l in enumerate(lines) if DASH_RULE.match(l.strip())]
    assert len(rules) >= 2, f"expected a 記号説明 block, dash rules at {rules[:4]}"
    body_start = rules[1] + 1
    footers = [i for i, l in enumerate(lines) if l.startswith("底本")]
    assert footers and footers[0] > body_start, "no 底本 footer found"
    body = lines[body_start:footers[0]]
    dropped_head_foot = sum(len(l) for l in lines[:body_start] + lines[footers[0]:])

    body_text = "\n".join(body)
    n_midashi = body_text.count("は中見出し］")
    body_text, n_head = MIDASHI.subn(r"\n## \1\n", body_text)
    assert n_head == n_midashi, f"{n_midashi - n_head} 中見出し not paired with １字下げ"

    n_ruby = len(RUBY.findall(body_text))
    body_text = RUBY.sub("", body_text)
    n_mark = body_text.count(RUBY_MARK)
    body_text = body_text.replace(RUBY_MARK, "")
    n_note = len(NOTE.findall(body_text))
    body_text = NOTE.sub("", body_text)
    assert "《" not in body_text and "［＃" not in body_text, "markup survived staging"
    assert "※" not in body_text, "a bare ※ survived staging"

    out = [l.strip("　 \t") for l in body_text.split("\n")]
    out = [l for l in out if l]
    counts = {
        "header_footer_chars": dropped_head_foot,
        "headings": n_head,
        "ruby": n_ruby,
        "ruby_marks": n_mark,
        "notes": n_note,
    }
    return out, counts


def split_parts(lines: list[str], parts: int) -> list[list[str]]:
    """Split at '## ' chapter boundaries into parts of near-equal bytes."""
    bounds = [i for i, l in enumerate(lines) if l.startswith("## ")]
    assert bounds and bounds[0] == 0, "staged text must open with a heading"
    bounds = bounds + [len(lines)]
    cum = [0]  # cum[i] = bytes through the end of section i-1
    for i in range(1, len(bounds)):
        sec = lines[bounds[i - 1]:bounds[i]]
        cum.append(cum[-1] + sum(len(l) + 2 for l in sec))
    total = cum[-1]
    # boundary k lands on the section end whose cumulative bytes sit
    # nearest k/parts of the whole; each part keeps at least one section
    closes = [0]
    for k in range(1, parts):
        target = k * total / parts
        i = min(range(1, len(cum)), key=lambda j: abs(cum[j] - target))
        closes.append(max(i, closes[-1] + 1))
    closes.append(len(cum) - 1)
    assert len(set(closes)) == parts + 1, "split boundaries collapsed"
    return [lines[bounds[closes[k]]:bounds[closes[k + 1]]] for k in range(parts)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("outdir", nargs="?", default="corpus/kotono_oni",
                    help="output directory (default corpus/kotono_oni)")
    ap.add_argument("--zip", help="local ruby-text zip (default: fetch the card)")
    ap.add_argument("--parts", type=int, default=3, choices=range(1, 6),
                    help="number of part files (default 3)")
    args = ap.parse_args()

    data = open(args.zip, "rb").read() if args.zip else fetch_zip(CARD_URL)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if n.endswith(".txt")]
        assert len(names) == 1, f"expected one .txt in the zip, got {names}"
        raw = z.read(names[0])
    text = raw.decode("cp932")  # strict: an undecodable byte wants eyes

    lines, counts = stage(text)
    parts = split_parts(lines, args.parts)

    outdir = pathlib.Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    for i, part in enumerate(parts):
        head = f"# {TITLE}（{PART_NAMES[i]}）"
        body = "\n\n".join(part)
        (outdir / f"{i + 1}.md").write_text(head + "\n\n" + body + "\n",
                                           encoding="utf-8", newline="\n")

    src = "\n".join([
        f"source: 青空文庫 図書カード57849（{TITLE}, 江戸川乱歩, 新字新仮名）",
        "fetch:   " + CARD_URL,
        "staged:  scripts/stage_aozora.py — header/footer strip (記号説明 block,",
        "         底本 footer), 中見出し → '##' headings, ruby 《…》/｜ drop,",
        "         ［＃…］注記 drop, one paragraph block per source line",
        f"shape:   {counts['headings']} chapters → {args.parts} part files,",
        f"         {counts['ruby']} ruby + {counts['ruby_marks']} ｜ + {counts['notes']} notes dropped,",
        f"         {counts['header_footer_chars']} header/footer chars dropped",
    ]) + "\n"
    (outdir / "SOURCE.txt").write_text(src, encoding="utf-8", newline="\n")

    sizes = [(outdir / f"{i + 1}.md").stat().st_size for i in range(args.parts)]
    print(f"staged {TITLE}: {counts['headings']} chapters, "
          f"{sum(sizes)} B in {args.parts} files {sizes}")
    print(f"lines: {len(lines)}; {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
