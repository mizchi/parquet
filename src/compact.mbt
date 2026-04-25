///|
priv struct CompactReader {
  data : Bytes
  mut offset : Int
  mut last_field_id : Int
  field_stack : Array[Int]
  mut bool_value : Bool?
}

///|
fn CompactReader::new(data : Bytes, start : Int) -> CompactReader {
  { data, offset: start, last_field_id: 0, field_stack: [], bool_value: None }
}

///|
fn CompactReader::ensure(
  self : CompactReader,
  len : Int,
) -> Unit raise ParquetError {
  if self.offset + len > self.data.length() {
    invalid_data("Unexpected end of compact stream")
  }
}

///|
fn CompactReader::read_byte(self : CompactReader) -> Byte raise ParquetError {
  self.ensure(1)
  let value = self.data[self.offset]
  self.offset += 1
  value
}

///|
fn CompactReader::read_binary(
  self : CompactReader,
) -> BytesView raise ParquetError {
  let len = self.read_varint32()
  if len < 0 {
    invalid_data("Negative binary length")
  }
  self.ensure(len)
  let view = self.data.view(start=self.offset, end=self.offset + len)
  self.offset += len
  view
}

///|
fn CompactReader::skip_bytes(
  self : CompactReader,
  len : Int,
) -> Unit raise ParquetError {
  self.ensure(len)
  self.offset += len
}

///|
fn CompactReader::begin_struct(self : CompactReader) -> Unit {
  self.field_stack.push(self.last_field_id)
  self.last_field_id = 0
}

///|
fn CompactReader::end_struct(self : CompactReader) -> Unit raise ParquetError {
  match self.field_stack.pop() {
    Some(prev) => self.last_field_id = prev
    None => invalid_data("Compact field stack underflow")
  }
}

///|
fn CompactReader::read_varint64(
  self : CompactReader,
) -> UInt64 raise ParquetError {
  let mut shift = 0
  let mut result = UInt64::default()
  while shift < 64 {
    let byte = self.read_byte().to_int()
    let payload = (byte & 0x7f).to_uint64()
    result = result | (payload << shift)
    if (byte & 0x80) == 0 {
      return result
    }
    shift += 7
  }
  raise ParquetError::InvalidData("Varint is too long")
}

///|
fn CompactReader::read_varint32(self : CompactReader) -> Int raise ParquetError {
  self.read_varint64().to_int()
}

///|
fn CompactReader::read_i16(self : CompactReader) -> Int raise ParquetError {
  zigzag_decode_i32(self.read_varint64())
}

///|
fn CompactReader::read_i32(self : CompactReader) -> Int raise ParquetError {
  zigzag_decode_i32(self.read_varint64())
}

///|
fn CompactReader::read_i64(self : CompactReader) -> Int64 raise ParquetError {
  zigzag_decode_i64(self.read_varint64())
}

///|
fn CompactReader::read_string(
  self : CompactReader,
) -> String raise ParquetError {
  bytes_to_utf8_string(self.read_binary())
}

///|
fn CompactReader::read_bool(self : CompactReader) -> Bool raise ParquetError {
  match self.bool_value {
    Some(value) => {
      self.bool_value = None
      value
    }
    None => self.read_byte().to_int() == thrift_compact_bool_true
  }
}

///|
fn compact_type_to_wire(compact_type : Int) -> Int raise ParquetError {
  if compact_type == 0 {
    thrift_wire_stop
  } else if compact_type == 1 || compact_type == 2 {
    thrift_wire_bool
  } else if compact_type == 3 {
    thrift_wire_byte
  } else if compact_type == 4 {
    thrift_wire_i16
  } else if compact_type == 5 {
    thrift_wire_i32
  } else if compact_type == 6 {
    thrift_wire_i64
  } else if compact_type == 7 {
    thrift_wire_double
  } else if compact_type == 8 {
    thrift_wire_binary
  } else if compact_type == 9 {
    thrift_wire_list
  } else if compact_type == 10 {
    thrift_wire_set
  } else if compact_type == 11 {
    thrift_wire_map
  } else if compact_type == 12 {
    thrift_wire_struct
  } else {
    raise ParquetError::InvalidData("Unknown compact type: \{compact_type}")
  }
}

