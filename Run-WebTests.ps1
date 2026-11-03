<#
.SYNOPSIS
    Unified MapGuide web-tier and API-binding test runner.

.DESCRIPTION
    Starts the selected Debug or Release mgserver in interactive mode, waits
    for its site port, runs the WebTestRunner and/or the .NET, Java and PHP API
    binding test runners, and stops the server gracefully afterward.

    The Java suite runs first when selected because it loads the Sheboygan
    sample package used by the WebTestRunner. If Java is not selected, the
    package is loaded directly before the server starts.

    Output is streamed to the console and tee'd to testlogs. A missing runner,
    a runner that executes no tests, or any failing test makes the script exit
    non-zero.

.PARAMETER Configuration
    Build configuration to test: Release (default) or Debug.

.PARAMETER Test
    One or more suites: Web, DotNet, Java, Php, Bindings (all API bindings),
    or All (the default).

.PARAMETER AdminPass
    MapGuide Administrator password for the Java and .NET API binding runners.
    Defaults to MG_TEST_ADMIN_PASS when set, otherwise "admin". The PHP tests
    currently hardcode "admin".

.PARAMETER StartupTimeoutSeconds
    Maximum time to wait for the MapGuide site port to accept connections.

.PARAMETER ShutdownTimeoutSeconds
    Maximum time to wait for mgserver to stop after it receives Ctrl+C.

.PARAMETER List
    Print the runner paths and commands without starting the server.

.EXAMPLE
    .\Run-WebTests.ps1

.EXAMPLE
    .\Run-WebTests.ps1 -Test Web

.EXAMPLE
    .\Run-WebTests.ps1 -Configuration Debug -Test Bindings

.EXAMPLE
    .\Run-WebTests.ps1 -List
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateSet('All', 'Bindings', 'Web', 'DotNet', 'Java', 'Php')]
    [string[]] $Test = @('All'),

    [string] $AdminPass = '',

    [ValidateRange(1, 600)]
    [int] $StartupTimeoutSeconds = 120,

    [ValidateRange(1, 300)]
    [int] $ShutdownTimeoutSeconds = 30,

    [switch] $List
)

$BuildRoot = $PSScriptRoot
$LogRoot = Join-Path $BuildRoot 'testlogs'
$Config = if ($Configuration -eq 'Debug') {
    @{ Bin = 'Debug64'; Install = 'dbg64'; Prefix = 'MgDbg64'; WebRunner = 'MgWebTestRunnerd.exe' }
}
else {
    @{ Bin = 'Release64'; Install = 'rel64'; Prefix = 'MgRel64'; WebRunner = 'MgWebTestRunner.exe' }
}

$ServerBin = Join-Path $BuildRoot "MgDev\Server\bin\$($Config.Bin)"
$WebBin = Join-Path $BuildRoot "MgDev\Web\bin\$($Config.Bin)"
$InstallRoot = Join-Path $BuildRoot "mg-install\$($Config.Install)"
$TestDataRoot = Join-Path $BuildRoot 'MgDev\UnitTest\TestData'
$DictionaryPath = Join-Path $BuildRoot 'MgDev\Oem\CsMap\CsMapDev\Dictionaries'
$WebConfigPath = Join-Path $WebBin 'webconfig.ini'
$BindingWebConfigPath = Join-Path $LogRoot ('{0}_WebConfig.ini' -f $Config.Prefix)
$ServerExe = Join-Path $ServerBin 'mgserver.exe'
$ServerConfigPath = Join-Path $ServerBin 'serverconfig.ini'
$SheboyganPackage = Join-Path $TestDataRoot 'Samples\Sheboygan\Sheboygan.mgp'

if ([string]::IsNullOrWhiteSpace($AdminPass)) {
    $AdminPass = if ([string]::IsNullOrWhiteSpace($env:MG_TEST_ADMIN_PASS)) {
        'admin'
    }
    else {
        $env:MG_TEST_ADMIN_PASS
    }
}

