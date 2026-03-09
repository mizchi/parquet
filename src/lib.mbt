///|
/// Read a parquet document from bytes.
pub fn read_bytes(data : Bytes) -> ParquetFile raise ParquetError {
  decode_parquet(data)
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
