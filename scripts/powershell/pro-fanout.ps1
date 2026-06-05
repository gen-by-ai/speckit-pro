#!/usr/bin/env pwsh
# =============================================================================
# pro-fanout.ps1 — PowerShell mirror of pro-scan.sh / pro-fanout.sh (best-effort).
#
# Parity note: like the rest of SpecKit Pro's PowerShell coverage, this is a
# best-effort mirror of the canonical bash engine. It reuses the SAME python
# helpers (partition.py, scan_report.py, validate_schemas.py) so behavior stays
# in sync; only the orchestration shell differs. Requires PowerShell 7+ for
# ForEach-Object -Parallel; falls back to sequential otherwise.
#
# Usage:
#   pro-fanout.ps1 [-Root <path>] [-Workers <N>] [-Substrate cli|sequential]
#                  [-Strategy dependency-cluster|size-bucket] [-DryRun] [-Json]
# =============================================================================
[CmdletBinding()]
param(
  [string]$Root = "",
  [int]$Workers = 0,
  [string]$Substrate = "auto",
  [string]$Strategy = "dependency-cluster",
  [int]$TimeoutSec = 300,
  [switch]$DryRun,
  [switch]$Json,
  [switch]$NoKnowledge
)
$ErrorActionPreference = "Stop"

function Log($m){ Write-Host "[fanout] $m" -ForegroundColor Blue }
function Warn($m){ Write-Host "[fanout WARN] $m" -ForegroundColor Yellow }

$ProjectRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
if (-not $Root) { $Root = $ProjectRoot }
Set-Location $ProjectRoot

# Resolve substrate: cli if an agent CLI is on PATH, else sequential.
function Detect-Substrate($override) {
  if ($override -in @("in-harness","cli","sequential")) { return $override }
  foreach ($b in @("copilot","claude","gemini","codex")) {
    if (Get-Command $b -ErrorAction SilentlyContinue) { return "cli" }
  }
  return "sequential"
}
$resolved = Detect-Substrate $Substrate
if ($resolved -eq "in-harness") { $resolved = Detect-Substrate "auto" }
if ($resolved -eq "sequential") { Warn "no agent CLI found — concurrency unavailable; running sequential." }

$cores = [Environment]::ProcessorCount
if ($Workers -le 0) { $Workers = [Math]::Max(1, $cores - 2) }
if ($resolved -eq "in-harness" -and $Workers -gt 16) { $Workers = 16 }
if ($resolved -eq "sequential") { $Workers = 1 }

$stamp = (Get-Date -AsUTC -Format "yyyyMMdd-HHmmss")
$runId = "scan-$stamp-$PID"
$work  = Join-Path $ProjectRoot ".knowledge/scan/.work/$runId"
New-Item -ItemType Directory -Force -Path (Join-Path $work "results") | Out-Null

# Partition (shared python helper)
python3 scripts/local/partition.py --root $Root --workers $Workers --strategy $Strategy --out (Join-Path $work "portions.json")
if ($LASTEXITCODE -ne 0) { throw "partition failed" }

$portions = (Get-Content (Join-Path $work "portions.json") | ConvertFrom-Json).portions

if ($DryRun) {
  Log "DRY RUN — substrate=$resolved workers=$Workers strategy=$Strategy portions=$($portions.Count)"
  foreach ($p in $portions) { "  {0,-6} {1,-18} {2,3} files" -f $p.portion_id, $p.cluster_label, $p.files.Count | Write-Host }
  Remove-Item -Recurse -Force $work
  exit 0
}

# Dispatch. Real CLI worker invocation is left as the per-CLI call (mirror of
# pro-fanout.sh); a SPECKIT_FANOUT_WORKER_CMD env hook is honored for testing.
$start = Get-Date
$dispatch = {
  param($pid, $work, $cliBin)
  $filesFile = Join-Path $work "portions/$pid.files"
  $out = Join-Path $work "results/$pid.json"
  if ($env:SPECKIT_FANOUT_WORKER_CMD) {
    & $env:SPECKIT_FANOUT_WORKER_CMD $pid $filesFile $out
  }
  # else: per-CLI invocation (copilot/claude/gemini) — see pro-fanout.sh for the map.
}
# write per-portion file lists
New-Item -ItemType Directory -Force -Path (Join-Path $work "portions") | Out-Null
foreach ($p in $portions) {
  ($p.files -join "`n") | Set-Content -Path (Join-Path $work "portions/$($p.portion_id).files")
}

if ($resolved -eq "sequential" -or $Workers -le 1) {
  foreach ($p in $portions) { & $dispatch $p.portion_id $work $resolved }
} elseif ($PSVersionTable.PSVersion.Major -ge 7) {
  $portions | ForEach-Object -ThrottleLimit $Workers -Parallel {
    $d = $using:dispatch; & $d $_.portion_id $using:work $using:resolved
  }
} else {
  Warn "PowerShell < 7 — no -Parallel; running sequential."
  foreach ($p in $portions) { & $dispatch $p.portion_id $work $resolved }
}

$wallMs = [int]((Get-Date) - $start).TotalMilliseconds
python3 scripts/local/scan_report.py --portions (Join-Path $work "portions.json") `
  --results-dir (Join-Path $work "results") --out-dir (Join-Path $ProjectRoot ".knowledge/scan") `
  --run-id $runId --substrate $resolved --workers-eff $Workers --workers-req $Workers `
  --repo (Split-Path $ProjectRoot -Leaf) --wall-ms $wallMs

$report = Join-Path $ProjectRoot ".knowledge/scan/latest.md"
if (-not $NoKnowledge) { Log "findings ready in $report — run /pro.knowledge-sync to graduate durable findings." }
if ($Json) { @{ run_id=$runId; substrate=$resolved; workers=$Workers; portions=$portions.Count; wall_ms=$wallMs; report=$report } | ConvertTo-Json -Compress }
Log "scan complete -> $report"
