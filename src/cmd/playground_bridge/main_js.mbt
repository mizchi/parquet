///|
extern "js" fn install_bridge(
  run_playground : (
    Array[String],
    Array[String],
    Array[String],
    Array[Array[String]],
    Array[Array[Bool]],
    String,
    (@playground.PlaygroundResult) -> Unit,
    (String) -> Unit,
  ) -> Unit,
) -> Unit =
  #|(run_playground) => {
  #|  const toBytes = (value) => {
  #|    if (value instanceof Uint8Array) {
  #|      return new Uint8Array(value);
  #|    }
  #|    if (Array.isArray(value)) {
  #|      return Uint8Array.from(value);
  #|    }
  #|    if (value && typeof value.length === "number") {
  #|      return Uint8Array.from(value);
  #|    }
  #|    if (value && value.buffer instanceof ArrayBuffer) {
  #|      return new Uint8Array(
  #|        value.buffer,
  #|        value.byteOffset || 0,
  #|        value.byteLength || value.buffer.byteLength,
  #|      );
  #|    }
  #|    if (value && typeof value === "object") {
  #|      const keys = Object.keys(value)
  #|        .filter((key) => /^\d+$/.test(key))
  #|        .sort((a, b) => Number(a) - Number(b));
  #|      if (keys.length > 0) {
  #|        return Uint8Array.from(keys.map((key) => value[key]));
  #|      }
  #|    }
  #|    return new Uint8Array();
  #|  };
  #|  globalThis.parquetDuckdbPlayground = {
  #|    runPlayground(input) {
  #|      return new Promise((resolve, reject) => {
  #|        run_playground(
  #|          input.schemaNames,
  #|          input.schemaTypes,
  #|          input.schemaRepetitions,
  #|          input.rowValues,
  #|          input.rowNulls,
  #|          input.sql,
  #|          (result) => {
  #|            const parquetBytes = toBytes(result.parquet_bytes);
  #|            resolve({
  #|              parquetBytes,
  #|              parquetSize: parquetBytes.byteLength,
  #|              parquetFileName: result.parquet_file_name,
  #|              preview: result.preview,
  #|              query: result.query,
  #|            });
  #|          },
  #|          reject,
  #|        );
  #|      });
  #|    },
  #|  };
  #|}

///|
fn main {
  install_bridge(fn(
    schema_names,
    schema_types,
    schema_repetitions,
    row_values,
    row_nulls,
    sql,
    on_ok,
    on_err,
  ) {
    @playground.run_playground(
      schema_names,
      schema_types,
      schema_repetitions,
      row_values,
      row_nulls,
      sql,
      on_done=fn(result) {
        match result {
          Ok(value) => on_ok(value)
          Err(message) => on_err(message)
        }
      },
    )
  })
}
