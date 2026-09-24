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

- `src/playground_bridge` now depends on `mizchi/duckdb` 0.6.4 instead of
  `f4ah6o/duckdb` 0.6.0. `f4ah6o/duckdb` pulls in `moonbitlang/quickcheck`
  0.9.10, which the current `moonc` no longer parses; `mizchi/duckdb` is a
  fork with that fixed, used until the fix lands upstream. The API is the
  same.

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
