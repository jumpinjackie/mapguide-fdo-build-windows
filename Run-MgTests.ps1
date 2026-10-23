<#
.SYNOPSIS
    Unified MapGuide server unit-test runner.

.DESCRIPTION
    Runs the MapGuide server test module (MgUnitTesting.dll) through the
    product's own entry point, "mgserver test <scope>", against the Debug or
    Release build tree. The server starts and stops itself around the run, so
    nothing has to be installed, configured or left running.

    Console output is streamed live and a copy is tee'd to a log file under
    the top-level 'testlogs' directory, next to the FDO suite logs.

    The test data the suites read lives in MgDev\UnitTest\TestData and is
    staged to <server bin>\..\UnitTestFiles by the server build's PostBuild
    step, which is the path the test module reads. A missing executable or a
    missing test-data directory is reported as SKIPPED, not as a pass.

.PARAMETER Configuration
    Which build tree to target: 'Release' (default) or 'Debug'. The tests run
    against the build output in MgDev\Server\bin\<Configuration>64, so the
    tree has to have been built with mapguide_rel.bat / mapguide_dbg.bat.

    Release is the default because that is the configuration that is normally
    built here and the one the rendering-heavy suites were timed on; a Debug
    pass does not validate the Release build, and vice versa, so run both when
    a change could behave differently under optimization.

.PARAMETER Test
    One or more scopes to run. Names are case-insensitive.
    'All' (default) runs every scope.

    A scope is a Catch2 tag registered by the test module, and it corresponds
    to one test source file under MgDev\Server\src\UnitTesting. -List prints
    the mapping, including which product code each one covers.

.PARAMETER List
    Print the available scopes (and the command each would run for the
    selected -Configuration) and exit without running anything.

.EXAMPLE
    .\Run-MgTests.ps1

.EXAMPLE
    .\Run-MgTests.ps1 -Test Misc

.EXAMPLE
    .\Run-MgTests.ps1 -Configuration Debug -Test FeatureService

.EXAMPLE
    .\Run-MgTests.ps1 -Test Geometry, MdfModel

.EXAMPLE
    .\Run-MgTests.ps1 -List

.NOTES
    The scope must be the bare suite name. MgTestCommand brackets whatever it
    is given ("[...]"), and the per-suite test-data setup matches the same
    bare name, so passing a tag expression such as "Misc]~[SlowTests" (which
    does parse as a Catch2 filter) runs the tests with none of their data
    prepared and fails them for the wrong reason.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [string[]] $Test = @('All'),

    [switch] $List
)

# The Debug/Release build trees live next to this script.
$BuildRoot = $PSScriptRoot
# All tee'd log files are collected here.
$LogRoot = Join-Path $BuildRoot 'testlogs'

