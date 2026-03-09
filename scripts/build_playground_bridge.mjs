import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = resolve(root, 'playground/generated');
const buildDir = resolve(root, '_build/js/debug/build/cmd/playground_bridge');

const run = (command, args) => {
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: 'inherit',
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed with exit code ${result.status}`);
  }
};

run('moon', ['build', 'src/cmd/playground_bridge', '--target', 'js']);

mkdirSync(outputDir, { recursive: true });

for (const name of ['playground_bridge.js', 'playground_bridge.js.map']) {
  const source = resolve(buildDir, name);
  if (!existsSync(source)) {
    throw new Error(`generated bridge file was not found: ${source}`);
  }
  copyFileSync(source, resolve(outputDir, name));
}
