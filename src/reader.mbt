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
fn push_null_values(target : Array[Value], count : Int) -> Unit {
  for _ in 0..<count {
    target.push(Null)
  }
}

///|
fn append_decoded_values(
  target : Array[Value],
  decoded_values : Array[Value],
  start : Int,
  count : Int,
) -> Int raise ParquetError {
  if start + count > decoded_values.length() {
    invalid_data("Decoded value count does not match definition levels")
  }
  for index in 0..<count {
    target.push(decoded_values[start + index])
  }
  start + count
}

///|
fn count_boolean_levels_range_non_null(
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
) -> Int raise ParquetError {
  let mut offset = start
  let mut produced = 0
  let mut non_null_count = 0
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
        } else if masked != 0 {
          non_null_count += popcount_low_bits(masked, bits_to_take)
        }
        run_index += bits_to_take
      }
      offset += groups
      produced += values_to_take
    }
  }
  non_null_count
}

///|
fn count_levels_range_non_null(
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
) -> Int raise ParquetError {
  if max_level == 0 {
    return count
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    return count_boolean_levels_range_non_null(
      data, start, end, max_level, count,
    )
  }
  let mut offset = start
  let mut produced = 0
  let mut non_null_count = 0
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
      for _ in 0..<values_to_take {
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
        if unpacked.to_int() == max_level {
          non_null_count += 1
        }
        let next_shift = shift + bit_width
        byte_index += next_shift >> 3
        shift = next_shift & 7
      }
      offset += byte_len
      produced += values_to_take
    }
  }
  non_null_count
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
fn append_optional_values_from_boolean_levels_range(
  target : Array[Value],
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  decoded_values : Array[Value],
  non_null_count : Int,
) -> Unit raise ParquetError {
  if decoded_values.length() != non_null_count {
    invalid_data("Decoded value count does not match definition levels")
  }
  let mut offset = start
  let mut produced = 0
  let mut value_index = 0
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
        value_index = append_decoded_values(
          target, decoded_values, value_index, values_to_take,
        )
      } else {
        push_null_values(target, values_to_take)
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
          value_index = append_decoded_values(
            target, decoded_values, value_index, bits_to_take,
          )
        } else if masked == 0 {
          push_null_values(target, bits_to_take)
        } else {
          for bit_index in 0..<bits_to_take {
            if ((masked >> bit_index) & 1) == max_level {
              value_index = append_decoded_values(
                target, decoded_values, value_index, 1,
              )
            } else {
              target.push(Null)
            }
          }
        }
        run_index += bits_to_take
      }
      offset += groups
      produced += values_to_take
    }
  }
  if value_index != non_null_count {
    invalid_data("Decoded value count does not match definition levels")
  }
}

///|
fn append_optional_values_from_levels_range(
  target : Array[Value],
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  decoded_values : Array[Value],
  non_null_count : Int,
) -> Unit raise ParquetError {
  if max_level == 0 {
    target.append(decoded_values)
    return
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    append_optional_values_from_boolean_levels_range(
      target, data, start, end, max_level, count, decoded_values, non_null_count,
    )
    return
  }
  if decoded_values.length() != non_null_count {
    invalid_data("Decoded value count does not match definition levels")
  }
  let mut offset = start
  let mut produced = 0
  let mut value_index = 0
  let mask = bit_mask_u64(bit_width)
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
        value_index = append_decoded_values(
          target, decoded_values, value_index, values_to_take,
        )
      } else {
        push_null_values(target, values_to_take)
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
      for _ in 0..<values_to_take {
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
        if unpacked.to_int() == max_level {
          value_index = append_decoded_values(
            target, decoded_values, value_index, 1,
          )
        } else {
          target.push(Null)
        }
        let next_shift = shift + bit_width
        byte_index += next_shift >> 3
        shift = next_shift & 7
      }
      offset += byte_len
      produced += values_to_take
    }
  }
  if value_index != non_null_count {
    invalid_data("Decoded value count does not match definition levels")
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
  let definition_offset = payload_offset
  let definition_len = if column.max_definition_level == 0 {
    0
  } else {
    4 + read_u32_le(data, definition_offset)
  }
  let value_offset = definition_offset + definition_len
  if column.max_definition_level == 0 {
    ignore(
      decode_non_null_values_into(
        values,
        data,
        value_offset,
        header.encoding,
        column,
        header.num_values,
        dictionary,
      ),
    )
    return
  }
  let level_start = definition_offset + 4
  let level_end = definition_offset + definition_len
  let non_null_count = count_levels_range_non_null(
    data,
    level_start,
    level_end,
    column.max_definition_level,
    header.num_values,
  )
  if non_null_count == 0 {
    push_null_values(values, header.num_values)
    return
  }
  if non_null_count == header.num_values {
    ignore(
      decode_non_null_values_into(
        values,
        data,
        value_offset,
        header.encoding,
        column,
        non_null_count,
        dictionary,
      ),
    )
    return
  }
  let (decoded_values, _) = decode_non_null_values(
    data,
    value_offset,
    header.encoding,
    column,
    non_null_count,
    dictionary,
  )
  append_optional_values_from_levels_range(
    values,
    data,
    level_start,
    level_end,
    column.max_definition_level,
    header.num_values,
    decoded_values,
    non_null_count,
  )
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
  if column.max_definition_level == 0 ||
    header.definition_levels_byte_length == 0 {
    ignore(
      decode_non_null_values_into(
        values,
        value_data,
        value_offset,
        header.encoding,
        column,
        header.num_values,
        dictionary,
      ),
    )
    return
  }
  let definition_offset = payload_offset
  let definition_end = definition_offset + header.definition_levels_byte_length
  let non_null_count = count_levels_range_non_null(
    level_data,
    definition_offset,
    definition_end,
    column.max_definition_level,
    header.num_values,
  )
  if non_null_count == 0 {
    push_null_values(values, header.num_values)
    return
  }
  if non_null_count == header.num_values {
    ignore(
      decode_non_null_values_into(
        values,
        value_data,
        value_offset,
        header.encoding,
        column,
        non_null_count,
        dictionary,
      ),
    )
    return
  }
  let (decoded_values, _) = decode_non_null_values(
    value_data,
    value_offset,
    header.encoding,
    column,
    non_null_count,
    dictionary,
  )
  append_optional_values_from_levels_range(
    values,
    level_data,
    definition_offset,
    definition_end,
    column.max_definition_level,
    header.num_values,
    decoded_values,
    non_null_count,
  )
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
