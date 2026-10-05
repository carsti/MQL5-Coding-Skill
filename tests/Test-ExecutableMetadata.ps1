#Requires -Version 5.1
[CmdletBinding()]
param([string]$GenuineMetaEditorPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scripts=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'WindowsExecutableMetadata.ps1')
. (Join-Path $scripts 'ToolkitSupport.ps1')
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$temporaryParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $temporaryParent ('mql5-metadata-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Condition,[string]$Message) {if (-not $Condition) {throw $Message};$script:checks++}
function Run([string]$Script,[string[]]$Arguments) {
    return Invoke-ToolkitProcess $hostExe (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts $Script))+$Arguments) $testRoot 60
}
function Long-Directory([string]$Root) {
    $path=$Root
    while ((Join-Path $path 'metaeditor64.exe').Length -le 290) {$path=Join-Path $path 'metadata-component'}
    [IO.Directory]::CreateDirectory((ConvertTo-Mql5ExtendedWindowsPath $path)) | Out-Null
    return $path
}
function Copy-Executable([string]$Source,[string]$Destination) {
    [IO.File]::Copy((ConvertTo-Mql5ExtendedWindowsPath $Source),(ConvertTo-Mql5ExtendedWindowsPath $Destination))
}
$beforeMode=$env:FAKE_METAEDITOR_MODE
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $short=Join-Path $testRoot 'short';[IO.Directory]::CreateDirectory($short) | Out-Null
    $editor=Join-Path $short 'metaeditor64.exe'
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) (Join-Path $PSScriptRoot 'FakeMetaEditor.cs')
    Check ($LASTEXITCODE -eq 0) 'The synthetic compiler must build.'
    Copy-Executable $editor (Join-Path $short 'terminal64.exe')
    $long=Long-Directory (Join-Path $testRoot 'long')
    $longEditor=Join-Path $long 'metaeditor64.exe'
    $longTerminal=Join-Path $long 'terminal64.exe'
    Copy-Executable $editor $longEditor;Copy-Executable $editor $longTerminal
    Check ((ConvertTo-Mql5ExtendedWindowsPath $editor) -ceq ('\\?\'+$editor)) 'Drive normalization is incorrect.'
    Check ((ConvertTo-Mql5ExtendedWindowsPath ('\\?\'+$longEditor)) -ceq ('\\?\'+$longEditor)) 'Extended drive paths must not receive another prefix.'
    Check ((ConvertTo-Mql5ExtendedWindowsPath '\\server\share\metaeditor64.exe') -ceq '\\?\UNC\server\share\metaeditor64.exe') 'UNC normalization is incorrect.'
    Check ((ConvertTo-Mql5ExtendedWindowsPath '\\?\UNC\server\share\metaeditor64.exe') -ceq '\\?\UNC\server\share\metaeditor64.exe') 'Extended UNC normalization is incorrect.'
    foreach ($path in @($editor,$longEditor,('\\?\'+$longEditor),$longTerminal)) {
        $info=Get-Mql5ExecutableVersionInfo $path
        Check ($info.FileVersion -ceq '5.0.0.1234' -and $info.FileMajorPart -eq 5 -and $info.FilePrivatePart -eq 1234) 'Version and build must survive long and extended paths.'
    }
    $badDirectory=Join-Path $testRoot 'bad';[IO.Directory]::CreateDirectory($badDirectory) | Out-Null
    $badEditor=Join-Path $badDirectory 'metaeditor64.exe';[IO.File]::WriteAllText($badEditor,'no Windows version resource')
    foreach ($path in @((Join-Path $testRoot 'missing.exe'),$badEditor)) {
        $message='';try {Get-Mql5ExecutableVersionInfo $path | Out-Null} catch {$message=$_.Exception.Message}
        Check ($message -match 'Windows executable metadata is unavailable') 'Unavailable metadata must fail explicitly.'
    }
    $source=Join-Path $testRoot 'Fixture.mq5';[IO.File]::WriteAllText($source,'void OnTick() {}')
    $profile=Join-Path $testRoot 'profile.json'
    $create=Run 'New-Mql5ProjectProfile.ps1' @('-ProfilePath',$profile,'-Name','Metadata','-ProjectRoot',$testRoot,'-Entrypoints',$source,'-MetaEditorPath',$longEditor)
    Check ($create.exit_code -eq 0) ('Long-path profile creation failed: '+$create.stderr+$create.stdout)
    $data=Read-Mql5ReleaseJson $profile
    $data.tester=@{entrypoint='Fixture.mq5';terminal_path=$longTerminal;terminal_data_path=$testRoot;set_path=$null;use_expert_defaults=$true;timeout_seconds=10;settings=@{symbol='EURUSD';period='M1';from_date='2025.01.12';to_date='2025.02.28';model=0;deposit='100000';currency='USD';leverage=100;execution_mode=0}}
    [IO.File]::WriteAllText($profile,($data | ConvertTo-Json -Depth 8))
    $validate=Run 'Invoke-Mql5Project.ps1' @('-ProfilePath',$profile)
    Check ($validate.exit_code -eq 0) ('Long-path tester selection failed: '+$validate.stderr+$validate.stdout)
    $health=Run 'Test-Mql5Environment.ps1' @('-WorkspaceRoot',$testRoot,'-CodexHome',$testRoot,'-SkillRoot',(Split-Path -Parent $scripts),'-MetaEditorPath',$longEditor,'-Json')
    $report=$health.stdout | ConvertFrom-Json
    Check ($report.metaeditor.available -and $report.metaeditor.candidates[0].file_version -ceq '5.0.0.1234' -and $report.metaeditor.candidates[0].build -eq 1234 -and $report.metaeditor.selected_path -ceq $longEditor) 'Discovery must retain the actual version, build, and canonical path.'
    $env:FAKE_METAEDITOR_MODE='success'
    # Metadata support is independent of native compiler path/lease limits.
    # Exercise an actual receipt through the synthetic compiler at a supported
    # execution path; the long-path resource queries above never launch an EA.
    $compile=Run 'Compile-Mql5.ps1' @('-SourcePath',$source,'-MetaEditorPath',$editor,'-SuppressLogOutput')
    Check ($compile.exit_code -eq 0 -and $compile.cleanup_verified) ('Synthetic compilation failed: '+$compile.stderr+$compile.stdout)
    $receiptPath=[regex]::Match($compile.stdout,'(?m)^MQL5_COMPILE_RECEIPT=(.+)\r?$').Groups[1].Value.Trim()
    $receipt=Read-Mql5ReleaseJson $receiptPath
    Check ($receipt.status -ceq 'success' -and $receipt.compiler.file_version -ceq '5.0.0.1234' -and $receipt.compiler.build -eq 1234 -and $receipt.compiler.path -ceq $editor -and $receipt.compiler.sha256 -ceq (Get-Mql5ReleaseHash $editor)) 'A successful receipt must record the actual compiler identity.'
    $failed=Run 'Compile-Mql5.ps1' @('-SourcePath',$source,'-MetaEditorPath',$badEditor,'-SuppressLogOutput')
    Check ($failed.exit_code -eq 2 -and ($failed.stdout+$failed.stderr) -match 'Windows executable metadata is unavailable') 'Compilation must reject missing version metadata as a tooling failure.'
    $invalid=Run 'New-Mql5ProjectProfile.ps1' @('-ProfilePath',(Join-Path $testRoot 'bad-profile.json'),'-Name','Bad','-ProjectRoot',$testRoot,'-Entrypoints',$source,'-MetaEditorPath',$badEditor)
    Check ($invalid.exit_code -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $testRoot 'bad-profile.json'))) 'Profile validation must reject missing metadata before writing a profile.'
    $health=Run 'Test-Mql5Environment.ps1' @('-WorkspaceRoot',$testRoot,'-CodexHome',$testRoot,'-SkillRoot',(Split-Path -Parent $scripts),'-MetaEditorPath',$badEditor,'-Json')
    $report=$health.stdout | ConvertFrom-Json
    Check (-not $report.metaeditor.available -and @($report.issues | Where-Object {$_.code -ceq 'executable_metadata_unavailable' -and $_.severity -ceq 'error'}).Count -eq 1) 'Discovery must expose unreadable metadata as a validation error.'
    if ($GenuineMetaEditorPath) {
        # These copies are queried only. Never execute a genuine editor here.
        $expected=Get-Mql5ExecutableVersionInfo $GenuineMetaEditorPath
        Check ($expected.FileMajorPart -eq 5 -and $expected.FilePrivatePart -gt 0) 'Select a genuine versioned MetaEditor 5 fixture.'
        $genuineShort=Join-Path $testRoot 'genuine-metaeditor64.exe'
        $genuineLong=Join-Path (Long-Directory (Join-Path $testRoot 'genuine')) 'metaeditor64.exe'
        Copy-Executable $GenuineMetaEditorPath $genuineShort;Copy-Executable $GenuineMetaEditorPath $genuineLong
        foreach ($copy in @($genuineShort,$genuineLong,('\\?\'+$genuineLong))) {
            $info=Get-Mql5ExecutableVersionInfo $copy
            Check ($info.FileVersion -ceq $expected.FileVersion -and $info.FilePrivatePart -eq $expected.FilePrivatePart -and (Get-Mql5ReleaseHash $copy) -ceq (Get-Mql5ReleaseHash $GenuineMetaEditorPath)) 'Genuine MetaEditor metadata or bytes changed.'
        }
        Write-Output ('GENUINE_METAEDITOR='+$expected.FileVersion+' build='+$expected.FilePrivatePart)
    }
    Write-Output ('EXECUTABLE_METADATA_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
} finally {
    $env:FAKE_METAEDITOR_MODE=$beforeMode
    $full=[IO.Path]::GetFullPath($testRoot)
    if (-not $full.StartsWith($temporaryParent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Test cleanup escaped the temporary directory.'}
    if (Test-Path -LiteralPath $full) {Remove-Item -LiteralPath (ConvertTo-Mql5ExtendedWindowsPath $full) -Recurse -Force}
}
