# Claude Code transcript JSONLからassistant message.usageのcache_readを合計する。
#
# 1行をJSON値として字句解析する。単純な grep でキー名だけを探すと本文や
# tool input の文字列をusageとして数えてしまうため、message/usage配下という
# JSONのパスを追跡する。message.idを第一キーにし、id無し行はPython側の
# token-reportと同じくrequestId・usage値の代替キーで重複を抑える。

BEGIN {
  total = 0
  assistant_turns = 0
  invalid = 0
}

function skip_ws(    c) {
  while (pos <= length(line)) {
    c = substr(line, pos, 1)
    if (c == " " || c == "\t" || c == "\r" || c == "\n") pos++
    else return
  }
}

function take_string(    c, escaped, out) {
  if (substr(line, pos, 1) != "\"") return 0
  pos++
  out = ""
  while (pos <= length(line)) {
    c = substr(line, pos, 1)
    pos++
    if (c == "\"") {
      string_value = out
      return 1
    }
    if (c != "\\") {
      # JSON文字列の生改行は不正である。
      if (c == "\r" || c == "\n") return 0
      out = out c
      continue
    }
    if (pos > length(line)) return 0
    escaped = substr(line, pos, 1)
    pos++
    if (escaped == "u") {
      if (pos + 3 > length(line) || substr(line, pos, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
        return 0
      }
      # キー比較に必要なASCIIはそのまま扱える。その他のescapeも境界を
      # 壊さないよう、文字列値には可逆な表現を残す。
      out = out "\\u" substr(line, pos, 4)
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
  c = substr(line, pos, 1)
  if (c == "-") pos++
  if (substr(line, pos, 1) == "0") {
    pos++
  } else if (substr(line, pos, 1) ~ /^[1-9]$/) {
    while (substr(line, pos, 1) ~ /^[0-9]$/) pos++
  } else {
    pos = start
    return 0
  }
  if (substr(line, pos, 1) == ".") {
    pos++
    if (substr(line, pos, 1) !~ /^[0-9]$/) { pos = start; return 0 }
    while (substr(line, pos, 1) ~ /^[0-9]$/) pos++
  }
  if (substr(line, pos, 1) == "e" || substr(line, pos, 1) == "E") {
    pos++
    if (substr(line, pos, 1) == "+" || substr(line, pos, 1) == "-") pos++
    if (substr(line, pos, 1) !~ /^[0-9]$/) { pos = start; return 0 }
    while (substr(line, pos, 1) ~ /^[0-9]$/) pos++
  }
  number_value = substr(line, start, pos - start)
  return 1
}

function take_literal(    word) {
  if (substr(line, pos, 4) == "true") { pos += 4; literal_value = "true"; return 1 }
  if (substr(line, pos, 5) == "false") { pos += 5; literal_value = "false"; return 1 }
  if (substr(line, pos, 4) == "null") { pos += 4; literal_value = "null"; return 1 }
  return 0
}

function nonnegative_integer(value) {
  return value ~ /^[0-9]+$/
}

function record_scalar(path, kind, value) {
  if (path == "/type" && kind == "string") entry_type = value
  else if (path == "/requestId" && (kind == "string" || kind == "number")) {
    request_kind = kind
    request_value = value
    has_request = 1
  } else if (path == "/message/id" && (kind == "string" || kind == "number")) {
    if (kind == "string" && value != "") {
      message_id_kind = kind
      message_id_value = value
      has_message_id = 1
    } else if (kind == "number" && nonnegative_integer(value)) {
      message_id_kind = kind
      message_id_value = value
      has_message_id = 1
    }
  } else if (path == "/message/usage/input_tokens") {
    if (kind == "number" && nonnegative_integer(value)) input_value = value
    else usage_invalid = 1
  } else if (path == "/message/usage/cache_creation_input_tokens") {
    if (kind == "number" && nonnegative_integer(value)) creation_value = value
    else usage_invalid = 1
  } else if (path == "/message/usage/cache_read_input_tokens") {
    if (kind == "number" && nonnegative_integer(value)) {
      cache_value = value
      has_cache = 1
    } else usage_invalid = 1
  } else if (path == "/message/usage/output_tokens") {
    if (kind == "number" && nonnegative_integer(value)) output_value = value
    else usage_invalid = 1
  }
}

function parse_value(path,    c, value) {
  skip_ws()
  c = substr(line, pos, 1)
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
  if (substr(line, pos, 1) != "{") return 0
  pos++
  skip_ws()
  if (substr(line, pos, 1) == "}") { pos++; return 1 }
  while (1) {
    skip_ws()
    if (!take_string()) return 0
    key = string_value
    skip_ws()
    if (substr(line, pos, 1) != ":") return 0
    pos++
    if (!parse_value(path "/" key)) return 0
    skip_ws()
    c = substr(line, pos, 1)
    if (c == "}") { pos++; return 1 }
    if (c != ",") return 0
    pos++
  }
}

function parse_array(path,    array_index, c) {
  if (substr(line, pos, 1) != "[") return 0
  pos++
  array_index = 0
  skip_ws()
  if (substr(line, pos, 1) == "]") { pos++; return 1 }
  while (1) {
    if (!parse_value(path "/" array_index)) return 0
    array_index++
    skip_ws()
    c = substr(line, pos, 1)
    if (c == "]") { pos++; return 1 }
    if (c != ",") return 0
    pos++
  }
}

{
  line = $0
  pos = 1
  entry_type = ""
  has_message_id = 0
  has_request = 0
  has_cache = 0
  usage_invalid = 0
  message_id_kind = ""
  message_id_value = ""
  request_kind = ""
  request_value = ""
  input_value = "0"
  creation_value = "0"
  cache_value = "0"
  output_value = "0"

  if (!parse_value("")) { invalid = 1; next }
  skip_ws()
  if (pos <= length(line) || usage_invalid) { invalid = 1; next }

  if (entry_type != "assistant" || !has_cache) next
  if (has_message_id) {
    dedup_key = "id\034" message_id_kind "\034" message_id_value
  } else {
    dedup_key = "fallback\034" (has_request ? request_kind : "none") "\034" \
      (has_request ? request_value : "") "\034" input_value "\034" \
      creation_value "\034" cache_value "\034" output_value
  }
  if (seen[dedup_key]) next
  seen[dedup_key] = 1
  total += cache_value
  assistant_turns += 1
}

END {
  if (invalid) exit 2
  if (summary) printf "%.0f\t%.0f\n", total, assistant_turns
  else printf "%.0f\n", total
}
