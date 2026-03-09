///|
/// Read a parquet file from disk.
pub fn read_file(path : String) -> ParquetFile raise ParquetError {
  let data = @fs.read_file_to_bytes(path) catch {
    err => raise ParquetError::Io(err.to_string())
  }
  read_bytes(data)
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
/// Encode a parquet document and write it to disk.
pub fn write_file(path : String, file : ParquetFile) -> Unit raise ParquetError {
  let data = write_bytes(file)
  @fs.write_bytes_to_file(path, data) catch {
    err => raise ParquetError::Io(err.to_string())
  }
}
