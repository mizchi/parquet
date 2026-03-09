///|
extern "js" fn js_clone_bytes(bytes : Bytes) -> Bytes =
  #|(bytes) => new Uint8Array(bytes)

///|
extern "js" fn js_connect_local_wasm(
  on_ok : (@duckdb.Connection) -> Unit,
  on_err : (String) -> Unit,
) -> Unit =
  #|(on_ok, on_err) => {
  #|  const toError = (err) => err && err.message ? err.message : String(err);
  #|  const run = async () => {
  #|    const duckdb = await import("@duckdb/duckdb-wasm");
  #|    const mvpWorker = (await import("@duckdb/duckdb-wasm/dist/duckdb-browser-mvp.worker.js?url")).default;
  #|    const ehWorker = (await import("@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js?url")).default;
  #|    const mvpModule = (await import("@duckdb/duckdb-wasm/dist/duckdb-mvp.wasm?url")).default;
  #|    const ehModule = (await import("@duckdb/duckdb-wasm/dist/duckdb-eh.wasm?url")).default;
  #|    const bundle = await duckdb.selectBundle({
  #|      mvp: { mainModule: mvpModule, mainWorker: mvpWorker },
  #|      eh: { mainModule: ehModule, mainWorker: ehWorker },
  #|    });
  #|    const logger = new duckdb.ConsoleLogger();
  #|    const worker = new Worker(bundle.mainWorker);
  #|    const db = new duckdb.AsyncDuckDB(logger, worker);
  #|    await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  #|    const conn = await db.connect();
  #|    on_ok({ kind: "wasm", db, conn, worker });
  #|  };
  #|  run().catch((err) => on_err(toError(err)));
  #|}

///|
extern "js" fn js_register_file_buffer(
  conn : @duckdb.Connection,
  file_name : String,
  bytes : Bytes,
  on_ok : () -> Unit,
  on_err : (String) -> Unit,
) -> Unit =
  #|(conn, file_name, bytes, on_ok, on_err) => {
  #|  const toError = (err) => err && err.message ? err.message : String(err);
  #|  const run = async () => {
  #|    if (!conn || conn.kind !== "wasm" || !conn.db) {
  #|      throw new Error("registerFileBuffer requires DuckDB WASM backend");
  #|    }
  #|    if (typeof conn.db.dropFile === "function") {
  #|      try {
  #|        await conn.db.dropFile(file_name);
  #|      } catch (_) {
  #|      }
  #|    }
  #|    await conn.db.registerFileBuffer(file_name, bytes);
  #|    on_ok();
  #|  };
  #|  run().catch((err) => on_err(toError(err)));
  #|}

///|
fn register_file_buffer(
  conn : @duckdb.Connection,
  file_name : String,
  bytes : Bytes,
  on_done : (Result[Unit, String]) -> Unit,
) -> Unit {
  js_register_file_buffer(
    conn,
    file_name,
    js_clone_bytes(bytes),
    fn() { on_done(Ok(())) },
    fn(message) { on_done(Err(message)) },
  )
}

///|
fn connect_local_wasm(
  on_done : (Result[@duckdb.Connection, String]) -> Unit,
) -> Unit {
  js_connect_local_wasm(fn(conn) { on_done(Ok(conn)) }, fn(message) {
    on_done(Err(message))
  })
}

///|
pub fn query_registered_parquet(
  parquet_bytes : Bytes,
  file_name : String,
  sql : String,
  on_done : (Result[PlaygroundTable, String]) -> Unit,
) -> Unit {
  connect_local_wasm(fn(connect_result) {
    match connect_result {
      Err(message) => on_done(Err("duckdb connect failed: " + message))
      Ok(conn) =>
        register_file_buffer(conn, file_name, parquet_bytes, fn(
          register_result,
        ) {
          match register_result {
            Err(message) =>
              close_with_result(
                conn,
                Err("duckdb register failed: " + message),
                on_done,
              )
            Ok(_) =>
              conn.query(sql, on_done=fn(query_result) {
                match query_result {
                  Err(@duckdb.DuckDBError::Message(message)) =>
                    close_with_result(
                      conn,
                      Err("duckdb query failed: " + message),
                      on_done,
                    )
                  Ok(result) =>
                    close_with_result(
                      conn,
                      Ok({
                        columns: result.columns,
                        rows: result.rows,
                        nulls: result.nulls,
                      }),
                      on_done,
                    )
                }
              })
          }
        })
    }
  })
}

///|
fn close_with_result(
  conn : @duckdb.Connection,
  result : Result[PlaygroundTable, String],
  on_done : (Result[PlaygroundTable, String]) -> Unit,
) -> Unit {
  conn.close(on_done=fn(close_result) {
    match close_result {
      Ok(_) => on_done(result)
      Err(@duckdb.DuckDBError::Message(message)) =>
        match result {
          Ok(_) => on_done(Err("duckdb close failed: " + message))
          Err(error) =>
            on_done(Err(error + "; duckdb close also failed: " + message))
        }
    }
  })
}
