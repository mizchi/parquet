///|
fn bytes_from_ints(values : Array[Int]) -> Bytes {
  Bytes::makei(values.length(), fn(index) { values[index].to_byte() })
}

///|
fn delta_byte_array_fixture_page() -> (Bytes, Int, Int) raise ParquetError {
  let data = try! @fs.read_file_to_bytes(
    "fixtures/apache-parquet-testing/data/delta_byte_array.parquet",
  )
  try! check_magic(data)
  let footer_len = try! read_u32_le(data, data.length() - 8)
  let footer_start = data.length() - 8 - footer_len
  let metadata = try! read_file_metadata(data, footer_start, footer_len)
  let columns = try! build_leaf_columns(metadata.schema)
  let row_group = metadata.row_groups[0]
  let column = columns[1]
  let chunk = row_group.columns[1]
  let page_offset = chunk.meta_data.data_page_offset.to_int()
  let (page_header, page_header_len) = try! read_page_header(data, page_offset)
  let payload_offset = page_offset + page_header_len
  match page_header.data_page {
    Some(header) => {
      let definition_len = try! read_u32_le(data, payload_offset)
      let value_offset = payload_offset + 4 + definition_len
      let non_null_count = try! count_levels_range_non_null(
        data,
        payload_offset + 4,
        value_offset,
        column.max_definition_level,
        header.num_values,
      )
      (data, value_offset, non_null_count)
    }
    None =>
      match page_header.data_page_v2 {
        Some(header) => {
          let value_offset = payload_offset +
            header.repetition_levels_byte_length +
            header.definition_levels_byte_length
          let non_null_count = try! count_levels_range_non_null(
            data,
            payload_offset + header.repetition_levels_byte_length,
            value_offset,
            column.max_definition_level,
            header.num_values,
          )
          (data, value_offset, non_null_count)
        }
        None => {
          invalid_data("Expected data page")
          (data, 0, 0)
        }
      }
  }
}

///|
test "streams optional dictionary values for boolean definition levels" {
  let target : Array[Value] = []
  let dictionary_values : Array[Value] = [
    Value::String("zero"),
    Value::String("one"),
    Value::String("two"),
  ]
  let level_data = bytes_from_ints([3, 0xCB])
  let value_data = bytes_from_ints([2, 4, 1, 2, 2, 4, 0])
  let cursor = try! DictionaryValueCursor::new(value_data, 0)
  try! append_optional_dictionary_values_from_levels_range(
    target,
    level_data,
    0,
    level_data.length(),
    1,
    8,
    cursor,
    dictionary_values,
  )
  assert_eq(target, [
    Value::String("one"),
    Value::String("one"),
    Value::Null,
    Value::String("two"),
    Value::Null,
    Value::Null,
    Value::String("zero"),
    Value::String("zero"),
  ])
}

///|
test "detects all-defined boolean definition levels" {
  assert_true(try! levels_range_all_max(bytes_from_ints([3, 0xFF]), 0, 2, 1, 8))
  assert_false(
    try! levels_range_all_max(bytes_from_ints([3, 0xEF]), 0, 2, 1, 8),
  )
}

///|
test "streams optional dictionary values for multi-bit definition levels" {
  let target : Array[Value] = []
  let dictionary_values : Array[Value] = [
    Value::String("zero"),
    Value::String("one"),
    Value::String("two"),
  ]
  let level_data = bytes_from_ints([3, 0x8A, 0x29])
  let value_data = bytes_from_ints([2, 4, 1, 2, 2, 4, 0])
  let cursor = try! DictionaryValueCursor::new(value_data, 0)
  try! append_optional_dictionary_values_from_levels_range(
    target,
    level_data,
    0,
    level_data.length(),
    2,
    8,
    cursor,
    dictionary_values,
  )
  assert_eq(target, [
    Value::String("one"),
    Value::String("one"),
    Value::Null,
    Value::String("two"),
    Value::Null,
    Value::String("zero"),
    Value::String("zero"),
    Value::Null,
  ])
}

