# MoonBit Project Commands

# Default target (js for browser compatibility)
target := "js"

# Default task: check and test
default: check test

# Format code
fmt:
    moon fmt

# Check formatting without rewriting files
fmt-check:
    moon fmt --check

# Type check
check:
    if [ "{{target}}" = "native" ]; then \
        CPATH="$HOME/brew/opt/duckdb/include:${CPATH:-}" \
        LIBRARY_PATH="$HOME/brew/opt/duckdb/lib:${LIBRARY_PATH:-}" \
        LD_LIBRARY_PATH="$HOME/brew/opt/duckdb/lib:${LD_LIBRARY_PATH:-}" \
        DYLD_LIBRARY_PATH="$HOME/brew/opt/duckdb/lib:${DYLD_LIBRARY_PATH:-}" \
        moon check --deny-warn --target {{target}}; \
    else \
        moon check --deny-warn --target {{target}}; \
    fi

# Run tests
test:
    if [ "{{target}}" = "native" ]; then \
        CPATH="$HOME/brew/opt/duckdb/include:${CPATH:-}" \
        LIBRARY_PATH="$HOME/brew/opt/duckdb/lib:${LIBRARY_PATH:-}" \
        LD_LIBRARY_PATH="$HOME/brew/opt/duckdb/lib:${LD_LIBRARY_PATH:-}" \
        DYLD_LIBRARY_PATH="$HOME/brew/opt/duckdb/lib:${DYLD_LIBRARY_PATH:-}" \
        moon test --target {{target}}; \
    else \
        moon test --target {{target}}; \
    fi

# Run benchmarks
bench:
    moon bench --target {{target}} --release

# Update snapshot tests
test-update:
    moon test --update --target {{target}}

# Run main
run:
    moon run src/main --target {{target}}

# Generate type definition files
info:
    moon info

# Compare MoonBit reader benchmarks against a local Rust implementation
bench-compare-rust:
    node scripts/compare_rust_bench.mjs

# Compare MoonBit js/wasm-gc/native reader benchmarks against the local Rust baseline
bench-compare-all:
    node scripts/compare_all_bench.mjs

# DuckDB interoperability end-to-end checks
e2e-duckdb:
    node scripts/duckdb_e2e.mjs

# Install browser playground dependencies
playground-install:
    pnpm --dir playground install

# Run the browser playground locally
playground-dev:
    pnpm --dir playground dev

# Run browser playground tests
playground-test:
    pnpm --dir playground test

# Build the browser playground for production
playground-build:
    pnpm --dir playground build

# Build the browser playground for GitHub Pages
playground-build-pages:
    PLAYGROUND_BASE_PATH="/parquet/" pnpm --dir playground build

# Verify browser playground test and build
playground-check: playground-test playground-build

# Verify generated type definition files are up to date
info-check:
    moon info
    git diff --exit-code -- ':(glob)**/*.generated.mbti'

# Clean build artifacts
clean:
    moon clean

# Pre-release check
release-check: fmt info check test playground-check

# Pre-release check on all supported targets
release-check-all:
    just release-check
    just target=native check test

# CI checks for the default target on a clean worktree
ci: fmt-check info-check check test

# CI checks across all supported targets
ci-all:
    just ci
    just target=native check test
    just playground-check
