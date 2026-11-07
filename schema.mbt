///|
fn collect_types(
  node : XmlNode,
  definitions : Map[String, XmlNode],
  includes : Map[String, String],
  stack : Array[String],
) -> Unit raise SbeError {
  if stack.length() > 16 {
    raise LimitExceeded("XInclude depth exceeds 16")
  }
  for child in node.children {
    match child.local_name() {
      "include" => {
        let href = child.required("href")
        if child.attributes.get("parse").unwrap_or("xml") != "xml" ||
          child.attributes.contains("xpointer") {
          raise Unsupported("XInclude text mode and xpointer")
        }
        for previous in stack {
          if previous == href {
            raise InvalidSchema("cyclic XInclude: \{href}", child.position)
          }
        }
        let text = match includes.get(href) {
          Some(value) => value
          None =>
            raise InvalidSchema(
              "XInclude resource was not supplied: \{href}",
              child.position,
            )
        }
        let resource = parse_xml(text)
        if resource.local_name() != "types" {
          raise Unsupported("XInclude supports a types root only")
        }
        stack.push(href)
        collect_types(resource, definitions, includes, stack)
        ignore(stack.pop())
      }
      "types" => collect_types(child, definitions, includes, stack)
      "type" | "enum" | "set" | "composite" => {
        let name = child.required("name")
        if definitions.contains(name) || primitive_type(name) != None {
          raise InvalidSchema(
            "duplicate or reserved type name: \{name}",
            child.position,
          )
        }
        definitions[name] = child
      }
      "message" => ()
      _ => raise Unsupported("schema element: \{child.name}")
    }
  }
}

///|
fn parse_schema_id(
  node : XmlNode,
  key : String,
  default~ : Int32,
) -> Int32 raise SbeError {
  let value = node.integer(key, default~)
  if value > 65534 {
    raise InvalidSchema(
      "\{key} must fit uint16 without the null value",
      node.position,
    )
  }
  value
}

///|
fn SchemaCompiler::block(
  self : SchemaCompiler,
  node : XmlNode,
  depth : Int32,
) -> BlockDef raise SbeError {
  if depth > 32 {
    raise LimitExceeded("nested group depth exceeds 32")
  }
  let fields : Array[FieldDef] = []
  let groups : Array[GroupDef] = []
  let data : Array[DataDef] = []
  let names : Map[String, Bool] = Map([])
  let ids : Map[Int32, Bool] = Map([])
  let mut offset = 0
  let mut phase = 0
  for child in node.children {
    let name = child.required("name")
    let id = child.integer("id", default=-1)
    if id < 0 || ids.contains(id) || names.contains(name) {
      raise InvalidSchema(
        "member ID and name must be present and unique",
        child.position,
      )
    }
    ids[id] = true
    names[name] = true
    let since_version = parse_schema_id(child, "sinceVersion", default=0)
    match child.local_name() {
      "field" => {
        if phase != 0 {
          raise InvalidSchema(
            "fixed fields must precede groups and data",
            child.position,
          )
        }
        let type_name = child.required("type")
        let type_def = self.resolve(type_name, 0)
        let presence = match child.attributes.get("presence") {
          Some(value) => parse_presence(value)
          None => type_presence(type_def)
        }
        let value_ref = child.attributes.get("valueRef")
        if presence == Constant &&
          type_presence(type_def) != Constant &&
          value_ref == None {
          raise InvalidSchema(
            "constant field requires valueRef or constant type",
            child.position,
          )
        }
        let start = child.integer("offset", default=offset)
        if start < offset {
          raise InvalidSchema(
            "field offset overlaps previous field",
            child.position,
          )
        }
        fields.push({
          name,
          id,
          type_name,
          offset: start,
          since_version,
          presence,
          value_ref,
        })
        offset = start +
          (if presence == Constant { 0 } else { type_size(type_def) })
      }
      "group" => {
        if phase > 1 {
          raise InvalidSchema(
            "groups must precede variable data",
            child.position,
          )
        }
        phase = 1
        let dimension = child.attributes
          .get("dimensionType")
          .unwrap_or("groupSizeEncoding")
        let (count_primitive, max_count) = self.group_dimension(dimension)
        groups.push({
          name,
          id,
          since_version,
          block: self.block(child, depth + 1),
          count_primitive,
          max_count,
        })
      }
      "data" => {
        phase = 2
        let type_name = child.required("type")
        let (length_primitive, max_length, character_encoding) = self.data_encoding(
          type_name,
        )
        data.push({
          name,
          id,
          since_version,
          length_primitive,
          max_length,
          character_encoding,
        })
      }
      _ => raise Unsupported("message member: \{child.name}")
    }
  }
  let block_length = node.integer("blockLength", default=offset)
  if block_length < offset || block_length > 65534 {
    raise InvalidSchema(
      "blockLength is smaller than fields or exceeds uint16",
      node.position,
    )
  }
  { fields, groups, data, block_length, }
}

///|
fn SchemaCompiler::group_dimension(
  self : SchemaCompiler,
  name : String,
) -> (Primitive, Int32) raise SbeError {
  match self.resolve(name, 0) {
    Composite(members, length) if members.length() == 2 => {
      let first = members[0]
      let second = members[1]
      if first.name != "blockLength" ||
        first.offset != 0 ||
        second.name != "numInGroup" ||
        second.offset != 2 {
        raise Unsupported(
          "group dimensions require uint16 blockLength followed by numInGroup",
        )
      }
      let block_type = self.resolve(first.type_name, 0)
      let count_type = self.resolve(second.type_name, 0)
      match (block_type, count_type) {
        (Encoded(a), Encoded(b)) if a.primitive == UInt16 &&
          a.length == 1 &&
          b.length == 1 &&
          b.presence == Required &&
          (
            b.primitive == UInt8 ||
            b.primitive == UInt16 ||
            b.primitive == UInt32
          ) &&
          length == 2 + b.primitive.width() => {
          let default = if b.primitive == UInt8 { 254 } else { 65534 }
          let max_count = match b.max_value {
            None => default
            Some(value) =>
              @string.parse_int(value) catch {
                _ => raise InvalidSchema("invalid numInGroup maxValue", 0)
              }
          }
          (b.primitive, if max_count < 100000 { max_count } else { 100000 })
        }
        _ => raise Unsupported("group dimension encodings")
      }
    }
    _ => raise Unsupported("extended group dimensions")
  }
}

