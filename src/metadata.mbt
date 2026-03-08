///|
fn read_schema_element(
  reader : CompactReader,
) -> SchemaElementMeta raise ParquetError {
  reader.begin_struct()
  let mut type_code : Int? = None
  let mut type_length : Int? = None
  let mut repetition_type : Int? = None
  let mut name = ""
  let mut num_children : Int? = None
  let mut converted_type : Int? = None
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => type_code = Some(reader.read_i32())
          2 => type_length = Some(reader.read_i32())
          3 => repetition_type = Some(reader.read_i32())
          4 => name = reader.read_string()
          5 => num_children = Some(reader.read_i32())
          6 => converted_type = Some(reader.read_i32())
          _ => reader.skip(wire_type)
        }
    }
  }
  {
    type_code,
    type_length,
    repetition_type,
    name,
    num_children,
    converted_type,
  }
}

///|
fn read_column_metadata(
  reader : CompactReader,
) -> ColumnMetaDataMeta raise ParquetError {
  reader.begin_struct()
  let mut type_code = -1
  let mut encodings : Array[Int] = []
  let mut path_in_schema : Array[String] = []
  let mut codec = -1
  let mut num_values = 0L
  let mut total_uncompressed_size = 0L
  let mut total_compressed_size = 0L
  let mut data_page_offset = 0L
  let mut dictionary_page_offset : Int64? = None
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => type_code = reader.read_i32()
          2 => {
            let (item_type, size) = reader.read_list_begin()
            if item_type != thrift_wire_i32 {
              invalid_data("Invalid encoding list element type")
            }
            let values : Array[Int] = []
            for _ in 0..<size {
              values.push(reader.read_i32())
            }
            encodings = values
          }
          3 => {
            let (item_type, size) = reader.read_list_begin()
            if item_type != thrift_wire_binary {
              invalid_data("Invalid path list element type")
            }
            let values : Array[String] = []
            for _ in 0..<size {
              values.push(reader.read_string())
            }
            path_in_schema = values
          }
          4 => codec = reader.read_i32()
          5 => num_values = reader.read_i64()
          6 => total_uncompressed_size = reader.read_i64()
          7 => total_compressed_size = reader.read_i64()
          9 => data_page_offset = reader.read_i64()
          11 => dictionary_page_offset = Some(reader.read_i64())
          _ => reader.skip(wire_type)
        }
    }
  }
  if type_code < 0 || codec < 0 {
    invalid_data("Missing required ColumnMetaData fields")
  }
  {
    type_code,
    encodings,
    path_in_schema,
    codec,
    num_values,
    total_uncompressed_size,
    total_compressed_size,
    data_page_offset,
    dictionary_page_offset,
  }
}

///|
fn read_column_chunk(
  reader : CompactReader,
) -> ColumnChunkMeta raise ParquetError {
  reader.begin_struct()
  let mut file_offset = 0L
  let mut meta_data : ColumnMetaDataMeta? = None
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          2 => file_offset = reader.read_i64()
          3 => meta_data = Some(read_column_metadata(reader))
          _ => reader.skip(wire_type)
        }
    }
  }
  match meta_data {
    Some(meta_data) => { file_offset, meta_data }
    None => raise ParquetError::InvalidData("ColumnChunk without meta_data")
  }
}

///|
fn read_row_group(reader : CompactReader) -> RowGroupMeta raise ParquetError {
  reader.begin_struct()
  let mut columns : Array[ColumnChunkMeta] = []
  let mut total_byte_size = 0L
  let mut num_rows = 0L
  let mut file_offset : Int64? = None
  let mut total_compressed_size : Int64? = None
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => {
            let (item_type, size) = reader.read_list_begin()
            if item_type != thrift_wire_struct {
              invalid_data("Invalid RowGroup.columns element type")
            }
            let values : Array[ColumnChunkMeta] = []
            for _ in 0..<size {
              values.push(read_column_chunk(reader))
            }
            columns = values
          }
          2 => total_byte_size = reader.read_i64()
          3 => num_rows = reader.read_i64()
          5 => file_offset = Some(reader.read_i64())
          6 => total_compressed_size = Some(reader.read_i64())
          _ => reader.skip(wire_type)
        }
    }
  }
  { columns, total_byte_size, num_rows, file_offset, total_compressed_size }
}

