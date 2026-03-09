export type SchemaType = 'Int32' | 'Int64' | 'String';
export type Repetition = 'Required' | 'Optional';

export type SchemaField = {
  name: string;
  type: SchemaType;
  repetition: Repetition;
};

export type BridgeInput = {
  schemaNames: string[];
  schemaTypes: SchemaType[];
  schemaRepetitions: Repetition[];
  rowValues: string[][];
  rowNulls: boolean[][];
  sql: string;
};

type RowRecord = Record<string, unknown>;

const INT32_MIN = -2147483648;
const INT32_MAX = 2147483647;
const INT64_PATTERN = /^-?\d+$/;

const parseJson = (text: string, label: string): unknown => {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} must be valid JSON: ${String(error)}`);
  }
};

const expectArray = <T>(value: unknown, label: string): T[] => {
  if (!Array.isArray(value)) {
    throw new Error(`${label} must be a JSON array`);
  }
  return value as T[];
};

const isObjectRecord = (value: unknown): value is RowRecord =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const assertSchemaType = (value: unknown, index: number): SchemaType => {
  if (value === 'Int32' || value === 'Int64' || value === 'String') {
    return value;
  }
  throw new Error(`schema[${index}].type must be one of Int32, Int64, String`);
};

const assertRepetition = (value: unknown, index: number): Repetition => {
  if (value === 'Required' || value === 'Optional') {
    return value;
  }
  throw new Error(`schema[${index}].repetition must be Required or Optional`);
};

const parseSchemaField = (value: unknown, index: number): SchemaField => {
  if (!isObjectRecord(value)) {
    throw new Error(`schema[${index}] must be an object`);
  }
  if (typeof value.name !== 'string' || value.name.trim() === '') {
    throw new Error(`schema[${index}].name must be a non-empty string`);
  }
  return {
    name: value.name,
    type: assertSchemaType(value.type, index),
    repetition: assertRepetition(value.repetition, index),
  };
};

export const parseSchema = (text: string): SchemaField[] => {
  const schema = expectArray<unknown>(parseJson(text, 'Schema'), 'Schema').map(
    parseSchemaField,
  );
  if (schema.length === 0) {
    throw new Error('Schema must contain at least one column');
  }
  const names = new Set<string>();
  for (const field of schema) {
    if (names.has(field.name)) {
      throw new Error(`schema contains duplicate column \`${field.name}\``);
    }
    names.add(field.name);
  }
  return schema;
};

const normalizeIntegerString = (value: number | string): string => {
  if (typeof value === 'number') {
    return value.toString(10);
  }
  return value.trim();
};

const normalizeCell = (
  row: RowRecord,
  field: SchemaField,
  rowIndex: number,
): { value: string; isNull: boolean } => {
  const rawValue = row[field.name];
  if (rawValue === undefined || rawValue === null) {
    if (field.repetition === 'Required') {
      throw new Error(`required field \`${field.name}\` cannot be null at row ${rowIndex}`);
    }
    return { value: '', isNull: true };
  }

  if (field.type === 'String') {
    if (typeof rawValue !== 'string') {
      throw new Error(`field \`${field.name}\` must be a string at row ${rowIndex}`);
    }
    return { value: rawValue, isNull: false };
  }

  if (typeof rawValue !== 'number' && typeof rawValue !== 'string') {
    throw new Error(`field \`${field.name}\` must be an integer at row ${rowIndex}`);
  }

  const normalized = normalizeIntegerString(rawValue);
  if (field.type === 'Int32') {
    if (!INT64_PATTERN.test(normalized)) {
      throw new Error(`field \`${field.name}\` must be a 32-bit integer at row ${rowIndex}`);
    }
    const parsed = Number(normalized);
    if (!Number.isSafeInteger(parsed) || parsed < INT32_MIN || parsed > INT32_MAX) {
      throw new Error(`field \`${field.name}\` must be a 32-bit integer at row ${rowIndex}`);
    }
    return { value: normalized, isNull: false };
  }

  if (!INT64_PATTERN.test(normalized)) {
    throw new Error(`field \`${field.name}\` must be an integer at row ${rowIndex}`);
  }

  return { value: normalized, isNull: false };
};

export const toBridgeInput = (
  schemaText: string,
  rowsText: string,
  sql: string,
): BridgeInput => {
  if (sql.trim() === '') {
    throw new Error('SQL must not be empty');
  }

  const schema = parseSchema(schemaText);
  const rows = expectArray<unknown>(parseJson(rowsText, 'Rows'), 'Rows');
  const schemaKeys = new Set(schema.map((field) => field.name));

  const rowValues = rows.map((value, rowIndex) => {
    if (!isObjectRecord(value)) {
      throw new Error(`rows[${rowIndex}] must be an object`);
    }

    const extraKey = Object.keys(value).find((key) => !schemaKeys.has(key));
    if (extraKey) {
      throw new Error(`rows[${rowIndex}] contains unknown field \`${extraKey}\``);
    }

    return schema.map((field) => normalizeCell(value, field, rowIndex).value);
  });

  const rowNulls = rows.map((value, rowIndex) => {
    const record = value as RowRecord;
    return schema.map((field) => normalizeCell(record, field, rowIndex).isNull);
  });

  return {
    schemaNames: schema.map((field) => field.name),
    schemaTypes: schema.map((field) => field.type),
    schemaRepetitions: schema.map((field) => field.repetition),
    rowValues,
    rowNulls,
    sql,
  };
};
