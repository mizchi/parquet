///|
priv struct DecodedLevels {
  levels : Array[Int]?
  non_null_count : Int
}

///|
fn materialize_defined_prefix(
  max_level : Int,
  count : Int,
  capacity : Int,
) -> Array[Int] {
  let levels : Array[Int] = Array::new(capacity~)
  for _ in 0..<count {
    levels.push(max_level)
  }
  levels
}

///|
fn append_repeated_levels(
  levels : Array[Int],
  value : Int,
  count : Int,
) -> Unit {
  for _ in 0..<count {
    levels.push(value)
  }
}

///|
fn popcount_low_bits(value : Int, bit_count : Int) -> Int {
  let mask = if bit_count >= 8 { 0xff } else { (1 << bit_count) - 1 }
  let mut bits = value & mask
  let mut count = 0
  while bits != 0 {
    bits = bits & (bits - 1)
    count += 1
  }
  count
}

///|
fn append_level_value(
  levels : Array[Int]?,
  value : Int,
  max_level : Int,
  produced : Int,
  run_index : Int,
  capacity : Int,
) -> Array[Int]? {
  match levels {
    Some(existing) => {
      existing.push(value)
      Some(existing)
    }
    None =>
      if value == max_level {
        None
      } else {
        let materialized = materialize_defined_prefix(
          max_level,
          produced + run_index,
          capacity,
        )
        materialized.push(value)
        Some(materialized)
      }
  }
}

///|
fn decode_boolean_levels_range_info(
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
) -> DecodedLevels raise ParquetError {
  let mut offset = start
  let mut produced = 0
  let mut non_null_count = 0
  let mut levels : Array[Int]? = None
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let repeated = data[offset].to_int() & 1
      offset += 1
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        non_null_count += values_to_take
      }
      match levels {
        Some(existing) =>
          append_repeated_levels(existing, repeated, values_to_take)
        None =>
          if repeated != max_level {
            let materialized = materialize_defined_prefix(
              max_level, produced, count,
            )
            append_repeated_levels(materialized, repeated, values_to_take)
            levels = Some(materialized)
          }
      }
      produced += values_to_take
    } else {
      let groups = header >> 1
      let group_values = groups * 8
      let values_to_take = if count - produced < group_values {
        count - produced
      } else {
        group_values
      }
      let mut run_index = 0
      for byte_offset in 0..<groups {
        if run_index >= values_to_take {
          break
        }
        let packed = data[offset + byte_offset].to_int()
        let remaining = values_to_take - run_index
        let bits_to_take = if remaining < 8 { remaining } else { 8 }
        let full_mask = if bits_to_take == 8 {
          0xff
        } else {
          (1 << bits_to_take) - 1
        }
        let masked = packed & full_mask
        if masked == full_mask {
          non_null_count += bits_to_take
          match levels {
            Some(existing) =>
              append_repeated_levels(existing, max_level, bits_to_take)
            None => ()
          }
        } else if masked == 0 {
          match levels {
            Some(existing) => append_repeated_levels(existing, 0, bits_to_take)
            None => {
              let materialized = materialize_defined_prefix(
                max_level,
                produced + run_index,
                count,
              )
              append_repeated_levels(materialized, 0, bits_to_take)
              levels = Some(materialized)
            }
          }
        } else {
          non_null_count += popcount_low_bits(masked, bits_to_take)
          let level_values = match levels {
            Some(existing) => existing
            None => {
              let materialized = materialize_defined_prefix(
                max_level,
                produced + run_index,
                count,
              )
              levels = Some(materialized)
              materialized
            }
          }
          for bit_index in 0..<bits_to_take {
            level_values.push((masked >> bit_index) & 1)
          }
        }
        run_index += bits_to_take
      }
      offset += groups
      produced += values_to_take
    }
  }
  { levels, non_null_count }
}

