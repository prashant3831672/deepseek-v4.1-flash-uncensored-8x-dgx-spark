#!/usr/bin/env bash
# Install the DeepSeek Harness (dsh) client pieces for a local vLLM cluster on a Mac.
# Idempotent: re-running only replaces what changed and backs up any file it
# overwrites (suffix .bak-<timestamp>).
#
#   bash install.sh --spark-host 192.0.2.10                 head node address the laptop can reach
#   bash install.sh --spark-host 192.0.2.10 --no-clone      config files only (dsh clone already built)
#   bash install.sh --spark-host 192.0.2.10 --model my-id   served model id if it is not dsv41-flash-uncensored
#
# What it installs (see README.md in this directory for the reasoning behind each):
#   ~/.dsh/settings.yaml                 the provider entry that makes dsh talk to vLLM correctly
#   ~/.local/bin/dsh-spark               launcher: cluster preflight, rebuild-if-stale, start the web UI
#   ~/.local/lib/undici-longtimeout.mjs  transport shim that lifts Node's 300 s fetch timeouts
#   ~/.local/lib/undici-patch/           the undici package the shim imports
#   $DSH_REPO                            a pinned source checkout of deepseek-harness, built
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPARK_HOST="${SPARK_HOST:-}"
SERVED_MODEL="${SERVED_MODEL:-dsv41-flash-uncensored}"
DSH_REPO="${DSH_REPO:-$HOME/src/deepseek-harness}"
DSH_PIN="${DSH_PIN:-c291e7961a}"      # dsh-v0.1.5-rc.2-139-gc291e7961a (2026-09-10), the commit this kit was verified with
UNDICI_VER="${UNDICI_VER:-8.10.0}"
CLONE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --spark-host) SPARK_HOST="$2"; shift 2 ;;
    --model)      SERVED_MODEL="$2"; shift 2 ;;
    --no-clone)   CLONE=0; shift ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
done
[ -n "$SPARK_HOST" ] || { echo "ERROR: --spark-host <address of the vLLM head node> is required (or export SPARK_HOST)"; exit 2; }
TS="$(date +%Y%m%d-%H%M%S)"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# put_file <src> <dst> <mode>: substitute the placeholders, back up a differing existing file
put_file() {
  local src="$1" dst="$2" mode="$3" tmp
  tmp="$(mktemp)"
  sed -e "s#__SPARK_HOST__#${SPARK_HOST}#g" -e "s#__SERVED_MODEL__#${SERVED_MODEL}#g" "$src" > "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    say "  unchanged  $dst"; rm -f "$tmp"; return
  fi
  if [ -f "$dst" ]; then cp -p "$dst" "$dst.bak-$TS"; say "  backed up  $dst -> $dst.bak-$TS"; fi
  install -m "$mode" "$tmp" "$dst"; rm -f "$tmp"
  say "  installed  $dst"
}

step "1/6 prerequisites"
command -v node >/dev/null || die "node not found. Install Node 22.19+ (brew install node@22, or nvm) and re-run."
NODE_V="$(node -p 'process.versions.node')"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit((a===22&&b>=19)||a>=24?0:1)' \
  || die "node $NODE_V is too old; dsh needs ^22.19.0 or >=24."
say "  node $NODE_V"
if ! command -v git >/dev/null; then die "git not found (xcode-select --install)"; fi
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode Command Line Tools missing: run 'xcode-select --install' (needed for pnpm build:native-system), then re-run."
fi
if command -v corepack >/dev/null; then
  corepack enable >/dev/null 2>&1 || true
  corepack prepare pnpm@11.7.0 --activate >/dev/null 2>&1 || say "  (corepack could not pin pnpm 11.7.0; continuing with $(pnpm --version 2>/dev/null || echo 'no pnpm'))"
fi
command -v pnpm >/dev/null || die "pnpm not found. Run: corepack enable && corepack prepare pnpm@11.7.0 --activate"
say "  pnpm $(pnpm --version)"

step "2/6 cluster preflight at http://${SPARK_HOST}:8888"
if served="$(curl -fsS -m 8 "http://${SPARK_HOST}:8888/v1/models" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)"; then
  say "  serving: $served"
  [ "$served" = "$SERVED_MODEL" ] || say "  NOTE: expected $SERVED_MODEL; re-run with --model $served if that is the id you want dsh to use"
else
  say "  UNREACHABLE now (continuing; config is installed regardless)."
  say "  The laptop must reach the head node's :8888 directly (same LAN, or a private overlay network). Never port-forward it."
fi

step "3/6 dsh config, launcher, transport shim"
mkdir -p "$HOME/.dsh" "$HOME/.local/bin" "$HOME/.local/lib"
put_file "$HERE/settings.yaml"            "$HOME/.dsh/settings.yaml"              600
put_file "$HERE/dsh-spark"                "$HOME/.local/bin/dsh-spark"            755
put_file "$HERE/undici-longtimeout.mjs"   "$HOME/.local/lib/undici-longtimeout.mjs" 644

step "4/6 undici ${UNDICI_VER} for the transport shim"
if [ -f "$HOME/.local/lib/undici-patch/node_modules/undici/index.js" ]; then
  say "  present   $HOME/.local/lib/undici-patch/node_modules/undici"
else
  mkdir -p "$HOME/.local/lib/undici-patch"
  ( cd "$HOME/.local/lib/undici-patch" || exit 1
    [ -f package.json ] || npm init -y >/dev/null 2>&1
    npm install "undici@${UNDICI_VER}" --no-audit --no-fund --loglevel=error ) \
    || die "npm install undici failed"
  say "  installed $HOME/.local/lib/undici-patch/node_modules/undici"
fi
node --import "$HOME/.local/lib/undici-longtimeout.mjs" -e 'process.exit(0)' \
  || die "the undici shim does not load; check $HOME/.local/lib/undici-longtimeout.mjs"
say "  shim loads"

step "5/6 dsh source checkout at $DSH_REPO (pinned to $DSH_PIN)"
if [ "$CLONE" = "0" ]; then
  say "  skipped (--no-clone)"
elif [ -d "$DSH_REPO/.git" ]; then
  say "  clone exists; not touching it ($(git -C "$DSH_REPO" log -1 --oneline 2>/dev/null | cut -c1-70))"
else
  mkdir -p "$(dirname "$DSH_REPO")"
  git clone https://github.com/deepseek-ai/deepseek-harness.git "$DSH_REPO"
  git -C "$DSH_REPO" checkout -q -b pinned-"$DSH_PIN" "$DSH_PIN"
  say "  building (pnpm install, build:lib, build:web, build:native-system) ... this takes a few minutes"
  ( cd "$DSH_REPO" && pnpm install && pnpm build:lib && pnpm build:web && pnpm build:native-system ) \
    || die "dsh build failed; fix the error above and re-run with --no-clone after building by hand"
  say "  built"
fi

step "6/6 done"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) say "  add to PATH (zsh):  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
cat <<EOF
  run:        cd <project dir> && DSH_REPO=$DSH_REPO dsh-spark
  second UI:  cd <other project> && dsh-spark --profile web --port 3081 --no-open
  cluster:    http://${SPARK_HOST}:8888/v1   (SPARK_URL=... overrides the launcher preflight;
              the address dsh actually calls is baseURL in ~/.dsh/settings.yaml)
  optional:   an official api.deepseek.com lane needs DEEPSEEK_API_KEY in the environment (see settings.yaml)
EOF
