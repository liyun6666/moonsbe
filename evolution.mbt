///|
pub(all) struct SchemaDifference {
  direction : String
  code : String
  path : String
  detail : String
} derive(Debug, ToJson)

///|
/// Conservative compatibility checks for this runtime's strict decoding
/// profile. An empty report is not a proof about arbitrary producer values.
pub(all) struct EvolutionReport {
  old_version : Int32
  new_version : Int32
  old_reads_new : Bool
  new_reads_old : Bool
  differences : Array[SchemaDifference]
} derive(Debug, ToJson)

///|
fn difference(
  issues : Array[SchemaDifference],
  direction : String,
  code : String,
  path : String,
  detail : String,
) -> Unit {
  issues.push({ direction, code, path, detail, })
}

///|
fn find_field(block : BlockDef, id : Int32) -> FieldDef? {
  for field in block.fields {
    if field.id == id {
      return Some(field)
    }
  }
  None
}

///|
fn find_group(block : BlockDef, id : Int32) -> GroupDef? {
  for group in block.groups {
    if group.id == id {
      return Some(group)
    }
  }
  None
}

///|
fn find_data(block : BlockDef, id : Int32) -> DataDef? {
  for data in block.data {
    if data.id == id {
      return Some(data)
    }
  }
  None
}

///|
fn compare_type(
  old : Schema,
  newer : Schema,
  old_name : String,
  new_name : String,
  path : String,
  issues : Array[SchemaDifference],
  depth : Int32,
) -> Unit raise SbeError {
  if depth > 64 {
    raise LimitExceeded("evolution comparison depth exceeds 64")
  }
  match (old.type_def(old_name), newer.type_def(new_name)) {
    (Encoded(a), Encoded(b)) => {
      if a.primitive != b.primitive ||
        a.length != b.length ||
        a.presence != b.presence ||
        a.constant != b.constant ||
        a.character_encoding != b.character_encoding {
        difference(
          issues, "both", "encoding-changed", path, "primitive, array, constant, presence or character encoding changed",
        )
      }
      if a.min_value != b.min_value ||
        a.max_value != b.max_value ||
        a.null_value != b.null_value {
        difference(
          issues, "both", "value-domain-changed", path, "minValue, maxValue or nullValue changed; producer values require review",
        )
      }
    }
    (Enumeration(ap, ac, presence_a), Enumeration(bp, bc, presence_b)) => {
      if ap != bp || presence_a != presence_b {
        difference(
          issues, "both", "enum-encoding-changed", path, "enum primitive or presence changed",
        )
      }
      compare_cases(ac, bc, path, issues, "enum")
    }
    (BitSet(ap, ac), BitSet(bp, bc)) => {
      if ap != bp {
        difference(
          issues, "both", "set-encoding-changed", path, "set primitive changed",
        )
      }
      compare_cases(ac, bc, path, issues, "set")
    }
    (Composite(a, a_length), Composite(b, b_length)) => {
      if a_length != b_length || a.length() != b.length() {
        difference(
          issues, "both", "composite-layout-changed", path, "composite encoded length or member count changed",
        )
      }
      let length = if a.length() < b.length() { a.length() } else { b.length() }
      for index in 0..<length {
        if a[index].name != b[index].name ||
          a[index].offset != b[index].offset ||
          a[index].since_version != b[index].since_version {
          difference(
            issues, "both", "composite-member-changed", path, "composite member order, name, offset or version changed",
          )
        }
        compare_type(
          old,
          newer,
          a[index].type_name,
          b[index].type_name,
          "\{path}.\{a[index].name}",
          issues,
          depth + 1,
        )
      }
    }
    _ =>
      difference(
        issues, "both", "type-kind-changed", path, "encoding kind changed between primitive, enum, set and composite",
      )
  }
}

///|
fn compare_cases(
  old_cases : Array[EnumCase],
  new_cases : Array[EnumCase],
  path : String,
  issues : Array[SchemaDifference],
  kind : String,
) -> Unit {
  for before in old_cases {
    let mut found = false
    for after in new_cases {
      if before.name == after.name {
        found = true
        if before.value != after.value ||
          before.since_version != after.since_version {
          difference(
            issues,
            "both",
            "\{kind}-case-changed",
            "\{path}.\{before.name}",
            "existing symbolic value or sinceVersion changed",
          )
        }
      }
    }
    if !found {
      difference(
        issues,
        "both",
        "\{kind}-case-removed",
        "\{path}.\{before.name}",
        "existing enum/set choice was removed",
      )
    }
  }
  for after in new_cases {
    let mut found = false
    for before in old_cases {
      if before.name == after.name {
        found = true
      }
    }
    if !found {
      difference(
        issues,
        "old-reads-new",
        "\{kind}-case-added",
        "\{path}.\{after.name}",
        "strict older decoders reject the new symbolic value or bit",
      )
    }
  }
}

