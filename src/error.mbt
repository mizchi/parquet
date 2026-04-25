///|
pub(all) suberror ParquetError {
  InvalidData(String)
  Unsupported(String)
  Io(String)
} derive(Eq)

///|
pub impl Show for ParquetError with output(self, logger) {
  match self {
    InvalidData(message) => logger.write_string("InvalidData(\{message})")
    Unsupported(message) => logger.write_string("Unsupported(\{message})")
    Io(message) => logger.write_string("Io(\{message})")
  }
}
