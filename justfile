set shell := ["bash", "-c"]

# Show available recipes
default:
    @just --list

# Run autogen + configure (idempotent; safe to re-run)
configure:
    ./autogen.sh
    ./configure

# Build USDX in parallel, logging to tmp-build.log
build:
    make -j$(nproc) 2>&1 | tee tmp-build.log
    @grep -c '^.*Warning:' tmp-build.log | xargs -I{} echo "Warnings: {}"

# Clean build artifacts
clean:
    make clean || true
    rm -f tmp-build.log .baseline-warnings.txt

# Run the built binary
run:
    ./game/ultrastardx

# Regenerate the baseline warning set from the last build log
baseline:
    @test -f tmp-build.log || (echo "run 'just build' first" && exit 1)
    grep -E 'Warning:|Hint:' tmp-build.log \
        | sed 's|{{justfile_directory()}}/||g' \
        > .baseline-warnings.txt
    @wc -l .baseline-warnings.txt

# Diff current build's warnings against the captured baseline
warnings-diff:
    @test -f .baseline-warnings.txt || (echo "run 'just baseline' first" && exit 1)
    @test -f tmp-build.log || (echo "run 'just build' first" && exit 1)
    @grep -E 'Warning:|Hint:' tmp-build.log \
        | sed 's|{{justfile_directory()}}/||g' \
        > .current-warnings.txt
    @diff -u .baseline-warnings.txt .current-warnings.txt && echo "OK: no new warnings" || (echo "FAIL: warning set changed"; exit 1)
    @rm -f .current-warnings.txt
