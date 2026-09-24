///|
fn invalid_data(message : String) -> Unit raise ParquetError {
  raise ParquetError::InvalidData(message)
}

///|
fn unsupported(message : String) -> Unit raise ParquetError {
  raise ParquetError::Unsupported(message)
}

///|
fn ceil_div(n : Int, d : Int) -> Int {
  if n == 0 {
    0
  } else {
    (n + d - 1) / d
  }
}

///|
fn normalize_schema_name(value : String) -> String {
  let trimmed = value.trim()
  match trimmed.strip_suffix(":") {
    Some(name) => name.to_owned()
    None => trimmed.to_owned()
  }
}

///|
fn bit_width(value : Int) -> Int {
  let mut width = 0
  let mut current = value
  while current > 0 {
    width += 1
    current = current >> 1
  }
  width
}

///|
fn zigzag_decode_i64(value : UInt64) -> Int64 {
  let shifted = value >> 1
  let sign = if (value & (1).to_uint64()) == Default::default() {
    Default::default()
  } else {
    (Default::default() : UInt64).lnot()
  }
  (shifted ^ sign).reinterpret_as_int64()
}

///|
fn zigzag_decode_i32(value : UInt64) -> Int {
  zigzag_decode_i64(value).to_int()
}

///|
fn zigzag_encode_i64(value : Int64) -> UInt64 {
  ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
}

///|
fn zigzag_encode_i32(value : Int) -> UInt64 {
  zigzag_encode_i64(value.to_int64())
}

///|
fn bytes_to_utf8_string(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes)
}

///|
fn string_to_bytes(value : String) -> Bytes {
  @utf8.encode(value)
}

///|
fn bytes_concat_prefix(
  prev : Bytes,
  prefix_len : Int,
  suffix : BytesView,
) -> Bytes {
  if prefix_len == 0 {
    return suffix.to_owned()
  }
  if suffix.length() == 0 {
    return if prefix_len == prev.length() {
      prev
    } else {
      prev[:prefix_len].to_owned()
    }
  }
  if prefix_len == prev.length() {
    return prev + suffix.to_owned()
  }
  Bytes::makei(prefix_len + suffix.length(), fn(i) {
    if i < prefix_len {
      prev[i]
    } else {
      suffix[i - prefix_len]
    }
  })
}
