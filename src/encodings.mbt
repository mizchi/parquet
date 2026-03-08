///|
fn read_u32_le(data : Bytes, start : Int) -> Int raise ParquetError {
  if start < 0 || start + 4 > data.length() {
    invalid_data("Unexpected end of buffer while reading u32")
  }
  data.unsafe_read_uint32_le(start).reinterpret_as_int()
}

///|
fn read_i32_le(data : Bytes, start : Int) -> Int raise ParquetError {
  read_u32_le(data, start)
}

///|
fn read_i64_le(data : Bytes, start : Int) -> Int64 raise ParquetError {
  if start < 0 || start + 8 > data.length() {
    invalid_data("Unexpected end of buffer while reading i64")
  }
  data.unsafe_read_uint64_le(start).reinterpret_as_int64()
}

///|
fn read_u64_le(data : Bytes, start : Int) -> UInt64 raise ParquetError {
  if start < 0 || start + 8 > data.length() {
    invalid_data("Unexpected end of buffer while reading u64")
  }
  data.unsafe_read_uint64_le(start)
}

///|
fn read_f32_le(data : Bytes, start : Int) -> Float raise ParquetError {
  if start < 0 || start + 4 > data.length() {
    invalid_data("Unexpected end of buffer while reading f32")
  }
  Float::reinterpret_from_uint(data.unsafe_read_uint32_le(start))
}

///|
fn read_f64_le(data : Bytes, start : Int) -> Double raise ParquetError {
  read_u64_le(data, start).reinterpret_as_double()
}

///|
fn read_int96_micros(data : Bytes, start : Int) -> Int64 raise ParquetError {
  let nanos_of_day = read_i64_le(data, start)
  let julian_day = read_u32_le(data, start + 8).to_int64()
  let day_micros = (julian_day - 2440588L) * 86400000000L
  let micros_of_day = nanos_of_day / 1000L
  day_micros + micros_of_day
}

///|
fn bit_mask_u64(bit_width : Int) -> UInt64 {
  if bit_width >= 64 {
    UInt64::default().lnot()
  } else {
    ((1).to_uint64() << bit_width) - (1).to_uint64()
  }
}

///|
fn read_partial_u64_le(data : Bytes, start : Int) -> UInt64 {
  if start + 8 <= data.length() {
    return data.unsafe_read_uint64_le(start)
  }
  let mut value = UInt64::default()
  let remaining = data.length() - start
  for index in 0..<remaining {
    value = value | (data[start + index].to_uint64() << (index * 8))
  }
  value
}

///|
fn read_varint64_at(
  data : Bytes,
  start : Int,
) -> (UInt64, Int) raise ParquetError {
  let mut offset = start
  let mut shift = 0
  let mut result = UInt64::default()
  while shift < 64 {
    if offset >= data.length() {
      invalid_data("Unexpected end of compact stream")
    }
    let byte = data[offset].to_int()
    offset += 1
    let payload = (byte & 0x7f).to_uint64()
    result = result | (payload << shift)
    if (byte & 0x80) == 0 {
      return (result, offset - start)
    }
    shift += 7
  }
  invalid_data("Varint is too long")
  (UInt64::default(), 0)
}

///|
fn read_varint32_at(data : Bytes, start : Int) -> (Int, Int) raise ParquetError {
  let (value, consumed) = read_varint64_at(data, start)
  (value.to_int(), consumed)
}

///|
fn read_zigzag_i64_at(
  data : Bytes,
  start : Int,
) -> (Int64, Int) raise ParquetError {
  let (value, consumed) = read_varint64_at(data, start)
  (zigzag_decode_i64(value), consumed)
}

