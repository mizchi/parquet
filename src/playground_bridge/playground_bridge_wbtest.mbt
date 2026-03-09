///|
test "prepare_playground builds parquet bytes and preview rows" {
  let result = prepare_playground(
    ["id", "score", "name"],
    ["Int32", "Int64", "String"],
    ["Required", "Optional", "Optional"],
    [["1", "10", "alice"], ["2", "", "bob"], ["3", "30", ""]],
    [[false, false, false], [false, true, false], [false, false, true]],
  )
  match result {
    Err(message) => fail(message)
    Ok(prepared) => {
      assert_eq(prepared.preview.columns, ["id", "score", "name"])
      assert_eq(prepared.preview.rows, [
        ["1", "10", "alice"],
        ["2", "", "bob"],
        ["3", "30", ""],
      ])
      assert_eq(prepared.preview.nulls, [
        [false, false, false],
        [false, true, false],
        [false, false, true],
      ])
      assert_true(prepared.parquet_bytes.length() > 4)
    }
  }
}

///|
test "prepare_playground rejects null in required column" {
  let result = prepare_playground(["id"], ["Int32"], ["Required"], [[""]], [
    [true],
  ])
  match result {
    Ok(_) => fail("expected required-column validation error")
    Err(message) =>
      assert_eq(message, "required column `id` cannot be null at row 0")
  }
}
