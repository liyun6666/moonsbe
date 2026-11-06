///|
/// The standard eight-byte SBE message header, without transport framing.
pub(all) struct MessageHeader {
  block_length : Int
  template_id : Int
  schema_id : Int
  version : Int
} derive(Eq, Debug)

///|
pub fn MessageHeader::write(self : MessageHeader, writer : Writer) -> Unit raise SbeError {
  for value in [self.block_length, self.template_id, self.schema_id, self.version] {
    if value < 0 || value > 65535 {
      raise InvalidValue("header", "header values must fit uint16")
    }
    writer.write_uint(value.to_uint64(), 2)
  }
}

///|
pub fn MessageHeader::read(reader : Reader) -> MessageHeader raise SbeError {
  {
    block_length: reader.read_uint(2).to_int(),
    template_id: reader.read_uint(2).to_int(),
    schema_id: reader.read_uint(2).to_int(),
    version: reader.read_uint(2).to_int(),
  }
}
