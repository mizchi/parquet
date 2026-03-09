export const DuckDBTypeId = {
  FLOAT: -1,
  DOUBLE: -1,
} as const;

export const DuckDBInstance = {
  async create(): Promise<never> {
    throw new Error('@duckdb/node-api is not available in the browser build');
  },
};
