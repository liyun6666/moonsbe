///|
/// A required unsigned scalar at its schema-defined position in a header.
pub(all) struct FrameMember {
  name : String
  offset : Int32
  primitive : Primitive
  min_value : Int32
  max_value : Int32
} derive(Debug, Eq)

///|
/// The compiled wire layout of a message header or a group dimension.
pub(all) struct FrameLayout {
  size : Int32
  members : Array[FrameMember]
} derive(Debug, Eq)

///|
fn FrameLayout::entry(
  self : FrameLayout,
  name : String,
) -> FrameMember raise SbeError {
  for entry in self.members {
    if entry.name == name {
      return entry
    }
  }
  raise InvalidSchema("missing framing member: \{name}", 0)
}

///|
fn framing_bound(
  value : String?,
  primitive : Primitive,
  default~ : Int32,
) -> Int32 raise SbeError {
  match value {
    None => default
    Some(text) => {
      let number = scalar_from_literal(primitive, text).as_unsigned()
      if number > 2147483647UL {
        2147483647
      } else {
        number.to_int()
      }
    }
  }
}

///|
fn SchemaCompiler::frame_layout(
  self : SchemaCompiler,
  name : String,
  required : Array[String],
) -> FrameLayout raise SbeError {
  let (entries, size) = match self.resolve(name, 0) {
    Composite(entries, size) => (entries, size)
    _ => raise InvalidSchema("framing type must be a composite: \{name}", 0)
  }
  let members : Array[FrameMember] = []
  for entry in entries {
    if !required.contains(entry.name) &&
      entry.name != "numGroups" &&
      entry.name != "numVarDataFields" {
      raise Unsupported("unknown framing member: \{name}.\{entry.name}")
    }
    let encoding = match self.resolve(entry.type_name, 0) {
      Encoded(encoding) if encoding.length == 1 &&
        encoding.presence == Required &&
        entry.since_version == 0 &&
        !encoding.primitive.is_signed() &&
        !encoding.primitive.is_float() &&
        encoding.primitive != Char => encoding
      _ =>
        raise InvalidSchema(
          "framing member must be an unversioned unsigned scalar: \{entry.name}",
          0,
        )
    }
    let primitive = encoding.primitive
    let physical_max = match primitive {
      UInt8 => 255
      UInt16 => 65535
      _ => 2147483647
    }
    let minimum = framing_bound(encoding.min_value, primitive, default=0)
    let maximum = framing_bound(
      encoding.max_value,
      primitive,
      default=physical_max,
    )
    if minimum > maximum || maximum > physical_max {
      raise InvalidSchema("invalid framing bounds: \{entry.name}", 0)
    }
    members.push({
      name: entry.name,
      offset: entry.offset,
      primitive,
      min_value: minimum,
      max_value: maximum,
    })
  }
  let layout = FrameLayout::{ size, members, }
  for field in required {
    ignore(layout.entry(field))
  }
  layout
}

///|
fn count_active(block : BlockDef, version : Int32) -> (Int32, Int32) {
  let mut groups = 0
  let mut data = 0
  for group in block.groups {
    if group.since_version <= version {
      groups += 1
    }
  }
  for field in block.data {
    if field.since_version <= version {
      data += 1
    }
  }
  (groups, data)
}

///|
fn FrameLayout::write(
  self : FrameLayout,
  writer : Writer,
  values : Map[String, Int32],
  block : BlockDef,
  version : Int32,
) -> Unit raise SbeError {
  let start = writer.position()
  let (groups, data) = count_active(block, version)
  for entry in self.members {
    let value = match entry.name {
      "numGroups" => groups
      "numVarDataFields" => data
      name => values.get(name).unwrap_or(-1)
    }
    if value < entry.min_value || value > entry.max_value {
      raise InvalidValue(entry.name, "value exceeds framing range")
    }
    writer.pad_to(start + entry.offset)
    writer.write_uint(value.to_uint64(), entry.primitive.width())
  }
  writer.pad_to(start + self.size)
}

///|
fn FrameLayout::read(
  self : FrameLayout,
  reader : Reader,
) -> Map[String, Int32] raise SbeError {
  let start = reader.position()
  reader.require(start, self.size)
  let fields : Map[String, Int32] = Map([])
  for entry in self.members {
    reader.seek(start + entry.offset)
    let value = reader.read_uint(entry.primitive.width())
    if value < entry.min_value.to_uint64() ||
      value > entry.max_value.to_uint64() {
      raise InvalidMessage("out-of-range framing member: \{entry.name}")
    }
    fields[entry.name] = value.to_int()
  }
  reader.seek(start + self.size)
  fields
}

///|
fn check_frame_counts(
  fields : Map[String, Int32],
  block : BlockDef,
  version : Int32,
) -> Unit raise SbeError {
  let (groups, data) = count_active(block, version)
  if fields.get("numGroups").unwrap_or(groups) != groups ||
    fields.get("numVarDataFields").unwrap_or(data) != data {
    raise InvalidMessage("framing counts do not match the acting schema")
  }
}
