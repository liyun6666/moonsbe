///|
test "typed version one reads extended framing and present composite" {
  let bytes = @sbe.from_hex(
    "000c000000000001000701010101020304000004e2fe08007b02010001002a0178026f6b",
  )
  let view = @wire.Extended::view(bytes)
  assert_eq(view.version(), 1)
  assert_eq(view.f_sequence(), 0x01020304UL)
  assert_eq(view.f_status(), Some(123UL))
  let message = @wire.Extended::decode(bytes)
  guard message.f_price is Some(price) else { fail("missing price") }
  assert_eq(price.f_mantissa, Some(1250L))
  assert_eq(price.f_exponent, -2L)
  assert_eq(price.f_quality, Some(8UL))
  assert_eq(message.f_rows[0].f_label, "x")
  assert_eq(message.f_note, "ok")
  assert_eq(message.encode(), bytes)
}

///|
test "typed version zero retains offsets and skips future composite members" {
  let bytes = @sbe.from_hex(
    "0009000000000001000700010101020304000004e2fe02010001002a0178026f6b",
  )
  let view = @wire.Extended::view(bytes)
  assert_eq(view.version(), 0)
  assert_eq(view.f_sequence(), 0x01020304UL)
  assert_eq(view.f_status(), None)
  let message = @wire.Extended::decode(bytes)
  guard message.f_price is Some(price) else { fail("missing price") }
  assert_eq(price.f_quality, None)
  assert_eq(message.f_status, None)
  assert_eq(message.f_rows[0].f_code, 42UL)
  assert_eq(message.f_note, "ok")
  assert_eq(message.encode(version=0), bytes)
}

///|
test "optional composite and optional scalar honor their own null markers" {
  // Nonzero bytes after the composite's null marker are ignored on decode.
  let bytes = @sbe.from_hex(
    "000c000000000001000701010101020304ffffff9dfe08ffff02010001002a0178026f6b",
  )
  let view = @wire.Extended::view(bytes)
  assert_eq(view.f_status(), None)
  let message = @wire.Extended::decode(bytes)
  assert_true(message.f_price is None)
  assert_eq(message.f_status, None)
  assert_eq(message.f_rows[0].f_code, 42UL)
  assert_eq(message.f_note, "ok")
  assert_eq(
    @sbe.to_hex(message.encode()),
    "000c000000000001000701010101020304ffffff9d0000ffff02010001002a0178026f6b",
  )
}

///|
test "frame checks reject incorrect extension counts and dimension bounds" {
  for
    bad in [
      "000c000000000001000701000101020304000004e2fe08007b02010001002a0178026f6b",
      "000c000000000001000701010101020304000004e2fe08007b02010000002a0178026f6b",
      "000c000000000001000701010101020304000004e2fe08007b02000001002a0178026f6b",
    ] {
    try @wire.Extended::decode(@sbe.from_hex(bad)) catch {
      @sbe.InvalidMessage(_) => ()
      _ => fail("expected an invalid framing diagnostic")
    } noraise {
      _ => fail("invalid framing was accepted")
    }
  }
}

///|
test "fixed numeric getter cannot read past the acting block into group bytes" {
  let bytes = @sbe.from_hex(
    "000a000000000001000701010101020304000004e2fe08007b02010001002a0178026f6b",
  )
  let view = @wire.Extended::view(bytes)
  assert_eq(view.f_sequence(), 0x01020304UL)
  try view.f_status() catch {
    @sbe.Truncated(_, _, _) => ()
    _ => fail("expected a fixed block boundary error")
  } noraise {
    _ => fail("getter read past acting block length")
  }
}