///|
fn SchemaCompiler::data_encoding(
  self : SchemaCompiler,
  name : String,
) -> (Primitive, Int32, String) raise SbeError {
  match self.resolve(name, 0) {
    Composite(members, _) if members.length() == 2 => {
      let first = members[0]
      let second = members[1]
      match
        (self.resolve(first.type_name, 0), self.resolve(second.type_name, 0)) {
        (Encoded(a), Encoded(b)) if first.name == "length" &&
          second.name == "varData" &&
          first.offset == 0 &&
          second.offset == a.primitive.width() &&
          a.length == 1 &&
          a.presence == Required &&
          b.length == 0 &&
          (
            a.primitive == UInt8 ||
            a.primitive == UInt16 ||
            a.primitive == UInt32
          ) &&
          (b.primitive == Char || b.primitive == UInt8) => {
          let default = if a.primitive == UInt8 {
            254
          } else if a.primitive == UInt16 {
            65534
          } else {
            16777216
          }
          let maximum = match a.max_value {
            None => default
            Some(value) =>
              @string.parse_int(value) catch {
                _ => raise InvalidSchema("invalid varData length maxValue", 0)
              }
          }
          (
            a.primitive,
            if maximum < 16777216 {
              maximum
            } else {
              16777216
            },
            b.character_encoding,
          )
        }
        _ => raise Unsupported("variable data encoding layout")
      }
    }
    _ =>
      raise Unsupported("variable data requires length and varData composite")
  }
}

///|
/// Compile an SBE XML schema. Include resources are supplied explicitly by
/// name; the compiler does not access the network or local filesystem.
pub fn parse_schema(
  xml : String,
  includes~ : Map[String, String] = Map([]),
) -> Schema raise SbeError {
  let root = parse_xml(xml)
  if root.local_name() != "messageSchema" {
    raise InvalidSchema("expected SBE messageSchema root", root.position)
  }
  let root_parts = root.name.split(":").to_array()
  if root_parts.length() > 1 {
    let binding = root.attributes.get("xmlns:\{root_parts[0]}")
    if binding != Some("http://fixprotocol.io/2016/sbe") &&
      binding != Some("http://fixprotocol.io/2019/sbe") {
      raise InvalidSchema("unbound or unsupported SBE namespace", root.position)
    }
  }
  let schema_id = parse_schema_id(root, "id", default=-1)
  if schema_id < 0 {
    raise InvalidSchema("messageSchema requires id", root.position)
  }
  let version = parse_schema_id(root, "version", default=0)
  let order = match root.attributes.get("byteOrder").unwrap_or("littleEndian") {
    "littleEndian" => LittleEndian
    "bigEndian" => BigEndian
    other => raise InvalidSchema("unknown byteOrder: \{other}", root.position)
  }
  let definitions : Map[String, XmlNode] = Map([])
  collect_types(root, definitions, includes, [])
  let compiler = SchemaCompiler::{
    definitions,
    compiled: Map([]),
    visiting: Map([]),
  }
  // Resolve a snapshot because composite compilation registers inline types.
  let type_names = definitions.keys().to_array()
  for name in type_names {
    ignore(compiler.resolve(name, 0))
  }
  let header_name = root.attributes.get("headerType").unwrap_or("messageHeader")
  match compiler.resolve(header_name, 0) {
    Composite(members, 8) if members.length() == 4 => {
      let names = ["blockLength", "templateId", "schemaId", "version"]
      for index, entry in members {
        if entry.name != names[index] || entry.offset != index * 2 {
          raise Unsupported("nonstandard message header layout")
        }
        match compiler.resolve(entry.type_name, 0) {
          Encoded(encoding) if encoding.primitive == UInt16 &&
            encoding.length == 1 &&
            encoding.presence == Required => ()
          _ =>
            raise Unsupported(
              "message header must contain four required uint16 values",
            )
        }
      }
    }
    _ => raise Unsupported("message header must be 8 bytes")
  }
  let messages : Array[MessageDef] = []
  let ids : Map[Int32, Bool] = Map([])
  let names : Map[String, Bool] = Map([])
  for child in root.children {
    if child.local_name() != "message" {
      continue
    }
    let id = parse_schema_id(child, "id", default=-1)
    let name = child.required("name")
    if id < 0 || ids.contains(id) || names.contains(name) {
      raise InvalidSchema(
        "message ID and name must be present and unique",
        child.position,
      )
    }
    ids[id] = true
    names[name] = true
    messages.push({
      name,
      id,
      since_version: parse_schema_id(child, "sinceVersion", default=0),
      block: compiler.block(child, 0),
    })
  }
  if messages.is_empty() {
    raise InvalidSchema("schema must contain a message", root.position)
  }
  let schema : Schema = {
    id: schema_id,
    version,
    package_name: root.attributes.get("package").unwrap_or("generated"),
    byte_order: order,
    types: compiler.compiled,
    messages,
  }
  validate_compiled_schema(schema)
  schema
}
