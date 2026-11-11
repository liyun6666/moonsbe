///|
/// A read-only window over the original bytes. Used by generated fixed-field
/// accessors to avoid copying the block or materializing a message record.
pub struct FixedBlock {
  bytes : Bytes
  start : Int32
  length : Int32
  order : ByteOrder
}

///|
pub fn FixedBlock::new(
  bytes : Bytes,
  start : Int32,
  length : Int32,
  order : ByteOrder,
) -> FixedBlock raise SbeError {
  if start < 0 ||
    length < 0 ||
    start > bytes.length() ||
    length > bytes.length() - start {
    raise Truncated(start, length, bytes.length())
  }
  { bytes, start, length, order, }
}

///|
pub fn FixedBlock::uint_at(
  self : FixedBlock,
  offset : Int32,
  width : Int32,
) -> UInt64 raise SbeError {
  check_word_width(width)
  if offset < 0 || offset > self.length || width > self.length - offset {
    raise Truncated(offset, width, self.length)
  }
  unsigned_word(self.bytes, self.start + offset, width, self.order)
}

///|
pub fn FixedBlock::int_at(
  self : FixedBlock,
  offset : Int32,
  width : Int32,
) -> Int64 raise SbeError {
  sign_extend(self.uint_at(offset, width), width)
}

///|
pub fn FixedBlock::float_at(
  self : FixedBlock,
  offset : Int32,
  width : Int32,
) -> Double raise SbeError {
  match width {
    4 =>
      Float::reinterpret_from_uint(self.uint_at(offset, 4).to_uint()).to_double()
    8 => self.uint_at(offset, 8).reinterpret_as_double()
    _ => raise InvalidMessage("float width must be 4 or 8")
  }
}
