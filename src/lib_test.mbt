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
    @parquet.Value::TimestampMicros(v) => v.to_string()
    @parquet.Value::Boolean(v) => v.to_string()
    @parquet.Value::Float(v) => v.to_string()
    @parquet.Value::Double(v) => v.to_string()
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
fn bytes_to_hex(bytes : Bytes) -> String {
  let out = StringBuilder::new()
  for byte in bytes {
    let value = byte.to_int()
    let high = value / 16
    let low = value % 16
    out.write_char(
      if high < 10 {
        Int::unsafe_to_char(48 + high)
      } else {
        Int::unsafe_to_char(55 + high)
      },
    )
    out.write_char(
      if low < 10 {
        Int::unsafe_to_char(48 + low)
      } else {
        Int::unsafe_to_char(55 + low)
      },
    )
  }
  out.to_string()
}

///|
fn read_parquet_fixture(name : String) -> @parquet.ParquetFile raise {
  @parquet.read_bytes(read_fixture(name)) catch {
    err => {
      println(err)
      raise err
    }
  }
}

///|
fn assert_timestamp_micros(
  value : @parquet.Value,
  expected : Int64,
) -> Unit raise {
  match value {
    @parquet.Value::TimestampMicros(v) => assert_eq(v, expected)
    _ => assert_true(false)
  }
}

///|
fn assert_text_value(value : @parquet.Value, expected : String) -> Unit raise {
  match value {
    @parquet.Value::String(v) => assert_eq(v, expected)
    @parquet.Value::Binary(v) => assert_eq(@utf8.decode_lossy(v[:]), expected)
    _ => assert_true(false)
  }
}