///|
fn compare_block(
  old : Schema,
  newer : Schema,
  a : BlockDef,
  b : BlockDef,
  path : String,
  issues : Array[SchemaDifference],
  depth : Int32,
) -> Unit raise SbeError {
  if depth > 32 {
    raise LimitExceeded("evolution group depth exceeds 32")
  }
  if b.block_length < a.block_length {
    difference(
      issues, "old-reads-new", "block-shrank", path, "new fixed block is shorter than the old layout",
    )
  }
  for before in a.fields {
    let field_path = "\{path}.\{before.name}"
    match find_field(b, before.id) {
      None =>
        difference(
          issues, "both", "field-removed", field_path, "existing field ID no longer exists",
        )
      Some(after) => {
        if before.offset != after.offset ||
          before.presence != after.presence ||
          before.since_version != after.since_version ||
          before.value_ref != after.value_ref ||
          before.name != after.name {
          difference(
            issues, "both", "field-contract-changed", field_path, "offset, presence, version, constant reference or symbolic name changed",
          )
        }
        compare_type(
          old,
          newer,
          before.type_name,
          after.type_name,
          field_path,
          issues,
          0,
        )
      }
    }
  }
  for after in b.fields {
    if find_field(a, after.id) is None {
      if after.since_version <= old.version ||
        (after.presence != Constant && after.offset < a.block_length) {
        difference(
          issues,
          "both",
          "unsafe-field-addition",
          "\{path}.\{after.name}",
          "new fixed fields must be versioned and appended beyond the previous block",
        )
      }
    }
  }
  let old_group_order = a.groups.map(group => group.id)
  let shared_group_order = b.groups
    .filter(group => find_group(a, group.id) is Some(_))
    .map(group => group.id)
  if old_group_order != shared_group_order {
    difference(
      issues, "both", "group-order-changed", path, "existing repeating group order changed or a group was removed",
    )
  }
  for before in a.groups {
    match find_group(b, before.id) {
      None =>
        difference(
          issues,
          "both",
          "group-removed",
          "\{path}.\{before.name}",
          "old repeating group no longer exists",
        )
      Some(after) => {
        if before.name != after.name ||
          before.since_version != after.since_version ||
          before.dimension != after.dimension {
          difference(
            issues,
            "both",
            "group-dimensions-changed",
            "\{path}.\{before.name}",
            "group identity, version or count encoding changed",
          )
        }
        compare_block(
          old,
          newer,
          before.block,
          after.block,
          "\{path}.\{before.name}[]",
          issues,
          depth + 1,
        )
      }
    }
  }
  for after in b.groups {
    if find_group(a, after.id) is None {
      let direction = if after.since_version > old.version {
        "old-reads-new"
      } else {
        "both"
      }
      difference(
        issues,
        direction,
        "group-added",
        "\{path}.\{after.name}",
        "older strict decoders cannot skip unknown variable group bodies",
      )
    }
  }
  let old_data_order = a.data.map(data => data.id)
  let shared_data_order = b.data
    .filter(data => find_data(a, data.id) is Some(_))
    .map(data => data.id)
  if old_data_order != shared_data_order {
    difference(
      issues, "both", "data-order-changed", path, "existing variable data order changed or data was removed",
    )
  }
  for before in a.data {
    match find_data(b, before.id) {
      None =>
        difference(
          issues,
          "both",
          "data-removed",
          "\{path}.\{before.name}",
          "old variable data no longer exists",
        )
      Some(after) =>
        if before.name != after.name ||
          before.since_version != after.since_version ||
          before.length_primitive != after.length_primitive ||
          before.max_length != after.max_length ||
          before.character_encoding != after.character_encoding {
          difference(
            issues,
            "both",
            "data-encoding-changed",
            "\{path}.\{before.name}",
            "variable data identity, length or text encoding changed",
          )
        }
    }
  }
  for after in b.data {
    if find_data(a, after.id) is None {
      let direction = if after.since_version > old.version {
        "old-reads-new"
      } else {
        "both"
      }
      difference(
        issues,
        direction,
        "data-added",
        "\{path}.\{after.name}",
        "older strict decoders reject unknown trailing variable data",
      )
    }
  }
}

///|
/// Compare two compiled schema versions. Results describe this library's
/// strict wire and symbolic-value profile, not general SBE conformance.
pub fn compare_schemas(
  old : Schema,
  newer : Schema,
) -> EvolutionReport raise SbeError {
  let issues : Array[SchemaDifference] = []
  if old.id != newer.id {
    difference(
      issues, "both", "schema-id-changed", "schema", "schemaId changed",
    )
  }
  if old.byte_order != newer.byte_order {
    difference(
      issues, "both", "byte-order-changed", "schema", "byteOrder changed",
    )
  }
  if old.header_layout != newer.header_layout {
    difference(
      issues, "both", "header-layout-changed", "schema", "message header layout or range changed",
    )
  }
  if newer.version < old.version {
    difference(
      issues, "both", "version-decreased", "schema", "new schema version is older",
    )
  }
  for before in old.messages {
    let mut found : MessageDef? = None
    for after in newer.messages {
      if before.id == after.id {
        found = Some(after)
      }
    }
    match found {
      None =>
        difference(
          issues,
          "both",
          "message-removed",
          before.name,
          "templateId was removed",
        )
      Some(after) => {
        if before.name != after.name ||
          before.since_version != after.since_version {
          difference(
            issues,
            "both",
            "message-identity-changed",
            before.name,
            "message name or introduction version changed",
          )
        }
        compare_block(
          old,
          newer,
          before.block,
          after.block,
          before.name,
          issues,
          0,
        )
      }
    }
  }
  for after in newer.messages {
    let mut found = false
    for before in old.messages {
      if before.id == after.id {
        found = true
      }
    }
    if !found {
      difference(
        issues,
        "old-reads-new",
        "message-added",
        after.name,
        "old decoders do not recognize the new templateId",
      )
    }
  }
  let mut old_reads_new = true
  let mut new_reads_old = true
  for issue in issues {
    if issue.direction == "both" || issue.direction == "old-reads-new" {
      old_reads_new = false
    }
    if issue.direction == "both" || issue.direction == "new-reads-old" {
      new_reads_old = false
    }
  }
  {
    old_version: old.version,
    new_version: newer.version,
    old_reads_new,
    new_reads_old,
    differences: issues,
  }
}