///|
fn wire_to_compact_type(wire_type : Int) -> Int raise ParquetError {
  if wire_type == thrift_wire_bool {
    thrift_compact_bool_true
  } else if wire_type == thrift_wire_byte {
    thrift_compact_byte
  } else if wire_type == thrift_wire_i16 {
    thrift_compact_i16
  } else if wire_type == thrift_wire_i32 {
    thrift_compact_i32
  } else if wire_type == thrift_wire_i64 {
    thrift_compact_i64
  } else if wire_type == thrift_wire_double {
    thrift_compact_double
  } else if wire_type == thrift_wire_binary {
    thrift_compact_binary
  } else if wire_type == thrift_wire_list {
    thrift_compact_list
  } else if wire_type == thrift_wire_set {
    thrift_compact_set
  } else if wire_type == thrift_wire_map {
    thrift_compact_map
  } else if wire_type == thrift_wire_struct {
    thrift_compact_struct
  } else {
    raise ParquetError::InvalidData("Cannot encode wire type: \{wire_type}")
  }
}

///|
fn CompactReader::read_field_begin(
  self : CompactReader,
) -> (Int, Int)? raise ParquetError {
  let byte = self.read_byte().to_int()
  if byte == thrift_compact_stop {
    return None
  }
  let modifier = (byte >> 4) & 0x0f
  let compact_type = byte & 0x0f
  let field_id = if modifier == 0 {
    self.read_i16()
  } else {
    self.last_field_id + modifier
  }
  if compact_type == thrift_compact_bool_true {
    self.bool_value = Some(true)
  } else if compact_type == thrift_compact_bool_false {
    self.bool_value = Some(false)
  }
  self.last_field_id = field_id
  Some((field_id, compact_type_to_wire(compact_type)))
}

///|
fn CompactReader::read_list_begin(
  self : CompactReader,
) -> (Int, Int) raise ParquetError {
  let header = self.read_byte().to_int()
  let mut size = (header >> 4) & 0x0f
  if size == 15 {
    size = self.read_varint32()
  }
  let compact_type = header & 0x0f
  (compact_type_to_wire(compact_type), size)
}

///|
fn CompactReader::read_map_begin(
  self : CompactReader,
) -> (Int, Int, Int) raise ParquetError {
  let size = self.read_varint32()
  if size == 0 {
    return (thrift_wire_stop, thrift_wire_stop, 0)
  }
  let header = self.read_byte().to_int()
  let key_type = compact_type_to_wire((header >> 4) & 0x0f)
  let value_type = compact_type_to_wire(header & 0x0f)
  (key_type, value_type, size)
}

///|
fn CompactReader::skip(
  self : CompactReader,
  wire_type : Int,
) -> Unit raise ParquetError {
  if wire_type == thrift_wire_bool {
    let _discard = self.read_bool()
    ()
  } else if wire_type == thrift_wire_byte {
    let _discard = self.read_byte()
    ()
  } else if wire_type == thrift_wire_i16 {
    let _discard = self.read_i16()
    ()
  } else if wire_type == thrift_wire_i32 {
    let _discard = self.read_i32()
    ()
  } else if wire_type == thrift_wire_i64 {
    let _discard = self.read_i64()
    ()
  } else if wire_type == thrift_wire_double {
    self.skip_bytes(8)
  } else if wire_type == thrift_wire_binary {
    let len = self.read_varint32()
    if len < 0 {
      invalid_data("Negative binary length while skipping")
    }
    self.skip_bytes(len)
  } else if wire_type == thrift_wire_list || wire_type == thrift_wire_set {
    let (item_type, size) = self.read_list_begin()
    for _ in 0..<size {
      self.skip(item_type)
    }
  } else if wire_type == thrift_wire_map {
    let (key_type, value_type, size) = self.read_map_begin()
    for _ in 0..<size {
      self.skip(key_type)
      self.skip(value_type)
    }
  } else if wire_type == thrift_wire_struct {
    self.begin_struct()
    let mut done = false
    while !done {
      match self.read_field_begin() {
        Some((_, next_type)) => self.skip(next_type)
        None => {
          self.end_struct()
          done = true
        }
      }
    }
  } else {
    invalid_data("Unsupported wire type while skipping: \{wire_type}")
  }
}

///|
priv struct ByteSink {
  buf : Array[Byte]
}

///|
fn ByteSink::new() -> ByteSink {
  { buf: [] }
}

///|
fn ByteSink::push_byte(self : ByteSink, value : Byte) -> Unit {
  self.buf.push(value)
}

///|
fn ByteSink::push_bytes(self : ByteSink, value : BytesView) -> Unit {
  for byte in value {
    self.buf.push(byte)
  }
}

///|
fn ByteSink::push_u32_le(self : ByteSink, value : Int) -> Unit {
  self.buf.push((value & 0xff).to_byte())
  self.buf.push(((value >> 8) & 0xff).to_byte())
  self.buf.push(((value >> 16) & 0xff).to_byte())
  self.buf.push(((value >> 24) & 0xff).to_byte())
}

