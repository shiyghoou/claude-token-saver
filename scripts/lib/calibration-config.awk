# token-saver.json全体を検証し、root直下calibrationの正整数を1つ読む。
# 対象値を見つけても早期終了せず、不正な末尾や構文があれば何も出力しない。

BEGIN {
  text = ""
  candidate_found = 0
}

{
  text = text $0 "\n"
}

function skip_ws(    c) {
  while (pos <= length(text)) {
    c = substr(text, pos, 1)
    if (c == " " || c == "\t" || c == "\r" || c == "\n") pos++
    else return
  }
}

function take_string(    c, escaped, out) {
  if (substr(text, pos, 1) != "\"") return 0
  pos++
  out = ""
  while (pos <= length(text)) {
    c = substr(text, pos, 1)
    pos++
    if (c == "\"") {
      string_value = out
      return 1
    }
    if (c != "\\") {
      if (c ~ /[[:cntrl:]]/) return 0
      out = out c
      continue
    }
    if (pos > length(text)) return 0
    escaped = substr(text, pos, 1)
    pos++
    if (escaped == "u") {
      if (pos + 3 > length(text) ||
          substr(text, pos, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return 0
      out = out "\\u" substr(text, pos, 4)
      pos += 4
    } else if (escaped == "\"" || escaped == "\\" || escaped == "/") {
      out = out escaped
    } else if (escaped == "b" || escaped == "f" || escaped == "n" ||
               escaped == "r" || escaped == "t") {
      out = out "\\" escaped
    } else {
      return 0
    }
  }
  return 0
}

function take_number(    start, c) {
  start = pos
  c = substr(text, pos, 1)
  if (c == "-") pos++
  if (substr(text, pos, 1) == "0") {
    pos++
  } else if (substr(text, pos, 1) ~ /^[1-9]$/) {
    while (substr(text, pos, 1) ~ /^[0-9]$/) pos++
  } else {
    pos = start
    return 0
  }
  if (substr(text, pos, 1) == ".") {
    pos++
    if (substr(text, pos, 1) !~ /^[0-9]$/) { pos = start; return 0 }
    while (substr(text, pos, 1) ~ /^[0-9]$/) pos++
  }
  if (substr(text, pos, 1) == "e" || substr(text, pos, 1) == "E") {
    pos++
    if (substr(text, pos, 1) == "+" || substr(text, pos, 1) == "-") pos++
    if (substr(text, pos, 1) !~ /^[0-9]$/) { pos = start; return 0 }
    while (substr(text, pos, 1) ~ /^[0-9]$/) pos++
  }
  number_value = substr(text, start, pos - start)
  return 1
}

function take_literal() {
  if (substr(text, pos, 4) == "true") { pos += 4; literal_value = "true"; return 1 }
  if (substr(text, pos, 5) == "false") { pos += 5; literal_value = "false"; return 1 }
  if (substr(text, pos, 4) == "null") { pos += 4; literal_value = "null"; return 1 }
  return 0
}

function record_scalar(path, kind, value) {
  if (path == "/calibration/" config_key &&
      kind == "number" && value ~ /^[1-9][0-9]*$/) {
    candidate = value
    candidate_found = 1
  }
}

function parse_value(path,    c) {
  skip_ws()
  c = substr(text, pos, 1)
  if (c == "{") return parse_object(path)
  if (c == "[") return parse_array(path)
  if (c == "\"") {
    if (!take_string()) return 0
    record_scalar(path, "string", string_value)
    return 1
  }
  if (c == "-" || c ~ /^[0-9]$/) {
    if (!take_number()) return 0
    record_scalar(path, "number", number_value)
    return 1
  }
  if (take_literal()) {
    record_scalar(path, "literal", literal_value)
    return 1
  }
  return 0
}

function parse_object(path,    key, c) {
  if (substr(text, pos, 1) != "{") return 0
  pos++
  skip_ws()
  if (substr(text, pos, 1) == "}") { pos++; return 1 }
  while (1) {
    skip_ws()
    if (!take_string()) return 0
    key = string_value
    skip_ws()
    if (substr(text, pos, 1) != ":") return 0
    pos++
    if (!parse_value(path "/" key)) return 0
    skip_ws()
    c = substr(text, pos, 1)
    if (c == "}") { pos++; return 1 }
    if (c != ",") return 0
    pos++
  }
}

function parse_array(path,    array_index, c) {
  if (substr(text, pos, 1) != "[") return 0
  pos++
  array_index = 0
  skip_ws()
  if (substr(text, pos, 1) == "]") { pos++; return 1 }
  while (1) {
    if (!parse_value(path "/" array_index)) return 0
    array_index++
    skip_ws()
    c = substr(text, pos, 1)
    if (c == "]") { pos++; return 1 }
    if (c != ",") return 0
    pos++
  }
}

END {
  pos = 1
  if (!parse_value("")) exit 2
  skip_ws()
  if (pos <= length(text)) exit 2
  if (!candidate_found) exit 1
  print candidate
  exit 0
}
