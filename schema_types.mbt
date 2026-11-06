///|
priv struct SchemaCompiler {
  definitions : Map[String, XmlNode]
  compiled : Map[String, TypeDef]
  visiting : Map[String, Bool]
}

///|
fn primitive_type(name : String) -> Primitive? {
  try Primitive::parse(name) catch {
    _ => None
  } noraise { primitive => Some(primitive) }
}

///|
fn default_encoding(primitive : Primitive) -> TypeEncoding {
  {
    primitive, length: 1, presence: Required, character_encoding: "",
    min_value: None, max_value: None, null_value: None, constant: None,
  }
}

///|
fn SchemaCompiler::resolve(self : SchemaCompiler, name : String, depth : Int) -> TypeDef raise SbeError {
  if depth > 64 {
    raise LimitExceeded("type reference depth exceeds 64")
  }
  match self.compiled.get(name) {
    Some(value) => return value
    None => ()
  }
  if self.visiting.get(name).unwrap_or(false) {
    raise InvalidSchema("recursive type reference: \{name}", 0)
  }
  let node = match self.definitions.get(name) {
    Some(value) => value
    None => match primitive_type(name) {
      Some(primitive) => {
        let value = Encoded(default_encoding(primitive))
        self.compiled[name] = value
        return value
      }
      None => raise InvalidSchema("unknown encoding type: \{name}", 0)
    }
  }
  self.visiting[name] = true
  let result = match node.local_name() {
    "type" => Encoded(parse_encoding(node))
    "enum" => {
      let primitive = self.encoding_primitive(node.required("encodingType"), depth + 1)
      if primitive.is_float() {
        raise InvalidSchema("enum cannot use a floating encoding", node.position)
      }
      let values = parse_enum_cases(node, "validValue")
      if values.is_empty() {
        raise InvalidSchema("enum must contain validValue entries", node.position)
      }
      Enumeration(primitive, values, parse_presence(node.attributes.get("presence").unwrap_or("required")))
    }
    "set" => {
      let primitive = self.encoding_primitive(node.required("encodingType"), depth + 1)
      if primitive.is_float() || primitive.is_signed() || primitive == Char {
        raise InvalidSchema("set encoding must be an unsigned integer", node.position)
      }
      let values = parse_enum_cases(node, "choice")
      for entry in values {
        let bit = @string.parse_int(entry.value) catch {
          _ => raise InvalidSchema("set choice must be a bit index", node.position)
        }
        if bit < 0 || bit >= primitive.width() * 8 {
          raise InvalidSchema("set bit index is outside its encoding", node.position)
        }
      }
      BitSet(primitive, values)
    }
    "composite" => {
      let members : Array[CompositeMember] = []
      let names : Map[String, Bool] = Map([])
      let mut offset = 0
      for child in node.children {
        let member_name = child.required("name")
        if names.contains(member_name) {
          raise InvalidSchema("duplicate composite member: \{member_name}", child.position)
        }
        names[member_name] = true
        let member_type_name = if child.local_name() == "ref" {
          child.required("type")
        } else {
          let qualified = "\{name}.\{member_name}"
          self.definitions[qualified] = child
          qualified
        }
        let resolved = self.resolve(member_type_name, depth + 1)
        let start = child.integer("offset", default=offset)
        if start < offset {
          raise InvalidSchema("composite offset overlaps previous member", child.position)
        }
        members.push({ name: member_name, type_name: member_type_name, offset: start })
        offset = start + type_size(resolved)
        if offset > 1048576 {
          raise LimitExceeded("composite size exceeds 1 MiB")
        }
      }
      Composite(members, offset)
    }
    _ => raise Unsupported("schema type element: \{node.name}")
  }
  self.compiled[name] = result
  self.visiting[name] = false
  result
}

///|
fn SchemaCompiler::encoding_primitive(self : SchemaCompiler, name : String, depth : Int) -> Primitive raise SbeError {
  match self.resolve(name, depth) {
    Encoded(encoding) if encoding.length == 1 && encoding.presence != Constant => encoding.primitive
    _ => raise InvalidSchema("encodingType must be a scalar primitive: \{name}", 0)
  }
}

///|
fn parse_encoding(node : XmlNode) -> TypeEncoding raise SbeError {
  let primitive = Primitive::parse(node.required("primitiveType"))
  let presence = parse_presence(node.attributes.get("presence").unwrap_or("required"))
  let value = node.text.trim().to_owned()
  let length = node.integer("length", default=if presence == Constant && primitive == Char {
    @utf8.encode(value).length()
  } else { 1 })
  if primitive.width() * length > 1048576 {
    raise LimitExceeded("primitive array size exceeds 1 MiB")
  }
  if presence == Constant && value.is_empty() {
    raise InvalidSchema("constant type requires a value", node.position)
  }
  let character_encoding = node.attributes.get("characterEncoding").unwrap_or(if primitive == Char { "ASCII" } else { "" })
  if character_encoding != "" && character_encoding != "ASCII" &&
      character_encoding != "US-ASCII" && character_encoding != "UTF-8" {
    raise Unsupported("characterEncoding: \{character_encoding}")
  }
  {
    primitive, length, presence, character_encoding,
    min_value: node.attributes.get("minValue"),
    max_value: node.attributes.get("maxValue"),
    null_value: node.attributes.get("nullValue"),
    constant: if presence == Constant { Some(value) } else { None },
  }
}

///|
fn parse_enum_cases(node : XmlNode, child_name : String) -> Array[EnumCase] raise SbeError {
  let result : Array[EnumCase] = []
  let names : Map[String, Bool] = Map([])
  let values : Map[String, Bool] = Map([])
  for child in node.children {
    if child.local_name() != child_name {
      raise InvalidSchema("unexpected element in \{node.name}", child.position)
    }
    let name = child.required("name")
    let value = child.text.trim().to_owned()
    if names.contains(name) || values.contains(value) || value.is_empty() {
      raise InvalidSchema("duplicate or empty enum/set entry", child.position)
    }
    names[name] = true
    values[value] = true
    result.push({ name, value, since_version: child.integer("sinceVersion", default=0) })
  }
  result
}
