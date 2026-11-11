///|
fn Generator::enum_type(
  self : Generator,
  wire_type : String,
  cases : Array[EnumCase],
) -> String raise SbeError {
  let name = type_identifier(wire_type)
  if !self.claim(name, "enum:\{wire_type}") {
    return name
  }
  let variants : Map[String, Bool] = Map([])
  let out = self.output
  out.write_string("///|\npub(all) enum \{name} {\n")
  for entry in cases {
    let variant = type_identifier(entry.name)
    if variants.contains(variant) {
      raise InvalidSchema("generated enum case collision", 0)
    }
    variants[variant] = true
    out.write_string("  \{variant}\n")
  }
  out.write_string(
    "} derive(Debug, Eq)\n\n///|\npub fn \{name}::to_value(self : \{name}) -> @sbe.Value {\n  match self {\n",
  )
  for entry in cases {
    out.write_string(
      "    \{type_identifier(entry.name)} => @sbe.Text(\{code_quote(entry.name)})\n",
    )
  }
  out.write_string(
    "  }\n}\n\n///|\npub fn \{name}::from_value(value : @sbe.Value) -> \{name} raise @sbe.SbeError {\n  match value.as_text() {\n",
  )
  for entry in cases {
    out.write_string(
      "    \{code_quote(entry.name)} => \{type_identifier(entry.name)}\n",
    )
  }
  out.write_string(
    "    _ => raise @sbe.value_error(\{code_quote(wire_type)}, \"unknown enum name\")\n  }\n}\n\n",
  )
  name
}

///|
fn Generator::adapter(
  self : Generator,
  wire_type : String,
  wire_name : String,
  depth : Int32,
) -> GenField raise SbeError {
  if depth > 64 {
    raise LimitExceeded("code generation type depth exceeds 64")
  }
  match self.schema.type_def(wire_type) {
    Encoded(encoding) => {
      let base = scalar_adapter(encoding.primitive, wire_name)
      if encoding.primitive != Char && encoding.length != 1 {
        array_adapter(base)
      } else {
        base
      }
    }
    Enumeration(_, cases, _) => {
      let name = self.enum_type(wire_type, cases)
      {
        wire_name,
        name: field_identifier(wire_name),
        type_name: name,
        to_value: source => "\{source}.to_value()",
        from_value: source => "\{name}::from_value(\{source})",
      }
    }
    BitSet(_, _) => array_adapter(scalar_adapter(Char, wire_name))
    Composite(entries, _) => {
      let name = type_identifier(wire_type)
      if self.claim(name, "composite:\{wire_type}") {
        let fields : Array[GenField] = []
        for entry in entries {
          let nested_type = self.schema.type_def(entry.type_name)
          if type_presence(nested_type) == Constant {
            continue
          }
          let field = self.adapter(entry.type_name, entry.name, depth + 1)
          fields.push(
            if type_presence(nested_type) == Optional || entry.since_version > 0 {
              optional_adapter(field)
            } else {
              field
            },
          )
        }
        self.record(name, fields)
      }
      {
        wire_name,
        name: field_identifier(wire_name),
        type_name: name,
        to_value: source => "\{source}.to_value()",
        from_value: source => "\{name}::from_value(\{source})",
      }
    }
  }
}

///|
fn Generator::record(
  self : Generator,
  name : String,
  fields : Array[GenField],
) -> Unit raise SbeError {
  let used : Map[String, Bool] = Map([])
  let out = self.output
  if fields.is_empty() {
    // MoonBit does not permit zero-field records. A unit marker preserves an
    // empty fixed/group record without adding a wire field.
    out.write_string(
      "///|\npub(all) struct \{name} { unit : Unit } derive(Debug)\n\n",
    )
  } else {
    out.write_string("///|\npub(all) struct \{name} {\n")
    for field in fields {
      if used.contains(field.name) {
        raise InvalidSchema("generated field name collision in \{name}", 0)
      }
      used[field.name] = true
      out.write_string("  \{field.name} : \{field.type_name}\n")
    }
    out.write_string("} derive(Debug)\n\n")
  }
  out.write_string(
    "///|\npub fn \{name}::to_value(self : \{name}) -> @sbe.Value {\n",
  )
  if fields.is_empty() {
    out.write_string("  ignore(self)\n")
  }
  out.write_string("  let fields : Map[String, @sbe.Value] = Map([])\n")
  for field in fields {
    out.write_string(
      "  fields[\{code_quote(field.wire_name)}] = \{(field.to_value)("self." + field.name)}\n",
    )
  }
  out.write_string(
    "  @sbe.Record(fields)\n}\n\n///|\npub fn \{name}::from_value(value : @sbe.Value) -> \{name} raise @sbe.SbeError {\n",
  )
  if fields.is_empty() {
    out.write_string("  ignore(value.as_record())\n  { unit: () }\n")
  } else {
    out.write_string("  {\n")
    for field in fields {
      let expression = "value.field(\{code_quote(field.wire_name)})"
      out.write_string(
        "    \{field.name}: \{(field.from_value)(expression)},\n",
      )
    }
    out.write_string("  }\n")
  }
  out.write_string("}\n\n")
}

