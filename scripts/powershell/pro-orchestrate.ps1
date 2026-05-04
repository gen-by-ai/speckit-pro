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
    [Parameter(Mandatory=$false)] [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Paths ───────────────────────────────────────────────────────────────────
$ProgressFile = Join-Path $SpecDir "progress.md"
$SessionFile  = Join-Path $SpecDir "session.md"

# ─── Helper Functions ─────────────────────────────────────────────────────────
function Write-ProInfo    { Write-Host "[Pro] $args" -ForegroundColor Cyan }
function Write-ProSuccess { Write-Host "[Pro] ✓ $args" -ForegroundColor Green }
function Write-ProWarn    { Write-Host "[Pro] ⚠ $args" -ForegroundColor Yellow }
function Write-ProError   { Write-Host "[Pro] ✗ $args" -ForegroundColor Red }

function Get-TaskCounts {
    $content = Get-Content $TasksPath -ErrorAction SilentlyContinue
    $completed = ($content | Where-Object { $_ -match '^\s*- \[[xX]\]' }).Count
    $total     = ($content | Where-Object { $_ -match '^\s*- \[[ xX]\]' }).Count
    return @{ Completed = $completed; Total = $total }
}

function Test-AllTasksDone {
    $content = Get-Content $TasksPath -ErrorAction SilentlyContinue
    $incomplete = ($content | Where-Object { $_ -match '^\s*- \[ \]' }).Count
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

function New-CheckpointCommit {
    param([string]$Label, [int]$Completed, [int]$Total)
    try {
        $inRepo = git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) { Write-ProWarn "Git not available — skipping checkpoint"; return }

        git add . 2>$null
        $diff = git diff --cached --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            git commit -m "[Pro] Checkpoint: $Label ($Completed/$Total tasks, feature: $FeatureName)" 2>$null
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

function Invoke-AgentIteration {
    param([int]$Iter, [string]$ResolvedCli)
    $counts = Get-TaskCounts
    $promptArgs = "feature=$FeatureName tasks=$TasksPath spec-dir=$SpecDir iteration=$Iter max=$MaxIterations checkpoint-freq=$CheckpointFrequency"

    $agentFile = ".github\agents\speckit.pro.loop.agent.md"
    $output = ""
    
    try {
        switch ($ResolvedCli) {
            "copilot" {
                $output = & $ResolvedCli agent --model $Model $agentFile $promptArgs 2>&1
            }
            "claude" {
                $output = & $ResolvedCli --model $Model --print --system-prompt $agentFile $promptArgs 2>&1
            }
            default {
                $output = & $ResolvedCli $agentFile $promptArgs 2>&1
            }
        }
    } catch {
        $output = "ERROR:$_"
    }

    # Extract status tag
    $statusMatch = [regex]::Match($output, '<pro-status>([^<]+)</pro-status>')
    $statusTag = if ($statusMatch.Success) { $statusMatch.Groups[1].Value } else { "UNKNOWN" }

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
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  SpecKit Pro — Autonomous Implementation Loop        ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  Feature:    $FeatureName" -ForegroundColor Green
Write-Host "║  Max iter:   $MaxIterations | Checkpoints every $CheckpointFrequency" -ForegroundColor Green
Write-Host "║  Model:      $Model" -ForegroundColor Green
Write-Host "║  Agent CLI:  $resolvedCli" -ForegroundColor Green
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
        "BLOCKED:*" {
            $reason = $result.Status.Substring(8)
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
            Write-ProWarn "Unknown agent status: '$($result.Status)' — treating as CONTINUE"
            $consecutiveFailures = 0
        }
    }

    if ($result.Status -eq "COMPLETE") { break }

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