# --- Test definitions ------------------------------------------------------
# Key is the scope accepted by "mgserver test", which is the Catch2 tag the
# suite registers. Source is the file that registers it and Covers names the
# product area the suite exercises, so a change can be matched to a scope.
$TestTable = [ordered]@{
    'CoordinateSystem'   = @{ Source = 'TestCoordinateSystem.cpp';   Covers = 'Common\CoordinateSystem' }
    'DrawingService'     = @{ Source = 'TestDrawingService.cpp';     Covers = 'Server\Services\Drawing' }
    'FeatureService'     = @{ Source = 'TestFeatureService.cpp';     Covers = 'Server\Services\Feature' }
    'Geometry'           = @{ Source = 'TestGeometry.cpp';           Covers = 'Common\Geometry' }
    'KmlService'         = @{ Source = 'TestKmlService.cpp';         Covers = 'Server\Services\Kml' }
    'LogManager'         = @{ Source = 'TestLogManager.cpp';         Covers = 'Server\Common\LogManager' }
    'MappingService'     = @{ Source = 'TestMappingService.cpp';     Covers = 'Server\Services\Mapping' }
    'MdfModel'           = @{ Source = 'TestMdfModel.cpp';           Covers = 'Common\MdfModel, Common\MdfParser' }
    'Misc'               = @{ Source = 'TestMisc.cpp';               Covers = 'Common (misc), Server\Services\Resource, Server\Services\Site' }
    'Performance'        = @{ Source = 'TestPerformance.cpp';        Covers = 'Server performance checks' }
    'RenderingService'   = @{ Source = 'TestRenderingService.cpp';   Covers = 'Server\Services\Rendering' }
    'RasterStylization'  = @{ Source = 'TestRasterStylization.cpp';  Covers = 'Server\Renderers (raster)' }
    'ResourceService'    = @{ Source = 'TestResourceService.cpp';    Covers = 'Server\Services\Resource' }
    'ServerAdminService' = @{ Source = 'TestServerAdminService.cpp'; Covers = 'Server\Services\ServerAdmin' }
    'ServerManager'      = @{ Source = 'TestServerManager.cpp';      Covers = 'Server\Core\ServerManager' }
    'ServiceManager'     = @{ Source = 'TestServiceManager.cpp';     Covers = 'Server\Core\ServiceManager' }
    'SiteManager'        = @{ Source = 'TestSiteManager.cpp';        Covers = 'Server\Core\SiteManager' }
    'SiteService'        = @{ Source = 'TestSiteService.cpp';        Covers = 'Server\Services\Site' }
    'Stylization'        = @{ Source = 'TestStylization.cpp';        Covers = 'Server\Renderers (vector stylization helpers)' }
    'TileService'        = @{ Source = 'TestTileService.cpp';        Covers = 'Server\Services\Tile' }
    'ProfilingService'   = @{ Source = 'TestProfilingService.cpp';   Covers = 'Server\Services\Profiling' }
    'TransformMesh'      = @{ Source = 'TestTransformMesh.cpp';      Covers = 'Common\Geometry (transform mesh)' }
}

# --- Build tree selection --------------------------------------------------
$ConfigMap = @{
    Debug   = @{ Bin = 'MgDev\Server\bin\Debug64';   Prefix = 'MgDbg64' }
    Release = @{ Bin = 'MgDev\Server\bin\Release64'; Prefix = 'MgRel64' }
}

function Get-CommandParts {
    param([string] $Name)

    $cfg = $ConfigMap[$Configuration]
    $wd = Join-Path $BuildRoot $cfg.Bin
    return [pscustomobject]@{
        Name      = $Name
        WorkDir   = $wd
        Exe       = Join-Path $wd 'mgserver.exe'
        TestData  = Join-Path (Split-Path -Parent $wd) 'UnitTestFiles'
        Log       = Join-Path $LogRoot ('{0}_{1}.txt' -f $cfg.Prefix, $Name)
        Args      = @('test', $Name)
    }
}

function Format-Elapsed {
    param([TimeSpan] $Elapsed)
    if ($Elapsed.TotalHours -ge 1) {
        return ('{0}h {1}m {2:0.0}s' -f [int] $Elapsed.TotalHours, $Elapsed.Minutes, ($Elapsed.Seconds + $Elapsed.Milliseconds / 1000))
    }
    if ($Elapsed.TotalMinutes -ge 1) {
        return ('{0}m {1:0.0}s' -f [int] $Elapsed.TotalMinutes, ($Elapsed.Seconds + $Elapsed.Milliseconds / 1000))
    }
    return ('{0:0.00}s' -f $Elapsed.TotalSeconds)
}

function Resolve-TestNames {
    param([string[]] $Requested)
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Requested) {
        if ($name -ieq 'All') {
            foreach ($key in $TestTable.Keys) { $resolved.Add([string] $key) }
            continue
        }
        $match = $TestTable.Keys | Where-Object { $_ -ieq $name }
        if ($match) {
            $resolved.Add([string] $match)
        }
        else {
            Write-Warning "Unknown test scope '$name' (use -List to see available scopes)."
        }
    }

    # De-duplicate while preserving order.
    $seen = @{}
    return @($resolved | Where-Object { -not $seen[$_] -and ($seen[$_] = $true) })
}