///|
test "detects all-defined multi-bit definition levels" {
  assert_true(
    try! levels_range_all_max(bytes_from_ints([3, 0xAA, 0xAA]), 0, 3, 2, 8),
  )
  assert_false(
    try! levels_range_all_max(bytes_from_ints([3, 0x8A, 0x29]), 0, 3, 2, 8),
  )
}

///|
test "decodes delta byte array lengths as ints" {
  let (data, value_offset, non_null_count) = try! delta_byte_array_fixture_page()
  let (prefix_lengths_ref, prefix_consumed_ref) = try! decode_delta_binary_packed(
    data, value_offset,
  )
  let (prefix_lengths, prefix_consumed) = try! decode_delta_binary_packed_ints(
    data, value_offset,
  )
  assert_eq(prefix_consumed, prefix_consumed_ref)
  assert_eq(prefix_lengths.length(), prefix_lengths_ref.length())
  for index in 0..<prefix_lengths.length() {
    assert_eq(prefix_lengths[index], prefix_lengths_ref[index].to_int())
  }
  let suffix_start = value_offset + prefix_consumed_ref
  let (suffix_lengths_ref, suffix_length_bytes_ref) = try! decode_delta_binary_packed(
    data, suffix_start,
  )
  let suffix_values_offset_ref = suffix_start + suffix_length_bytes_ref
  let mut suffix_end_ref = suffix_values_offset_ref
  for length in suffix_lengths_ref {
    let suffix_len = length.to_int()
    if suffix_len < 0 || suffix_end_ref + suffix_len > data.length() {
      invalid_data("Invalid DELTA_LENGTH_BYTE_ARRAY suffix length")
    }
    suffix_end_ref += suffix_len
  }
  let (suffix_lengths, suffix_values_offset, suffix_consumed) = try! decode_delta_length_byte_array_layout_ints(
    data, suffix_start, non_null_count,
  )
  assert_eq(suffix_values_offset, suffix_values_offset_ref)
  assert_eq(suffix_consumed, suffix_end_ref - suffix_start)
  assert_eq(suffix_lengths.length(), suffix_lengths_ref.length())
  for index in 0..<suffix_lengths.length() {
    assert_eq(suffix_lengths[index], suffix_lengths_ref[index].to_int())
  }
}

///|
test "streams delta byte array cursor over fixture page" {
  let (data, value_offset, non_null_count) = try! delta_byte_array_fixture_page()
  let prefix_scan = try! DeltaBinaryPackedCursor::new(data, value_offset)
  try! prefix_scan.skip(non_null_count)
  let (_, prefix_consumed_ref) = try! decode_delta_binary_packed(
    data, value_offset,
  )
  let actual : Array[Value] = []
  let cursor = try! DeltaByteArrayValueCursor::new(
    data, value_offset, non_null_count,
  )
  try! cursor.append_into(actual, non_null_count, String)
  assert_eq(try! prefix_scan.consumed(), prefix_consumed_ref)
  assert_eq(actual.length(), non_null_count)
  assert_eq(actual[0], Value::String("Sir"))
  assert_eq(actual[1], Value::String("Mrs."))
  assert_eq(actual[2], Value::String("Ms."))
  assert_eq(actual[3], Value::String("Sir"))
}

///|
test "decodes delta byte array columns in columnar mode" {
  let data = try! @fs.read_file_to_bytes(
    "fixtures/apache-parquet-testing/data/delta_byte_array.parquet",
  )
  try! check_magic(data)
  let footer_len = try! read_u32_le(data, data.length() - 8)
  let footer_start = data.length() - 8 - footer_len
  let metadata = try! read_file_metadata(data, footer_start, footer_len)
  let columns = try! build_leaf_columns(metadata.schema)
  let row_group = metadata.row_groups[0]
  for column_index in 0..<columns.length() {
    let decoded = decode_column_chunk_columnar(
      data,
      row_group.columns[column_index],
      columns[column_index],
    ) catch {
      err => fail("column \{column_index}: \{err.to_string()}")
    }
    assert_eq(decoded.length(), row_group.num_rows.to_int())
  }
}
