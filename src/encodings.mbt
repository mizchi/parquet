///|
fn read_u32_le(data : Bytes, start : Int) -> Int raise ParquetError {
  if start < 0 || start + 4 > data.length() {
    invalid_data("Unexpected end of buffer while reading u32")
  }
  data[start].to_int() |
  (data[start + 1].to_int() << 8) |
  (data[start + 2].to_int() << 16) |
  (data[start + 3].to_int() << 24)
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
  let mut raw = UInt64::default()
  for i in 0..<8 {
    raw = raw | (data[start + i].to_uint64() << (i * 8))
  }
  raw.reinterpret_as_int64()
}

///|
fn unpack_lsb_bitpacked(
  data : Bytes,
  start : Int,
  bit_width : Int,
  count : Int,
) -> Array[UInt64] {
  if bit_width == 0 {
    return Array::make(count, UInt64::default())
  }
  let values : Array[UInt64] = []
  for index in 0..<count {
    let base_bit = index * bit_width
    let mut value = UInt64::default()
    for bit in 0..<bit_width {
      let absolute_bit = base_bit + bit
      let byte_index = start + absolute_bit / 8
      let bit_index = absolute_bit % 8
      let byte = data[byte_index].to_int()
      if ((byte >> bit_index) & 1) == 1 {
        value = value | ((1).to_uint64() << bit)
      }
    }
    values.push(value)
  }
  values
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
  let values : Array[Int] = []
  if bit_width == 0 {
    for _ in 0..<count {
      values.push(0)
    }
    return (values, offset - start)
  }
  while values.length() < count && offset < end {
    let header_reader = CompactReader::new(data, offset)
    let header = header_reader.read_varint32()
    offset = header_reader.offset
    if (header & 1) == 0 {
      let run_len = header >> 1
      let byte_width = ceil_div(bit_width, 8)
      let mut repeated = 0
      for i in 0..<byte_width {
        repeated = repeated | (data[offset + i].to_int() << (i * 8))
      }
      offset += byte_width
      for _ in 0..<run_len {
        if values.length() < count {
          values.push(repeated)
        }
      }
    } else {
      let groups = header >> 1
      let group_values = groups * 8
      let byte_len = ceil_div(group_values * bit_width, 8)
      let unpacked = unpack_lsb_bitpacked(data, offset, bit_width, group_values)
      offset += byte_len
      for value in unpacked {
        if values.length() < count {
          values.push(value.to_int())
        }
      }
    }
  }
  (values, offset - start)
}

///|
fn decode_delta_binary_packed(
  data : Bytes,
  start : Int,
) -> (Array[Int64], Int) raise ParquetError {
  let reader = CompactReader::new(data, start)
  let block_size = reader.read_varint32()
  let miniblock_count = reader.read_varint32()
  let total_count = reader.read_varint32()
  let first_value = reader.read_i64()
  if block_size <= 0 || miniblock_count <= 0 || total_count <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED header")
  }
  let values_per_miniblock = block_size / miniblock_count
  if values_per_miniblock <= 0 {
    invalid_data("Invalid DELTA_BINARY_PACKED miniblock size")
  }
  let values : Array[Int64] = [first_value]
  let mut previous = first_value
  while values.length() < total_count {
    let min_delta = reader.read_i64()
    let bit_widths : Array[Int] = []
    for _ in 0..<miniblock_count {
      bit_widths.push(reader.read_byte().to_int())
    }
    for miniblock_index in 0..<miniblock_count {
      let remaining = total_count - values.length()
      if remaining <= 0 {
        break
      }
      let bit_width = bit_widths[miniblock_index]
      let byte_len = ceil_div(values_per_miniblock * bit_width, 8)
      let unpacked = unpack_lsb_bitpacked(
        reader.data,
        reader.offset,
        bit_width,
        values_per_miniblock,
      )
      reader.offset += byte_len
      let values_to_take = if remaining < values_per_miniblock {
        remaining
      } else {
        values_per_miniblock
      }
      for index in 0..<values_to_take {
        let delta = i64_add_u64_wrapping(min_delta, unpacked[index])
        previous = i64_add_wrapping(previous, delta)
        values.push(previous)
      }
    }
  }
  (values, reader.offset - start)
}

