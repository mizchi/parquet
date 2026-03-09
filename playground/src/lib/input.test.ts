import { describe, expect, test } from 'vitest';
import { toBridgeInput } from './input.ts';

describe('toBridgeInput', () => {
  test('converts schema and rows JSON to bridge arrays', () => {
    const result = toBridgeInput(
      JSON.stringify(
        [
          { name: 'id', type: 'Int32', repetition: 'Required' },
          { name: 'score', type: 'Int64', repetition: 'Optional' },
          { name: 'name', type: 'String', repetition: 'Optional' },
        ],
        null,
        2,
      ),
      JSON.stringify(
        [
          { id: 1, score: 10, name: 'alice' },
          { id: 2, score: null, name: 'bob' },
          { id: 3, score: 30, name: null },
        ],
        null,
        2,
      ),
      "select * from read_parquet('playground.parquet') order by id",
    );

    expect(result).toEqual({
      schemaNames: ['id', 'score', 'name'],
      schemaTypes: ['Int32', 'Int64', 'String'],
      schemaRepetitions: ['Required', 'Optional', 'Optional'],
      rowValues: [
        ['1', '10', 'alice'],
        ['2', '', 'bob'],
        ['3', '30', ''],
      ],
      rowNulls: [
        [false, false, false],
        [false, true, false],
        [false, false, true],
      ],
      sql: "select * from read_parquet('playground.parquet') order by id",
    });
  });

  test('fills missing optional fields with nulls', () => {
    const result = toBridgeInput(
      JSON.stringify([{ name: 'name', type: 'String', repetition: 'Optional' }]),
      JSON.stringify([{}]),
      'select 1',
    );

    expect(result.rowValues).toEqual([['']]);
    expect(result.rowNulls).toEqual([[true]]);
  });

  test('rejects null in required columns', () => {
    expect(() =>
      toBridgeInput(
        JSON.stringify([{ name: 'id', type: 'Int32', repetition: 'Required' }]),
        JSON.stringify([{ id: null }]),
        'select 1',
      ),
    ).toThrowError('required field `id` cannot be null at row 0');
  });

  test('rejects non integer values for Int32 columns', () => {
    expect(() =>
      toBridgeInput(
        JSON.stringify([{ name: 'id', type: 'Int32', repetition: 'Required' }]),
        JSON.stringify([{ id: 1.25 }]),
        'select 1',
      ),
    ).toThrowError('field `id` must be a 32-bit integer at row 0');
  });
});
