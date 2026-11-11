///|
fn encoding_null(encoding : TypeEncoding) -> Value raise SbeError {
  match encoding.null_value {
    Some(text) => {
      let value = scalar_from_literal(encoding.primitive, text)
      if encoding.primitive == Float32 {
        Floating(Float::from_double(value.as_float()).to_double())
      } else {
        value
      }
    }
    None => default_null(encoding.primitive)
  }
}

///|
fn check_scalar(
  encoding : TypeEncoding,
  value : Value,
  path : String,
) -> Unit raise SbeError {
  let primitive = encoding.primitive
  if primitive == Char {
    let text = value.as_text()
    let bytes = @utf8.encode(text)
    if bytes.length() != 1 || bytes[0].to_int() < 32 || bytes[0].to_int() > 126 {
      raise InvalidValue(path, "char must be a printable ASCII byte")
    }
    return
  }
  if primitive.is_signed() {
    let number = value.as_signed()
    let bits = primitive.width() * 8
    let min = match encoding.min_value {
      Some(text) => scalar_from_literal(primitive, text).as_signed()
      None =>
        if bits == 64 {
          -9223372036854775807L
        } else {
          0L - (1L << (bits - 1)) + 1L
        }
    }
    let max = match encoding.max_value {
      Some(text) => scalar_from_literal(primitive, text).as_signed()
      None =>
        if bits == 64 {
          9223372036854775807L
        } else {
          (1L << (bits - 1)) - 1L
        }
    }
    if number < min ||
      number > max ||
      same_scalar(Signed(number), encoding_null(encoding)) {
      raise InvalidValue(path, "signed integer is outside its SBE value range")
    }
  } else if primitive.is_float() {
    let number = value.as_float()
    if number.is_nan() || number.is_inf() {
      raise InvalidValue(path, "required floating value must be finite")
    }
    if primitive == Float32 && Float::from_double(number).is_inf() {
      raise InvalidValue(path, "value overflows float32")
    }
    let wire_value = if primitive == Float32 {
      Float::from_double(number).to_double()
    } else {
      number
    }
    if same_scalar(Floating(wire_value), encoding_null(encoding)) {
      raise InvalidValue(path, "floating value equals the reserved null")
    }
    match encoding.min_value {
      Some(text) if number < scalar_from_literal(primitive, text).as_float() =>
        raise InvalidValue(path, "float is below minValue")
      _ => ()
    }
    match encoding.max_value {
      Some(text) if number > scalar_from_literal(primitive, text).as_float() =>
        raise InvalidValue(path, "float exceeds maxValue")
      _ => ()
    }
  } else {
    let number = value.as_unsigned()
    let min = match encoding.min_value {
      Some(text) => scalar_from_literal(primitive, text).as_unsigned()
      None => 0UL
    }
    let max = match encoding.max_value {
      Some(text) => scalar_from_literal(primitive, text).as_unsigned()
      None =>
        if primitive.width() == 8 {
          0xfffffffffffffffeUL
        } else {
          (1UL << (primitive.width() * 8)) - 2UL
        }
    }
    if number < min ||
      number > max ||
      same_scalar(Unsigned(number), encoding_null(encoding)) {
      raise InvalidValue(
        path, "unsigned integer is outside its SBE value range",
      )
    }
  }
}

///|
fn write_scalar(
  writer : Writer,
  primitive : Primitive,
  value : Value,
) -> Unit raise SbeError {
  if primitive == Char {
    writer.write_bytes(@utf8.encode(value.as_text()))
  } else if primitive.is_float() {
    writer.write_float(value.as_float(), primitive.width())
  } else if primitive.is_signed() {
    writer.write_int(value.as_signed(), primitive.width())
  } else {
    writer.write_uint(value.as_unsigned(), primitive.width())
  }
}

///|
fn read_scalar(reader : Reader, primitive : Primitive) -> Value raise SbeError {
  if primitive == Char {
    let code = reader.read_uint(1).to_int()
    match code.to_char() {
      Some(char) => Text(char.to_string())
      None => raise InvalidMessage("invalid character byte")
    }
  } else if primitive.is_float() {
    Floating(reader.read_float(primitive.width()))
  } else if primitive.is_signed() {
    Signed(reader.read_int(primitive.width()))
  } else {
    Unsigned(reader.read_uint(primitive.width()))
  }
}

///|
fn encode_text(
  text : String,
  character_encoding : String,
  path : String,
) -> Bytes raise SbeError {
  let bytes = @utf8.encode(text)
  if character_encoding == "ASCII" || character_encoding == "US-ASCII" {
    for byte in bytes {
      if byte.to_int() > 127 {
        raise InvalidValue(path, "non-ASCII character in ASCII field")
      }
    }
  }
  bytes
}

///|
fn decode_text(
  bytes : Bytes,
  character_encoding : String,
) -> String raise SbeError {
  if character_encoding == "ASCII" || character_encoding == "US-ASCII" {
    for byte in bytes {
      if byte.to_int() > 127 {
        raise InvalidMessage("non-ASCII byte in ASCII field")
      }
    }
  }
  @utf8.decode(bytes) catch {
    _ => raise InvalidMessage("malformed UTF-8 in text field")
  }
}

///|
fn constant_value(schema : Schema, field : FieldDef) -> Value raise SbeError {
  match field.value_ref {
    Some(reference) => {
      let parts = reference.split(".").to_array()
      if parts.length() != 2 {
        raise InvalidSchema("valueRef must be Enum.Value", 0)
      }
      let enum_name = parts[0].to_owned()
      let case_name = parts[1].to_owned()
      match schema.type_def(enum_name) {
        Enumeration(primitive, cases, _) => {
          for entry in cases {
            if entry.name == case_name {
              return match schema.type_def(field.type_name) {
                Enumeration(_, _, _) => Text(case_name)
                _ => scalar_from_literal(primitive, entry.value)
              }
            }
          }
          raise InvalidSchema("unknown valueRef case: \{reference}", 0)
        }
        _ => raise InvalidSchema("valueRef target must be an enum", 0)
      }
    }
    None =>
      match schema.type_def(field.type_name) {
        Encoded(encoding) =>
          match encoding.constant {
            Some(text) =>
              if encoding.primitive == Char {
                Text(text)
              } else {
                scalar_from_literal(encoding.primitive, text)
              }
            None => raise InvalidSchema("constant field has no value", 0)
          }
        _ => raise InvalidSchema("constant field has no valueRef", 0)
      }
  }
}
