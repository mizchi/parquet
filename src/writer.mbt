///|
fn assert_flat_supported(file : ParquetFile) -> Unit raise ParquetError {
  let columns = file.columns()
  let rows = file.rows()
  if columns.is_empty() {
    invalid_data("Cannot write parquet file without columns")
  }
  for row in rows {
    if row.length() != columns.length() {
      invalid_data("Row width does not match column count")
    }
  }
  for column in columns {
    if column.repetition == Repeated {
      unsupported("Repeated columns are not supported by the writer yet")
    }
    match column.column_type {
      Int32 | Int64 | String | Binary => ()
      _ => unsupported("This column type is not supported by the writer yet")
    }
  }
}

///|
fn encode_definition_levels(
  values : Array[Value],
  repetition : Repetition,
) -> Bytes {
  if repetition != Optional {
    return Bytes::default()
  }
  let levels = values.map(fn(value) { if value == Null { 0 } else { 1 } })
  encode_rle_levels(levels, 1, true)
}

///|
fn encode_rle_levels(
  values : Array[Int],
  bit_width : Int,
  length_prefixed : Bool,
) -> Bytes {
  let body = ByteSink::new()
  let mut index = 0
  let byte_width = ceil_div(bit_width, 8)
  while index < values.length() {
    let value = values[index]
    let mut run_len = 1
    while index + run_len < values.length() && values[index + run_len] == value {
      run_len += 1
    }
    body.push_varint((run_len << 1).to_uint64())
    for byte_index in 0..<byte_width {
      body.push_byte(((value >> (byte_index * 8)) & 0xff).to_byte())
    }
    index += run_len
  }
  if !length_prefixed {
    return body.to_bytes()
  }
  let out = ByteSink::new()
  out.push_u32_le(body.length())
  out.push_bytes(body.to_bytes()[:])
  out.to_bytes()
}

///|
fn collect_column_values(
  file : ParquetFile,
  column_index : Int,
) -> Array[Value] {
  file.rows().map(fn(row) { row[column_index] })
}

///|
fn writer_type_code(column_type : ColumnType) -> Int raise ParquetError {
  match column_type {
    Int32 => parquet_type_int32
    Int64 => parquet_type_int64
    String => parquet_type_byte_array
    Binary => parquet_type_byte_array
    TimestampMicros => {
      unsupported(
        "TIMESTAMP_MICROS columns are not supported by the writer yet",
      )
      0
    }
    _ => {
      unsupported("This column type is not supported by the writer yet")
      0
    }
  }
}

///|
fn encode_plain_non_null_values(
  values : Array[Value],
  column_type : ColumnType,
) -> Bytes raise ParquetError {
  let sink = ByteSink::new()
  for value in values {
    match (column_type, value) {
      (Int32, Value::Int32(v)) => sink.push_i32_le(v)
      (Int64, Value::Int64(v)) => sink.push_i64_le(v)
      (String, Value::String(v)) => {
        let bytes = string_to_bytes(v)
        sink.push_u32_le(bytes.length())
        sink.push_bytes(bytes[:])
      }
      (Binary, Value::Binary(v)) => {
        sink.push_u32_le(v.length())
        sink.push_bytes(v[:])
      }
      (TimestampMicros, _) =>
        unsupported(
          "TIMESTAMP_MICROS columns are not supported by the writer yet",
        )
      (Boolean, _) =>
        unsupported("BOOLEAN columns are not supported by the writer yet")
      (Float, _) =>
        unsupported("FLOAT columns are not supported by the writer yet")
      (Double, _) =>
        unsupported("DOUBLE columns are not supported by the writer yet")
      (_, Null) => ()
      _ => unsupported("Column values do not match declared column type")
    }
  }
  sink.to_bytes()
}

///|
fn encode_data_page(
  values : Array[Value],
  column : Column,
) -> Bytes raise ParquetError {
  let non_null_values = values.filter(fn(value) { value != Null })
  let definition_levels = encode_definition_levels(values, column.repetition)
  let value_bytes = encode_plain_non_null_values(
    non_null_values,
    column.column_type,
  )
  let payload = definition_levels + value_bytes
  let writer = CompactWriter::new()
  writer.begin_struct()
  writer.write_i32_field(1, page_type_data_page)
  writer.write_i32_field(2, payload.length())
  writer.write_i32_field(3, payload.length())
  writer.write_field_header(5, thrift_wire_struct)
  writer.begin_struct()
  writer.write_i32_field(1, values.length())
  writer.write_i32_field(2, encoding_plain)
  writer.write_i32_field(3, encoding_rle)
  writer.write_i32_field(4, encoding_rle)
  writer.end_struct()
  writer.end_struct()
  writer.write_bytes() + payload
}

///|
fn write_list_of_i32(
  writer : CompactWriter,
  field_id : Int,
  values : Array[Int],
) -> Unit raise ParquetError {
  writer.write_field_header(field_id, thrift_wire_list)
  writer.write_list_header(values.length(), thrift_wire_i32)
  for value in values {
    writer.sink.push_zigzag_i32(value)
  }
}

///|
fn write_list_of_string(
  writer : CompactWriter,
  field_id : Int,
  values : Array[String],
) -> Unit raise ParquetError {
  writer.write_field_header(field_id, thrift_wire_list)
  writer.write_list_header(values.length(), thrift_wire_binary)
  for value in values {
    writer.sink.push_string(value)
  }
}

