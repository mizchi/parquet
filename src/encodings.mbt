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
fn decode_plain_boolean_values(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Value], Int) raise ParquetError {
  let values : Array[Value] = []
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
fn decode_dictionary_indices(
  data : Bytes,
  start : Int,
  count : Int,
) -> (Array[Int], Int) raise ParquetError {
  if start >= data.length() {
    invalid_data("Unexpected end of buffer while reading dictionary indices")
  }
  let index_bit_width = data[start].to_int()
  let (indices, consumed) = decode_rle_hybrid(
    data,
    start + 1,
    index_bit_width,
    count,
    false,
  )
  (indices, 1 + consumed)
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
  let values : Array[Value] = []
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
            bytes_to_utf8_string(
              data.view(start=offset, end=offset + len).to_bytes(),
            ),
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
      Some(dictionary_values) => {
        let (indices, consumed) = decode_dictionary_indices(data, start, count)
        let decoded : Array[Value] = []
        for index in indices {
          match dictionary_values.get(index) {
            Some(value) => decoded.push(value)
            None => invalid_data("Dictionary index out of range")
          }
        }
        return (decoded, consumed)
      }
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
  } else if encoding == encoding_delta_byte_array {
    match column.column_type {
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
  } else {
    unsupported("Unsupported parquet encoding: \{encoding}")
    ([], 0)
  }
}
