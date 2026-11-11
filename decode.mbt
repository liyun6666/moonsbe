///|
priv struct DecodeState {
  reader : Reader
  mut entries_left : Int32
}

///|
fn decode_type(
  schema : Schema,
  type_name : String,
  reader : Reader,
  presence : Presence,
  version : Int32,
  depth : Int32,
) -> Value raise SbeError {
  if depth > 64 {
    raise LimitExceeded("value nesting exceeds 64")
  }
  match schema.type_def(type_name) {
    Encoded(encoding) => {
      if encoding.presence == Constant {
        let text = encoding.constant.unwrap_or("")
        return if encoding.primitive == Char {
          Text(text)
        } else {
          scalar_from_literal(encoding.primitive, text)
        }
      }
      if encoding.primitive == Char && encoding.length != 1 {
        let bytes = reader.read_bytes(encoding.length)
        let mut length = bytes.length()
        while length > 0 && bytes[length - 1] == 0 {
          length -= 1
        }
        for index in 0..<length {
          if bytes[index] == 0 {
            raise InvalidMessage("embedded NUL before fixed text padding")
          }
        }
        return Text(
          decode_text(bytes[:length].to_owned(), encoding.character_encoding),
        )
      }
      if encoding.length == 1 {
        let value = read_scalar(reader, encoding.primitive)
        if presence == Optional && same_scalar(value, encoding_null(encoding)) {
          return Absent
        }
        check_scalar(encoding, value, type_name)
        value
      } else {
        let values : Array[Value] = []
        for _ in 0..<encoding.length {
          let value = read_scalar(reader, encoding.primitive)
          check_scalar(encoding, value, type_name)
          values.push(value)
        }
        Sequence(values)
      }
    }
    Enumeration(primitive, cases, _) => {
      let value = read_scalar(reader, primitive)
      if presence == Optional && same_scalar(value, default_null(primitive)) {
        return Absent
      }
      for entry in cases {
        if entry.since_version <= version &&
          same_scalar(value, scalar_from_literal(primitive, entry.value)) {
          return Text(entry.name)
        }
      }
      raise InvalidMessage("unknown enum value in \{type_name}")
    }
    BitSet(primitive, cases) => {
      let bits = reader.read_uint(primitive.width())
      let mut known_bits = 0UL
      let selected : Array[Value] = []
      for entry in cases {
        let bit = @string.parse_int(entry.value) catch {
          _ => raise InvalidSchema("invalid set bit", 0)
        }
        let mask = 1UL << bit
        if entry.since_version <= version {
          known_bits = known_bits | mask
          if (bits & mask) != 0UL {
            selected.push(Text(entry.name))
          }
        }
      }
      if (bits & (known_bits ^ 0xffffffffffffffffUL)) != 0UL {
        raise InvalidMessage("unknown set bits in \{type_name}")
      }
      Sequence(selected)
    }
    Composite(members, _) => {
      let start = reader.position()
      let length = schema.encoded_size_at(type_name, version)
      reader.require(start, length)
      if presence == Optional {
        let (first, marker) = schema.composite_null_marker(members)
        reader.seek(start + first.offset)
        let value = read_scalar(reader, marker.primitive)
        if same_scalar(value, encoding_null(marker)) {
          reader.seek(start + length)
          return Absent
        }
      }
      let fields : Map[String, Value] = Map([])
      for entry in members {
        if entry.since_version > version {
          fields[entry.name] = Absent
          continue
        }
        reader.seek(start + entry.offset)
        let nested = schema.type_def(entry.type_name)
        fields[entry.name] = decode_type(
          schema,
          entry.type_name,
          reader,
          type_presence(nested),
          version,
          depth + 1,
        )
      }
      reader.seek(start + length)
      Record(fields)
    }
  }
}

///|
fn decode_block(
  schema : Schema,
  block : BlockDef,
  state : DecodeState,
  acting_length : Int32,
  version : Int32,
  depth : Int32,
) -> Value raise SbeError {
  if depth > 32 {
    raise LimitExceeded("group depth exceeds 32")
  }
  let reader = state.reader
  let start = reader.position()
  reader.require(start, acting_length)
  let fields : Map[String, Value] = Map([])
  for field in block.fields {
    if field.since_version > version {
      fields[field.name] = Absent
    } else if field.presence == Constant {
      fields[field.name] = constant_value(schema, field)
    } else {
      let size = schema.encoded_size_at(field.type_name, version)
      if field.offset > acting_length || size > acting_length - field.offset {
        raise InvalidMessage(
          "blockLength does not contain active field \{field.name}",
        )
      }
      reader.seek(start + field.offset)
      fields[field.name] = decode_type(
        schema,
        field.type_name,
        reader,
        field.presence,
        version,
        0,
      )
    }
  }
  reader.seek(start + acting_length)
  for group in block.groups {
    if group.since_version > version {
      fields[group.name] = Absent
      continue
    }
    let dimensions = group.dimension.read(reader)
    check_frame_counts(dimensions, group.block, version)
    let length = dimensions["blockLength"]
    let count = dimensions["numInGroup"]
    if count > state.entries_left {
      raise LimitExceeded("group entry budget exhausted: \{group.name}")
    }
    state.entries_left -= count
    let entries : Array[Value] = []
    for _ in 0..<count {
      entries.push(
        decode_block(schema, group.block, state, length, version, depth + 1),
      )
    }
    fields[group.name] = Sequence(entries)
  }
  for data in block.data {
    if data.since_version > version {
      fields[data.name] = Absent
      continue
    }
    let length_word = reader.read_uint(data.length_primitive.width())
    if length_word > data.max_length.to_uint64() {
      raise LimitExceeded("variable data length exceeds limit: \{data.name}")
    }
    let bytes = reader.read_bytes(length_word.to_int())
    fields[data.name] = if data.character_encoding == "" {
      Binary(bytes)
    } else {
      Text(decode_text(bytes, data.character_encoding))
    }
  }
  Record(fields)
}

///|
pub(all) struct DecodedMessage {
  header : MessageHeader
  value : Value
} derive(Debug)

///|
/// Decode exactly one transport-delimited message. Extra trailing bytes are
/// rejected rather than interpreted as another frame or silently discarded.
pub fn decode(
  schema : Schema,
  bytes : Bytes,
  max_entries~ : Int32 = 100000,
) -> DecodedMessage raise SbeError {
  if bytes.length() > 16777216 || max_entries < 0 || max_entries > 1000000 {
    raise LimitExceeded("message or entry budget exceeds supported limit")
  }
  let reader = Reader::new(bytes, order=schema.byte_order)
  let fields = schema.header_layout.read(reader)
  let header = MessageHeader::{
    block_length: fields["blockLength"],
    template_id: fields["templateId"],
    schema_id: fields["schemaId"],
    version: fields["version"],
  }
  if header.schema_id != schema.id {
    raise InvalidMessage("schemaId does not match compiled schema")
  }
  let message = schema.message(header.template_id)
  if message.since_version > header.version {
    raise InvalidMessage("template did not exist in acting version")
  }
  check_frame_counts(fields, message.block, header.version)
  let state = DecodeState::{ reader, entries_left: max_entries, }
  let value = decode_block(
    schema,
    message.block,
    state,
    header.block_length,
    header.version,
    0,
  )
  if reader.remaining() != 0 {
    raise InvalidMessage(
      "trailing bytes; unknown variable fields or incorrect frame boundary",
    )
  }
  { header, value, }
}
