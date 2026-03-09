import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig(() => {
  const base = process.env.PLAYGROUND_BASE_PATH ?? '/';

  return {
    base,
    resolve: {
      alias: {
        '@duckdb/node-api': resolve(__dirname, 'src/stubs/duckdb-node-api.ts'),
      },
    },
    server: {
      port: 4173,
    },
  };
});
