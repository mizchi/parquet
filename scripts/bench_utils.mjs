import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export const benchmarkOrder = [
  "read delta binary packed benchmark",
  "read int32 null pages benchmark",
  "read fixed length byte array benchmark",
  "read alltypes plain benchmark",
  "read alltypes dictionary benchmark",
  "read int96 from spark benchmark",
  "read empty snappy datapage v2 benchmark",
];

export function run(command, args) {
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
  return `${result.stdout}${result.stderr}`;
}

function unitToMicros(value, unit) {
  if (unit === "ns") return value / 1000;
  if (unit === "us" || unit === "µs") return value;
  if (unit === "ms") return value * 1000;
  if (unit === "s") return value * 1_000_000;
  throw new Error(`unknown time unit: ${unit}`);
}

export function parseMoonBench(output) {
  const lines = output.split(/\r?\n/);
  const results = new Map();
  let currentName = null;
  for (const line of lines) {
    const nameMatch = line.match(/bench .*?\("(.+?)"\) ok/);
    if (nameMatch) {
      currentName = nameMatch[1];
      continue;
    }
    if (!currentName) continue;
    const timeMatch = line.match(/^\s*([0-9.]+)\s*(ns|us|µs|ms|s)\s*±/);
    if (!timeMatch) continue;
    const mean = unitToMicros(Number(timeMatch[1]), timeMatch[2]);
    results.set(currentName, mean);
    currentName = null;
  }
  return results;
}

export function parseRustBench(output) {
  const results = new Map();
  for (const line of output.split(/\r?\n/)) {
    if (!line.includes("\t")) continue;
    const [name, status, value] = line.split("\t");
    if (status === "ok") {
      results.set(name, { kind: "ok", mean: Number(value) });
    } else if (status === "err") {
      results.set(name, { kind: "err", error: value });
    }
  }
  return results;
}

export function formatMicros(value) {
  if (value >= 1000) return `${(value / 1000).toFixed(2)} ms`;
  return `${value.toFixed(2)} us`;
}
