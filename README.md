# LocalClaudeCode

One-shot installer that gives you **Claude Code** running fully **locally** on
**Ollama** — no Anthropic account, no subscription, no cloud traffic.

It installs Ollama, Node.js (if missing), the Claude Code CLI, and
[`claude-code-router`](https://github.com/musistudio/claude-code-router) which
transparently proxies Claude Code's Anthropic-API calls to the local Ollama
daemon at `127.0.0.1:11434`. A model is picked for you based on your RAM/VRAM
and pulled automatically. The top community plugins (superpowers, context7,
claude-mem, ralph-loop, feature-dev, code-review, ...) are preseeded in
`~/.claude/settings.json` so you get the full Claude Code experience out of
the box.

## Install

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.sh | bash
```

Non-interactive (accept the suggested model, no prompts):

```bash
curl -fsSL https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.sh | bash -s -- -y
```

Force a specific model:

```bash
curl -fsSL https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.sh \
  | bash -s -- -y --model=qwen2.5-coder:14b
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.ps1 | iex
```

Non-interactive:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.ps1))) -Yes
```

Specific model:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.ps1))) -Yes -Model 'qwen2.5-coder:14b'
```

## Use

After install, in any directory:

```bash
lcc                # thin wrapper around: ccr code
# or
ccr code           # direct invocation of the router
```

`ccr` starts on demand, launches Claude Code with `ANTHROPIC_BASE_URL`
pointing at its local proxy, and the proxy forwards every request to
Ollama. On first launch Claude Code will ask you to trust each plugin
marketplace — accept them.

## Hardware-based model selection

The installer inspects RAM (and NVIDIA VRAM if present) and picks a default
from this table:

| Budget (RAM or VRAM) | Suggested model        | Size |
|----------------------|------------------------|------|
| ≥ 4 GB               | `qwen2.5-coder:3b`     | ~2 GB |
| ≥ 7 GB               | `qwen2.5-coder:7b`     | ~5 GB |
| ≥ 11 GB              | `qwen2.5-coder:14b`    | ~9 GB |
| ≥ 15 GB              | `gpt-oss:20b`          | ~13 GB |
| ≥ 22 GB              | `qwen2.5-coder:32b`    | ~20 GB |
| ≥ 45 GB              | `deepseek-r1:70b`      | ~43 GB |

You can always override interactively or via `--model`. Any tag from
<https://ollama.com/library> is valid.

## What gets configured

- **Ollama** runs as a background service (systemd on Linux, launchd via the
  Ollama app on macOS, a hidden `ollama serve` on Windows).
- **`~/.claude-code-router/config.json`** — points ccr at Ollama. Switch
  models later by editing this file and running `ccr restart`.
- **`~/.claude/settings.json`** — enables these plugins via the official
  marketplace (`anthropics/claude-plugins-official`) plus `thedotmack` and
  `obra/superpowers-marketplace`:
  `superpowers`, `context7`, `claude-mem`, `ralph-loop`, `feature-dev`,
  `code-review`, `code-simplifier`, `frontend-design`, `claude-md-management`,
  `firecrawl`, `chrome-devtools-mcp`, `huggingface-skills`.
- **`lcc`** wrapper installed to `/usr/local/bin` (Linux/macOS) or
  `%USERPROFILE%\.local\bin` (Windows, auto-added to user PATH).

Any existing `settings.json` / `config.json` is backed up before write.

## Switch / add models

```bash
ollama pull qwen3-coder:30b          # pull anything from the library
# edit ~/.claude-code-router/config.json → set both the Providers.models list
# and Router.default/... to the new "ollama,<tag>" reference
ccr restart
```

## Uninstall

- Remove npm packages: `npm uninstall -g @anthropic-ai/claude-code @musistudio/claude-code-router`
- Remove config dirs: `~/.claude-code-router/`, `~/.claude/`
- Remove model data: `ollama rm <model>` then uninstall Ollama via your OS
  package manager.

## Requirements

- 64-bit Linux / macOS / Windows
- ≥ 4 GB free RAM (8 GB+ recommended)
- ~5-25 GB disk for the model
- On Linux: root (for the Ollama service) or a user with `sudo`. The script
  falls back to `nvm` if neither is available for Node.

## How it works

```
claude  ──►  ccr (local proxy)  ──►  ollama (127.0.0.1:11434)
          Anthropic API format   OpenAI-compatible /v1
```

Claude Code itself is unmodified — the router does all the translation. No
keys are sent anywhere. Everything stays on your machine.

## Credits

- [Anthropic Claude Code](https://github.com/anthropics/claude-code)
- [`claude-code-router` by musistudio](https://github.com/musistudio/claude-code-router)
- [Ollama](https://ollama.com)

## License

MIT
