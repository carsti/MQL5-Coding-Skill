#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\mql5-coding\scripts\TesterProcessJob.cs')
$checks=0
function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) {throw $Message}
    $script:checks++
}
function Read-Case([string]$Text,[int]$Limit,[bool]$Capture,[bool]$TooLarge) {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Text)
    $stream=New-Object IO.MemoryStream(,$bytes)
    $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8)
    try {
        $result=[Mql5Coding.JobProcessLaunch]::ReadProbeOutputAsync($reader,$Limit,$Capture).GetAwaiter().GetResult()
        Check ($result.LimitExceeded -eq $TooLarge) 'Output-limit decision disagrees with the specified character limit.'
        if ($Capture -and -not $TooLarge) {Check ($result.Text -ceq $Text) 'Accepted stdout was changed.'}
        else {Check ($null -eq $result.Text) 'Discarded/oversized output text was retained.'}
    } finally {$reader.Dispose();$stream.Dispose()}
}
Read-Case '' 4 $true $false
Read-Case 'abc' 4 $true $false
Read-Case 'abcd' 4 $true $false
Read-Case 'abcde' 4 $true $true
Read-Case ('x'*16384) 8192 $true $true
$unicode=[string][char]0xE9+[char]0x6F22+[char]0xD83D+[char]0xDE00
Read-Case $unicode 4 $true $false
Read-Case ($unicode+'x') 4 $true $true
Read-Case 'abcd' 4 $false $false
Read-Case 'abcde' 4 $false $true
$invalid=$false
$stream=New-Object IO.MemoryStream
$reader=New-Object IO.StreamReader($stream)
try {try {[void][Mql5Coding.JobProcessLaunch]::ReadProbeOutputAsync($reader,0,$true).GetAwaiter().GetResult()} catch {$invalid=$true}}
finally {$reader.Dispose();$stream.Dispose()}
Check $invalid 'An invalid output limit was accepted.'
Write-Output ('HEALTH_PROBE_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
