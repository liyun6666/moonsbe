///|
test "unsigned words preserve all bits in both byte orders" {
  for order in [@moonsbe.LittleEndian, @moonsbe.BigEndian] {
    let writer = @moonsbe.Writer::new(order~)
    writer.write_uint(255UL, 1)
    writer.write_uint(65535UL, 2)
    writer.write_uint(0xffffffffUL, 4)
    writer.write_uint(0xffffffffffffffffUL, 8)
    let reader = @moonsbe.Reader::new(writer.to_bytes(), order~)
    assert_eq(reader.read_uint(1), 255UL)
    assert_eq(reader.read_uint(2), 65535UL)
    assert_eq(reader.read_uint(4), 0xffffffffUL)
    assert_eq(reader.read_uint(8), 0xffffffffffffffffUL)
    assert_eq(reader.remaining(), 0)
  }
}

///|
test "signed words sign extend and floats retain bit values" {
  let writer = @moonsbe.Writer::new()
  writer.write_int(-128L, 1)
  writer.write_int(-32768L, 2)
  writer.write_int(-2147483648L, 4)
  writer.write_int(-9223372036854775808L, 8)
  writer.write_float(35.5, 4)
  writer.write_float(-100.125, 8)
  let reader = @moonsbe.Reader::new(writer.to_bytes())
  assert_eq(reader.read_int(1), -128L)
  assert_eq(reader.read_int(2), -32768L)
  assert_eq(reader.read_int(4), -2147483648L)
  assert_eq(reader.read_int(8), -9223372036854775808L)
  assert_eq(reader.read_float(4), 35.5)
  assert_eq(reader.read_float(8), -100.125)
}

///|
test "truncated reads never advance the cursor" {
  let reader = @moonsbe.Reader::new(b"\x01")
  try reader.read_uint(2) catch {
    @moonsbe.Truncated(offset, length, available) => {
      assert_eq(offset, 0)
      assert_eq(length, 2)
      assert_eq(available, 1)
    }
    _ => fail("wrong error")
  } noraise { _ => fail("expected truncation") }
  assert_eq(reader.position(), 0)
}

///|
test "writer rejects overflow and its configured memory limit" {
  let writer = @moonsbe.Writer::new(limit=2)
  try writer.write_uint(256UL, 1) catch {
    @moonsbe.InvalidValue(_, _) => ()
    _ => fail("wrong overflow error")
  } noraise { _ => fail("overflow must be rejected") }
  writer.write_uint(42UL, 2)
  try writer.write_uint(1UL, 1) catch {
    @moonsbe.LimitExceeded(_) => ()
    _ => fail("wrong limit error")
  } noraise { _ => fail("writer limit must be enforced") }
}

///|
test "standard header has published little endian layout" {
  let writer = @moonsbe.Writer::new()
  let header : @moonsbe.MessageHeader = {
    block_length: 47, template_id: 1, schema_id: 1, version: 0,
  }
  header.write(writer)
  assert_eq(writer.to_bytes(), b"\x2f\x00\x01\x00\x01\x00\x00\x00")
  assert_eq(@moonsbe.MessageHeader::read(@moonsbe.Reader::new(writer.to_bytes())), header)
}
