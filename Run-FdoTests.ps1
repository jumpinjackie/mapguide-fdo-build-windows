<#
.SYNOPSIS
    Unified FDO unit-test runner.

.DESCRIPTION
    Consolidates the debug_test_*.bat and rel_test_*.bat scripts into a single
    PowerShell script. Each test suite is run against the Debug (fdo-dbg) or
    Release (fdo-rel) build tree. Console output is streamed live and a copy
    is tee'd to a log file under the top-level 'testlogs' directory.

.PARAMETER Configuration
    Which build tree to target: 'Debug' (default) or 'Release'.

.PARAMETER Test
    One or more test suites to run. Names are case-insensitive.
    'All' (default) runs every suite; 'Odbc' runs all ODBC sub-suites.
    Individual suites: FdoCore, Gdal, MySql, OdbcAccess, OdbcDbase,
    OdbcExcel, OdbcMySql, OdbcOracle, OdbcSqlServer, OdbcText, Ogr, PostGis,
    Sdf, Shp, Sqlite, SqlServerSpatial, Wfs, Wms.

.PARAMETER List
    Print the available suites (and the command each would run for the
    selected -Configuration) and exit without running anything.

.EXAMPLE
    .\Run-FdoTests.ps1

.EXAMPLE
    .\Run-FdoTests.ps1 -Configuration Release -Test Gdal, Ogr, Wms

.EXAMPLE
    .\Run-FdoTests.ps1 -Test Odbc

.EXAMPLE
    .\Run-FdoTests.ps1 -List

.NOTES
    If a suite needs third-party environment variables (FDOORACLE, FDOMYSQL,
    FDOPOSTGRESQL), source the matching fdoenv*.bat first, or set the
    variables before invoking this script.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',

    [string[]] $Test = @('All'),

    [switch] $List
)

# The Debug/Release build trees live next to this script.
$BuildRoot = $PSScriptRoot
# All tee'd log files are collected here.
$LogRoot = Join-Path $BuildRoot 'testlogs'

# --- Test definitions ------------------------------------------------------
# WorkDir is relative to $BuildRoot, Exe is relative to WorkDir. Suite is a
# configuration-independent extra appended after '-NoWAIT'. InitFile is
# resolved relative to $BuildRoot (the *Init.txt files now live next to this
# script). Log is the log file name written under $LogRoot.
$RdbmsDbg = 'fdo-dbg\Providers\GenericRdbms\Src\UnitTest'
$RdbmsRel = 'fdo-rel\Providers\GenericRdbms\Src\UnitTest'

