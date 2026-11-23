#requires -Version 7.5
<#
.SYNOPSIS
    Runs the BCQuality review on a developer's machine before the push, and writes the findings to a markdown report.
.DESCRIPTION
    The same review as the pipeline, minus the two PR-bound steps:
      - the Context job (reads the PR, takes settings from the target branch) -> Get-PrContext.ps1 -SettingsFile with settings written here
      - Publish-PrReview.ps1 (posts threads)                                  -> bcquality.md, built from publish-plan.json
    For Linux and macOS. On Windows use ADO-BCQuality-Windows, which starts the agent CLI without the npm shim.
    It reviews the committed HEAD against the merge base with origin/<Target>, which is the diff a PR into <Target> gets.
    Nothing is posted and no Azure DevOps token is used.

    Authentication (claude-code): the developer's own Claude Code login by default (BCQ_CLAUDE_AUTH=subscription, see
    Providers/Claude/Adapter.ps1), or ANTHROPIC_API_KEY with -UseApiKey. A subscription run uses the plan's usage limits.
.EXAMPLE
    pwsh -NoProfile -File scripts/Invoke-LocalReview.ps1 -RepoDir ~/src/client-repo -Target test
#>
[CmdletBinding()]
param(
    [string] $RepoDir = (Get-Location).Path,
    [string] $Target = 'main',                         # branch the PR will target
    [string] $OutDir,                                  # default: <temp>/bcquality-local/<repo>-<stamp>
    [string] $BCQualityVersion = '1.9',
    [string] $EnabledLayers = 'microsoft,community',
    [string] $Model = 'claude-sonnet-5-5',
    [string] $ExtraSettingsJson = '',                  # a JSON object merged over the settings (see New-ReviewSettings.ps1)
    [string] $AgentCacheDir = (Join-Path ([IO.Path]::GetTempPath()) 'bcquality-local'),
    [switch] $UseApiKey,                               # authenticate with ANTHROPIC_API_KEY instead of the Claude Code login
    [switch] $AllowDirty,                              # review HEAD even with uncommitted tracked changes (they are not reviewed)
    [switch] $ListOnly                                 # print the files that would be reviewed and stop
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$scriptsRoot = Split-Path $PSScriptRoot -Parent
$schema = Join-Path $scriptsRoot 'schemas/bcquality-ado.settings.schema.json'
$packageJson = Join-Path $scriptsRoot 'package.json'

function Get-SetVariable([object[]] $Lines, [string] $Name) {
    # The shared scripts publish values as ##vso[task.setvariable] lines; read them back when running outside a pipeline.
    $hit = @($Lines | ForEach-Object { "$_" } | Where-Object { $_ -match "##vso\[task\.setvariable variable=$([regex]::Escape($Name))[;\]]" }) | Select-Object -Last 1
    if ($hit) { ($hit -split '\]', 2)[1].Trim() }
}
function Write-Lines([object[]] $Lines) { $Lines | Where-Object { "$_" -notmatch '^##vso\[' } | ForEach-Object { Write-Host $_ } }

if ($env:TF_BUILD -eq 'True') { throw 'Invoke-LocalReview.ps1 is for developer machines. Pipelines use templates/bcquality-pr-review.yml.' }
if ($IsWindows) { throw 'Invoke-LocalReview.ps1 here is for Linux and macOS. On Windows use the ADO-BCQuality-Windows repository.' }
$RepoDir = (Resolve-Path -LiteralPath (git -C $RepoDir rev-parse --show-toplevel)).Path
$head = (git -C $RepoDir rev-parse HEAD).Trim()
$dirty = @(git -C $RepoDir status --porcelain --untracked-files=no)
if ($dirty.Count -and -not $AllowDirty) { throw "Uncommitted changes in $RepoDir. The review reads the committed HEAD: commit first, or pass -AllowDirty." }

git -C $RepoDir fetch --quiet origin $Target
if ($LASTEXITCODE -ne 0) { throw "git fetch origin $Target failed." }
$mergeBase = (git -C $RepoDir merge-base "origin/$Target" $head).Trim()
$changed = @(git -C $RepoDir diff --name-only --no-renames $mergeBase $head | Where-Object { $_ -match '\.al$|(^|/)app\.json$' })
Write-Host "Reviewing $($head.Substring(0, 8)) against origin/$Target (merge base $($mergeBase.Substring(0, 8))): $($changed.Count) AL/app.json file(s)"
$changed | ForEach-Object { Write-Host "  $_" }
if ($ListOnly -or $changed.Count -eq 0) { return }

if (-not $OutDir) { $OutDir = Join-Path $AgentCacheDir "$(Split-Path $RepoDir -Leaf)-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
$work = Join-Path $OutDir 'work'
$review = Join-Path $OutDir 'review'
New-Item -ItemType Directory -Path $work, $review -Force | Out-Null

# Authentication for every agent call of this run.
if ($UseApiKey) {
    if (-not $env:ANTHROPIC_API_KEY) { throw '-UseApiKey was given but ANTHROPIC_API_KEY is not set.' }
    Remove-Item Env:BCQ_CLAUDE_AUTH -ErrorAction SilentlyContinue
}
else { $env:BCQ_CLAUDE_AUTH = 'subscription' }

# The pinned CLI from package.json, installed once per version into the cache (private prefix, no global npm change).
# This repo's adapter starts `claude` from PATH, so the prefix's bin folder goes first.
$pinned = (Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json).dependencies.'@anthropic-ai/claude-code'
if ($pinned -notmatch '^\d+\.\d+\.\d+$') { throw "package.json must pin @anthropic-ai/claude-code to an exact version, found '$pinned'." }
$agentRoot = Join-Path $AgentCacheDir "agent-claude-code-$pinned"
$agentBin = Join-Path $agentRoot 'node_modules/.bin'
if (-not (Test-Path -LiteralPath (Join-Path $agentBin 'claude'))) {
    Write-Host "Installing @anthropic-ai/claude-code@$pinned into $agentRoot"
    New-Item -ItemType Directory -Path $agentRoot -Force | Out-Null
    & npm install --prefix $agentRoot --ignore-scripts=false "@anthropic-ai/claude-code@$pinned" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $agentBin 'claude'))) { throw "npm install of @anthropic-ai/claude-code@$pinned failed." }
}
$env:PATH = "$agentBin$([IO.Path]::PathSeparator)$env:PATH"

