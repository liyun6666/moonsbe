///|
priv struct XmlNode {
  name : String
  attributes : Map[String, String]
  children : Array[XmlNode]
  text : String
  position : Int32
}

///|
priv struct XmlReader {
  chars : Array[Char]
  mut pos : Int32
  mut nodes : Int32
}

///|
fn XmlReader::peek(self : XmlReader) -> Char? {
  self.chars.get(self.pos)
}

///|
fn XmlReader::starts(self : XmlReader, text : String) -> Bool {
  let expected = text.iter().to_array()
  if expected.length() > self.chars.length() - self.pos {
    return false
  }
  for index, char in expected {
    if self.chars[self.pos + index] != char {
      return false
    }
  }
  true
}

///|
fn XmlReader::consume(self : XmlReader, text : String) -> Unit raise SbeError {
  if !self.starts(text) {
    raise InvalidSchema("expected \{text}", self.pos)
  }
  self.pos += text.char_length()
}

///|
fn XmlReader::space(self : XmlReader) -> Unit {
  while self.pos < self.chars.length() {
    match self.chars[self.pos] {
      ' ' | '\t' | '\r' | '\n' => self.pos += 1
      _ => break
    }
  }
}

///|
fn xml_name_start(char : Char) -> Bool {
  char.is_ascii_alphabetic() || char == '_' || char == ':'
}

///|
fn XmlReader::name(self : XmlReader) -> String raise SbeError {
  let result = StringBuilder()
  match self.peek() {
    Some(char) if xml_name_start(char) => ()
    _ => raise InvalidSchema("expected an XML name", self.pos)
  }
  while self.pos < self.chars.length() {
    let char = self.chars[self.pos]
    if !(xml_name_start(char) ||
      char.is_ascii_digit() ||
      char == '.' ||
      char == '-') {
      break
    }
    result.write_char(char)
    self.pos += 1
  }
  result.to_string()
}

///|
fn XmlReader::entity(self : XmlReader) -> Char raise SbeError {
  self.consume("&")
  let result = StringBuilder()
  while self.peek() != Some(';') {
    match self.peek() {
      None => raise InvalidSchema("unterminated XML entity", self.pos)
      Some(char) => {
        if result.to_string().length() > 12 {
          raise InvalidSchema("XML entity is too long", self.pos)
        }
        result.write_char(char)
        self.pos += 1
      }
    }
  }
  self.pos += 1
  let entity = result.to_string()
  match entity {
    "amp" => '&'
    "lt" => '<'
    "gt" => '>'
    "quot" => '"'
    "apos" => '\''
    _ => {
      let (digits, base) = if entity.has_prefix("#x") {
        (entity[2:].to_owned(), 16)
      } else if entity.has_prefix("#") {
        (entity[1:].to_owned(), 10)
      } else {
        raise InvalidSchema("unknown XML entity: \{entity}", self.pos)
      }
      let code = @string.parse_int(digits, base~) catch {
        _ => raise InvalidSchema("invalid XML character reference", self.pos)
      }
      if !(code == 9 ||
        code == 10 ||
        code == 13 ||
        (code >= 32 && code <= 0xd7ff) ||
        (code >= 0xe000 && code <= 0xfffd) ||
        (code >= 0x10000 && code <= 0x10ffff)) {
        raise InvalidSchema("invalid XML code point", self.pos)
      }
      match code.to_char() {
        Some(char) => char
        None => raise InvalidSchema("invalid Unicode scalar", self.pos)
      }
    }
  }
}

///|
fn XmlReader::attribute(self : XmlReader) -> String raise SbeError {
  let quote = match self.peek() {
    Some('\'') => '\''
    Some('"') => '"'
    _ => raise InvalidSchema("attribute value must be quoted", self.pos)
  }
  self.pos += 1
  let result = StringBuilder()
  while self.peek() != Some(quote) {
    match self.peek() {
      None => raise InvalidSchema("unclosed XML attribute", self.pos)
      Some('<') => raise InvalidSchema("unescaped '<' in attribute", self.pos)
      Some('&') => result.write_char(self.entity())
      Some(char) => {
        result.write_char(if char == '\n' || char == '\t' { ' ' } else { char })
        self.pos += 1
      }
    }
  }
  self.pos += 1
  result.to_string()
}

///|
fn XmlReader::comment(self : XmlReader) -> Unit raise SbeError {
  self.consume("<!--")
  while !self.starts("-->") {
    if self.peek() == None {
      raise InvalidSchema("unclosed XML comment", self.pos)
    }
    if self.starts("--") {
      raise InvalidSchema("double hyphen in XML comment", self.pos)
    }
    self.pos += 1
  }
  self.consume("-->")
}