///|
fn decode_levels_range_info(
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
) -> DecodedLevels raise ParquetError {
  if max_level == 0 {
    return { levels: None, non_null_count: count }
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    return decode_boolean_levels_range_info(data, start, end, max_level, count)
  }
  let mut offset = start
  let mut produced = 0
  let mut non_null_count = 0
  let mut levels : Array[Int]? = None
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let byte_width = ceil_div(bit_width, 8)
      let mut repeated = 0
      for i in 0..<byte_width {
        repeated = repeated | (data[offset + i].to_int() << (i * 8))
      }
      offset += byte_width
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        non_null_count += values_to_take
      }
      match levels {
        Some(existing) =>
          for _ in 0..<values_to_take {
            existing.push(repeated)
          }
        None =>
          if repeated != max_level {
            let materialized = materialize_defined_prefix(
              max_level, produced, count,
            )
            for _ in 0..<values_to_take {
              materialized.push(repeated)
            }
            levels = Some(materialized)
          }
      }
      produced += values_to_take
    } else {
      let groups = header >> 1
      let group_values = groups * 8
      let byte_len = ceil_div(group_values * bit_width, 8)
      let values_to_take = if count - produced < group_values {
        count - produced
      } else {
        group_values
      }
      let mut byte_index = offset
      let mut shift = 0
      let mask = bit_mask_u64(bit_width)
      for run_index in 0..<values_to_take {
        let low = if byte_index + 8 <= data.length() {
          data.unsafe_read_uint64_le(byte_index) >> shift
        } else {
          read_partial_u64_le(data, byte_index) >> shift
        }
        let spill_bits = shift + bit_width - 64
        let unpacked = if spill_bits > 0 {
          let high_byte = if byte_index + 8 < data.length() {
            data[byte_index + 8].to_uint64()
          } else {
            UInt64::default()
          }
          low | ((high_byte & bit_mask_u64(spill_bits)) << (64 - shift))
        } else {
          low & mask
        }
        let level = unpacked.to_int()
        if level == max_level {
          non_null_count += 1
        }
        levels = append_level_value(
          levels, level, max_level, produced, run_index, count,
        )
        let next_shift = shift + bit_width
        byte_index += next_shift >> 3
        shift = next_shift & 7
      }
      offset += byte_len
      produced += values_to_take
    }
  }
  { levels, non_null_count }
}

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
fn decode_levels_v1_info(
  data : Bytes,
  start : Int,
  max_level : Int,
  count : Int,
) -> (DecodedLevels, Int) raise ParquetError {
  if max_level == 0 {
    ({ levels: None, non_null_count: count }, 0)
  } else {
    let encoded_len = read_u32_le(data, start)
    let level_start = start + 4
    let info = decode_levels_range_info(
      data,
      level_start,
      level_start + encoded_len,
      max_level,
      count,
    )
    (info, 4 + encoded_len)
  }
}

///|
fn decode_levels_v2_info(
  data : Bytes,
  start : Int,
  len : Int,
  max_level : Int,
  count : Int,
) -> DecodedLevels raise ParquetError {
  if max_level == 0 || len == 0 {
    { levels: None, non_null_count: count }
  } else {
    decode_levels_range_info(data, start, start + len, max_level, count)
  }
}

///|
fn append_optional_values(
  target : Array[Value],
  definition_levels : Array[Int],
  max_definition_level : Int,
  decoded_values : Array[Value],
  non_null_count : Int,
) -> Unit raise ParquetError {
  if decoded_values.length() != non_null_count {
    invalid_data("Decoded value count does not match definition levels")
  }
  let mut value_index = 0
  for level in definition_levels {
    if level == max_definition_level {
      target.push(decoded_values[value_index])
      value_index += 1
    } else {
      target.push(Null)
    }
  }
}

///|
fn decode_data_page_v1(
  values : Array[Value],
  data : Bytes,
  payload_offset : Int,
  header : DataPageHeaderMeta,
  column : LeafColumnMeta,
  dictionary : Array[Value]?,
) -> Unit raise ParquetError {
  if column.max_repetition_level > 0 {
    unsupported("Repeated columns are not supported yet")
  }
  let repetition_len = 0
  let definition_offset = payload_offset + repetition_len
  let (definition_info, definition_len) = decode_levels_v1_info(
    data,
    definition_offset,
    column.max_definition_level,
    header.num_values,
  )
  let non_null_count = definition_info.non_null_count
  let value_offset = definition_offset + definition_len
  let (decoded_values, _) = decode_non_null_values(
    data,
    value_offset,
    header.encoding,
    column,
    non_null_count,
    dictionary,
  )
  match definition_info.levels {
    None => values.append(decoded_values)
    Some(definition_levels) =>
      append_optional_values(
        values,
        definition_levels,
        column.max_definition_level,
        decoded_values,
        non_null_count,
      )
  }
}