///|
fn append_lsb_bitpacked_ints(
  values : Array[Int],
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
) -> Unit {
  if count == 0 {
    return
  }
  if bit_width == 0 {
    for _ in 0..<count {
      values.push(0)
    }
    return
  }
  if bit_width == 64 {
    let mut offset = start
    for _ in 0..<count {
      values.push(data.unsafe_read_uint64_le(offset).to_int())
      offset += 8
    }
    return
  }
  let mask = bit_mask_u64(bit_width)
  if bit_width <= 56 {
    let mut offset = start
    let mut bit_buffer = UInt64::default()
    let mut bits_in_buffer = 0
    for _ in 0..<count {
      while bits_in_buffer < bit_width {
        bit_buffer = bit_buffer | (data[offset].to_uint64() << bits_in_buffer)
        bits_in_buffer += 8
        offset += 1
      }
      values.push((bit_buffer & mask).to_int())
      bit_buffer = bit_buffer >> bit_width
      bits_in_buffer -= bit_width
    }
    return
  }
  let mut byte_index = start
  let mut shift = 0
  for _ in 0..<count {
    let low = if byte_index + 8 <= data.length() {
      data.unsafe_read_uint64_le(byte_index) >> shift
    } else {
      read_partial_u64_le(data, byte_index) >> shift
    }
    let spill_bits = shift + bit_width - 64
    if spill_bits > 0 {
      let high_byte = if byte_index + 8 < data.length() {
        data[byte_index + 8].to_uint64()
      } else {
        UInt64::default()
      }
      values.push(
        (low | ((high_byte & bit_mask_u64(spill_bits)) << (64 - shift))).to_int(),
      )
    } else {
      values.push((low & mask).to_int())
    }
    let next_shift = shift + bit_width
    byte_index += next_shift >> 3
    shift = next_shift & 7
  }
}

///|
fn append_lsb_bitpacked_deltas(
  values : Array[Int64],
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
  min_delta : Int64,
  previous : Int64,
) -> Int64 {
  let min_delta_bits = min_delta.reinterpret_as_uint64()
  let mut current_bits = previous.reinterpret_as_uint64()
  if count == 0 {
    return previous
  }
  if bit_width == 0 {
    for _ in 0..<count {
      current_bits = current_bits + min_delta_bits
      values.push(current_bits.reinterpret_as_int64())
    }
    return current_bits.reinterpret_as_int64()
  }
  if bit_width == 64 {
    let mut offset = start
    for _ in 0..<count {
      current_bits = current_bits +
        min_delta_bits +
        data.unsafe_read_uint64_le(offset)
      values.push(current_bits.reinterpret_as_int64())
      offset += 8
    }
    return current_bits.reinterpret_as_int64()
  }
  let mask = bit_mask_u64(bit_width)
  if bit_width <= 56 {
    let mut offset = start
    let mut bit_buffer = UInt64::default()
    let mut bits_in_buffer = 0
    for _ in 0..<count {
      while bits_in_buffer < bit_width {
        bit_buffer = bit_buffer | (data[offset].to_uint64() << bits_in_buffer)
        bits_in_buffer += 8
        offset += 1
      }
      current_bits = current_bits + min_delta_bits + (bit_buffer & mask)
      values.push(current_bits.reinterpret_as_int64())
      bit_buffer = bit_buffer >> bit_width
      bits_in_buffer -= bit_width
    }
    return current_bits.reinterpret_as_int64()
  }
  let mut byte_index = start
  let mut shift = 0
  for _ in 0..<count {
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
    current_bits = current_bits + min_delta_bits + unpacked
    values.push(current_bits.reinterpret_as_int64())
    let next_shift = shift + bit_width
    byte_index += next_shift >> 3
    shift = next_shift & 7
  }
  current_bits.reinterpret_as_int64()
}

///|
fn append_lsb_bitpacked_int32_delta_values(
  values : Array[Value],
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
  min_delta : Int64,
  previous : Int64,
) -> Int64 {
  let min_delta_bits = min_delta.reinterpret_as_uint64()
  let mut current_bits = previous.reinterpret_as_uint64()
  if count == 0 {
    return previous
  }
  if bit_width == 0 {
    for _ in 0..<count {
      current_bits = current_bits + min_delta_bits
      values.push(Value::Int32(current_bits.reinterpret_as_int64().to_int()))
    }
    return current_bits.reinterpret_as_int64()
  }
  if bit_width == 64 {
    let mut offset = start
    for _ in 0..<count {
      current_bits = current_bits +
        min_delta_bits +
        data.unsafe_read_uint64_le(offset)
      values.push(Value::Int32(current_bits.reinterpret_as_int64().to_int()))
      offset += 8
    }
    return current_bits.reinterpret_as_int64()
  }
  let mask = bit_mask_u64(bit_width)
  if bit_width <= 56 {
    let mut offset = start
    let mut bit_buffer = UInt64::default()
    let mut bits_in_buffer = 0
    for _ in 0..<count {
      while bits_in_buffer < bit_width {
        bit_buffer = bit_buffer | (data[offset].to_uint64() << bits_in_buffer)
        bits_in_buffer += 8
        offset += 1
      }
      current_bits = current_bits + min_delta_bits + (bit_buffer & mask)
      values.push(Value::Int32(current_bits.reinterpret_as_int64().to_int()))
      bit_buffer = bit_buffer >> bit_width
      bits_in_buffer -= bit_width
    }
    return current_bits.reinterpret_as_int64()
  }
  let mut byte_index = start
  let mut shift = 0
  for _ in 0..<count {
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
    current_bits = current_bits + min_delta_bits + unpacked
    values.push(Value::Int32(current_bits.reinterpret_as_int64().to_int()))
    let next_shift = shift + bit_width
    byte_index += next_shift >> 3
    shift = next_shift & 7
  }
  current_bits.reinterpret_as_int64()
}

