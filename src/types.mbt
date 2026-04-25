///|
pub(all) enum ColumnType {
  Boolean
  Int32
  Int64
  TimestampMicros
  Float
  Double
  String
  Binary
} derive(Eq)

///|
pub impl Show for ColumnType with output(self, logger) {
  let name = match self {
    Boolean => "Boolean"
    Int32 => "Int32"
    Int64 => "Int64"
    TimestampMicros => "TimestampMicros"
    Float => "Float"
    Double => "Double"
    String => "String"
    Binary => "Binary"
  }
  logger.write_string(name)
}

///|
pub(all) enum Repetition {
  Required
  Optional
  Repeated
} derive(Eq)

///|
pub impl Show for Repetition with output(self, logger) {
  let name = match self {
    Required => "Required"
    Optional => "Optional"
    Repeated => "Repeated"
  }
  logger.write_string(name)
}

///|
pub(all) enum Value {
  Boolean(Bool)
  Int32(Int)
  Int64(Int64)
  TimestampMicros(Int64)
  Float(Float)
  Double(Double)
  String(String)
  Binary(Bytes)
  Null
} derive(Eq)

///|
pub impl Show for Value with output(self, logger) {
  match self {
    Boolean(value) => logger.write_string("Boolean(\{value})")
    Int32(value) => logger.write_string("Int32(\{value})")
    Int64(value) => logger.write_string("Int64(\{value})")
    TimestampMicros(value) => logger.write_string("TimestampMicros(\{value})")
    Float(value) => logger.write_string("Float(\{value})")
    Double(value) => logger.write_string("Double(\{value})")
    String(value) => logger.write_string("String(\{value})")
    Binary(value) => logger.write_string("Binary(\{value})")
    Null => logger.write_string("Null")
  }
}

///|
pub(all) enum ParquetColumnData {
  Values(Array[Value])
  BooleanValues(Array[Bool])
  Int32Values(Array[Int])
  NullableInt32Values(Array[Int?])
  Int64Values(Array[Int64])
  NullableInt64Values(Array[Int64?])
  TimestampMicrosValues(Array[Int64])
  NullableTimestampMicrosValues(Array[Int64?])
  FloatValues(Array[Float])
  DoubleValues(Array[Double])
  Utf8Values(Array[Bytes])
  NullableUtf8Values(Array[Bytes?])
  BinaryValues(Array[Bytes])
  NullableBinaryValues(Array[Bytes?])
} derive(Eq)

///|
pub impl Show for ParquetColumnData with output(self, logger) {
  match self {
    Values(values) => logger.write_string("Values(\{values})")
    BooleanValues(values) => logger.write_string("BooleanValues(\{values})")
    Int32Values(values) => logger.write_string("Int32Values(\{values})")
    NullableInt32Values(values) =>
      logger.write_string("NullableInt32Values(\{values})")
    Int64Values(values) => logger.write_string("Int64Values(\{values})")
    NullableInt64Values(values) =>
      logger.write_string("NullableInt64Values(\{values})")
    TimestampMicrosValues(values) =>
      logger.write_string("TimestampMicrosValues(\{values})")
    NullableTimestampMicrosValues(values) =>
      logger.write_string("NullableTimestampMicrosValues(\{values})")
    FloatValues(values) => logger.write_string("FloatValues(\{values})")
    DoubleValues(values) => logger.write_string("DoubleValues(\{values})")
    Utf8Values(values) => logger.write_string("Utf8Values(\{values})")
    NullableUtf8Values(values) =>
      logger.write_string("NullableUtf8Values(\{values})")
    BinaryValues(values) => logger.write_string("BinaryValues(\{values})")
    NullableBinaryValues(values) =>
      logger.write_string("NullableBinaryValues(\{values})")
  }
}

///|
pub fn ParquetColumnData::length(self : ParquetColumnData) -> Int {
  match self {
    Values(values) => values.length()
    BooleanValues(values) => values.length()
    Int32Values(values) => values.length()
    NullableInt32Values(values) => values.length()
    Int64Values(values) => values.length()
    NullableInt64Values(values) => values.length()
    TimestampMicrosValues(values) => values.length()
    NullableTimestampMicrosValues(values) => values.length()
    FloatValues(values) => values.length()
    DoubleValues(values) => values.length()
    Utf8Values(values) => values.length()
    NullableUtf8Values(values) => values.length()
    BinaryValues(values) => values.length()
    NullableBinaryValues(values) => values.length()
  }
}

///|
fn ParquetColumnData::value_at(self : ParquetColumnData, index : Int) -> Value {
  match self {
    Values(values) => values[index]
    BooleanValues(values) => Value::Boolean(values[index])
    Int32Values(values) => Value::Int32(values[index])
    NullableInt32Values(values) =>
      match values[index] {
        Some(value) => Value::Int32(value)
        None => Value::Null
      }
    Int64Values(values) => Value::Int64(values[index])
    NullableInt64Values(values) =>
      match values[index] {
        Some(value) => Value::Int64(value)
        None => Value::Null
      }
    TimestampMicrosValues(values) => Value::TimestampMicros(values[index])
    NullableTimestampMicrosValues(values) =>
      match values[index] {
        Some(value) => Value::TimestampMicros(value)
        None => Value::Null
      }
    FloatValues(values) => Value::Float(values[index])
    DoubleValues(values) => Value::Double(values[index])
    Utf8Values(values) => Value::String(bytes_to_utf8_string(values[index][:]))
    NullableUtf8Values(values) =>
      match values[index] {
        Some(value) => Value::String(bytes_to_utf8_string(value[:]))
        None => Value::Null
      }
    BinaryValues(values) => Value::Binary(values[index])
    NullableBinaryValues(values) =>
      match values[index] {
        Some(value) => Value::Binary(value)
        None => Value::Null
      }
  }
}