# The test cases live in MgUnitTesting.dll, so a rebuild of that module is what
# makes an edited or added test case visible. A binary older than the newest
# test source silently runs the previous tests and reports a green result, which
# is the one failure mode this runner cannot see for itself.
function Test-TestModuleAge {
    param([pscustomobject] $Parts)

    $module = if ($Configuration -eq 'Debug') { 'MgUnitTestingd.dll' } else { 'MgUnitTesting.dll' }
    $modulePath = Join-Path (Split-Path -Parent $Parts.Exe) $module
    $sourceDir = Join-Path $BuildRoot 'MgDev\Server\src\UnitTesting'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { return }
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { return }

    $newest = Get-ChildItem -LiteralPath $sourceDir -Filter '*.cpp' -File |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $newest) { return }

    if ((Get-Item -LiteralPath $modulePath).LastWriteTime -lt $newest.LastWriteTime) {
        $wrapper = if ($Configuration -eq 'Debug') { 'mapguide_dbg.bat' } else { 'mapguide_rel.bat' }
        Write-Warning ("{0} is older than {1}; rebuild with '{2} -w=server', or the tests that ran are the previous ones." -f $module, $newest.Name, $wrapper)
    }
}

# --- Result detection ------------------------------------------------------
# The test module runs under Catch2 v2, which ends a run with exactly one
# summary, in one of two shapes:
#   success: "All tests passed (N assertions in M test cases)"
#   failure: "test cases:   603 |   600 passed |   3 failed"
#            "assertions: 48839 | 48836 passed |   3 failed"
# The exit code is the primary signal (MgTestCommand turns a negative result
# positive and Catch2 returns the failed-assertion count), but the summary is
# read as well so a run that reports failures while exiting 0 is not reported
# as a pass.
$CatchSuccessRegex = 'All tests passed \((?<assertions>\d+) assertions? in (?<cases>\d+) test cases?\)'
$CatchCaseRegex = '(?m)^\s*test cases:\s*(?<cases>\d+)\s*\|(?<rest>.*)$'
$CatchFailedRegex = '(?m)^\s*(?:test cases|assertions):\s*\d+\s*\|.*?\b(?<n>[1-9]\d*) failed'

