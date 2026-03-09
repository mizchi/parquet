import type { BridgeInput } from './lib/input.ts';

export type PlaygroundTable = {
  columns: string[];
  rows: string[][];
  nulls: boolean[][];
};

export type PlaygroundResult = {
  parquetBytes: Uint8Array;
  parquetSize: number;
  parquetFileName: string;
  preview: PlaygroundTable;
  query: PlaygroundTable;
};

declare global {
  interface Window {
    parquetDuckdbPlayground?: {
      runPlayground(input: BridgeInput): Promise<PlaygroundResult>;
    };
  }
}

export {};
