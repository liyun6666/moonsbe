///|
/// Structured errors include an XML position or byte offset when available.
pub suberror SbeError {
  InvalidSchema(String, Int)
  Unsupported(String)
  Truncated(Int, Int, Int)
  InvalidValue(String, String)
  InvalidMessage(String)
  LimitExceeded(String)
} derive(Debug)

///|
pub(all) enum ByteOrder {
  LittleEndian
  BigEndian
} derive(Eq, Debug)

///|
pub(all) enum Primitive {
  Char
  Int8
  UInt8
  Int16
  UInt16
  Int32
  UInt32
  Int64
  UInt64
  Float32
  Float64
} derive(Eq, Debug)

///|
pub fn Primitive::width(self : Primitive) -> Int {
  match self {
    Char | Int8 | UInt8 => 1
    Int16 | UInt16 => 2
    Int32 | UInt32 | Float32 => 4
    Int64 | UInt64 | Float64 => 8
  }
}

///|
pub fn Primitive::is_signed(self : Primitive) -> Bool {
  match self {
    Int8 | Int16 | Int32 | Int64 => true
    _ => false
  }
}

///|
pub fn Primitive::is_float(self : Primitive) -> Bool {
  self == Float32 || self == Float64
}

///|
pub fn Primitive::parse(name : String) -> Primitive raise SbeError {
  match name {
    "char" => Char
    "int8" => Int8
    "uint8" => UInt8
    "int16" => Int16
    "uint16" => UInt16
    "int32" => Int32
    "uint32" => UInt32
    "int64" => Int64
    "uint64" => UInt64
    "float" => Float32
    "double" => Float64
    _ => raise Unsupported("primitiveType: \{name}")
  }
}
