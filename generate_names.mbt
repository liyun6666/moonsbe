///|
/// Public factory used by generated adapters when rejecting a typed value.
pub fn value_error(path : String, reason : String) -> SbeError {
  InvalidValue(path, reason)
}

///|
fn code_quote(text : String) -> String {
  let result = StringBuilder()
  result.write_char('"')
  for char in text {
    match char {
      '"' => result.write_string("\\\"")
      '\\' => result.write_string("\\\\")
      '\n' => result.write_string("\\n")
      '\r' => result.write_string("\\r")
      '\t' => result.write_string("\\t")
      _ => {
        if char.to_int() < 32 {
          result.write_string("\\u{\{char.to_int().to_string(radix=16)}}")
        } else { result.write_char(char) }
      }
    }
  }
  result.write_char('"')
  result.to_string()
}

///|
fn type_identifier(name : String) -> String raise SbeError {
  let out = StringBuilder()
  let mut upper = true
  for char in name {
    if char.is_ascii_alphabetic() || char.is_ascii_digit() {
      out.write_char(if upper { char.to_ascii_uppercase() } else { char })
      upper = false
    } else { upper = true }
  }
  let result = out.to_string()
  if result.is_empty() || result.iter().to_array()[0].is_ascii_digit() {
    raise Unsupported("schema name cannot be converted to a MoonBit type: \{name}")
  }
  result
}

///|
fn field_identifier(name : String) -> String raise SbeError {
  let out = StringBuilder()
  let mut previous_lower = false
  for char in name {
    if char.is_ascii_uppercase() {
      if previous_lower { out.write_char('_') }
      out.write_char(char.to_ascii_lowercase())
      previous_lower = false
    } else if char.is_ascii_lowercase() || char.is_ascii_digit() {
      out.write_char(char)
      previous_lower = true
    } else {
      out.write_char('_')
      previous_lower = false
    }
  }
  let result = out.to_string()
  if result.is_empty() || result.iter().to_array()[0].is_ascii_digit() {
    raise Unsupported("schema name cannot be converted to a field: \{name}")
  }
  // Every generated field has a prefix, avoiding language keywords and method
  // collisions without silently changing wire names.
  "f_\{result}"
}

///|
priv struct GenField {
  wire_name : String
  name : String
  type_name : String
  to_value : (String) -> String
  from_value : (String) -> String
}

///|
priv struct Generator {
  schema : Schema
  output : StringBuilder
  emitted : Map[String, String]
}

///|
fn Generator::claim(self : Generator, generated : String, original : String) -> Bool raise SbeError {
  match generated {
    "String" | "Bytes" | "Json" | "Unit" | "Bool" | "Int" | "Int32" | "Int64" |
    "UInt" | "UInt32" | "UInt64" | "Float" | "Double" | "Array" | "Map" | "Option" | "Result" =>
      raise Unsupported("generated type conflicts with MoonBit built-in: \{generated}")
    _ => ()
  }
  match self.emitted.get(generated) {
    Some(previous) if previous != original => raise InvalidSchema("generated name collision: \{generated}", 0)
    Some(_) => false
    None => {
      self.emitted[generated] = original
      true
    }
  }
}

///|
fn optional_adapter(field : GenField) -> GenField {
  {
    ..field,
    type_name: "\{field.type_name}?",
    to_value: (source) => "match \{source} { Some(item) => \{(field.to_value)("item")}; None => @sbe.Absent }",
    from_value: (source) => "match \{source} { @sbe.Absent => None; item => Some(\{(field.from_value)("item")}) }",
  }
}

///|
fn array_adapter(field : GenField) -> GenField {
  {
    ..field,
    type_name: "Array[\{field.type_name}]",
    to_value: (source) => "@sbe.Sequence(\{source}.map((item) => \{(field.to_value)("item")}))",
    from_value: (source) => "\{source}.as_sequence().map((item) => \{(field.from_value)("item")})",
  }
}

///|
fn scalar_adapter(primitive : Primitive, wire_name : String) -> GenField raise SbeError {
  let (type_name, value_case, getter) = if primitive == Char {
    ("String", "Text", "as_text")
  } else if primitive.is_float() {
    ("Double", "Floating", "as_float")
  } else if primitive.is_signed() {
    ("Int64", "Signed", "as_signed")
  } else { ("UInt64", "Unsigned", "as_unsigned") }
  {
    wire_name, name: field_identifier(wire_name), type_name,
    to_value: (source) => "@sbe.\{value_case}(\{source})",
    from_value: (source) => "\{source}.\{getter}()",
  }
}