///|
fn append_lsb_bitpacked_int64_delta_values(
  values : Array[Value],
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
  min_delta : Int64,
  previous : Int64,
) -> Int64 {
  let min_delta_bits = min_delta.reinterpret_as_uint64()
  let mut current_bits = previous.reinterpret_as_uint64()
  if count == 0 {
    return previous
  }
  if bit_width == 0 {
    for _ in 0..<count {
      current_bits = current_bits + min_delta_bits
      values.push(Value::Int64(current_bits.reinterpret_as_int64()))
    }
    return current_bits.reinterpret_as_int64()
  }
  if bit_width == 64 {
    let mut offset = start
    for _ in 0..<count {
      current_bits = current_bits +
        min_delta_bits +
        data.unsafe_read_uint64_le(offset)
      values.push(Value::Int64(current_bits.reinterpret_as_int64()))
      offset += 8
    }
    return current_bits.reinterpret_as_int64()
  }
  let mask = bit_mask_u64(bit_width)
  if bit_width <= 56 {
    let mut offset = start
    let mut bit_buffer = UInt64::default()
    let mut bits_in_buffer = 0
    for _ in 0..<count {
      while bits_in_buffer < bit_width {
        bit_buffer = bit_buffer | (data[offset].to_uint64() << bits_in_buffer)
        bits_in_buffer += 8
        offset += 1
      }
      current_bits = current_bits + min_delta_bits + (bit_buffer & mask)
      values.push(Value::Int64(current_bits.reinterpret_as_int64()))
      bit_buffer = bit_buffer >> bit_width
      bits_in_buffer -= bit_width
    }
    return current_bits.reinterpret_as_int64()
  }
  let mut byte_index = start
  let mut shift = 0
  for _ in 0..<count {
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
    current_bits = current_bits + min_delta_bits + unpacked
    values.push(Value::Int64(current_bits.reinterpret_as_int64()))
    let next_shift = shift + bit_width
    byte_index += next_shift >> 3
    shift = next_shift & 7
  }
  current_bits.reinterpret_as_int64()
}

///|
fn decode_rle_hybrid_range(
  data : Bytes,
  start : Int,
  end : Int,
  bit_width : Int,
  count : Int,
) -> (Array[Int], Int) raise ParquetError {
  let mut offset = start
  let values : Array[Int] = Array::new(capacity=count)
  let mut produced = 0
  if bit_width == 0 {
    for _ in 0..<count {
      values.push(0)
    }
    return (values, 0)
  }
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
      for _ in 0..<values_to_take {
        values.push(repeated)
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
      append_lsb_bitpacked_ints(values, data, offset, bit_width, values_to_take)
      offset += byte_len
      produced += values_to_take
    }
  }
  (values, offset - start)
}

///|
fn decode_rle_hybrid(
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
  length_prefixed : Bool,
) -> (Array[Int], Int) raise ParquetError {
  let mut offset = start
  let end = if length_prefixed {
    let encoded_len = read_u32_le(data, offset)
    offset += 4
    offset + encoded_len
  } else {
    data.length()
  }
  let (values, consumed) = decode_rle_hybrid_range(
    data, offset, end, bit_width, count,
  )
  (values, offset - start + consumed)
}

