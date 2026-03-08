///|
fn read_bench_fixture(name : String) -> Bytes {
  try! @fs.read_file_to_bytes("fixtures/apache-parquet-testing/data/" + name)
}

///|
fn sample_flat_file() -> ParquetFile {
  new_parquet_file(
    [
      new_column("id", Int32, Required),
      new_column("score", Int64, Optional),
      new_column("name", String, Optional),
    ],
    [
      [Value::Int32(1), Value::Int64(10L), Value::String("alice")],
      [Value::Int32(2), Value::Null, Value::String("bob")],
      [Value::Int32(3), Value::Int64(30L), Value::Null],
    ],
    Some("bench"),
  )
}

///|
test "read delta binary packed benchmark" (b : @bench.T) {
  let data = read_bench_fixture("delta_binary_packed.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "read int32 null pages benchmark" (b : @bench.T) {
  let data = read_bench_fixture("int32_with_null_pages.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "read fixed length byte array benchmark" (b : @bench.T) {
  let data = read_bench_fixture("fixed_length_byte_array.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "read alltypes plain benchmark" (b : @bench.T) {
  let data = read_bench_fixture("alltypes_plain.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "read alltypes dictionary benchmark" (b : @bench.T) {
  let data = read_bench_fixture("alltypes_dictionary.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "read int96 from spark benchmark" (b : @bench.T) {
  let data = read_bench_fixture("int96_from_spark.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "write flat parquet benchmark" (b : @bench.T) {
  let file = sample_flat_file()
  b.bench(() => ignore(try! write_bytes(file)))
}