$JavaExe = $null
if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
    $javaFromHome = Join-Path $env:JAVA_HOME 'bin\java.exe'
    if (Test-Path -LiteralPath $javaFromHome -PathType Leaf) {
        $JavaExe = $javaFromHome
    }
}
if (-not $JavaExe) {
    $javaCommand = Get-Command 'java.exe' -ErrorAction SilentlyContinue
    if ($javaCommand) {
        $JavaExe = $javaCommand.Source
    }
}

$InstallTestRoot = Join-Path $InstallRoot 'Test\UnitTest'
$TestTable = [ordered]@{
    Java = @{
        Description = 'Java API binding'
        Exe = $JavaExe
        WorkDir = Join-Path $InstallTestRoot 'Java'
        Runner = Join-Path $InstallTestRoot 'Java\MgUnitTest.jar'
        Args = @('-jar', 'MgUnitTest.jar')
    }
    DotNet = @{
        Description = '.NET API binding'
        Exe = Join-Path $InstallTestRoot 'DotNet\TestRunner.exe'
        WorkDir = Join-Path $InstallTestRoot 'DotNet'
        Runner = Join-Path $InstallTestRoot 'DotNet\TestRunner.exe'
        Args = @('--admin-pass', $AdminPass)
    }
    Php = @{
        Description = 'PHP API binding'
        Exe = Join-Path $InstallRoot 'Web\Php\php.exe'
        WorkDir = Join-Path $InstallTestRoot 'Php'
        Runner = Join-Path $InstallTestRoot 'Php\RunTests.php'
        Args = @('RunTests.php')
    }
    Web = @{
        Description = 'C++ web-tier tests'
        Exe = Join-Path $WebBin $Config.WebRunner
        WorkDir = $WebBin
        Runner = Join-Path $WebBin $Config.WebRunner
        Args = @()
    }
}
$ExecutionOrder = @('Java', 'DotNet', 'Php', 'Web')

function Resolve-TestNames {
    param([string[]] $Requested)

    $selected = @{}
    foreach ($name in $Requested) {
        if ($name -ieq 'All') {
            foreach ($key in $ExecutionOrder) { $selected[$key] = $true }
        }
        elseif ($name -ieq 'Bindings') {
            foreach ($key in @('Java', 'DotNet', 'Php')) { $selected[$key] = $true }
        }
        else {
            $selected[$name] = $true
        }
    }
    return @($ExecutionOrder | Where-Object { $selected.ContainsKey($_) })
}

function Get-TestParts {
    param([string] $Name)

    $definition = $TestTable[$Name]
    $testWebConfig = if ($Name -eq 'Web') { $WebConfigPath } else { $BindingWebConfigPath }
    return [pscustomobject]@{
        Name = $Name
        Description = $definition.Description
        Exe = $definition.Exe
        WorkDir = $definition.WorkDir
        Runner = $definition.Runner
        Args = $definition.Args
        Log = Join-Path $LogRoot ('{0}_{1}.txt' -f $Config.Prefix, $Name)
        DetailLog = Join-Path $LogRoot ('{0}_{1}_details.log' -f $Config.Prefix, $Name)
        WebConfig = $testWebConfig
        TestData = $TestDataRoot
        Dictionary = $DictionaryPath
    }
}

