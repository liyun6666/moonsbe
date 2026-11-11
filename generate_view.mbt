///|
fn Generator::fixed_view(
  self : Generator,
  name : String,
  message : MessageDef,
) -> Unit raise SbeError {
  let numeric : Array[(FieldDef, TypeEncoding)] = []
  for field in message.block.fields {
    if field.presence == Constant {
      continue
    }
    match self.schema.type_def(field.type_name) {
      Encoded(encoding) if encoding.primitive != Char =>
        numeric.push((field, encoding))
      _ => ()
    }
  }
  if numeric.is_empty() {
    return
  }
  let view = name + "View"
  ignore(self.claim(view, "view:\{message.id}"))
  let order = match self.schema.byte_order {
    LittleEndian => "@sbe.LittleEndian"
    BigEndian => "@sbe.BigEndian"
  }
  let out = self.output
  out.write_string(
    "///|\n/// Direct reads of fixed numeric fields from the original bytes.\npub struct \{view} {\n  block : @sbe.FixedBlock\n  acting_version : Int\n}\n\n",
  )
  out.write_string(
    "///|\npub fn \{view}::version(self : \{view}) -> Int { self.acting_version }\n\n",
  )
  let layout = self.schema.header_layout
  out.write_string(
    "///|\n/// Checks message identity and fixed block bounds. Use decode for full validation.\npub fn \{name}::view(bytes : Bytes) -> \{view} raise @sbe.SbeError {\n  if bytes.length() > 16777216 { raise @sbe.value_error(\"message\", \"message exceeds 16 MiB\") }\n  let header = @sbe.FixedBlock::new(bytes, 0, \{layout.size}, \{order})\n",
  )
  for key in ["blockLength", "templateId", "schemaId", "version"] {
    let entry = layout.entry(key)
    let variable = field_identifier(key)
    out.write_string(
      "  let \{variable} = header.uint_at(\{entry.offset}, \{entry.primitive.width()})\n",
    )
    let lower = if entry.min_value > 0 {
      "\{variable} < \{entry.min_value}UL || "
    } else {
      ""
    }
    out.write_string(
      "  if \{lower}\{variable} > \{entry.max_value}UL { raise @sbe.value_error(\{code_quote(key)}, \"out-of-range framing member\") }\n",
    )
  }
  out.write_string(
    "  if f_template_id != \{message.id}UL || f_schema_id != \{self.schema.id}UL || f_version.to_int() < \{message.since_version} {\n    raise @sbe.value_error(\"header\", \"unexpected template, schema or acting version\")\n  }\n  { block: @sbe.FixedBlock::new(bytes, \{layout.size}, f_block_length.to_int(), \{order}), acting_version: f_version.to_int() }\n}\n\n",
  )
  for item in numeric {
    self.numeric_accessor(view, item.0, item.1)
  }
}

///|
fn numeric_is_null(encoding : TypeEncoding) -> String raise SbeError {
  match encoding_null(encoding) {
    Unsigned(value) => "value == \{value}UL"
    Signed(value) => "value == \{value}L"
    Floating(value) =>
      if value.is_nan() {
        "value.is_nan()"
      } else if value.is_inf() {
        if value < 0.0 {
          "value.is_inf() && value < 0.0"
        } else {
          "value.is_inf() && value > 0.0"
        }
      } else {
        "value == \{value}"
      }
    _ => raise InvalidSchema("numeric accessor expected a numeric null", 0)
  }
}

///|
fn Generator::numeric_accessor(
  self : Generator,
  view : String,
  field : FieldDef,
  encoding : TypeEncoding,
) -> Unit raise SbeError {
  let name = field_identifier(field.name)
  let primitive = encoding.primitive
  let width = primitive.width()
  let (type_name, reader) = if primitive.is_signed() {
    ("Int64", "int_at")
  } else if primitive.is_float() {
    ("Double", "float_at")
  } else {
    ("UInt64", "uint_at")
  }
  let optional = field.presence == Optional || field.since_version > 0
  let result = if optional { type_name + "?" } else { type_name }
  let array = encoding.length != 1
  let argument = if array { ", index : Int" } else { "" }
  let out = self.output
  out.write_string(
    "///|\npub fn \{view}::\{name}(self : \{view}\{argument}) -> \{result} raise @sbe.SbeError {\n",
  )
  if array {
    out.write_string(
      "  if index < 0 || index >= \{encoding.length} { raise @sbe.value_error(\{code_quote(field.name)}, \"array index out of range\") }\n",
    )
  }
  if field.since_version > 0 {
    out.write_string(
      "  if self.acting_version < \{field.since_version} { return None }\n",
    )
  }
  let offset = if array {
    "\{field.offset} + index * \{width}"
  } else {
    "\{field.offset}"
  }
  out.write_string("  let value = self.block.\{reader}(\{offset}, \{width})\n")
  if field.presence == Optional {
    out.write_string("  if \{numeric_is_null(encoding)} { return None }\n")
  }
  out.write_string(
    if optional {
      "  Some(value)\n}\n\n"
    } else {
      "  value\n}\n\n"
    },
  )
}
