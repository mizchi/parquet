# MoonBit Template

A minimal MoonBit project template with CI, justfile, and AI coding assistant support.

## Usage

Clone this repository and start coding:

```bash
git clone https://github.com/mizchi/moonbit-template my-project
cd my-project
```

Update `moon.mod.json` with your module name:

```json
{
  "name": "your-username/your-project",
  ...
}
```

### Post-install

Set up pre-commit hooks with [prek](https://github.com/j178/prek):

```bash
prek install
```

Optional: install [starlint](https://github.com/mizchi/starlint) for MoonBit linting, then uncomment the `starlint` hook in `.pre-commit-config.yaml`:

```bash
moon install mizchi/starlint/cmd/starlint
```

## Quick Commands

```bash
just           # check + test
just fmt       # format code
just fmt-check # verify formatting
just check     # type check
just test      # run tests
just test-update  # update snapshot tests
just run       # run main
just info      # generate type definition files
just ci        # local CI equivalent for default target
just ci-all    # lint + js/native test matrix
just release-check-all  # release check on js + native
```

## Project Structure

```
my-project/
├── moon.mod.json      # Module configuration
├── src/
│   ├── moon.pkg       # Package configuration
│   ├── lib.mbt        # Library code
│   ├── lib_test.mbt   # Tests
│   ├── lib_bench.mbt  # Benchmarks
│   ├── README.mbt.md  # Package README + doc tests
│   ├── quickcheck_test.mbt # Property tests
│   └── main/
│       ├── moon.pkg
│       └── main.mbt   # Entry point
├── justfile           # Task runner
└── .github/workflows/
    └── ci.yml         # GitHub Actions CI
```

## Features

- `src/` directory structure with `moon.pkg` format
- Snapshot testing with `inspect()`
- Doc tests in `.mbt.md` files
- Property-based tests with `moonbitlang/quickcheck`
- Benchmarks with `moon bench`
- GitHub Actions CI with format and `.mbti` verification
- Pre-commit hooks via [prek](https://github.com/j178/prek) (optional [starlint](https://github.com/mizchi/starlint))
- Claude Code / GitHub Copilot support (AGENTS.md)

## Recommended Reading

- Latest MoonBit update as of 2026-03-08: [MoonBit 0.8.0 Released (2026-02-09)](https://www.moonbitlang.com/updates/moonbit-0-8-0-release)
- Property testing reference: [moonbitlang/quickcheck](https://github.com/moonbitlang/quickcheck)

## CLI Tool Template

To build a CLI tool, use the [`feat/cli`](https://github.com/mizchi/moonbit-template/tree/feat/cli) branch:

```bash
git clone -b feat/cli https://github.com/mizchi/moonbit-template my-cli
```

The `feat/cli` branch includes:

- `src/cmd/app/` - CLI executable (`is-main: true`, native target)
- `install.sh` - curl-based installer script
- `.github/workflows/release.yml` - Builds and releases linux-x64 / macos-arm64 binaries
- Two install methods: `moon install` and `curl | sh`

## Release Checklist

Before tagging a release:

1. Update `moon.mod.json` version and metadata (`repository`, `keywords`, `description`)
2. Update `CHANGELOG.md`
3. Run `just release-check-all`
4. Create annotated tag (for example: `git tag -a v0.2.0 -m "Release v0.2.0"`)
5. Push branch and tag

## License

Apache-2.0
