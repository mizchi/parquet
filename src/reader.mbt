///|
fn decode_levels_v1(
  data : Bytes,
  start : Int,
  max_level : Int,
  count : Int,
) -> (Array[Int], Int) raise ParquetError {
  if max_level == 0 {
    (Array::make(count, 0), 0)
  } else {
    decode_rle_hybrid(data, start, bit_width(max_level), count, true)
  }
}

///|
fn decode_levels_v2(
  data : Bytes,
  start : Int,
  len : Int,
  max_level : Int,
  count : Int,
) -> Array[Int] raise ParquetError {
  if max_level == 0 || len == 0 {
    Array::make(count, 0)
  } else {
    let view = data.view(start~, end=start + len).to_bytes()
    let (levels, _) = decode_rle_hybrid(
      view,
      0,
      bit_width(max_level),
      count,
      false,
    )
    levels
  }
}

///|
fn materialize_optional_values(
  definition_levels : Array[Int],
  max_definition_level : Int,
  decoded_values : Array[Value],
) -> Array[Value] raise ParquetError {
  let values : Array[Value] = []
  let mut value_index = 0
  for level in definition_levels {
    if level == max_definition_level {
      match decoded_values.get(value_index) {
        Some(value) => {
          values.push(value)
          value_index += 1
        }
        None => invalid_data("Not enough decoded values for definition levels")
      }
    } else {
      values.push(Null)
    }
  }
  if value_index != decoded_values.length() {
    invalid_data("Too many decoded values for definition levels")
  }
  values
}

///|
fn decode_data_page_v1(
  data : Bytes,
  payload_offset : Int,
  header : DataPageHeaderMeta,
  column : LeafColumnMeta,
  dictionary : Array[Value]?,
) -> Array[Value] raise ParquetError {
  if column.max_repetition_level > 0 {
    unsupported("Repeated columns are not supported yet")
  }
  let (_, repetition_len) = decode_levels_v1(
    data,
    payload_offset,
    column.max_repetition_level,
    header.num_values,
  )
  let definition_offset = payload_offset + repetition_len
  let (definition_levels, definition_len) = decode_levels_v1(
    data,
    definition_offset,
    column.max_definition_level,
    header.num_values,
  )
  let non_null_count = if column.max_definition_level == 0 {
    header.num_values
  } else {
    definition_levels.fold(init=0, fn(acc, level) {
      acc + (if level == column.max_definition_level { 1 } else { 0 })
    })
  }
  let value_offset = definition_offset + definition_len
  let (decoded_values, _) = decode_non_null_values(
    data,
    value_offset,
    header.encoding,
    column,
    non_null_count,
    dictionary,
  )
  if column.max_definition_level == 0 {
    decoded_values
  } else {
    materialize_optional_values(
      definition_levels,
      column.max_definition_level,
      decoded_values,
    )
  }
}

///|
fn decode_data_page_v2(
  data : Bytes,
  payload_offset : Int,
  header : DataPageHeaderV2Meta,
  column : LeafColumnMeta,
  dictionary : Array[Value]?,
) -> Array[Value] raise ParquetError {
  if column.max_repetition_level > 0 {
    unsupported("Repeated columns are not supported yet")
  }
  let _repetition_levels = decode_levels_v2(
    data,
    payload_offset,
    header.repetition_levels_byte_length,
    column.max_repetition_level,
    header.num_values,
  )
  let definition_offset = payload_offset + header.repetition_levels_byte_length
  let definition_levels = decode_levels_v2(
    data,
    definition_offset,
    header.definition_levels_byte_length,
    column.max_definition_level,
    header.num_values,
  )
  let value_offset = definition_offset + header.definition_levels_byte_length
  let non_null_count = if column.max_definition_level == 0 {
    header.num_values
  } else {
    definition_levels.fold(init=0, fn(acc, level) {
      acc + (if level == column.max_definition_level { 1 } else { 0 })
    })
  }
  let (decoded_values, _) = decode_non_null_values(
    data,
    value_offset,
    header.encoding,
    column,
    non_null_count,
    dictionary,
  )
  if column.max_definition_level == 0 {
    decoded_values
  } else {
    materialize_optional_values(
      definition_levels,
      column.max_definition_level,
      decoded_values,
    )
  }
}

