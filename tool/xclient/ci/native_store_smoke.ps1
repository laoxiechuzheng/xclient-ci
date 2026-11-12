param(
    [Parameter(Mandatory)][ValidateSet('prepare','run')][string]$Mode,
    [string]$Output,
    [string]$State,
    [string]$Bundle
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'github_hosted_windows_required'}
$script=Join-Path $PSScriptRoot 'native_store_smoke.py'
$arguments=@($script,$Mode,'--platform','windows')
if($Mode -eq 'prepare'){$arguments+=@('--output',$Output)}else{$arguments+=@('--state',$State,'--bundle',$Bundle)}
& python @arguments
exit $LASTEXITCODE