$TestTable = [ordered]@{
    'FdoCore' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Fdo\UnitTest'; Exe = '..\Unmanaged\Bin\Win64\Debug\UnitTest.exe'; Log = 'Dbg64_UnitTestFDOCore.txt' }
        Release = @{ WorkDir = 'fdo-rel\Fdo\UnitTest';                 Exe = '..\Unmanaged\Bin\Win64\Release\UnitTest.exe'; Log = 'Rel64_UnitTestFDOCore.txt' }
    }
    'Gdal' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\GDAL\Src\UnitTest'; Exe = '..\..\Bin\Win64\Debug\UnitTest.exe'; Log = 'Dbg64_UnitTestGDAL.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\GDAL\Src\UnitTest'; Exe = '..\..\Bin\Win64\Release\UnitTest.exe'; Log = 'Rel64_UnitTestGDAL.txt' }
    }
    'MySql' = @{
        Suite   = $null
        InitFile = 'MySqlInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestMySql.exe'; Log = 'Dbg64_UnitTestMySQL.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestMySql.exe'; Log = 'Rel64_UnitTestMySQL.txt' }
    }
    'OdbcAccess' = @{
        Suite   = 'OdbcAccessTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_Access.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_Access.txt' }
    }
    'OdbcDbase' = @{
        Suite   = 'OdbcDbaseTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_Dbase.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_Dbase.txt' }
    }
    'OdbcExcel' = @{
        Suite   = 'OdbcExcelTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_Excel.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_Excel.txt' }
    }
    'OdbcMySql' = @{
        Suite   = 'OdbcMySqlTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_MySQL.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_MySQL.txt' }
    }
    'OdbcOracle' = @{
        Suite   = 'OdbcOracleTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_Oracle.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_Oracle.txt' }
    }
    'OdbcSqlServer' = @{
        Suite   = 'OdbcSqlServerTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_SqlServer.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_SqlServer.txt' }
    }
    'OdbcText' = @{
        Suite   = 'OdbcTextTests'
        InitFile = 'OdbcInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestOdbc.exe'; Log = 'Dbg64_UnitTestODBC_Text.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestOdbc.exe'; Log = 'Rel64_UnitTestODBC_Text.txt' }
    }
    'Ogr' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\OGR\Src\UnitTest'; Exe = '..\..\Bin\Win64\Debug\UnitTest.exe'; Log = 'Dbg64_UnitTestOGR.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\OGR\Src\UnitTest'; Exe = '..\..\Bin\Win64\Release\UnitTest.exe'; Log = 'Rel64_UnitTestOGR.txt' }
    }
    'PostGis' = @{
        Suite   = $null
        InitFile = 'PostGisInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestPostGIS.exe'; Log = 'Dbg64_UnitTestPostGIS.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestPostGIS.exe'; Log = 'Rel64_UnitTestPostGIS.txt' }
    }
    'Sdf' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\SDF\Src\UnitTest'; Exe = '..\..\Bin\Win64\Debug\UnitTest.exe'; Log = 'Dbg64_UnitTestSDF.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\SDF\Src\UnitTest'; Exe = '..\..\Bin\Win64\Release\UnitTest.exe'; Log = 'Rel64_UnitTestSDF.txt' }
    }
    'Shp' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\SHP\Src\UnitTest'; Exe = '..\..\Bin\Win64\Debug\UnitTest.exe'; Log = 'Dbg64_UnitTestSHP.txt'; Clean = 'fdo-dbg\Providers\SHP\TestData\clean.cmd' }
        Release = @{ WorkDir = 'fdo-rel\Providers\SHP\Src\UnitTest'; Exe = '..\..\Bin\Win64\Release\UnitTest.exe'; Log = 'Rel64_UnitTestSHP.txt'; Clean = 'fdo-rel\Providers\SHP\TestData\clean.cmd' }
    }
    'Sqlite' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\SQLite\Src\UnitTest'; Exe = '..\..\Bin\Win64\Debug\UnitTest.exe'; Log = 'Dbg64_UnitTestSQLite.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\SQLite\Src\UnitTest'; Exe = '..\..\Bin\Win64\Release\UnitTest.exe'; Log = 'Rel64_UnitTestSQLite.txt' }
    }
    'SqlServerSpatial' = @{
        Suite   = $null
        InitFile = 'SqlServerSpatialInit.txt'
        Debug   = @{ WorkDir = $RdbmsDbg; Exe = 'Dbg64\UnitTestSQLServerSpatial.exe'; Log = 'Dbg64_UnitTestSQLServerSpatial.txt' }
        Release = @{ WorkDir = $RdbmsRel; Exe = 'Rel64\UnitTestSQLServerSpatial.exe'; Log = 'Rel64_UnitTestSQLServerSpatial.txt' }
    }
    'Wms' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\WMS\Bin\Win64\Debug'; Exe = 'UnitTest.exe'; Log = 'Dbg64_UnitTestWMS.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\WMS\Bin\Win64\Release'; Exe = 'UnitTest.exe'; Log = 'Rel64_UnitTestWMS.txt' }
    }
    'Wfs' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\WFS\Bin\Win64\Debug'; Exe = 'UnitTest.exe'; Log = 'Dbg64_UnitTestWFS.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\WFS\Bin\Win64\Release'; Exe = 'UnitTest.exe'; Log = 'Rel64_UnitTestWFS.txt' }
    }
}

$OdbcSuites = @('OdbcAccess', 'OdbcDbase', 'OdbcExcel', 'OdbcMySql', 'OdbcOracle', 'OdbcSqlServer', 'OdbcText')

function Get-CommandParts {
    param([string] $Name)
    $def = $TestTable[$Name]
    $cfg = $def[$Configuration]
    $wd  = Join-Path $BuildRoot $cfg.WorkDir
    $exe = Join-Path $wd $cfg.Exe
    $log = Join-Path $LogRoot $cfg.Log
    $clean = if ($cfg.Clean) { Join-Path $BuildRoot $cfg.Clean } else { $null }

    $argList = New-Object System.Collections.Generic.List[string]
    if ($def.Suite) { $argList.Add($def.Suite) }
    $argList.Add('-NoWAIT')
    if ($def.InitFile) { $argList.Add("initfiletest=$(Join-Path $BuildRoot $def.InitFile)") }

    return [pscustomobject]@{
        Name    = $Name
        WorkDir = $wd
        Exe     = $exe
        Log     = $log
        Clean   = $clean
        Args    = $argList
    }
}

