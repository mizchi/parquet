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
fn[T] push_none_values(target : Array[T?], count : Int) -> Unit {
  for _ in 0..<count {
    target.push(None)
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
fn[T] append_decoded_option_values(
  target : Array[T?],
  decoded_values : Array[T],
  start : Int,
  count : Int,
) -> Int raise ParquetError {
  if start + count > decoded_values.length() {
    invalid_data("Decoded value count does not match definition levels")
  }
  for index in 0..<count {
    target.push(Some(decoded_values[start + index]))
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
fn[T] append_optional_option_values_from_boolean_levels_range(
  target : Array[T?],
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  decoded_values : Array[T],
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
        value_index = append_decoded_option_values(
          target, decoded_values, value_index, values_to_take,
        )
      } else {
        push_none_values(target, values_to_take)
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
          value_index = append_decoded_option_values(
            target, decoded_values, value_index, bits_to_take,
          )
        } else if masked == 0 {
          push_none_values(target, bits_to_take)
        } else {
          for bit_index in 0..<bits_to_take {
            if ((masked >> bit_index) & 1) == max_level {
              value_index = append_decoded_option_values(
                target, decoded_values, value_index, 1,
              )
            } else {
              target.push(None)
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
fn append_optional_dictionary_values_from_boolean_levels_range(
  target : Array[Value],
  level_data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  cursor : DictionaryValueCursor,
  dictionary_values : Array[Value],
) -> Unit raise ParquetError {
  let mut offset = start
  let mut produced = 0
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(level_data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let repeated = level_data[offset].to_int() & 1
      offset += 1
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        cursor.append_into(target, values_to_take, dictionary_values)
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
        let packed = level_data[offset + byte_offset].to_int()
        let remaining = values_to_take - run_index
        let bits_to_take = if remaining < 8 { remaining } else { 8 }
        let full_mask = if bits_to_take == 8 {
          0xff
        } else {
          (1 << bits_to_take) - 1
        }
        let masked = packed & full_mask
        if masked == full_mask {
          cursor.append_into(target, bits_to_take, dictionary_values)
        } else if masked == 0 {
          push_null_values(target, bits_to_take)
        } else {
          let mut defined_run = 0
          for bit_index in 0..<bits_to_take {
            if ((masked >> bit_index) & 1) == max_level {
              defined_run += 1
            } else {
              if defined_run > 0 {
                cursor.append_into(target, defined_run, dictionary_values)
                defined_run = 0
              }
              target.push(Null)
            }
          }
          if defined_run > 0 {
            cursor.append_into(target, defined_run, dictionary_values)
          }
        }
        run_index += bits_to_take
      }
      offset += groups
      produced += values_to_take
    }
  }
}

///|
fn append_optional_plain_values_from_boolean_levels_range(
  target : Array[Value],
  level_data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  value_data : Bytes,
  value_offset : Int,
  column : LeafColumnMeta,
) -> Unit raise ParquetError {
  let mut offset = start
  let mut produced = 0
  let mut value_offset = value_offset
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(level_data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let repeated = level_data[offset].to_int() & 1
      offset += 1
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        value_offset += decode_plain_values_into(
          target, value_data, value_offset, column, values_to_take,
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
        let packed = level_data[offset + byte_offset].to_int()
        let remaining = values_to_take - run_index
        let bits_to_take = if remaining < 8 { remaining } else { 8 }
        let full_mask = if bits_to_take == 8 {
          0xff
        } else {
          (1 << bits_to_take) - 1
        }
        let masked = packed & full_mask
        if masked == full_mask {
          value_offset += decode_plain_values_into(
            target, value_data, value_offset, column, bits_to_take,
          )
        } else if masked == 0 {
          push_null_values(target, bits_to_take)
        } else {
          let mut defined_run = 0
          for bit_index in 0..<bits_to_take {
            if ((masked >> bit_index) & 1) == max_level {
              defined_run += 1
            } else {
              if defined_run > 0 {
                value_offset += decode_plain_values_into(
                  target, value_data, value_offset, column, defined_run,
                )
                defined_run = 0
              }
              target.push(Null)
            }
          }
          if defined_run > 0 {
            value_offset += decode_plain_values_into(
              target, value_data, value_offset, column, defined_run,
            )
          }
        }
        run_index += bits_to_take
      }
      offset += groups
      produced += values_to_take
    }
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
fn[T] append_optional_option_values_from_levels_range(
  target : Array[T?],
  data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  decoded_values : Array[T],
  non_null_count : Int,
) -> Unit raise ParquetError {
  if max_level == 0 {
    for value in decoded_values {
      target.push(Some(value))
    }
    return
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    append_optional_option_values_from_boolean_levels_range(
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
        value_index = append_decoded_option_values(
          target, decoded_values, value_index, values_to_take,
        )
      } else {
        push_none_values(target, values_to_take)
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
          value_index = append_decoded_option_values(
            target, decoded_values, value_index, 1,
          )
        } else {
          target.push(None)
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
fn append_optional_dictionary_values_from_levels_range(
  target : Array[Value],
  level_data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  cursor : DictionaryValueCursor,
  dictionary_values : Array[Value],
) -> Unit raise ParquetError {
  if max_level == 0 {
    cursor.append_into(target, count, dictionary_values)
    return
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    append_optional_dictionary_values_from_boolean_levels_range(
      target, level_data, start, end, max_level, count, cursor, dictionary_values,
    )
    return
  }
  let mut offset = start
  let mut produced = 0
  let mask = bit_mask_u64(bit_width)
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(level_data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let byte_width = ceil_div(bit_width, 8)
      let mut repeated = 0
      for i in 0..<byte_width {
        repeated = repeated | (level_data[offset + i].to_int() << (i * 8))
      }
      offset += byte_width
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        cursor.append_into(target, values_to_take, dictionary_values)
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
      let mut defined_run = 0
      for _ in 0..<values_to_take {
        let low = if byte_index + 8 <= level_data.length() {
          level_data.unsafe_read_uint64_le(byte_index) >> shift
        } else {
          read_partial_u64_le(level_data, byte_index) >> shift
        }
        let spill_bits = shift + bit_width - 64
        let unpacked = if spill_bits > 0 {
          let high_byte = if byte_index + 8 < level_data.length() {
            level_data[byte_index + 8].to_uint64()
          } else {
            UInt64::default()
          }
          low | ((high_byte & bit_mask_u64(spill_bits)) << (64 - shift))
        } else {
          low & mask
        }
        if unpacked.to_int() == max_level {
          defined_run += 1
        } else {
          if defined_run > 0 {
            cursor.append_into(target, defined_run, dictionary_values)
            defined_run = 0
          }
          target.push(Null)
        }
        let next_shift = shift + bit_width
        byte_index += next_shift >> 3
        shift = next_shift & 7
      }
      if defined_run > 0 {
        cursor.append_into(target, defined_run, dictionary_values)
      }
      offset += byte_len
      produced += values_to_take
    }
  }
}

///|
fn append_optional_delta_byte_array_values_from_boolean_levels_range(
  target : Array[Value],
  level_data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  cursor : DeltaByteArrayValueCursor,
  column_type : ColumnType,
) -> Unit raise ParquetError {
  let mut offset = start
  let mut produced = 0
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(level_data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let repeated = level_data[offset].to_int() & 1
      offset += 1
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        cursor.append_into(target, values_to_take, column_type)
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
        let packed = level_data[offset + byte_offset].to_int()
        let remaining = values_to_take - run_index
        let bits_to_take = if remaining < 8 { remaining } else { 8 }
        let full_mask = if bits_to_take == 8 {
          0xff
        } else {
          (1 << bits_to_take) - 1
        }
        let masked = packed & full_mask
        if masked == full_mask {
          cursor.append_into(target, bits_to_take, column_type)
        } else if masked == 0 {
          push_null_values(target, bits_to_take)
        } else {
          let mut defined_run = 0
          for bit_index in 0..<bits_to_take {
            if ((masked >> bit_index) & 1) == max_level {
              defined_run += 1
            } else {
              if defined_run > 0 {
                cursor.append_into(target, defined_run, column_type)
                defined_run = 0
              }
              target.push(Null)
            }
          }
          if defined_run > 0 {
            cursor.append_into(target, defined_run, column_type)
          }
        }
        run_index += bits_to_take
      }
      offset += groups
      produced += values_to_take
    }
  }
}

///|
fn append_optional_delta_byte_array_values_from_levels_range(
  target : Array[Value],
  level_data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  cursor : DeltaByteArrayValueCursor,
  column_type : ColumnType,
) -> Unit raise ParquetError {
  if max_level == 0 {
    cursor.append_into(target, count, column_type)
    return
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    append_optional_delta_byte_array_values_from_boolean_levels_range(
      target, level_data, start, end, max_level, count, cursor, column_type,
    )
    return
  }
  let mut offset = start
  let mut produced = 0
  let mask = bit_mask_u64(bit_width)
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(level_data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let byte_width = ceil_div(bit_width, 8)
      let mut repeated = 0
      for i in 0..<byte_width {
        repeated = repeated | (level_data[offset + i].to_int() << (i * 8))
      }
      offset += byte_width
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        cursor.append_into(target, values_to_take, column_type)
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
      let mut defined_run = 0
      for _ in 0..<values_to_take {
        let low = if byte_index + 8 <= level_data.length() {
          level_data.unsafe_read_uint64_le(byte_index) >> shift
        } else {
          read_partial_u64_le(level_data, byte_index) >> shift
        }
        let spill_bits = shift + bit_width - 64
        let unpacked = if spill_bits > 0 {
          let high_byte = if byte_index + 8 < level_data.length() {
            level_data[byte_index + 8].to_uint64()
          } else {
            UInt64::default()
          }
          low | ((high_byte & bit_mask_u64(spill_bits)) << (64 - shift))
        } else {
          low & mask
        }
        if unpacked.to_int() == max_level {
          defined_run += 1
        } else {
          if defined_run > 0 {
            cursor.append_into(target, defined_run, column_type)
            defined_run = 0
          }
          target.push(Null)
        }
        let next_shift = shift + bit_width
        byte_index += next_shift >> 3
        shift = next_shift & 7
      }
      if defined_run > 0 {
        cursor.append_into(target, defined_run, column_type)
      }
      offset += byte_len
      produced += values_to_take
    }
  }
}

///|
fn append_optional_plain_values_from_levels_range(
  target : Array[Value],
  level_data : Bytes,
  start : Int,
  end : Int,
  max_level : Int,
  count : Int,
  value_data : Bytes,
  value_offset : Int,
  column : LeafColumnMeta,
) -> Unit raise ParquetError {
  if max_level == 0 {
    ignore(
      decode_plain_values_into(target, value_data, value_offset, column, count),
    )
    return
  }
  let bit_width = bit_width(max_level)
  if bit_width == 1 {
    append_optional_plain_values_from_boolean_levels_range(
      target, level_data, start, end, max_level, count, value_data, value_offset,
      column,
    )
    return
  }
  let mut offset = start
  let mut produced = 0
  let mut value_offset = value_offset
  let mask = bit_mask_u64(bit_width)
  while produced < count && offset < end {
    let (header, header_len) = read_varint32_at(level_data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let byte_width = ceil_div(bit_width, 8)
      let mut repeated = 0
      for i in 0..<byte_width {
        repeated = repeated | (level_data[offset + i].to_int() << (i * 8))
      }
      offset += byte_width
      let values_to_take = if count - produced < run_len {
        count - produced
      } else {
        run_len
      }
      if repeated == max_level {
        value_offset += decode_plain_values_into(
          target, value_data, value_offset, column, values_to_take,
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
      let mut defined_run = 0
      for _ in 0..<values_to_take {
        let low = if byte_index + 8 <= level_data.length() {
          level_data.unsafe_read_uint64_le(byte_index) >> shift
        } else {
          read_partial_u64_le(level_data, byte_index) >> shift
        }
        let spill_bits = shift + bit_width - 64
        let unpacked = if spill_bits > 0 {
          let high_byte = if byte_index + 8 < level_data.length() {
            level_data[byte_index + 8].to_uint64()
          } else {
            UInt64::default()
          }
          low | ((high_byte & bit_mask_u64(spill_bits)) << (64 - shift))
        } else {
          low & mask
        }
        if unpacked.to_int() == max_level {
          defined_run += 1
        } else {
          if defined_run > 0 {
            value_offset += decode_plain_values_into(
              target, value_data, value_offset, column, defined_run,
            )
            defined_run = 0
          }
          target.push(Null)
        }
        let next_shift = shift + bit_width
        byte_index += next_shift >> 3
        shift = next_shift & 7
      }
      if defined_run > 0 {
        value_offset += decode_plain_values_into(
          target, value_data, value_offset, column, defined_run,
        )
      }
      offset += byte_len
      produced += values_to_take
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
  if header.encoding == encoding_plain && column.column_type != Boolean {
    append_optional_plain_values_from_levels_range(
      values,
      data,
      level_start,
      level_end,
      column.max_definition_level,
      header.num_values,
      data,
      value_offset,
      column,
    )
    return
  }
  if header.encoding == encoding_plain_dictionary ||
    header.encoding == encoding_rle_dictionary {
    match dictionary {
      Some(dictionary_values) => {
        let cursor = DictionaryValueCursor::new(data, value_offset)
        append_optional_dictionary_values_from_levels_range(
          values,
          data,
          level_start,
          level_end,
          column.max_definition_level,
          header.num_values,
          cursor,
          dictionary_values,
        )
        return
      }
      None => {
        invalid_data("Dictionary encoded page without dictionary page")
        return
      }
    }
  }
  if header.encoding == encoding_delta_byte_array {
    match column.column_type {
      String | Binary => {
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
        let cursor = DeltaByteArrayValueCursor::new(
          data, value_offset, non_null_count,
        )
        append_optional_delta_byte_array_values_from_levels_range(
          values,
          data,
          level_start,
          level_end,
          column.max_definition_level,
          header.num_values,
          cursor,
          column.column_type,
        )
        return
      }
      _ => ()
    }
  }
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
  if header.encoding == encoding_plain && column.column_type != Boolean {
    append_optional_plain_values_from_levels_range(
      values,
      level_data,
      definition_offset,
      definition_end,
      column.max_definition_level,
      header.num_values,
      value_data,
      value_offset,
      column,
    )
    return
  }
  if header.encoding == encoding_plain_dictionary ||
    header.encoding == encoding_rle_dictionary {
    match dictionary {
      Some(dictionary_values) => {
        let cursor = DictionaryValueCursor::new(value_data, value_offset)
        append_optional_dictionary_values_from_levels_range(
          values,
          level_data,
          definition_offset,
          definition_end,
          column.max_definition_level,
          header.num_values,
          cursor,
          dictionary_values,
        )
        return
      }
      None => {
        invalid_data("Dictionary encoded page without dictionary page")
        return
      }
    }
  }
  if header.encoding == encoding_delta_byte_array {
    match column.column_type {
      String | Binary => {
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
        let cursor = DeltaByteArrayValueCursor::new(
          value_data, value_offset, non_null_count,
        )
        append_optional_delta_byte_array_values_from_levels_range(
          values,
          level_data,
          definition_offset,
          definition_end,
          column.max_definition_level,
          header.num_values,
          cursor,
          column.column_type,
        )
        return
      }
      _ => ()
    }
  }
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
fn value_to_int32(value : Value) -> Int raise ParquetError {
  match value {
    Int32(v) => v
    _ => {
      invalid_data("Dictionary value type mismatch for INT32 column")
      0
    }
  }
}

///|
fn value_to_int64(
  value : Value,
  column_type : ColumnType,
) -> Int64 raise ParquetError {
  match (column_type, value) {
    (Int64, Int64(v)) => v
    (TimestampMicros, TimestampMicros(v)) => v
    _ => {
      invalid_data("Dictionary value type mismatch for INT64-like column")
      0L
    }
  }
}

///|
fn decode_required_utf8_values_into(
  target : Array[Bytes],
  data : Bytes,
  start : Int,
  encoding : Int,
  count : Int,
) -> Int raise ParquetError {
  if count == 0 {
    return 0
  }
  if encoding == encoding_plain {
    let mut offset = start
    for _ in 0..<count {
      let len = read_u32_le(data, offset)
      offset += 4
      target.push(data.view(start=offset, end=offset + len).to_bytes())
      offset += len
    }
    return offset - start
  }
  if encoding == encoding_delta_byte_array {
    return decode_delta_byte_array_bytes_into(target, data, start, count)
  }
  unsupported("Unsupported required UTF-8 encoding: \{encoding}")
  0
}

///|
fn decode_required_binary_values_into(
  target : Array[Bytes],
  data : Bytes,
  start : Int,
  encoding : Int,
  column : LeafColumnMeta,
  count : Int,
) -> Int raise ParquetError {
  if count == 0 {
    return 0
  }
  if encoding == encoding_plain {
    let mut offset = start
    for _ in 0..<count {
      let len = match column.fixed_length {
        Some(value) => value
        None => {
          let byte_len = read_u32_le(data, offset)
          offset += 4
          byte_len
        }
      }
      target.push(data.view(start=offset, end=offset + len).to_bytes())
      offset += len
    }
    return offset - start
  }
  if encoding == encoding_delta_byte_array {
    return decode_delta_byte_array_bytes_into(target, data, start, count)
  }
  unsupported("Unsupported required binary encoding: \{encoding}")
  0
}

///|
fn decode_required_int32_values_into(
  target : Array[Int],
  data : Bytes,
  start : Int,
  encoding : Int,
  count : Int,
  dictionary : Array[Value]?,
) -> Int raise ParquetError {
  if encoding == encoding_plain {
    let mut offset = start
    for _ in 0..<count {
      target.push(read_i32_le(data, offset))
      offset += 4
    }
    return offset - start
  }
  if encoding == encoding_delta_binary_packed {
    return decode_delta_binary_packed_ints_into(target, data, start, count)
  }
  if encoding == encoding_plain_dictionary ||
    encoding == encoding_rle_dictionary {
    return match dictionary {
      Some(dictionary_values) => {
        let (values, consumed) = decode_dictionary_values(
          data, start, count, dictionary_values,
        )
        for value in values {
          target.push(value_to_int32(value))
        }
        consumed
      }
      None => {
        invalid_data("Dictionary encoded page without dictionary page")
        0
      }
    }
  }
  unsupported("Unsupported required INT32 encoding: \{encoding}")
  0
}

///|
fn decode_required_int64_values_into(
  target : Array[Int64],
  data : Bytes,
  start : Int,
  encoding : Int,
  column_type : ColumnType,
  count : Int,
  dictionary : Array[Value]?,
) -> Int raise ParquetError {
  if encoding == encoding_plain {
    let mut offset = start
    for _ in 0..<count {
      target.push(read_i64_le(data, offset))
      offset += 8
    }
    return offset - start
  }
  if encoding == encoding_delta_binary_packed {
    return decode_delta_binary_packed_int64s_into(target, data, start, count)
  }
  if encoding == encoding_plain_dictionary ||
    encoding == encoding_rle_dictionary {
    return match dictionary {
      Some(dictionary_values) => {
        let (values, consumed) = decode_dictionary_values(
          data, start, count, dictionary_values,
        )
        for value in values {
          target.push(value_to_int64(value, column_type))
        }
        consumed
      }
      None => {
        invalid_data("Dictionary encoded page without dictionary page")
        0
      }
    }
  }
  unsupported("Unsupported required INT64 encoding: \{encoding}")
  0
}

///|
fn decode_required_int32_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Int] raise ParquetError {
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Int] = Array::new(capacity=target_values)
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
        Some(data_page) => {
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let definition_offset = page_data_offset
          let definition_len = if column.max_definition_level == 0 {
            0
          } else {
            4 + read_u32_le(payload, definition_offset)
          }
          let value_offset = definition_offset + definition_len
          if column.max_definition_level > 0 {
            let non_null_count = count_levels_range_non_null(
              payload,
              definition_offset + 4,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
            )
            if non_null_count != data_page.num_values {
              unsupported("Nullable INT32 column contains nulls")
            }
          }
          ignore(
            decode_required_int32_values_into(
              values,
              payload,
              value_offset,
              data_page.encoding,
              data_page.num_values,
              dictionary,
            ),
          )
        }
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
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          if column.max_definition_level > 0 &&
            data_page_v2.definition_levels_byte_length > 0 {
            let definition_offset = payload_offset +
              data_page_v2.repetition_levels_byte_length
            let definition_end = definition_offset +
              data_page_v2.definition_levels_byte_length
            let non_null_count = count_levels_range_non_null(
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
            )
            if non_null_count != data_page_v2.num_values {
              unsupported("Nullable INT32 column contains nulls")
            }
          }
          ignore(
            decode_required_int32_values_into(
              values,
              value_data,
              value_data_offset,
              data_page_v2.encoding,
              data_page_v2.num_values,
              dictionary,
            ),
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
fn decode_required_int64_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Int64] raise ParquetError {
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Int64] = Array::new(capacity=target_values)
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
        Some(data_page) => {
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let definition_offset = page_data_offset
          let definition_len = if column.max_definition_level == 0 {
            0
          } else {
            4 + read_u32_le(payload, definition_offset)
          }
          let value_offset = definition_offset + definition_len
          if column.max_definition_level > 0 {
            let non_null_count = count_levels_range_non_null(
              payload,
              definition_offset + 4,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
            )
            if non_null_count != data_page.num_values {
              unsupported("Nullable INT64 column contains nulls")
            }
          }
          ignore(
            decode_required_int64_values_into(
              values,
              payload,
              value_offset,
              data_page.encoding,
              column.column_type,
              data_page.num_values,
              dictionary,
            ),
          )
        }
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
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          if column.max_definition_level > 0 &&
            data_page_v2.definition_levels_byte_length > 0 {
            let definition_offset = payload_offset +
              data_page_v2.repetition_levels_byte_length
            let definition_end = definition_offset +
              data_page_v2.definition_levels_byte_length
            let non_null_count = count_levels_range_non_null(
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
            )
            if non_null_count != data_page_v2.num_values {
              unsupported("Nullable INT64 column contains nulls")
            }
          }
          ignore(
            decode_required_int64_values_into(
              values,
              value_data,
              value_data_offset,
              data_page_v2.encoding,
              column.column_type,
              data_page_v2.num_values,
              dictionary,
            ),
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
fn decode_required_utf8_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Bytes] raise ParquetError {
  if column.max_definition_level > 0 {
    unsupported("Nullable UTF-8 columns are not supported in typed mode yet")
  }
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Bytes] = Array::new(capacity=target_values)
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
        Some(data_page) => {
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let definition_offset = page_data_offset
          let definition_len = if column.max_definition_level == 0 {
            0
          } else {
            4 + read_u32_le(payload, definition_offset)
          }
          let value_offset = definition_offset + definition_len
          if column.max_definition_level > 0 {
            let non_null_count = count_levels_range_non_null(
              payload,
              definition_offset + 4,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
            )
            if non_null_count != data_page.num_values {
              unsupported("Nullable UTF-8 column contains nulls")
            }
          }
          ignore(
            decode_required_utf8_values_into(
              values,
              payload,
              value_offset,
              data_page.encoding,
              data_page.num_values,
            ),
          )
        }
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
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          if column.max_definition_level > 0 &&
            data_page_v2.definition_levels_byte_length > 0 {
            let definition_offset = payload_offset +
              data_page_v2.repetition_levels_byte_length
            let definition_end = definition_offset +
              data_page_v2.definition_levels_byte_length
            let non_null_count = count_levels_range_non_null(
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
            )
            if non_null_count != data_page_v2.num_values {
              unsupported("Nullable UTF-8 column contains nulls")
            }
          }
          ignore(
            decode_required_utf8_values_into(
              values,
              value_data,
              value_data_offset,
              data_page_v2.encoding,
              data_page_v2.num_values,
            ),
          )
        }
        None => invalid_data("DATA_PAGE_V2 without data_page_header_v2")
      }
    } else if page_header.page_type == page_type_dictionary_page {
      unsupported(
        "Dictionary UTF-8 columns are not supported in typed mode yet",
      )
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
fn decode_required_binary_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Bytes] raise ParquetError {
  if column.max_definition_level > 0 {
    unsupported("Nullable binary columns are not supported in typed mode yet")
  }
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Bytes] = Array::new(capacity=target_values)
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
        Some(data_page) => {
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let definition_offset = page_data_offset
          let definition_len = if column.max_definition_level == 0 {
            0
          } else {
            4 + read_u32_le(payload, definition_offset)
          }
          let value_offset = definition_offset + definition_len
          if column.max_definition_level > 0 {
            let non_null_count = count_levels_range_non_null(
              payload,
              definition_offset + 4,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
            )
            if non_null_count != data_page.num_values {
              unsupported("Nullable binary column contains nulls")
            }
          }
          ignore(
            decode_required_binary_values_into(
              values,
              payload,
              value_offset,
              data_page.encoding,
              column,
              data_page.num_values,
            ),
          )
        }
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
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          if column.max_definition_level > 0 &&
            data_page_v2.definition_levels_byte_length > 0 {
            let definition_offset = payload_offset +
              data_page_v2.repetition_levels_byte_length
            let definition_end = definition_offset +
              data_page_v2.definition_levels_byte_length
            let non_null_count = count_levels_range_non_null(
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
            )
            if non_null_count != data_page_v2.num_values {
              unsupported("Nullable binary column contains nulls")
            }
          }
          ignore(
            decode_required_binary_values_into(
              values,
              value_data,
              value_data_offset,
              data_page_v2.encoding,
              column,
              data_page_v2.num_values,
            ),
          )
        }
        None => invalid_data("DATA_PAGE_V2 without data_page_header_v2")
      }
    } else if page_header.page_type == page_type_dictionary_page {
      unsupported(
        "Dictionary binary columns are not supported in typed mode yet",
      )
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
fn decode_optional_int32_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Int?] raise ParquetError {
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Int?] = Array::new(capacity=target_values)
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
        Some(data_page) => {
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let definition_offset = page_data_offset
          let definition_data_offset = definition_offset + 4
          let definition_len = if column.max_definition_level == 0 {
            0
          } else {
            4 + read_u32_le(payload, definition_offset)
          }
          let value_offset = definition_offset + definition_len
          let non_null_count = if column.max_definition_level == 0 {
            data_page.num_values
          } else {
            count_levels_range_non_null(
              payload,
              definition_data_offset,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
            )
          }
          let dense : Array[Int] = Array::new(capacity=non_null_count)
          if non_null_count > 0 {
            ignore(
              decode_required_int32_values_into(
                dense,
                payload,
                value_offset,
                data_page.encoding,
                non_null_count,
                dictionary,
              ),
            )
          }
          if non_null_count == 0 {
            push_none_values(values, data_page.num_values)
          } else if column.max_definition_level == 0 {
            for value in dense {
              values.push(Some(value))
            }
          } else {
            append_optional_option_values_from_levels_range(
              values,
              payload,
              definition_data_offset,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
              dense,
              non_null_count,
            )
          }
        }
        None => invalid_data("DATA_PAGE without data_page_header")
      }
    } else if page_header.page_type == page_type_data_page_v2 {
      match page_header.data_page_v2 {
        Some(data_page_v2) => {
          let definition_offset = payload_offset +
            data_page_v2.repetition_levels_byte_length
          let definition_end = definition_offset +
            data_page_v2.definition_levels_byte_length
          let value_offset = definition_end
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
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let non_null_count = if column.max_definition_level == 0 ||
            data_page_v2.definition_levels_byte_length == 0 {
            data_page_v2.num_values
          } else {
            count_levels_range_non_null(
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
            )
          }
          let dense : Array[Int] = Array::new(capacity=non_null_count)
          if non_null_count > 0 {
            ignore(
              decode_required_int32_values_into(
                dense,
                value_data,
                value_data_offset,
                data_page_v2.encoding,
                non_null_count,
                dictionary,
              ),
            )
          }
          if non_null_count == 0 {
            push_none_values(values, data_page_v2.num_values)
          } else if column.max_definition_level == 0 ||
            data_page_v2.definition_levels_byte_length == 0 {
            for value in dense {
              values.push(Some(value))
            }
          } else {
            append_optional_option_values_from_levels_range(
              values,
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
              dense,
              non_null_count,
            )
          }
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
fn decode_optional_utf8_column_chunk(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> Array[Bytes?] raise ParquetError {
  let mut offset = chunk.meta_data.dictionary_page_offset
    .unwrap_or(chunk.meta_data.data_page_offset)
    .to_int()
  let target_values = chunk.meta_data.num_values.to_int()
  let values : Array[Bytes?] = Array::new(capacity=target_values)
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
        Some(data_page) => {
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let definition_offset = page_data_offset
          let definition_data_offset = definition_offset + 4
          let definition_len = if column.max_definition_level == 0 {
            0
          } else {
            4 + read_u32_le(payload, definition_offset)
          }
          let value_offset = definition_offset + definition_len
          let non_null_count = if column.max_definition_level == 0 {
            data_page.num_values
          } else {
            count_levels_range_non_null(
              payload,
              definition_data_offset,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
            )
          }
          let dense : Array[Bytes] = Array::new(capacity=non_null_count)
          if non_null_count > 0 {
            ignore(
              decode_required_utf8_values_into(
                dense,
                payload,
                value_offset,
                data_page.encoding,
                non_null_count,
              ),
            )
          }
          if non_null_count == 0 {
            push_none_values(values, data_page.num_values)
          } else if column.max_definition_level == 0 {
            for value in dense {
              values.push(Some(value))
            }
          } else {
            append_optional_option_values_from_levels_range(
              values,
              payload,
              definition_data_offset,
              value_offset,
              column.max_definition_level,
              data_page.num_values,
              dense,
              non_null_count,
            )
          }
        }
        None => invalid_data("DATA_PAGE without data_page_header")
      }
    } else if page_header.page_type == page_type_data_page_v2 {
      match page_header.data_page_v2 {
        Some(data_page_v2) => {
          let definition_offset = payload_offset +
            data_page_v2.repetition_levels_byte_length
          let definition_end = definition_offset +
            data_page_v2.definition_levels_byte_length
          let value_offset = definition_end
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
          if column.max_repetition_level > 0 {
            unsupported("Repeated columns are not supported yet")
          }
          let non_null_count = if column.max_definition_level == 0 ||
            data_page_v2.definition_levels_byte_length == 0 {
            data_page_v2.num_values
          } else {
            count_levels_range_non_null(
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
            )
          }
          let dense : Array[Bytes] = Array::new(capacity=non_null_count)
          if non_null_count > 0 {
            ignore(
              decode_required_utf8_values_into(
                dense,
                value_data,
                value_data_offset,
                data_page_v2.encoding,
                non_null_count,
              ),
            )
          }
          if non_null_count == 0 {
            push_none_values(values, data_page_v2.num_values)
          } else if column.max_definition_level == 0 ||
            data_page_v2.definition_levels_byte_length == 0 {
            for value in dense {
              values.push(Some(value))
            }
          } else {
            append_optional_option_values_from_levels_range(
              values,
              data,
              definition_offset,
              definition_end,
              column.max_definition_level,
              data_page_v2.num_values,
              dense,
              non_null_count,
            )
          }
        }
        None => invalid_data("DATA_PAGE_V2 without data_page_header_v2")
      }
    } else if page_header.page_type == page_type_dictionary_page {
      unsupported(
        "Dictionary UTF-8 columns are not supported in typed mode yet",
      )
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
fn decode_column_chunk_columnar(
  data : Bytes,
  chunk : ColumnChunkMeta,
  column : LeafColumnMeta,
) -> ParquetColumnData raise ParquetError {
  if column.max_repetition_level > 0 {
    return Values(decode_column_chunk(data, chunk, column))
  }
  match column.column_type {
    Int32 =>
      if column.max_definition_level == 0 {
        Int32Values(decode_required_int32_column_chunk(data, chunk, column))
      } else {
        NullableInt32Values(
          decode_optional_int32_column_chunk(data, chunk, column),
        )
      }
    Int64 =>
      Int64Values(decode_required_int64_column_chunk(data, chunk, column))
    TimestampMicros =>
      TimestampMicrosValues(
        decode_required_int64_column_chunk(data, chunk, column),
      )
    String =>
      if not(chunk.meta_data.encodings.contains(encoding_plain_dictionary)) &&
        not(chunk.meta_data.encodings.contains(encoding_rle_dictionary)) &&
        column.max_definition_level == 0 {
        Utf8Values(decode_required_utf8_column_chunk(data, chunk, column))
      } else if not(
          chunk.meta_data.encodings.contains(encoding_plain_dictionary),
        ) &&
        not(chunk.meta_data.encodings.contains(encoding_rle_dictionary)) {
        NullableUtf8Values(
          decode_optional_utf8_column_chunk(data, chunk, column),
        )
      } else {
        Values(decode_column_chunk(data, chunk, column))
      }
    Binary =>
      if column.max_definition_level == 0 &&
        not(chunk.meta_data.encodings.contains(encoding_plain_dictionary)) &&
        not(chunk.meta_data.encodings.contains(encoding_rle_dictionary)) {
        BinaryValues(decode_required_binary_column_chunk(data, chunk, column))
      } else {
        Values(decode_column_chunk(data, chunk, column))
      }
    _ => Values(decode_column_chunk(data, chunk, column))
  }
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
  column_count : Int,
  column_values : Array[Array[Value]],
  row_count : Int,
) -> Array[Array[Value]] raise ParquetError {
  for column_index in 0..<column_count {
    if column_values[column_index].length() != row_count {
      invalid_data("Column length mismatch while assembling rows")
    }
  }
  let rows : Array[Array[Value]] = Array::makei(row_count, fn(_) {
    Array::make(column_count, Null)
  })
  for column_index in 0..<column_count {
    let column = column_values[column_index]
    for row_index in 0..<row_count {
      rows[row_index].unsafe_set(column_index, column[row_index])
    }
  }
  rows
}

///|
fn append_column_data(
  all_column_data : Array[ParquetColumnData],
  column_index : Int,
  chunk_data : ParquetColumnData,
) -> Unit {
  match all_column_data[column_index] {
    Values(existing) =>
      match chunk_data {
        Values(values) => existing.append(values)
        _ =>
          if existing.is_empty() {
            all_column_data.unsafe_set(column_index, chunk_data)
          } else {
            let merged = existing
            merged.append(chunk_data.to_values())
            all_column_data.unsafe_set(column_index, Values(merged))
          }
      }
    BooleanValues(existing) =>
      match chunk_data {
        BooleanValues(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    Int32Values(existing) =>
      match chunk_data {
        Int32Values(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    NullableInt32Values(existing) =>
      match chunk_data {
        NullableInt32Values(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    Int64Values(existing) =>
      match chunk_data {
        Int64Values(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    TimestampMicrosValues(existing) =>
      match chunk_data {
        TimestampMicrosValues(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    FloatValues(existing) =>
      match chunk_data {
        FloatValues(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    DoubleValues(existing) =>
      match chunk_data {
        DoubleValues(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    Utf8Values(existing) =>
      match chunk_data {
        Utf8Values(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    NullableUtf8Values(existing) =>
      match chunk_data {
        NullableUtf8Values(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
    BinaryValues(existing) =>
      match chunk_data {
        BinaryValues(values) => existing.append(values)
        _ => {
          let merged = all_column_data[column_index].to_values()
          merged.append(chunk_data.to_values())
          all_column_data.unsafe_set(column_index, Values(merged))
        }
      }
  }
}

///|
fn build_public_columns(columns : Array[LeafColumnMeta]) -> Array[Column] {
  columns.map(fn(column) {
    {
      name: column.name,
      column_type: column.column_type,
      repetition: column.repetition,
    }
  })
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
fn decode_parquet_columnar(
  data : Bytes,
) -> ParquetColumnarFile raise ParquetError {
  check_magic(data)
  let footer_len = read_u32_le(data, data.length() - 8)
  let footer_start = data.length() - 8 - footer_len
  if footer_start < 4 {
    invalid_data("Invalid parquet footer length")
  }
  let metadata = read_file_metadata(data, footer_start, footer_len)
  let leaf_columns = build_leaf_columns(metadata.schema)
  let public_columns = build_public_columns(leaf_columns)
  let column_count = leaf_columns.length()
  let all_column_data : Array[ParquetColumnData] = Array::makei(column_count, fn(
    _,
  ) {
    Values([])
  })
  let mut total_rows = 0
  for row_group in metadata.row_groups {
    if row_group.columns.length() != column_count {
      invalid_data("RowGroup column count does not match schema leaf count")
    }
    total_rows += row_group.num_rows.to_int()
    for column_index in 0..<column_count {
      let chunk_data = decode_column_chunk_columnar(
        data,
        row_group.columns[column_index],
        leaf_columns[column_index],
      ) catch {
        ParquetError::Unsupported(_) =>
          Values(
            decode_column_chunk(
              data,
              row_group.columns[column_index],
              leaf_columns[column_index],
            ),
          )
        err => raise err
      }
      append_column_data(all_column_data, column_index, chunk_data)
    }
  }
  new_parquet_columnar_file(
    public_columns,
    all_column_data,
    total_rows,
    metadata.created_by,
  )
}

///|
fn decode_parquet(data : Bytes) -> ParquetFile raise ParquetError {
  let columnar = decode_parquet_columnar(data)
  {
    columns: columnar.columns,
    row_count: columnar.row_count,
    column_data: columnar.column_data,
    rows_cache: None,
    created_by: columnar.created_by,
  }
}
