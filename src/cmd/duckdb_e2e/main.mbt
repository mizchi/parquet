///|
fn fail(message : String) -> Unit {
  abort(message)
}

///|
fn sample_file() -> @parquet.ParquetFile {
  @parquet.new_parquet_file(
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
    Some("duckdb-e2e"),
  )
}

///|
fn verify_columns(file : @parquet.ParquetFile) -> Unit {
  let columns = file.columns()
  if columns.length() != 3 {
    fail("expected 3 columns, got \{columns.length()}")
  }
  if columns[0].name() != "id" || columns[0].column_type() != @parquet.Int32 {
    fail("unexpected id column")
  }
  if columns[1].name() != "score" || columns[1].column_type() != @parquet.Int64 {
    fail("unexpected score column")
  }
  if columns[2].name() != "name" || columns[2].column_type() != @parquet.String {
    fail("unexpected name column")
  }
}

///|
fn verify_rows(file : @parquet.ParquetFile) -> Unit {
  let expected = sample_file().rows()
  if file.rows() != expected {
    fail("rows did not match expected sample")
  }
}

///|
fn verify_read(path : String) -> Unit {
  let file = try! @parquet.read_file(path)
  verify_columns(file)
  verify_rows(file)
}

///|
fn write_sample(path : String) -> Unit {
  try! @parquet.write_file(path, sample_file())
}

///|
fn usage() -> Unit {
  println(
    "usage: moon run src/cmd/duckdb_e2e -- <verify-read|write-sample> <path>",
  )
}

///|
fn main {
  let args = @sys.get_cli_args()
  if args.length() != 3 {
    usage()
    fail("invalid arguments")
  }
  let command = args[1]
  let path = args[2]
  if command == "verify-read" {
    verify_read(path)
  } else if command == "write-sample" {
    write_sample(path)
  } else {
    usage()
    fail("unknown command: " + command)
  }
}
