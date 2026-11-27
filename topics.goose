namespace honkmqtt;

// MQTT strings use well-formed UTF-8 and cannot contain U+0000.
fn valid_utf8(text: const u8[:]) -> bool {
    var i = 0;
    while i < text.len {
        let a = text[i] as i64;
        if a == 0 { return false; }
        if a < 128 { i += 1; continue; }
        var count = 0;
        var value = 0;
        var minimum = 0;
        if a >= 194 && a <= 223 { count = 2; value = a - 192; minimum = 128; }
        else if a >= 224 && a <= 239 { count = 3; value = a - 224; minimum = 2048; }
        else if a >= 240 && a <= 244 { count = 4; value = a - 240; minimum = 65536; }
        else { return false; }
        if text.len - i < count { return false; }
        for j in 1..count {
            let b = text[i + j] as i64;
            if b < 128 || b > 191 { return false; }
            value = value * 64 + b - 128;
        }
        if value < minimum || value > 1114111 || (value >= 55296 && value <= 57343) { return false; }
        i += count;
    }
    return true;
}

// Topic names and filters are length-bounded MQTT UTF-8 strings.
fn valid_topic(topic: const u8[:]) -> bool {
    if topic.len == 0 || topic.len > 65535 || !valid_utf8(topic) { return false; }
    for c in topic { if c == 0 || c == '+' || c == '#' { return false; } }
    return true;
}

fn valid_filter(filter: const u8[:]) -> bool {
    if filter.len == 0 || filter.len > 65535 || !valid_utf8(filter) { return false; }
    for c, i in filter {
        if c == 0 { return false; }
        if c == '#' {
            if i != filter.len - 1 || (i > 0 && filter[i - 1] != '/') { return false; }
        }
        if c == '+' {
            if (i > 0 && filter[i - 1] != '/') || (i + 1 < filter.len && filter[i + 1] != '/') { return false; }
        }
    }
    return true;
}

// Returns false for invalid UTF-8, topic names, or wildcard syntax.
fn matches(filter: const u8[:], topic: const u8[:]) -> bool {
    if !valid_filter(filter) || !valid_topic(topic) { return false; }
    if topic[0] == '$' && (filter[0] == '+' || filter[0] == '#') { return false; }
    var f = 0;
    var t = 0;
    loop {
        if f < filter.len && filter[f] == '#' { return true; }
        if f < filter.len && filter[f] == '+' {
            f += 1;
            while t < topic.len && topic[t] != '/' { t += 1; }
        } else {
            while f < filter.len && filter[f] != '/' {
                if t >= topic.len || filter[f] != topic[t] { return false; }
                f += 1; t += 1;
            }
        }
        if f == filter.len && t == topic.len { return true; }
        if f < filter.len && filter[f] == '/' && f + 2 == filter.len && filter[f + 1] == '#' && t == topic.len { return true; }
        if f >= filter.len || t >= topic.len || filter[f] != '/' || topic[t] != '/' { return false; }
        f += 1; t += 1;
    }
}