function New-BindingWebConfig {
    if (-not (Test-Path -LiteralPath $WebConfigPath -PathType Leaf)) {
        throw "Web tier configuration not found: $WebConfigPath"
    }

    $resourcesPath = Join-Path $WebBin 'Resources'
    if (-not (Test-Path -LiteralPath (Join-Path $resourcesPath 'mapguide_en.res') -PathType Leaf)) {
        throw "Web tier resources not found: $(Join-Path $resourcesPath 'mapguide_en.res')"
    }

    $logsPath = Join-Path $LogRoot 'WebLogs'
    $tempPath = Join-Path $WebBin 'Temp'
    New-Item -ItemType Directory -Path $logsPath, $tempPath -Force | Out-Null

    # Binding runners use different working directories, so resolve the
    # web-tier resources and CS-Map dictionaries outside the config file.
    $updates = @{
        LogsPath = "$logsPath\"
        MentorDictionaryPath = "$DictionaryPath\"
        ResourcesPath = "$resourcesPath\"
        TempPath = "$tempPath\"
    }
    $section = ''
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $WebConfigPath) {
        if ($line.Trim() -match '^\[(?<section>[^\]]+)\]$') {
            $section = $Matches.section
        }
        if ($section -ieq 'GeneralProperties') {
            foreach ($key in @($updates.Keys)) {
                if ($line -match "^\s*$key\s*=") {
                    $lines.Add("$key = $($updates[$key])")
                    $updates.Remove($key)
                    continue
                }
            }
            if ($line -match '^\s*(LogsPath|MentorDictionaryPath|ResourcesPath|TempPath)\s*=') {
                continue
            }
        }
        $lines.Add($line)
    }
    if ($updates.Count -gt 0) {
        throw "Could not update binding web configuration values: $($updates.Keys -join ', ')."
    }

    [System.IO.File]::WriteAllLines($BindingWebConfigPath, $lines.ToArray(), [System.Text.Encoding]::UTF8)
}

function Get-TestSkipReason {
    param([pscustomobject] $Parts)

    if (-not $Parts.Exe) {
        return 'Java runtime not found; set JAVA_HOME or add java.exe to PATH'
    }
    if (-not (Test-Path -LiteralPath $Parts.Exe -PathType Leaf)) {
        return "runner executable not found: $($Parts.Exe)"
    }
    if (-not (Test-Path -LiteralPath $Parts.Runner -PathType Leaf)) {
        return "test runner not found: $($Parts.Runner)"
    }
    if (-not (Test-Path -LiteralPath $Parts.WorkDir -PathType Container)) {
        return "working directory not found: $($Parts.WorkDir)"
    }
    if (-not (Test-Path -LiteralPath $Parts.WebConfig -PathType Leaf)) {
        return "webconfig.ini not found: $($Parts.WebConfig)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $WebBin 'Resources\mapguide_en.res') -PathType Leaf)) {
        return "web-tier resources not found: $(Join-Path $WebBin 'Resources\mapguide_en.res')"
    }
    if (-not (Test-Path -LiteralPath $Parts.TestData -PathType Container)) {
        return "test data directory not found: $($Parts.TestData)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Parts.Dictionary 'Coordsys.CSD') -PathType Leaf)) {
        return "CS-Map dictionary not found: $($Parts.Dictionary)"
    }
    if ($Parts.Name -eq 'Web' -and
        -not (Test-Path -LiteralPath (Join-Path $Parts.WorkDir 'TestData\WebLayoutUnformatted.xml') -PathType Leaf)) {
        return 'WebTestRunner test data is missing from its output directory'
    }
    if ($Parts.Name -eq 'Php') {
        $phpIni = Join-Path (Split-Path -Parent $Parts.Exe) 'php.ini'
        $phpExtension = Join-Path (Split-Path -Parent $Parts.Exe) 'ext\php_MapGuideApi.dll'
        if (-not (Test-Path -LiteralPath $phpIni -PathType Leaf) -or
            -not (Test-Path -LiteralPath $phpExtension -PathType Leaf)) {
            return 'PHP runtime is missing php.ini or the MapGuide API extension'
        }
    }
    return $null
}

function Get-IniValue {
    param(
        [string] $Path,
        [string] $Section,
        [string] $Key
    )

    $currentSection = ''
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(?<section>[^\]]+)\]$') {
            $currentSection = $Matches.section
            continue
        }
        if ($currentSection -ieq $Section -and
            $trimmed -match '^(?<key>[^=;#]+?)\s*=\s*(?<value>.*?)\s*$' -and
            $Matches.key.Trim() -ieq $Key) {
            return $Matches.value.Trim().Trim('"')
        }
    }
    throw "Configuration value '$Key' was not found in section '$Section' of '$Path'."
}

