#!/usr/bin/env bash
# install/uninstall が同じ内容で target-local token-calibrate entrypoint を生成する。

cts_write_token_calibrate_entrypoint() {
  local output="$1" source_launcher="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# claude-token-saver managed token-calibrate entrypoint\n'
    printf 'set -uo pipefail\n'
    printf 'CTS_TOKEN_CALIBRATE_SOURCE=%q\n' "$source_launcher"
    printf 'CTS_TOKEN_CALIBRATE_ENTRYPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"\n'
    printf 'CTS_TOKEN_CALIBRATE_TARGET_ROOT="$(cd "$CTS_TOKEN_CALIBRATE_ENTRYPOINT_DIR/.." && pwd -P)"\n'
    printf 'export CTS_TOKEN_CALIBRATE_TARGET_ROOT\n'
    printf 'exec bash "$CTS_TOKEN_CALIBRATE_SOURCE" "$@"\n'
  } >"$output"
}
