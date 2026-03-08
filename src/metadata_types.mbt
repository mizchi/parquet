///|
priv struct SchemaElementMeta {
  type_code : Int?
  type_length : Int?
  repetition_type : Int?
  name : String
  num_children : Int?
  converted_type : Int?
}

///|
priv struct ColumnMetaDataMeta {
  type_code : Int
  encodings : Array[Int]
  path_in_schema : Array[String]
  codec : Int
  num_values : Int64
  total_uncompressed_size : Int64
  total_compressed_size : Int64
  data_page_offset : Int64
  dictionary_page_offset : Int64?
}

///|
priv struct ColumnChunkMeta {
  file_offset : Int64
  meta_data : ColumnMetaDataMeta
}

///|
priv struct RowGroupMeta {
  columns : Array[ColumnChunkMeta]
  total_byte_size : Int64
  num_rows : Int64
  file_offset : Int64?
  total_compressed_size : Int64?
}

///|
priv struct FileMetaDataMeta {
  schema : Array[SchemaElementMeta]
  row_groups : Array[RowGroupMeta]
  created_by : String?
}

///|
priv struct DataPageHeaderMeta {
  num_values : Int
  encoding : Int
}

///|
priv struct DataPageHeaderV2Meta {
  num_values : Int
  encoding : Int
  definition_levels_byte_length : Int
  repetition_levels_byte_length : Int
  is_compressed : Bool
}

///|
priv struct PageHeaderMeta {
  page_type : Int
  uncompressed_page_size : Int
  compressed_page_size : Int
  data_page : DataPageHeaderMeta?
  data_page_v2 : DataPageHeaderV2Meta?
  dictionary_page : DictionaryPageHeaderMeta?
}

///|
priv struct DictionaryPageHeaderMeta {
  num_values : Int
  encoding : Int
}

///|
priv struct LeafColumnMeta {
  name : String
  column_type : ColumnType
  repetition : Repetition
  max_definition_level : Int
  max_repetition_level : Int
  fixed_length : Int?
}
