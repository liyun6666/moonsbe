///|
fn json_text(value : Json, path : String) -> String raise SbeError {
  match value {
    String(text) => text
    _ => raise InvalidValue(path, "expected a JSON string")
  }
}

///|
fn json_scalar(
  primitive : Primitive,
  value : Json,
  path : String,
) -> Value raise SbeError {
  if primitive == Char {
    return Text(json_text(value, path))
  }
  let literal = match value {
    String(text) => text
    Number(number, repr~) =>
      match repr {
        Some(text) => text
        None => {
          if !primitive.is_float() &&
            (number > 9007199254740991.0 || number < -9007199254740991.0) {
            raise InvalidValue(
              path, "large integer requires an exact JSON literal or a string",
            )
          }
          number.to_string()
        }
      }
    _ => raise InvalidValue(path, "expected an exact number or numeric string")
  }
  scalar_from_literal(primitive, literal)
}

///|
fn type_from_json(
  schema : Schema,
  type_name : String,
  json : Json,
  depth : Int32,
) -> Value raise SbeError {
  if depth > 64 {
    raise LimitExceeded("JSON value nesting exceeds 64")
  }
  if json is Null {
    return Absent
  }
  match schema.type_def(type_name) {
    Encoded(encoding) => {
      if encoding.primitive == Char {
        return Text(json_text(json, type_name))
      }
      if encoding.length == 1 {
        return json_scalar(encoding.primitive, json, type_name)
      }
      match json {
        Array(items) =>
          Sequence(
            items.map(item => json_scalar(encoding.primitive, item, type_name)),
          )
        _ => raise InvalidValue(type_name, "expected an array")
      }
    }
    Enumeration(_, _, _) => Text(json_text(json, type_name))
    BitSet(_, _) =>
      match json {
        Array(items) =>
          Sequence(items.map(item => Text(json_text(item, type_name))))
        _ => raise InvalidValue(type_name, "bit set must be an array of names")
      }
    Composite(entries, _) => {
      let object = match json {
        Object(fields) => fields
        _ => raise InvalidValue(type_name, "expected a composite JSON object")
      }
      let fields : Map[String, Value] = Map([])
      for name, value in object {
        let mut found : CompositeMember? = None
        for entry in entries {
          if entry.name == name {
            found = Some(entry)
          }
        }
        match found {
          None =>
            raise InvalidValue(type_name, "unknown composite member: \{name}")
          Some(entry) =>
            fields[name] = type_from_json(
              schema,
              entry.type_name,
              value,
              depth + 1,
            )
        }
      }
      Record(fields)
    }
  }
}

///|
fn block_from_json(
  schema : Schema,
  block : BlockDef,
  json : Json,
  depth : Int32,
) -> Value raise SbeError {
  if depth > 32 {
    raise LimitExceeded("JSON group nesting exceeds 32")
  }
  let source = match json {
    Object(fields) => fields
    _ => raise InvalidValue("message", "expected a JSON object")
  }
  for name, _ in source {
    if !block_has_name(block, name) {
      raise InvalidValue(name, "unknown JSON field")
    }
  }
  let fields : Map[String, Value] = Map([])
  for field in block.fields {
    match source.get(field.name) {
      Some(value) =>
        fields[field.name] = type_from_json(schema, field.type_name, value, 0)
      None => ()
    }
  }
  for group in block.groups {
    match source.get(group.name) {
      None => ()
      Some(Null) => fields[group.name] = Absent
      Some(Array(items)) =>
        fields[group.name] = Sequence(
          items.map(item => {
            block_from_json(schema, group.block, item, depth + 1)
          }),
        )
      _ => raise InvalidValue(group.name, "group must be a JSON array")
    }
  }
  for data in block.data {
    match source.get(data.name) {
      None => ()
      Some(Null) => fields[data.name] = Absent
      Some(value) => {
        let text = json_text(value, data.name)
        fields[data.name] = if data.character_encoding == "" {
          Binary(from_hex(text))
        } else {
          Text(text)
        }
      }
    }
  }
  Record(fields)
}

///|
/// Parse a message JSON document without losing integer precision. Duplicate
/// keys are rejected before any schema-driven conversion occurs.
pub fn value_from_json(
  schema : Schema,
  template_id : Int32,
  source : String,
) -> Value raise SbeError {
  if source.length() > 16000000 {
    raise LimitExceeded("JSON input exceeds 16 million code units")
  }
  let value = @json.parse(
    source,
    max_nesting_depth=128,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => raise InvalidValue("json", "malformed JSON or duplicate object key")
  }
  block_from_json(schema, schema.message(template_id).block, value, 0)
}

///|
/// Return directly requested include names, allowing a host to supply bytes.
pub fn schema_include_names(source : String) -> Array[String] raise SbeError {
  let root = parse_xml(source)
  let result : Array[String] = []
  fn visit(node : XmlNode) -> Unit raise SbeError {
    for child in node.children {
      if child.local_name() == "include" {
        result.push(child.required("href"))
      } else if child.local_name() == "types" {
        visit(child)
      }
    }
  }
  visit(root)
  result
}
