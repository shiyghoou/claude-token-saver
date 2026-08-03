# Stop hook payloadを依存追加なしで完全検証するPOSIX awk JSONパーサ。
# 値を抽出するcommon.shより先に使い、末尾の壊れた入力もfail-closedにする。

BEGIN {
  text = ""
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

function take_string(    c, escaped) {
  if (substr(text, pos, 1) != "\"") return 0
  pos++
  while (pos <= length(text)) {
    c = substr(text, pos, 1)
    pos++
    if (c == "\"") return 1
    if (c != "\\") {
      if (c ~ /[[:cntrl:]]/) return 0
      continue
    }
    if (pos > length(text)) return 0
    escaped = substr(text, pos, 1)
    pos++
    if (escaped == "u") {
      if (pos + 3 > length(text) ||
          substr(text, pos, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return 0
      pos += 4
    } else if (escaped != "\"" && escaped != "\\" && escaped != "/" &&
               escaped != "b" && escaped != "f" && escaped != "n" &&
               escaped != "r" && escaped != "t") {
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
  return 1
}

function take_literal() {
  if (substr(text, pos, 4) == "true") { pos += 4; return 1 }
  if (substr(text, pos, 5) == "false") { pos += 5; return 1 }
  if (substr(text, pos, 4) == "null") { pos += 4; return 1 }
  return 0
}

function parse_value(    c) {
  skip_ws()
  c = substr(text, pos, 1)
  if (c == "{") return parse_object()
  if (c == "[") return parse_array()
  if (c == "\"") return take_string()
  if (c == "-" || c ~ /^[0-9]$/) return take_number()
  return take_literal()
}

function parse_object(    c) {
  if (substr(text, pos, 1) != "{") return 0
  pos++
  skip_ws()
  if (substr(text, pos, 1) == "}") { pos++; return 1 }
  while (1) {
    skip_ws()
    if (!take_string()) return 0
    skip_ws()
    if (substr(text, pos, 1) != ":") return 0
    pos++
    if (!parse_value()) return 0
    skip_ws()
    c = substr(text, pos, 1)
    if (c == "}") { pos++; return 1 }
    if (c != ",") return 0
    pos++
  }
}

function parse_array(    c) {
  if (substr(text, pos, 1) != "[") return 0
  pos++
  skip_ws()
  if (substr(text, pos, 1) == "]") { pos++; return 1 }
  while (1) {
    if (!parse_value()) return 0
    skip_ws()
    c = substr(text, pos, 1)
    if (c == "]") { pos++; return 1 }
    if (c != ",") return 0
    pos++
  }
}

END {
  pos = 1
  if (!parse_value()) exit 2
  skip_ws()
  if (pos <= length(text)) exit 2
  exit 0
}
