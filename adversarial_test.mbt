///|
test "encoding constraints are rejected while compiling the schema" {
  for types in [
    "<type name=\"Broken\" primitiveType=\"uint8\" minValue=\"10\" maxValue=\"2\"/>",
    "<type name=\"Broken\" primitiveType=\"uint8\" maxValue=\"1000\"/>",
    "<type name=\"Broken\" primitiveType=\"uint16\" presence=\"optional\" length=\"2\"/>",
    "<enum name=\"Broken\" encodingType=\"uint8\"><validValue name=\"Null\">255</validValue></enum>",
    "<enum name=\"Broken\" encodingType=\"uint8\"><validValue name=\"A\">1</validValue><validValue name=\"B\">01</validValue></enum>",
  ] {
    try test_schema("<field name=\"value\" id=\"1\" type=\"Broken\"/>", types~) catch {
      _ => ()
    } noraise { _ => fail("invalid schema constraint was accepted") }
  }
}

///|
test "type reference cycles and invalid valueRef are rejected" {
  let cycles = "<composite name=\"A\"><ref name=\"b\" type=\"B\"/></composite><composite name=\"B\"><ref name=\"a\" type=\"A\"/></composite>"
  try test_schema("<field name=\"a\" id=\"1\" type=\"A\"/>", types=cycles) catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected cyclic reference failure")
  } noraise { _ => fail("type cycle accepted") }
  try test_schema("<field name=\"a\" id=\"1\" type=\"uint8\" presence=\"constant\" valueRef=\"Unknown.Nope\"/>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected unknown valueRef failure")
  } noraise { _ => fail("unknown constant accepted") }
}

///|
test "malicious group dimensions cannot allocate beyond the shared budget" {
  let schema = test_schema("<group name=\"rows\" id=\"1\"><field name=\"id\" id=\"2\" type=\"uint8\"/></group>", types=group_types())
  let bytes = @moonsbe.from_hex("00000100070000000100ffff")
  try @moonsbe.decode(schema, bytes, max_entries=10) catch {
    @moonsbe.LimitExceeded(_) => ()
    _ => fail("entry budget should be checked before reading group bodies")
  } noraise { _ => fail("excess group count accepted") }
}

///|
test "unknown enum bytes and unsupported text encodings fail explicitly" {
  let types = "<enum name=\"Mode\" encodingType=\"char\"><validValue name=\"A\">A</validValue></enum>"
  let schema = test_schema("<field name=\"mode\" id=\"1\" type=\"Mode\"/>", types~)
  try @moonsbe.decode(schema, @moonsbe.from_hex("01000100070000005a")) catch {
    @moonsbe.InvalidMessage(_) => ()
    _ => fail("expected unknown enum")
  } noraise { _ => fail("unknown enum accepted") }
  try test_schema("<field name=\"text\" id=\"1\" type=\"Text\"/>", types="<type name=\"Text\" primitiveType=\"char\" characterEncoding=\"MadeUp\"/>") catch {
    @moonsbe.Unsupported(_) => ()
    _ => fail("expected unsupported character encoding")
  } noraise { _ => fail("unsupported encoding accepted") }
}

///|
test "unknown schema namespace and future declarations are rejected" {
  try @moonsbe.parse_schema("<sbe:messageSchema xmlns:sbe=\"https://invalid.example/sbe\" id=\"1\"/>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected namespace failure")
  } noraise { _ => fail("wrong SBE namespace accepted") }
  try test_schema("<field name=\"new\" id=\"1\" type=\"uint32\" sinceVersion=\"1\"/>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected future version failure")
  } noraise { _ => fail("future field in version zero schema accepted") }
}

///|
test "compiled newer schema can decode an old block and older schema skips appended fixed fields" {
  let old = test_schema("<field name=\"id\" id=\"1\" type=\"uint16\"/>")
  let newer = test_schema("<field name=\"id\" id=\"1\" type=\"uint16\"/><field name=\"new\" id=\"2\" type=\"uint32\" sinceVersion=\"1\"/>", version=1)
  let old_message = @moonsbe.encode(old, 1, @moonsbe.Record({ "id": @moonsbe.Unsigned(10UL) }))
  assert_true(@moonsbe.decode(newer, old_message).value.field("new") is @moonsbe.Absent)
  let new_message = @moonsbe.encode(newer, 1, @moonsbe.Record({ "id": @moonsbe.Unsigned(10UL), "new": @moonsbe.Unsigned(20UL) }))
  assert_eq(@moonsbe.decode(old, new_message).value.field("id").as_unsigned(), 10UL)
}

///|
test "non-ASCII fixed text, malformed UTF8, and forged block lengths are rejected" {
  let text_schema = test_schema("<field name=\"text\" id=\"1\" type=\"Text\"/>", types="<type name=\"Text\" primitiveType=\"char\" length=\"4\"/>")
  try @moonsbe.encode(text_schema, 1, @moonsbe.Record({ "text": @moonsbe.Text("月") })) catch {
    @moonsbe.InvalidValue(_, _) => ()
    _ => fail("expected ASCII failure")
  } noraise { _ => fail("non-ASCII text accepted") }
  let schema = test_schema("<data name=\"label\" id=\"1\" type=\"varText\"/>", types=group_types())
  try @moonsbe.decode(schema, @moonsbe.from_hex("000001000700000002c0af")) catch {
    @moonsbe.InvalidMessage(_) => ()
    _ => fail("expected malformed UTF8")
  } noraise { _ => fail("overlong UTF8 accepted") }
  let fixed = test_schema("<field name=\"id\" id=\"1\" type=\"uint32\"/>")
  try @moonsbe.decode(fixed, @moonsbe.from_hex("010001000700000001")) catch {
    @moonsbe.InvalidMessage(_) => ()
    _ => fail("expected invalid acting block length")
  } noraise { _ => fail("short blockLength accepted") }
}