///|
fn XmlReader::node(self : XmlReader, depth : Int32) -> XmlNode raise SbeError {
  if depth > 64 || self.nodes >= 20000 {
    raise LimitExceeded("XML schema exceeds depth or node limit")
  }
  self.nodes += 1
  let position = self.pos
  self.consume("<")
  let name = self.name()
  let attributes : Map[String, String] = Map([])
  for ;; {
    let before_space = self.pos
    self.space()
    if self.starts("/>") {
      self.consume("/>")
      return { name, attributes, children: [], text: "", position, }
    }
    if self.starts(">") {
      self.consume(">")
      break
    }
    if before_space == self.pos {
      raise InvalidSchema("attributes require separating whitespace", self.pos)
    }
    let key = self.name()
    if attributes.contains(key) {
      raise InvalidSchema("duplicate XML attribute: \{key}", self.pos)
    }
    self.space()
    self.consume("=")
    self.space()
    attributes[key] = self.attribute()
  }
  let text = StringBuilder()
  let children : Array[XmlNode] = []
  while !self.starts("</") {
    if self.peek() == None {
      raise InvalidSchema("unclosed XML element: \{name}", self.pos)
    }
    if self.starts("<!--") {
      self.comment()
    } else if self.starts("<![CDATA[") {
      self.consume("<![CDATA[")
      while !self.starts("]]>") {
        match self.peek() {
          None => raise InvalidSchema("unclosed CDATA", self.pos)
          Some(char) => {
            text.write_char(char)
            self.pos += 1
          }
        }
      }
      self.consume("]]>")
    } else if self.starts("<!") || self.starts("<?") {
      raise Unsupported(
        "DTD, entity declarations and nested processing instructions",
      )
    } else if self.peek() == Some('<') {
      children.push(self.node(depth + 1))
    } else if self.peek() == Some('&') {
      text.write_char(self.entity())
    } else {
      text.write_char(self.chars[self.pos])
      self.pos += 1
    }
  }
  self.consume("</")
  let closing = self.name()
  if closing != name {
    raise InvalidSchema("mismatched end tag for \{name}", self.pos)
  }
  self.space()
  self.consume(">")
  { name, attributes, children, text: text.to_string(), position, }
}

///|
fn parse_xml(text : String) -> XmlNode raise SbeError {
  if text.length() > 2000000 {
    raise LimitExceeded("schema XML exceeds 2 million code units")
  }
  let normalized = text
    .replace_all(old="\r\n", new="\n")
    .replace_all(old="\r", new="\n")
  let reader = XmlReader::{
    chars: normalized.iter().to_array(),
    pos: 0,
    nodes: 0,
  }
  if reader.peek() == Some('\u{feff}') {
    reader.pos += 1
  }
  reader.space()
  if reader.starts("<?xml ") {
    reader.consume("<?xml ")
    while !reader.starts("?>") {
      if reader.peek() == None {
        raise InvalidSchema("unclosed XML declaration", reader.pos)
      }
      reader.pos += 1
    }
    reader.consume("?>")
  }
  reader.space()
  while reader.starts("<!--") {
    reader.comment()
    reader.space()
  }
  if reader.starts("<!") {
    raise Unsupported("DTD and external entities")
  }
  let root = reader.node(0)
  reader.space()
  while reader.starts("<!--") {
    reader.comment()
    reader.space()
  }
  if reader.peek() != None {
    raise InvalidSchema("content after root element", reader.pos)
  }
  root
}

///|
fn XmlNode::local_name(self : XmlNode) -> String {
  let parts = self.name.split(":").to_array()
  parts[parts.length() - 1].to_owned()
}

///|
fn XmlNode::required(self : XmlNode, key : String) -> String raise SbeError {
  match self.attributes.get(key) {
    Some(value) if !value.is_empty() => value
    _ =>
      raise InvalidSchema(
        "\{self.name} requires attribute \{key}",
        self.position,
      )
  }
}

///|
fn XmlNode::integer(
  self : XmlNode,
  key : String,
  default~ : Int32,
) -> Int32 raise SbeError {
  match self.attributes.get(key) {
    None => default
    Some(value) => {
      let parsed = @string.parse_int(value) catch {
        _ =>
          raise InvalidSchema(
            "\{key} must be a nonnegative integer",
            self.position,
          )
      }
      if parsed < 0 || parsed > 1048576 {
        raise InvalidSchema("\{key} exceeds supported range", self.position)
      }
      parsed
    }
  }
}
