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
| read delta binary packed benchmark | 846.96 us | 241.81 us | 1.26 ms | 138.42 us |
| read int32 null pages benchmark | 53.80 us | 24.70 us | 101.40 us | 5.96 us |
| read fixed length byte array benchmark | 77.85 us | 26.64 us | 168.70 us | unsupported |
| read alltypes plain benchmark | 24.07 us | 15.26 us | 57.84 us | 17.73 us |
| read alltypes dictionary benchmark | 20.78 us | 25.29 us | 80.78 us | 21.84 us |
| read int96 from spark benchmark | 7.79 us | 5.04 us | 13.46 us | 4.78 us |
| read empty snappy datapage v2 benchmark | 3.80 us | 3.03 us | 8.91 us | 2.17 us |

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