///|
fn decode_delta_binary_packed(
  data : Bytes,
  start : Int,
) -> (Array[Int64], Int) raise ParquetError {
  let original_start = start
  let data_len = data.length()
  let (block_size, block_size_len) = read_varint32_at(data, start)
  let start = start + block_size_len
  let (miniblock_count, miniblock_len) = read_varint32_at(data, start)
  let start = start + miniblock_len
  let (total_count, total_count_len) = read_varint32_at(data, start)
  let start = start + total_count_len
  let (first_value, first_value_len) = read_zigzag_i64_at(data, start)
  let mut offset = start + first_value_len
  if block_size <= 0 || miniblock_count <= 0 || total_count <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED header")
  }
  let values_per_miniblock = block_size / miniblock_count
  if values_per_miniblock <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED miniblock size")
  }
  let values : Array[Int64] = Array::new(capacity=total_count)
  values.push(first_value)
  let mut previous = first_value
  let mut produced = 1
  while produced < total_count {
    let (min_delta, min_delta_len) = read_zigzag_i64_at(data, offset)
    offset += min_delta_len
    if offset + miniblock_count > data_len {
      invalid_data("Unexpected end of delta miniblock widths")
    }
    let bit_widths_start = offset
    offset += miniblock_count
    let remaining = total_count - produced
    if remaining >= block_size {
      for miniblock_index in 0..<miniblock_count {
        let bit_width = data[bit_widths_start + miniblock_index].to_int()
        let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
        previous = append_lsb_bitpacked_deltas(
          values, data, offset, bit_width, values_per_miniblock, min_delta, previous,
        )
        offset += byte_len
      }
      produced += block_size
    } else {
      let mut remaining = remaining
      for miniblock_index in 0..<miniblock_count {
        if remaining <= 0 {
          break
        }
        let bit_width = data[bit_widths_start + miniblock_index].to_int()
        let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
        let values_to_take = if remaining < values_per_miniblock {
          remaining
        } else {
          values_per_miniblock
        }
        previous = append_lsb_bitpacked_deltas(
          values, data, offset, bit_width, values_to_take, min_delta, previous,
        )
        offset += byte_len
        produced += values_to_take
        remaining -= values_to_take
      }
    }
  }
  (values, offset - original_start)
}

///|
fn decode_delta_binary_packed_int32_values(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  let values : Array[Value] = Array::new(capacity=count)
  let consumed = decode_delta_binary_packed_int32_values_into(
    values, data, start, count,
  )
  (values, consumed)
}

///|
fn decode_delta_binary_packed_int32_values_into(
  values : Array[Value],
  data : Bytes,
  start : Int,
  count : Int,
) -> Int raise ParquetError {
  let original_start = start
  let data_len = data.length()
  let (block_size, block_size_len) = read_varint32_at(data, start)
  let start = start + block_size_len
  let (miniblock_count, miniblock_len) = read_varint32_at(data, start)
  let start = start + miniblock_len
  let (total_count, total_count_len) = read_varint32_at(data, start)
  let start = start + total_count_len
  let (first_value, first_value_len) = read_zigzag_i64_at(data, start)
  let mut offset = start + first_value_len
  if block_size <= 0 || miniblock_count <= 0 || total_count <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED header")
  }
  if total_count != count {
    invalid_data("DELTA_BINARY_PACKED count mismatch")
  }
  let values_per_miniblock = block_size / miniblock_count
  if values_per_miniblock <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED miniblock size")
  }
  values.push(Value::Int32(first_value.to_int()))
  let mut previous = first_value
  let mut produced = 1
  while produced < total_count {
    let (min_delta, min_delta_len) = read_zigzag_i64_at(data, offset)
    offset += min_delta_len
    if offset + miniblock_count > data_len {
      invalid_data("Unexpected end of delta miniblock widths")
    }
    let bit_widths_start = offset
    offset += miniblock_count
    let remaining = total_count - produced
    if remaining >= block_size {
      for miniblock_index in 0..<miniblock_count {
        let bit_width = data[bit_widths_start + miniblock_index].to_int()
        let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
        previous = append_lsb_bitpacked_int32_delta_values(
          values, data, offset, bit_width, values_per_miniblock, min_delta, previous,
        )
        offset += byte_len
      }
      produced += block_size
    } else {
      let mut remaining = remaining
      for miniblock_index in 0..<miniblock_count {
        if remaining <= 0 {
          break
        }
        let bit_width = data[bit_widths_start + miniblock_index].to_int()
        let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
        let values_to_take = if remaining < values_per_miniblock {
          remaining
        } else {
          values_per_miniblock
        }
        previous = append_lsb_bitpacked_int32_delta_values(
          values, data, offset, bit_width, values_to_take, min_delta, previous,
        )
        offset += byte_len
        produced += values_to_take
        remaining -= values_to_take
      }
    }
  }
  offset - original_start
}

