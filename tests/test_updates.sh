#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../main.sh
source "$ROOT/main.sh"

ln -s "$ROOT/main.sh" "$TMP/dnscrypt_manager"
[[ "$(resolve_script_dir "$TMP/dnscrypt_manager")" == "$ROOT" ]]

curl() {
    printf '{\n  "sha": "1111111111111111111111111111111111111111"\n}\n'
}
# Consumed by the sourced resolver function.
# shellcheck disable=SC2034
GITHUB_API_URL=https://api.github.invalid/commits/main
GITHUB_RAW_BASE=https://raw.githubusercontent.invalid/gopnikgame/Installer_dnscypt
resolve_update_snapshot
[[ "$UPDATE_COMMIT" == 1111111111111111111111111111111111111111 ]]
[[ "$GITHUB_REPO" == "$GITHUB_RAW_BASE/$UPDATE_COMMIT" ]]

grep -q 'update_modules true' "$ROOT/main.sh"
grep -q 'bash -n "${module_file}.tmp"' "$ROOT/main.sh"
grep -q 'bash -n "${lib_file}.tmp"' "$ROOT/main.sh"
grep -q 'DOWNLOAD_BASE="${REPOSITORY_RAW_BASE}/${INSTALL_COMMIT}"' "$ROOT/quick_install.sh"
grep -q '^#!/usr/bin/env bash$' "$ROOT/quick_install.sh"
if grep -q 'raw.githubusercontent.com/gopnikgame/Installer_dnscypt/main/' "$ROOT/quick_install.sh"; then
    printf 'quick installer still mixes files from floating main\n' >&2
    exit 1
fi

printf 'update snapshot tests: OK\n'