///|
fn decode_dictionary_page(
  data : Bytes,
  payload_offset : Int,
  header : DictionaryPageHeaderMeta,
  column : LeafColumnMeta,
) -> Array[Value] raise ParquetError {
  if header.encoding != encoding_plain {
    unsupported("Only PLAIN dictionary pages are supported right now")
  }
  let (values, _) = decode_plain_values(
    data,
    payload_offset,
    column,
    header.num_values,
  )
  values
}

///|
fn decode_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Value] raise ParquetError {
  if chunk.meta_data.codec != codec_uncompressed {
    unsupported("Only UNCOMPRESSED parquet pages are supported right now")
  }
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Value] = []
  let mut dictionary : Array[Value]? = None
  while values.length() < target_values {
    let (page_header, page_header_len) = read_page_header(data, offset)
    let payload_offset = offset + page_header_len
    if page_header.page_type == page_type_data_page {
      match page_header.data_page {
        Some(data_page) =>
          values.append(
            decode_data_page_v1(
              data, payload_offset, data_page, column, dictionary,
            ),
          )
        None => invalid_data("DATA_PAGE without data_page_header")
      }
    } else if page_header.page_type == page_type_data_page_v2 {
      match page_header.data_page_v2 {
        Some(data_page_v2) =>
          values.append(
            decode_data_page_v2(
              data, payload_offset, data_page_v2, column, dictionary,
            ),
          )
        None => invalid_data("DATA_PAGE_V2 without data_page_header_v2")
      }
    } else if page_header.page_type == page_type_dictionary_page {
      match page_header.dictionary_page {
        Some(dictionary_header) =>
          dictionary = Some(
            decode_dictionary_page(
              data, payload_offset, dictionary_header, column,
            ),
          )
        None => invalid_data("DICTIONARY_PAGE without dictionary_page_header")
      }
    } else {
      unsupported("Unsupported page type: \{page_header.page_type}")
    }
    offset = payload_offset + page_header.compressed_page_size
  }
  if values.length() != target_values {
    invalid_data("Decoded value count does not match column metadata")
  }
  values
}

///|
fn build_rows(
  columns : Array[LeafColumnMeta],
  column_values : Array[Array[Value]],
  row_count : Int,
) -> Array[Array[Value]] raise ParquetError {
  let rows : Array[Array[Value]] = []
  for row_index in 0..<row_count {
    let row : Array[Value] = []
    for column_index in 0..<columns.length() {
      match column_values[column_index].get(row_index) {
        Some(value) => row.push(value)
        None => invalid_data("Column length mismatch while assembling rows")
      }
    }
    rows.push(row)
  }
  rows
}

///|
fn check_magic(data : Bytes) -> Unit raise ParquetError {
  if data.length() < 12 {
    invalid_data("Parquet file is too short")
  }
  if data[0] != parquet_magic_0 ||
    data[1] != parquet_magic_1 ||
    data[2] != parquet_magic_2 ||
    data[3] != parquet_magic_3 {
    invalid_data("Missing parquet header magic")
  }
  let end = data.length() - 4
  if data[end] != parquet_magic_0 ||
    data[end + 1] != parquet_magic_1 ||
    data[end + 2] != parquet_magic_2 ||
    data[end + 3] != parquet_magic_3 {
    invalid_data("Missing parquet footer magic")
  }
}

///|
fn decode_parquet(data : Bytes) -> ParquetFile raise ParquetError {
  check_magic(data)
  let footer_len = read_u32_le(data, data.length() - 8)
  let footer_start = data.length() - 8 - footer_len
  if footer_start < 4 {
    invalid_data("Invalid parquet footer length")
  }
  let metadata = read_file_metadata(data, footer_start, footer_len)
  let leaf_columns = build_leaf_columns(metadata.schema)
  let all_rows : Array[Array[Value]] = []
  for row_group in metadata.row_groups {
    if row_group.columns.length() != leaf_columns.length() {
      invalid_data("RowGroup column count does not match schema leaf count")
    }
    let column_values : Array[Array[Value]] = []
    for column_index in 0..<leaf_columns.length() {
      column_values.push(
        decode_column_chunk(
          data,
          row_group.columns[column_index],
          leaf_columns[column_index],
        ),
      )
    }
    all_rows.append(
      build_rows(leaf_columns, column_values, row_group.num_rows.to_int()),
    )
  }
  {
    columns: leaf_columns.map(fn(column) {
      {
        name: column.name,
        column_type: column.column_type,
        repetition: column.repetition,
      }
    }),
    rows: all_rows,
    created_by: metadata.created_by,
  }
}
