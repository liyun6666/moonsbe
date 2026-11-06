///|
/// Typed values retain full uint64 and int64 precision on every backend.
/// Integers are strings in JSON; binary values use lowercase hexadecimal.
pub(all) enum Value {
  Signed(Int64)
  Unsigned(UInt64)
  Floating(Double)
  Text(String)
  Binary(Bytes)
  Record(Map[String, Value])
  Sequence(Array[Value])
  Absent
} derive(Debug)

///|
pub fn Value::field(self : Value, name : String) -> Value raise SbeError {
  match self {
    Record(fields) => match fields.get(name) {
      Some(value) => value
      None => raise InvalidValue(name, "required field is missing")
    }
    _ => raise InvalidValue(name, "expected a record")
  }
}

///|
pub fn Value::as_record(self : Value) -> Map[String, Value] raise SbeError {
  match self {
    Record(fields) => fields
    _ => raise InvalidValue("value", "expected a record")
  }
}

///|
pub fn Value::as_sequence(self : Value) -> Array[Value] raise SbeError {
  match self {
    Sequence(values) => values
    _ => raise InvalidValue("value", "expected an array")
  }
}

///|
pub fn Value::as_unsigned(self : Value) -> UInt64 raise SbeError {
  match self {
    Unsigned(value) => value
    Signed(value) if value >= 0L => value.reinterpret_as_uint64()
    _ => raise InvalidValue("value", "expected an unsigned integer")
  }
}

///|
pub fn Value::as_signed(self : Value) -> Int64 raise SbeError {
  match self {
    Signed(value) => value
    Unsigned(value) if value <= 0x7fffffffffffffffUL => value.reinterpret_as_int64()
    _ => raise InvalidValue("value", "expected a signed integer")
  }
}

///|
pub fn Value::as_float(self : Value) -> Double raise SbeError {
  match self {
    Floating(value) => value
    _ => raise InvalidValue("value", "expected a floating point number")
  }
}

///|
pub fn Value::as_text(self : Value) -> String raise SbeError {
  match self {
    Text(value) => value
    _ => raise InvalidValue("value", "expected text")
  }
}

///|
pub fn Value::as_binary(self : Value) -> Bytes raise SbeError {
  match self {
    Binary(value) => value
    _ => raise InvalidValue("value", "expected binary data")
  }
}

///|
pub fn to_hex(bytes : Bytes) -> String {
  let result = StringBuilder()
  let digits = "0123456789abcdef".iter().to_array()
  for byte in bytes {
    result.write_char(digits[byte.to_int() >> 4])
    result.write_char(digits[byte.to_int() & 15])
  }
  result.to_string()
}

///|
pub fn from_hex(text : String) -> Bytes raise SbeError {
  if text.length() > 33554432 || text.length() % 2 != 0 {
    raise InvalidValue("hex", "expected an even number of hexadecimal digits within 16 MiB")
  }
  let bytes : Array[Byte] = []
  let mut first = -1
  for char in text {
    let value = match char {
      '0'..='9' => char.to_int() - '0'.to_int()
      'a'..='f' => char.to_int() - 'a'.to_int() + 10
      'A'..='F' => char.to_int() - 'A'.to_int() + 10
      _ => raise InvalidValue("hex", "invalid hexadecimal digit")
    }
    if first < 0 {
      first = value
    } else {
      bytes.push((first * 16 + value).to_byte())
      first = -1
    }
  }
  Bytes::from_array(bytes)
}

///|
pub fn Value::to_json(self : Value) -> Json {
  match self {
    Signed(value) => Json::string(value.to_string())
    Unsigned(value) => Json::string(value.to_string())
    Floating(value) => if value.is_nan() {
      Json::string("NaN")
    } else if value.is_inf() {
      Json::string(if value > 0.0 { "Infinity" } else { "-Infinity" })
    } else { Json::number(value) }
    Text(value) => Json::string(value)
    Binary(value) => Json::string(to_hex(value))
    Record(fields) => {
      let result : Map[String, Json] = Map([])
      for name, value in fields { result[name] = value.to_json() }
      Json::object(result)
    }
    Sequence(values) => Json::array(values.map(Value::to_json))
    Absent => Json::null()
  }
}

///|
fn scalar_from_literal(primitive : Primitive, text : String) -> Value raise SbeError {
  if primitive == Char {
    if @utf8.encode(text).length() != 1 {
      raise InvalidValue("char", "expected one ASCII byte")
    }
    return Text(text)
  }
  if primitive.is_signed() {
    let value = @string.parse_int64(text) catch {
      _ => raise InvalidValue("integer", "invalid signed literal: \{text}")
    }
    Signed(value)
  } else if primitive.is_float() {
    if text == "NaN" { return Floating(0.0 / 0.0) }
    let value = @string.parse_double(text) catch {
      _ => raise InvalidValue("float", "invalid floating literal: \{text}")
    }
    Floating(value)
  } else {
    let value = @string.parse_uint64(text) catch {
      _ => raise InvalidValue("integer", "invalid unsigned literal: \{text}")
    }
    Unsigned(value)
  }
}

///|
fn default_null(primitive : Primitive) -> Value {
  match primitive {
    Char => Text("\u{0000}")
    Int8 => Signed(-128L)
    UInt8 => Unsigned(255UL)
    Int16 => Signed(-32768L)
    UInt16 => Unsigned(65535UL)
    Int32 => Signed(-2147483648L)
    UInt32 => Unsigned(0xffffffffUL)
    Int64 => Signed(-9223372036854775808L)
    UInt64 => Unsigned(0xffffffffffffffffUL)
    Float32 | Float64 => Floating(0.0 / 0.0)
  }
}

///|
fn same_scalar(left : Value, right : Value) -> Bool {
  match (left, right) {
    (Signed(a), Signed(b)) => a == b
    (Unsigned(a), Unsigned(b)) => a == b
    (Floating(a), Floating(b)) => a == b || (a.is_nan() && b.is_nan())
    (Text(a), Text(b)) => a == b
    (Absent, Absent) => true
    _ => false
  }
}
