///|
test "fixed message matches an independent published-layout vector" {
  let schema = test_schema(
    "<field name=\"id\" id=\"1\" type=\"uint64\"/><field name=\"quantity\" id=\"2\" type=\"int32\"/>",
  )
  let value = @moonsbe.Record({
    "id": @moonsbe.Unsigned(0xfffffffffffffffeUL),
    "quantity": @moonsbe.Signed(-42L),
  })
  let bytes = @moonsbe.encode(schema, 1, value)
  assert_eq(@moonsbe.to_hex(bytes), "0c00010007000000feffffffffffffffd6ffffff")
  let decoded = @moonsbe.decode(schema, bytes)
  assert_eq(decoded.value.field("id").as_unsigned(), 0xfffffffffffffffeUL)
  assert_eq(decoded.value.field("quantity").as_signed(), -42L)
}

///|
test "big endian schema changes both header and payload order" {
  let schema = test_schema(
    "<field name=\"id\" id=\"1\" type=\"uint32\"/>",
    order="bigEndian",
  )
  let bytes = @moonsbe.encode(
    schema,
    1,
    @moonsbe.Record({ "id": @moonsbe.Unsigned(0x01020304UL) }),
  )
  assert_eq(@moonsbe.to_hex(bytes), "000400010007000001020304")
  assert_eq(
    @moonsbe.decode(schema, bytes).value.field("id").as_unsigned(),
    0x01020304UL,
  )
}

///|
test "optional scalar uses the SBE null sentinel and min max are enforced" {
  let schema = test_schema(
    "<field name=\"amount\" id=\"1\" type=\"Amount\"/>",
    types="<type name=\"Amount\" primitiveType=\"int16\" presence=\"optional\" minValue=\"0\" maxValue=\"100\"/>",
  )
  let bytes = @moonsbe.encode(
    schema,
    1,
    @moonsbe.Record({ "amount": @moonsbe.Absent }),
  )
  assert_eq(@moonsbe.to_hex(bytes), "02000100070000000080")
  assert_true(
    @moonsbe.decode(schema, bytes).value.field("amount") is @moonsbe.Absent,
  )
  try
    @moonsbe.encode(
      schema,
      1,
      @moonsbe.Record({ "amount": @moonsbe.Signed(101L) }),
    )
  catch {
    @moonsbe.InvalidValue(_, _) => ()
    _ => fail("expected range error")
  } noraise {
    _ => fail("custom maxValue must be enforced")
  }
}

///|
test "enum, bit set and constant valueRef retain symbolic names" {
  let types = "<enum name=\"Mode\" encodingType=\"char\"><validValue name=\"A\">A</validValue><validValue name=\"B\">B</validValue></enum><set name=\"Flags\" encodingType=\"uint8\"><choice name=\"fast\">1</choice><choice name=\"safe\">3</choice></set>"
  let schema = test_schema(
    "<field name=\"mode\" id=\"1\" type=\"Mode\"/><field name=\"fixed\" id=\"2\" type=\"Mode\" presence=\"constant\" valueRef=\"Mode.B\"/><field name=\"flags\" id=\"3\" type=\"Flags\"/>",
    types~,
  )
  let value = @moonsbe.Record({
    "mode": @moonsbe.Text("A"),
    "flags": @moonsbe.Sequence([@moonsbe.Text("fast"), @moonsbe.Text("safe")]),
  })
  let bytes = @moonsbe.encode(schema, 1, value)
  assert_eq(@moonsbe.to_hex(bytes), "0200010007000000410a")
  let decoded = @moonsbe.decode(schema, bytes).value
  assert_eq(decoded.field("mode").as_text(), "A")
  assert_eq(decoded.field("fixed").as_text(), "B")
  assert_eq(decoded.field("flags").as_sequence().length(), 2)
}

///|
fn group_types() -> String {
  "<composite name=\"groupSizeEncoding\"><type name=\"blockLength\" primitiveType=\"uint16\"/><type name=\"numInGroup\" primitiveType=\"uint16\"/></composite><composite name=\"varText\"><type name=\"length\" primitiveType=\"uint8\"/><type name=\"varData\" primitiveType=\"uint8\" length=\"0\" characterEncoding=\"UTF-8\"/></composite>"
}

///|
test "nested groups and UTF8 data use sequential SBE cursor layout" {
  let schema = test_schema(
    "<group name=\"rows\" id=\"1\"><field name=\"number\" id=\"2\" type=\"uint16\"/><group name=\"samples\" id=\"3\"><field name=\"reading\" id=\"4\" type=\"float\"/></group><data name=\"label\" id=\"5\" type=\"varText\"/></group>",
    types=group_types(),
  )
  let value = @moonsbe.Record({
    "rows": @moonsbe.Sequence([
      @moonsbe.Record({
        "number": @moonsbe.Unsigned(42UL),
        "samples": @moonsbe.Sequence([
          @moonsbe.Record({ "reading": @moonsbe.Floating(1.5) }),
        ]),
        "label": @moonsbe.Text("月"),
      }),
    ]),
  })
  let bytes = @moonsbe.encode(schema, 1, value)
  assert_eq(
    @moonsbe.to_hex(bytes),
    "0000010007000000020001002a00040001000000c03f03e69c88",
  )
  let decoded = @moonsbe.decode(schema, bytes).value.field("rows").as_sequence()[0]
  assert_eq(decoded.field("label").as_text(), "月")
  assert_eq(
    decoded.field("samples").as_sequence()[0].field("reading").as_float(),
    1.5,
  )
}

///|
test "acting version omits newly added fixed fields" {
  let schema = test_schema(
    "<field name=\"id\" id=\"1\" type=\"uint16\"/><field name=\"added\" id=\"2\" type=\"uint32\" sinceVersion=\"1\"/>",
    version=1,
  )
  let bytes = @moonsbe.encode(
    schema,
    1,
    @moonsbe.Record({ "id": @moonsbe.Unsigned(5UL) }),
    version=0,
  )
  assert_eq(bytes.length(), 10)
  let decoded = @moonsbe.decode(schema, bytes)
  assert_eq(decoded.header.version, 0)
  assert_true(decoded.value.field("added") is @moonsbe.Absent)
}

///|
test "every truncated prefix is rejected and extra bytes are not swallowed" {
  let schema = test_schema("<field name=\"id\" id=\"1\" type=\"uint64\"/>")
  let bytes = @moonsbe.encode(
    schema,
    1,
    @moonsbe.Record({ "id": @moonsbe.Unsigned(99UL) }),
  )
  for length in 0..<bytes.length() {
    try @moonsbe.decode(schema, bytes[:length].to_owned()) catch {
      _ => ()
    } noraise {
      _ => fail("truncated prefix accepted")
    }
  }
  try @moonsbe.decode(schema, bytes + b"\x00") catch {
    @moonsbe.InvalidMessage(_) => ()
    _ => fail("expected trailing bytes error")
  } noraise {
    _ => fail("trailing byte accepted")
  }
}

///|
test "unknown record fields and numeric null sentinels are rejected" {
  let schema = test_schema("<field name=\"id\" id=\"1\" type=\"uint8\"/>")
  for
    value in [
      @moonsbe.Record({ "id": @moonsbe.Unsigned(255UL) }),
      @moonsbe.Record({
        "id": @moonsbe.Unsigned(1UL),
        "typo": @moonsbe.Unsigned(2UL),
      }),
    ] {
    try @moonsbe.encode(schema, 1, value) catch {
      @moonsbe.InvalidValue(_, _) => ()
      _ => fail("expected invalid input")
    } noraise {
      _ => fail("invalid input accepted")
    }
  }
}
