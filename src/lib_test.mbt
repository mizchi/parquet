///|
fn parse_csv(text : String) -> Array[Array[String]] {
  let chars = text.to_array()
  let rows : Array[Array[String]] = []
  let mut row : Array[String] = []
  let field = StringBuilder::new()
  let mut in_quotes = false
  let mut index = 0
  while index < chars.length() {
    let ch = chars[index]
    if in_quotes {
      if ch == '"' {
        if index + 1 < chars.length() && chars[index + 1] == '"' {
          field.write_char('"')
          index += 1
        } else {
          in_quotes = false
        }
      } else {
        field.write_char(ch)
      }
    } else if ch == '"' {
      in_quotes = true
    } else if ch == ',' {
      row.push(field.to_string())
      field.reset()
    } else if ch == '\n' {
      row.push(field.to_string())
      field.reset()
      rows.push(row)
      row = []
    } else if ch == '\r' {
      ()
    } else {
      field.write_char(ch)
    }
    index += 1
  }
  if not(in_quotes) && (not(field.is_empty()) || not(row.is_empty())) {
    row.push(field.to_string())
    rows.push(row)
  }
  rows
}

///|
fn normalize_fixture_header(value : String) -> String {
  value.trim().to_string()
}

///|
fn value_to_cell(value : @parquet.Value) -> String {
  match value {
    @parquet.Value::Null => ""
    @parquet.Value::Int32(v) => v.to_string()
    @parquet.Value::Int64(v) => v.to_string()
    @parquet.Value::String(v) => v
    @parquet.Value::Binary(v) => v.to_unchecked_string()
  }
}

///|
fn table_to_cells(file : @parquet.ParquetFile) -> Array[Array[String]] {
  let header = file.columns().map(fn(column) { column.name() })
  let body = file.rows().map(fn(row) { row.map(value_to_cell) })
  [header] + body
}

///|
fn read_fixture(name : String) -> Bytes {
  try! @fs.read_file_to_bytes("fixtures/apache-parquet-testing/data/" + name)
}

///|
fn read_fixture_text(name : String) -> String {
  try! @fs.read_file_to_string("fixtures/apache-parquet-testing/data/" + name)
}

///|
fn assert_fixture(
  parquet_name : String,
  expected_csv_name : String,
) -> Unit raise {
  let file = try! @parquet.read_bytes(read_fixture(parquet_name))
  let expected = parse_csv(read_fixture_text(expected_csv_name))
  let actual = table_to_cells(file)
  assert_eq(actual.length(), expected.length())
  for row_index in 0..<expected.length() {
    assert_eq(actual[row_index].length(), expected[row_index].length())
    for col_index in 0..<expected[row_index].length() {
      let actual_value = if row_index == 0 {
        normalize_fixture_header(actual[row_index][col_index])
      } else {
        actual[row_index][col_index]
      }
      let expected_value = if row_index == 0 {
        normalize_fixture_header(expected[row_index][col_index])
      } else {
        expected[row_index][col_index]
      }
      assert_eq(actual_value, expected_value)
    }
  }
}

///|
test "reads delta binary packed fixture" {
  assert_fixture(
    "delta_binary_packed.parquet", "delta_binary_packed_expect.csv",
  )
}

///|
test "reads delta byte array fixture" {
  assert_fixture("delta_byte_array.parquet", "delta_byte_array_expect.csv")
}

///|
test "reads delta optional columns fixture" {
  assert_fixture(
    "delta_encoding_optional_column.parquet", "delta_encoding_optional_column_expect.csv",
  )
}

///|
test "reads delta required columns fixture" {
  assert_fixture(
    "delta_encoding_required_column.parquet", "delta_encoding_required_column_expect.csv",
  )
}

///|
test "writes a flat parquet file that round-trips" {
  let file = @parquet.new_parquet_file(
    [
      @parquet.new_column("id", @parquet.Int32, @parquet.Required),
      @parquet.new_column("score", @parquet.Int64, @parquet.Optional),
      @parquet.new_column("name", @parquet.String, @parquet.Optional),
    ],
    [
      [
        @parquet.Value::Int32(1),
        @parquet.Value::Int64(10L),
        @parquet.Value::String("alice"),
      ],
      [
        @parquet.Value::Int32(2),
        @parquet.Value::Null,
        @parquet.Value::String("bob"),
      ],
      [
        @parquet.Value::Int32(3),
        @parquet.Value::Int64(30L),
        @parquet.Value::Null,
      ],
    ],
    Some("test"),
  )
  let encoded = try! @parquet.write_bytes(file)
  let decoded = try! @parquet.read_bytes(encoded)
  assert_eq(decoded.columns(), file.columns())
  assert_eq(decoded.rows(), file.rows())
}