///|
fn ByteSink::push_i32_le(self : ByteSink, value : Int) -> Unit {
  self.push_u32_le(value)
}

///|
fn ByteSink::push_i64_le(self : ByteSink, value : Int64) -> Unit {
  let raw = value.reinterpret_as_uint64()
  for shift in [0, 8, 16, 24, 32, 40, 48, 56] {
    self.buf.push(((raw >> shift) & (255).to_uint64()).to_byte())
  }
}

///|
fn ByteSink::push_varint(self : ByteSink, value : UInt64) -> Unit {
  let mut remaining = value
  while remaining >= (128).to_uint64() {
    self.buf.push(
      ((remaining & (127).to_uint64()) | (128).to_uint64()).to_byte(),
    )
    remaining = remaining >> 7
  }
  self.buf.push(remaining.to_byte())
}

///|
fn ByteSink::push_zigzag_i32(self : ByteSink, value : Int) -> Unit {
  self.push_varint(zigzag_encode_i32(value))
}

///|
fn ByteSink::push_zigzag_i64(self : ByteSink, value : Int64) -> Unit {
  self.push_varint(zigzag_encode_i64(value))
}

///|
fn ByteSink::push_binary(self : ByteSink, value : BytesView) -> Unit {
  self.push_varint(value.length().to_uint64())
  self.push_bytes(value)
}

///|
fn ByteSink::push_string(self : ByteSink, value : String) -> Unit {
  self.push_binary(string_to_bytes(value)[:])
}

///|
fn ByteSink::length(self : ByteSink) -> Int {
  self.buf.length()
}

///|
fn ByteSink::to_bytes(self : ByteSink) -> Bytes {
  Bytes::from_array(FixedArray::makei(self.buf.length(), fn(i) { self.buf[i] }))
}

///|
priv struct CompactWriter {
  sink : ByteSink
  mut last_field_id : Int
  field_stack : Array[Int]
}

///|
fn CompactWriter::new() -> CompactWriter {
  { sink: ByteSink::new(), last_field_id: 0, field_stack: [] }
}

///|
fn CompactWriter::begin_struct(self : CompactWriter) -> Unit {
  self.field_stack.push(self.last_field_id)
  self.last_field_id = 0
}

///|
fn CompactWriter::end_struct(self : CompactWriter) -> Unit {
  self.sink.push_byte(thrift_compact_stop.to_byte())
  match self.field_stack.pop() {
    Some(prev) => self.last_field_id = prev
    None => self.last_field_id = 0
  }
}

///|
fn CompactWriter::write_field_header(
  self : CompactWriter,
  field_id : Int,
  wire_type : Int,
) -> Unit raise ParquetError {
  let compact_type = wire_to_compact_type(wire_type)
  let delta = field_id - self.last_field_id
  if delta > 0 && delta <= 15 {
    self.sink.push_byte(((delta << 4) | compact_type).to_byte())
  } else {
    self.sink.push_byte(compact_type.to_byte())
    self.sink.push_zigzag_i32(field_id)
  }
  self.last_field_id = field_id
}

///|
fn CompactWriter::write_i32_field(
  self : CompactWriter,
  field_id : Int,
  value : Int,
) -> Unit raise ParquetError {
  self.write_field_header(field_id, thrift_wire_i32)
  self.sink.push_zigzag_i32(value)
}

///|
fn CompactWriter::write_i64_field(
  self : CompactWriter,
  field_id : Int,
  value : Int64,
) -> Unit raise ParquetError {
  self.write_field_header(field_id, thrift_wire_i64)
  self.sink.push_zigzag_i64(value)
}

///|
fn CompactWriter::write_string_field(
  self : CompactWriter,
  field_id : Int,
  value : String,
) -> Unit raise ParquetError {
  self.write_field_header(field_id, thrift_wire_binary)
  self.sink.push_string(value)
}

///|
fn CompactWriter::write_list_header(
  self : CompactWriter,
  size : Int,
  item_type : Int,
) -> Unit raise ParquetError {
  let compact_type = wire_to_compact_type(item_type)
  if size < 15 {
    self.sink.push_byte(((size << 4) | compact_type).to_byte())
  } else {
    self.sink.push_byte((0xf0 | compact_type).to_byte())
    self.sink.push_varint(size.to_uint64())
  }
}

///|
fn CompactWriter::write_bytes(self : CompactWriter) -> Bytes {
  self.sink.to_bytes()
}
