import {
  benchmarkOrder,
  formatMicros,
  parseMoonBench,
  parseRustBench,
  run,
} from "./bench_utils.mjs";

const moon = parseMoonBench(run("moon", ["bench", "--target", "js", "--release"]));
const rust = parseRustBench(
  run("cargo", ["run", "--release", "--manifest-path", "tools/rust-bench/Cargo.toml"]),
);

console.log("| benchmark | moon(js) | rust | ratio |");
console.log("|---|---:|---:|---:|");
for (const name of benchmarkOrder) {
  const moonValue = moon.get(name);
  const rustValue = rust.get(name);
  if (moonValue == null || rustValue == null) {
    throw new Error(`missing benchmark result for ${name}`);
  }
  if (rustValue.kind !== "ok") {
    console.log(`| ${name} | ${formatMicros(moonValue)} | unsupported | n/a |`);
    continue;
  }
  console.log(
    `| ${name} | ${formatMicros(moonValue)} | ${formatMicros(rustValue.mean)} | ${(moonValue / rustValue.mean).toFixed(2)}x |`,
  );
}
