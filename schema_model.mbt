///|
pub(all) enum Presence {
  Required
  Optional
  Constant
} derive(Eq, Debug)

///|
pub(all) struct TypeEncoding {
  primitive : Primitive
  length : Int32
  presence : Presence
  character_encoding : String
  min_value : String?
  max_value : String?
  null_value : String?
  constant : String?
} derive(Debug)

///|
pub(all) struct EnumCase {
  name : String
  value : String
  since_version : Int32
} derive(Debug)

///|
pub(all) struct CompositeMember {
  name : String
  type_name : String
  offset : Int32
  since_version : Int32
} derive(Debug)

///|
pub(all) enum TypeDef {
  Encoded(TypeEncoding)
  Enumeration(Primitive, Array[EnumCase], Presence)
  BitSet(Primitive, Array[EnumCase])
  Composite(Array[CompositeMember], Int32)
} derive(Debug)

///|
pub(all) struct FieldDef {
  name : String
  id : Int32
  type_name : String
  offset : Int32
  since_version : Int32
  presence : Presence
  value_ref : String?
} derive(Debug)

///|
pub(all) struct GroupDef {
  name : String
  id : Int32
  since_version : Int32
  block : BlockDef
  count_primitive : Primitive
  max_count : Int32
  dimension : FrameLayout
} derive(Debug)

///|
pub(all) struct DataDef {
  name : String
  id : Int32
  since_version : Int32
  length_primitive : Primitive
  max_length : Int32
  character_encoding : String
} derive(Debug)

///|
pub(all) struct BlockDef {
  fields : Array[FieldDef]
  groups : Array[GroupDef]
  data : Array[DataDef]
  block_length : Int32
} derive(Debug)

///|
pub(all) struct MessageDef {
  name : String
  id : Int32
  since_version : Int32
  block : BlockDef
} derive(Debug)

///|
/// A compiled schema. Treat collections as immutable after compilation.
pub(all) struct Schema {
  id : Int32
  version : Int32
  package_name : String
  byte_order : ByteOrder
  header_layout : FrameLayout
  types : Map[String, TypeDef]
  messages : Array[MessageDef]
} derive(Debug)

///|
pub fn Schema::message(self : Schema, id : Int32) -> MessageDef raise SbeError {
  for message in self.messages {
    if message.id == id {
      return message
    }
  }
  raise InvalidMessage("unknown templateId \{id}")
}

///|
pub fn Schema::type_def(self : Schema, name : String) -> TypeDef raise SbeError {
  match self.types.get(name) {
    Some(value) => value
    None => raise InvalidSchema("unknown type: \{name}", 0)
  }
}

///|
pub fn Schema::encoded_size(
  self : Schema,
  name : String,
) -> Int32 raise SbeError {
  type_size(self.type_def(name))
}

///|
fn type_size(type_def : TypeDef) -> Int32 {
  match type_def {
    Encoded(encoding) =>
      if encoding.presence == Constant {
        0
      } else {
        encoding.primitive.width() * encoding.length
      }
    Enumeration(primitive, _, presence) =>
      if presence == Constant {
        0
      } else {
        primitive.width()
      }
    BitSet(primitive, _) => primitive.width()
    Composite(_, length) => length
  }
}

///|
fn Schema::encoded_size_at(
  self : Schema,
  name : String,
  version : Int32,
) -> Int32 raise SbeError {
  let definition = self.type_def(name)
  match definition {
    Composite(members, _) if version < self.version => {
      let mut end = 0
      for entry in members {
        if entry.since_version <= version {
          end = end.max(
            entry.offset + self.encoded_size_at(entry.type_name, version),
          )
        }
      }
      end
    }
    _ => type_size(definition)
  }
}

///|
fn type_presence(type_def : TypeDef) -> Presence {
  match type_def {
    Encoded(encoding) => encoding.presence
    Enumeration(_, _, presence) => presence
    _ => Required
  }
}

///|
fn parse_presence(text : String) -> Presence raise SbeError {
  match text {
    "required" => Required
    "optional" => Optional
    "constant" => Constant
    _ => raise InvalidSchema("unknown presence: \{text}", 0)
  }
}
