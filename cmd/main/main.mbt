///|
suberror CliError { CliError(String) } derive(Debug)

///|
fn usage() -> String {
  (
    #|moonsbe: standard SBE binary messages and MoonBit code generation
    #|
    #|  schema SCHEMA.xml
    #|  encode SCHEMA.xml TEMPLATE_ID MESSAGE.json OUTPUT.bin
    #|  decode SCHEMA.xml INPUT.bin [OUTPUT.json]
    #|  hex INPUT.bin
    #|
    #|Run with: moon run cmd/main --target js -- COMMAND ...
    #|Integers in JSON may be exact decimal strings. Binary fields use hex.
    #|Input .bin must contain exactly one complete SBE message.
  )
}

///|
fn load_schema(path : String) -> @sbe.Schema raise {
  let source = @fs.read_file_to_string(path)
  let normalized = path.replace_all(old="\\", new="/")
  let parts = normalized.split("/").map((part) => part.to_owned()).to_array()
  ignore(parts.pop())
  let directory = parts.join("/")
  let includes : Map[String, String] = Map([])
  let queue = @sbe.schema_include_names(source)
  let mut head = 0
  while head < queue.length() {
    let name = queue[head]
    head += 1
    if includes.contains(name) { continue }
    if includes.length() >= 16 || name.contains(":") || name.contains("..") ||
        name.has_prefix("/") || name.has_prefix("\\") || name.contains("\\") {
      raise CliError("CLI includes require bounded relative paths within the schema directory")
    }
    let resource_path = if directory.is_empty() { name } else { "\{directory}/\{name}" }
    let text = @fs.read_file_to_string(resource_path)
    includes[name] = text
    for nested in @sbe.schema_include_names(text) { queue.push(nested) }
  }
  @sbe.parse_schema(source, includes~)
}

///|
fn schema_json(schema : @sbe.Schema) -> Json {
  let messages = schema.messages.map((message) => Json::object({
    "name": Json::string(message.name),
    "templateId": Json::number(message.id.to_double()),
    "blockLength": Json::number(message.block.block_length.to_double()),
    "fixedFields": Json::number(message.block.fields.length().to_double()),
    "groups": Json::number(message.block.groups.length().to_double()),
    "variableData": Json::number(message.block.data.length().to_double()),
  }))
  Json::object({
    "schemaId": Json::number(schema.id.to_double()),
    "version": Json::number(schema.version.to_double()),
    "package": Json::string(schema.package_name),
    "byteOrder": Json::string(match schema.byte_order { LittleEndian => "littleEndian"; BigEndian => "bigEndian" }),
    "messages": Json::array(messages),
  })
}

///|
fn template_id(source : String) -> Int raise {
  let id = @string.parse_int(source)
  if id < 0 || id > 65534 { raise CliError("templateId must be 0..65534") }
  id
}

///|
fn run(args : Array[String]) -> Unit raise {
  match args {
    [] | ["help"] | ["--help"] => println(usage())
    ["schema", path] => println(schema_json(load_schema(path)).stringify(indent=2))
    ["encode", schema_path, id, input_path, output_path] => {
      let schema = load_schema(schema_path)
      let template = template_id(id)
      let value = @sbe.value_from_json(schema, template, @fs.read_file_to_string(input_path))
      let bytes = @sbe.encode(schema, template, value)
      @fs.write_bytes_to_file(output_path, bytes)
      println("Encoded \{bytes.length()} bytes")
    }
    ["decode", schema_path, input_path] => {
      let result = @sbe.decode(load_schema(schema_path), @fs.read_file_to_bytes(input_path))
      println(result.value.to_json().stringify(indent=2))
    }
    ["decode", schema_path, input_path, output_path] => {
      let result = @sbe.decode(load_schema(schema_path), @fs.read_file_to_bytes(input_path))
      @fs.write_string_to_file(output_path, result.value.to_json().stringify(indent=2))
      println("Decoded template \{result.header.template_id}")
    }
    ["hex", input_path] => println(@sbe.to_hex(@fs.read_file_to_bytes(input_path)))
    _ => { println(usage()); @sys.exit(2) }
  }
}

///|
fn main {
  let raw = @env.args()
  let args = if raw.length() >= 2 { raw[2:].to_owned() } else { [] }
  try run(args) catch {
    error => { println("ERROR: \{Repr(error)}"); @sys.exit(2) }
  }
}
