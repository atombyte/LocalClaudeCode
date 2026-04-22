<#
    LocalClaudeCode installer — Windows (PowerShell 5.1 / 7+)
    One-liner:
        irm https://raw.githubusercontent.com/atombyte/LocalClaudeCode/main/install.ps1 | iex

    Installs: Ollama, Node.js LTS (if missing), Claude Code CLI,
    claude-code-router; detects RAM/VRAM, pulls a suitable model, writes
    router + plugin configs. After install: `lcc` launches Claude Code wired
    to your local Ollama.
#>
[CmdletBinding()]
param(
    [string] $Model,
    [string] $HomeDir,
    [switch] $NonInteractive,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
if ($Yes) { $NonInteractive = $true }

# Resolve the real user home. $env:USERPROFILE is unreliable (can be
# redirected by launchers, portable setups, or elevated shells). Claude Code
# and Node-based tools read from Node's os.homedir() — use the same source so
# configs land where Claude Code will actually look for them.
function Resolve-HomeDir {
    if ($HomeDir) { return (Resolve-Path -LiteralPath $HomeDir).Path }
    if (Get-Command node -ErrorAction SilentlyContinue) {
        try {
            $h = (& node -e "process.stdout.write(require('os').homedir())" 2>$null).Trim()
            if ($h -and (Test-Path -LiteralPath $h)) { return $h }
        } catch { }
    }
    if ($env:HOME -and (Test-Path -LiteralPath $env:HOME)) { return $env:HOME }
    # Last resort: construct from HOMEDRIVE+HOMEPATH (Windows-standard) before
    # falling back to USERPROFILE, which we consider least trustworthy here.
    if ($env:HOMEDRIVE -and $env:HOMEPATH) {
        $cand = Join-Path $env:HOMEDRIVE $env:HOMEPATH
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $env:USERPROFILE
}

function Say  ([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function OK   ([string]$m) { Write-Host "OK  $m" -ForegroundColor Green }
function Warn ([string]$m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die  ([string]$m) { Write-Host "ERR $m" -ForegroundColor Red; exit 1 }

function Test-Cmd ([string]$n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}

function Ensure-Winget {
    if (Test-Cmd winget) { return $true }
    Warn "winget not found. You may need to install packages manually."
    return $false
}

function Ensure-Node {
    if (Test-Cmd node) {
        $v = (& node -v).TrimStart('v').Split('.')[0]
        if ([int]$v -ge 18) { OK "Node $(& node -v) present."; return }
        Warn "Node < v18; upgrading."
    }
    Say "Installing Node.js LTS..."
    if (Ensure-Winget) {
        winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent -e | Out-Null
        Refresh-Path
    } else {
        Die "Install Node.js LTS manually (https://nodejs.org) and re-run."
    }
    if (-not (Test-Cmd node)) { Die "Node install failed." }
    OK "Node $(& node -v) installed."
}

function Ensure-Ollama {
    if (Test-Cmd ollama) { OK "Ollama present."; return }
    Say "Installing Ollama..."
    if (Ensure-Winget) {
        winget install --id Ollama.Ollama --accept-source-agreements --accept-package-agreements --silent -e | Out-Null
        Refresh-Path
    } else {
        # Fallback: direct MSI/exe install.
        $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
        Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $setup -UseBasicParsing
        Start-Process -FilePath $setup -ArgumentList '/VERYSILENT' -Wait
        Refresh-Path
    }
    if (-not (Test-Cmd ollama)) { Die "Ollama install failed." }
    OK "Ollama installed."
}

function Start-OllamaIfNeeded {
    try {
        Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/version' -UseBasicParsing -TimeoutSec 1 | Out-Null
        return
    } catch { }
    Say "Starting Ollama server..."
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/version' -UseBasicParsing -TimeoutSec 1 | Out-Null
            OK "Ollama running on :11434"
            return
        } catch { }
    }
    Die "Ollama did not become ready on :11434"
}

function Ensure-ClaudeCli {
    if (Test-Cmd claude) { OK "claude CLI present."; return }
    Say "Installing @anthropic-ai/claude-code..."
    & npm install -g '@anthropic-ai/claude-code' | Out-Host
    if ($LASTEXITCODE -ne 0) { Die "npm install of @anthropic-ai/claude-code failed." }
}

function Ensure-Ccr {
    if (Test-Cmd ccr) { OK "ccr present."; return }
    Say "Installing @musistudio/claude-code-router..."
    & npm install -g '@musistudio/claude-code-router' | Out-Host
    if ($LASTEXITCODE -ne 0) { Die "npm install of claude-code-router failed." }
}

function Detect-Hardware {
    $ramGb  = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $vramGb = 0
    try {
        $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 }
        if ($gpus) {
            # AdapterRAM is uint32 — caps at 4 GB on big cards. Try nvidia-smi first.
            if (Test-Cmd nvidia-smi) {
                $mb = (& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) | Select-Object -First 1
                if ($mb) { $vramGb = [int]([int]$mb.Trim() / 1024) }
            }
            if ($vramGb -eq 0) {
                $vramGb = [int](($gpus | Measure-Object -Property AdapterRAM -Maximum).Maximum / 1GB)
            }
        }
    } catch { }
    return @{ Ram = $ramGb; Vram = $vramGb }
}

# size_gb, id, display
$Models = @(
    @{ Size = 2;  Id = 'qwen2.5-coder:3b';  Name = 'Qwen2.5 Coder 3B (tiny)' },
    @{ Size = 5;  Id = 'qwen2.5-coder:7b';  Name = 'Qwen2.5 Coder 7B (balanced)' },
    @{ Size = 9;  Id = 'qwen2.5-coder:14b'; Name = 'Qwen2.5 Coder 14B' },
    @{ Size = 13; Id = 'gpt-oss:20b';       Name = 'GPT-OSS 20B (OpenAI open)' },
    @{ Size = 20; Id = 'qwen2.5-coder:32b'; Name = 'Qwen2.5 Coder 32B (best coding)' },
    @{ Size = 43; Id = 'deepseek-r1:70b';   Name = 'DeepSeek R1 70B (reasoning)' }
)

function Pick-DefaultModel ([int]$ram, [int]$vram) {
    $budget = $ram
    if ($vram -gt 3) { $budget = $vram }
    $choice = 'qwen2.5-coder:3b'
    foreach ($m in $Models) {
        if ($budget -ge ($m.Size + 2)) { $choice = $m.Id }
    }
    return $choice
}

function Prompt-Model ([string]$suggested) {
    if ($Model) { return $Model }
    if ($NonInteractive) { return $suggested }
    Write-Host ""
    Write-Host "Choose a model:" -ForegroundColor White
    for ($i = 0; $i -lt $Models.Count; $i++) {
        $m = $Models[$i]
        $mark = if ($m.Id -eq $suggested) { '*' } else { ' ' }
        '{0}{1}) {2,-22} {3,3} GB  {4}' -f $mark, ($i+1), $m.Id, $m.Size, $m.Name | Write-Host
    }
    Write-Host "  c) custom (any tag from https://ollama.com/library)"
    $ans = Read-Host "Pick number [default: $suggested]"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $suggested }
    if ($ans -match '^(c|C)$') {
        $tag = Read-Host "Ollama model tag"
        if ($tag) { return $tag } else { return $suggested }
    }
    if ($ans -match '^\d+$') {
        $n = [int]$ans
        if ($n -ge 1 -and $n -le $Models.Count) { return $Models[$n-1].Id }
    }
    return $suggested
}

function Write-CcrConfig ([string]$model) {
    $dir = Join-Path $script:HomeResolved '.claude-code-router'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg = Join-Path $dir 'config.json'
    if (Test-Path $cfg) {
        Copy-Item $cfg "$cfg.backup.$((Get-Date).ToFileTime())"
        Warn "Existing ccr config backed up."
    }
    $obj = [ordered]@{
        LOG       = $false
        Providers = @(
            [ordered]@{
                name         = 'ollama'
                api_base_url = 'http://127.0.0.1:11434/v1/chat/completions'
                api_key      = 'ollama'
                models       = @($model)
            }
        )
        Router = [ordered]@{
            default     = "ollama,$model"
            background  = "ollama,$model"
            think       = "ollama,$model"
            longContext = "ollama,$model"
            webSearch   = "ollama,$model"
        }
    }
    $json = ($obj | ConvertTo-Json -Depth 10)
    [System.IO.File]::WriteAllText($cfg, $json, [System.Text.UTF8Encoding]::new($false))
    OK "Wrote $cfg"
}

function Merge-ClaudeSettings {
    $dir = Join-Path $script:HomeResolved '.claude'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg = Join-Path $dir 'settings.json'

    $preseed = [ordered]@{
        enabledPlugins = [ordered]@{
            'superpowers@claude-plugins-official'          = $true
            'context7@claude-plugins-official'             = $true
            'claude-mem@thedotmack'                        = $true
            'ralph-loop@claude-plugins-official'           = $true
            'feature-dev@claude-plugins-official'          = $true
            'code-review@claude-plugins-official'          = $true
            'code-simplifier@claude-plugins-official'      = $true
            'frontend-design@claude-plugins-official'      = $true
            'claude-md-management@claude-plugins-official' = $true
            'firecrawl@claude-plugins-official'            = $true
            'chrome-devtools-mcp@claude-plugins-official'  = $true
            'huggingface-skills@claude-plugins-official'   = $true
        }
        extraKnownMarketplaces = [ordered]@{
            'claude-plugins-official' = [ordered]@{
                source = [ordered]@{ source = 'github'; repo = 'anthropics/claude-plugins-official' }
            }
            'thedotmack' = [ordered]@{
                source     = [ordered]@{ source = 'github'; repo = 'thedotmack/claude-mem' }
                autoUpdate = $true
            }
            'superpowers-marketplace' = [ordered]@{
                source = [ordered]@{ source = 'github'; repo = 'obra/superpowers-marketplace' }
            }
        }
        autoUpdatesChannel = 'latest'
    }

    if (Test-Path $cfg) {
        Copy-Item $cfg "$cfg.backup.$((Get-Date).ToFileTime())"
        $existing = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $existing.enabledPlugins) {
            Add-Member -InputObject $existing -NotePropertyName enabledPlugins -NotePropertyValue (New-Object psobject) -Force
        }
        foreach ($k in $preseed.enabledPlugins.Keys) {
            Add-Member -InputObject $existing.enabledPlugins -NotePropertyName $k -NotePropertyValue $true -Force
        }
        if (-not $existing.extraKnownMarketplaces) {
            Add-Member -InputObject $existing -NotePropertyName extraKnownMarketplaces -NotePropertyValue (New-Object psobject) -Force
        }
        foreach ($k in $preseed.extraKnownMarketplaces.Keys) {
            Add-Member -InputObject $existing.extraKnownMarketplaces -NotePropertyName $k -NotePropertyValue $preseed.extraKnownMarketplaces[$k] -Force
        }
        if (-not $existing.autoUpdatesChannel) {
            Add-Member -InputObject $existing -NotePropertyName autoUpdatesChannel -NotePropertyValue 'latest' -Force
        }
        $json = $existing | ConvertTo-Json -Depth 20
    } else {
        $json = $preseed | ConvertTo-Json -Depth 20
    }
    [System.IO.File]::WriteAllText($cfg, $json, [System.Text.UTF8Encoding]::new($false))
    OK "Preseeded $cfg (marketplaces + plugins)"
}

