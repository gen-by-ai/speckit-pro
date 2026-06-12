# =============================================================================
# SpecKit Pro — Autonomous Implementation Orchestrator (PowerShell)
# pro-orchestrate.ps1
#
# Windows equivalent of pro-orchestrate.sh
#
# Usage:
#   .\pro-orchestrate.ps1 `
#     -FeatureName "001-my-feature" `
#     -TasksPath "specs\001-my-feature\tasks.md" `
#     -SpecDir "specs\001-my-feature" `
#     [-MaxIterations 20] `
#     [-CheckpointFrequency 3] `
#     [-Model "claude-sonnet-4.6"] `
#     [-AgentCli "copilot"] `
#     [-Resume]
# =============================================================================

param(
    [Parameter(Mandatory=$true)]  [string]$FeatureName,
    [Parameter(Mandatory=$true)]  [string]$TasksPath,
    [Parameter(Mandatory=$true)]  [string]$SpecDir,
    [Parameter(Mandatory=$false)] [int]   $MaxIterations = 20,
    [Parameter(Mandatory=$false)] [int]   $CheckpointFrequency = 3,
    [Parameter(Mandatory=$false)] [string]$Model = "claude-sonnet-4.6",
    [Parameter(Mandatory=$false)] [string]$AgentCli = "copilot",
    [Parameter(Mandatory=$false)] [string]$SubagentModel = "",
    [Parameter(Mandatory=$false)] [string]$EffortPlanning = "xhigh",
    [Parameter(Mandatory=$false)] [string]$EffortExecution = "high",
    [Parameter(Mandatory=$false)] [string]$EffortVerification = "xhigh",
    [Parameter(Mandatory=$false)] [string]$EffortExploratory = "medium",
    [Parameter(Mandatory=$false)] [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Paths ───────────────────────────────────────────────────────────────────
$ProgressFile = Join-Path $SpecDir "progress.md"
$SessionFile  = Join-Path $SpecDir "session.md"
$StatusFile   = Join-Path $SpecDir ".pro-status.json"  # file-based status contract (preferred over stdout scrape)

# ─── Effort / Sub-agent env exports ──────────────────────────────────────────
if ($SubagentModel -ne "") { $env:CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel }
$env:SPECKIT_EFFORT_PLANNING      = $EffortPlanning
$env:SPECKIT_EFFORT_EXECUTION     = $EffortExecution
$env:SPECKIT_EFFORT_VERIFICATION  = $EffortVerification
$env:SPECKIT_EFFORT_EXPLORATORY   = $EffortExploratory

# ─── Helper Functions ─────────────────────────────────────────────────────────
function Write-ProInfo    { Write-Host "[Pro] $args" -ForegroundColor Cyan }
function Write-ProSuccess { Write-Host "[Pro] ✓ $args" -ForegroundColor Green }
function Write-ProWarn    { Write-Host "[Pro] ⚠ $args" -ForegroundColor Yellow }
function Write-ProError   { Write-Host "[Pro] ✗ $args" -ForegroundColor Red }

function Get-TaskCounts {
    # @(...) wrappers are load-bearing: under Set-StrictMode -Version Latest a
    # 0- or 1-match Where-Object result has no .Count and throws, killing the
    # loop on any tasks.md with zero completed tasks.
    $content = Get-Content $TasksPath -ErrorAction SilentlyContinue
    $completed = @($content | Where-Object { $_ -match '^\s*- \[[xX]\]' }).Count
    $total     = @($content | Where-Object { $_ -match '^\s*- \[[ xX]\]' }).Count
    return @{ Completed = $completed; Total = $total }
}

function Test-AllTasksDone {
    $content = Get-Content $TasksPath -ErrorAction SilentlyContinue
    $incomplete = @($content | Where-Object { $_ -match '^\s*- \[ \]' }).Count
    return $incomplete -eq 0
}

function Write-ProgressBar {
    param([int]$Completed, [int]$Total)
    $width = 20
    $filled = if ($Total -gt 0) { [int](($Completed * $width) / $Total) } else { 0 }
    $empty  = $width - $filled
    $bar    = ("█" * $filled) + ("░" * $empty)
    $pct    = if ($Total -gt 0) { [int](($Completed * 100) / $Total) } else { 0 }
    Write-Host "  Progress: $bar $Completed/$Total ($pct%)" -ForegroundColor Cyan
}

# Reads commit.commit_artifacts from pro-config (pure PowerShell section walker —
# mirrors commit_artifacts_enabled() in pro-orchestrate.sh; no external deps).
# Returns $true only on an explicit `commit_artifacts: true`; default $false.
function Test-CommitArtifactsEnabled {
    $root = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) { $root = (Get-Location).Path }
    $candidates = @(
        (Join-Path $root ".specify/extensions/pro/pro-config.local.yml"),
        (Join-Path $root ".specify/extensions/pro/pro-config.yml"),
        (Join-Path $root "pro-config.yml")
    )
    foreach ($cfg in $candidates) {
        if (-not (Test-Path $cfg)) { continue }
        $inSection = $false
        foreach ($line in (Get-Content $cfg -ErrorAction SilentlyContinue)) {
            if ($line -match '^commit:') { $inSection = $true; continue }
            if ($inSection -and $line -match '^\S') { $inSection = $false }
            if ($inSection -and $line -match '^\s*commit_artifacts:\s*(.+)$') {
                $v = ($Matches[1] -replace '#.*$', '').Trim().Trim('"').Trim("'")
                return ($v -eq 'true')
            }
        }
    }
    return $false
}

function New-CheckpointCommit {
    param([string]$Label, [int]$Completed, [int]$Total)
    try {
        $inRepo = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) { Write-ProWarn "Git not available — skipping checkpoint"; return }

        # Scoped staging (audit B3 / FR-007): never blanket-stage — workspace state
        # must stay out of feature-branch commits. .knowledge/features and
        # .knowledge/metrics are ALWAYS excluded (machine-generated); specs/ is
        # excluded unless the operator opted in with commit_artifacts: true.
        # Stage broadly, then DE-STAGE workspace paths: exclude pathspecs naming
        # gitignored (or partly-ignored) dirs make `git add` exit 1 with the
        # addIgnoredFile advice; `git reset -- <path>` is a clean no-op when
        # nothing under the path is staged.
        $destage = @('specs', '.knowledge/features', '.knowledge/metrics')
        if (Test-CommitArtifactsEnabled) { $destage = @('.knowledge/features', '.knowledge/metrics') }
        git add -A -- . 2>$null
        $addExit = $LASTEXITCODE
        git reset -q -- @destage 2>$null
        if ($LASTEXITCODE -ne 0) { git rm -r -q --cached --ignore-unmatch -- @destage 2>$null }
        $global:LASTEXITCODE = $addExit
        if ($LASTEXITCODE -ne 0) {
            $statusLine = @(git status -s 2>$null | Select-Object -First 1) -join ' '
            Write-ProWarn "Checkpoint staging failed: $statusLine"
            return
        }

        $diff = git diff --cached --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            git commit -m "[Pro] Checkpoint: $Label ($Completed/$Total tasks, feature: $FeatureName)" 2>$null
            # Verified commit (audit B4): check the exit code — a silent 2>$null
            # commit failure must never be followed by an unconditional success log.
            if ($LASTEXITCODE -ne 0) {
                $statusSnippet = @(git status -s 2>$null | Select-Object -First 3) -join ' '
                Write-ProError "Checkpoint commit failed: $statusSnippet"
                return
            }
            $hash = git rev-parse --short HEAD
            Write-ProSuccess "Checkpoint committed: $Label ($hash)"

            Add-Content $ProgressFile "### Checkpoint ✓ — $Label"
            Add-Content $ProgressFile "Commit: ``$hash`` | $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
            Add-Content $ProgressFile "State: $Completed/$Total tasks complete."
            Add-Content $ProgressFile ""
        } else {
            Write-ProInfo "Checkpoint skipped — no uncommitted changes"
        }
    } catch {
        Write-ProWarn "Checkpoint failed: $_"
    }
}