function Test-TcpPort {
    param([string] $HostName, [int] $Port)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $attempt.AsyncWaitHandle.WaitOne(300)) {
            return $false
        }
        $client.EndConnect($attempt)
        return $true
    }
    catch [System.Net.Sockets.SocketException] {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Start-MapGuideServer {
    param([int] $Port, [string] $HostName)

    $stdoutLog = Join-Path $LogRoot ('{0}_Server.txt' -f $Config.Prefix)
    $stderrLog = Join-Path $LogRoot ('{0}_Server_stderr.txt' -f $Config.Prefix)
    Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    Write-Host "Starting MapGuide server: $ServerExe run" -ForegroundColor Cyan
    Write-Host "  Site endpoint: ${HostName}:$Port"
    Write-Host "  Server logs  : $stdoutLog, $stderrLog"

    return Start-Process -FilePath $ServerExe -ArgumentList @('run') `
        -WorkingDirectory $ServerBin -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
}

function Wait-MapGuideServer {
    param([System.Diagnostics.Process] $Process, [string] $HostName, [int] $Port)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "mgserver exited during startup with code $($Process.ExitCode). See testlogs\$($Config.Prefix)_Server.txt."
        }
        if (Test-TcpPort -HostName $HostName -Port $Port) {
            Write-Host "MapGuide server is listening on ${HostName}:$Port." -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out after $StartupTimeoutSeconds seconds waiting for the MapGuide site port ${HostName}:$Port."
}

function Stop-MapGuideServer {
    param([System.Diagnostics.Process] $Process)

    $Process.Refresh()
    if ($Process.HasExited) {
        return ($Process.ExitCode -eq 0)
    }

    $handlerRegistered = $false
    $stopped = $false
    try {
        if (-not ('MapGuideConsoleSignal' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MapGuideConsoleSignal
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GenerateConsoleCtrlEvent(uint controlEvent, uint processGroupId);
}
'@
        }

        Write-Host 'Stopping MapGuide server with Ctrl+C...' -ForegroundColor Cyan
        # Ignore the console signal in this process; the server shares this console.
        $handlerRegistered = [MapGuideConsoleSignal]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
        if (-not $handlerRegistered) {
            throw [System.ComponentModel.Win32Exception]::new(
                [Runtime.InteropServices.Marshal]::GetLastWin32Error(),
                'Could not protect the test runner from the server stop signal.')
        }
        if (-not [MapGuideConsoleSignal]::GenerateConsoleCtrlEvent(0, 0)) {
            throw [System.ComponentModel.Win32Exception]::new(
                [Runtime.InteropServices.Marshal]::GetLastWin32Error(),
                'Could not send Ctrl+C to mgserver.')
        }
        $stopped = $Process.WaitForExit($ShutdownTimeoutSeconds * 1000)
    }
    catch {
        Write-Warning "Graceful server shutdown failed: $($_.Exception.Message)"
    }
    finally {
        if ($handlerRegistered) {
            [void] [MapGuideConsoleSignal]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
        }
    }

    if (-not $stopped) {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Write-Warning "Graceful shutdown failed; terminating mgserver process $($Process.Id)."
            try {
                $Process.Kill()
                $Process.WaitForExit()
            }
            catch {
                Write-Error "Could not terminate mgserver process $($Process.Id): $($_.Exception.Message)"
            }
        }
        return $false
    }
    if ($Process.ExitCode -ne 0) {
        Write-Warning "mgserver stopped with exit code $($Process.ExitCode)."
        return $false
    }
    Write-Host 'MapGuide server stopped.' -ForegroundColor Green
    return $true
}

function Invoke-LoggedCommand {
    param(
        [string] $Name,
        [string] $Exe,
        [string[]] $Arguments,
        [string] $WorkDir,
        [string] $Log
    )

    if (Test-Path -LiteralPath $Log -PathType Leaf) {
        Remove-Item -LiteralPath $Log -Force
    }
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    Write-Host "  WorkDir : $WorkDir"
    $commandText = $Exe
    if ($Arguments.Count -gt 0) {
        $commandText += ' ' + ($Arguments -join ' ')
    }
    if (-not [string]::IsNullOrEmpty($AdminPass)) {
        $commandText = $commandText.Replace($AdminPass, '<redacted>')
    }
    Write-Host "  Command : $commandText"
    Write-Host "  Log     : $Log"

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $WorkDir
    try {
        & $Exe @Arguments 2>&1 |
            ForEach-Object {
                $line = $_.ToString()
                if (-not [string]::IsNullOrEmpty($AdminPass)) {
                    $line = $line.Replace($AdminPass, '<redacted>')
                }
                $line
            } | Tee-Object -FilePath $Log | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $timer.Stop()

    return [pscustomobject]@{
        ExitCode = $exitCode
        Duration = $timer.Elapsed
    }
}

function Clear-TestDatabases {
    $databaseFiles = @(
        'Unicode\UnicodeTest.db',
        'WmsTest\WmsTest.db',
        'WebLayout\WebLayoutTest.db',
        'WfsTest\WfsTest.db',
        'MapLayer\MapLayerTest.db',
        'ServerAdmin\ServerAdminTest.db',
        'MappingService\MappingServiceTest.db',
        'SiteService\SiteServiceTest.db',
        'FeatureService\FeatureServiceTest.db',
        'DrawingService\DrawingServiceTest.db',
        'ResourceService\ResourceServiceTest.db'
    )
    foreach ($relativePath in $databaseFiles) {
        $path = Join-Path $TestDataRoot $relativePath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Get-TestOutcome {
    param([pscustomobject] $Parts, [int] $ExitCode)

    $cases = 0
    $logFailures = $false
    $text = if (Test-Path -LiteralPath $Parts.Log -PathType Leaf) {
        Get-Content -LiteralPath $Parts.Log -Raw
    }
    else {
        ''
    }

    if ($Parts.Name -eq 'Web') {
        $success = [regex]::Match($text, 'All tests passed \(\d+ assertions? in (?<cases>\d+) test cases?\)')
        if ($success.Success) {
            $cases = [int] $success.Groups['cases'].Value
        }
        else {
            $caseSummary = [regex]::Match($text, '(?m)^\s*test cases:\s*(?<cases>\d+)\s*\|')
            if ($caseSummary.Success) {
                $cases = [int] $caseSummary.Groups['cases'].Value
            }
        }
        $logFailures = [regex]::IsMatch($text, '(?m)^\s*test cases:\s*\d+\s*\|.*?\b[1-9]\d*\s+failed')
    }
    else {
        $summary = [regex]::Match($text, 'Tests failed/run:\s*(?<failed>\d+)\s*/\s*(?<cases>\d+)')
        if ($summary.Success) {
            $cases = [int] $summary.Groups['cases'].Value
            $logFailures = ([int] $summary.Groups['failed'].Value -gt 0)
        }
    }

    return [pscustomobject]@{
        Cases = $cases
        ZeroTests = ($cases -eq 0)
        LogFailures = $logFailures -and ($ExitCode -eq 0)
    }
}

function Invoke-Test {
    param([pscustomobject] $Parts)

    if ($Parts.Name -in @('Java', 'DotNet', 'Php')) {
        Clear-TestDatabases
    }

    $env:MG_TEST_WEBCONFIG_PATH = $Parts.WebConfig
    $env:MG_TEST_DATA_PATH = $Parts.TestData
    $env:MG_TEST_LOG_PATH = $Parts.DetailLog
    $env:MG_TEST_ADMIN_PASS = $AdminPass
    $env:MENTOR_DICTIONARY_PATH = $Parts.Dictionary

    if (Test-Path -LiteralPath $Parts.DetailLog) {
        Remove-Item -LiteralPath $Parts.DetailLog -Force
    }
    if ($Parts.Name -eq 'Php') {
        $phpLog = Join-Path $Parts.WorkDir 'UnitTests.log'
        Remove-Item -LiteralPath $phpLog -Force -ErrorAction SilentlyContinue
    }

    $run = Invoke-LoggedCommand -Name $Parts.Name -Exe $Parts.Exe -Arguments $Parts.Args `
        -WorkDir $Parts.WorkDir -Log $Parts.Log

    if ($Parts.Name -eq 'Php') {
        $phpLog = Join-Path $Parts.WorkDir 'UnitTests.log'
        if (Test-Path -LiteralPath $phpLog -PathType Leaf) {
            Copy-Item -LiteralPath $phpLog -Destination $Parts.DetailLog -Force
        }
    }

    $outcome = Get-TestOutcome -Parts $Parts -ExitCode $run.ExitCode
    return [pscustomobject]@{
        Name = $Parts.Name
        ExitCode = $run.ExitCode
        Skipped = $false
        SkipReason = $null
        Duration = $run.Duration
        Cases = $outcome.Cases
        ZeroTests = $outcome.ZeroTests
        LogFailures = $outcome.LogFailures
    }
}

function Write-Summary {
    param([object[]] $Results)

    Write-Host ''
    Write-Host '=== Web/API Test Summary ===' -ForegroundColor Cyan
    foreach ($result in $Results) {
        if ($result.Skipped) {
            Write-Host ("  {0,-10} SKIPPED: {1}" -f $result.Name, $result.SkipReason) -ForegroundColor Yellow
            continue
        }
        $elapsed = if ($null -ne $result.Duration) { ' [' + $result.Duration.ToString('hh\:mm\:ss\.f') + ']' } else { '' }
        if ($result.ZeroTests) {
            Write-Host ("  {0,-10} FAILED (no test cases ran){1}" -f $result.Name, $elapsed) -ForegroundColor Red
        }
        elseif ($result.LogFailures) {
            Write-Host ("  {0,-10} FAILED (log reports failures; exit 0){1}" -f $result.Name, $elapsed) -ForegroundColor Red
        }
        elseif ($result.ExitCode -eq 0) {
            Write-Host ("  {0,-10} OK ({1} test cases){2}" -f $result.Name, $result.Cases, $elapsed) -ForegroundColor Green
        }
        else {
            Write-Host ("  {0,-10} FAILED (exit {1}){2}" -f $result.Name, $result.ExitCode, $elapsed) -ForegroundColor Red
        }
    }
}

$testsToRun = Resolve-TestNames -Requested $Test
if ($List) {
    Write-Host "Available MapGuide web/API test suites (Configuration: $Configuration)" -ForegroundColor Cyan
    Write-Host "  Server : $ServerExe run"
    Write-Host "  Web cfg: $WebConfigPath"
    Write-Host "  API cfg: $BindingWebConfigPath (generated for test-runner resource paths)"
    Write-Host "  Data   : $TestDataRoot"
    foreach ($name in $ExecutionOrder) {
        $parts = Get-TestParts -Name $name
        $runner = if ($parts.Exe) { $parts.Exe } else { 'java.exe (JAVA_HOME or PATH)' }
        Write-Host ("  {0,-10} {1}" -f $name, $parts.Description)
        Write-Host ("  {0,-10} {1}" -f '', $runner)
        if ($name -in @('Java', 'Php')) {
            Write-Host ("  {0,-10} {1}" -f '', $parts.Runner)
        }
    }
    Write-Host '  Bindings selects DotNet, Java, and Php. All selects every suite.'
    Write-Host ''
    Write-Host 'The runner refuses an already-running mgserver, starts one server for the selected suites, and stops it afterward.'
    return
}

if (@($testsToRun | Where-Object { $_ -ne 'Web' }).Count -gt 0) {
    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    }
    New-BindingWebConfig
}