///|
fn decode_data_page_v2(
  values : Array[Value],
  level_data : Bytes,
  payload_offset : Int,
  header : DataPageHeaderV2Meta,
  column : LeafColumnMeta,
  dictionary : Array[Value]?,
  value_data : Bytes,
  value_offset : Int,
) -> Unit raise ParquetError {
  if column.max_repetition_level > 0 {
    unsupported("Repeated columns are not supported yet")
  }
  let definition_offset = payload_offset
  let definition_info = decode_levels_v2_info(
    level_data,
    definition_offset,
    header.definition_levels_byte_length,
    column.max_definition_level,
    header.num_values,
  )
  let non_null_count = definition_info.non_null_count
  let (decoded_values, _) = decode_non_null_values(
    value_data,
    value_offset,
    header.encoding,
    column,
    non_null_count,
    dictionary,
  )
  match definition_info.levels {
    None => values.append(decoded_values)
    Some(definition_levels) =>
      append_optional_values(
        values,
        definition_levels,
        column.max_definition_level,
        decoded_values,
        non_null_count,
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
  if header.encoding != encoding_plain &&
    header.encoding != encoding_plain_dictionary {
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
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Value] = Array::new(capacity=target_values)
  let mut dictionary : Array[Value]? = None
  while values.length() < target_values {
    let (page_header, page_header_len) = read_page_header(data, offset)
    let payload_offset = offset + page_header_len
    if page_header.page_type == page_type_data_page {
      let payload = if chunk.meta_data.codec == codec_uncompressed {
        data
      } else {
        decompress_page_payload(
          data,
          payload_offset,
          page_header.compressed_page_size,
          page_header.uncompressed_page_size,
          chunk.meta_data.codec,
        )
      }
      let page_data_offset = if chunk.meta_data.codec == codec_uncompressed {
        payload_offset
      } else {
        0
      }
      match page_header.data_page {
        Some(data_page) =>
          decode_data_page_v1(
            values, payload, page_data_offset, data_page, column, dictionary,
          )
        None => invalid_data("DATA_PAGE without data_page_header")
      }
    } else if page_header.page_type == page_type_data_page_v2 {
      match page_header.data_page_v2 {
        Some(data_page_v2) => {
          let value_offset = payload_offset +
            data_page_v2.repetition_levels_byte_length +
            data_page_v2.definition_levels_byte_length
          let compressed_value_len = page_header.compressed_page_size -
            data_page_v2.repetition_levels_byte_length -
            data_page_v2.definition_levels_byte_length
          let uncompressed_value_len = page_header.uncompressed_page_size -
            data_page_v2.repetition_levels_byte_length -
            data_page_v2.definition_levels_byte_length
          let (value_data, value_data_offset) = if data_page_v2.is_compressed &&
            chunk.meta_data.codec != codec_uncompressed {
            if compressed_value_len == 0 {
              (Bytes::default(), 0)
            } else {
              (
                decompress_page_payload(
                  data,
                  value_offset,
                  compressed_value_len,
                  uncompressed_value_len,
                  chunk.meta_data.codec,
                ),
                0,
              )
            }
          } else {
            (data, value_offset)
          }
          decode_data_page_v2(
            values, data, payload_offset, data_page_v2, column, dictionary, value_data,
            value_data_offset,
          )
        }
        None => invalid_data("DATA_PAGE_V2 without data_page_header_v2")
      }
    } else if page_header.page_type == page_type_dictionary_page {
      let payload = if chunk.meta_data.codec == codec_uncompressed {
        data
      } else {
        decompress_page_payload(
          data,
          payload_offset,
          page_header.compressed_page_size,
          page_header.uncompressed_page_size,
          chunk.meta_data.codec,
        )
      }
      let page_data_offset = if chunk.meta_data.codec == codec_uncompressed {
        payload_offset
      } else {
        0
      }
      match page_header.dictionary_page {
        Some(dictionary_header) =>
          dictionary = Some(
            decode_dictionary_page(
              payload, page_data_offset, dictionary_header, column,
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
  let column_count = columns.length()
  for column_index in 0..<column_count {
    if column_values[column_index].length() != row_count {
      invalid_data("Column length mismatch while assembling rows")
    }
  }
  let rows : Array[Array[Value]] = Array::new(capacity=row_count)
  for row_index in 0..<row_count {
    let row : Array[Value] = Array::new(capacity=column_count)
    for column_index in 0..<column_count {
      row.push(column_values[column_index][row_index])
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
