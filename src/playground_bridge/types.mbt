///|
pub struct PlaygroundTable {
  columns : Array[String]
  rows : Array[Array[String]]
  nulls : Array[Array[Bool]]
}

///|
pub struct PlaygroundResult {
  parquet_bytes : Bytes
  parquet_size : Int
  parquet_file_name : String
  preview : PlaygroundTable
  query : PlaygroundTable
}

///|
priv struct PreparedPlayground {
  parquet_bytes : Bytes
  preview : PlaygroundTable
}
