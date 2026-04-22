#!/usr/bin/env bash
# LocalClaudeCode installer — Linux / macOS
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.sh | bash
#
# Installs: Ollama, Node.js (if missing), Claude Code CLI, claude-code-router,
# pulls a model sized to your hardware, preconfigures router + plugins so
# `ccr code` starts a fully-local Claude Code that only ever talks to Ollama.

set -euo pipefail

# ----- colors -----
if [[ -t 1 ]]; then
  B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; C="\033[36m"; N="\033[0m"
else
  B=""; G=""; Y=""; R=""; C=""; N=""
fi
say()  { printf "${C}==>${N} %s\n" "$*"; }
ok()   { printf "${G}OK${N}  %s\n" "$*"; }
warn() { printf "${Y}!!${N}  %s\n" "$*" >&2; }
die()  { printf "${R}ERR${N} %s\n" "$*" >&2; exit 1; }

NONINTERACTIVE="${NONINTERACTIVE:-0}"
MODEL_OVERRIDE="${MODEL:-}"
for a in "$@"; do
  case "$a" in
    -y|--yes|--non-interactive) NONINTERACTIVE=1 ;;
    --model=*)                  MODEL_OVERRIDE="${a#*=}" ;;
  esac
done

# ----- OS detect -----
UNAME=$(uname -s)
case "$UNAME" in
  Linux*)  OS=linux ;;
  Darwin*) OS=macos ;;
  *) die "Unsupported OS: $UNAME (this script is for Linux/macOS; use install.ps1 on Windows)";;
esac
ok "OS: $OS"

# ----- prereqs -----
have() { command -v "$1" >/dev/null 2>&1; }

ensure_curl() {
  have curl || die "curl not found. Install it first."
}

ensure_node() {
  if have node && have npm; then
    local v
    v=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || echo 0)
    if [[ "$v" -ge 18 ]]; then
      ok "Node $(node -v) present."
      return 0
    fi
    warn "Node is older than v18 ($(node -v)); upgrading."
  fi
  say "Installing Node.js (LTS)..."
  if [[ "$OS" == macos ]]; then
    if have brew; then
      brew install node
    else
      die "Node.js missing. Install Homebrew (https://brew.sh) or Node.js (https://nodejs.org) and re-run."
    fi
  else
    # Linux — prefer NodeSource, fall back to nvm.
    if have apt-get && [[ $EUID -eq 0 || -n "${SUDO_USER:-}" || $(sudo -n true 2>/dev/null; echo $?) == 0 ]]; then
      local SUDO=""; [[ $EUID -ne 0 ]] && SUDO=sudo
      curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
      $SUDO apt-get install -y nodejs
    elif have dnf; then
      local SUDO=""; [[ $EUID -ne 0 ]] && SUDO=sudo
      curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -
      $SUDO dnf install -y nodejs
    else
      say "No root apt/dnf detected — installing nvm for current user."
      export NVM_DIR="$HOME/.nvm"
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
      # shellcheck disable=SC1091
      . "$NVM_DIR/nvm.sh"
      nvm install --lts
      nvm use --lts
    fi
  fi
  have node || die "Node install failed."
  ok "Node $(node -v) installed."
}

ensure_ollama() {
  if have ollama; then
    ok "ollama already installed ($(ollama --version 2>/dev/null | head -1 || echo '?'))."
    return 0
  fi
  say "Installing Ollama..."
  if [[ "$OS" == macos ]]; then
    if have brew; then
      brew install --cask ollama || brew install ollama
    else
      warn "Homebrew missing. Download the Ollama app manually: https://ollama.com/download"
      die "Install Ollama and re-run."
    fi
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  have ollama || die "Ollama install failed."
  ok "Ollama installed."
}

start_ollama_bg() {
  # On macOS the .app starts its own server; on Linux the installer registers
  # a systemd unit. If neither is running, start `ollama serve` detached.
  if curl -fsS --max-time 1 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    return 0
  fi
  say "Starting Ollama server..."
  if [[ "$OS" == linux ]] && have systemctl; then
    sudo systemctl enable --now ollama 2>/dev/null || nohup ollama serve >/tmp/ollama.log 2>&1 &
  else
    nohup ollama serve >/tmp/ollama.log 2>&1 &
  fi
  for _ in {1..30}; do
    sleep 1
    if curl -fsS --max-time 1 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      ok "Ollama running on :11434"
      return 0
    fi
  done
  die "Ollama did not become ready; see /tmp/ollama.log"
}

ensure_claude_cli() {
  if have claude; then
    ok "claude CLI present."
  else
    say "Installing @anthropic-ai/claude-code..."
    npm install -g @anthropic-ai/claude-code
  fi
}

ensure_ccr() {
  if have ccr; then
    ok "ccr (claude-code-router) present."
  else
    say "Installing @musistudio/claude-code-router..."
    npm install -g @musistudio/claude-code-router
  fi
}