///|
fn Generator::block_record(
  self : Generator,
  name : String,
  block : BlockDef,
  depth : Int32,
  identity : String,
) -> Unit raise SbeError {
  if depth > 32 {
    raise LimitExceeded("code generation group depth exceeds 32")
  }
  if !self.claim(name, "block:\{identity}") {
    return
  }
  let fields : Array[GenField] = []
  for field in block.fields {
    if field.presence == Constant {
      continue
    }
    let adapter = self.adapter(field.type_name, field.name, 0)
    fields.push(
      if field.presence == Optional || field.since_version > 0 {
        optional_adapter(adapter)
      } else {
        adapter
      },
    )
  }
  for group in block.groups {
    let group_type = "\{name}\{type_identifier(group.name)}"
    self.block_record(
      group_type,
      group.block,
      depth + 1,
      "\{identity}/\{group.id}",
    )
    let adapter = GenField::{
      wire_name: group.name,
      name: field_identifier(group.name),
      type_name: group_type,
      to_value: source => "\{source}.to_value()",
      from_value: source => "\{group_type}::from_value(\{source})",
    }
    let array = array_adapter(adapter)
    fields.push(
      if group.since_version > 0 {
        optional_adapter(array)
      } else {
        array
      },
    )
  }
  for data in block.data {
    let adapter = if data.character_encoding == "" {
      GenField::{
        wire_name: data.name,
        name: field_identifier(data.name),
        type_name: "Bytes",
        to_value: source => "@sbe.Binary(\{source})",
        from_value: source => "\{source}.as_binary()",
      }
    } else {
      scalar_adapter(Char, data.name)
    }
    fields.push(
      if data.since_version > 0 {
        optional_adapter(adapter)
      } else {
        adapter
      },
    )
  }
  self.record(name, fields)
}

///|
/// Generate typed MoonBit adapters and direct-access fixed numeric views.
/// Whole-message adapters use the shared checked runtime. The result imports
/// this module under the alias `sbe`.
pub fn generate_moonbit(
  xml : String,
  includes~ : Map[String, String] = Map([]),
) -> String raise SbeError {
  let schema = parse_schema(xml, includes~)
  let output = StringBuilder()
  output.write_string(
    "// Generated by liyun6666/moonsbe. Do not edit.\n// Schema ID \{schema.id}, schema version \{schema.version}.\n\n",
  )
  output.write_string(
    "///|\nlet compiled_schema : Lazy[@sbe.Schema] = Lazy(() => try! @sbe.parse_schema(\n  \{code_quote(xml)},\n  includes=Map([\n",
  )
  for name, source in includes {
    output.write_string("    (\{code_quote(name)}, \{code_quote(source)}),\n")
  }
  output.write_string("  ]),\n))\n\n")
  let generator = Generator::{ schema, output, emitted: Map([]), }
  for message in schema.messages {
    let name = type_identifier(message.name)
    generator.block_record(name, message.block, 0, "\{message.id}")
    output.write_string(
      "///|\npub fn \{name}::encode(self : \{name}, version? : Int = \{schema.version}) -> Bytes raise @sbe.SbeError {\n  @sbe.encode(compiled_schema.force(), \{message.id}, self.to_value(), version~)\n}\n\n",
    )
    output.write_string(
      "///|\npub fn \{name}::decode(bytes : Bytes) -> \{name} raise @sbe.SbeError {\n  let message = @sbe.decode(compiled_schema.force(), bytes)\n  if message.header.template_id != \{message.id} {\n    raise @sbe.value_error(\"templateId\", \"wrong generated message type\")\n  }\n  \{name}::from_value(message.value)\n}\n\n",
    )
    generator.fixed_view(name, message)
  }
  output.to_string()
}