function Initialize-ProgressFile {
    if (-not (Test-Path $ProgressFile)) {
        @"
# Implementation Progress Log

Feature: $FeatureName
Started: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')

---
"@ | Set-Content $ProgressFile
        Write-ProInfo "Created progress.md"
    }
}

function Update-Session {
    param([string]$Phase, [string]$Status, [string]$Notes)
    if (-not (Test-Path $SessionFile)) {
        @"
# Session State

Feature: $FeatureName
Created: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')

---
"@ | Set-Content $SessionFile
    }
    @"

## Session Entry — $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')

- **Phase**: $Phase
- **Status**: $Status
- **Notes**: $Notes
"@ | Add-Content $SessionFile
}

# ─── File-based status contract (parity with bash read_status_file) ──────────
# The worker writes {"status":"CONTINUE","reason":"..."} to
# <spec-dir>/.pro-status.json each iteration (pro.loop.md instructs it to). A
# file is an unambiguous channel: it survives CLI cost-footers, mid-answer tag
# mentions and missing tags. When present and parseable it OVERRIDES the stdout
# scrape — except BUDGET_STOP, the CLI's own budget brake, which always wins.
function Read-StatusFile {
    if (-not (Test-Path $StatusFile)) { return "" }
    $d = $null
    try {
        $raw = Get-Content -Raw $StatusFile -ErrorAction Stop
        $d = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return "" }
    if ($null -eq $d) { return "" }
    $status = ""
    $reason = ""
    if ($d.PSObject.Properties['status'] -and $null -ne $d.status) {
        $status = ([string]$d.status).Trim()
    }
    if ($d.PSObject.Properties['reason'] -and $null -ne $d.reason) {
        $reason = (([string]$d.reason) -replace "[`r`n]+", " ").Trim()
    }
    if ($status -eq "") { return "" }
    if ($reason -ne "" -and ($status -eq "BLOCKED" -or $status -eq "ERROR")) {
        return "${status}:${reason}"
    }
    return $status
}

