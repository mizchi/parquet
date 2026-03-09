# mizchi/parquet

Parquet reader/writer for MoonBit.

## Status

- Reader passes the vendored `apache-parquet-testing` fixtures used in this repo:
  - `delta_binary_packed`
  - `delta_byte_array`
  - `delta_encoding_optional_column`
  - `delta_encoding_required_column`
  - `int32_with_null_pages`
  - `fixed_length_byte_array`
  - `datapage_v2_empty_datapage.snappy.parquet`
  - `int96_from_spark`
  - `alltypes_plain`
  - `alltypes_dictionary`
- Writer currently supports flat schemas with `Int32`, `Int64`, `String`, and `Binary`, with `Required` / `Optional` repetition.
- DuckDB interoperability is checked both ways:
  - DuckDB-written parquet can be read by this implementation.
  - MoonBit-written parquet can be read by DuckDB.

## Benchmark

Measured on 2026-03-09 on `Apple M5`, `macOS 26.2`, `Darwin arm64`.

Reproduce:

```bash
just bench-compare-all
just bench-compare-rust
```

Comparison table from `just bench-compare-all`:

| benchmark | moon(js) | moon(wasm-gc) | moon(native) | rust |
|---|---:|---:|---:|---:|
| read delta binary packed benchmark | 512.22 us | 127.01 us | 645.99 us | 203.85 us |
| read int32 null pages benchmark | 17.34 us | 10.85 us | 43.60 us | 7.61 us |
| read fixed length byte array benchmark | 87.17 us | 10.41 us | 54.68 us | unsupported |
| read alltypes plain benchmark | 20.49 us | 12.02 us | 45.42 us | 19.57 us |
| read alltypes dictionary benchmark | 16.83 us | 11.04 us | 42.53 us | 17.31 us |
| read int96 from spark benchmark | 10.90 us | 3.52 us | 16.19 us | 3.28 us |
| read empty snappy datapage v2 benchmark | 3.46 us | 1.72 us | 6.27 us | 2.58 us |

Notes:

- Rust is the local baseline in `tools/rust-bench`, built on top of Apache's `parquet` crate.
- `fixed_length_byte_array` is marked `unsupported` because the current Rust benchmark tool does not read that fixture.
- On this machine, `wasm-gc` is the fastest MoonBit target for the read-side microbenchmarks above.

## Development

```bash
just                  # check + test
just target=js bench
just target=wasm-gc bench
just target=native bench
just bench-compare-all
just e2e-duckdb
moon info
```

## Browser Playground

The repository includes a browser playground that generates parquet on DuckDB WASM and lets you try SQL against it immediately.

```bash
just playground-install
just playground-dev
```

Production build:

```bash
just playground-build
just playground-build-pages
```

In the UI, you can edit schema JSON / rows JSON / SQL, generate parquet bytes with `mizchi/parquet`, and execute `read_parquet('playground.parquet')` on the `f4ah6o/duckdb` WASM backend.

GitHub Pages:

`https://mizchi.github.io/parquet/`

## License

Apache-2.0
