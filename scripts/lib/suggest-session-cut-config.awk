# suggest-session-cut.sh が使う設定JSONから、指定された数値フィールドを1つ読む。
# jq/Pythonへ依存しないための小さな字句スキャナであり、文字列本文中の同名文字列を
# 設定値として拾わない。設定全体の妥当性を評価するものではなく、対象キーの値が
# JSONの非負整数ならそれだけを出力する。不正な設定は呼び出し側が既定値へ戻す。

BEGIN {
  text = ""
}

{
  text = text $0
}

function skip_ws(    c) {
  while (pos <= length(text)) {
    c = substr(text, pos, 1)
    if (c == " " || c == "\t" || c == "\r" || c == "\n") {
      pos++
    } else {
      return
    }
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
      out = out c
      continue
    }
    if (pos > length(text)) return 0
    escaped = substr(text, pos, 1)
    pos++
    if (escaped == "u") {
      if (pos + 3 > length(text) || substr(text, pos, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) {
        return 0
      }
      out = out "\\u" substr(text, pos, 4)
      pos += 4
    } else if (escaped == "\"" || escaped == "\\" || escaped == "/") {
      out = out escaped
    } else if (escaped == "b" || escaped == "f" || escaped == "n" ||
               escaped == "r" || escaped == "t") {
      out = out escaped
    } else {
      return 0
    }
  }
  return 0
}

function take_digits(    start) {
  start = pos
  while (pos <= length(text) && substr(text, pos, 1) ~ /^[0-9]$/) pos++
  if (pos == start) return 0
  number_value = substr(text, start, pos - start)
  return 1
}

END {
  wanted = config_key
  pos = 1
  while (pos <= length(text)) {
    if (substr(text, pos, 1) == "\"") {
      if (!take_string()) exit 2
      if (string_value == wanted) {
        skip_ws()
        if (substr(text, pos, 1) == ":") {
          pos++
          skip_ws()
          if (take_digits()) {
            # JSONの数値の直後に識別子文字があれば、数値の一部として扱わない。
            if (substr(text, pos, 1) !~ /^[A-Za-z0-9_.+-]$/) {
              print number_value
              exit 0
            }
          }
        }
      }
    } else {
      pos++
    }
  }
  exit 1
}