///|
fn encode_parquet(file : ParquetFile) -> Bytes raise ParquetError {
  assert_flat_supported(file)
  let columns = file.columns()
  let rows = file.rows()
  let body = ByteSink::new()
  let mut offset = 4
  let column_chunks : Array[ColumnChunkMeta] = []
  for column_index in 0..<columns.length() {
    let column = columns[column_index]
    let values = collect_column_values(file, column_index)
    let page = encode_data_page(values, column)
    let page_offset = offset
    body.push_bytes(page[:])
    offset += page.length()
    column_chunks.push({
      file_offset: 0L,
      meta_data: {
        type_code: writer_type_code(column.column_type),
        encodings: [encoding_plain, encoding_rle],
        path_in_schema: [column.name],
        codec: codec_uncompressed,
        num_values: rows.length().to_int64(),
        total_uncompressed_size: page.length().to_int64(),
        total_compressed_size: page.length().to_int64(),
        data_page_offset: page_offset.to_int64(),
        dictionary_page_offset: None,
      },
    })
  }
  let row_group = {
    columns: column_chunks,
    total_byte_size: body.length().to_int64(),
    num_rows: rows.length().to_int64(),
    file_offset: Some(4L),
    total_compressed_size: Some(body.length().to_int64()),
  }
  let footer = CompactWriter::new()
  footer.begin_struct()
  footer.write_i32_field(1, 1)
  footer.write_field_header(2, thrift_wire_list)
  footer.write_list_header(columns.length() + 1, thrift_wire_struct)
  let root = CompactWriter::new()
  root.begin_struct()
  root.write_string_field(4, "schema")
  root.write_i32_field(5, columns.length())
  root.end_struct()
  footer.sink.push_bytes(root.write_bytes()[:])
  for column in columns {
    let element = CompactWriter::new()
    element.begin_struct()
    element.write_i32_field(1, writer_type_code(column.column_type))
    element.write_i32_field(
      3,
      match column.repetition {
        Required => repetition_required
        Optional => repetition_optional
        Repeated => repetition_repeated
      },
    )
    element.write_string_field(4, column.name)
    if column.column_type == String {
      element.write_i32_field(6, converted_type_utf8)
    }
    element.end_struct()
    footer.sink.push_bytes(element.write_bytes()[:])
  }
  footer.write_i64_field(3, rows.length().to_int64())
  footer.write_field_header(4, thrift_wire_list)
  footer.write_list_header(1, thrift_wire_struct)
  let row_group_writer = CompactWriter::new()
  row_group_writer.begin_struct()
  row_group_writer.write_field_header(1, thrift_wire_list)
  row_group_writer.write_list_header(
    row_group.columns.length(),
    thrift_wire_struct,
  )
  for chunk in row_group.columns {
    let chunk_writer = CompactWriter::new()
    chunk_writer.begin_struct()
    chunk_writer.write_i64_field(2, chunk.file_offset)
    chunk_writer.write_field_header(3, thrift_wire_struct)
    chunk_writer.begin_struct()
    chunk_writer.write_i32_field(1, chunk.meta_data.type_code)
    write_list_of_i32(chunk_writer, 2, chunk.meta_data.encodings)
    write_list_of_string(chunk_writer, 3, chunk.meta_data.path_in_schema)
    chunk_writer.write_i32_field(4, chunk.meta_data.codec)
    chunk_writer.write_i64_field(5, chunk.meta_data.num_values)
    chunk_writer.write_i64_field(6, chunk.meta_data.total_uncompressed_size)
    chunk_writer.write_i64_field(7, chunk.meta_data.total_compressed_size)
    chunk_writer.write_i64_field(9, chunk.meta_data.data_page_offset)
    chunk_writer.end_struct()
    chunk_writer.end_struct()
    row_group_writer.sink.push_bytes(chunk_writer.write_bytes()[:])
  }
  row_group_writer.write_i64_field(2, row_group.total_byte_size)
  row_group_writer.write_i64_field(3, row_group.num_rows)
  row_group_writer.write_i64_field(5, row_group.file_offset.unwrap_or(0L))
  row_group_writer.write_i64_field(
    6,
    row_group.total_compressed_size.unwrap_or(0L),
  )
  row_group_writer.end_struct()
  footer.sink.push_bytes(row_group_writer.write_bytes()[:])
  footer.write_string_field(6, "mizchi/parquet")
  footer.end_struct()
  let footer_bytes = footer.write_bytes()
  let file_bytes = ByteSink::new()
  file_bytes.push_byte(parquet_magic_0)
  file_bytes.push_byte(parquet_magic_1)
  file_bytes.push_byte(parquet_magic_2)
  file_bytes.push_byte(parquet_magic_3)
  file_bytes.push_bytes(body.to_bytes()[:])
  file_bytes.push_bytes(footer_bytes[:])
  file_bytes.push_u32_le(footer_bytes.length())
  file_bytes.push_byte(parquet_magic_0)
  file_bytes.push_byte(parquet_magic_1)
  file_bytes.push_byte(parquet_magic_2)
  file_bytes.push_byte(parquet_magic_3)
  file_bytes.to_bytes()
}
