# gloaming build tasks. The library lives in src/ (package gloaming);
# the test suite is a separate package in tests/ that imports it through
# the collection below.

# Show available tasks
default:
    @just --list

# Type-check the library package and the glexport auxiliary package
# (text interchange, outside the library body) with vet and strict
# style. (tests/ is not checked here: core:testing only exists in test
# builds, which is what `just test` compiles.)
check:
    odin check src/gloaming -vet -strict-style -no-entry-point
    odin check src/glexport -collection:gloaming=src -vet -strict-style -no-entry-point

# Type-check the moli adapter package (lives outside src/ because
# the core never imports moli). Requires the vendored moli submodule.
check-adapter:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d vendor/moli/src/moli ]; then
        echo 'SKIP: vendor/moli not initialized (git submodule update --init)'
        exit 0
    fi
    odin check adapter_src/moli_adapter -collection:gloaming=src \
        -collection:moli=vendor/moli/src -vet -strict-style -no-entry-point

# Type-check the CLI host package (links the adapter, so it needs
# the submodule too).
check-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d vendor/moli/src/moli ]; then
        echo 'SKIP: vendor/moli not initialized (the CLI links the adapter)'
        exit 0
    fi
    odin check cli -collection:gloaming=src -collection:moli=vendor/moli/src \
        -collection:gladapter=adapter_src -vet -strict-style

# Build the CLI host binary to ./gloaming (one-shot, no daemon).
cli:
    #!/usr/bin/env bash
    set -euo pipefail
    odin build cli -collection:gloaming=src -collection:moli=vendor/moli/src \
        -collection:gladapter=adapter_src -o:speed -out:gloaming
    echo 'built ./gloaming'

# Run the adapter tests (moli's committed fixture dictionary — the real
# dict and corpus stay bench-side). Same log discipline as `test`:
# verdicts from the log, zero error/warn/leak lines.
test-adapter:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d vendor/moli/src/moli ]; then
        echo 'SKIP: vendor/moli not initialized (adapter tests need the submodule)'
        exit 0
    fi
    mkdir -p tmp
    odin test adapter_tests -collection:gloaming=src -collection:moli=vendor/moli/src \
        -collection:gladapter=adapter_src -define:ODIN_TEST_THREADS=1 2>&1 | tee tmp/adapter-test.log
    pattern='\[ERROR\]|\[FATAL\]|\[WARN \]|\[WARN\]|\+\+\+ leak|bad free|out of range'
    if grep -a -q -E "$pattern" tmp/adapter-test.log; then
        grep -a -E "$pattern" tmp/adapter-test.log
        echo 'FAIL: errors or leak blocks in the adapter test log (above)'
        exit 1
    fi

# Stage the public-domain JP bench corpus (孤島の鬼, 江戸川乱歩) from
# 青空文庫 into corpus/kotono_oni/ (gitignored like every corpus) —
# scripts/stage_aozora.py fetches, strips the Aozora markup, and splits
# the chapters into the three part files bench/ reads. The ZH
# and EN arm corpora stay hand-staged from Project Gutenberg per their
# SOURCE.txt files. Needs network access.
corpus-ja:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f corpus/kotono_oni/1.md ]; then
        echo 'corpus/kotono_oni already staged (rm it to re-stage)'
        exit 0
    fi
    python3 scripts/stage_aozora.py

# Run the quantitative benchmark (bench/ over the real corpus; the
# committed record is docs/benchmarks.md, curated by hand from this log).
# The provenance block carries the facts a number is meaningless
# without: date, toolchain, and both trees' HEADs (a moved number
# attributes to a side — moli, the adapter seam, or gloaming — per
# docs/benchmarks.md). Skip-guarded: an uninitialized submodule and a
# missing staged corpus (the corpus stays a dev-machine fact).
bench:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d vendor/moli/src/moli ] || [ ! -f corpus/kotono_oni/1.md ]; then
        echo 'SKIP: bench needs vendor/moli (git submodule update --init) and the staged corpus (just corpus-ja)'
        exit 0
    fi
    mkdir -p tmp
    {
        echo "date:     $(date -Is)"
        echo "odin:     $(odin version)"
        echo "gloaming: $(git rev-parse --short HEAD)$( [ -n "$(git status --porcelain)" ] && echo ' (dirty)' )"
        echo "moli:     $(git -C vendor/moli rev-parse --short HEAD)$( [ -n "$(git -C vendor/moli status --porcelain)" ] && echo ' (dirty)' )"
        echo "host:     $(uname -srm)"
    } | tee tmp/bench.log
    odin run bench -collection:gloaming=src -collection:moli=vendor/moli/src \
        -collection:gladapter=adapter_src -o:speed 2>&1 | tee -a tmp/bench.log

# Run the test suite serially, then gate on the log: verdicts come from
# the log, never the exit status alone, and the leak discipline is zero
# leak lines — not "fewer than before".
test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp
    odin test tests -collection:gloaming=src -define:ODIN_TEST_THREADS=1 2>&1 | tee tmp/test.log
    pattern='\[ERROR\]|\[FATAL\]|\[WARN \]|\[WARN\]|\+\+\+ leak|bad free|out of range'
    if grep -a -q -E "$pattern" tmp/test.log; then
        grep -a -E "$pattern" tmp/test.log
        echo 'FAIL: errors or leak blocks in the test log (above)'
        exit 1
    fi
