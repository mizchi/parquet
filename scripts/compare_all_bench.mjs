import {
  benchmarkOrder,
  formatMicros,
  parseMoonBench,
  parseRustBench,
  run,
} from "./bench_utils.mjs";

const moonTargets = {
  js: parseMoonBench(run("moon", ["bench", "--target", "js", "--release"])),
  "wasm-gc": parseMoonBench(
    run("moon", ["bench", "--target", "wasm-gc", "--release"]),
  ),
  native: parseMoonBench(run("moon", ["bench", "--target", "native", "--release"])),
};

const rust = parseRustBench(
  run("cargo", ["run", "--release", "--manifest-path", "tools/rust-bench/Cargo.toml"]),
);

console.log("| benchmark | moon(js) | moon(wasm-gc) | moon(native) | rust |");
console.log("|---|---:|---:|---:|---:|");
for (const name of benchmarkOrder) {
  const jsValue = moonTargets.js.get(name);
  const wasmGcValue = moonTargets["wasm-gc"].get(name);
  const nativeValue = moonTargets.native.get(name);
  const rustValue = rust.get(name);
  if (
    jsValue == null ||
    wasmGcValue == null ||
    nativeValue == null ||
    rustValue == null
  ) {
    throw new Error(`missing benchmark result for ${name}`);
  }
  const rustCell = rustValue.kind === "ok"
    ? formatMicros(rustValue.mean)
    : "unsupported";
  console.log(
    `| ${name} | ${formatMicros(jsValue)} | ${formatMicros(wasmGcValue)} | ${formatMicros(nativeValue)} | ${rustCell} |`,
  );
}
