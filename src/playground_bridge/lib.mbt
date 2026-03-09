///|
let playground_file_name = "playground.parquet"

///|
fn parse_column_type(name : String) -> Result[@parquet.ColumnType, String] {
  if name == "Int32" {
    Ok(@parquet.Int32)
  } else if name == "Int64" {
    Ok(@parquet.Int64)
  } else if name == "String" {
    Ok(@parquet.String)
  } else {
    Err("unsupported column type: " + name)
  }
}

///|
fn parse_repetition(name : String) -> Result[@parquet.Repetition, String] {
  if name == "Required" {
    Ok(@parquet.Required)
  } else if name == "Optional" {
    Ok(@parquet.Optional)
  } else {
    Err("unsupported repetition: " + name)
  }
}

///|
fn parse_cell(
  type_name : String,
  value : String,
  is_null : Bool,
) -> Result[@parquet.Value, String] {
  if is_null {
    return Ok(@parquet.Value::Null)
  }
  if type_name == "Int32" {
    let parsed = @strconv.parse_int(value[:]) catch {
      err =>
        return Err(
          "invalid Int32 value: " + value + " (" + err.to_string() + ")",
        )
    }
    return Ok(@parquet.Value::Int32(parsed))
  }
  if type_name == "Int64" {
    let parsed = @strconv.parse_int64(value[:]) catch {
      err =>
        return Err(
          "invalid Int64 value: " + value + " (" + err.to_string() + ")",
        )
    }
    return Ok(@parquet.Value::Int64(parsed))
  }
  if type_name == "String" {
    return Ok(@parquet.Value::String(value))
  }
  Err("unsupported column type: " + type_name)
}

///|
fn value_to_cell(value : @parquet.Value) -> (String, Bool) {
  match value {
    @parquet.Value::Null => ("", true)
    @parquet.Value::Int32(v) => (v.to_string(), false)
    @parquet.Value::Int64(v) => (v.to_string(), false)
    @parquet.Value::TimestampMicros(v) => (v.to_string(), false)
    @parquet.Value::Boolean(v) => (v.to_string(), false)
    @parquet.Value::Float(v) => (v.to_string(), false)
    @parquet.Value::Double(v) => (v.to_string(), false)
    @parquet.Value::String(v) => (v, false)
    @parquet.Value::Binary(v) => (v.to_unchecked_string(), false)
  }
}

///|
fn table_from_parquet(file : @parquet.ParquetFile) -> PlaygroundTable {
  let rows : Array[Array[String]] = []
  let nulls : Array[Array[Bool]] = []
  for row in file.rows() {
    let out_row : Array[String] = []
    let out_nulls : Array[Bool] = []
    for value in row {
      let (cell, is_null) = value_to_cell(value)
      out_row.push(cell)
      out_nulls.push(is_null)
    }
    rows.push(out_row)
    nulls.push(out_nulls)
  }
  { columns: file.columns().map(fn(column) { column.name() }), rows, nulls }
}

///|
fn build_columns(
  schema_names : Array[String],
  schema_types : Array[String],
  schema_repetitions : Array[String],
) -> Result[Array[@parquet.Column], String] {
  let count = schema_names.length()
  if count == 0 {
    return Err("schema must contain at least one column")
  }
  if schema_types.length() != count {
    return Err("schema type count did not match schema name count")
  }
  if schema_repetitions.length() != count {
    return Err("schema repetition count did not match schema name count")
  }
  let columns : Array[@parquet.Column] = []
  for index in 0..<count {
    if schema_names[index].is_empty() {
      return Err("column name must not be empty at index \{index}")
    }
    let column_type = match parse_column_type(schema_types[index]) {
      Ok(value) => value
      Err(message) =>
        return Err(message + " at column `" + schema_names[index] + "`")
    }
    let repetition = match parse_repetition(schema_repetitions[index]) {
      Ok(value) => value
      Err(message) =>
        return Err(message + " at column `" + schema_names[index] + "`")
    }
    columns.push(
      @parquet.new_column(schema_names[index], column_type, repetition),
    )
  }
  Ok(columns)
}

///|
fn build_rows(
  columns : Array[@parquet.Column],
  schema_types : Array[String],
  row_values : Array[Array[String]],
  row_nulls : Array[Array[Bool]],
) -> Result[Array[Array[@parquet.Value]], String] {
  if row_values.length() != row_nulls.length() {
    return Err("row value count did not match row null count")
  }
  let rows : Array[Array[@parquet.Value]] = []
  for row_index in 0..<row_values.length() {
    let values = row_values[row_index]
    let nulls = row_nulls[row_index]
    if values.length() != columns.length() {
      return Err(
        "row \{row_index} value count \{values.length()} did not match schema width \{columns.length()}",
      )
    }
    if nulls.length() != columns.length() {
      return Err(
        "row \{row_index} null count \{nulls.length()} did not match schema width \{columns.length()}",
      )
    }
    let row : Array[@parquet.Value] = []
    for col_index in 0..<columns.length() {
      let column = columns[col_index]
      if nulls[col_index] && column.repetition() == @parquet.Required {
        return Err(
          "required column `" +
          column.name() +
          "` cannot be null at row \{row_index}",
        )
      }
      let value = match
        parse_cell(schema_types[col_index], values[col_index], nulls[col_index]) {
        Ok(parsed) => parsed
        Err(message) =>
          return Err(
            message + " at row \{row_index}, column `" + column.name() + "`",
          )
      }
      row.push(value)
    }
    rows.push(row)
  }
  Ok(rows)
}

///|
fn prepare_playground(
  schema_names : Array[String],
  schema_types : Array[String],
  schema_repetitions : Array[String],
  row_values : Array[Array[String]],
  row_nulls : Array[Array[Bool]],
) -> Result[PreparedPlayground, String] {
  let columns = match
    build_columns(schema_names, schema_types, schema_repetitions) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let rows = match build_rows(columns, schema_types, row_values, row_nulls) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let bytes = @parquet.write_bytes(
    @parquet.new_parquet_file(columns, rows, Some("parquet-browser-playground")),
  ) catch {
    err => return Err("failed to encode parquet: " + err.to_string())
  }
  let preview_file = @parquet.read_bytes(bytes) catch {
    err => return Err("failed to decode generated parquet: " + err.to_string())
  }
  Ok({ parquet_bytes: bytes, preview: table_from_parquet(preview_file) })
}

///|
pub fn run_playground(
  schema_names : Array[String],
  schema_types : Array[String],
  schema_repetitions : Array[String],
  row_values : Array[Array[String]],
  row_nulls : Array[Array[Bool]],
  sql : String,
  on_done~ : (Result[PlaygroundResult, String]) -> Unit,
) -> Unit {
  let prepared = match
    prepare_playground(
      schema_names, schema_types, schema_repetitions, row_values, row_nulls,
    ) {
    Ok(value) => value
    Err(message) => {
      on_done(Err(message))
      return
    }
  }
  query_registered_parquet(prepared.parquet_bytes, playground_file_name, sql, fn(
    query_result,
  ) {
    match query_result {
      Ok(query) =>
        on_done(
          Ok({
            parquet_bytes: prepared.parquet_bytes,
            parquet_size: prepared.parquet_bytes.length(),
            parquet_file_name: playground_file_name,
            preview: prepared.preview,
            query,
          }),
        )
      Err(message) => on_done(Err(message))
    }
  })
}