function Invoke-SuiteChunk {
    param([string] $Name)

    $parts = Get-CommandParts -Name $Name

    if (-not (Test-Path -LiteralPath $parts.WorkDir -PathType Container)) {
        Write-Warning "[$Name] SKIPPED: working directory not found: $($parts.WorkDir)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true; Duration = $null; ZeroTests = $false; LogFailures = $false; Cases = 0 }
    }
    if (-not (Test-Path -LiteralPath $parts.Exe -PathType Leaf)) {
        Write-Warning "[$Name] SKIPPED: executable not found: $($parts.Exe) (build this $Configuration tree first)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true; Duration = $null; ZeroTests = $false; LogFailures = $false; Cases = 0 }
    }
    if (-not (Test-Path -LiteralPath $parts.TestData -PathType Container)) {
        Write-Warning "[$Name] SKIPPED: test data directory not found: $($parts.TestData) (rebuild the server so PostBuild stages MgDev\UnitTest\TestData)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true; Duration = $null; ZeroTests = $false; LogFailures = $false; Cases = 0 }
    }

    Write-Host ''
    Write-Host "=== $Name [$Configuration] ===" -ForegroundColor Cyan
    Write-Host "  WorkDir : $($parts.WorkDir)"
    Write-Host "  Command : $($parts.Exe) $($parts.Args -join ' ')"
    Write-Host "  Log     : $($parts.Log)"

    # A previous run's log would otherwise still hold its failures when the
    # scan below reads the file.
    Remove-Item -LiteralPath $parts.Log -Force -ErrorAction SilentlyContinue

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $parts.WorkDir
    try {
        & $parts.Exe @($parts.Args) 2>&1 | Tee-Object -FilePath $parts.Log | Out-Host
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $stopwatch.Stop()
    $duration = $stopwatch.Elapsed

    $color = if ($code -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  Exit    : $code" -ForegroundColor $color
    Write-Host "  Elapsed : $(Format-Elapsed -Elapsed $duration)"

    $zeroTests = $false
    $logFailures = $false
    $cases = 0
    if (Test-Path -LiteralPath $parts.Log -PathType Leaf) {
        $logText = Get-Content -LiteralPath $parts.Log -Raw

        $success = [regex]::Match($logText, $CatchSuccessRegex)
        if ($success.Success) {
            $cases = [int] $success.Groups['cases'].Value
        }
        else {
            $caseInfo = [regex]::Match($logText, $CatchCaseRegex)
            if ($caseInfo.Success) { $cases = [int] $caseInfo.Groups['cases'].Value }
        }

        if ($cases -eq 0) {
            $zeroTests = $true
            Write-Warning "[$Name] the run reported no test cases, so nothing was actually verified."
        }

        if (($code -eq 0) -and [regex]::IsMatch($logText, $CatchFailedRegex)) {
            $logFailures = $true
            Write-Warning "[$Name] the log reports failing test cases but the executable exited 0."
        }
    }

    return [pscustomobject]@{
        Name        = $Name
        ExitCode    = $code
        Skipped     = $false
        Duration    = $duration
        ZeroTests   = $zeroTests
        LogFailures = $logFailures
        Cases       = $cases
    }
}

# --- Entry point -----------------------------------------------------------
if ($List) {
    Write-Host "Available MapGuide test scopes (Configuration: $Configuration)" -ForegroundColor Cyan
    foreach ($key in $TestTable.Keys) {
        $parts = Get-CommandParts -Name ([string] $key)
        $def = $TestTable[$key]
        Write-Host ("  {0,-18} {1} {2}" -f $key, $parts.Exe, ($parts.Args -join ' '))
        Write-Host ("  {0,-18} covers {1} ({2})" -f '', $def.Covers, $def.Source) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host "Pseudo-name: All (every scope). A scope is a Catch2 tag, so the finest"
    Write-Host "granularity is one test source file; tag expressions are not supported (see -Test)."
    return
}

$testsToRun = Resolve-TestNames -Requested $Test
if (-not $testsToRun) {
    Write-Warning 'Nothing to run (no matching test scopes).'
    exit 0
}

# The server owns the site and the repository for the duration of a run, so a
# second instance already running would make every suite fail for the wrong
# reason. Report it rather than working around it.
$running = @(Get-Process -Name 'mgserver' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Warning ("A MapGuide server is already running (process id {0}). Stop it and re-run: the tests start and stop their own server." -f (($running | ForEach-Object { $_.Id }) -join ', '))
    exit 2
}

if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

Write-Host "Running $($testsToRun.Count) scope(s) against $Configuration at:" -ForegroundColor Cyan
Write-Host "  $(Join-Path $BuildRoot $ConfigMap[$Configuration].Bin)"

Test-TestModuleAge -Parts (Get-CommandParts -Name ([string] $testsToRun[0]))

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$results = foreach ($name in $testsToRun) {
    Invoke-SuiteChunk -Name $name
}
$totalStopwatch.Stop()

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
foreach ($r in $results) {
    $elapsedText = if ($null -ne $r.Duration) { ' [' + (Format-Elapsed -Elapsed $r.Duration) + ']' } else { '' }
    if ($r.Skipped) {
        Write-Host ("  {0,-18} SKIPPED" -f $r.Name) -ForegroundColor Yellow
    }
    elseif ($r.ZeroTests) {
        Write-Host ("  {0,-18} FAILED (no test cases ran){1}" -f $r.Name, $elapsedText) -ForegroundColor Red
    }
    elseif ($r.LogFailures) {
        Write-Host ("  {0,-18} FAILED (log reports failures; exit 0){1}" -f $r.Name, $elapsedText) -ForegroundColor Red
    }
    elseif ($r.ExitCode -eq 0) {
        Write-Host ("  {0,-18} OK ({1} test cases){2}" -f $r.Name, $r.Cases, $elapsedText) -ForegroundColor Green
    }
    else {
        Write-Host ("  {0,-18} FAILED (exit {1}){2}" -f $r.Name, $r.ExitCode, $elapsedText) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ("  Total elapsed: {0}" -f (Format-Elapsed -Elapsed $totalStopwatch.Elapsed)) -ForegroundColor Cyan

$failed = @($results | Where-Object { -not $_.Skipped -and (($_.ExitCode -ne 0) -or $_.ZeroTests -or $_.LogFailures) })
if ($failed.Count -gt 0) {
    exit 1
}
exit 0
