///|
fn generator_schema(message_name : String, fields : String) -> String {
  "<messageSchema id=\"1\"><types><composite name=\"messageHeader\"><type name=\"blockLength\" primitiveType=\"uint16\"/><type name=\"templateId\" primitiveType=\"uint16\"/><type name=\"schemaId\" primitiveType=\"uint16\"/><type name=\"version\" primitiveType=\"uint16\"/></composite></types><message name=\"\{message_name}\" id=\"1\">\{fields}</message></messageSchema>"
}

///|
test "generator rejects schema names that collide with language builtins" {
  try @moonsbe.generate_moonbit(generator_schema("String", "<field name=\"id\" id=\"1\" type=\"uint16\"/>")) catch {
    @moonsbe.Unsupported(_) => ()
    _ => fail("expected generated identifier failure")
  } noraise { _ => fail("generator emitted a conflicting builtin type") }
}

///|
test "normalized generated field names cannot silently collide" {
  let schema = generator_schema("Example", "<field name=\"some-value\" id=\"1\" type=\"uint16\"/><field name=\"some_value\" id=\"2\" type=\"uint16\"/>")
  try @moonsbe.generate_moonbit(schema) catch {
    @moonsbe.InvalidSchema(_, _) => ()
    _ => fail("expected field collision diagnostic")
  } noraise { _ => fail("colliding fields accepted") }
}