///|
fn assert_row_shape(
  row : Array[@parquet.Value],
  expected_id : Int,
  expected_bool : Bool,
  expected_date : String,
  expected_string : String,
  expected_timestamp_micros : Int64,
) -> Unit raise {
  assert_eq(row.length(), 11)
  match row[0] {
    @parquet.Value::Int32(v) => assert_eq(v, expected_id)
    _ => assert_true(false)
  }
  match row[1] {
    @parquet.Value::Boolean(v) => assert_eq(v, expected_bool)
    _ => assert_true(false)
  }
  match row[2] {
    @parquet.Value::Int32(v) => assert_eq(v, expected_id % 2)
    _ => assert_true(false)
  }
  match row[3] {
    @parquet.Value::Int32(v) => assert_eq(v, expected_id % 2)
    _ => assert_true(false)
  }
  match row[4] {
    @parquet.Value::Int32(v) => assert_eq(v, expected_id % 2)
    _ => assert_true(false)
  }
  match row[5] {
    @parquet.Value::Int64(v) =>
      assert_eq(v, if expected_id % 2 == 0 { 0L } else { 10L })
    _ => assert_true(false)
  }
  match row[6] {
    @parquet.Value::Float(v) =>
      assert_eq(
        v.reinterpret_as_uint(),
        if expected_id % 2 == 0 {
          0
        } else {
          0x3F8CCCCD
        },
      )
    _ => assert_true(false)
  }
  match row[7] {
    @parquet.Value::Double(v) =>
      assert_eq(
        v.reinterpret_as_uint64(),
        if expected_id % 2 == 0 {
          0L.reinterpret_as_uint64()
        } else {
          4621875412584313651L.reinterpret_as_uint64()
        },
      )
    _ => assert_true(false)
  }
  match row[8] {
    value => assert_text_value(value, expected_date)
  }
  match row[9] {
    value => assert_text_value(value, expected_string)
  }
  assert_timestamp_micros(row[10], expected_timestamp_micros)
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
test "reads int32 fixture with null pages" {
  let file = try! @parquet.read_bytes(
    read_fixture("int32_with_null_pages.parquet"),
  )
  assert_eq(file.columns().length(), 1)
  assert_eq(file.columns()[0].name(), "int32_field")
  assert_eq(file.rows().length(), 1000)
  let mut null_count = 0
  let mut min_value = 2147483647
  let mut max_value = -2147483648
  let first_twelve : Array[String] = []
  for row_index in 0..<file.rows().length() {
    let value = file.rows()[row_index][0]
    if row_index < 12 {
      first_twelve.push(value_to_cell(value))
    }
    match value {
      @parquet.Value::Int32(v) => {
        if v < min_value {
          min_value = v
        }
        if v > max_value {
          max_value = v
        }
      }
      @parquet.Value::Null => null_count += 1
      _ => assert_true(false)
    }
  }
  assert_eq(null_count, 275)
  assert_eq(min_value, -2136906554)
  assert_eq(max_value, 2145722375)
  assert_eq(first_twelve, [
    "-654807448", "-465559769", "-34563097", "398454479", "", "2018642597", "486675473",
    "546345848", "-117215667", "-352034204", "-1172816214", "-2023202216",
  ])
}

///|
test "reads fixed length byte array fixture" {
  let file = try! @parquet.read_bytes(
    read_fixture("fixed_length_byte_array.parquet"),
  )
  assert_eq(file.columns().length(), 1)
  assert_eq(file.columns()[0].name(), "flba_field")
  assert_eq(file.columns()[0].column_type(), @parquet.Binary)
  assert_eq(file.rows().length(), 1000)
  let values : Array[String] = []
  for row in file.rows() {
    match row[0] {
      @parquet.Value::Binary(bytes) => values.push(bytes_to_hex(bytes))
      @parquet.Value::Null => assert_true(false)
      _ => assert_true(false)
    }
  }
  assert_eq(values[0], "000003E8")
  assert_eq(values[1], "000003E7")
  assert_eq(values[2], "000003E6")
  assert_eq(values[3], "000003E5")
  assert_eq(values[4], "000003E4")
  assert_eq(values[5], "000003E3")
  assert_eq(values[6], "000003E2")
  assert_eq(values[7], "000003E1")
  assert_eq(values[8], "000003DF")
  assert_eq(values[9], "000003DE")
  assert_eq(values[10], "000003DD")
  assert_eq(values[11], "000003DC")
}

///|
test "reads empty snappy datapage v2 fixture" {
  let file = try! read_parquet_fixture(
    "datapage_v2_empty_datapage.snappy.parquet",
  )
  assert_eq(file.columns().length(), 1)
  assert_eq(file.columns()[0].name(), "value")
  assert_eq(file.columns()[0].column_type(), @parquet.Float)
  assert_eq(file.rows().length(), 1)
  assert_eq(file.rows()[0].length(), 1)
  assert_eq(file.rows()[0][0], @parquet.Value::Null)
}

///|
test "reads int96 from spark fixture" {
  let file = try! read_parquet_fixture("int96_from_spark.parquet")
  assert_eq(file.columns().length(), 1)
  assert_eq(file.columns()[0].name(), "a")
  assert_eq(file.columns()[0].column_type(), @parquet.TimestampMicros)
  assert_eq(file.rows().length(), 6)
  assert_timestamp_micros(file.rows()[0][0], 1704141296123456L)
  assert_timestamp_micros(file.rows()[1][0], 1704070800000000L)
  assert_timestamp_micros(file.rows()[2][0], 253402225200000000L)
  assert_timestamp_micros(file.rows()[3][0], 1735599600000000L)
  assert_eq(file.rows()[4][0], @parquet.Value::Null)
  assert_timestamp_micros(file.rows()[5][0], 9089380393200000000L)
}

///|
test "reads alltypes plain fixture" {
  let file = try! read_parquet_fixture("alltypes_plain.parquet")
  assert_eq(file.columns().length(), 11)
  assert_eq(file.rows().length(), 8)
  assert_eq(file.columns()[0].name(), "id")
  assert_eq(file.columns()[0].column_type(), @parquet.Int32)
  assert_eq(file.columns()[1].name(), "bool_col")
  assert_eq(file.columns()[1].column_type(), @parquet.Boolean)
  assert_eq(file.columns()[6].name(), "float_col")
  assert_eq(file.columns()[6].column_type(), @parquet.Float)
  assert_eq(file.columns()[7].name(), "double_col")
  assert_eq(file.columns()[7].column_type(), @parquet.Double)
  assert_eq(file.columns()[10].name(), "timestamp_col")
  assert_eq(file.columns()[10].column_type(), @parquet.TimestampMicros)
  assert_row_shape(file.rows()[0], 4, true, "03/01/09", "0", 1235865600000000L)
  assert_row_shape(file.rows()[1], 5, false, "03/01/09", "1", 1235865660000000L)
  assert_row_shape(file.rows()[6], 0, true, "01/01/09", "0", 1230768000000000L)
  assert_row_shape(file.rows()[7], 1, false, "01/01/09", "1", 1230768060000000L)
}

///|
test "reads alltypes dictionary fixture" {
  let file = try! read_parquet_fixture("alltypes_dictionary.parquet")
  assert_eq(file.columns().length(), 11)
  assert_eq(file.rows().length(), 2)
  assert_eq(file.columns()[10].column_type(), @parquet.TimestampMicros)
  assert_row_shape(file.rows()[0], 0, true, "01/01/09", "0", 1230768000000000L)
  assert_row_shape(file.rows()[1], 1, false, "01/01/09", "1", 1230768060000000L)
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
