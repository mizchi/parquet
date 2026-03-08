///|
/// Read a parquet file from disk.
pub fn read_file(path : String) -> ParquetFile raise ParquetError {
  let data = @fs.read_file_to_bytes(path) catch {
    err => raise ParquetError::Io(err.to_string())
  }
  read_bytes(data)
}

///|
/// Read a parquet document from bytes.
pub fn read_bytes(data : Bytes) -> ParquetFile raise ParquetError {
  decode_parquet(data)
}

///|
/// Read a parquet file from disk without row materialization.
pub fn read_file_columnar(
  path : String,
) -> ParquetColumnarFile raise ParquetError {
  let data = @fs.read_file_to_bytes(path) catch {
    err => raise ParquetError::Io(err.to_string())
  }
  read_bytes_columnar(data)
}

///|
/// Read a parquet document from bytes without row materialization.
pub fn read_bytes_columnar(
  data : Bytes,
) -> ParquetColumnarFile raise ParquetError {
  decode_parquet_columnar(data)
}

///|
/// Encode a parquet document to bytes.
///
/// The current writer supports flat schemas of `Int32`, `Int64`, `String`,
/// and `Binary`, with `Required` or `Optional` repetition.
pub fn write_bytes(file : ParquetFile) -> Bytes raise ParquetError {
  encode_parquet(file)
}

///|
/// Encode a parquet document and write it to disk.
pub fn write_file(path : String, file : ParquetFile) -> Unit raise ParquetError {
  let data = write_bytes(file)
  @fs.write_bytes_to_file(path, data) catch {
    err => raise ParquetError::Io(err.to_string())
  }
}