///|
fn decode_delta_binary_packed_int64_values(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  let values : Array[Value] = Array::new(capacity=count)
  let consumed = decode_delta_binary_packed_int64_values_into(
    values, data, start, count,
  )
  (values, consumed)
}

///|
fn decode_delta_binary_packed_int64_values_into(
  values : Array[Value],
  data : Bytes,
  start : Int,
  count : Int,
) -> Int raise ParquetError {
  let original_start = start
  let data_len = data.length()
  let (block_size, block_size_len) = read_varint32_at(data, start)
  let start = start + block_size_len
  let (miniblock_count, miniblock_len) = read_varint32_at(data, start)
  let start = start + miniblock_len
  let (total_count, total_count_len) = read_varint32_at(data, start)
  let start = start + total_count_len
  let (first_value, first_value_len) = read_zigzag_i64_at(data, start)
  let mut offset = start + first_value_len
  if block_size <= 0 || miniblock_count <= 0 || total_count <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED header")
  }
  if total_count != count {
    invalid_data("DELTA_BINARY_PACKED count mismatch")
  }
  let values_per_miniblock = block_size / miniblock_count
  if values_per_miniblock <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED miniblock size")
  }
  values.push(Value::Int64(first_value))
  let mut previous = first_value
  let mut produced = 1
  while produced < total_count {
    let (min_delta, min_delta_len) = read_zigzag_i64_at(data, offset)
    offset += min_delta_len
    if offset + miniblock_count > data_len {
      invalid_data("Unexpected end of delta miniblock widths")
    }
    let bit_widths_start = offset
    offset += miniblock_count
    let remaining = total_count - produced
    if remaining >= block_size {
      for miniblock_index in 0..<miniblock_count {
        let bit_width = data[bit_widths_start + miniblock_index].to_int()
        let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
        previous = append_lsb_bitpacked_int64_delta_values(
          values, data, offset, bit_width, values_per_miniblock, min_delta, previous,
        )
        offset += byte_len
      }
      produced += block_size
    } else {
      let mut remaining = remaining
      for miniblock_index in 0..<miniblock_count {
        if remaining <= 0 {
          break
        }
        let bit_width = data[bit_widths_start + miniblock_index].to_int()
        let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
        let values_to_take = if remaining < values_per_miniblock {
          remaining
        } else {
          values_per_miniblock
        }
        previous = append_lsb_bitpacked_int64_delta_values(
          values, data, offset, bit_width, values_to_take, min_delta, previous,
        )
        offset += byte_len
        produced += values_to_take
        remaining -= values_to_take
      }
    }
  }
  offset - original_start
}

///|
fn decode_delta_length_byte_array_layout(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Int64], Int, Int) raise ParquetError {
  let (lengths, lengths_len) = decode_delta_binary_packed(data, start)
  if lengths.length() != count {
    invalid_data("DELTA_LENGTH_BYTE_ARRAY count mismatch")
  }
  let values_offset = start + lengths_len
  let mut offset = values_offset
  for length in lengths {
    let size = length.to_int()
    if size < 0 || offset + size > data.length() {
      invalid_data("Invalid DELTA_LENGTH_BYTE_ARRAY suffix length")
    }
    offset += size
  }
  (lengths, values_offset, offset - start)
}

///|
fn decode_delta_byte_array_values(
  data : Bytes,
  start : Int,
  count : Int,
  column_type : ColumnType,
) -> (Array[Value], Int) raise ParquetError {
  let values : Array[Value] = Array::new(capacity=count)
  let consumed = decode_delta_byte_array_values_into(
    values, data, start, count, column_type,
  )
  (values, consumed)
}