///|
fn ParquetColumnData::to_values(self : ParquetColumnData) -> Array[Value] {
  match self {
    Values(values) => values
    _ => Array::makei(self.length(), fn(index) { self.value_at(index) })
  }
}

///|
fn rows_to_column_data(
  columns : Array[Column],
  rows : Array[Array[Value]],
) -> Array[ParquetColumnData] {
  let column_count = columns.length()
  Array::makei(column_count, fn(column_index) {
    Values(rows.map(fn(row) { row[column_index] }))
  })
}

///|
fn materialize_rows(
  column_count : Int,
  column_data : Array[ParquetColumnData],
  row_count : Int,
) -> Array[Array[Value]] {
  let rows : Array[Array[Value]] = Array::makei(row_count, fn(_) {
    Array::make(column_count, Null)
  })
  for column_index in 0..<column_count {
    let data = column_data[column_index]
    for row_index in 0..<row_count {
      rows[row_index].unsafe_set(column_index, data.value_at(row_index))
    }
  }
  rows
}

///|
fn materialize_column_values(
  column_data : Array[ParquetColumnData],
) -> Array[Array[Value]] {
  column_data.map(fn(data) { data.to_values() })
}

///|
pub struct Column {
  name : String
  column_type : ColumnType
  repetition : Repetition
} derive(Eq)

///|
pub impl Show for Column with output(self, logger) {
  logger.write_string(
    "Column { name: \{self.name}, column_type: \{self.column_type}, repetition: \{self.repetition} }",
  )
}

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
  row_count : Int
  column_data : Array[ParquetColumnData]
  mut rows_cache : Array[Array[Value]]?
  created_by : String?
}

///|
pub fn new_parquet_file(
  columns : Array[Column],
  rows : Array[Array[Value]],
  created_by : String?,
) -> ParquetFile {
  {
    columns,
    row_count: rows.length(),
    column_data: rows_to_column_data(columns, rows),
    rows_cache: Some(rows),
    created_by,
  }
}

///|
pub fn ParquetFile::columns(self : ParquetFile) -> Array[Column] {
  self.columns
}

///|
pub fn ParquetFile::row_count(self : ParquetFile) -> Int {
  self.row_count
}

///|
pub fn ParquetFile::column_data(self : ParquetFile) -> Array[ParquetColumnData] {
  self.column_data
}

///|
pub fn ParquetFile::rows(self : ParquetFile) -> Array[Array[Value]] {
  match self.rows_cache {
    Some(rows) => rows
    None => {
      let rows = materialize_rows(
        self.columns.length(),
        self.column_data,
        self.row_count,
      )
      self.rows_cache = Some(rows)
      rows
    }
  }
}

///|
pub fn ParquetFile::created_by(self : ParquetFile) -> String? {
  self.created_by
}

///|
pub impl Eq for ParquetFile with equal(self, other) -> Bool {
  self.columns == other.columns &&
  self.row_count == other.row_count &&
  self.created_by == other.created_by &&
  self.rows() == other.rows()
}

///|
pub impl Show for ParquetFile with output(self, logger) {
  logger.write_string(
    "ParquetFile { columns: \{self.columns.length()}, row_count: \{self.row_count} }",
  )
}

///|
pub struct ParquetColumnarFile {
  columns : Array[Column]
  column_data : Array[ParquetColumnData]
  row_count : Int
  mut column_values_cache : Array[Array[Value]]?
  created_by : String?
}

///|
pub fn new_parquet_columnar_file(
  columns : Array[Column],
  column_data : Array[ParquetColumnData],
  row_count : Int,
  created_by : String?,
) -> ParquetColumnarFile {
  { columns, column_data, row_count, column_values_cache: None, created_by }
}

///|
pub fn ParquetColumnarFile::columns(
  self : ParquetColumnarFile,
) -> Array[Column] {
  self.columns
}

///|
pub fn ParquetColumnarFile::column_data(
  self : ParquetColumnarFile,
) -> Array[ParquetColumnData] {
  self.column_data
}

///|
pub fn ParquetColumnarFile::column_values(
  self : ParquetColumnarFile,
) -> Array[Array[Value]] {
  match self.column_values_cache {
    Some(values) => values
    None => {
      let values = materialize_column_values(self.column_data)
      self.column_values_cache = Some(values)
      values
    }
  }
}

///|
pub fn ParquetColumnarFile::row_count(self : ParquetColumnarFile) -> Int {
  self.row_count
}

///|
pub fn ParquetColumnarFile::created_by(self : ParquetColumnarFile) -> String? {
  self.created_by
}

///|
pub impl Eq for ParquetColumnarFile with equal(self, other) -> Bool {
  self.columns == other.columns &&
  self.row_count == other.row_count &&
  self.created_by == other.created_by &&
  self.column_values() == other.column_values()
}

///|
pub impl Show for ParquetColumnarFile with output(self, logger) {
  logger.write_string(
    "ParquetColumnarFile { columns: \{self.columns.length()}, row_count: \{self.row_count} }",
  )
}
