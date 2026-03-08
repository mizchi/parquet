///|
fn read_bench_fixture(name : String) -> Bytes {
  try! @fs.read_file_to_bytes("fixtures/apache-parquet-testing/data/" + name)
}

///|
priv struct DeltaBenchContext {
  data : Bytes
  columns : Array[LeafColumnMeta]
  row_group : RowGroupMeta
  column_values : Array[Array[Value]]
  row_count : Int
}

///|
priv struct DeltaPageBenchContext {
  data : Bytes
  column : LeafColumnMeta
  chunk : ColumnChunkMeta
  value_offset : Int
  value_count : Int
  encoding : Int
}

///|
fn delta_bench_context() -> DeltaBenchContext {
  let data = read_bench_fixture("delta_binary_packed.parquet")
  try! check_magic(data)
  let footer_len = try! read_u32_le(data, data.length() - 8)
  let footer_start = data.length() - 8 - footer_len
  let metadata = try! read_file_metadata(data, footer_start, footer_len)
  let columns = try! build_leaf_columns(metadata.schema)
  let row_group = metadata.row_groups[0]
  let column_values : Array[Array[Value]] = Array::new(
    capacity=columns.length(),
  )
  for index in 0..<columns.length() {
    column_values.push(
      try! decode_column_chunk(data, row_group.columns[index], columns[index]),
    )
  }
  {
    data,
    columns,
    row_group,
    column_values,
    row_count: row_group.num_rows.to_int(),
  }
}

///|
fn delta_first_column_context() -> DeltaPageBenchContext {
  let ctx = delta_bench_context()
  let column = ctx.columns[0]
  let chunk = ctx.row_group.columns[0]
  let offset = chunk.meta_data.data_page_offset.to_int()
  let (page_header, page_header_len) = try! read_page_header(ctx.data, offset)
  let payload_offset = offset + page_header_len
  match page_header.data_page {
    Some(header) => {
      let (_, repetition_len) = try! decode_levels_v1(
        ctx.data,
        payload_offset,
        column.max_repetition_level,
        header.num_values,
      )
      let definition_offset = payload_offset + repetition_len
      let (_, definition_len) = try! decode_levels_v1(
        ctx.data,
        definition_offset,
        column.max_definition_level,
        header.num_values,
      )
      {
        data: ctx.data,
        column,
        chunk,
        value_offset: definition_offset + definition_len,
        value_count: header.num_values,
        encoding: header.encoding,
      }
    }
    None =>
      match page_header.data_page_v2 {
        Some(header) =>
          {
            data: ctx.data,
            column,
            chunk,
            value_offset: payload_offset +
            header.repetition_levels_byte_length +
            header.definition_levels_byte_length,
            value_count: header.num_values,
            encoding: header.encoding,
          }
        None => panic()
      }
  }
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
test "delta binary packed footer/schema benchmark" (b : @bench.T) {
  let data = read_bench_fixture("delta_binary_packed.parquet")
  b.bench(() => {
    try! check_magic(data)
    let footer_len = try! read_u32_le(data, data.length() - 8)
    let footer_start = data.length() - 8 - footer_len
    let metadata = try! read_file_metadata(data, footer_start, footer_len)
    ignore(try! build_leaf_columns(metadata.schema))
  })
}

///|
test "delta binary packed decode columns benchmark" (b : @bench.T) {
  let ctx = delta_bench_context()
  b.bench(() => {
    let values : Array[Array[Value]] = Array::new(capacity=ctx.columns.length())
    for index in 0..<ctx.columns.length() {
      values.push(
        try! decode_column_chunk(
          ctx.data,
          ctx.row_group.columns[index],
          ctx.columns[index],
        ),
      )
    }
    ignore(values)
  })
}

///|
test "delta binary packed first column chunk benchmark" (b : @bench.T) {
  let ctx = delta_first_column_context()
  b.bench(() => {
    ignore(try! decode_column_chunk(ctx.data, ctx.chunk, ctx.column))
  })
}

///|
test "delta binary packed first column values benchmark" (b : @bench.T) {
  let ctx = delta_first_column_context()
  b.bench(() => {
    ignore(
      try! decode_non_null_values(
        ctx.data,
        ctx.value_offset,
        ctx.encoding,
        ctx.column,
        ctx.value_count,
        None,
      ),
    )
  })
}

///|
test "delta binary packed first column raw delta benchmark" (b : @bench.T) {
  let ctx = delta_first_column_context()
  b.bench(() => {
    ignore(try! decode_delta_binary_packed(ctx.data, ctx.value_offset))
  })
}

///|
test "delta binary packed build rows benchmark" (b : @bench.T) {
  let ctx = delta_bench_context()
  b.bench(() => {
    ignore(try! build_rows(ctx.columns, ctx.column_values, ctx.row_count))
  })
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
test "read empty snappy datapage v2 benchmark" (b : @bench.T) {
  let data = read_bench_fixture("datapage_v2_empty_datapage.snappy.parquet")
  b.bench(() => ignore(try! read_bytes(data)))
}

///|
test "write flat parquet benchmark" (b : @bench.T) {
  let file = sample_flat_file()
  b.bench(() => ignore(try! write_bytes(file)))
}
