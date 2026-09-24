# Changelog

All notable changes to this project should be documented in this file.

## [0.2.2] - 2026-09-24

### Changed

- Updated `moonbitlang/x` to `0.5.5` (from `0.4.40`) to track the current
  MoonBit toolchain.
- Adapted `read_file`/`read_file_columnar`/`write_file` to the `x/fs`
  `IOError` shape on `0.5.5`, which now only implements `Debug` (destructure
  the error instead of calling the removed `to_string` method).
- Added `derive(Debug)` to `Value`, `Column`, `ColumnType`, `Repetition`,
  `ParquetColumnData`, `ParquetFile`, `ParquetColumnarFile`, and
  `ParquetError` so `assert_eq`/`inspect` work under the current `moon`
  toolchain, which requires `Debug` for equality assertions. This is
  additive and keeps the existing `Eq`/`Show` behavior.
- Migrated away from APIs deprecated by the current MoonBit core: `.view()`
  -> `.exact_view()`, `BytesView::to_bytes()` -> `.to_owned()`,
  `StringView::to_string()` -> `.to_owned()`, `Array::new(capacity=...)` ->
  `Array(capacity=...)`, `T::default()` -> `Default::default()`, and
  `StringBuilder::new()` -> `StringBuilder()`.
- Replaced the deprecated `moonbitlang/x/sys` `get_cli_args()` call in
  `src/cmd/duckdb_e2e` with `moonbitlang/core/env` `args()`.
- Regenerated `.mbti` interface files (`moon info`).

### Known issues

- `src/playground_bridge` (and its `src/cmd/playground_bridge` demo binary)
  depend on `f4ah6o/duckdb`, whose own `duckdb_arrow_js.mbt` source (and the
  `moonbitlang/quickcheck` version it pulls in) use a `for`/`match`-with-
  `else` construct that the current `moonc` no longer parses. This is a
  pre-existing incompatibility in that upstream dependency, reproducible
  against the already-published `0.2.1` tag on the current toolchain, and is
  unrelated to this release; it blocks `moon check`/`moon info` only for
  those two packages, not for the core `mizchi/parquet` library or
  `src/cmd/duckdb_e2e`.

## [Unreleased]

### Added

- Property-based test example with `moonbitlang/quickcheck`
- Package-level `src/README.mbt.md` with executable examples
- `just ci`, `just ci-all`, `just fmt-check`, and `just info-check`

### Changed

- GitHub Actions CI now verifies formatting and generated `.mbti` files
- CI now runs `native` checks on both Ubuntu and macOS
- Root README now links to the latest MoonBit update and QuickCheck reference
- `moon.mod.json` now points `readme` to `src/README.mbt.md`

### Fixed

- Removed the broken `hello()` example from the published README path
- Aligned local `just` workflows with the CI entrypoints

## [0.1.2] - 2026-02-12

### Changed

- Baseline template state before release-workflow hardening.