///|
fn decode_delta_byte_array_values_into(
  target : Array[Value],
  data : Bytes,
  start : Int,
  count : Int,
  column_type : ColumnType,
) -> Int raise ParquetError {
  let (prefix_lengths, prefix_len_bytes) = decode_delta_binary_packed(
    data, start,
  )
  if prefix_lengths.length() != count {
    invalid_data("DELTA_BYTE_ARRAY prefix count mismatch")
  }
  let (suffix_lengths, suffix_data_start, suffix_len_bytes) = decode_delta_length_byte_array_layout(
    data,
    start + prefix_len_bytes,
    count,
  )
  let mut previous = Bytes::default()
  let mut suffix_offset = suffix_data_start
  for index in 0..<count {
    let prefix_len = prefix_lengths[index].to_int()
    if prefix_len < 0 || prefix_len > previous.length() {
      invalid_data("Invalid DELTA_BYTE_ARRAY prefix length")
    }
    let suffix_len = suffix_lengths[index].to_int()
    if suffix_len < 0 || suffix_offset + suffix_len > data.length() {
      invalid_data("Invalid DELTA_LENGTH_BYTE_ARRAY suffix length")
    }
    let value = bytes_concat_prefix(
      previous,
      prefix_len,
      data.view(start=suffix_offset, end=suffix_offset + suffix_len),
    )
    match column_type {
      String => target.push(Value::String(bytes_to_utf8_string(value[:])))
      Binary => target.push(Value::Binary(value))
      _ => {
        unsupported("DELTA_BYTE_ARRAY is only valid for byte arrays")
        return 0
      }
    }
    previous = value
    suffix_offset += suffix_len
  }
  prefix_len_bytes + suffix_len_bytes
}

///|
fn decode_plain_boolean_values(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  let values : Array[Value] = Array::new(capacity=count)
  for index in 0..<count {
    let byte_index = start + index / 8
    let bit_index = index % 8
    if byte_index >= data.length() {
      invalid_data("Unexpected end of buffer while reading BOOLEAN values")
    }
    let bit = (data[byte_index].to_int() >> bit_index) & 1
    values.push(Value::Boolean(bit == 1))
  }
  (values, ceil_div(count, 8))
}

///|
fn decode_plain_boolean_values_into(
  target : Array[Value],
  data : Bytes,
  start : Int,
  count : Int,
) -> Int raise ParquetError {
  for index in 0..<count {
    let byte_index = start + index / 8
    let bit_index = index % 8
    if byte_index >= data.length() {
      invalid_data("Unexpected end of buffer while reading BOOLEAN values")
    }
    let bit = (data[byte_index].to_int() >> bit_index) & 1
    target.push(Value::Boolean(bit == 1))
  }
  ceil_div(count, 8)
}

///|
fn append_lsb_bitpacked_dictionary_values(
  target : Array[Value],
  dictionary_values : Array[Value],
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
) -> Unit raise ParquetError {
  if count == 0 {
    return
  }
  let dictionary_len = dictionary_values.length()
  if bit_width == 0 {
    if dictionary_len == 0 {
      invalid_data("Dictionary index out of range")
    }
    for _ in 0..<count {
      target.push(dictionary_values[0])
    }
    return
  }
  if bit_width == 64 {
    let mut offset = start
    for _ in 0..<count {
      let index = data.unsafe_read_uint64_le(offset).to_int()
      if index >= dictionary_len {
        invalid_data("Dictionary index out of range")
      }
      target.push(dictionary_values[index])
      offset += 8
    }
    return
  }
  let mask = bit_mask_u64(bit_width)
  if bit_width <= 56 {
    let mut offset = start
    let mut bit_buffer = UInt64::default()
    let mut bits_in_buffer = 0
    for _ in 0..<count {
      while bits_in_buffer < bit_width {
        bit_buffer = bit_buffer | (data[offset].to_uint64() << bits_in_buffer)
        bits_in_buffer += 8
        offset += 1
      }
      let index = (bit_buffer & mask).to_int()
      if index >= dictionary_len {
        invalid_data("Dictionary index out of range")
      }
      target.push(dictionary_values[index])
      bit_buffer = bit_buffer >> bit_width
      bits_in_buffer -= bit_width
    }
    return
  }
  let mut byte_index = start
  let mut shift = 0
  for _ in 0..<count {
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
    let index = unpacked.to_int()
    if index >= dictionary_len {
      invalid_data("Dictionary index out of range")
    }
    target.push(dictionary_values[index])
    let next_shift = shift + bit_width
    byte_index += next_shift >> 3
    shift = next_shift & 7
  }
}

