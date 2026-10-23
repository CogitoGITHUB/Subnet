// One job: the Rust side of the wire shape — read one request, write one
// response. The shape is the one in protocol.rkt: a request is an object
// with "op" and "args"; a response is an object with "ok" and "data". The
// values are strings, so the reader stays small and never guesses: a line
// it cannot read is refused, not guessed at.

#[derive(Clone)]
/// Value is one value read off the wire: a text, or an object of members.
enum Value {
    Text(String),
    Object(Vec<(String, Value)>),
}

/// Request is one request read off the wire: the operation, and its
/// arguments, each argument a name and a value.
pub struct Request {
    pub op: String,
    pub args: Vec<(String, String)>,
}

/// arg answers one argument of the request, and answers the empty string
/// when the request does not carry it.
pub fn arg(request: &Request, name: &str) -> String {
    for (key, value) in &request.args {
        if key == name {
            return value.clone();
        }
    }
    String::new()
}

/// read_request reads one request from one line of JSON, and answers
/// nothing when the line is not a request.
pub fn read_request(line: &str) -> Option<Request> {
    let members = parse_object(line)?;
    let op = text_of(&members, "op")?;
    let arguments = object_of(&members, "args")?;
    let mut args: Vec<(String, String)> = Vec::new();
    for (key, value) in &arguments {
        match value {
            Value::Text(text) => args.push((key.clone(), text.clone())),
            _ => return None,
        }
    }
    Some(Request { op, args })
}

/// write_response writes one response as one line of JSON: the flag first,
/// then the data, so a reader always knows what it holds.
pub fn write_response(ok: bool, data: &[(String, String)]) -> String {
    let mut out = String::from("{\"ok\":");
    out.push_str(if ok { "true" } else { "false" });
    out.push_str(",\"data\":{");
    let mut first = true;
    for (key, value) in data {
        if !first {
            out.push(',');
        }
        first = false;
        out.push('"');
        out.push_str(&escape(key));
        out.push_str("\":\"");
        out.push_str(&escape(value));
        out.push('"');
    }
    out.push_str("}}");
    out
}

/// text_of answers the text of one member of an object, and answers
/// nothing when the object does not carry it.
fn text_of(members: &[(String, Value)], name: &str) -> Option<String> {
    for (key, value) in members {
        if key == name {
            if let Value::Text(text) = value {
                return Some(text.clone());
            }
            return None;
        }
    }
    None
}

/// object_of answers the members of one object inside an object, and
/// answers nothing when the object does not carry it.
fn object_of(members: &[(String, Value)], name: &str) -> Option<Vec<(String, Value)>> {
    for (key, value) in members {
        if key == name {
            if let Value::Object(inner) = value {
                return Some(inner.clone());
            }
            return None;
        }
    }
    None
}

/// parse_object reads one JSON object from a line, and answers nothing
/// when the line does not hold one.
fn parse_object(line: &str) -> Option<Vec<(String, Value)>> {
    let mut at = 0usize;
    match parse_value(line, &mut at)? {
        Value::Object(members) => Some(members),
        _ => None,
    }
}

/// parse_value reads one value at the place the cursor stands, and moves
/// the cursor past it.
fn parse_value(text: &str, at: &mut usize) -> Option<Value> {
    skip_spaces(text, at);
    let byte = *text.as_bytes().get(*at)?;
    if byte == b'"' {
        return Some(Value::Text(parse_string(text, at)?));
    }
    if byte == b'{' {
        *at += 1;
        let mut members: Vec<(String, Value)> = Vec::new();
        loop {
            skip_spaces(text, at);
            let byte = *text.as_bytes().get(*at)?;
            if byte == b'}' {
                *at += 1;
                return Some(Value::Object(members));
            }
            if byte == b',' {
                *at += 1;
                continue;
            }
            let key = parse_string(text, at)?;
            skip_spaces(text, at);
            if *text.as_bytes().get(*at)? != b':' {
                return None;
            }
            *at += 1;
            let value = parse_value(text, at)?;
            members.push((key, value));
        }
    }
    None
}

/// parse_string reads one JSON string at the place the cursor stands, and
/// moves the cursor past it.
fn parse_string(text: &str, at: &mut usize) -> Option<String> {
    let bytes = text.as_bytes();
    if bytes.get(*at) != Some(&b'"') {
        return None;
    }
    *at += 1;
    let mut out = String::new();
    while *at < bytes.len() {
        let byte = bytes[*at];
        if byte == b'"' {
            *at += 1;
            return Some(out);
        }
        if byte == b'\\' {
            *at += 1;
            let escaped = *bytes.get(*at)?;
            *at += 1;
            match escaped {
                b'n' => out.push('\n'),
                b't' => out.push('\t'),
                b'r' => out.push('\r'),
                b'"' => out.push('"'),
                b'\\' => out.push('\\'),
                b'/' => out.push('/'),
                other => {
                    out.push('\\');
                    out.push(other as char);
                }
            }
            continue;
        }
        let rest = &text[*at..];
        let character = rest.chars().next()?;
        out.push(character);
        *at += character.len_utf8();
    }
    None
}

/// skip_spaces moves the cursor past the spaces.
fn skip_spaces(text: &str, at: &mut usize) {
    while let Some(byte) = text.as_bytes().get(*at) {
        if *byte == b' ' || *byte == b'\n' || *byte == b'\t' || *byte == b'\r' {
            *at += 1;
        } else {
            return;
        }
    }
}

/// escape writes one text so it survives the round trip as a JSON string.
fn escape(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            _ => out.push(c),
        }
    }
    out
}
