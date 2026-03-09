///|
extern "js" fn js_read_file(path : String) -> Int =
  #|(path) => {
  #|  const state = globalThis.__parquet_file_io_state || {};
  #|  globalThis.__parquet_file_io_state = state;
  #|  const fail = (message) => {
  #|    state.bytes = new Uint8Array();
  #|    state.error = message;
  #|    return -1;
  #|  };
  #|  try {
  #|    const isNode = typeof process !== "undefined" &&
  #|      !!(process.versions && process.versions.node);
  #|    if (!isNode) {
  #|      return fail("file I/O is only supported in Node.js");
  #|    }
  #|    const req = typeof require === "function"
  #|      ? require
  #|      : (0, eval)("typeof require === 'function' ? require : undefined");
  #|    if (!req) {
  #|      return fail("Node.js require is not available");
  #|    }
  #|    const fs = req("node:fs");
  #|    state.bytes = new Uint8Array(fs.readFileSync(path));
  #|    state.error = "";
  #|    return 0;
  #|  } catch (err) {
  #|    return fail(err && err.message ? err.message : String(err));
  #|  }
  #|}

///|
extern "js" fn js_last_file_bytes() -> Bytes =
  #|() => {
  #|  const state = globalThis.__parquet_file_io_state || {};
  #|  return state.bytes || new Uint8Array();
  #|}

///|
extern "js" fn js_last_file_error() -> String =
  #|() => {
  #|  const state = globalThis.__parquet_file_io_state || {};
  #|  return state.error || "";
  #|}

///|
extern "js" fn js_write_file(path : String, data : Bytes) -> Int =
  #|(path, data) => {
  #|  const state = globalThis.__parquet_file_io_state || {};
  #|  globalThis.__parquet_file_io_state = state;
  #|  const fail = (message) => {
  #|    state.error = message;
  #|    return -1;
  #|  };
  #|  try {
  #|    const isNode = typeof process !== "undefined" &&
  #|      !!(process.versions && process.versions.node);
  #|    if (!isNode) {
  #|      return fail("file I/O is only supported in Node.js");
  #|    }
  #|    const req = typeof require === "function"
  #|      ? require
  #|      : (0, eval)("typeof require === 'function' ? require : undefined");
  #|    if (!req) {
  #|      return fail("Node.js require is not available");
  #|    }
  #|    const fs = req("node:fs");
  #|    fs.writeFileSync(path, Buffer.from(data));
  #|    state.error = "";
  #|    return 0;
  #|  } catch (err) {
  #|    return fail(err && err.message ? err.message : String(err));
  #|  }
  #|}

///|
fn io_error() -> ParquetError {
  ParquetError::Io(js_last_file_error())
}

///|
/// Read a parquet file from disk.
pub fn read_file(path : String) -> ParquetFile raise ParquetError {
  if js_read_file(path) != 0 {
    raise io_error()
  }
  read_bytes(js_last_file_bytes())
}

///|
/// Read a parquet file from disk without row materialization.
pub fn read_file_columnar(
  path : String,
) -> ParquetColumnarFile raise ParquetError {
  if js_read_file(path) != 0 {
    raise io_error()
  }
  read_bytes_columnar(js_last_file_bytes())
}

///|
/// Encode a parquet document and write it to disk.
pub fn write_file(path : String, file : ParquetFile) -> Unit raise ParquetError {
  let data = write_bytes(file)
  if js_write_file(path, data) != 0 {
    raise io_error()
  }
}
