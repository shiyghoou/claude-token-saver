# suggest-session-cut.sh が使う設定JSONから、指定された数値フィールドを1つ読む。
# jq/Pythonへ依存しないための小さな字句スキャナであり、root直下にある
# suggest_session_cutオブジェクトの直下だけを設定値として扱う。設定全体の妥当性を
# 評価するものではなく、対象キーの値が非負整数ならそれだけを出力する。
# 不正な設定は呼び出し側が既定値へ戻す。

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

function take_atom(    c, start) {
  start = pos
  while (pos <= length(text)) {
    c = substr(text, pos, 1)
    if (c == " " || c == "\t" || c == "\r" || c == "\n" ||
        c == "{" || c == "}" || c == "[" || c == "]" ||
        c == ":" || c == ",") {
      break
    }
    pos++
  }
  if (pos == start) return 0
  atom_value = substr(text, start, pos - start)
  return 1
}

END {
  wanted = config_key
  pos = 1
  depth = 0
  root_seen = 0
  target_depth = 0

  while (pos <= length(text)) {
    skip_ws()
    if (pos > length(text)) break
    c = substr(text, pos, 1)
    token = ""
    token_value = ""
    if (c == "\"") {
      if (!take_string()) exit 2
      token = "string"
      token_value = string_value
    } else if (c == "{" || c == "}" || c == "[" || c == "]" ||
               c == ":" || c == ",") {
      token = c
      pos++
    } else {
      if (!take_atom()) exit 2
      token = "atom"
      token_value = atom_value
    }

    if (!root_seen) {
      if (token != "{") exit 2
      root_seen = 1
      depth = 1
      container[depth] = "object"
      state[depth] = "key"
      continue
    }

    if (depth == 0) exit 2
    if (container[depth] == "object") {
      if (state[depth] == "key") {
        if (token == "}") {
          if (target_depth == depth) target_depth = 0
          delete container[depth]
          delete state[depth]
          delete object_key[depth]
          depth--
        } else if (token == "string") {
          object_key[depth] = token_value
          state[depth] = "colon"
        } else {
          exit 2
        }
      } else if (state[depth] == "colon") {
        if (token != ":") exit 2
        state[depth] = "value"
      } else if (state[depth] == "value") {
        parent_depth = depth
        is_target = (parent_depth == 1 &&
                     object_key[parent_depth] == "suggest_session_cut" &&
                     token == "{")
        if (parent_depth == target_depth && object_key[parent_depth] == wanted &&
            token == "atom" && token_value ~ /^[0-9][0-9]*$/) {
          print token_value
          exit 0
        }
        state[parent_depth] = "after"
        if (token == "{" || token == "[") {
          depth++
          if (token == "{") {
            container[depth] = "object"
            state[depth] = "key"
          } else {
            container[depth] = "array"
            state[depth] = "value"
          }
          if (is_target) target_depth = depth
        } else if (token != "string" && token != "atom") {
          exit 2
        }
      } else {
        if (token == ",") {
          state[depth] = "key"
        } else if (token == "}") {
          if (target_depth == depth) target_depth = 0
          delete container[depth]
          delete state[depth]
          delete object_key[depth]
          depth--
        } else {
          exit 2
        }
      }
    } else {
      if (state[depth] == "value") {
        if (token == "]") {
          delete container[depth]
          delete state[depth]
          depth--
        } else if (token == "{" || token == "[") {
          state[depth] = "after"
          depth++
          if (token == "{") {
            container[depth] = "object"
            state[depth] = "key"
          } else {
            container[depth] = "array"
            state[depth] = "value"
          }
        } else if (token == "string" || token == "atom") {
          state[depth] = "after"
        } else {
          exit 2
        }
      } else {
        if (token == ",") {
          state[depth] = "value"
        } else if (token == "]") {
          delete container[depth]
          delete state[depth]
          depth--
        } else {
          exit 2
        }
      }
    }
  }
  exit 1
}