function Resolve-TestNames {
    param([string[]] $Requested)
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Requested) {
        if ($name -ieq 'All') {
            foreach ($key in $TestTable.Keys) { $resolved.Add([string] $key) }
            continue
        }
        if ($name -ieq 'Odbc') {
            foreach ($suite in $OdbcSuites) { $resolved.Add($suite) }
            continue
        }
        $match = $TestTable.Keys | Where-Object { $_ -ieq $name }
        if ($match) {
            $resolved.Add([string] $match)
        }
        else {
            Write-Warning "Unknown test '$name' (use -List to see available suites)."
        }
    }

    # De-duplicate while preserving order.
    $seen = @{}
    return @($resolved | Where-Object { -not $seen[$_] -and ($seen[$_] = $true) })
}

function Invoke-TestSuite {
    param([string] $Name)
    $parts = Get-CommandParts -Name $Name

    if (-not (Test-Path -LiteralPath $parts.WorkDir -PathType Container)) {
        Write-Warning "[$Name] SKIPPED: working directory not found: $($parts.WorkDir)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true }
    }
    if (-not (Test-Path -LiteralPath $parts.Exe -PathType Leaf)) {
        Write-Warning "[$Name] SKIPPED: executable not found: $($parts.Exe)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true }
    }

    Write-Host ''
    Write-Host "=== $Name [$Configuration] ===" -ForegroundColor Cyan
    Write-Host "  WorkDir : $($parts.WorkDir)"
    Write-Host "  Command : $($parts.Exe) $($parts.Args -join ' ')"
    Write-Host "  Log     : $($parts.Log)"

    if ($parts.Clean -and (Test-Path -LiteralPath $parts.Clean -PathType Leaf)) {
        Write-Host "  Clean   : $($parts.Clean)"
        Push-Location -LiteralPath (Split-Path -Parent $parts.Clean)
        try {
            cmd.exe /c $parts.Clean | Out-Host
        }
        finally {
            Pop-Location
        }
    }

    Push-Location -LiteralPath $parts.WorkDir
    try {
        & $parts.Exe @($parts.Args) 2>&1 | Tee-Object -FilePath $parts.Log | Out-Host
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $color = if ($code -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  Exit    : $code" -ForegroundColor $color
    return [pscustomobject]@{ Name = $Name; ExitCode = $code; Skipped = $false }
}

# --- Entry point -----------------------------------------------------------
if ($List) {
    Write-Host "Available FDO test suites (Configuration: $Configuration)" -ForegroundColor Cyan
    foreach ($key in $TestTable.Keys) {
        $parts = Get-CommandParts -Name ([string] $key)
        Write-Host ("  {0,-18} {1} {2}" -f $key, $parts.Exe, ($parts.Args -join ' '))
    }
    Write-Host ''
    Write-Host "Pseudo-names: All (every suite), Odbc (all ODBC sub-suites)."
    return
}

$testsToRun = Resolve-TestNames -Requested $Test
if (-not $testsToRun) {
    Write-Warning 'Nothing to run (no matching test suites).'
    exit 0
}

if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

Write-Host "Running $($testsToRun.Count) suite(s) against $Configuration tree at:" -ForegroundColor Cyan
Write-Host "  $BuildRoot"

$results = foreach ($name in $testsToRun) {
    Invoke-TestSuite -Name $name
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
foreach ($r in $results) {
    if ($r.Skipped) {
        Write-Host ("  {0,-18} SKIPPED" -f $r.Name) -ForegroundColor Yellow
    }
    elseif ($r.ExitCode -eq 0) {
        Write-Host ("  {0,-18} OK (exit 0)" -f $r.Name) -ForegroundColor Green
    }
    else {
        Write-Host ("  {0,-18} FAILED (exit {1})" -f $r.Name, $r.ExitCode) -ForegroundColor Red
    }
}

$failed = @($results | Where-Object { -not $_.Skipped -and $_.ExitCode -ne 0 })
if ($failed.Count -gt 0) {
    exit 1
}
exit 0
