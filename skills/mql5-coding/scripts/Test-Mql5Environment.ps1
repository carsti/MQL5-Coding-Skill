#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [string]$CodexHome,
    [string]$CodexPath,
    [string]$McpPackageRoot,
    [string]$SkillRoot,
    [string]$McpSourceRoot,
    [string]$SkillSourceRoot,
    [string]$MetaEditorPath,
    [string]$PythonPath,
    [ValidateRange(5,60)][int]$TimeoutSeconds = 15,
    [switch]$RequireCompiler,
    [switch]$RequirePython,
    [switch]$Json,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$issues = New-Object 'Collections.Generic.List[object]'
function Add-Issue([string]$Code, [string]$Severity, [string]$Message) {
    $issues.Add([ordered]@{code=$Code;severity=$Severity;message=$Message})
}
function Value($Object, [string]$Name, $Default=$null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {return $Object.$Name}
    return $Default
}
function Full-Path([string]$Path) {return [IO.Path]::GetFullPath($Path)}
function Directory-Path([string]$Path) {
    $full=Full-Path $Path
    if ($full -ieq [IO.Path]::GetPathRoot($full)) {return $full}
    return $full.TrimEnd('\')
}
function Same-Path([string]$First, [string]$Second) {
    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {return $false}
    return (Full-Path $First).TrimEnd('\') -ieq (Full-Path $Second).TrimEnd('\')
}
function Hash-File([string]$Path) {
    # Avoid module auto-loading: a 5.1 subprocess may inherit PS7's module path.
    $stream=[IO.File]::OpenRead($Path)
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}
    finally {$algorithm.Dispose(); $stream.Dispose()}
}
function Absolute-LaunchPath($Path) {
    return $Path -is [string] -and [IO.Path]::IsPathRooted($Path) -and ($Path -match '^[A-Za-z]:[\\/]' -or $Path -match '^\\\\[^\\/]+[\\/][^\\/]+')
}
function Assert-RegistrationShape($Registration) {
    if ($Registration -isnot [pscustomobject] -or (Value $Registration 'name') -isnot [string] -or (Value $Registration 'enabled') -isnot [bool]) {throw 'Unsupported registration fields.'}
    $transport=Value $Registration 'transport'
    if ($transport -isnot [pscustomobject] -or (Value $transport 'type') -isnot [string] -or (Value $transport 'command') -isnot [string]) {throw 'Unsupported registration transport.'}
    $arguments=$transport.PSObject.Properties['args']
    if ($null -eq $arguments -or $arguments.Value -isnot [array]) {throw 'Unsupported registration arguments.'}
    foreach ($argument in $arguments.Value) {if ($argument -isnot [string]) {throw 'Unsupported registration argument.'}}
    foreach ($selection in @(@($Registration,'enabled_tools'),@($Registration,'disabled_tools'),@($transport,'env_vars'))) {
        $values=$selection[0].PSObject.Properties[$selection[1]]
        if ($null -ne $values -and $null -ne $values.Value) {
            if ($values.Value -isnot [array]) {throw 'Unsupported registration array.'}
            foreach ($item in $values.Value) {if ($item -isnot [string]) {throw 'Unsupported registration array value.'}}
        }
    }
    $cwd=Value $transport 'cwd'
    if ($null -ne $cwd -and $cwd -isnot [string]) {throw 'Unsupported registration working directory.'}
    $environment=Value $transport 'env'
    if ($null -ne $environment) {
        if ($environment -isnot [pscustomobject]) {throw 'Unsupported registration environment.'}
        foreach ($entry in $environment.PSObject.Properties) {if ([string]::IsNullOrWhiteSpace($entry.Name) -or $entry.Value -isnot [string]) {throw 'Unsupported registration environment value.'}}
    }
}
function Invoke-Probe([string]$Executable, [string[]]$Arguments, [string]$Directory, [int]$Seconds=$TimeoutSeconds) {
    $job=$null
    $answer=@{ok=$false;reason='launch_failed';text=$null;exit_code=$null}
    try {
        if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'TesterProcessJob.cs')}
        $environment=@{MQL5_CHM_MCP_ROOT=$null;PYTHONDONTWRITEBYTECODE='1';CODEX_HOME=$CodexHome}
        $job=[Mql5Coding.JobProcessLaunch]::CreateSuspendedProbe($Executable,$Arguments,$Directory,$environment)
        $stdout=[Mql5Coding.JobProcessLaunch]::ReadProbeOutputAsync($job.StandardOutput,1048576,$true)
        $stderr=[Mql5Coding.JobProcessLaunch]::ReadProbeOutputAsync($job.StandardError,1048576,$false)
        $job.Resume()
        $deadline=[Diagnostics.Stopwatch]::StartNew()
        $exited=$false
        $oversized=$false
        do {
            $oversized=($stdout.IsCompleted -and $stdout.Result.LimitExceeded) -or ($stderr.IsCompleted -and $stderr.Result.LimitExceeded)
            if ($oversized) {break}
            $remaining=[int]($Seconds*1000-$deadline.ElapsedMilliseconds)
            if ($remaining -le 0) {break}
            $exited=$job.WaitForExit([Math]::Min(100,$remaining))
        } while (-not $exited)
        if ($oversized) {$answer=@{ok=$false;reason='oversized_output';text=$null;exit_code=$null}}
        elseif (-not $exited) {$answer=@{ok=$false;reason='timeout';text=$null;exit_code=$null}}
        elseif (-not $stdout.Wait(3000) -or -not $stderr.Wait(3000)) {$answer=@{ok=$false;reason='output_timeout';text=$null;exit_code=$job.ExitCode}}
        elseif ($stdout.Result.LimitExceeded -or $stderr.Result.LimitExceeded) {$answer=@{ok=$false;reason='oversized_output';text=$null;exit_code=$job.ExitCode}}
        else {$answer=@{ok=($job.ExitCode -eq 0);reason='completed';text=$stdout.Result.Text;exit_code=$job.ExitCode}}
    } catch {
        # Never put subprocess output, config contents, or exception text in the report.
        $answer=@{ok=$false;reason='launch_failed';text=$null;exit_code=$null}
    } finally {
        if ($null -ne $job) {
            try {$job.TerminateAndWaitForEmpty(5000)}
            catch {$answer=@{ok=$false;reason='cleanup_failed';text=$null;exit_code=$null}}
            finally {$job.Dispose()}
        }
    }
    return $answer
}
function Find-Codex {
    if ($CodexPath) {return Full-Path $CodexPath}
    $command=Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {return $command.Source}
    $desktopBin=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $desktopBin -PathType Container) {
        $found=@(Get-ChildItem -LiteralPath $desktopBin -Directory | ForEach-Object {Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue} | Sort-Object -Property LastWriteTimeUtc -Descending)
        if ($found.Count) {return $found[0].FullName}
    }
    # Native executable inside an npm installation; do not execute PowerShell/cmd shims.
    $npmRoot=Join-Path $env:APPDATA 'npm\node_modules\@openai\codex'
    if (Test-Path -LiteralPath $npmRoot -PathType Container) {
        $found=@(Get-ChildItem -LiteralPath $npmRoot -Filter codex.exe -Recurse -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) {return $found[0].FullName}
    }
    return $null
}
function Skill-Files([string]$Root) {
    $Root=Directory-Path $Root
    $rootPrefix=$Root.TrimEnd('\')+'\'
    $result=@{}
    $directories=New-Object 'Collections.Generic.Stack[string]'
    $directories.Push($Root)
    while ($directories.Count -gt 0) {
        $directory=$directories.Pop()
        if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Unsupported skill directory link.'}
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Unsupported skill link.'}
            if ($entry.PSIsContainer) {$directories.Push($entry.FullName)}
            else {$result[$entry.FullName.Substring($rootPrefix.Length).Replace('\','/')]=Hash-File $entry.FullName}
        }
    }
    return $result
}
function Fingerprint($Files) {
    [string[]]$names=@($Files.Keys)
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $bytes=[Text.Encoding]::UTF8.GetBytes((@($names | ForEach-Object {$_ + [char]0 + $Files[$_]}) -join "`n"))
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}
    finally {$algorithm.Dispose()}
}
function Compare-Files($Source, $Installed, [string]$SourcePath, [string]$Mode) {
    $differences=@()
    foreach ($name in @(@($Source.Keys)+@($Installed.Keys) | Sort-Object -Unique)) {
        $state=if (-not $Source.ContainsKey($name)) {'installed_only'} elseif (-not $Installed.ContainsKey($name)) {'missing_installed'} elseif ($Source[$name] -cne $Installed[$name]) {'changed'} else {$null}
        if ($state) {$differences+=@([ordered]@{relative_path=$name;state=$state;source_sha256=$Source[$name];installed_sha256=$Installed[$name]})}
    }
    return [ordered]@{status=$(if ($differences.Count) {'different'} else {'same'});mode=$Mode;source_root=$SourcePath;files_compared=$Installed.Count;differences=@($differences)}
}
function Find-Source([string[]]$Candidates, [string]$Required) {
    foreach ($candidate in $Candidates) {if (Test-Path -LiteralPath (Join-Path $candidate $Required) -PathType Leaf) {return Full-Path $candidate}}
    return $null
}
function Check-Package([string]$Root) {
    $files=@{}
    $manifestPath=Join-Path $Root 'checksums.sha256'
    foreach ($line in [IO.File]::ReadAllLines($manifestPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {continue}
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {throw 'Invalid checksum entry.'}
        $expected=$Matches[1].ToLowerInvariant()
        $name=$Matches[2].Replace('\','/')
        if ($files.ContainsKey($name) -or $name -match '(^/|^[a-zA-Z]:|(^|/)\.\.(/|$))') {throw 'Invalid checksum path.'}
        $path=Full-Path (Join-Path $Root $name)
        if (-not $path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Checksum path escapes the package.'}
        $segment=$path
        while ($segment.Length -ge $Root.Length) {
            if ((Get-Item -LiteralPath $segment).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Package path contains a link.'}
            if (Same-Path $segment $Root) {break}
            $segment=Split-Path -Parent $segment
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Hash-File $path) -cne $expected) {throw 'Package checksum mismatch.'}
        $files[$name]=$expected
    }
    foreach ($required in @('runtime/node.exe','app/server.mjs','scripts/Smoke-Test-McpServer.mjs','package.json','data/active.json')) {
        if (-not $files.ContainsKey($required)) {throw 'Required probe input is not covered by checksums.'}
    }
    return $files
}
function Find-Editors {
    $candidates=New-Object 'Collections.Generic.List[string]'
    if ($MetaEditorPath) {$candidates.Add((Full-Path $MetaEditorPath))}
    else {
        foreach ($name in @('METAEDITOR_EXE','METAEDITOR_PATH')) {
            foreach ($scope in @('Process','User','Machine')) {
                $value=[Environment]::GetEnvironmentVariable($name,$scope)
                if ($value) {$candidates.Add([Environment]::ExpandEnvironmentVariables($value.Trim('"')))}
            }
        }
        foreach ($name in @('metaeditor64.exe','metaeditor.exe')) {
            $command=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) {$candidates.Add($command.Source)}
        }
        foreach ($parent in @($env:ProgramFiles,${env:ProgramFiles(x86)})) {
            if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
                foreach ($directory in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue) {$candidates.Add($directory.FullName)}
            }
        }
        foreach ($entry in @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue)) {
            if ((Value $entry 'DisplayName' '') -match 'MetaTrader 5|MetaEditor') {
                $location=Value $entry 'InstallLocation'
                if ($location) {$candidates.Add($location)}
            }
        }
    }
    $editors=@()
    foreach ($candidate in $candidates) {
        $paths=if (Test-Path -LiteralPath $candidate -PathType Container) {@((Join-Path $candidate 'metaeditor64.exe'),(Join-Path $candidate 'metaeditor.exe'))} else {@($candidate)}
        foreach ($path in $paths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {continue}
            $file=Get-Item -LiteralPath $path
            if ($file.Name -notin @('metaeditor64.exe','metaeditor.exe') -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.VersionInfo.FileMajorPart -ne 5) {continue}
            # MT4 also ships an editor with product major version 5. Check its
            # associated terminal first, then the explicit MetaEditor 5 label.
            $terminalFound=$false; $mt5=$false; $incompatibleTerminal=$false
            foreach ($terminalName in @('terminal64.exe','terminal.exe')) {
                $terminal=Join-Path $file.DirectoryName $terminalName
                if (Test-Path -LiteralPath $terminal -PathType Leaf) {
                    $terminalFound=$true
                    if ((Get-Item -LiteralPath $terminal).VersionInfo.FileMajorPart -eq 5) {$mt5=$true}
                    else {$incompatibleTerminal=$true}
                }
            }
            if (-not $terminalFound) {$mt5=$file.VersionInfo.FileDescription -match '^MetaEditor\s+5\b'}
            if (-not $mt5 -or $incompatibleTerminal) {continue}
            if (@($editors | Where-Object {Same-Path $_.path $file.FullName}).Count) {continue}
            $editors+=@([ordered]@{path=$file.FullName;file_version=$file.VersionInfo.FileVersion;build=$file.VersionInfo.FilePrivatePart})
        }
    }
    return $editors
}

$report=[ordered]@{schema_version=1;kind='mql5_environment_health';checked_utc=[DateTime]::UtcNow.ToString('o');status='failed';workspace_root=$WorkspaceRoot;codex_home=$null;codex=[ordered]@{path=$null;version=$null;registration_state='not_checked';native_chat_availability='not_checked'};mcp=[ordered]@{package_root=$null;package_version=$null;node_version=$null;integrity='not_checked';checked_files=0;stdio_available=$false;connection='direct_stdio';corpus_revision=$null;index_revision=$null;source_comparison=@{status='not_requested'}};skill=[ordered]@{root=$null;installed=$false;declared_version=$null;file_count=0;fingerprint_sha256=$null;source_comparison=@{status='not_requested'}};metaeditor=[ordered]@{available=$false;candidates=@();selected_path=$null};python=[ordered]@{path=$null;available=$false;version=$null;pyyaml_available=$false;shared_launcher_present=$false};issues=@();exit_code=1}
try {
    $WorkspaceRoot=Full-Path $WorkspaceRoot
    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {throw 'Workspace directory does not exist.'}
    if (-not $CodexHome) {$CodexHome=if ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}}
    $CodexHome=Full-Path $CodexHome
    $report.workspace_root=$WorkspaceRoot
    $report.codex_home=$CodexHome
    if (-not $SkillRoot) {$SkillRoot=Join-Path $CodexHome 'skills\mql5-coding'}
    $SkillRoot=Directory-Path $SkillRoot
    $report.skill.root=$SkillRoot
    if (-not (Test-Path -LiteralPath (Join-Path $SkillRoot 'SKILL.md') -PathType Leaf)) {Add-Issue 'skill_missing' 'error' 'The installed mql5-coding skill is missing.'}
    else {
        try {
            $skillFiles=Skill-Files $SkillRoot
            . (Join-Path $PSScriptRoot 'SkillRelease.ps1')
            foreach ($required in @(Get-Mql5SkillReleaseFiles)) {
                if (-not $skillFiles.ContainsKey($required)) {throw 'An essential skill file is missing.'}
            }
            # Use this invoked checker's trusted companion, not code from the
            # selected tree being inspected. Share the updater's version rules.
            . (Join-Path $PSScriptRoot 'SkillRelease.ps1')
            $identity=Read-Mql5ReleaseJson (Join-Path $SkillRoot 'version.json')
            Assert-Mql5SkillVersion $identity
            $report.skill.declared_version=$identity.version
            $report.skill.installed=$true
            $report.skill.file_count=$skillFiles.Count
            $report.skill.fingerprint_sha256=Fingerprint $skillFiles
            $contract=Get-Content -LiteralPath (Join-Path $SkillRoot 'references\mcp-contract.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ((Value $contract 'server_name') -cne 'mql5-chm') {throw 'Wrong consumer dependency.'}
            if (-not $SkillSourceRoot) {$SkillSourceRoot=Find-Source @((Join-Path $WorkspaceRoot 'skills\mql5-coding'),(Join-Path $WorkspaceRoot 'MQL5-Coding-Skill\skills\mql5-coding'),(Join-Path $WorkspaceRoot 'MQL5-Coding-Skill-main\MQL5-Coding-Skill-main\skills\mql5-coding')) 'SKILL.md'}
            if ($SkillSourceRoot) {
                $SkillSourceRoot=Directory-Path $SkillSourceRoot
                try {
                    $report.skill.source_comparison=Compare-Files (Skill-Files $SkillSourceRoot) $skillFiles $SkillSourceRoot 'complete_skill_inventory'
                    if ($report.skill.source_comparison.status -eq 'different') {Add-Issue 'skill_source_differs' 'warning' 'Skill source and installed files differ; inspect the listed differences.'}
                } catch {$report.skill.source_comparison=@{status='unavailable';source_root=$SkillSourceRoot}; Add-Issue 'skill_source_unavailable' 'warning' 'The selected skill source cannot be compared.'}
            }
        } catch {Add-Issue 'skill_unreadable' 'error' 'The installed skill or selected source could not be read or has an invalid consumer contract.'}
    }
    $codex=Find-Codex
    $registration=$null
    if ($codex -and (Test-Path -LiteralPath $codex -PathType Leaf)) {
        $report.codex.path=$codex
        $version=Invoke-Probe $codex @('--version') $WorkspaceRoot
        if ($version.ok -and $version.text.Trim() -match '^codex(?:-cli)?\s+(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)$') {$report.codex.version=$Matches[1]}
        else {Add-Issue 'codex_version_unavailable' 'warning' 'Codex CLI version could not be verified.'}
        $result=Invoke-Probe $codex @('mcp','get','mql5-chm','--json') $WorkspaceRoot
        try {
            if (-not $result.ok) {throw 'Codex query failed.'}
            if (-not $result.text.TrimStart().StartsWith('{')) {throw 'Registration must be a JSON object.'}
            $registration=$result.text | ConvertFrom-Json
            Assert-RegistrationShape $registration
            if ((Value $registration 'name') -cne 'mql5-chm' -or (Value (Value $registration 'transport') 'type') -cne 'stdio') {throw 'Unexpected registration.'}
            $report.codex.registration_state='enabled'
            if (-not $registration.enabled) {$report.codex.registration_state='disabled'; Add-Issue 'mcp_disabled' 'error' 'The mql5-chm registration is disabled.'}
            $allowed=@(Value $registration 'enabled_tools' @())
            $allowListPresent=$null -ne $registration.PSObject.Properties['enabled_tools'] -and $null -ne $registration.enabled_tools
            $denied=@(Value $registration 'disabled_tools' @())
            foreach ($tool in @('mql5_chm_status','mql5_chm_search','mql5_chm_read','mql5_chm_read_image')) {
                if ($tool -in $denied -or ($allowListPresent -and $tool -notin $allowed)) {Add-Issue 'mcp_tool_disabled' 'error' "A required documentation tool is disabled: $tool"}
            }
            $transport=$registration.transport
            $arguments=@(Value $transport 'args' @())
            if ($arguments.Count -ne 1 -or -not (Absolute-LaunchPath $arguments[0]) -or -not (Absolute-LaunchPath $transport.command)) {throw 'Unsupported launch arguments.'}
            $registeredRoot=Split-Path -Parent (Split-Path -Parent ([string]$arguments[0]))
            if (-not $McpPackageRoot) {$McpPackageRoot=$registeredRoot}
            $cwdProperty=$transport.PSObject.Properties['cwd']
            $cwdMatches=$null -eq $cwdProperty -or $null -eq $cwdProperty.Value -or ((Absolute-LaunchPath $cwdProperty.Value) -and (Same-Path $cwdProperty.Value $McpPackageRoot))
            if (-not (Same-Path $McpPackageRoot $registeredRoot) -or -not (Same-Path $transport.command (Join-Path $McpPackageRoot 'runtime\node.exe')) -or -not (Same-Path ([string]$arguments[0]) (Join-Path $McpPackageRoot 'app\server.mjs')) -or -not $cwdMatches) {Add-Issue 'mcp_registration_mismatch' 'error' 'Codex command and server argument must select the tested package; an explicit working directory must select that same package.'}
            if (@((Value $transport 'env' ([pscustomobject]@{})).PSObject.Properties | Where-Object {$_.Name -eq 'MQL5_CHM_MCP_ROOT'}).Count -or 'MQL5_CHM_MCP_ROOT' -in @(Value $transport 'env_vars' @())) {Add-Issue 'mcp_ambient_root' 'error' 'The registration sets an unsupported ambient corpus-root override.'}
            if (@((Value $transport 'env' ([pscustomobject]@{})).PSObject.Properties).Count -gt 0 -or @(Value $transport 'env_vars' @()).Count -gt 0) {Add-Issue 'mcp_custom_environment' 'warning' 'Registration has custom environment settings. The direct package probe does not reproduce them, so configured startup is not fully verified.'}
        } catch {$registration=$null; $report.codex.registration_state='unavailable'; Add-Issue 'codex_registration_unavailable' 'error' 'Codex could not return a supported mql5-chm registration in this workspace.'}
    } else {
        $report.codex.registration_state='cli_missing'
        Add-Issue 'codex_cli_missing' 'warning' 'Codex CLI was not found; registration is unverified. Supply -CodexPath for a native executable.'
    }
    if (-not $McpPackageRoot) {Add-Issue 'mcp_package_missing' 'error' 'The MCP package could not be resolved. Supply -McpPackageRoot when registration is unavailable.'}
    else {
        $McpPackageRoot=Directory-Path $McpPackageRoot
        $report.mcp.package_root=$McpPackageRoot
        $mcpPhase='package_metadata'
        try {
            $package=Get-Content -LiteralPath (Join-Path $McpPackageRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ((Value $package 'name') -cne 'mql5-chm-mcp' -or (Value $package 'version' '') -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {throw 'Invalid MCP package identity.'}
            $report.mcp.package_version=$package.version
            $mcpPhase='integrity'
            $installedFiles=Check-Package $McpPackageRoot
            $report.mcp.integrity='passed'
            $report.mcp.checked_files=$installedFiles.Count
            $mcpPhase='source_comparison'
            if (-not $McpSourceRoot) {$McpSourceRoot=Find-Source @($WorkspaceRoot,(Join-Path $WorkspaceRoot 'MQL5-CHM-MCP'),(Join-Path $WorkspaceRoot 'MQL5-CHM-MCP-main\MQL5-CHM-MCP-main')) 'src\server.mjs'}
            if ($McpSourceRoot) {
                $McpSourceRoot=Directory-Path $McpSourceRoot
                try {
                    $source=@{}; $installed=@{}
                    foreach ($name in $installedFiles.Keys) {
                        if ($name -match '^(data|revisions|runtime)/') {continue}
                        $sourcePath=Join-Path $McpSourceRoot $name
                        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {$source[$name]=Hash-File $sourcePath; $installed[$name]=$installedFiles[$name]}
                    }
                    if (-not (Test-Path -LiteralPath (Join-Path $McpSourceRoot 'package.json') -PathType Leaf)) {throw 'MCP source is unavailable.'}
                    $report.mcp.source_comparison=Compare-Files $source $installed $McpSourceRoot 'common_distributed_files'
                    if ($report.mcp.source_comparison.status -eq 'different') {Add-Issue 'mcp_source_differs' 'warning' 'MCP source and installed distributable files differ; development-only files and generated corpus/runtime files are excluded.'}
                } catch {$report.mcp.source_comparison=@{status='unavailable';source_root=$McpSourceRoot}; Add-Issue 'mcp_source_unavailable' 'warning' 'The selected MCP source cannot be compared.'}
            }
            $node=Join-Path $McpPackageRoot 'runtime\node.exe'
            $mcpPhase='node_version'
            $nodeVersion=Invoke-Probe $node @('--version') $McpPackageRoot
            if (-not $nodeVersion.ok -or $nodeVersion.text.Trim() -cne ('v'+$package.engines.node)) {throw 'Pinned Node version does not match.'}
            $report.mcp.node_version=$nodeVersion.text.Trim()
            $mcpPhase='active_revision'
            $pointer=Get-Content -LiteralPath (Join-Path $McpPackageRoot 'data\active.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pointer.active_revision -cnotmatch '^[0-9a-f]{64}$') {throw 'Invalid active revision.'}
            $manifest=Get-Content -LiteralPath (Join-Path $McpPackageRoot ('revisions\'+$pointer.active_revision+'\manifest.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($manifest.corpus_revision -cnotmatch '^[0-9a-f]{64}$' -or $manifest.schema_version -notin @(2,3)) {throw 'Invalid revision metadata.'}
            $report.mcp.index_revision=$pointer.active_revision
            $report.mcp.corpus_revision=$manifest.corpus_revision
            $mcpPhase='stdio'
            $probe=Invoke-Probe $node @((Join-Path $McpPackageRoot 'scripts\Smoke-Test-McpServer.mjs'),'--server',(Join-Path $McpPackageRoot 'app\server.mjs'),'--timeout-ms',([string]($TimeoutSeconds*1000)),'--expected-server-version',([string]$report.mcp.package_version),'--expected-active-revision',([string]$pointer.active_revision),'--expected-index-revision',([string]$pointer.active_revision),'--expected-corpus-revision',([string]$manifest.corpus_revision),'--expected-schema-version',([string]$manifest.schema_version)) $McpPackageRoot ($TimeoutSeconds+5)
            if (-not $probe.ok -or $probe.text.Trim() -cne 'Verified MCP initialize, tools/list, and mql5_chm_status.') {throw 'MCP probe failed.'}
            $report.mcp.stdio_available=$true
        } catch {Add-Issue ('mcp_'+$mcpPhase+'_failed') 'error' ('The MCP '+$mcpPhase.Replace('_',' ')+' check failed. See the selected package/source paths in this report.'); if ($mcpPhase -eq 'integrity') {$report.mcp.integrity='failed'}}
    }
    $editors=@(Find-Editors)
    $report.metaeditor.available=($editors.Count -gt 0)
    $report.metaeditor.candidates=$editors
    if ($editors.Count -gt 0) {$report.metaeditor.selected_path=$editors[0].path}
    else {Add-Issue 'metaeditor_missing' $(if ($RequireCompiler) {'error'} else {'warning'}) 'MetaEditor was not found; it is required for compilation, not documentation review.'}
    $sharedPython=Join-Path $CodexHome 'tools\mql5-python\.venv\Scripts\python.exe'
    $report.python.shared_launcher_present=Test-Path -LiteralPath (Join-Path $CodexHome 'tools\mql5-python\mql5-python.cmd') -PathType Leaf
    if (-not $PythonPath -and (Test-Path -LiteralPath $sharedPython -PathType Leaf)) {$PythonPath=$sharedPython}
    if (-not $PythonPath) {$pythonCommand=Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($pythonCommand) {$PythonPath=$pythonCommand.Source}}
    if ($PythonPath -and (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        $PythonPath=Full-Path $PythonPath
        $report.python.path=$PythonPath
        $file=Get-Item -LiteralPath $PythonPath
        if (-not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $file.Length -gt 0) {
            $python=Invoke-Probe $PythonPath @('-I','-B','-c','import sys, json, importlib.util; print(json.dumps({"version":sys.version.split()[0],"pyyaml":importlib.util.find_spec("yaml") is not None}))') $WorkspaceRoot
            try {
                if (-not $python.ok) {throw 'Python probe failed.'}
                $data=$python.text | ConvertFrom-Json
                if ($data.version -notmatch '^\d+\.\d+\.\d+$' -or $data.pyyaml -isnot [bool]) {throw 'Invalid Python metadata.'}
                $report.python.available=$true; $report.python.version=$data.version; $report.python.pyyaml_available=$data.pyyaml
            } catch {}
        }
    }
    if (-not $report.python.available) {Add-Issue 'python_unavailable' $(if ($RequirePython) {'error'} else {'warning'}) 'Python is unavailable. It is optional for MQL5 documentation review and compilation.'}
    elseif (-not $report.python.pyyaml_available) {Add-Issue 'pyyaml_missing' 'warning' 'Python is available, but PyYAML is missing for skill metadata and compatibility validation.'}
} catch {Add-Issue 'health_check_error' 'error' 'The health command could not complete. Check supplied paths and access permissions.'; $report.exit_code=2}

$report.issues=@($issues.ToArray())
$errors=@($report.issues | Where-Object {$_.severity -eq 'error'})
$warnings=@($report.issues | Where-Object {$_.severity -eq 'warning'})
if ($report.exit_code -ne 2) {$report.exit_code=$(if ($errors.Count) {1} else {0})}
$report.status=$(if ($errors.Count) {'failed'} elseif ($warnings.Count) {'warning'} else {'passed'})
$reportJson=$report | ConvertTo-Json -Depth 12
if ($ReportPath) {
    try {
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($reportJson+[Environment]::NewLine)
        $stream=[IO.File]::Open((Full-Path $ReportPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    } catch {$report.exit_code=2; $report.status='failed'; Add-Issue 'report_write_failed' 'error' 'The report could not be created. Use a new filename in an existing directory.'; $report.issues=@($issues.ToArray()); $reportJson=$report | ConvertTo-Json -Depth 12}
}
if ($Json) {Write-Output $reportJson}
else {
    Write-Output "MQL5 health: $($report.status) (exit $($report.exit_code))"
    Write-Output "MCP: version $($report.mcp.package_version), integrity $($report.mcp.integrity), direct stdio available $($report.mcp.stdio_available)"
    Write-Output "Codex CLI: version $($report.codex.version), registration $($report.codex.registration_state); native chat availability not checked"
    Write-Output "Skill: installed $($report.skill.installed), $($report.skill.file_count) files, fingerprint $($report.skill.fingerprint_sha256)"
    Write-Output "Source comparison: MCP $($report.mcp.source_comparison.status), skill $($report.skill.source_comparison.status)"
    foreach ($component in @('mcp','skill')) {
        foreach ($difference in @(Value $report[$component].source_comparison 'differences' @())) {Write-Output "$component source difference: $($difference.state) $($difference.relative_path)"}
    }
    foreach ($editor in $report.metaeditor.candidates) {Write-Output "MetaEditor: build $($editor.build), $($editor.path)"}
    Write-Output "Python: available $($report.python.available), version $($report.python.version), PyYAML $($report.python.pyyaml_available)"
    foreach ($issue in $report.issues) {Write-Output "[$($issue.severity)] $($issue.message)"}
    if ($ReportPath -and $report.exit_code -ne 2) {Write-Output "Report: $(Full-Path $ReportPath)"}
}
exit $report.exit_code
