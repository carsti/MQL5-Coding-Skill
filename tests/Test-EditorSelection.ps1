#Requires -Version 5.1
[CmdletBinding()]
param([string]$RepositoryRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $RepositoryRoot) {$RepositoryRoot=Split-Path -Parent $PSScriptRoot}
$scripts=Join-Path $RepositoryRoot 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'WindowsExecutableMetadata.ps1')
. (Join-Path $scripts 'ToolkitSupport.ps1')
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$temporaryParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $temporaryParent ('mql5-editor-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Condition,[string]$Message) {if (-not $Condition) {throw $Message};$script:checks++}
function Run([string]$Script,[string[]]$Arguments) {Invoke-ToolkitProcess $hostExe (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts $Script))+$Arguments) $testRoot 60}
function Build-Editor([string]$Name,[int]$Major,[string]$Description) {
    $directory=Join-Path $testRoot $Name;[IO.Directory]::CreateDirectory($directory) | Out-Null
    $source=Join-Path $directory 'fixture.cs'
    $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeMetaEditor.cs')).Replace('5.0.0.1234',([string]$Major+'.0.0.1234')).Replace('AssemblyTitle("MetaEditor 5")',('AssemblyTitle("'+$Description+'")'))
    [IO.File]::WriteAllText($source,$text)
    $editor=Join-Path $directory 'metaeditor64.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) $source
    Check ($LASTEXITCODE -eq 0) ('Cannot build '+$Name)
    return $editor
}
$saved=@{};foreach ($name in @('FAKE_METAEDITOR_MODE','FAKE_METAEDITOR_ARGS_PATH','METAEDITOR_EXE','METAEDITOR_PATH','FAKE_METAEDITOR_PINNED_TERMINAL_PATH','FAKE_METAEDITOR_PINNED_TERMINAL_TRACE')) {$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $source=Join-Path $testRoot 'Fixture.mq5';[IO.File]::WriteAllText($source,'void OnTick() {}')
    $major4=Build-Editor 'major4' 4 'MetaEditor 4'
    $major6=Build-Editor 'major6' 6 'MetaEditor 6'
    $standalone=Build-Editor 'standalone' 5 'MetaEditor 5'
    $mt4Label=Build-Editor 'mt4-label' 5 'MetaEditor 4'
    $attached=Build-Editor 'attached' 5 'MetaEditor'
    Copy-Item -LiteralPath $standalone -Destination (Join-Path (Split-Path -Parent $attached) 'terminal64.exe')
    $mixed=Build-Editor 'mixed' 5 'MetaEditor 5'
    Copy-Item -LiteralPath $standalone -Destination (Join-Path (Split-Path -Parent $mixed) 'terminal64.exe')
    Copy-Item -LiteralPath $major4 -Destination (Join-Path (Split-Path -Parent $mixed) 'terminal.exe')
    $unreadable=Join-Path $testRoot 'unreadable\metaeditor64.exe';[IO.Directory]::CreateDirectory((Split-Path -Parent $unreadable)) | Out-Null;[IO.File]::WriteAllText($unreadable,'no readable metadata')
    $badSibling=Build-Editor 'unreadable-sibling' 5 'MetaEditor 5'
    Copy-Item -LiteralPath $unreadable -Destination (Join-Path (Split-Path -Parent $badSibling) 'terminal64.exe')
    $marker=Join-Path $testRoot 'started.txt'
    $env:FAKE_METAEDITOR_MODE='success';$env:FAKE_METAEDITOR_ARGS_PATH=$marker
    $env:METAEDITOR_EXE=$standalone;$env:METAEDITOR_PATH=$standalone
    foreach ($editor in @($major4,$major6,$mt4Label,$mixed,$unreadable,$badSibling)) {
        # A valid automatic fallback is available. Explicit rejection must not
        # launch either executable; the fake writes this marker on entry.
        $compile=Run 'Compile-Mql5.ps1' @('-SourcePath',$source,'-MetaEditorPath',$editor,'-SuppressLogOutput')
        Check ($compile.exit_code -eq 2 -and $compile.cleanup_verified -and -not (Test-Path -LiteralPath $marker)) ('Rejected editor launched or returned the wrong exit code: '+$editor+' '+$compile.stdout+$compile.stderr)
        $profile=Join-Path $testRoot 'invalid-profile.json'
        $create=Run 'New-Mql5ProjectProfile.ps1' @('-ProfilePath',$profile,'-Name','Invalid editor','-ProjectRoot',$testRoot,'-Entrypoints',$source,'-MetaEditorPath',$editor)
        Check ($create.exit_code -eq 2 -and -not (Test-Path -LiteralPath $profile)) 'Profile validation must use the same editor policy.'
        $health=Run 'Test-Mql5Environment.ps1' @('-WorkspaceRoot',$testRoot,'-CodexHome',$testRoot,'-SkillRoot',(Split-Path -Parent $scripts),'-MetaEditorPath',$editor,'-Json')
        $report=$health.stdout | ConvertFrom-Json
        Check (-not $report.metaeditor.available -and -not (Test-Path -LiteralPath $marker)) 'Health must reject the same selection without execution.'
    }
    foreach ($editor in @($standalone,$attached)) {
        $selection=Assert-Mql5MetaEditor $editor
        Check ($selection.VersionInfo.FileVersion -ceq '5.0.0.1234' -and $selection.Path -ceq $editor) 'Valid selection must preserve the actual version and canonical path.'
        if ($editor -ceq $attached) {
            $env:FAKE_METAEDITOR_PINNED_TERMINAL_PATH=Join-Path (Split-Path -Parent $attached) 'terminal64.exe'
            $env:FAKE_METAEDITOR_PINNED_TERMINAL_TRACE=Join-Path $testRoot 'sibling-lease.txt'
        }
        $compile=Run 'Compile-Mql5.ps1' @('-SourcePath',$source,'-MetaEditorPath',$editor,'-SuppressLogOutput')
        Check ($compile.exit_code -eq 0 -and $compile.cleanup_verified -and (Test-Path -LiteralPath $marker)) ('Valid editor failed: '+$compile.stdout+$compile.stderr)
        $receiptPath=[regex]::Match($compile.stdout,'(?m)^MQL5_COMPILE_RECEIPT=(.+)\r?$').Groups[1].Value.Trim()
        $receipt=Read-Mql5ReleaseJson $receiptPath
        Check ($receipt.compiler.file_version -ceq '5.0.0.1234' -and $receipt.compiler.build -eq 1234) 'Receipt metadata must remain real.'
        if ($editor -ceq $attached) {
            Check ([IO.File]::ReadAllText($env:FAKE_METAEDITOR_PINNED_TERMINAL_TRACE) -ceq 'write_blocked=True;rename_blocked=True') 'Compiler must hold sibling leases during the actual synthetic process execution.'
            $stream=[IO.File]::Open($env:FAKE_METAEDITOR_PINNED_TERMINAL_PATH,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);$stream.Dispose()
            Check (-not (Test-Path -LiteralPath ($env:FAKE_METAEDITOR_PINNED_TERMINAL_PATH+'.moved'))) 'Compiler must release sibling leases after cleanup without changing the terminal.'
            $env:FAKE_METAEDITOR_PINNED_TERMINAL_PATH=$null;$env:FAKE_METAEDITOR_PINNED_TERMINAL_TRACE=$null
        }
        Remove-Item -LiteralPath $marker
    }
    # Pinning uses the compiler's existing native identity leases. A held
    # terminal cannot be modified or deleted until validation/execution ends.
    Add-Type -Path (Join-Path $scripts 'CompilerProcessJob.cs')
    $leases=New-Object 'Collections.Generic.List[object]'
    try {
        $selection=Assert-Mql5MetaEditor $attached -PinSibling {param($path) $lease=[Mql5Coding.CompilerProcessJob]::OpenExecutableFileIdentityLease($path);$leases.Add($lease);return $lease.FinalPath}
        Check ($leases.Count -eq 1 -and $selection.SiblingPaths.Count -eq 1) 'Every inspected sibling must be pinned.'
        $blocked=$false;try {$stream=[IO.File]::Open($selection.SiblingPaths[0],[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);$stream.Dispose()} catch {$blocked=$true}
        Check $blocked 'Sibling executable lease must prevent writing during execution.'
    } finally {foreach ($lease in $leases) {$lease.Dispose()}}

    # Load discovery functions alone; this never executes a genuine editor.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'Compile-Mql5.ps1'),[ref]$tokens,[ref]$errors)
    foreach ($name in @('Get-MetaEditorFromCandidate','Resolve-MetaEditorExecutable')) {
        $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    Check ($null -eq (Get-MetaEditorFromCandidate $mixed)) 'Automatic discovery must skip incompatible candidates.'
    $fallback=Join-Path $testRoot 'fallback';[IO.Directory]::CreateDirectory($fallback) | Out-Null
    Copy-Item -LiteralPath $major4 -Destination (Join-Path $fallback 'metaeditor64.exe')
    Copy-Item -LiteralPath $standalone -Destination (Join-Path $fallback 'metaeditor.exe')
    Check ((Get-MetaEditorFromCandidate $fallback) -ceq (Join-Path $fallback 'metaeditor.exe')) 'Automatic directory discovery must retain the 64-bit then 32-bit search order, skipping incompatible files.'
    $message='';try {Resolve-MetaEditorExecutable $fallback | Out-Null} catch {$message=$_.Exception.Message}
    Check ($message -match 'major version 5') 'An explicit incompatible directory selection must fail without fallback.'
    $env:METAEDITOR_EXE=$null;$env:METAEDITOR_PATH=$standalone
    # Ignore unrelated user/machine candidates when proving this isolated
    # environment fallback; production discovery still retains its order.
    $candidateDefinition=(Get-Command Get-MetaEditorFromCandidate).Definition
    . ([scriptblock]::Create('function Get-TestMetaEditorCandidate {'+$candidateDefinition+'}'))
    function Get-MetaEditorFromCandidate {
        param($Candidate,[switch]$RequireCompatible)
        if ($Candidate -and ([string]$Candidate).StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)) {return Get-TestMetaEditorCandidate $Candidate -RequireCompatible:$RequireCompatible}
        return $null
    }
    $env:METAEDITOR_EXE=$mixed
    Check ((Resolve-MetaEditorExecutable $null) -ceq $standalone) 'Automatic discovery must continue from incompatible METAEDITOR_EXE to valid METAEDITOR_PATH.'
    Check (-not (Test-Path -LiteralPath $marker)) 'Metadata and discovery checks must not launch executables.'
    Write-Output ('EDITOR_SELECTION_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
} finally {
    foreach ($entry in $saved.GetEnumerator()) {[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value)}
    $full=[IO.Path]::GetFullPath($testRoot)
    if (-not $full.StartsWith($temporaryParent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Test cleanup escaped its temporary parent.'}
    if (Test-Path -LiteralPath $full) {Remove-Item -LiteralPath $full -Recurse -Force}
}