function Install-LccWrapper {
    $dir = Join-Path $script:HomeResolved '.local\bin'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cmd = Join-Path $dir 'lcc.cmd'
    $content = "@echo off`r`nccr code %*`r`n"
    [System.IO.File]::WriteAllText($cmd, $content, [System.Text.ASCIIEncoding]::new())
    OK "Installed wrapper: $cmd"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not ($userPath -split ';' | Where-Object { $_ -ieq $dir })) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$dir"), 'User')
        Warn "Added $dir to user PATH. Open a new terminal to use 'lcc'."
    }
}

# ----- main -----
Say "LocalClaudeCode installer starting"
Ensure-Node
# HomeResolved needs Node (uses os.homedir()), so resolve after Ensure-Node.
$script:HomeResolved = Resolve-HomeDir
OK "Home dir: $script:HomeResolved"
if ($script:HomeResolved -ne $env:USERPROFILE) {
    Warn "USERPROFILE ($env:USERPROFILE) differs from detected home — using detected home."
}
Ensure-Ollama
Refresh-Path
Start-OllamaIfNeeded
Ensure-ClaudeCli
Ensure-Ccr

$hw = Detect-Hardware
Say ("Detected RAM: {0} GB | GPU VRAM: {1} GB" -f $hw.Ram, $hw.Vram)
$default = Pick-DefaultModel -ram $hw.Ram -vram $hw.Vram
$chosen  = Prompt-Model -suggested $default
OK "Chosen model: $chosen"

Say "Pulling $chosen (may take several minutes)..."
& ollama pull $chosen
if ($LASTEXITCODE -ne 0) { Die "ollama pull failed." }

Write-CcrConfig -model $chosen
Merge-ClaudeSettings
Install-LccWrapper

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host @"

Start your local Claude Code:
  lcc                    # wrapper (same as: ccr code)
  ccr code               # or invoke the router directly

The router (ccr) proxies Claude Code's Anthropic API traffic to Ollama at
127.0.0.1:11434 — no cloud calls, no subscription.

Plugins preseeded (superpowers, context7, claude-mem, ralph-loop, ...).
On first launch Claude Code may ask you to trust each marketplace — accept.

Switch model later: edit $($script:HomeResolved)\.claude-code-router\config.json
                    then run: ccr restart
Pull more models:   ollama pull <name>   (https://ollama.com/library)
"@
