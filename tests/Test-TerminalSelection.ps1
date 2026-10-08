#Requires -Version 5.1
[CmdletBinding()]
param([string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$scripts=Join-Path $repo 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'WindowsExecutableMetadata.ps1')
. (Join-Path $scripts 'ToolkitSupport.ps1')
$hostExe=if($PSVersionTable.PSEdition -eq 'Core'){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
$temporaryParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
$root=if($EvidenceDirectory){[IO.Path]::GetFullPath($EvidenceDirectory)}else{Join-Path $temporaryParent ('mql5-terminal-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $root){throw 'Terminal-selection evidence requires a fresh directory.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=0;$results=@()
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Run([string]$Name,[hashtable]$Parameters){
    $command='& '+"'"+(Join-Path $scripts $Name).Replace("'","''")+"'"
    foreach($key in $Parameters.Keys){if($Parameters[$key] -is [bool]){if($Parameters[$key]){$command+=' -'+$key}}else{$command+=' -'+$key+" '"+([string]$Parameters[$key]).Replace("'","''")+"'"}}
    $command+='; exit $LASTEXITCODE'
    return Invoke-ToolkitProcess $hostExe @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) $root 90
}
$saved=@{};foreach($name in @('FAKE_MT5_MODE','FAKE_MT5_MARKER','FAKE_MT5_READY_PATH','FAKE_MT5_REPORT_FIXTURE','FAKE_MT5_RECEIPT_LOCK_PATHS')){$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null,'Process')}
try{
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $source=Join-Path $root 'Fixture.mq5';$expert=Join-Path $root 'Fixture.ex5'
    [IO.File]::WriteAllText($source,'// Nontrading selection fixture; never compiled by MetaEditor.')
    [IO.File]::WriteAllBytes($expert,[byte[]]@(1,2,3,4));$expertHash=(Get-FileHash -LiteralPath $expert).Hash.ToLowerInvariant()
    $editorDirectory=Join-Path $root 'editor';[void][IO.Directory]::CreateDirectory($editorDirectory)
    $editor=Join-Path $editorDirectory 'metaeditor64.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) (Join-Path $PSScriptRoot 'FakeMetaEditor.cs');Check ($LASTEXITCODE -eq 0) 'Synthetic editor metadata fixture failed.'
    foreach($case in @('major4','major6','major0','unreadable','valid5')){
        $caseRoot=Join-Path $root $case;$install=Join-Path $caseRoot 'install';$data=Join-Path $caseRoot 'data';$started=Join-Path $install 'started.txt'
        foreach($dir in @($install,(Join-Path $data 'MQL5\Experts'),(Join-Path $data 'MQL5\Profiles\Tester'),(Join-Path $data 'Tester\logs'),(Join-Path $data 'logs'))){[void][IO.Directory]::CreateDirectory($dir)}
        $terminal=Join-Path $install 'terminal64.exe'
        if($case -ceq 'unreadable'){[IO.File]::WriteAllText($terminal,'No Windows version resource.')}
        else{
            $major=switch($case){major4{4}major6{6}major0{0}valid5{5}}
            $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeTerminal.cs')).Replace('internal static class FakeTerminal',('[assembly: System.Reflection.AssemblyFileVersion("'+$major+'.0.0.1234")]'+[Environment]::NewLine+'internal static class FakeTerminal')).Replace('string configPath = ConfigPath(args);','File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"started.txt"),"started"); string configPath = ConfigPath(args);')
            $cs=Join-Path $caseRoot 'fake.cs';[IO.File]::WriteAllText($cs,$text)
            & $csc /nologo /target:exe ('/out:'+$terminal) $cs;Check ($LASTEXITCODE -eq 0) ('Synthetic terminal failed: '+$case)
        }
        [IO.File]::WriteAllText((Join-Path $data 'origin.txt'),$install,[Text.Encoding]::Unicode)
        $accepted=$false;try{$selection=Assert-Mql5Terminal $terminal;$accepted=$true}catch{}
        Check ($accepted -eq ($case -ceq 'valid5')) ('Shared terminal validator mismatch: '+$case)
        if($accepted){Check ($selection.Path -ceq $terminal -and $selection.VersionInfo.FileVersion -ceq '5.0.0.1234') 'Canonical terminal/version changed.'}
        $profilePath=Join-Path $caseRoot 'profile.json'
        $create=Run 'New-Mql5ProjectProfile.ps1' @{ProfilePath=$profilePath;Name='Terminal';ProjectRoot=$root;Entrypoints=$source;MetaEditorPath=$editor;TesterEntrypoint=$source;TerminalPath=$terminal;TerminalDataPath=$data;UseExpertDefaults=$true;Symbol='SYNTH';Period='M1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000';Currency='USD';Leverage=100;ExecutionMode=0}
        Check ($create.exit_code -eq $(if($accepted){0}else{2})) ('Profile terminal policy mismatch: '+$case)
        Check ((Test-Path -LiteralPath $profilePath) -eq $accepted) 'Invalid profile publication.'
        foreach($mode in @('PreflightOnly','Execute')){
            $output=Join-Path $caseRoot $mode
            $parameters=@{ExpertPath=$expert;ExpectedExpertSha256=$expertHash;TerminalPath=$terminal;TerminalDataPath=$data;OutputDirectory=$output;UseExpertDefaults=$true;Symbol='SYNTH';Period='M1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000';Currency='USD';Leverage=100;ExecutionMode=0;TimeoutSeconds=10};$parameters[$mode]=$true
            $run=Run 'Invoke-Mt5TesterSmoke.ps1' $parameters
            $result=Read-Mql5ReleaseJson (Join-Path $output 'smoke-result.json')
            Check ($run.exit_code -eq $(if($accepted){0}else{2}) -and $run.cleanup_verified) ('Direct terminal selection mismatch: '+$case+' '+$mode+' '+$run.stderr)
            Check ($result.status -ceq $(if(-not $accepted){'tooling_error'}elseif($mode -ceq 'PreflightOnly'){'preflight_passed'}else{'engine_smoke_passed'})) 'Incorrect terminal evidence status.'
            Check ($result.process.execution_attempted -eq ($accepted -and $mode -ceq 'Execute')) 'Rejected terminal marked as launched.'
            Check ((Test-Path -LiteralPath $started) -eq ($accepted -and $mode -ceq 'Execute')) 'Rejected terminal actually started.'
            $results+=@([pscustomobject]@{case=$case;mode=$mode;exit_code=$run.exit_code;status=$result.status;started=(Test-Path -LiteralPath $started);cleanup_verified=$run.cleanup_verified})
        }
        if($accepted){
            $inferred=Run 'Invoke-Mt5TesterSmoke.ps1' @{ExpertPath=$expert;ExpectedExpertSha256=$expertHash;TerminalDataPath=$data;OutputDirectory=(Join-Path $caseRoot 'inferred-preflight');PreflightOnly=$true;UseExpertDefaults=$true;Symbol='SYNTH';Period='M1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000';Currency='USD';Leverage=100;ExecutionMode=0}
            Check ($inferred.exit_code -eq 0) 'Origin-selected valid terminal was rejected.'
        }
    }
    # Exercise the unchanged production discovery function with filesystem
    # enumeration/lease boundaries replaced by this disposable fixture tree.
    # Version resources and origin contents remain real; never inspect or
    # mutate the user's MetaQuotes application-data directory here.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'TesterPathIntegrity.ps1'),[ref]$tokens,[ref]$errors)
    $binding=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Resolve-TerminalBinding'},$true).Extent.Text
    $discovery=& {
        param($Definition,$FixtureRoot)
        . ([scriptblock]::Create($Definition))
        $state=[pscustomobject]@{candidates=@('major4','major6','major0','unreadable','valid5')}
        function Open-NonReparseDirectoryChain {param($Path,$Tracker,$LeasesByPath) return [pscustomobject]@{Identity=[IO.Path]::GetFullPath($Path)}}
        function Try-OpenNonReparseFileLeaf {param($Path,$Tracker,$LeasesByPath) if([IO.File]::Exists($Path)){return $Path};return $null}
        function Open-NonReparseFileLeaf {param($Path,$Tracker,$LeasesByPath) return $Path}
        function Read-TerminalOrigin {param($Path,$Lease) return [IO.File]::ReadAllText($Path).Trim()}
        function Get-ChildItem {param($LiteralPath,[switch]$Directory) foreach($name in $state.candidates){[pscustomobject]@{FullName=(Join-Path $FixtureRoot ($name+'\data'))}}}
        $selected=Resolve-TerminalBinding -Tracker @() -LeasesByPath @{}
        $state.candidates=@('major4','major6','major0','unreadable')
        $missing=$false;try{Resolve-TerminalBinding -Tracker @() -LeasesByPath @{}|Out-Null}catch{$missing=$_.Exception.Message -match 'No terminal data directory'}
        $secondData=Join-Path $FixtureRoot 'second-valid\data';[void][IO.Directory]::CreateDirectory($secondData)
        [IO.File]::WriteAllText((Join-Path $secondData 'origin.txt'),(Join-Path $FixtureRoot 'valid5\install'),[Text.Encoding]::Unicode)
        $state.candidates=@('major4','valid5','second-valid')
        $ambiguous=$false;try{Resolve-TerminalBinding -Tracker @() -LeasesByPath @{}|Out-Null}catch{$ambiguous=$_.Exception.Message -match 'discovery is ambiguous'}
        [pscustomobject]@{selected=$selected;missing=$missing;ambiguous=$ambiguous}
    } $binding $root
    Check ($discovery.selected.terminal_path -ceq (Join-Path $root 'valid5\install\terminal64.exe')) 'Automatic discovery selected an incompatible candidate.'
    Check $discovery.missing 'Automatic discovery accepted only incompatible candidates.'
    Check $discovery.ambiguous 'Automatic discovery hid compatible-binding ambiguity.'
    $longDirectory=Join-Path $root 'long-metadata'
    while((Join-Path $longDirectory 'terminal64.exe').Length -le 290){$longDirectory=Join-Path $longDirectory 'metadata-component'}
    [void][IO.Directory]::CreateDirectory((ConvertTo-Mql5ExtendedWindowsPath $longDirectory))
    $longTerminal=Join-Path $longDirectory 'terminal64.exe'
    [IO.File]::Copy((ConvertTo-Mql5ExtendedWindowsPath $terminal),(ConvertTo-Mql5ExtendedWindowsPath $longTerminal))
    foreach($path in @($longTerminal,(ConvertTo-Mql5ExtendedWindowsPath $longTerminal))){
        $longSelection=Assert-Mql5Terminal $path
        Check ($longSelection.Path -ceq $longTerminal -and $longSelection.VersionInfo.FileVersion -ceq '5.0.0.1234') 'Terminal metadata lost its canonical long path or version.'
    }
    $wrongName=Join-Path $root 'renamed.exe';[IO.File]::Copy($terminal,$wrongName)
    $rejected=$false;try{Assert-Mql5Terminal $wrongName|Out-Null}catch{$rejected=$true};Check $rejected 'Major5 wrong filename accepted.'
    $report=[pscustomobject]@{host=$PSVersionTable.PSVersion.ToString();checks=$checks;cases=$results}
    [IO.File]::WriteAllText((Join-Path $root 'proof.json'),($report|ConvertTo-Json -Depth 6))
    Write-Output ('TERMINAL_SELECTION_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
}finally{
    foreach($entry in $saved.GetEnumerator()){[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')}
    if(-not $EvidenceDirectory){$full=[IO.Path]::GetFullPath($root);if(-not $full.StartsWith($temporaryParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'mql5-terminal-*'){throw 'Unsafe terminal test cleanup.'};if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath (ConvertTo-Mql5ExtendedWindowsPath $full) -Recurse -Force}}
}
