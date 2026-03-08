# Changelog

All notable changes to this project should be documented in this file.

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
