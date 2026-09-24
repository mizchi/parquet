///|
pub(all) suberror ParquetError {
  InvalidData(String)
  Unsupported(String)
  Io(String)
} derive(Eq, Debug)

///|
pub extend ParquetError with Eq::{not_equal, equal}

///|
pub extend ParquetError with @debug.Debug::{to_repr}

///|
pub impl Show for ParquetError with fn output(self, logger) {
  match self {
    InvalidData(message) => logger.write_string("InvalidData(\{message})")
    Unsupported(message) => logger.write_string("Unsupported(\{message})")
    Io(message) => logger.write_string("Io(\{message})")
  }
}

///|
pub extend ParquetError with Show::{to_string, output}