$results = @()
$runnable = @()
foreach ($name in $testsToRun) {
    $parts = Get-TestParts -Name $name
    $skipReason = Get-TestSkipReason -Parts $parts
    if ($skipReason) {
        Write-Warning "[$name] SKIPPED: $skipReason"
        $results += [pscustomobject]@{
            Name = $name
            ExitCode = $null
            Skipped = $true
            SkipReason = $skipReason
            Duration = $null
            Cases = 0
            ZeroTests = $false
            LogFailures = $false
        }
    }
    else {
        $runnable += $parts
    }
}

if ($runnable.Count -eq 0) {
    Write-Summary -Results $results
    exit 1
}

$running = @(Get-Process -Name 'mgserver' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Warning ("A MapGuide server is already running (process id {0}). Stop it before running these tests." -f (($running | ForEach-Object { $_.Id }) -join ', '))
    exit 2
}

if (-not (Test-Path -LiteralPath $ServerExe -PathType Leaf)) {
    Write-Error "MapGuide server executable not found: $ServerExe"
    exit 1
}
if (-not (Test-Path -LiteralPath $ServerConfigPath -PathType Leaf)) {
    Write-Error "MapGuide server configuration not found: $ServerConfigPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

$oldEnvironment = @{}
foreach ($name in @('MG_TEST_WEBCONFIG_PATH', 'MG_TEST_DATA_PATH', 'MG_TEST_LOG_PATH', 'MG_TEST_ADMIN_PASS', 'MENTOR_DICTIONARY_PATH')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$env:MG_TEST_WEBCONFIG_PATH = $WebConfigPath
$env:MG_TEST_DATA_PATH = $TestDataRoot
$env:MG_TEST_ADMIN_PASS = $AdminPass
$env:MENTOR_DICTIONARY_PATH = $DictionaryPath

$serverProcess = $null
$fatalFailure = $false
try {
    $serverPort = [int] (Get-IniValue -Path $ServerConfigPath -Section 'SiteConnectionProperties' -Key 'Port')
    $webConfigPaths = @($runnable | Select-Object -ExpandProperty WebConfig -Unique)
    foreach ($configPath in $webConfigPaths) {
        $webPort = [int] (Get-IniValue -Path $configPath -Section 'SiteConnectionProperties' -Key 'Port')
        if ($serverPort -ne $webPort) {
            throw "The server site port ($serverPort) does not match webconfig.ini '$configPath' ($webPort)."
        }
    }
    $hostName = Get-IniValue -Path $webConfigPaths[0] -Section 'SiteConnectionProperties' -Key 'IpAddress'

    if (-not (@($runnable | Where-Object { $_.Name -eq 'Java' }).Count -gt 0)) {
        if (-not (Test-Path -LiteralPath $SheboyganPackage -PathType Leaf)) {
            throw "Sheboygan sample package not found: $SheboyganPackage"
        }
        $setupLog = Join-Path $LogRoot ('{0}_SetupSheboygan.txt' -f $Config.Prefix)
        $setup = Invoke-LoggedCommand -Name 'Load Sheboygan test package' -Exe $ServerExe `
            -Arguments @('loadpackage', $SheboyganPackage) -WorkDir $ServerBin -Log $setupLog
        if ($setup.ExitCode -ne 0 -or
            -not (Select-String -LiteralPath $setupLog -Pattern 'Package loaded\.' -Quiet)) {
            throw "mgserver loadpackage failed with exit code $($setup.ExitCode); see $setupLog."
        }
    }

    $serverProcess = Start-MapGuideServer -Port $serverPort -HostName $hostName
    Wait-MapGuideServer -Process $serverProcess -HostName $hostName -Port $serverPort

    foreach ($parts in $runnable) {
        try {
            $results += Invoke-Test -Parts $parts
        }
        catch {
            Write-Error "[$($parts.Name)] test execution failed: $($_.Exception.Message)"
            $fatalFailure = $true
            break
        }
        if ($serverProcess.HasExited) {
            Write-Error "mgserver exited while the test suites were running."
            $fatalFailure = $true
            break
        }
    }
}
catch {
    Write-Error "Web/API test run aborted: $($_.Exception.Message)"
    $fatalFailure = $true
}
finally {
    try {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            if (-not (Stop-MapGuideServer -Process $serverProcess)) {
                $fatalFailure = $true
            }
        }
    }
    finally {
        foreach ($name in $oldEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
        }
    }
}

Write-Summary -Results $results
$failed = @($results | Where-Object {
    $_.Skipped -or $_.ExitCode -ne 0 -or $_.ZeroTests -or $_.LogFailures
})
if ($fatalFailure -or $failed.Count -gt 0) {
    exit 1
}
exit 0