///|
fn decode_delta_length_byte_array(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Bytes], Int) raise ParquetError {
  let (lengths, lengths_len) = decode_delta_binary_packed(data, start)
  if lengths.length() != count {
    invalid_data("DELTA_LENGTH_BYTE_ARRAY count mismatch")
  }
  let mut offset = start + lengths_len
  let values : Array[Bytes] = []
  for length in lengths {
    let size = length.to_int()
    if size < 0 || offset + size > data.length() {
      invalid_data("Invalid DELTA_LENGTH_BYTE_ARRAY suffix length")
    }
    values.push(data.view(start=offset, end=offset + size).to_bytes())
    offset += size
  }
  (values, offset - start)
}

///|
fn decode_delta_byte_array(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Bytes], Int) raise ParquetError {
  let (prefix_lengths, prefix_len_bytes) = decode_delta_binary_packed(
    data, start,
  )
  if prefix_lengths.length() != count {
    invalid_data("DELTA_BYTE_ARRAY prefix count mismatch")
  }
  let (suffixes, suffix_len_bytes) = decode_delta_length_byte_array(
    data,
    start + prefix_len_bytes,
    count,
  )
  let mut previous = Bytes::default()
  let values : Array[Bytes] = []
  for index in 0..<count {
    let prefix_len = prefix_lengths[index].to_int()
    if prefix_len < 0 || prefix_len > previous.length() {
      invalid_data("Invalid DELTA_BYTE_ARRAY prefix length")
    }
    let value = bytes_concat_prefix(previous, prefix_len, suffixes[index])
    values.push(value)
    previous = value
  }
  (values, prefix_len_bytes + suffix_len_bytes)
}

///|
fn decode_plain_values(
  data : Bytes,
  start : Int,
  column_type : ColumnType,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  let mut offset = start
  let values : Array[Value] = []
  match column_type {
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
    String =>
      for _ in 0..<count {
        let len = read_u32_le(data, offset)
        offset += 4
        values.push(
          Value::String(
            bytes_to_utf8_string(
              data.view(start=offset, end=offset + len).to_bytes(),
            ),
          ),
        )
        offset += len
      }
    Binary =>
      for _ in 0..<count {
        let len = read_u32_le(data, offset)
        offset += 4
        values.push(
          Value::Binary(data.view(start=offset, end=offset + len).to_bytes()),
        )
        offset += len
      }
  }
  (values, offset - start)
}

///|
fn decode_non_null_values(
  data : Bytes,
  start : Int,
  encoding : Int,
  column_type : ColumnType,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  if count == 0 {
    return ([], 0)
  }
  match encoding {
    0 => decode_plain_values(data, start, column_type, count)
    5 =>
      match column_type {
        Int32 => {
          let (values, consumed) = decode_delta_binary_packed(data, start)
          let decoded : Array[Value] = []
          for index in 0..<count {
            decoded.push(Value::Int32(values[index].to_int()))
          }
          (decoded, consumed)
        }
        Int64 => {
          let (values, consumed) = decode_delta_binary_packed(data, start)
          let decoded : Array[Value] = []
          for index in 0..<count {
            decoded.push(Value::Int64(values[index]))
          }
          (decoded, consumed)
        }
        _ => {
          unsupported("DELTA_BINARY_PACKED is only valid for INT32/INT64")
          ([], 0)
        }
      }
    7 =>
      match column_type {
        String => {
          let (values, consumed) = decode_delta_byte_array(data, start, count)
          let decoded : Array[Value] = []
          for value in values {
            decoded.push(Value::String(bytes_to_utf8_string(value)))
          }
          (decoded, consumed)
        }
        Binary => {
          let (values, consumed) = decode_delta_byte_array(data, start, count)
          let decoded : Array[Value] = []
          for value in values {
            decoded.push(Value::Binary(value))
          }
          (decoded, consumed)
        }
        _ => {
          unsupported("DELTA_BYTE_ARRAY is only valid for byte arrays")
          ([], 0)
        }
      }
    _ => {
      unsupported("Unsupported parquet encoding: \{encoding}")
      ([], 0)
    }
  }
}
