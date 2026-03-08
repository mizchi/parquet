///|
fn read_snappy_le_int(
  data : Bytes,
  start : Int,
  byte_count : Int,
) -> Int raise ParquetError {
  if start < 0 || start + byte_count > data.length() {
    invalid_data("Unexpected end of SNAPPY buffer")
  }
  let mut value = 0
  for index in 0..<byte_count {
    value = value | (data[start + index].to_int() << (index * 8))
  }
  value
}

///|
fn decode_snappy_block(
  data : Bytes,
  expected_len : Int,
) -> Bytes raise ParquetError {
  let reader = CompactReader::new(data, 0)
  let decoded_len = reader.read_varint32()
  if decoded_len != expected_len {
    invalid_data("SNAPPY decoded length does not match page header")
  }
  let mut offset = reader.offset
  let sink = ByteSink::new()
  while sink.length() < decoded_len {
    if offset >= data.length() {
      invalid_data("Unexpected end of SNAPPY stream")
    }
    let tag = data[offset].to_int()
    offset += 1
    match tag & 0x03 {
      0 => {
        let mut literal_len = (tag >> 2) + 1
        if literal_len > 60 {
          let extra_len_bytes = literal_len - 60
          literal_len = read_snappy_le_int(data, offset, extra_len_bytes) + 1
          offset += extra_len_bytes
        }
        if offset + literal_len > data.length() {
          invalid_data("Unexpected end of SNAPPY literal")
        }
        for index in 0..<literal_len {
          sink.push_byte(data[offset + index])
        }
        offset += literal_len
      }
      1 => {
        if offset >= data.length() {
          invalid_data("Unexpected end of SNAPPY copy")
        }
        let copy_len = 4 + ((tag >> 2) & 0x07)
        let copy_offset = (tag >> 5 << 8) | data[offset].to_int()
        offset += 1
        if copy_offset <= 0 || copy_offset > sink.buf.length() {
          invalid_data("Invalid SNAPPY copy offset")
        }
        let source_start = sink.buf.length() - copy_offset
        for index in 0..<copy_len {
          sink.push_byte(sink.buf[source_start + index])
        }
      }
      2 => {
        let copy_len = 1 + (tag >> 2)
        let copy_offset = read_snappy_le_int(data, offset, 2)
        offset += 2
        if copy_offset <= 0 || copy_offset > sink.buf.length() {
          invalid_data("Invalid SNAPPY copy offset")
        }
        let source_start = sink.buf.length() - copy_offset
        for index in 0..<copy_len {
          sink.push_byte(sink.buf[source_start + index])
        }
      }
      3 => {
        let copy_len = 1 + (tag >> 2)
        let copy_offset = read_snappy_le_int(data, offset, 4)
        offset += 4
        if copy_offset <= 0 || copy_offset > sink.buf.length() {
          invalid_data("Invalid SNAPPY copy offset")
        }
        let source_start = sink.buf.length() - copy_offset
        for index in 0..<copy_len {
          sink.push_byte(sink.buf[source_start + index])
        }
      }
      _ => invalid_data("Invalid SNAPPY tag")
    }
  }
  if sink.length() != decoded_len {
    invalid_data("SNAPPY decoded length mismatch")
  }
  sink.to_bytes()
}

///|
fn decompress_page_payload(
  data : Bytes,
  payload_offset : Int,
  compressed_len : Int,
  expected_len : Int,
  codec : Int,
) -> Bytes raise ParquetError {
  let payload = data
    .view(start=payload_offset, end=payload_offset + compressed_len)
    .to_bytes()
  if codec == codec_uncompressed {
    payload
  } else if codec == codec_snappy {
    decode_snappy_block(payload, expected_len)
  } else {
    unsupported("Unsupported parquet codec: \{codec}")
    Bytes::default()
  }
}