///|
fn read_file_metadata(
  data : Bytes,
  start : Int,
  footer_len : Int,
) -> FileMetaDataMeta raise ParquetError {
  let reader = CompactReader::new(data, start)
  let end_offset = start + footer_len
  reader.begin_struct()
  let mut version = -1
  let mut schema : Array[SchemaElementMeta] = []
  let mut row_groups : Array[RowGroupMeta] = []
  let mut created_by : String? = None
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => version = reader.read_i32()
          2 => {
            let (item_type, size) = reader.read_list_begin()
            if item_type != thrift_wire_struct {
              invalid_data("Invalid FileMetaData.schema element type")
            }
            let values : Array[SchemaElementMeta] = []
            for _ in 0..<size {
              values.push(read_schema_element(reader))
            }
            schema = values
          }
          3 => ignore(reader.read_i64())
          4 => {
            let (item_type, size) = reader.read_list_begin()
            if item_type != thrift_wire_struct {
              invalid_data("Invalid FileMetaData.row_groups element type")
            }
            let values : Array[RowGroupMeta] = []
            for _ in 0..<size {
              values.push(read_row_group(reader))
            }
            row_groups = values
          }
          6 => created_by = Some(reader.read_string())
          _ => reader.skip(wire_type)
        }
    }
  }
  if reader.offset != end_offset {
    invalid_data("Footer length mismatch")
  }
  if version < 0 {
    invalid_data("Missing FileMetaData.version")
  }
  { schema, row_groups, created_by }
}

///|
fn read_data_page_header(
  reader : CompactReader,
) -> DataPageHeaderMeta raise ParquetError {
  reader.begin_struct()
  let mut num_values = -1
  let mut encoding = -1
  let mut definition_level_encoding = -1
  let mut repetition_level_encoding = -1
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => num_values = reader.read_i32()
          2 => encoding = reader.read_i32()
          3 => definition_level_encoding = reader.read_i32()
          4 => repetition_level_encoding = reader.read_i32()
          _ => reader.skip(wire_type)
        }
    }
  }
  if num_values < 0 ||
    encoding < 0 ||
    definition_level_encoding < 0 ||
    repetition_level_encoding < 0 {
    invalid_data("Missing DataPageHeader fields")
  }
  { num_values, encoding }
}

///|
fn read_data_page_header_v2(
  reader : CompactReader,
) -> DataPageHeaderV2Meta raise ParquetError {
  reader.begin_struct()
  let mut num_values = -1
  let mut num_rows = -1
  let mut encoding = -1
  let mut definition_levels_byte_length = 0
  let mut repetition_levels_byte_length = 0
  let mut is_compressed = true
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => num_values = reader.read_i32()
          2 => {
            let _num_nulls = reader.read_i32()
            ()
          }
          3 => num_rows = reader.read_i32()
          4 => encoding = reader.read_i32()
          5 => definition_levels_byte_length = reader.read_i32()
          6 => repetition_levels_byte_length = reader.read_i32()
          7 => is_compressed = reader.read_bool()
          _ => reader.skip(wire_type)
        }
    }
  }
  if num_values < 0 || num_rows < 0 || encoding < 0 {
    invalid_data("Missing DataPageHeaderV2 fields")
  }
  {
    num_values,
    encoding,
    definition_levels_byte_length,
    repetition_levels_byte_length,
    is_compressed,
  }
}

///|
fn read_dictionary_page_header(
  reader : CompactReader,
) -> DictionaryPageHeaderMeta raise ParquetError {
  reader.begin_struct()
  let mut num_values = -1
  let mut encoding = -1
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => num_values = reader.read_i32()
          2 => encoding = reader.read_i32()
          _ => reader.skip(wire_type)
        }
    }
  }
  if num_values < 0 || encoding < 0 {
    invalid_data("Missing DictionaryPageHeader fields")
  }
  { num_values, encoding }
}

