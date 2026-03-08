import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(
      [
        `${command} ${args.join(" ")} failed with exit code ${result.status}`,
        result.stdout.trim(),
        result.stderr.trim(),
      ]
        .filter(Boolean)
        .join("\n"),
    );
  }
  return result.stdout;
}

function sqlPath(path) {
  return path.replaceAll("'", "''");
}

const tmpDir = fs.mkdtempSync(join(os.tmpdir(), "parquet-duckdb-e2e-"));
const duckdbParquetPath = join(tmpDir, "from_duckdb.parquet");
const moonbitParquetPath = join(tmpDir, "from_moonbit.parquet");

run("duckdb", [
  ":memory:",
  "-c",
  `COPY (
    SELECT 1::INTEGER AS id, 10::BIGINT AS score, 'alice'::VARCHAR AS name
    UNION ALL
    SELECT 2::INTEGER AS id, NULL::BIGINT AS score, 'bob'::VARCHAR AS name
    UNION ALL
    SELECT 3::INTEGER AS id, 30::BIGINT AS score, NULL::VARCHAR AS name
  ) TO '${sqlPath(duckdbParquetPath)}' (FORMAT PARQUET)`,
]);

run("moon", [
  "run",
  "src/cmd/duckdb_e2e",
  "--target",
  "js",
  "--",
  "verify-read",
  duckdbParquetPath,
]);

run("moon", [
  "run",
  "src/cmd/duckdb_e2e",
  "--target",
  "js",
  "--",
  "write-sample",
  moonbitParquetPath,
]);

const output = run("duckdb", [
  ":memory:",
  "-json",
  "-noheader",
  "-c",
  `SELECT id, score, name FROM '${sqlPath(moonbitParquetPath)}' ORDER BY id`,
]);
const actual = JSON.parse(output);
const expected = [
  { id: 1, score: 10, name: "alice" },
  { id: 2, score: null, name: "bob" },
  { id: 3, score: 30, name: null },
];

if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(
    `duckdb read mismatch\nactual: ${JSON.stringify(actual)}\nexpected: ${JSON.stringify(expected)}`,
  );
}

console.log("duckdb e2e ok");
