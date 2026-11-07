///|
fn has_difference(report : @moonsbe.EvolutionReport, code : String) -> Bool {
  for issue in report.differences {
    if issue.code == code {
      return true
    }
  }
  false
}

///|
test "fixed append with correct sinceVersion is compatible in both directions" {
  let old = test_schema("<field name=\"id\" id=\"1\" type=\"uint16\"/>")
  let newer = test_schema(
    "<field name=\"id\" id=\"1\" type=\"uint16\"/><field name=\"extra\" id=\"2\" type=\"uint32\" sinceVersion=\"1\"/>",
    version=1,
  )
  let report = @moonsbe.compare_schemas(old, newer)
  assert_true(report.old_reads_new)
  assert_true(report.new_reads_old)
  assert_eq(report.differences.length(), 0)
}

///|
test "changing a fixed encoding is flagged even when field IDs are stable" {
  let old = test_schema("<field name=\"id\" id=\"1\" type=\"uint16\"/>")
  let newer = test_schema(
    "<field name=\"id\" id=\"1\" type=\"uint32\"/>",
    version=1,
  )
  let report = @moonsbe.compare_schemas(old, newer)
  assert_false(report.old_reads_new)
  assert_false(report.new_reads_old)
  assert_true(has_difference(report, "encoding-changed"))
}

///|
test "new enum values are rejected by old strict decoders" {
  let field = "<field name=\"mode\" id=\"1\" type=\"Mode\"/>"
  let a = "<enum name=\"Mode\" encodingType=\"uint8\"><validValue name=\"A\">1</validValue></enum>"
  let b = "<enum name=\"Mode\" encodingType=\"uint8\"><validValue name=\"A\">1</validValue><validValue name=\"B\" sinceVersion=\"1\">2</validValue></enum>"
  let report = @moonsbe.compare_schemas(
    test_schema(field, types=a),
    test_schema(field, types=b, version=1),
  )
  assert_false(report.old_reads_new)
  assert_true(report.new_reads_old)
  assert_true(has_difference(report, "enum-case-added"))
}

///|
test "new variable data is explicitly outside old strict decoder compatibility" {
  let field = "<field name=\"id\" id=\"1\" type=\"uint16\"/>"
  let old = test_schema(field, types=group_types())
  let newer = test_schema(
    field +
    "<data name=\"label\" id=\"2\" type=\"varText\" sinceVersion=\"1\"/>",
    types=group_types(),
    version=1,
  )
  let report = @moonsbe.compare_schemas(old, newer)
  assert_false(report.old_reads_new)
  assert_true(report.new_reads_old)
  assert_true(has_difference(report, "data-added"))
}

///|
test "byte order changes and unversioned additions cannot masquerade as safe evolution" {
  let field = "<field name=\"id\" id=\"1\" type=\"uint16\"/>"
  let old = test_schema(field)
  let changed = test_schema(
    field + "<field name=\"extra\" id=\"2\" type=\"uint16\"/>",
    version=1,
    order="bigEndian",
  )
  let report = @moonsbe.compare_schemas(old, changed)
  assert_true(has_difference(report, "byte-order-changed"))
  assert_true(has_difference(report, "unsafe-field-addition"))
  assert_false(report.old_reads_new)
  assert_false(report.new_reads_old)
}