# ----- hardware detect -----
# Prints: <ram_gb> <vram_gb>   (vram=0 if unknown)
detect_hw() {
  local ram_gb=0 vram_gb=0
  if [[ "$OS" == macos ]]; then
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    ram_gb=$(( bytes / 1024 / 1024 / 1024 ))
    # Apple Silicon: unified memory. Treat ~75% of RAM as usable VRAM.
    if sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qi 'apple'; then
      vram_gb=$(( ram_gb * 3 / 4 ))
    fi
  else
    if have free; then
      ram_gb=$(free -g | awk '/^Mem:/ {print $2}')
    elif [[ -r /proc/meminfo ]]; then
      local kb
      kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
      ram_gb=$(( kb / 1024 / 1024 ))
    fi
    if have nvidia-smi; then
      local mb
      mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
      [[ -n "$mb" ]] && vram_gb=$(( mb / 1024 ))
    elif have rocm-smi; then
      local mb
      mb=$(rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total/ {print $NF; exit}')
      [[ -n "$mb" ]] && vram_gb=$(( mb / 1024 / 1024 ))
    fi
  fi
  echo "$ram_gb $vram_gb"
}

# ----- model picker -----
# Model table: size_gb | id | human name (coding-focused)
MODELS=(
  "2  qwen2.5-coder:3b    Qwen2.5 Coder 3B (tiny)"
  "5  qwen2.5-coder:7b    Qwen2.5 Coder 7B (balanced)"
  "9  qwen2.5-coder:14b   Qwen2.5 Coder 14B"
  "13 gpt-oss:20b         GPT-OSS 20B (OpenAI open)"
  "20 qwen2.5-coder:32b   Qwen2.5 Coder 32B (best coding)"
  "43 deepseek-r1:70b     DeepSeek R1 70B (reasoning)"
)

pick_default_model() {
  local ram="$1" vram="$2"
  # Prefer VRAM if GPU present and sizeable; otherwise RAM.
  local budget="$ram"
  if [[ "$vram" -gt 3 ]]; then budget="$vram"; fi
  local choice="qwen2.5-coder:3b"
  for row in "${MODELS[@]}"; do
    local sz id
    sz=$(echo "$row" | awk '{print $1}')
    id=$(echo "$row" | awk '{print $2}')
    if (( budget >= sz + 2 )); then choice="$id"; fi
  done
  echo "$choice"
}

prompt_model() {
  local suggested="$1"
  if [[ -n "$MODEL_OVERRIDE" ]]; then
    echo "$MODEL_OVERRIDE"; return
  fi
  if [[ "$NONINTERACTIVE" == 1 ]] || [[ ! -t 0 ]]; then
    echo "$suggested"; return
  fi
  printf "\n${B}Choose a model${N} (size / id):\n"
  local i=1
  for row in "${MODELS[@]}"; do
    local sz id name
    sz=$(echo "$row" | awk '{print $1}')
    id=$(echo "$row" | awk '{print $2}')
    name=$(echo "$row" | cut -d' ' -f3- | sed 's/^ *//')
    local mark=" "
    [[ "$id" == "$suggested" ]] && mark="*"
    printf "  %s%d) %-22s %sGB  %s\n" "$mark" "$i" "$id" "$sz" "$name"
    i=$((i+1))
  done
  echo   "  c) custom (any tag from https://ollama.com/library)"
  printf "\nPick number [default: %s]: " "$suggested"
  local ans
  read -r ans </dev/tty || true
  if [[ -z "$ans" ]]; then echo "$suggested"; return; fi
  if [[ "$ans" == c || "$ans" == C ]]; then
    printf "Ollama model tag: "
    local tag; read -r tag </dev/tty
    echo "${tag:-$suggested}"; return
  fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#MODELS[@]} )); then
    echo "${MODELS[$((ans-1))]}" | awk '{print $2}'; return
  fi
  echo "$suggested"
}

# ----- config writers -----
write_ccr_config() {
  local model="$1"
  local dir="$HOME/.claude-code-router"
  local cfg="$dir/config.json"
  mkdir -p "$dir"
  if [[ -f "$cfg" ]]; then
    cp "$cfg" "$cfg.backup.$(date +%s)"
    warn "Existing ccr config backed up."
  fi
  cat > "$cfg" <<JSON
{
  "LOG": false,
  "Providers": [
    {
      "name": "ollama",
      "api_base_url": "http://127.0.0.1:11434/v1/chat/completions",
      "api_key": "ollama",
      "models": ["$model"]
    }
  ],
  "Router": {
    "default":     "ollama,$model",
    "background":  "ollama,$model",
    "think":       "ollama,$model",
    "longContext": "ollama,$model",
    "webSearch":   "ollama,$model"
  }
}
JSON
  ok "Wrote $cfg"
}

# Plugin marketplaces + enabled plugins to preseed into ~/.claude/settings.json
PRESEED_JSON='{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "claude-mem@thedotmack": true,
    "ralph-loop@claude-plugins-official": true,
    "feature-dev@claude-plugins-official": true,
    "code-review@claude-plugins-official": true,
    "code-simplifier@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "firecrawl@claude-plugins-official": true,
    "chrome-devtools-mcp@claude-plugins-official": true,
    "huggingface-skills@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "claude-plugins-official": {
      "source": { "source": "github", "repo": "anthropics/claude-plugins-official" }
    },
    "thedotmack": {
      "source": { "source": "github", "repo": "thedotmack/claude-mem" },
      "autoUpdate": true
    },
    "superpowers-marketplace": {
      "source": { "source": "github", "repo": "obra/superpowers-marketplace" }
    }
  },
  "autoUpdatesChannel": "latest"
}'

