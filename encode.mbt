///|
fn encode_type(
  schema : Schema,
  type_name : String,
  value : Value,
  writer : Writer,
  presence : Presence,
  version : Int32,
  path : String,
  depth : Int32,
) -> Unit raise SbeError {
  if depth > 64 {
    raise LimitExceeded("value nesting exceeds 64")
  }
  match schema.type_def(type_name) {
    Encoded(encoding) => {
      if presence == Constant || encoding.presence == Constant {
        return
      }
      if value is Absent {
        if presence != Optional || encoding.length != 1 {
          raise InvalidValue(path, "required field cannot be absent")
        }
        write_scalar(writer, encoding.primitive, encoding_null(encoding))
      } else if encoding.primitive == Char {
        let text = value.as_text()
        let bytes = encode_text(text, encoding.character_encoding, path)
        if bytes.length() > encoding.length {
          raise InvalidValue(path, "text exceeds fixed array length")
        }
        for byte in bytes {
          if byte == 0 {
            raise InvalidValue(path, "fixed text cannot contain embedded NUL")
          }
        }
        if encoding.length == 1 {
          check_scalar(encoding, value, path)
        }
        writer.write_bytes(bytes)
        writer.pad_to(writer.position() + encoding.length - bytes.length())
      } else if encoding.length == 1 {
        check_scalar(encoding, value, path)
        write_scalar(writer, encoding.primitive, value)
      } else {
        let values = value.as_sequence()
        if values.length() != encoding.length {
          raise InvalidValue(
            path, "fixed array has the wrong number of elements",
          )
        }
        for index, entry in values {
          check_scalar(encoding, entry, "\{path}[\{index}]")
          write_scalar(writer, encoding.primitive, entry)
        }
      }
    }
    Enumeration(primitive, cases, _) => {
      if value is Absent {
        if presence != Optional {
          raise InvalidValue(path, "required enum cannot be absent")
        }
        write_scalar(writer, primitive, default_null(primitive))
        return
      }
      let name = value.as_text()
      for entry in cases {
        if entry.name == name && entry.since_version <= version {
          write_scalar(
            writer,
            primitive,
            scalar_from_literal(primitive, entry.value),
          )
          return
        }
      }
      raise InvalidValue(path, "unknown or future enum value: \{name}")
    }
    BitSet(primitive, cases) => {
      let names = value.as_sequence()
      let seen : Map[String, Bool] = Map([])
      let mut bits = 0UL
      for item in names {
        let name = item.as_text()
        if seen.contains(name) {
          raise InvalidValue(path, "duplicate set choice")
        }
        seen[name] = true
        let mut found = false
        for entry in cases {
          if entry.name == name && entry.since_version <= version {
            let bit = @string.parse_int(entry.value) catch {
              _ => raise InvalidSchema("invalid bit index", 0)
            }
            bits = bits | (1UL << bit)
            found = true
          }
        }
        if !found {
          raise InvalidValue(path, "unknown or future set choice: \{name}")
        }
      }
      writer.write_uint(bits, primitive.width())
    }
    Composite(members, _) => {
      let start = writer.position()
      let length = schema.encoded_size_at(type_name, version)
      if presence == Optional {
        let (first, marker) = schema.composite_null_marker(members)
        let null = encoding_null(marker)
        if value is Absent {
          writer.pad_to(start + first.offset)
          write_scalar(writer, marker.primitive, null)
          writer.pad_to(start + length)
          return
        }
        let item = value.field(first.name)
        if item is Absent || same_scalar(item, null) {
          raise InvalidValue(
            path, "present composite requires a non-null first element",
          )
        }
      }
      let fields = value.as_record()
      for entry in members {
        if entry.since_version > version {
          if !(fields.get(entry.name).unwrap_or(Absent) is Absent) {
            raise InvalidValue(
              path,
              "future composite member supplied: \{entry.name}",
            )
          }
          continue
        }
        writer.pad_to(start + entry.offset)
        let nested_type = schema.type_def(entry.type_name)
        let item = match nested_type {
          Encoded(encoding) if encoding.presence == Constant => {
            let text = encoding.constant.unwrap_or("")
            let expected = if encoding.primitive == Char {
              Text(text)
            } else {
              scalar_from_literal(encoding.primitive, text)
            }
            match fields.get(entry.name) {
              Some(given) if !same_scalar(given, expected) =>
                raise InvalidValue(path, "constant composite value differs")
              _ => ()
            }
            continue
          }
          _ => fields.get(entry.name).unwrap_or(Absent)
        }
        encode_type(
          schema,
          entry.type_name,
          item,
          writer,
          type_presence(nested_type),
          version,
          "\{path}.\{entry.name}",
          depth + 1,
        )
      }
      for name, _ in fields {
        let mut known = false
        for entry in members {
          if entry.name == name {
            known = true
          }
        }
        if !known {
          raise InvalidValue(path, "unknown composite field: \{name}")
        }
      }
      writer.pad_to(start + length)
    }
  }
}

