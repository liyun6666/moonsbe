///|
test "read sequence by decoding the whole message" (bench : @bench.T) {
  let bytes = @sbe.from_hex(
    "000c000000000001000701010101020304000004e2fe08007b02010001002a0178026f6b",
  )
  let sample = @wire.Extended::decode(bytes)
  assert_eq(sample.f_sequence, 0x01020304UL)
  bench.bench(() => {
    let message = try! @wire.Extended::decode(bytes)
    bench.keep(message.f_sequence)
  })
}

///|
test "read sequence through the generated fixed view" (bench : @bench.T) {
  let bytes = @sbe.from_hex(
    "000c000000000001000701010101020304000004e2fe08007b02010001002a0178026f6b",
  )
  let sample = @wire.Extended::view(bytes)
  assert_eq(sample.f_sequence(), 0x01020304UL)
  bench.bench(() => {
    let view = try! @wire.Extended::view(bytes)
    bench.keep(try! view.f_sequence())
  })
}
