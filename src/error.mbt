///|
pub(all) suberror ParquetError {
  InvalidData(String)
  Unsupported(String)
  Io(String)
} derive(Show, Eq)