merge_claude_settings() {
  local dir="$HOME/.claude"
  local cfg="$dir/settings.json"
  mkdir -p "$dir"
  if [[ -f "$cfg" ]]; then
    cp "$cfg" "$cfg.backup.$(date +%s)"
    if have node; then
      node -e '
        const fs = require("fs");
        const path = process.argv[1];
        const add = JSON.parse(process.argv[2]);
        let cur = {};
        try { cur = JSON.parse(fs.readFileSync(path, "utf8")); } catch {}
        cur.enabledPlugins = Object.assign({}, cur.enabledPlugins || {}, add.enabledPlugins);
        cur.extraKnownMarketplaces = Object.assign({}, cur.extraKnownMarketplaces || {}, add.extraKnownMarketplaces);
        if (add.autoUpdatesChannel && !cur.autoUpdatesChannel) cur.autoUpdatesChannel = add.autoUpdatesChannel;
        fs.writeFileSync(path, JSON.stringify(cur, null, 2));
      ' "$cfg" "$PRESEED_JSON"
    else
      warn "node missing; wrote fresh settings instead of merging."
      echo "$PRESEED_JSON" > "$cfg"
    fi
  else
    echo "$PRESEED_JSON" > "$cfg"
  fi
  ok "Preseeded $cfg (marketplaces + plugins)"
}

install_lcc_wrapper() {
  local target
  if [[ -w /usr/local/bin ]]; then
    target=/usr/local/bin/lcc
  elif have sudo && [[ -d /usr/local/bin ]]; then
    target=/usr/local/bin/lcc
    local SUDO=sudo
  else
    target="$HOME/.local/bin/lcc"
    mkdir -p "$HOME/.local/bin"
  fi
  # ANTHROPIC_API_KEY forces Claude Code into API-key auth mode so the ccr
  # proxy is actually used. Without it, a cached OAuth session (Pro/Max
  # subscription) takes precedence and Claude Code silently bypasses ccr,
  # hitting api.anthropic.com directly.
  local script='#!/usr/bin/env bash
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-ccr-local}"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-ccr-local}"
exec ccr code "$@"
'
  if [[ -n "${SUDO:-}" ]]; then
    echo "$script" | $SUDO tee "$target" >/dev/null
    $SUDO chmod +x "$target"
  else
    echo "$script" > "$target"
    chmod +x "$target"
  fi
  ok "Installed wrapper: $target"
  case ":$PATH:" in
    *":$(dirname "$target"):"*) ;;
    *) warn "$(dirname "$target") is not on PATH. Add it to your shell rc." ;;
  esac
}

# ----- main -----
say "LocalClaudeCode installer starting"
ensure_curl
ensure_node
ensure_ollama
start_ollama_bg
ensure_claude_cli
ensure_ccr

read -r RAM VRAM < <(detect_hw)
say "Detected RAM: ${RAM} GB | GPU VRAM: ${VRAM} GB"
DEFAULT=$(pick_default_model "$RAM" "$VRAM")
MODEL=$(prompt_model "$DEFAULT")
ok "Chosen model: $MODEL"

say "Pulling $MODEL (may take several minutes)..."
ollama pull "$MODEL"

write_ccr_config "$MODEL"
merge_claude_settings
install_lcc_wrapper

cat <<EOF

${G}Done.${N}

Start your local Claude Code:
  ${B}lcc${N}                    # wrapper (same as: ccr code)
  ${B}ccr code${N}               # or invoke the router directly

The router (ccr) spawns on demand and proxies Claude Code's Anthropic API
traffic to Ollama at 127.0.0.1:11434 — no cloud calls, no subscription.

Plugins are preseeded (superpowers, context7, claude-mem, ralph-loop, ...).
On first launch Claude Code may ask you to trust each marketplace — accept.

Switch model later: edit ~/.claude-code-router/config.json and run ${B}ccr restart${N}.
Pull more models: ${B}ollama pull <name>${N} (see https://ollama.com/library).
EOF