///|
fn decode_dictionary_values(
  data : Bytes,
  start : Int,
  count : Int,
  dictionary_values : Array[Value],
) -> (Array[Value], Int) raise ParquetError {
  let values : Array[Value] = Array::new(capacity=count)
  let consumed = decode_dictionary_values_into(
    values, data, start, count, dictionary_values,
  )
  (values, consumed)
}

///|
fn decode_dictionary_values_into(
  target : Array[Value],
  data : Bytes,
  start : Int,
  count : Int,
  dictionary_values : Array[Value],
) -> Int raise ParquetError {
  if start >= data.length() {
    invalid_data("Unexpected end of buffer while reading dictionary indices")
  }
  let index_bit_width = data[start].to_int()
  if index_bit_width == 0 {
    if dictionary_values.length() == 0 {
      invalid_data("Dictionary index out of range")
    }
    for _ in 0..<count {
      target.push(dictionary_values[0])
    }
    return 1
  }
  let mut offset = start + 1
  let mut produced = 0
  while produced < count && offset < data.length() {
    let (header, header_len) = read_varint32_at(data, offset)
    offset += header_len
    if (header & 1) == 0 {
      let run_len = header >> 1
      let byte_width = ceil_div(index_bit_width, 8)
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
      if repeated >= dictionary_values.length() {
        invalid_data("Dictionary index out of range")
      }
      for _ in 0..<values_to_take {
        target.push(dictionary_values[repeated])
      }
      produced += values_to_take
    } else {
      let groups = header >> 1
      let group_values = groups * 8
      let byte_len = ceil_div(group_values * index_bit_width, 8)
      let values_to_take = if count - produced < group_values {
        count - produced
      } else {
        group_values
      }
      append_lsb_bitpacked_dictionary_values(
        target, dictionary_values, data, offset, index_bit_width, values_to_take,
      )
      offset += byte_len
      produced += values_to_take
    }
  }
  1 + (offset - (start + 1))
}

///|
fn decode_plain_values(
  data : Bytes,
  start : Int,
  column : LeafColumnMeta,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  if column.column_type == Boolean {
    return decode_plain_boolean_values(data, start, count)
  }
  let mut offset = start
  let values : Array[Value] = Array::new(capacity=count)
  match column.column_type {
    Boolean => ()
    Int32 =>
      for _ in 0..<count {
        values.push(Value::Int32(read_i32_le(data, offset)))
        offset += 4
      }
    Int64 =>
      for _ in 0..<count {
        values.push(Value::Int64(read_i64_le(data, offset)))
        offset += 8
      }
    TimestampMicros =>
      for _ in 0..<count {
        values.push(Value::TimestampMicros(read_int96_micros(data, offset)))
        offset += 12
      }
    Float =>
      for _ in 0..<count {
        values.push(Value::Float(read_f32_le(data, offset)))
        offset += 4
      }
    Double =>
      for _ in 0..<count {
        values.push(Value::Double(read_f64_le(data, offset)))
        offset += 8
      }
    String =>
      for _ in 0..<count {
        let len = read_u32_le(data, offset)
        offset += 4
        values.push(
          Value::String(
            bytes_to_utf8_string(data.view(start=offset, end=offset + len)),
          ),
        )
        offset += len
      }
    Binary =>
      for _ in 0..<count {
        let len = match column.fixed_length {
          Some(value) => value
          None => {
            let byte_len = read_u32_le(data, offset)
            offset += 4
            byte_len
          }
        }
        values.push(
          Value::Binary(data.view(start=offset, end=offset + len).to_bytes()),
        )
        offset += len
      }
  }
  (values, offset - start)
}

