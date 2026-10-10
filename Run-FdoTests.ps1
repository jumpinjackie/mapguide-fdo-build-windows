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
    Individual suites: FdoCore, Gdal, KingOracle, MySql, OdbcAccess, OdbcDbase,
    OdbcExcel, OdbcMySql, OdbcOracle, OdbcSqlServer, OdbcText, Ogr, PostGis,
    Sdf, Shp, Sqlite, SqlServerSpatial, Wfs, Wms.

.PARAMETER Fixture
    One or more CppUnit registry (fixture) names to run instead of the whole
    suite. The name is the class's named registration, e.g. FdoSelectTest,
    FdoFilterTest, SelectTests. Requires exactly one -Test suite. Prefer this
    over a full suite when iterating: it is far faster and attributes a
    failure or a leak to a single test. A name that matches nothing runs zero
    tests, which this runner reports as a failure.

.PARAMETER List
    Print the available suites (and the command each would run for the
    selected -Configuration) and exit without running anything.

.PARAMETER Timing
    Emit a per-test timing breakdown for each suite. The GenericRdbms tests
    print a "<Class>.<test> (<timestamp>):" marker as each test starts, so the
    gap between consecutive markers gives the per-test wall clock time (the
    test body plus that test's setUp/tearDown). Where a test prints
    "Elapsed: N seconds" for explicitly instrumented work, that is reported
    alongside so measured vs unmeasured time is visible. A ranked report is
    printed after each suite and the full breakdown is written next to the
    suite log as "<log>.timing.txt".

.PARAMETER RoundTrips
    Capture server-side statement counters around each suite that supports it
    (currently only the SQL Server Spatial suite, via sys.dm_exec_query_stats).
    This is a proxy for round trips: it reports how many statements were
    executed, the logical reads and CPU time, and the most-executed statements.
    The connection settings (service/username/password) are read from the
    suite's *Init.txt file at run time; the credentials need VIEW SERVER STATE.
    Counters are server-wide, so other activity on the same server is included.

.EXAMPLE
    .\Run-FdoTests.ps1

.EXAMPLE
    .\Run-FdoTests.ps1 -Configuration Release -Test Gdal, Ogr, Wms

.EXAMPLE
    .\Run-FdoTests.ps1 -Test Odbc

.EXAMPLE
    .\Run-FdoTests.ps1 -List

.EXAMPLE
    .\Run-FdoTests.ps1 -Timing

.EXAMPLE
    .\Run-FdoTests.ps1 -Test SqlServerSpatial -Timing -RoundTrips

.EXAMPLE
    .\Run-FdoTests.ps1 -Test SqlServerSpatial -Fixture FdoSelectTest -Timing

.NOTES
    If a suite needs third-party environment variables (FDOORACLE, FDOMYSQL,
    FDOPOSTGRESQL), source the matching fdoenv*.bat first, or set the
    variables before invoking this script.

    The KingOracle suite runs KgOraUnitTest.exe. That executable needs the
    Oracle client libraries (oci.dll and friends) either copied next to it or
    on PATH, and a reachable Oracle instance. It defaults to a local Oracle XE
    instance (//localhost:1521/xe).

    Pointing it at a different instance needs both variables below: the
    executable has two independent connection paths that read different
    variables, so setting only one leaves the other path on the //localhost
    default, failing with ORA-12541.

    - KG_DEFAULT_ORA_CONNECTION - the whole connection string, e.g.
      'Username=fdounittest;Password=fdounittest;Service=//fdodb:1521/xe;
      OracleSchema=fdounittest'. This is what CreateDefaultConnection()
      reads, so it covers most of the suite (ConnectionTests, DataTypeTests,
      SelectTests, FilterProcessorTests, InsertUpdateDeleteTests). The
      compiled-in default masks the password, so supply your own Password key.

    - KG_ORA_SERVICE - the Service/DbLink alone, e.g. '//fdodb:1521/xe', as
      read by GetService(). It covers the OCI tests (OCITests), SchemaTests
      and the raw-OCI setup in GeometryTests; KG_ORA_USERNAME and
      KG_ORA_PASSWORD override the fdounittest defaults on that path.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',

    [string[]] $Test = @('All'),

    [string[]] $Fixture,

    [switch] $List,

    [switch] $Timing,

    [switch] $RoundTrips
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
    'KingOracle' = @{
        Suite   = $null
        InitFile = $null
        Debug   = @{ WorkDir = 'fdo-dbg\Providers\KingOracle\bin\Win64\Debug'; Exe = 'KgOraUnitTest.exe'; Log = 'Dbg64_UnitTestKingOracle.txt' }
        Release = @{ WorkDir = 'fdo-rel\Providers\KingOracle\bin\Win64\Release'; Exe = 'KgOraUnitTest.exe'; Log = 'Rel64_UnitTestKingOracle.txt' }
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
        # The Microsoft Access (ACE) ODBC driver stops accepting new connections
        # part-way through a long-lived process: from roughly the 60th test
        # onwards, connects start failing with Jet -1036 "Too many client tasks",
        # even though every connection the provider opened was closed again and
        # nothing leaks (see the README's ODBC Access note). The whole suite
        # therefore runs as one process per fixture. Missing from this list is
        # the suite's MessageTest, which is registered under OdbcAccessMessageTest
        # for the purpose.
        Fixtures = @(
            'OdbcAccessFdoInsertTest'
            'OdbcAccessFdoMultiThreadTest'
            'OdbcAccessFdoSchemaTest'
            'OdbcAccessFdoSelectTest'
            'OdbcAccessFdoSqlCmdTest'
            'OdbcAccessFdoUpdateTest'
            'OdbcAccessDescribeSchemaTest'
            'OdbcAccessFdoAdvancedSelectTest'
            'OdbcAccessFdoConnectionInfoTest'
            'OdbcAccessFdoConnectTest'
            'OdbcAccessFdoDeleteTest'
            'OdbcAccessMessageTest'
        )
        # The tests run against a prefabricated .mdb, but the Delete fixture
        # removes EMPLOYEES rows without putting them back, so a second run
        # against the same file fails the row-count assertions in
        # FdoAdvancedSelectTest. Restore the datastore from the pristine copies
        # kept in the tree (next to this table's WorkDir, i.e. the exe's parent
        # directory) before every Access run.
        TestData = @('MSTest.mdb', 'Lidar.mdb')
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
        Stats   = 'SqlServer'
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
    param(
        [string] $Name,
        [string[]] $Fixture
    )
    $def = $TestTable[$Name]
    $cfg = $def[$Configuration]
    $wd  = Join-Path $BuildRoot $cfg.WorkDir
    $exe = Join-Path $wd $cfg.Exe
    $log = Join-Path $LogRoot $cfg.Log
    $clean = if ($cfg.Clean) { Join-Path $BuildRoot $cfg.Clean } else { $null }

    # Positional arguments name the CppUnit registries to run. -Fixture selects
    # specific fixtures; otherwise the suite's own selector is used. No
    # positional argument at all means "every registry in the executable".
    $registries = if ($Fixture) { @($Fixture) } elseif ($def.Suite) { @($def.Suite) } else { @() }

    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($registry in $registries) { $argList.Add($registry) }
    $argList.Add('-NoWAIT')
    if ($def.InitFile) { $argList.Add("initfiletest=$(Join-Path $BuildRoot $def.InitFile)") }

    return [pscustomobject]@{
        Name     = $Name
        WorkDir  = $wd
        Exe      = $exe
        Log      = $log
        Clean    = $clean
        Args     = $argList
        InitFile = $def.InitFile
        Stats    = $def.Stats
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

# --- Instrumentation ------------------------------------------------------
# The GenericRdbms tests write a marker as each test starts:
#   <Class>.<test> (Wed Oct  7 11:43:10 2026):
# The gap between consecutive markers attributes wall-clock time per test
# (test body plus that test's setUp/tearDown). Some tests also print
# "Elapsed: N seconds" for explicitly instrumented work.
$TestMarkerRegex = '^(?<name>\S.*?) \((?<ts>\w{3} \w{3}\s+\d+ \d{2}:\d{2}:\d{2} \d{4})\):\s*$'
$ElapsedRegex = 'Elapsed:\s+(?<sec>[0-9.]+)\s+seconds'

function ConvertFrom-TestMarkerTime {
    param([string] $Text)
    return [datetime]::ParseExact(($Text -replace '\s+', ' '), 'ddd MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture)
}

function Write-TimingReport {
    param(
        [System.Collections.Generic.List[object]] $Entries,
        [double] $Unattributed,
        [string] $LogPath
    )

    if ($Entries.Count -eq 0) {
        Write-Host '  Timing  : no per-test markers found in the output.' -ForegroundColor Yellow
        return
    }

    $attributed = 0.0
    foreach ($e in $Entries) { $attributed += $e.Duration }

    Write-Host ''
    Write-Host '  --- Timing: slowest tests ---' -ForegroundColor Yellow
    foreach ($e in ($Entries | Sort-Object Duration -Descending | Select-Object -First 15)) {
        $measured = if ($e.Measured -gt 0) { '{0:N2}s' -f $e.Measured } else { '-' }
        Write-Host ('  {0,10:N2}s  measured {1,9}  {2}' -f $e.Duration, $measured, $e.Name)
    }

    $byClass = $Entries | Group-Object { ($_.Name -split '\.')[0] } | ForEach-Object {
        [pscustomobject]@{
            Class = $_.Name
            Tests = $_.Count
            Total = ($_.Group | Measure-Object Duration -Sum).Sum
        }
    } | Sort-Object Total -Descending

    Write-Host ''
    Write-Host '  --- Timing: by test class ---' -ForegroundColor Yellow
    foreach ($c in $byClass) {
        Write-Host ('  {0,10:N2}s  {1,5} tests  {2}' -f $c.Total, $c.Tests, $c.Class)
    }

    Write-Host ''
    Write-Host ('  Timing  : {0:N1}s across {1} tests, {2:N1}s before the first test' -f $attributed, $Entries.Count, $Unattributed) -ForegroundColor DarkGray

    $timingPath = [System.IO.Path]::ChangeExtension($LogPath, '.timing.txt')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Test' + [char]9 + 'Start' + [char]9 + 'DurationSec' + [char]9 + 'MeasuredSec')
    foreach ($e in ($Entries | Sort-Object Duration -Descending)) {
        $lines.Add($e.Name + [char]9 + $e.Start.ToString('yyyy-MM-dd HH:mm:ss') + [char]9 + ('{0:N3}' -f $e.Duration) + [char]9 + ('{0:N3}' -f $e.Measured))
    }
    Set-Content -LiteralPath $timingPath -Value $lines -Encoding UTF8
    Write-Host "  Timing  : full breakdown written to $timingPath" -ForegroundColor DarkGray
}

# --- SQL Server round-trip counters ---------------------------------------
# These are a proxy for round trips: sys.dm_exec_query_stats counts how many
# times each cached statement ran. The connection settings come from the
# suite's *Init.txt so no credentials live in this script.

function Get-SqlServerTarget {
    param([string] $InitFile)
    if ([string]::IsNullOrEmpty($InitFile)) { return $null }
    $path = Join-Path $BuildRoot $InitFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    $props = @{}
    foreach ($part in ((Get-Content -LiteralPath $path -Raw) -split ';')) {
        if ($part -match '^\s*(?<k>[^=]+)=(?<v>.*)$') {
            $props[$Matches['k'].Trim().ToLowerInvariant()] = $Matches['v'].Trim()
        }
    }
    if (-not $props.ContainsKey('service') -or -not $props.ContainsKey('username') -or -not $props.ContainsKey('password')) {
        return $null
    }

    return [pscustomobject]@{
        Server   = $props['service']
        User     = $props['username']
        Password = $props['password']
    }
}

function Format-ConnStringValue {
    param([string] $Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $needsQuoting = $false
    foreach ($c in @(';', "'", '"')) {
        if ($Value.Contains($c)) { $needsQuoting = $true }
    }
    if ($Value.StartsWith(' ') -or $Value.EndsWith(' ')) { $needsQuoting = $true }
    if ($needsQuoting) { return "'" + $Value.Replace("'", "''") + "'" }
    return $Value
}

function Open-SqlServerConnection {
    param([object] $Target)
    Add-Type -AssemblyName 'System.Data' -ErrorAction Stop
    $cs = 'Server={0};Database=master;User Id={1};Password={2};TrustServerCertificate=True;Encrypt=False;Connect Timeout=5;Application Name=FDO test harness' -f `
        (Format-ConnStringValue $Target.Server), (Format-ConnStringValue $Target.User), (Format-ConnStringValue $Target.Password)
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.Open()
    return $conn
}

function Get-SqlServerQueryStats {
    param([object] $Target)
    $stats = @{}
    $conn = Open-SqlServerConnection -Target $Target
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 30
        $cmd.CommandText = @'
SELECT CONVERT(varchar(66), sql_handle, 1) + ':' + CONVERT(varchar(12), statement_start_offset) AS k,
       execution_count, total_logical_reads, total_worker_time
FROM sys.dm_exec_query_stats
'@
        $rdr = $cmd.ExecuteReader()
        while ($rdr.Read()) {
            $stats[[string] $rdr['k']] = [pscustomobject]@{
                Exec  = [long] $rdr['execution_count']
                Reads = [long] $rdr['total_logical_reads']
                Cpu   = [long] $rdr['total_worker_time']
            }
        }
        $rdr.Close()
    }
    finally { $conn.Dispose() }
    return $stats
}

function Get-SqlServerStatementText {
    param([object] $Target, [string[]] $Keys)
    $map = @{}
    if ($Keys.Count -eq 0) { return $map }
    $quoted = ($Keys | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $conn = Open-SqlServerConnection -Target $Target
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 60
        $cmd.CommandText = @"
SELECT CONVERT(varchar(66), qs.sql_handle, 1) + ':' + CONVERT(varchar(12), qs.statement_start_offset) AS k,
       SUBSTRING(st.text,
                 (qs.statement_start_offset / 2) + 1,
                 ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS t
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE CONVERT(varchar(66), qs.sql_handle, 1) + ':' + CONVERT(varchar(12), qs.statement_start_offset) IN ($quoted)
"@
        $rdr = $cmd.ExecuteReader()
        while ($rdr.Read()) { $map[[string] $rdr['k']] = [string] $rdr['t'] }
        $rdr.Close()
    }
    finally { $conn.Dispose() }
    return $map
}

function Write-RoundTripReport {
    param([object] $Target, [hashtable] $Before, [hashtable] $After, [string] $LogPath)

    $exec = [long] 0
    $reads = [long] 0
    $cpu = [long] 0
    $deltas = New-Object System.Collections.Generic.List[object]

    foreach ($k in $After.Keys) {
        $a = $After[$k]
        $be = [long] 0; $br = [long] 0; $bc = [long] 0
        if ($Before.ContainsKey($k)) {
            $b = $Before[$k]
            $be = $b.Exec; $br = $b.Reads; $bc = $b.Cpu
        }
        $de = $a.Exec - $be
        $dr = $a.Reads - $br
        $dc = $a.Cpu - $bc
        if ($de -lt 0) { $de = 0 }
        if ($dr -lt 0) { $dr = 0 }
        if ($dc -lt 0) { $dc = 0 }
        if (($de -eq 0) -and ($dr -eq 0) -and ($dc -eq 0)) { continue }
        $exec += $de
        $reads += $dr
        $cpu += $dc
        $deltas.Add([pscustomobject]@{ Key = $k; Exec = $de; Reads = $dr; Cpu = $dc })
    }

    Write-Host ''
    Write-Host '  --- SQL Server statements (round-trip proxy) ---' -ForegroundColor Yellow
    Write-Host ('  Statements executed : {0:N0}' -f $exec)
    Write-Host ('  Logical reads       : {0:N0}' -f $reads)
    Write-Host ('  CPU time            : {0:N1}s' -f ($cpu / 1000000.0))

    $top = @($deltas | Sort-Object Exec -Descending | Select-Object -First 200)
    if ($top.Count -gt 0) {
        $text = @{}
        try {
            $text = Get-SqlServerStatementText -Target $Target -Keys @($top | ForEach-Object { $_.Key })
        }
        catch {
            Write-Warning "  Could not fetch statement text: $($_.Exception.Message)"
        }
        Write-Host ''
        Write-Host '  Most-executed statements:' -ForegroundColor DarkGray
        foreach ($d in (@($top | Select-Object -First 12))) {
            $t = $text[$d.Key]
            if ($null -eq $t) { $t = '' }
            $t = ($t -replace '\s+', ' ').Trim()
            if ($t.Length -gt 110) { $t = $t.Substring(0, 110) + '...' }
            Write-Host ('    {0,9:N0}x {1,13:N0} reads {2,9:N0} ms  {3}' -f $d.Exec, $d.Reads, ($d.Cpu / 1000), $t)
        }

        if (-not [string]::IsNullOrEmpty($LogPath)) {
            $stmtPath = [System.IO.Path]::ChangeExtension($LogPath, '.statements.txt')
            $stmtLines = New-Object System.Collections.Generic.List[string]
            $stmtLines.Add("Executions`tLogicalReads`tCpuMs`tStatement")
            foreach ($d in $top) {
                $t = $text[$d.Key]
                if ($null -eq $t) { $t = '' }
                $t = ($t -replace '\s+', ' ').Trim()
                $stmtLines.Add(("{0}`t{1}`t{2}`t{3}" -f $d.Exec, $d.Reads, [int] ($d.Cpu / 1000), $t))
            }
            Set-Content -LiteralPath $stmtPath -Value $stmtLines -Encoding UTF8
            Write-Host ("  Full statement breakdown (top {0}) written to {1}" -f $top.Count, $stmtPath) -ForegroundColor DarkGray
        }
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

# --- Result detection ------------------------------------------------------
# CppUnit prints exactly one summary at the end of a run, in one of two shapes
# depending on the outputter the suite installs:
#   TextOutputter     : "OK (n tests)" | "!!!FAILURES!!!" + "Run:  n   Failures: n   Errors: n"
#   CompilerOutputter : "OK (n)"       | "Failures !!!"   + "Run: n   Failure total: n   Failures: n   Errors: n"
# The exit code is the primary pass/fail signal, but a suite whose executable
# does not propagate CppUnit's result (the GDAL provider's did not) exits 0 on
# failure; these patterns let the log act as a second opinion.
$CppUnitSuccessRegex = 'OK \((?<n>\d+)(?: tests?)?\)'
$CppUnitFailureRegex = '(?m)^\s*(?:!!!FAILURES!!!|Failures !!!)\s*$|(?m)^\s*Run:\s*\d+\s+.*?(?:Failure total|Failures|Errors):\s*[1-9]'

function Invoke-SuiteChunk {
    param(
        [string] $Name,
        [string[]] $Fixture,
        [string] $Header,
        [switch] $Append
    )
    $parts = Get-CommandParts -Name $Name -Fixture $Fixture

    if (-not (Test-Path -LiteralPath $parts.WorkDir -PathType Container)) {
        Write-Warning "[$Name] SKIPPED: working directory not found: $($parts.WorkDir)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true; Duration = $null; ZeroTests = $false }
    }
    if (-not (Test-Path -LiteralPath $parts.Exe -PathType Leaf)) {
        Write-Warning "[$Name] SKIPPED: executable not found: $($parts.Exe)"
        return [pscustomobject]@{ Name = $Name; ExitCode = $null; Skipped = $true; Duration = $null; ZeroTests = $false }
    }

    Write-Host ''
    if ($Header) { Write-Host $Header -ForegroundColor Cyan } else { Write-Host "=== $Name [$Configuration] ===" -ForegroundColor Cyan }
    Write-Host "  WorkDir : $($parts.WorkDir)"
    Write-Host "  Command : $($parts.Exe) $($parts.Args -join ' ')"
    Write-Host "  Log     : $($parts.Log)"

    $captureStats = $false
    $statsTarget = $null
    $statsBefore = $null
    if ($RoundTrips -and $parts.Stats -eq 'SqlServer') {
        try {
            $statsTarget = Get-SqlServerTarget -InitFile $parts.InitFile
            if ($null -ne $statsTarget) {
                $statsBefore = Get-SqlServerQueryStats -Target $statsTarget
                $captureStats = $true
                Write-Host "  Stats   : SQL Server statement counters via $($statsTarget.Server)"
            }
            else {
                Write-Warning "[$Name] -RoundTrips requested, but no usable connection settings were found in '$($parts.InitFile)'."
            }
        }
        catch {
            Write-Warning "[$Name] -RoundTrips: could not snapshot SQL Server counters: $($_.Exception.Message)"
            $captureStats = $false
            $statsTarget = $null
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $startedAt = [datetime]::Now

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

    $testTiming = $null
    if ($Timing) { $testTiming = New-Object System.Collections.Generic.List[object] }
    $pending = $null
    $firstMarkerTime = $null

    Push-Location -LiteralPath $parts.WorkDir
    try {
        $teeArgs = @{ FilePath = $parts.Log }
        if ($Append) {
            $teeArgs['Append'] = $true
        }
        else {
            # A chunked suite's first chunk replaces the log; without this the
            # previous run's output (including any failures) would still be in
            # the file the failure scan reads.
            Remove-Item -LiteralPath $parts.Log -Force -ErrorAction SilentlyContinue
        }

        if ($null -ne $testTiming) {
            & $parts.Exe @($parts.Args) 2>&1 | ForEach-Object {
                $text = [string] $_
                if ($text -match $TestMarkerRegex) {
                    $markerTime = ConvertFrom-TestMarkerTime -Text $Matches['ts']
                    if ($null -ne $pending) {
                        $pending.End = $markerTime
                        $testTiming.Add($pending)
                    }
                    if ($null -eq $firstMarkerTime) { $firstMarkerTime = $markerTime }
                    $pending = [pscustomobject]@{ Name = $Matches['name']; Start = $markerTime; End = $null; Measured = 0.0 }
                }
                elseif (($null -ne $pending) -and ($text -match $ElapsedRegex)) {
                    $pending.Measured = $pending.Measured + [double] $Matches['sec']
                }
                $_
            } | Tee-Object @teeArgs | Out-Host
        }
        else {
            & $parts.Exe @($parts.Args) 2>&1 | Tee-Object @teeArgs | Out-Host
        }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $stopwatch.Stop()
    $duration = $stopwatch.Elapsed
    $endedAt = [datetime]::Now

    $unattributed = 0.0
    if ($null -ne $testTiming) {
        if ($null -ne $pending) {
            $pending.End = $endedAt
            $testTiming.Add($pending)
        }
        foreach ($e in $testTiming) {
            if ($null -eq $e.End) { $e.End = $endedAt }
            $e | Add-Member -NotePropertyName Duration -NotePropertyValue ([math]::Max(0.0, ($e.End - $e.Start).TotalSeconds)) -Force
        }
        if ($null -ne $firstMarkerTime) {
            $unattributed = [math]::Max(0.0, ($firstMarkerTime - $startedAt).TotalSeconds)
        }
    }

    $color = if ($code -eq 0) { 'Green' } else { 'Red' }
    Write-Host "  Exit    : $code" -ForegroundColor $color
    Write-Host "  Elapsed : $(Format-Elapsed -Elapsed $duration)"

    if ($null -ne $testTiming) {
        Write-TimingReport -Entries $testTiming -Unattributed $unattributed -LogPath $parts.Log
    }

    if ($captureStats) {
        try {
            $statsAfter = Get-SqlServerQueryStats -Target $statsTarget
            Write-RoundTripReport -Target $statsTarget -Before $statsBefore -After $statsAfter -LogPath $parts.Log
        }
        catch {
            Write-Warning "[$Name] -RoundTrips: could not snapshot SQL Server counters: $($_.Exception.Message)"
        }
    }

    # The log is only consulted once the run has finished and its output has
    # been flushed to the file.
    $zeroTests = $false
    $logFailures = $false
    if (Test-Path -LiteralPath $parts.Log -PathType Leaf) {
        $logText = Get-Content -LiteralPath $parts.Log -Raw

        # A fixture name that matches no registry makes CppUnit run zero tests
        # and still exit 0; surface that as a failure rather than a false green.
        if ($Fixture) {
            $result = [regex]::Match($logText, $CppUnitSuccessRegex)
            if ($result.Success -and ([int] $result.Groups['n'].Value) -eq 0) {
                $zeroTests = $true
                Write-Warning "[$Name] -Fixture ($($Fixture -join ', ')) matched no tests."
            }
        }

        # Some executables do not propagate CppUnit's result to their exit code,
        # so a failing run reports exit 0. Trust the log in that case too.
        if (($code -eq 0) -and [regex]::IsMatch($logText, $CppUnitFailureRegex)) {
            $logFailures = $true
            Write-Warning "[$Name] the log reports CppUnit failures but the executable exited 0."
        }
    }

    return [pscustomobject]@{ Name = $Name; ExitCode = $code; Skipped = $false; Duration = $duration; ZeroTests = $zeroTests; LogFailures = $logFailures }
}

# Restores a suite's prefabricated test data from the pristine copies in the
# source tree, so that each run starts from the state the tests expect. Only
# suites that declare TestData are affected.
function Restore-SuiteTestData {
    param(
        [string] $Name
    )

    $def = $TestTable[$Name]
    if (-not ($def -and $def.TestData)) { return }

    $parts = Get-CommandParts -Name $Name
    $dataDir = Split-Path -Parent $parts.Exe
    foreach ($file in $def.TestData) {
        $source = Join-Path $parts.WorkDir $file
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }

        $target = Join-Path $dataDir $file
        Copy-Item -LiteralPath $source -Destination $target -Force

        # A leftover ACE lock file belongs to a database that was not shut down
        # cleanly; the driver recreates it on demand.
        $lock = [System.IO.Path]::ChangeExtension($target, '.ldb')
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue

        Write-Host "  TestData: restored $file in $dataDir" -ForegroundColor DarkGray
    }
}

# Runs a suite. A suite that declares a Fixtures list (the ODBC Access suite does,
# because of the ACE driver's per-process connection limit) is run as one process
# per fixture, with every chunk's output appended to the suite's single log file.
function Invoke-TestSuite {
    param(
        [string] $Name,
        [string[]] $Fixture
    )

    $def = $TestTable[$Name]
    if ($Fixture -or -not ($def -and $def.Fixtures)) {
        Restore-SuiteTestData -Name $Name
        return Invoke-SuiteChunk -Name $Name -Fixture $Fixture
    }

    $chunks = @($def.Fixtures)
    Write-Host ''
    Write-Host "=== $Name [$Configuration] - $($chunks.Count) fixtures, one process each ===" -ForegroundColor Cyan
    Restore-SuiteTestData -Name $Name

    $results = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $chunk = [string] $chunks[$i]
        $chunkArgs = @{
            Name    = $Name
            Fixture = @($chunk)
            Header  = "  --- [$($i + 1)/$($chunks.Count)] $chunk"
        }
        if ($i -gt 0) { $chunkArgs['Append'] = $true }
        $results.Add((Invoke-SuiteChunk @chunkArgs))
    }

    $duration = [TimeSpan]::Zero
    $code = 0
    $skippedCount = 0
    $zeroTests = $false
    $logFailures = $false
    foreach ($r in $results) {
        if ($null -ne $r.Duration) { $duration = $duration + $r.Duration }
        if ($r.Skipped) { $skippedCount++ }
        if (($null -ne $r.ExitCode) -and ($r.ExitCode -ne 0)) { $code = $r.ExitCode }
        if ($r.ZeroTests) { $zeroTests = $true }
        if ($r.LogFailures) { $logFailures = $true }
    }

    return [pscustomobject]@{
        Name        = $Name
        ExitCode    = $code
        Skipped     = ($results.Count -gt 0) -and ($skippedCount -eq $results.Count)
        Duration    = $duration
        ZeroTests   = $zeroTests
        LogFailures = $logFailures
    }
}

# --- Entry point -----------------------------------------------------------
if ($List) {
    Write-Host "Available FDO test suites (Configuration: $Configuration)" -ForegroundColor Cyan
    foreach ($key in $TestTable.Keys) {
        $parts = Get-CommandParts -Name ([string] $key)
        Write-Host ("  {0,-18} {1} {2}" -f $key, $parts.Exe, ($parts.Args -join ' '))
        $def = $TestTable[$key]
        if ($def -and $def.Fixtures) {
            Write-Host ("  {0,-18} runs as {1} fixtures, one process each" -f '', @($def.Fixtures).Count) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host "Pseudo-names: All (every suite), Odbc (all ODBC sub-suites)."
    Write-Host "Add -Fixture <registry> with a single -Test suite to run specific CppUnit fixtures instead of the whole suite."
    return
}

$testsToRun = Resolve-TestNames -Requested $Test
if (-not $testsToRun) {
    Write-Warning 'Nothing to run (no matching test suites).'
    exit 0
}

# A fixture only makes sense against one executable; more than one suite
# would apply the name to suites it does not belong to.
if ($Fixture -and $testsToRun.Count -ne 1) {
    Write-Warning ('-Fixture requires exactly one suite via -Test, but {0} were selected ({1}).' -f $testsToRun.Count, ($testsToRun -join ', '))
    exit 2
}

if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

Write-Host "Running $($testsToRun.Count) suite(s) against $Configuration tree at:" -ForegroundColor Cyan
Write-Host "  $BuildRoot"
if ($Fixture) { Write-Host ("  Fixtures: {0}" -f ($Fixture -join ', ')) -ForegroundColor DarkGray }
if ($Timing) { Write-Host '  Per-test timing is enabled (-Timing).' -ForegroundColor DarkGray }
if ($RoundTrips) {
    $statsSuites = @($testsToRun | Where-Object { $TestTable[$_].Stats -eq 'SqlServer' })
    if ($statsSuites.Count -gt 0) {
        Write-Host ('  SQL Server round-trip counters are enabled (-RoundTrips) for: {0}.' -f ($statsSuites -join ', ')) -ForegroundColor DarkGray
    }
    else {
        Write-Host '  -RoundTrips was requested, but no selected suite supports it (only SqlServerSpatial does).' -ForegroundColor Yellow
    }
}

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$results = foreach ($name in $testsToRun) {
    Invoke-TestSuite -Name $name -Fixture $Fixture
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
        Write-Host ("  {0,-18} FAILED (no tests matched the fixture){1}" -f $r.Name, $elapsedText) -ForegroundColor Red
    }
    elseif ($r.LogFailures) {
        Write-Host ("  {0,-18} FAILED (log reports failures; exit 0){1}" -f $r.Name, $elapsedText) -ForegroundColor Red
    }
    elseif ($r.ExitCode -eq 0) {
        Write-Host ("  {0,-18} OK (exit 0){1}" -f $r.Name, $elapsedText) -ForegroundColor Green
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
