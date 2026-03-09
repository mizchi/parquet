///|
pub fn query_registered_parquet(
  _parquet_bytes : Bytes,
  _file_name : String,
  _sql : String,
  on_done : (Result[PlaygroundTable, String]) -> Unit,
) -> Unit {
  let _ = @duckdb.JsBackend::Auto
  on_done(Err("browser playground queries are only supported on the JS target"))
}