///|
fn decode_plain_values_into(
  target : Array[Value],
  data : Bytes,
  start : Int,
  column : LeafColumnMeta,
  count : Int,
) -> Int raise ParquetError {
  if column.column_type == Boolean {
    return decode_plain_boolean_values_into(target, data, start, count)
  }
  let mut offset = start
  match column.column_type {
    Boolean => ()
    Int32 =>
      for _ in 0..<count {
        target.push(Value::Int32(read_i32_le(data, offset)))
        offset += 4
      }
    Int64 =>
      for _ in 0..<count {
        target.push(Value::Int64(read_i64_le(data, offset)))
        offset += 8
      }
    TimestampMicros =>
      for _ in 0..<count {
        target.push(Value::TimestampMicros(read_int96_micros(data, offset)))
        offset += 12
      }
    Float =>
      for _ in 0..<count {
        target.push(Value::Float(read_f32_le(data, offset)))
        offset += 4
      }
    Double =>
      for _ in 0..<count {
        target.push(Value::Double(read_f64_le(data, offset)))
        offset += 8
      }
    String =>
      for _ in 0..<count {
        let len = read_u32_le(data, offset)
        offset += 4
        target.push(
          Value::String(
            bytes_to_utf8_string(data.view(start=offset, end=offset + len)),
          ),
        )
        offset += len
      }
    Binary =>
      for _ in 0..<count {
        let len = match column.fixed_length {
          Some(value) => value
          None => {
            let byte_len = read_u32_le(data, offset)
            offset += 4
            byte_len
          }
        }
        target.push(
          Value::Binary(data.view(start=offset, end=offset + len).to_bytes()),
        )
        offset += len
      }
  }
  offset - start
}

///|
fn decode_non_null_values(
  data : Bytes,
  start : Int,
  encoding : Int,
  column : LeafColumnMeta,
  count : Int,
  dictionary : Array[Value]?,
) -> (Array[Value], Int) raise ParquetError {
  if count == 0 {
    return ([], 0)
  }
  if encoding == encoding_plain_dictionary ||
    encoding == encoding_rle_dictionary {
    match dictionary {
      Some(dictionary_values) =>
        return decode_dictionary_values(data, start, count, dictionary_values)
      None => {
        invalid_data("Dictionary encoded page without dictionary page")
        return ([], 0)
      }
    }
  }
  if encoding == encoding_plain {
    decode_plain_values(data, start, column, count)
  } else if encoding == encoding_delta_binary_packed {
    match column.column_type {
      Int32 => decode_delta_binary_packed_int32_values(data, start, count)
      Int64 => decode_delta_binary_packed_int64_values(data, start, count)
      _ => {
        unsupported("DELTA_BINARY_PACKED is only valid for INT32/INT64")
        ([], 0)
      }
    }
  } else if encoding == encoding_delta_byte_array {
    match column.column_type {
      String => decode_delta_byte_array_values(data, start, count, String)
      Binary => decode_delta_byte_array_values(data, start, count, Binary)
      _ => {
        unsupported("DELTA_BYTE_ARRAY is only valid for byte arrays")
        ([], 0)
      }
    }
  } else {
    unsupported("Unsupported parquet encoding: \{encoding}")
    ([], 0)
  }
}

///|
fn decode_non_null_values_into(
  target : Array[Value],
  data : Bytes,
  start : Int,
  encoding : Int,
  column : LeafColumnMeta,
  count : Int,
  dictionary : Array[Value]?,
) -> Int raise ParquetError {
  if count == 0 {
    return 0
  }
  if encoding == encoding_plain_dictionary ||
    encoding == encoding_rle_dictionary {
    match dictionary {
      Some(dictionary_values) =>
        return decode_dictionary_values_into(
          target, data, start, count, dictionary_values,
        )
      None => {
        invalid_data("Dictionary encoded page without dictionary page")
        return 0
      }
    }
  }
  if encoding == encoding_plain {
    decode_plain_values_into(target, data, start, column, count)
  } else if encoding == encoding_delta_binary_packed {
    match column.column_type {
      Int32 =>
        decode_delta_binary_packed_int32_values_into(target, data, start, count)
      Int64 =>
        decode_delta_binary_packed_int64_values_into(target, data, start, count)
      _ => {
        unsupported("DELTA_BINARY_PACKED is only valid for INT32/INT64")
        0
      }
    }
  } else if encoding == encoding_delta_byte_array {
    match column.column_type {
      String =>
        decode_delta_byte_array_values_into(target, data, start, count, String)
      Binary =>
        decode_delta_byte_array_values_into(target, data, start, count, Binary)
      _ => {
        unsupported("DELTA_BYTE_ARRAY is only valid for byte arrays")
        0
      }
    }
  } else {
    unsupported("Unsupported parquet encoding: \{encoding}")
    0
  }
}
