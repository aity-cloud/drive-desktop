# PowerShell twin of scripts/craft.sh for the Windows (and macOS) runners,
# modelled on upstream's .github/workflows/.craft.ps1: run CraftMaster with
# the Pin's own .craft.ini from the materialised tree plus our CI override.
#
# Required environment:
#   AITY_MATERIALIZED  absolute path of the materialised tree
#   CRAFT_TARGET       Craft target, e.g. windows-cl-msvc2022-x86_64

if ($IsWindows) {
    $python = (python -c "import sys; print(sys.executable)")
} else {
    $python = (Get-Command python3).Source
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $myInvocation.MyCommand.Definition)

if (-not $env:AITY_MATERIALIZED) { throw "AITY_MATERIALIZED is not set" }
if (-not $env:CRAFT_TARGET) { throw "CRAFT_TARGET is not set" }

$command = @("${env:HOME}${env:USERPROFILE}/craft/CraftMaster/CraftMaster/CraftMaster.py",
             "--config", "${env:AITY_MATERIALIZED}/.craft.ini",
             "--config-override", "${RepoRoot}/ci/craft-override.ini",
             "--target", "${env:CRAFT_TARGET}",
             "--variables", "WORKSPACE=${env:HOME}${env:USERPROFILE}/craft") + $args

Write-Host "Exec: ${python} ${command}"

& $python @command
if ($LASTEXITCODE -ne 0) {
    exit 1
}
