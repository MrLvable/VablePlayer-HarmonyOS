param(
  [Parameter(Mandatory=$true)]
  [string]$DevEcoHome
)

$ErrorActionPreference = 'Stop'
$taskNode = Join-Path $DevEcoHome 'tools\node\node.exe'
$taskHvigor = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.js'
if (!(Test-Path -LiteralPath $taskNode) -or !(Test-Path -LiteralPath $taskHvigor)) {
  throw 'DevEco Studio tools not found. Pass -DevEcoHome with your installation directory.'
}

Push-Location $PSScriptRoot
try {
  $env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
  $env:OHOS_BASE_SDK_HOME = Join-Path $DevEcoHome 'sdk'
  $env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
  $env:PATH = (Join-Path $DevEcoHome 'tools\node') + ';' + (Join-Path $DevEcoHome 'jbr\bin') + ';' + $env:PATH
  & $taskNode $taskHvigor --mode module -p module=entry@default -p product=default assembleHap --no-daemon
  $taskExitCode = $LASTEXITCODE
} finally {
  Pop-Location
}
exit $taskExitCode
