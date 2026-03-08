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
| read delta binary packed benchmark | 556.04 us | 208.60 us | 870.22 us | 111.03 us |
| read int32 null pages benchmark | 23.05 us | 12.64 us | 65.69 us | 5.54 us |
| read fixed length byte array benchmark | 51.52 us | 16.75 us | 84.41 us | unsupported |
| read alltypes plain benchmark | 19.02 us | 11.41 us | 44.90 us | 13.81 us |
| read alltypes dictionary benchmark | 16.84 us | 10.79 us | 41.95 us | 13.11 us |
| read int96 from spark benchmark | 7.13 us | 2.63 us | 11.35 us | 2.55 us |
| read empty snappy datapage v2 benchmark | 3.41 us | 1.71 us | 6.29 us | 1.99 us |

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

## License

Apache-2.0
