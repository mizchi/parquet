///|
pub(all) enum ColumnType {
  Boolean
  Int32
  Int64
  Float
  Double
  String
  Binary
} derive(Show, Eq)

///|
pub(all) enum Repetition {
  Required
  Optional
  Repeated
} derive(Show, Eq)

///|
pub(all) enum Value {
  Boolean(Bool)
  Int32(Int)
  Int64(Int64)
  Float(Float)
  Double(Double)
  String(String)
  Binary(Bytes)
  Null
} derive(Show, Eq)

///|
pub struct Column {
  name : String
  column_type : ColumnType
  repetition : Repetition
} derive(Show, Eq)

///|
pub fn new_column(
  name : String,
  column_type : ColumnType,
  repetition : Repetition,
) -> Column {
  { name, column_type, repetition }
}

///|
pub fn Column::name(self : Column) -> String {
  self.name
}

///|
pub fn Column::column_type(self : Column) -> ColumnType {
  self.column_type
}

///|
pub fn Column::repetition(self : Column) -> Repetition {
  self.repetition
}

///|
pub struct ParquetFile {
  columns : Array[Column]
  rows : Array[Array[Value]]
  created_by : String?
} derive(Show, Eq)

///|
pub fn new_parquet_file(
  columns : Array[Column],
  rows : Array[Array[Value]],
  created_by : String?,
) -> ParquetFile {
  { columns, rows, created_by }
}

///|
pub fn ParquetFile::columns(self : ParquetFile) -> Array[Column] {
  self.columns
}

///|
pub fn ParquetFile::rows(self : ParquetFile) -> Array[Array[Value]] {
  self.rows
}

///|
pub fn ParquetFile::created_by(self : ParquetFile) -> String? {
  self.created_by
}
