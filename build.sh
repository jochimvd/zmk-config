#!/usr/bin/env bash
# Build the firmware locally, using the same Docker image as the GitHub Actions workflow.
#
#   ./build.sh                 build every target in build.yaml
#   ./build.sh corne           build targets whose shield/board/artifact name contains "corne"
#   ./build.sh -u corne        run `west update` first (needed after changing config/west.yml)
#   ./build.sh -p corne        pristine build (wipe the build directories first)
#
# The west workspace (zmk/, zephyr/, modules/, ...) lives in the repo root and is git-ignored.
# Build trees go to build/<artifact>/, firmware images to firmware/<artifact>.uf2.
set -euo pipefail

IMAGE=zmkfirmware/zmk-build-arm:stable
ROOT=$(cd "$(dirname "$0")" && pwd)

update=0
pristine=auto
while getopts "up" opt; do
  case $opt in
    u) update=1 ;;
    p) pristine=always ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

tty=()
[ -t 1 ] && tty=(-t)

docker run --rm "${tty[@]}" \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp/home \
  -e UPDATE="$update" \
  -e PRISTINE="$pristine" \
  -v "$ROOT:/zmk-config" \
  -w /zmk-config \
  "$IMAGE" \
  bash -c '
set -euo pipefail

[ -d .west ] || west init -l config
if [ ! -d zmk ] || [ "$UPDATE" = 1 ]; then
  west update --fetch-opt=--filter=tree:0
fi
west zephyr-export >/dev/null

# One line per build.yaml entry: board|shield|snippet|cmake-args|artifact-name
targets=$(python3 - "$@" <<"EOF"
import sys, yaml
filters = sys.argv[1:]
for t in yaml.safe_load(open("build.yaml"))["include"]:
    board, shield = t["board"], t.get("shield", "")
    name = t.get("artifact-name") or (f"{shield}-{board}-zmk" if shield else f"{board}-zmk")
    if filters and not any(f in f"{board} {shield} {name}" for f in filters):
        continue
    print("|".join([board, shield, t.get("snippet", ""), t.get("cmake-args", ""), name]))
EOF
)
[ -n "$targets" ] || { echo "No build.yaml target matches: $*" >&2; exit 1; }

mkdir -p firmware
failed=()
while IFS="|" read -r board shield snippet cmake_args name; do
  echo "==> Building $name"
  args=(-s zmk/app -d "build/$name" -b "$board" -p "$PRISTINE")
  [ -n "$snippet" ] && args+=(-S "$snippet")
  # shellcheck disable=SC2086
  if west build "${args[@]}" -- -DZMK_CONFIG=/zmk-config/config ${shield:+-DSHIELD="$shield"} $cmake_args; then
    for ext in uf2 bin; do
      if [ -f "build/$name/zephyr/zmk.$ext" ]; then
        cp "build/$name/zephyr/zmk.$ext" "firmware/$name.$ext"
        echo "==> firmware/$name.$ext"
        break
      fi
    done
  else
    failed+=("$name")
  fi
done <<< "$targets"

if [ ${#failed[@]} -gt 0 ]; then
  echo "==> FAILED: ${failed[*]}" >&2
  exit 1
fi
' build "$@"