# Settings, context and BCQuality, as the pipeline does, without the PR.
$settingsFile = Join-Path $work 'settings.json'
& (Join-Path $PSScriptRoot 'New-ReviewSettings.ps1') -OutFile $settingsFile -BCQualityVersion $BCQualityVersion -EnabledLayers $EnabledLayers `
    -Provider 'claude-code' -Model $Model -LeafModel $Model -ExtraSettingsJson $ExtraSettingsJson -SchemaPath $schema
$contextDir = Join-Path $work 'context'
Write-Lines (& (Join-Path $PSScriptRoot 'Get-PrContext.ps1') -RepoDir $RepoDir -OutDir $contextDir -TargetBranch "refs/heads/$Target" -HeadSha $head `
        -AuthorIdentity ([string](git -C $RepoDir config user.email)) -SchemaPath $schema -SettingsFile $settingsFile 6>&1)
$contextPath = Join-Path $contextDir 'context.json'
$context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json -Depth 50
if ($context.skipped) { Write-Host "Review skipped: $($context.skipReason)"; return }
# BCQuality, as templates/steps/setup-bcquality.yml does it: clone the pinned release outside the repo, prune knowledge by the
# settings, build the index. No token: the clone uses the developer's own git credentials (a fork in your own organization).
. (Join-Path $PSScriptRoot 'BCQualityRepo.ps1')
. (Join-Path $PSScriptRoot 'KnowledgePolicy.ps1')
$bcqRoot = Join-Path $work 'bcquality'
if (Test-Path -LiteralPath $bcqRoot) { Remove-Item -LiteralPath $bcqRoot -Recurse -Force }
$null = Invoke-BCQualityClone -Repo $context.settings.BCQuality.repo -Version $context.settings.BCQuality.version -Root $bcqRoot
$knowledge = $context.settings.BCQuality.PSObject.Properties['knowledge']
$allow = @(if ($knowledge) { $knowledge.Value.allow })
$deny = @(if ($knowledge) { $knowledge.Value.deny })
$null = Invoke-KnowledgePolicy -BCQualityRoot $bcqRoot -EnabledLayers @($context.settings.BCQuality.enabledLayers) -Allow $allow -Deny $deny
$bcqCommit = (git -C $bcqRoot rev-parse HEAD).Trim()

# The review step itself, unchanged.
& (Join-Path $PSScriptRoot 'Run-Generate.ps1') -ContextPath $contextPath -ToolsDir $PSScriptRoot -RepoDir $RepoDir -OutDir $review `
    -BCQualityRoot $bcqRoot -BCQualityCommit $bcqCommit -AgentVersion $pinned -RunUrl ''

# The threads Publish-PrReview.ps1 would post, as markdown.
$plan = Get-Content -LiteralPath (Join-Path $review 'publish-plan.json') -Raw | ConvertFrom-Json -Depth 50
$items = @($plan.items | Sort-Object filePath, line)
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# BCQuality local review"); $md.Add('')
$md.Add("Head ``$head`` against ``origin/$Target`` (merge base ``$mergeBase``). BCQuality $BCQualityVersion at ``$bcqCommit``, Claude Code $pinned, $Model, $(if ($UseApiKey) { 'API key' } else { 'Claude Code login' }).")
$md.Add('')
foreach ($it in $items) { $md.Add("## $($it.filePath):$($it.line)"); $md.Add(''); $md.Add([string]$it.content); $md.Add('') }
$md.Add('## Summary'); $md.Add(''); $md.Add([string]$plan.summary.content)
$report = Join-Path $OutDir 'bcquality.md'
Set-Content -LiteralPath $report -Value ($md -join "`n") -Encoding utf8
Write-Host "Report: $report ($($items.Count) inline finding(s), outcome $($plan.outcome))"
