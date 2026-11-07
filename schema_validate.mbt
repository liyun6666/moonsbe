///|
fn validate_encoding(
  encoding : TypeEncoding,
  name : String,
) -> Unit raise SbeError {
  if encoding.presence == Optional && encoding.length != 1 {
    raise Unsupported("optional primitive arrays: \{name}")
  }
  if encoding.presence == Constant {
    let text = encoding.constant.unwrap_or("")
    if encoding.primitive == Char {
      let bytes = encode_text(text, encoding.character_encoding, name)
      if bytes.length() != encoding.length {
        raise InvalidSchema(
          "constant char length differs from its value: \{name}",
          0,
        )
      }
    } else {
      if encoding.length != 1 {
        raise Unsupported("constant numeric arrays")
      }
      let scalar = scalar_from_literal(encoding.primitive, text)
      check_scalar(encoding, scalar, name)
    }
  }
  if encoding.primitive == Char {
    return
  }
  for value in [encoding.min_value, encoding.max_value, encoding.null_value] {
    match value {
      None => ()
      Some(text) => {
        let scalar = scalar_from_literal(encoding.primitive, text)
        // Validate the physical integer width independently of the min/max
        // constraints themselves. A fresh writer avoids incidental limits.
        write_scalar(Writer::new(limit=8), encoding.primitive, scalar)
      }
    }
  }
  match (encoding.min_value, encoding.max_value) {
    (Some(min), Some(max)) => {
      let a = scalar_from_literal(encoding.primitive, min)
      let b = scalar_from_literal(encoding.primitive, max)
      let ordered = if encoding.primitive.is_signed() {
        a.as_signed() <= b.as_signed()
      } else if encoding.primitive.is_float() {
        !a.as_float().is_nan() &&
        !b.as_float().is_nan() &&
        a.as_float() <= b.as_float()
      } else {
        a.as_unsigned() <= b.as_unsigned()
      }
      if !ordered {
        raise InvalidSchema("minValue exceeds maxValue: \{name}", 0)
      }
    }
    _ => ()
  }
}

///|
fn validate_block(
  schema : Schema,
  block : BlockDef,
  depth : Int32,
) -> Unit raise SbeError {
  if depth > 32 {
    raise LimitExceeded("group nesting exceeds 32")
  }
  let mut previous_since = 0
  for field in block.fields {
    if field.since_version > schema.version ||
      field.since_version < previous_since {
      raise InvalidSchema(
        "fixed field sinceVersion must be nondecreasing and within schema version",
        0,
      )
    }
    previous_since = field.since_version
    let definition = schema.type_def(field.type_name)
    match definition {
      Encoded(encoding) if encoding.length == 0 =>
        raise InvalidSchema("zero-length varData type used as a fixed field", 0)
      Composite(_, _) | BitSet(_, _) if field.presence != Required =>
        raise Unsupported("optional or constant composite/set fields")
      Encoded(encoding) if field.presence == Optional && encoding.length != 1 =>
        raise Unsupported("optional primitive arrays")
      _ => ()
    }
    if field.presence == Constant {
      ignore(constant_value(schema, field))
    }
    if field.value_ref != None && field.presence != Constant {
      raise InvalidSchema("valueRef is valid only for a constant field", 0)
    }
  }
  for group in block.groups {
    if group.since_version > schema.version || group.max_count < 0 {
      raise InvalidSchema("group version or count bound is invalid", 0)
    }
    validate_block(schema, group.block, depth + 1)
  }
  for data in block.data {
    if data.since_version > schema.version || data.max_length < 0 {
      raise InvalidSchema("variable data version or length bound is invalid", 0)
    }
  }
}

///|
fn validate_compiled_schema(schema : Schema) -> Unit raise SbeError {
  for name, definition in schema.types {
    match definition {
      Encoded(encoding) => validate_encoding(encoding, name)
      Enumeration(primitive, cases, _) => {
        let values : Array[Value] = []
        for entry in cases {
          if entry.since_version > schema.version {
            raise InvalidSchema("enum case is newer than schema", 0)
          }
          let scalar = scalar_from_literal(primitive, entry.value)
          check_scalar(default_encoding(primitive), scalar, name)
          for previous in values {
            if same_scalar(scalar, previous) {
              raise InvalidSchema("duplicate numeric enum value", 0)
            }
          }
          values.push(scalar)
        }
      }
      BitSet(_, cases) =>
        for entry in cases {
          if entry.since_version > schema.version {
            raise InvalidSchema("set choice is newer than schema", 0)
          }
        }
      Composite(entries, _) =>
        if entries.is_empty() {
          raise InvalidSchema("composite must contain a type or reference", 0)
        }
    }
  }
  for message in schema.messages {
    if message.since_version > schema.version {
      raise InvalidSchema("message is newer than schema", 0)
    }
    validate_block(schema, message.block, 0)
  }
}
