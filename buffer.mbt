///|
/// Bounded binary input. Cursor reads never silently clamp a truncated frame.
pub struct Reader {
  bytes : Bytes
  order : ByteOrder
  mut position : Int32
}

///|
pub fn Reader::new(bytes : Bytes, order~ : ByteOrder = LittleEndian) -> Reader {
  { bytes, order, position: 0, }
}

///|
pub fn Reader::position(self : Reader) -> Int32 {
  self.position
}

///|
pub fn Reader::remaining(self : Reader) -> Int32 {
  self.bytes.length() - self.position
}

///|
fn Reader::require(
  self : Reader,
  offset : Int32,
  length : Int32,
) -> Unit raise SbeError {
  if offset < 0 ||
    length < 0 ||
    offset > self.bytes.length() ||
    length > self.bytes.length() - offset {
    raise Truncated(offset, length, self.bytes.length())
  }
}

///|
pub fn Reader::seek(self : Reader, position : Int32) -> Unit raise SbeError {
  self.require(position, 0)
  self.position = position
}

///|
pub fn Reader::read_bytes(
  self : Reader,
  length : Int32,
) -> Bytes raise SbeError {
  self.require(self.position, length)
  let result = self.bytes[self.position:self.position + length].to_owned()
  self.position += length
  result
}

///|
/// Read an unsigned word of 1, 2, 4 or 8 bytes without loss of precision.
pub fn Reader::read_uint(self : Reader, width : Int32) -> UInt64 raise SbeError {
  if width != 1 && width != 2 && width != 4 && width != 8 {
    raise InvalidMessage("integer width must be 1, 2, 4 or 8")
  }
  self.require(self.position, width)
  let mut word = 0UL
  for i in 0..<width {
    let shift = match self.order {
      LittleEndian => i * 8
      BigEndian => (width - i - 1) * 8
    }
    word = word | (self.bytes[self.position + i].to_uint64() << shift)
  }
  self.position += width
  word
}

///|
pub fn Reader::read_int(self : Reader, width : Int32) -> Int64 raise SbeError {
  let word = self.read_uint(width)
  if width == 8 {
    return word.reinterpret_as_int64()
  }
  let bits = width * 8
  let extended = if (word & (1UL << (bits - 1))) != 0UL {
    word | (0xffffffffffffffffUL << bits)
  } else {
    word
  }
  extended.reinterpret_as_int64()
}

///|
pub fn Reader::read_float(
  self : Reader,
  width : Int32,
) -> Double raise SbeError {
  match width {
    4 => Float::reinterpret_from_uint(self.read_uint(4).to_uint()).to_double()
    8 => self.read_uint(8).reinterpret_as_double()
    _ => raise InvalidMessage("float width must be 4 or 8")
  }
}

///|
/// A growable writer with an explicit output bound; padding is always zero.
pub struct Writer {
  bytes : Array[Byte]
  order : ByteOrder
  limit : Int32
}

///|
pub fn Writer::new(
  order~ : ByteOrder = LittleEndian,
  limit~ : Int32 = 16777216,
) -> Writer {
  { bytes: [], order, limit, }
}

///|
pub fn Writer::position(self : Writer) -> Int32 {
  self.bytes.length()
}

///|
pub fn Writer::to_bytes(self : Writer) -> Bytes {
  Bytes::from_array(self.bytes)
}

///|
fn Writer::reserve(self : Writer, count : Int32) -> Unit raise SbeError {
  if count < 0 || self.limit < 0 || count > self.limit - self.bytes.length() {
    raise LimitExceeded("encoded message exceeds the output limit")
  }
}

///|
pub fn Writer::pad_to(self : Writer, offset : Int32) -> Unit raise SbeError {
  if offset < self.bytes.length() {
    raise InvalidMessage("cannot pad backwards")
  }
  self.reserve(offset - self.bytes.length())
  while self.bytes.length() < offset {
    self.bytes.push(0)
  }
}

///|
pub fn Writer::write_bytes(self : Writer, bytes : Bytes) -> Unit raise SbeError {
  self.reserve(bytes.length())
  for byte in bytes {
    self.bytes.push(byte)
  }
}

///|
pub fn Writer::write_uint(
  self : Writer,
  value : UInt64,
  width : Int32,
) -> Unit raise SbeError {
  if width != 1 && width != 2 && width != 4 && width != 8 {
    raise InvalidMessage("integer width must be 1, 2, 4 or 8")
  }
  if width < 8 && value >= 1UL << (width * 8) {
    raise InvalidValue("integer", "unsigned value exceeds \{width} bytes")
  }
  self.reserve(width)
  for i in 0..<width {
    let shift = match self.order {
      LittleEndian => i * 8
      BigEndian => (width - i - 1) * 8
    }
    self.bytes.push(((value >> shift) & 255UL).to_byte())
  }
}

///|
pub fn Writer::write_int(
  self : Writer,
  value : Int64,
  width : Int32,
) -> Unit raise SbeError {
  if width != 1 && width != 2 && width != 4 && width != 8 {
    raise InvalidMessage("integer width must be 1, 2, 4 or 8")
  }
  if width < 8 {
    let bound = 1L << (width * 8 - 1)
    if value < 0L - bound || value >= bound {
      raise InvalidValue("integer", "signed value exceeds \{width} bytes")
    }
  }
  let mask = if width == 8 {
    0xffffffffffffffffUL
  } else {
    (1UL << (width * 8)) - 1UL
  }
  self.write_uint(value.reinterpret_as_uint64() & mask, width)
}

///|
pub fn Writer::write_float(
  self : Writer,
  value : Double,
  width : Int32,
) -> Unit raise SbeError {
  match width {
    4 =>
      self.write_uint(
        Float::from_double(value).reinterpret_as_uint().to_uint64(),
        4,
      )
    8 => self.write_uint(value.reinterpret_as_uint64(), 8)
    _ => raise InvalidMessage("float width must be 4 or 8")
  }
}