///|
fn block_has_name(block : BlockDef, name : String) -> Bool {
  for field in block.fields {
    if field.name == name {
      return true
    }
  }
  for group in block.groups {
    if group.name == name {
      return true
    }
  }
  for data in block.data {
    if data.name == name {
      return true
    }
  }
  false
}

///|
fn block_length_at(
  schema : Schema,
  block : BlockDef,
  version : Int32,
) -> Int32 raise SbeError {
  if version == schema.version {
    return block.block_length
  }
  let mut length = 0
  for field in block.fields {
    if field.since_version <= version && field.presence != Constant {
      let end = field.offset + schema.encoded_size_at(field.type_name, version)
      if end > length {
        length = end
      }
    }
  }
  length
}

///|
fn encode_block(
  schema : Schema,
  block : BlockDef,
  value : Value,
  writer : Writer,
  version : Int32,
  path : String,
  depth : Int32,
) -> Unit raise SbeError {
  if depth > 32 {
    raise LimitExceeded("group depth exceeds 32")
  }
  let fields = value.as_record()
  let start = writer.position()
  for name, _ in fields {
    if !block_has_name(block, name) {
      raise InvalidValue(path, "unknown message field: \{name}")
    }
  }
  for field in block.fields {
    if field.since_version > version {
      if !(fields.get(field.name).unwrap_or(Absent) is Absent) {
        raise InvalidValue(
          field.name,
          "field did not exist in the requested version",
        )
      }
      continue
    }
    if field.presence == Constant {
      let expected = constant_value(schema, field)
      match fields.get(field.name) {
        Some(given) if !same_scalar(given, expected) =>
          raise InvalidValue(field.name, "constant field differs from schema")
        _ => ()
      }
      continue
    }
    writer.pad_to(start + field.offset)
    encode_type(
      schema,
      field.type_name,
      fields.get(field.name).unwrap_or(Absent),
      writer,
      field.presence,
      version,
      "\{path}.\{field.name}",
      0,
    )
  }
  writer.pad_to(start + block_length_at(schema, block, version))
  for group in block.groups {
    if group.since_version > version {
      if !(fields.get(group.name).unwrap_or(Absent) is Absent) {
        raise InvalidValue(group.name, "future group supplied")
      }
      continue
    }
    let entries = value.field(group.name).as_sequence()
    if entries.length() > group.max_count || entries.length() > 100000 {
      raise LimitExceeded("group count exceeds allowed range: \{group.name}")
    }
    group.dimension.write(
      writer,
      Map([
        ("blockLength", block_length_at(schema, group.block, version)),
        ("numInGroup", entries.length()),
      ]),
      group.block,
      version,
    )
    for index, entry in entries {
      encode_block(
        schema,
        group.block,
        entry,
        writer,
        version,
        "\{path}.\{group.name}[\{index}]",
        depth + 1,
      )
    }
  }
  for data in block.data {
    if data.since_version > version {
      if !(fields.get(data.name).unwrap_or(Absent) is Absent) {
        raise InvalidValue(data.name, "future variable data supplied")
      }
      continue
    }
    let input = value.field(data.name)
    let bytes = if data.character_encoding == "" {
      input.as_binary()
    } else {
      encode_text(input.as_text(), data.character_encoding, data.name)
    }
    if bytes.length() > data.max_length {
      raise LimitExceeded("variable data exceeds maxValue: \{data.name}")
    }
    writer.write_uint(bytes.length().to_uint64(), data.length_primitive.width())
    writer.write_bytes(bytes)
  }
}

///|
/// Encode one complete SBE message including its schema-defined header.
pub fn encode(
  schema : Schema,
  template_id : Int32,
  value : Value,
  version~ : Int32 = schema.version,
  max_bytes~ : Int32 = 16777216,
) -> Bytes raise SbeError {
  if version < 0 || version > schema.version {
    raise InvalidValue(
      "version", "encoding version must be within compiled schema",
    )
  }
  let message = schema.message(template_id)
  if message.since_version > version {
    raise InvalidValue(
      "templateId", "message did not exist in requested version",
    )
  }
  let writer = Writer::new(order=schema.byte_order, limit=max_bytes)
  schema.header_layout.write(
    writer,
    Map([
      ("blockLength", block_length_at(schema, message.block, version)),
      ("templateId", template_id),
      ("schemaId", schema.id),
      ("version", version),
    ]),
    message.block,
    version,
  )
  encode_block(schema, message.block, value, writer, version, message.name, 0)
  writer.to_bytes()
}