///|
fn read_page_header(
  data : Bytes,
  start : Int,
) -> (PageHeaderMeta, Int) raise ParquetError {
  let reader = CompactReader::new(data, start)
  reader.begin_struct()
  let mut page_type = -1
  let mut uncompressed_page_size = -1
  let mut compressed_page_size = -1
  let mut data_page : DataPageHeaderMeta? = None
  let mut data_page_v2 : DataPageHeaderV2Meta? = None
  let mut dictionary_page : DictionaryPageHeaderMeta? = None
  let mut done = false
  while not(done) {
    match reader.read_field_begin() {
      None => {
        reader.end_struct()
        done = true
      }
      Some((field_id, wire_type)) =>
        match field_id {
          1 => page_type = reader.read_i32()
          2 => uncompressed_page_size = reader.read_i32()
          3 => compressed_page_size = reader.read_i32()
          5 => data_page = Some(read_data_page_header(reader))
          7 => dictionary_page = Some(read_dictionary_page_header(reader))
          8 => data_page_v2 = Some(read_data_page_header_v2(reader))
          _ => reader.skip(wire_type)
        }
    }
  }
  if page_type < 0 || uncompressed_page_size < 0 || compressed_page_size < 0 {
    invalid_data("Missing PageHeader fields")
  }
  (
    {
      page_type,
      uncompressed_page_size,
      compressed_page_size,
      data_page,
      data_page_v2,
      dictionary_page,
    },
    reader.offset - start,
  )
}

///|
fn to_repetition(value : Int?) -> Repetition {
  match value {
    Some(1) => Optional
    Some(2) => Repeated
    _ => Required
  }
}

///|
fn to_column_type(
  type_code : Int,
  converted_type : Int?,
) -> ColumnType raise ParquetError {
  if type_code == parquet_type_boolean {
    Boolean
  } else if type_code == parquet_type_int32 {
    Int32
  } else if type_code == parquet_type_int64 {
    Int64
  } else if type_code == parquet_type_int96 {
    TimestampMicros
  } else if type_code == parquet_type_float {
    Float
  } else if type_code == parquet_type_double {
    Double
  } else if type_code == parquet_type_byte_array {
    match converted_type {
      Some(0) => String
      _ => Binary
    }
  } else if type_code == parquet_type_fixed_len_byte_array {
    Binary
  } else {
    raise ParquetError::Unsupported(
      "Unsupported parquet physical type: \{type_code}",
    )
  }
}

///|
fn build_leaf_columns(
  schema : Array[SchemaElementMeta],
) -> Array[LeafColumnMeta] raise ParquetError {
  fn walk(
    schema : Array[SchemaElementMeta],
    index : Int,
    path : Array[String],
    max_definition_level : Int,
    max_repetition_level : Int,
    is_root : Bool,
  ) -> (Int, Array[LeafColumnMeta]) raise ParquetError {
    let element = schema[index]
    let repetition = to_repetition(element.repetition_type)
    let next_definition = if is_root {
      max_definition_level
    } else if repetition == Optional {
      max_definition_level + 1
    } else {
      max_definition_level
    }
    let next_repetition = if repetition == Repeated {
      max_repetition_level + 1
    } else {
      max_repetition_level
    }
    let next_path = if is_root { path } else { path + [element.name] }
    match element.num_children {
      Some(children) => {
        let mut cursor = index + 1
        let leaves : Array[LeafColumnMeta] = []
        for _ in 0..<children {
          let (next_index, child_leaves) = walk(
            schema, cursor, next_path, next_definition, next_repetition, false,
          )
          cursor = next_index
          leaves.append(child_leaves)
        }
        (cursor, leaves)
      }
      None =>
        match element.type_code {
          Some(type_code) =>
            (
              index + 1,
              [
                {
                  name: normalize_schema_name(element.name),
                  column_type: to_column_type(type_code, element.converted_type),
                  repetition,
                  max_definition_level: next_definition,
                  max_repetition_level: next_repetition,
                  fixed_length: match element.type_length {
                    Some(value) => Some(value)
                    None =>
                      if type_code == parquet_type_int96 {
                        Some(12)
                      } else {
                        None
                      }
                  },
                },
              ],
            )
          None =>
            raise ParquetError::InvalidData("Leaf schema element without type")
        }
    }
  }
  let (_, leaves) = walk(schema, 0, [], 0, 0, true)
  leaves
}
