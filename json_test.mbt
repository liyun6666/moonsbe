///|
test "JSON integer literals retain uint64 precision without Double coercion" {
  let schema = test_schema("<field name=\"id\" id=\"1\" type=\"uint64\"/>")
  let value = @moonsbe.value_from_json(
    schema, 1, "{\"id\":18446744073709551614}",
  )
  assert_eq(value.field("id").as_unsigned(), 18446744073709551614UL)
  let bytes = @moonsbe.encode(schema, 1, value)
  assert_eq(
    @moonsbe.decode(schema, bytes).value.to_json().stringify(),
    "{\"id\":\"18446744073709551614\"}",
  )
}

///|
test "JSON duplicate keys and fractions for integer fields are rejected" {
  let schema = test_schema("<field name=\"id\" id=\"1\" type=\"uint16\"/>")
  for
    source in [
      "{\"id\":1,\"id\":2}", "{\"id\":1.5}", "{\"id\":1,\"unknown\":2}",
    ] {
    try @moonsbe.value_from_json(schema, 1, source) catch {
      @moonsbe.InvalidValue(_, _) => ()
      _ => fail("expected invalid JSON message")
    } noraise {
      _ => fail("ambiguous input accepted")
    }
  }
}

///|
test "hex conversion is lossless and rejects malformed input" {
  let bytes = b"\x00\x01\xab\xff"
  assert_eq(@moonsbe.to_hex(bytes), "0001abff")
  assert_eq(@moonsbe.from_hex("0001ABff"), bytes)
  try @moonsbe.from_hex("0g") catch {
    @moonsbe.InvalidValue(_, _) => ()
    _ => fail("expected malformed hex")
  } noraise {
    _ => fail("invalid hex accepted")
  }
}
