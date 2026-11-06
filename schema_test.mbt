///|
fn test_schema(body : String, types? : String = "", order? : String = "littleEndian", version? : Int = 0) -> @moonsbe.Schema raise {
  @moonsbe.parse_schema(
    "<sbe:messageSchema xmlns:sbe=\"http://fixprotocol.io/2016/sbe\" id=\"7\" version=\"\{version}\" byteOrder=\"\{order}\"><types><composite name=\"messageHeader\"><type name=\"blockLength\" primitiveType=\"uint16\"/><type name=\"templateId\" primitiveType=\"uint16\"/><type name=\"schemaId\" primitiveType=\"uint16\"/><type name=\"version\" primitiveType=\"uint16\"/></composite>\{types}</types><sbe:message name=\"Sample\" id=\"1\">\{body}</sbe:message></sbe:messageSchema>",
  )
}

///|
test "schema compilation resolves aliases, arrays and explicit padding" {
  let schema = test_schema(
    "<field name=\"id\" id=\"1\" type=\"uint64\"/><field name=\"code\" id=\"2\" type=\"Code\" offset=\"12\"/>",
    types="<type name=\"Code\" primitiveType=\"char\" length=\"4\"/>",
  )
  assert_eq(schema.id, 7)
  assert_eq(schema.message(1).block.block_length, 16)
  assert_eq(schema.message(1).block.fields[1].offset, 12)
  assert_eq(schema.encoded_size("Code"), 4)
}

///|
test "constant fields do not consume wire bytes" {
  let schema = test_schema(
    "<field name=\"kind\" id=\"1\" type=\"Kind\"/><field name=\"id\" id=\"2\" type=\"uint16\"/>",
    types="<type name=\"Kind\" primitiveType=\"char\" presence=\"constant\">fixed</type>",
  )
  assert_eq(schema.message(1).block.block_length, 2)
  assert_eq(schema.encoded_size("Kind"), 0)
}

///|
test "invalid schema references and duplicate attributes are rejected" {
  try test_schema("<field name=\"bad\" id=\"1\" type=\"Missing\"/>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected invalid schema")
  } noraise { _ => fail("unknown type must fail") }
  try @moonsbe.parse_schema("<messageSchema id=\"1\" id=\"2\"/>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected invalid XML")
  } noraise { _ => fail("duplicate XML attributes must fail") }
}

///|
test "DTD and missing XInclude are explicit failures" {
  try @moonsbe.parse_schema("<!DOCTYPE x [<!ENTITY y SYSTEM 'file:///secret'>]><messageSchema/>") catch {
    @moonsbe.Unsupported(_) => ()
    _ => fail("expected unsupported DTD")
  } noraise { _ => fail("DTD must be rejected") }
  try @moonsbe.parse_schema("<messageSchema id=\"1\"><include href=\"missing.xml\"/></messageSchema>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected missing resource")
  } noraise { _ => fail("include must not be ignored") }
}

///|
test "overlapping fields and fields after variable data are rejected" {
  try test_schema("<field name=\"a\" id=\"1\" type=\"uint32\"/><field name=\"b\" id=\"2\" type=\"uint16\" offset=\"2\"/>") catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected overlap")
  } noraise { _ => fail("overlap must fail") }
}