# Resolve-StatusFileOverride <current-signal> — returns the effective signal and
# CONSUMES (deletes) the status file. Mirrors bash apply_status_file_override:
# allowed-status whitelist (incl. MAX_ITERATIONS), stdout BUDGET_STOP always
# wins, unknown file statuses are ignored with a warning. Diagnostics go via
# Write-Host (Write-Pro*) so they never pollute the returned value.
function Resolve-StatusFileOverride {
    param([string]$Current)
    $fileSignal = Read-StatusFile
    Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($fileSignal)) { return $Current }
    $allowed = ($fileSignal -in @('COMPLETE', 'CONTINUE', 'MAX_ITERATIONS', 'BLOCKED', 'ERROR')) -or
               ($fileSignal -like 'BLOCKED:*') -or ($fileSignal -like 'ERROR:*')
    if ($allowed) {
        if ($Current -eq 'BUDGET_STOP') { return $Current }
        if ($fileSignal -ne $Current) {
            Write-ProInfo "Status-file contract: '$fileSignal' (stdout scrape said '$Current')"
        }
        return $fileSignal
    }
    Write-ProWarn "Status file holds unknown status '$fileSignal' — ignoring"
    return $Current
}

function Resolve-AgentFile {
    # Mirror of the bash resolve_agent_file: the old hardcoded .github\agents\
    # path ships in NEITHER the dev repo NOR installed consumers
    # (.extensionignore excludes .github/). First readable candidate wins.
    param([string]$Name)
    $candidates = @()
    if ($env:SPECKIT_PRO_AGENTS_DIR) { $candidates += (Join-Path $env:SPECKIT_PRO_AGENTS_DIR $Name) }
    $extensionRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidates += (Join-Path (Join-Path $extensionRoot "agents") $Name)
    $candidates += (Join-Path ".specify\extensions\pro\agents" $Name)
    $candidates += (Join-Path "agents" $Name)
    $candidates += (Join-Path ".github\agents" $Name)
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Invoke-AgentIteration {
    param([int]$Iter, [string]$ResolvedCli)
    $counts = Get-TaskCounts
    $promptArgs = "feature=$FeatureName tasks=$TasksPath spec-dir=$SpecDir iteration=$Iter max=$MaxIterations checkpoint-freq=$CheckpointFrequency"

    $agentFile = Resolve-AgentFile "speckit.pro.loop.agent.md"
    if (-not $agentFile) {
        Write-ProError "Loop agent definition 'speckit.pro.loop.agent.md' not found in any known layout."
        return @{ Output = ""; Status = "ERROR:agent-definition-missing" }
    }
    $output = ""

    # Consume-before-call (parity with bash run_agent_iteration): a stale status
    # file from a previous iteration must never be read as this iteration's
    # verdict — and must never linger in specs/<feature>/ to be swept into a
    # checkpoint commit when commit_artifacts is enabled.
    Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue

    try {
        switch ($ResolvedCli) {
            "copilot" {
                $output = & $ResolvedCli agent --model $Model $agentFile $promptArgs 2>&1
            }
            "claude" {
                # claude has NO --system-prompt-file and --system-prompt does not
                # take a path: inject the agent definition as the LITERAL prompt
                # contents (parity with the bash orchestrator, FR-001), and grant
                # headless permissions or no edit is ever approved.
                $agentContent = Get-Content -Raw $agentFile
                $output = & $ResolvedCli --print --model $Model `
                    --append-system-prompt $agentContent `
                    --permission-mode acceptEdits `
                    --allowedTools "Read Edit Write Bash(git *) Grep Glob" `
                    $promptArgs 2>&1
            }
            default {
                $output = & $ResolvedCli $agentFile $promptArgs 2>&1
            }
        }
    } catch {
        $output = "ERROR:$_"
    }

    # Extract status tag — take the LAST match (protocol: tag is the final line;
    # the first match is poisoned by any early mention of the protocol).
    $joined = ($output | Out-String)
    $statusMatches = [regex]::Matches($joined, '<pro-status>([^<]+)</pro-status>')
    $statusTag = if ($statusMatches.Count -gt 0) { $statusMatches[$statusMatches.Count - 1].Groups[1].Value } else { "UNKNOWN" }

    # File contract beats the stdout scrape; BUDGET_STOP always wins. The file
    # is consumed (deleted) here whether or not it overrides.
    $statusTag = Resolve-StatusFileOverride $statusTag

    return @{ Output = $output; Status = $statusTag }
}

function Resolve-AgentCli {
    if (Get-Command $AgentCli -ErrorAction SilentlyContinue) { return $AgentCli }
    foreach ($cli in @("copilot", "claude", "gemini", "codex")) {
        if (Get-Command $cli -ErrorAction SilentlyContinue) {
            Write-ProWarn "Agent CLI '$AgentCli' not found; using '$cli'"
            return $cli
        }
    }
    Write-ProError "No agent CLI found. Install one of: copilot, claude, gemini, codex"
    exit 1
}

# ─── Validation ───────────────────────────────────────────────────────────────
if (-not (Test-Path $TasksPath)) {
    Write-ProError "tasks.md not found at: $TasksPath"
    exit 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────
$resolvedCli = Resolve-AgentCli
Initialize-ProgressFile

$iteration = 1
$consecutiveFailures = 0

# Resume mode: detect last iteration
if ($Resume -and (Test-Path $ProgressFile)) {
    $lastIterMatch = Select-String "Iteration (\d+)" $ProgressFile | Select-Object -Last 1
    if ($lastIterMatch) {
        $lastIter = [int]$lastIterMatch.Matches[0].Groups[1].Value
        $iteration = $lastIter + 1
        Write-ProInfo "Resuming from iteration $iteration (previous: $lastIter)"
    }
}

# Check if already complete
if (Test-AllTasksDone) {
    Write-ProSuccess "All tasks already complete — nothing to do!"
    Write-ProInfo "Run /speckit.pro.status for a summary."
    exit 0
}

Update-Session "implement" "started" "Autonomous loop starting at iteration $iteration"

Write-Host ""
$subagentDisplay = if ($SubagentModel -ne "") { $SubagentModel } else { "(same as model)" }
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  SpecKit Pro — Autonomous Implementation Loop        ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  Feature:     $FeatureName" -ForegroundColor Green
Write-Host "║  Max iter:    $MaxIterations | Checkpoints every $CheckpointFrequency" -ForegroundColor Green
Write-Host "║  Model:       $Model" -ForegroundColor Green
Write-Host "║  Sub-agent:   $subagentDisplay" -ForegroundColor Green
Write-Host "║  Agent CLI:   $resolvedCli" -ForegroundColor Green
Write-Host "║  Effort:      plan=$EffortPlanning exec=$EffortExecution verify=$EffortVerification" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# ─── Loop ─────────────────────────────────────────────────────────────────────
while ($iteration -le $MaxIterations) {
    if (Test-AllTasksDone) { break }

    $counts = Get-TaskCounts
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host "  SpecKit Pro │ Loop Iteration $iteration/$MaxIterations" -ForegroundColor Blue
    Write-Host "  Feature: $FeatureName" -ForegroundColor Blue
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-ProgressBar $counts.Completed $counts.Total
    Write-Host ""

    Write-ProInfo "Spawning agent iteration $iteration/$MaxIterations..."
    $result = Invoke-AgentIteration $iteration $resolvedCli

    Write-ProInfo "Agent status: $($result.Status)"

    switch -Wildcard ($result.Status) {
        "COMPLETE" {
            Write-ProSuccess "Agent confirmed all tasks complete!"
            $c = (Get-TaskCounts)
            New-CheckpointCommit "final-complete" $c.Completed $c.Total
            Update-Session "implement" "completed" "All tasks complete after $iteration iterations"
            break
        }
        "CONTINUE" {
            Write-ProSuccess "Iteration $iteration complete — continuing..."
            $consecutiveFailures = 0
        }
        "MAX_ITERATIONS" {
            # The worker's own documented safety tag (pro.loop.md) — parity with
            # bash: honor it as a clean stop (checkpoint + session "paused"),
            # NOT an unknown status feeding the circuit breaker.
            Write-ProWarn "Agent reports MAX_ITERATIONS — honoring its stop request."
            $c = Get-TaskCounts
            New-CheckpointCommit "agent-max-iterations-iter$iteration" $c.Completed $c.Total
            Update-Session "implement" "paused" "Agent emitted MAX_ITERATIONS at iteration $iteration"
            break
        }
        { $_ -like "BLOCKED:*" -or $_ -eq "BLOCKED" } {
            # Bare BLOCKED (no colon) is valid per pro.loop.md — parity with
            # bash's `BLOCKED:*|BLOCKED` arm and its fallback reason.
            $reason = if ($result.Status.Length -gt 8) { $result.Status.Substring(8) } else { "" }
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "(no reason given)" }
            Write-ProWarn "Task blocked: $reason"
            $consecutiveFailures++
            if ($consecutiveFailures -ge 3) {
                Write-ProError "Circuit breaker: $consecutiveFailures consecutive blocks"
                $c = Get-TaskCounts
                New-CheckpointCommit "circuit-breaker-iter$iteration" $c.Completed $c.Total
                Update-Session "implement" "blocked" "Circuit breaker: $reason"
                exit 1
            }
        }
        "ERROR:*" {
            $errMsg = $result.Status.Substring(6)
            Write-ProError "Agent error: $errMsg"
            $consecutiveFailures++
            if ($consecutiveFailures -ge 3) {
                Write-ProError "Circuit breaker: 3 consecutive failures"
                $c = Get-TaskCounts
                New-CheckpointCommit "circuit-breaker-iter$iteration" $c.Completed $c.Total
                Update-Session "implement" "failed" "Circuit breaker: $errMsg"
                exit 1
            }
            Write-ProWarn "Retrying... ($consecutiveFailures/3 failures)"
        }
        default {
            # Parity with the bash orchestrator (P1#6): a crashed CLI, expired
            # auth or rate-limit returns no tag — UNKNOWN must count toward the
            # circuit breaker, not reset it.
            Write-ProWarn "Unknown agent status: '$($result.Status)' — counting toward circuit breaker"
            $consecutiveFailures++
            if ($consecutiveFailures -ge 3) {
                Write-ProError "Circuit breaker: $consecutiveFailures consecutive unparseable statuses"
                $c = Get-TaskCounts
                New-CheckpointCommit "circuit-breaker-iter$iteration" $c.Completed $c.Total
                Update-Session "implement" "failed" "Circuit breaker: $consecutiveFailures consecutive unknown statuses"
                exit 1
            }
            Write-ProWarn "Retrying... ($consecutiveFailures/3 failures)"
        }
    }

    # Loop exits (a `break` inside `switch` only exits the switch, not the loop):
    # COMPLETE and MAX_ITERATIONS both stop iterating; post-loop summary decides
    # the final exit path exactly as the bash orchestrator does.
    if ($result.Status -eq "COMPLETE" -or $result.Status -eq "MAX_ITERATIONS") { break }

    # Periodic checkpoint
    if ($iteration % $CheckpointFrequency -eq 0) {
        $c = Get-TaskCounts
        New-CheckpointCommit "iter$iteration" $c.Completed $c.Total
    }

    $iteration++
}

# ─── Post-loop ────────────────────────────────────────────────────────────────
$finalCounts = Get-TaskCounts

if (Test-AllTasksDone) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  SpecKit Pro — Implementation Complete ✓             ║" -ForegroundColor Green
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "║  Feature: $FeatureName" -ForegroundColor Green
    Write-Host "║  Tasks:   $($finalCounts.Completed)/$($finalCounts.Total) completed" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green

    New-CheckpointCommit "implementation-complete" $finalCounts.Completed $finalCounts.Total
    Update-Session "implement" "completed" "All $($finalCounts.Total) tasks complete in $($iteration - 1) iterations"
    exit 0
} else {
    $remaining = $finalCounts.Total - $finalCounts.Completed
    Write-Host ""
    Write-ProWarn "Maximum iterations ($MaxIterations) reached. $remaining tasks remain."
    Write-ProgressBar $finalCounts.Completed $finalCounts.Total
    Write-ProInfo "Resume with: /speckit.pro.resume"

    New-CheckpointCommit "max-iterations-reached" $finalCounts.Completed $finalCounts.Total
    Update-Session "implement" "paused" "$remaining tasks remain after max iterations"
    exit 1
}
