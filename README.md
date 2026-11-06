# mapguide-fdo-build-windows

Ready-to-go build environment for MapGuide and FDO on Windows

Currently targets:

 * MapGuide Open Source 4.0
 * FDO 4.2

## Requirements

 * SWIG 4.3.1 (Must have `SWIG_DIR` environment variable set to install dir where swig.exe is present)
 * Java 8 SDK (Must have `JAVA_HOME` environment variable set)
 * Apache Ant (Must have `ANT_HOME` environment variable set)
 * Visual Studio 2022 or 2026 with MSVC 2019 compiler and .net 6+ SDK workloads enabled
 * 7-zip (The `7z` executable must be globally accessible from the command-line)
 * Perl (The `perl` executable must be globally accessible from the command-line)
 * WiX Toolset
 * docfx (`dotnet tool install -g docfx`)
 * Python 3.x
    * Sphinx (`pip install -U sphinx`)
 * SVN checkouts of
    * `https://svn.osgeo.org/mapguide/trunk/Tools/MgInstantSetup` -> `MgInstantSetup`
    * `https://svn.osgeo.org/fdo/branches/4.2` -> `fdo-dbg`
    * `https://svn.osgeo.org/fdo/branches/4.2` -> `fdo-rel` (or copy the `fdo-dbg` checkout)
    * MapGuide 4.0 
       * `https://svn.osgeo.org/mapguide/trunk/Installer` -> `Installer`
       * `https://svn.osgeo.org/mapguide/branches/4.0/MgDev` -> `MgDev`

## FDO Thirdparty Libraries setup

This environment is expecting to build FDO with MySQL, PostgreSQL and Oracle provider support.

Drop the required files under `fdo_rdbms_thirdparty` as follows:

 * `fdo_rdbms_thirdparty`
    * `mysql_x64`
        * `include` (Drop mysql client headers here)
        * `lib`
            * `debug` (Drop debug .lib files here)
            * `opt` (Drop release .lib files here)
    * `oracle_x64`
        * `instantclient_12_2`
            * `sdk` (Oracle Instant Client 12c files should be here)
    * `pgsql`
        * `include` (Drop PostgreSQL library headers here)
        * `lib`
            * `ms`
                * `Win64` (Drop .lib files here)

## Steps

 1. (If you want multi-platform .net packges, otherwise skip) Build MapGuide for Linux (generic target) using the [Docker environment](https://github.com/jumpinjackie/mapguide-fdo-docker-build/)
 2. (If you want multi-platform .net packges, otherwise skip) Copy the `-common-` and `-portable-` tarballs for `generic` into `mgcommon` as `mapguideopensource-common.tar.gz` and `mapguideopensource-portable.tar.gz`
 3. If wanting to build Windows Installer, set an environment variable `BUILD_INSTALLER` to `1`
 4. If wanting to build InstantSetup bundle, set an environment variable `BUILD_INSTANTSETUP` to `1`
 5. If wanting a different relase label than `Trunk`, set an environment variable `MG_RELEASE_LABEL` to your desired label (eg. `Beta2`, `RC1`, `Final`, etc)
 6. Build FDO trunk: `fdo_rel.bat`
 7. Setup MG build: `mapguide_rel_setup.bat`
   *  Generates a `mapguide_40_revision.txt` containing the SVN HEAD revision number. This file is needed for next step
 8. Run MG build: `mapguide_rel.bat`

## Re-baselining the product versions

Both trees stamp a version into their binaries, and the two are independent: FDO has no version
script, so its version is literal text in the `.rc` files, the `StampVer` command lines of the
`.vcxproj`/`.vcproj` files, the provider info headers, the managed override assemblies, the
`providers.xml` registries, the `/usr/local/fdo-4.2.0` install prefix in the build scripts and the
CMake variables, while MapGuide has `MgDev\updateversion.vbs` and `MgDev\stampassemblies.bat`, which
`mapguide_<cfg>_setup.bat` drives for a build and `Bump-Version.ps1` drives directly for a bump.

`Bump-Version.ps1` establishes a new baseline for both. It sweeps the versioned files of both FDO
working copies, sets the installer's `FDO_VERSION` property and the `MG_VER_*` constants the MapGuide
wrappers use, and then stamps the MapGuide tree with the version it was given, through the tree's own
`MgDev\updateversion.vbs` and `MgDev\stampassemblies.bat` run from the MgDev root. `-MapGuideVersion
4.0.1.0` therefore leaves the tree carrying exactly `4.0.1.0` — the `.rc` files,
`Common\ProductVersion.h` and the managed assembly versions all say it — and the stamped
`ProductVersion` is read back afterwards. The bump does not go through `mapguide_<cfg>_setup.bat`,
because that wrapper appends the SVN revision as the fourth component; it keeps that behaviour for
when it is run on its own as the build's preparation step, which turns the same tree into
`4.0.1.<revision>`.

```
.\Bump-Version.ps1 -MapGuideVersion 4.0.1.0 -FdoVersion 4.2.1.0 -WhatIf   # review first
.\Bump-Version.ps1 -MapGuideVersion 4.0.1.0 -FdoVersion 4.2.1.0
.\Bump-Version.ps1 -FdoVersion 4.2.1.0                                    # FDO only
.\Bump-Version.ps1 -MapGuideVersion 4.0.1.0                               # MapGuide only
```

Either product can be bumped on its own: a version that is omitted leaves that product where it
is, and the run then does not touch its files at all — a MapGuide-only bump rewrites the four
`MG_VER_*` constants and stamps `MgDev`, and touches nothing under `fdo-dbg`/`fdo-rel`; an FDO-only
bump rewrites the carrier list and the installer's `FDO_VERSION` and leaves `MgDev` alone, since the
MapGuide stamping only runs when `-MapGuideVersion` is given and the tree is not already carrying it.
`-SkipMapGuideStamp` writes the constants and leaves the tree as it is.

Which FDO files carry the version is not guessed and not searched for at run time: the carrier list
is captured in the script, taken from the commit that bumped FDO's baseline to 4.2 (r7529,
"Ticket #926: Update FDO Trunk version to 4.2"), extended with what was added afterwards and cut
down to the files that exist today. Only those files are read and stamped, so a bump takes about
ten seconds instead of a sweep of both working copies.

The four-component forms (`4.2.0.0`, `4,2,0,0`, `4.2.0.0000`) and the three-component form
(`/usr/local/fdo-4.2.0`, `AC_INIT(FDO,...,4.2.0,...)`, `FDORELNUMBER=4.2.0`) are all rewritten
there. Files that look similar but are not FDO's version are deliberately absent from the list —
`Thirdparty/gdal`'s "giflib 4.2.0" notes, and `Thirdparty/openssl`'s IA-64 assembler where
`4,2,0,0` is an `ar.pfs` register allocation. `-Scan` re-searches the working copies for any
carrier the list has missed and reports it, which is the thing to run after adding files to the
trees; it takes about ten seconds per tree. It asks `svn status --no-ignore` what the working copy
ignores, so the copies a build writes into the trees (the `providers.xml` copies under each
provider's `Bin`, `deps.json`, MSBuild caches, `mc`-generated `.rc` files) do not drown the real
hits, and it requires a version number to stand on its own, so numbers like `4.2.15` do not match.

`-MapGuideVersion` is stamped verbatim, all four components of it. The four wrappers take only the
first three (`MG_VER_MAJOR`/`MG_VER_MINOR`/`MG_VER_BUILD`), so the revision is added back the next
time `mapguide_<cfg>_setup.bat` runs as part of preparing a build — until then the tree carries the
exact version the bump asked for. FDO provider names are `major.minor` only (`OSGeo.SDF.4.2`), so an
FDO bump changes the version fields without renaming a provider, and the installer's
`FDO_VERSION_SMALL` stays at `4.2`. Nothing is rebuilt: run `fdo_rel.bat` (and `fdo_dbg.bat` for
Debug), then `mapguide_rel_setup.bat` again to restage the rebuilt FDO, then `mapguide_rel.bat`.

## Limitations

Debug and Release can both be built from the same `MgDev` checkout, but not in the same build
invocation: each configuration has its own FDO staging (`Oem\FDO\Lib64\Debug64` or `Lib64\Release64`,
and `Oem\FDO\Bin\Debug64` or `Release64`) and its own output directories (`MgDev\Debug64` and
`MgDev\Release64`, `mg-install\dbg64` and `mg-install\rel64`). Build the two wrappers one at a time,
never concurrently: they share `MgDev\nuget.config` and the `MgDev\packages\Installed` NuGet cache.
Re-running a setup script replaces only its own configuration's staging and leaves the other in place.
The two FDO trees (`fdo-dbg`/`fdo-rel`) are likewise one configuration each. The `MgDev` project-file
changes behind this are in the MapGuide history as r10243, and the installer's `FdoRegUtil` reference
is Installer r10244.

## SQL Server Spatial performance levers (`FDO_SQS_PERF`)

Two behaviours of the SQL Server Spatial provider and its ODBC driver are shaped by the way the FDO
test suite exercises them: the physical-schema catalog query (`sys.objects`, the "database object"
query) is re-executed for every catalog lookup, and `SQLDescribeParam()` is called for every bound
parameter, which costs a server round trip each. Together they are the largest source of the SQL
Server traffic in the `SqlServerSpatial` FDO unit-test suite and a large part of why that suite is
several times slower than the equivalent MySQL/PostGIS suites. Both can be avoided, and both are
opt-in behind one flag:

```powershell
$env:FDO_SQS_PERF="1"           # remember catalog lookups and parameter types
.\Run-FdoTests.ps1 -Test SqlServerSpatial -Timing -RoundTrips

Remove-Item Env:FDO_SQS_PERF    # (or set it to 0) use the original behaviour
```

`FDO_SQS_PERF` is read by the SQL Server Spatial schema manager (the provider) and by the SQL
Server Spatial ODBC driver. `1` enables both behaviours; any other value, including unset, keeps
the original behaviour exactly — each one is a single test of the flag in front of the original
code, so the un-flagged path is the code that was there before.

**Catalog lookups.** A named catalog lookup (a single object, or a candidate batch) that the cache
cannot already answer runs the same query the un-cached path would have run, and remembers what it
found. Objects that are not found are not remembered, so a repeat lookup of a missing object
queries again, just as it did before — the cache can never hide a database object that exists. It
is dropped when schema changes are committed. Un-qualified (bulk) catalog reads are not cached, so
the physical schema bulk load always reads the database.

**Parameter types.** `SQLDescribeParam()` is asked once per parameter of a statement text instead
of once per bind, and every later bind of that statement reuses the answer, so the arguments handed
to `SQLBindParameter()` are exactly the ones the original path builds. The answers are keyed by
statement text and connection, and are dropped when the context is torn down, when a connection
goes away, and when a statement that can change what a parameter resolves to (DDL, `USE`, ...) is
prepared.

Together they take the `FdoSelectTest` fixture from ~45 s to ~20 s and the full suite from
~24 min to ~9m30s, both `OK`.

Both paths are also leak-checked: with `FDO_CRT_LEAK_CHECK=1` the fixture leaks the same 7 blocks
(~8 KB) of pre-existing global state with the flag on as with it off, against ~5.5 MB leaked before
the schema-manager catalog reader's field lookups were made ownership-correct; after that fix the
full suite ran in 8m 12.0 s.

The provider and driver changes are in the gitignored FDO SVN tree, committed upstream as FDO r8392.

## SQL Server ODBC driver selection

The SQL Server Spatial provider chooses its ODBC driver from those registered with the ODBC driver
manager, in this order:

1. the Microsoft ODBC Driver for SQL Server, newest version first (`ODBC Driver 18 for SQL Server`
   when it is installed, then 17, 13, 11);
2. SQL Server Native Client, newest version first (`SQL Server Native Client 11.0`, then 10.0);
3. the legacy `SQL Server` driver (`sqlsrv32.dll`).

Only a driver that the driver manager lists is selected, so a driver DLL that is present on disk but
not registered is not used. The provider's ODBC layer recognizes the Microsoft ODBC Driver through
`SQLGetInfo(SQL_DRIVER_NAME)` (`msodbcsql18.dll`, ...) as well, so connections made with it still
take the SQL Server paths in `Providers\GenericRdbms\Src\SQLServerSpatial\ODBCDriver`.

The answer is resolved once per process and reused by every later connection, because a full
`SQLDrivers()` enumeration is not free: measured with a `SQLAllocHandle`/`SQLDriversW`/`SQLFreeHandle`
loop over the six drivers registered on this machine it costs about **1.9 ms**, against about
**4.5 ms** for the five failing `LoadLibrary("SQLNCLI<version>.DLL")` probes it replaced, and about
**0.7 ms** for a single successful `LoadLibrary` (which only happens when a Native Client is present
and no Microsoft ODBC Driver is). The selection is therefore already cheaper per connection than the
probe loop was, and memoizing removes the cost altogether. A driver installed after the first SQL
Server connection is picked up when the process restarts.

The generated connection string asks for `Encrypt=no;TrustServerCertificate=yes`. `Encrypt=no` keeps
the transport SQL Server Native Client used: login packets are encrypted, the session is not. ODBC
Driver 18 for SQL Server would otherwise encrypt by default, which measured ~15 us more per round
trip (6%) on a loopback connection here. `TrustServerCertificate=yes` does not turn encryption on by
itself - it only stops the driver validating the certificate when encryption happens - and it is
what lets a server configured to force encryption accept its own self-signed certificate instead of
failing with "The certificate chain was issued by an authority that is not trusted". Because it
skips validation, it does not authenticate the server; a deployment that needs that can replace the
attribute in `FdoRdbmsSqlServerConnection::GenConnectionStringParm()`.

The provider and unit-test driver changes are in the gitignored FDO SVN tree, committed upstream as
FDO r8420 and r8423.

## Batch parameter values / bulk insert for SQL Server Spatial (parked)

Separate from the round-trip work above: an external client's "bulk copy" feature asks a provider for
`FdoIInsert::GetBatchParameterValues()` and, when a provider answers, sends many features through one
insert command. The SQL Server Spatial provider answers `NULL`, so those inserts go one row per
`Execute()`.

This has been investigated but **not implemented**: the two candidate paths (an ODBC parameter-array
batch that the RDBI/ODBC layers already have the plumbing for, and a BCP-backed bulk insert behind a
new optional RDBI capability), the identity/transaction obstacles, the ABI check under the current
`freeze` mode, and the open questions for the client remain open.

## Connection and command timeouts for SQL Server Spatial (FDO ticket 880)

[ticket 880](https://trac.osgeo.org/fdo/ticket/880) reports that a temporarily unavailable SQL Server
leaves MapGuide not answering requests at all. The FDO half of that was two declared capabilities that
had never been implemented. `FdoIConnection` has `Get/SetConnectionTimeout()` (milliseconds) and
`FdoICommand` has `Get/SetCommandTimeout()`, but every GenericRdbms provider answered
`SupportsTimeout() == false`, returned 0 from the getters and ignored the setters;
`FdoRdbmsConnection::mConnectionTimeout` and `FdoRdbmsCommand::m_TimeOut` were written by nothing and
read by nothing, and nothing in the tree ever set `SQL_ATTR_LOGIN_TIMEOUT` or `SQL_ATTR_QUERY_TIMEOUT`.
The only bound on a connect attempt was therefore whatever the ODBC driver applied to itself -
Microsoft's SQL Server drivers default to 15 s, plus the OS TCP retry, which is the "around 20 sec" the
ticket measured.

The change described in this section is complete and validated but not yet committed upstream; the
measurements below were taken with it applied in both `fdo-dbg` and `fdo-rel`.

Both timeouts now live in the GenericRdbms layer and are applied by the RDBI driver:

* `rdbi_set_connect_timeout()` and `rdbi_set_query_timeout()` (with new optional `set_connect_timeout`
  and `set_query_timeout` entries in the RDBI methods table) carry a value in seconds to the vendor
  driver. Drivers that cannot honour one leave the entry NULL, and the call is a no-op for them.
* Both ODBC drivers (`Src/ODBCDriver`, `Src/SQLServerSpatial/ODBCDriver`) record the values, set
  `SQL_ATTR_LOGIN_TIMEOUT` on each new connection handle before `SQLConnect`/`SQLDriverConnect`, and set
  `SQL_ATTR_QUERY_TIMEOUT` on each statement handle as it is allocated - the query timeout is a statement
  attribute, so it is applied per statement rather than per connection.
* `FdoRdbmsConnection` implements `Get/SetConnectionTimeout()` (milliseconds in, whole seconds applied)
  and hands the value to `DbiConnection`, which passes it on before connecting. The default is 0, leaving
  the native driver's own timeout in place, so a client that asks for nothing sees the old behaviour.
* Every command class - the `FdoRdbmsCommand`/`FdoRdbmsFeatureCommand` templates, the provider's
  `FdoRdbmsSimple*Command` family used by this provider for Select/Insert/Update/Delete, and the schema,
  datastore, spatial-index and SQL commands - hands its timeout to the connection when it is created and
  whenever the timeout changes, so the driver is always holding the timeout of the most recently created
  or configured command.
* `FdoRdbmsSqlServerConnectionCapabilities::SupportsTimeout()` and
  `FdoRdbmsSqlServerCommandCapabilities::SupportsTimeout()` now answer `true`. The connection one is what
  makes MapGuide's `FDOConnectionTimeoutCustom` do anything: `MgFdoConnectionManager::SetConnectionTimeout()`
  is gated on that capability, so the setting was previously skipped silently for every GenericRdbms
  provider.

Measured with throwaway probes against this tree, in Debug and Release. The connection cases point at a
listener that accepts a connection but never answers the TDS login (`127.0.0.1:1444`); the command cases
are a `WAITFOR DELAY '00:00:10'` on the test server, both as a bare statement (the one-shot
`SQLExecDirect` path) and as `select 1 as x; waitfor ...` (the cursor path the feature commands use).

| Timeout | Not asked for | Asked for 3000 ms |
|---|---:|---:|
| Connection (Debug / Release) | 15,015 ms / 15,031 ms | 3,031 ms / 3,031 ms |
| Command, one-shot path (Debug / Release) | 10,000 ms / 10,000 ms | 3,000 ms / 3,000 ms |
| Command, cursor path (Debug / Release) | 10,015 ms | 3,015 ms / 3,015 ms |

A timed-out command fails with the driver's `Query timeout expired`; the unset cases run to completion,
so nothing changes for a client that asks for no timeout. Fixtures, both configurations:
`SqlServerSpatial` `ConnectTests,FdoCapabilityTest,FdoConnectTest,DescribeSchemaTest,FdoSqlCmdTest,FdoDatastoreTest,FdoSpatialContextTest`
is `OK (58 tests)`, `FdoSelectTest` is `OK (24 tests)`, `FdoApplySchemaTest` is `OK (5 tests)` (Debug,
11 min), and the `MySql`/`PostGis` `ConnectTests` stay `OK (4 tests)`, which is what exercises the no-op
path in drivers with no such methods.

The two throwaway probes whose numbers are quoted above are in [probes/](./probes), each documenting
its own usage in its header comment.

One thing this does not fix, because it is not in the provider: the ticket's "all other requests were
blocked" is MapGuide holding its manager-wide `sm_mutex` across `FdoIConnection::Open()` -
`MgFdoConnectionManager::Open()` takes the guard and the blocking `Open()` happens inside it - so one
dead server parks every other FDO request in the process until the connect gives up. The connection
timeout above only bounds how long that is.

That lock is the connection pool's, not FDO's: it guards the provider registry, the per-provider slot
counters and the connection cache's in-use flags, and the pool slot is already reserved before the open
begins - so it is scoped wider than the state it protects. Narrowing it, while keeping the recursive
mutex and the reservation/claim steps as they are, would remove that stall; it is a MapGuide-side
change and is not part of the provider work above.

## Test data stores are named after the Windows account (`fdo_<account>`)

The database-backed FDO suites (MySQL, PostGIS, SQL Server Spatial) get the name of the data store
they use — for PostGIS and MySQL a real database — from the `datastore` key of their
`*Init.txt`. None of the `*Init.txt` files in this repo set that key, and the suites then derive it:

```
datastore = "fdo_" + <Windows account name, lower-cased>      # ConnectionUtil::GetEnviron()
```

So on this machine (account `user`) the PostGIS suite works in the database `fdo_user`, and its
sub-suites in `fdo_user_<suffix>` (`fdo_user_schema_mgr`, `fdo_user_emptygeom`,
`fdo_user_apply_schema`, ...) — the same 40-odd names you can see in `sys.databases` on the SQL
Server test host. The data store is **created on demand**: `UnitTestUtil::GetConnection(suffix,
bCreate=true)` creates it through the provider's `CreateDataStore` when `DatastoreExists()` says it
is not there, and nothing drops the base data store at the end of a run.

The consequence to be aware of: on a **fresh database server** (a recreated container/volume), or
under a **different Windows account**, the first suite run has nothing to connect to yet.
`FdoConnectionInfoTest::TestProviderInfo` runs first and is the one test that opened a connection
naming the data store without creating it, so it failed with
`FATAL: database "fdo_user" does not exist`, the run created the data store one test later, and
every run after that was green — which made it look like a flaky test. It now creates the data
store first, so the first run is green too (PostGIS, MySQL and SQL Server Spatial: their
`TestProviderInfo` are the same code).

Those three test files live in the gitignored FDO SVN tree, committed upstream as FDO r8389.

## The PostGIS schema tests ignore the schemas the template database contributes

A PostGIS data store is created from a template database (`postgis_30_sample`, `template_postgis`,
...), so every test database inherits whatever schemas the template carries. A container's template
can hold the schemas the PostGIS extensions install — `tiger`, `tiger_data`, `topology` — and the
provider maps *every* PostgreSQL schema of the database to a feature schema, so those schemas come
back from `FdoIDescribeSchema` and land in the master file comparisons:

```
1) test: PostGisSchemaMgrTests.testGenDefault (F)
 "Output file PostGIS_29245_gen_default1.xml differs from expected output file
  PostGIS_29245_gen_default1_PostGIS_master.txt"
5) test: PostGisSchemaMgrTests.testMaterializedViews (F)  "schemas->GetCount() == 2"
```

They are false positives: the schemas are not part of the datastore the tests build. The tests now
drop them before comparing, through a provider hook:

* `ConnectionUtil::IsExtraSchema()` — a provider says whether a feature schema is external to the
  datastore under test. The default is `false`, so no other provider's comparison changes.
* `UnitTestUtil::RemoveExtraSchemas()` — removes the schemas the hook names, and is called on every
  schema collection the tests use: inside `ExportDb()`, and at each `FdoIDescribeSchema::Execute()`
  in `SchemaMgrTests`, `FdoApplySchemaTest::TestNoMeta` and
  `PostGisSchemaMgrTests::testMaterializedViews`.
* `PostGisConnectionUtil::IsExtraSchema()` — ignores the three extension schemas by name, and any
  other schema that carries no classes and is not the default `public` schema (the tests put at
  least one class in every schema they create, so an empty one was inherited from the template).
  `public` is never ignored: the tests expect it, and it is legitimately empty in some masters.

Those files live in the gitignored FDO SVN tree, committed upstream as FDO r8403.

## The ODBC Access suite runs one fixture per process (`OdbcAccess`)

The FDO core and GenericRdbms suites run from their executable directories, where the build stages
their golden masters and test inputs (`Fdo\Unmanaged\Bin\Win64\Debug`/`Release` for FDO core,
`GenericRdbms\Src\UnitTest\Dbg64`/`Rel64` for GenericRdbms). Generated comparison/output files
therefore stay in the build output instead of accumulating in the versioned test source directories;
comparisons use the staged golden masters in the working directory.

The SDF suite also runs from its executable directory. Its tests use paths relative to
`../../TestData`, so the runner stages the versioned `Providers\SDF\TestData` contents into
`Providers\SDF\Bin\TestData` before running the suite. Generated SDF data stays in this build-output
copy rather than in the source test data.

The SHP suite uses the same `../../TestData` layout and also runs from its executable directory.
The runner stages `Providers\SHP\TestData` into `Providers\SHP\Bin\TestData` and runs its cleanup
script from that staged copy, keeping generated shapefiles and indexes out of the versioned test
data.

The SQLite suite also runs from its executable directory and stages `Providers\SQLite\TestData`
into `Providers\SQLite\Bin\TestData`. That staged directory is refreshed from the source before
each run, so test-created or modified SQLite databases remain in build output and each run starts
from the original test data.

The Access suite is the one suite that could not be run as a whole. From roughly its 63rd test
onwards, the tests that open a **second** connection while the fixture's own connection is open
(`FdoUpdateTest.updateCities`/`updateTable1`, `FdoConnectTest.OpenTest`/`ConfigFileTest`/
`ConnectWithParmTest`, and the `FdoDeleteTest` fixture's `setUp`) failed with

```
Message: [Microsoft][ODBC Microsoft Access Driver] Too many client tasks.
Message: [Microsoft][ODBC Driver Manager] Driver's SQLSetConnectAttr failed
```

`Too many client tasks` is Jet error **-1036**, and it is the *ACE driver* refusing the connection,
not the provider failing to release one:

- Reproduced with the raw ODBC API against a copy of the same `.mdb`, no FDO code involved: a
  process can have 24 connections open at once; after closing that batch only 12 can be opened, then
  6, then 3 — so closed connections are not all released by the driver. One at a time it is
  unlimited (400 sequential connects, each closed before the next, all succeed), so this is not a
  simple connection counter.
- Instrumenting the ODBC protocol driver (`ODBCDriver\connect.c`/`disconnect.c`) showed the provider
  makes ~170 connects for a suite run, matches every one with a disconnect, never calls
  `SQLDisconnect` in vain (`DISCONNECT-SKIPPED` never fired) and never holds more than 10
  connections at once (that peak is `FdoMultiThreadTest`'s ten threads). With
  `FDO_CRT_LEAK_CHECK=1` the suite reports no CRT leak records either — there is nothing to plug.
- It depends on how many connections the *process* has already made, which is why the failures look
  like interference from the other suites: any single fixture passes on its own, 62 tests in one
  process pass, 63+ fail.

So the suite is run as one process per fixture: the `OdbcAccess` entry of `Run-FdoTests.ps1` carries
a `Fixtures` list, and the runner runs each of them in turn, appending to the suite's single log
(120 tests across 12 processes, about 6 seconds). `MessageTest` is registered under
`OdbcAccessMessageTest` for that purpose, so a run against a test build from before that
registration reports the last chunk as `FAILED (no tests matched the fixture)`.

Two further notes:

- The tests run against a prefabricated database — the DSN the suite creates points at
  `<exe dir>\MSTest.mdb` (`...\UnitTest\Dbg64\MSTest.mdb` for Debug, `...\Rel64` for Release). The
  Access `FdoDeleteTest::FeatureDelete` deletes `EMPLOYEES` rows matching `JOBTITLE = 'Box Filler'`
  and, unlike the fixture it overrides, does not put them back, so a second run against the same
  file fails `FdoAdvancedSelectTest`'s row counts (`Expected my count to be 7, got 5`,
  `Expected a different average salary`). The runner therefore restores `MSTest.mdb` and
  `Lidar.mdb` from the pristine versioned copies in the parent `UnitTest` source directory before
  every Access run, and removes any leftover `.ldb`.
- The budget belongs to the ACE **engine** in the process, not to the Access file. All four
  ACE-backed code paths are the same `ACEODBC.DLL`, and refilling and draining a pool of five
  connections refuses the 34th creation with the same Jet -1036 `Too many client tasks` on the
  Access, Excel, dBASE **and** Text drivers - only the driver name in the message differs. What
  spends the budget is connections that *overlap*; strictly one at a time it is unlimited (3000
  connect/query/disconnect cycles, no refusal). It is not the ten-thread fixture that makes the
  Access suite hit this: run it with `FdoMultiThreadTest` excluded (117 tests in one process) and it
  still fails, in the same seven tests - the fixture is only the largest single charge (ten
  connections at once, three times), so it makes the failure arrive sooner. The suite's own lighter
  overlap is enough at this size: the tests that hold a second connection while the fixture's is
  open (`updateCities`, `updateTable1`, the connect fixture's own opens, and the delete fixture's
  `setUp`) spread over ~115 connections. `OdbcExcel` (51 tests), `OdbcDbase` (31) and `OdbcText` (6)
  are green because their connections effectively never overlap, not because they are safe - the
  ceiling is one overlapping connection away for them, and for any ACE-backed data store.
- The ACE driver is the only 64-bit Access ODBC driver (the legacy Jet 4 driver,
  `Microsoft Access Driver (*.mdb)`, is 32-bit only), so this is a driver limitation to work around
  rather than something to fix in the provider.

The FDO-tree part of this — giving `MessageTest` a registry name of its own (`OdbcAccessMessageTest`
in `Providers\GenericRdbms\Src\UnitTest\Odbc\OdbcTestRegister.cpp`) and the note in the tree's own
readme (`OpenSourceBuild__README.txt`, in its Windows ODBC unit-test section) — is in the FDO tree as
r8396 and r8407.

## Leak checking an FDO suite from the command line (`FDO_CRT_LEAK_CHECK`)

The Debug suites link the debug CRT, and most of them take their `main` from the cppunit test host
(`Thirdparty\cppunit\HostApp\TestMain.cpp` — used by FdoCore, SDF, SHP, SQLite, OGR, WFS, WMS,
KingOracle, ArcSDE and the GenericRdbms suites: `UnitTestSQLServerSpatial.exe`, `UnitTestPostGIS.exe`,
`UnitTestMySQL.exe` and the ODBC ones), which already turns the CRT's leak check on
with `_CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF)`. By default that report is
written to the *debugger's* output, which a plain command-line run discards. Set
`FDO_CRT_LEAK_CHECK=1` to send it to stderr instead, so it appears in the console output and in the
log the runner tees. The GDAL suite has its own `main`, which sets the flag but has no stderr gate, so
this variable does nothing for it and its report is debugger-only:

```powershell
$env:FDO_CRT_LEAK_CHECK="1"
.\Run-FdoTests.ps1 -Test SqlServerSpatial -Fixture FdoSelectTest     # ~20 s; report is at the end
Select-String -Path testlogs\Dbg64_UnitTestSQLServerSpatial.txt -Pattern 'Detected memory leaks' -Context 0,300
```

The report lists every block still allocated when the process exits, as
`{block} normal block at 0x0000000000000000, N bytes long`. Two things to know when reading it:

* **Compare against the unchanged tree.** Deliberately-live global and singleton state is always in
  the dump; the Debug `SqlServerSpatial` suite has 7 such blocks (~8 KB) with default provider
  behaviour, and that is the baseline rather than a defect. Judge by the difference, and by the
  *set* of record sizes, not by the total.
* **The provider's blocks carry no file/line** (only the host's own translation unit has
  `_CRTDBG_MAP_ALLOC`), so identify them by size and arithmetic — e.g. `sizeof(odbcdr_context_def)`
  is 3600, `sizeof(odbcdr_stmt_desc)` is 48 and `sizeof(odbcdr_param_desc_map)` is 40. Block numbers
  can be followed under a debugger with `_CrtSetBreakAlloc(<block>)`; without one, the
  reference-count instrumentation in [docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) is what
  names the *holder* of a leaked object.
* **To get a provider file named**, add the mapping to the suspect translation unit for the
  diagnosing run:
  ```cpp
  #ifdef _DEBUG
  #define _CRTDBG_MAP_ALLOC
  #include <crtdbg.h>
  #define new new( _NORMAL_BLOCK, __FILE__, __LINE__ )   // note: breaks placement new
  #endif
  ```
  With it in place the dump names the allocation site (`DbObjectReader.cpp(519) : {1500178} normal
  block ...`). An allocation hook in the *test host* cannot do this: it fires for the host's own
  debug-allocator calls, and the provider DLL's TUs allocate through the plain allocator even though
  both use the shared `/MDd` heap (which is why the dump still lists the provider's blocks).

MSVC has no LeakSanitizer — `/fsanitize=address` exists but `/fsanitize=leak` does not — so there
is no ASan-style leak report on Windows. The CRT debug heap, Application Verifier, Dr. Memory and
Visual Studio's memory tooling are the options, and the first of those works fine from a
command-line run.

The test-host change lives in the gitignored FDO SVN tree, committed upstream as FDO r8390.

## Running the MapGuide server test suite (`Run-MgTests.ps1`)

The MapGuide tests are not separate executables. They are the `MgUnitTesting.dll` module that
`mgserver.exe` loads through its own `test` command, so a run costs one server start and stop and
nothing has to be installed, configured or left running:

```
mgserver.exe test <scope>[,<scope>...]
```

`<scope>` is one Catch2 tag, or a comma- or semicolon-delimited list of tags (whitespace is accepted
too). Every named scope runs in the same server process, so a list costs one start and stop rather
than one per scope.

`Run-MgTests.ps1` wraps that for the build output here, in the same shape as `Run-FdoTests.ps1`:

```powershell
.\Run-MgTests.ps1 -List                          # scopes, with the test source file each covers
.\Run-MgTests.ps1 -Test Misc                     # one scope, Release tree
.\Run-MgTests.ps1 -Configuration Debug -Test FeatureService
.\Run-MgTests.ps1 -Test Geometry, MdfModel       # both scopes, one server process
.\Run-MgTests.ps1 -PerScope -Test Geometry, MdfModel   # one server process per scope
```

* `-Configuration` selects `MgDev\Server\bin\Release64` (default) or `Debug64`; `-Test` takes the
  Catch2 tag the suite registers (`All` runs every scope); `-List` prints the scope-to-source mapping
  without running anything. A Debug run first needs the Debug FDO SDK: `fdo_dbg.bat`, then
  `mapguide_dbg_setup.bat` (which stages `fdo-build\dbg64\Fdo` into the Debug folders under
  `MgDev\Oem\FDO`). With the Debug FDO never staged, a Debug scope reports `SKIPPED`.
* By default all selected scopes are passed to one `mgserver` run (`test a,b,...`), so a multi-scope
  run starts the server once. `-PerScope` restores the previous behavior of one process per scope,
  which is what to use when a per-scope verdict or log is needed.
* Output is streamed and tee'd to `testlogs\MgRel64_<Scope>.txt` / `testlogs\MgDbg64_<Scope>.txt` for
  a single scope, `..._All.txt` for every scope, and `..._<First>_and_<N-1>_more.txt` for a subset.
  With `-PerScope` each scope keeps its own `..._<Scope>.txt`. The script exits non-zero if the run
  failed, reports `SKIPPED` when the executable or the staged test data is missing, and reports a run
  that executed no test cases as `FAILED` — a stale `MgUnitTesting.dll` advertises scopes in
  `mgserver test list` and then matches none of them.
* The test data is staged to `MgDev\Server\bin\UnitTestFiles` by the server build's PostBuild step. The
  suites read it as `../UnitTestFiles`, which is why the runner works from the build output.
* A MapGuide server must not already be running: the tests start and stop their own, and the runner
  refuses to start (`exit 2`) rather than failing every suite for the wrong reason.
* These logs are a leak probe only in Debug, and only with `MG_CRT_LEAK_CHECK=1` (see below): without
  it the CRT writes its leak report to the debugger's output, so nothing leak-related appears here.
  Release has no debug heap at all. A batch run writes one log for the whole server process, so use
  `-PerScope` when a leak report has to be attributed to a single scope.

The inner loop for a server change is `mapguide_rel.bat -w=server` (the server solution, no web tier,
bindings, docs or installer preparation) followed by the scope whose test source covers the change. It
builds the server tree only, so it assumes the OEM libraries (ACE, Xerces, dbxml, CS-Map) for that
configuration already exist — a full build makes them, and after a fresh checkout each configuration
needs `mapguide_*.bat -w=oem` once before the first `-w=server`.
Steady-state cost on this machine: the `-w=server` build is about a minute, `Geometry` 1 s, `Misc` 6 s,
`RenderingService` 25 s, `FeatureService` 74 s, `CoordinateSystem` 59 s, `TileService` 84 s, and all 22
scopes about 5 min. `-List` names the source file each scope covers.

Unlike the FDO runner there is no `-Fixture`: a scope is a tag registered by one file, so that file is
the finest granularity, and each scope name must be passed bare. `mgserver` splits a list on commas,
semicolons and whitespace, brackets each name and passes the whole set as one Catch2 tag expression;
`TestServiceFactory::IsRunningSuite()` matches the unbracketed name when it prepares that suite's data,
so a Catch2 tag expression such as `Misc]~[SlowTests` — which parses, and which looks like a way to skip
the slow coordinate-system tests — is split into names that match nothing, runs the tests with none of
their data prepared and fails them for the wrong reason.

`MgDev\UnitTest\run_server_tests.bat` is a different thing and is not used by this loop: it copies the
test data next to a *configured installation* and starts it.

## Running the MapGuide web and API binding tests (`Run-WebTests.ps1`)

The web tier and the .NET, Java, and PHP API binding test runners need a live MapGuide server. The
root-level runner starts the selected Debug or Release `mgserver` in interactive mode, waits for its
site port, runs the selected suites, and sends Ctrl+C to stop the server gracefully. It refuses to
start if another `mgserver` process is already running.

```powershell
.\Run-WebTests.ps1 -List
.\Run-WebTests.ps1                                   # all four suites
.\Run-WebTests.ps1 -Test Web                         # C++ WebTestRunner
.\Run-WebTests.ps1 -Test Bindings                    # .NET, Java, and PHP
.\Run-WebTests.ps1 -Configuration Debug -Test Java, DotNet
```

`-Test` accepts `Web`, `DotNet`, `Java`, `Php`, `Bindings`, or `All` (the default). Suites run
serially in one server process. Java runs before the other suites when selected because it loads the
Sheboygan sample package used by WebTestRunner. When Java is not selected, the script loads that
package with `mgserver loadpackage` before starting the server. Binding runs remove only their
generated SQLite `.db` files under `MgDev\UnitTest\TestData` before each suite so stale test output
does not affect validation.

The MapGuide server and WebTestRunner must be built for the chosen configuration. Binding runners
are taken from the matching `mg-install\{rel64,dbg64}` test pack, so build the bindings/install
components as well. Java requires `JAVA_HOME` or `java.exe` on `PATH`. `-AdminPass` supplies the
MapGuide Administrator password for the Java and .NET runners (default: `admin`;
`MG_TEST_ADMIN_PASS` is used when set). The PHP test sources currently hardcode `Administrator/admin`,
so they do not honor this option. The server site port in
`Server\bin\<Configuration>64\serverconfig.ini` must match the one in
`Web\bin\<Configuration>64\webconfig.ini`. For the binding runners, the script writes a temporary
web configuration under `testlogs` with absolute resource and dictionary paths so each runner can
initialize from its own working directory.

Output is streamed and logged to `testlogs\MgRel64_<Suite>.txt` or
`testlogs\MgDbg64_<Suite>.txt`; the language runners also keep their detailed logs there or in their
test-pack working directories. Missing runners and runs with no test cases are reported as failures,
not passes. This runner covers the WebTestRunner and API binding suites; it does not start an HTTP
server for the separate MapAgent acceptance tests.

### Leak checking a MapGuide scope from the command line (`MG_CRT_LEAK_CHECK`)

The Debug `mgserver` sets the CRT's leak check at startup, but the report is written to the
*debugger's* output, which a plain command-line run discards. Set `MG_CRT_LEAK_CHECK=1` and
`Server\src\Core\main.cpp` sends it to stderr instead, so it lands at the end of the scope's tee'd log:

```powershell
$env:MG_CRT_LEAK_CHECK="1"
.\Run-MgTests.ps1 -Configuration Debug -Test Misc          # ~15 s
Select-String -Path testlogs\MgDbg64_Misc.txt -Pattern 'Detected memory leaks' -Context 0,40
Remove-Item Env:\MG_CRT_LEAK_CHECK
```

The report is the CRT's own, in the same shape as the FDO one: `{block} normal block at 0x…, N bytes
long`, ending with `Object dump complete.`. Two things to know:

* **Only Debug reports anything.** The Release CRT has no debug heap, so the variable there produces
  no report even when the code leaks.
* **Expect noise, and compare sets rather than totals.** On an unmodified tree `Misc` reports 4 blocks
  (8,266 bytes) and `KmlService` 3 blocks (8,250 bytes) — most of that is one ~8.2 KB block of
  process-lifetime state. Because each scope is its own process, a scope's dump belongs to that scope;
  run the scope before and after the change, and require the record set to shrink without new records
  appearing.

This needs a Debug tree, which in turn needs the Debug FDO SDK (`fdo_dbg.bat`, `mapguide_dbg_setup.bat`)
and the Debug OEM libraries once (`mapguide_dbg.bat -w=oem`) before `mapguide_dbg.bat -w=server`.
Staging Debug does not disturb the Release staging, so the Release configuration stays buildable and
testable without re-running `mapguide_rel_setup.bat`.

The `MG_CRT_LEAK_CHECK` gate landed upstream as r10226, and the `Band.h`/`GridData.h` narrowing that
keeps the r10225 stylization tests from pulling the FDO expression engine through `Stylization.h`
landed as r10227.

## Steps (tldr, powershell)

```powershell
$env:BUILD_INSTALLER=1
$env:BUILD_INSTANTSETUP=1
$env:MG_RELEASE_LABEL="Final"
.\fdo_rel.bat
.\mapguide_rel_setup.bat
.\mapguide_rel.bat
```

## Artifacts produced

 * FDO binaries at: `fdo-build\rel64`
 * InstantSetup bundle at: `mg-install\rel64`. The server install step creates `Repositories`, `Logs`,
   `Packages` and `Temp` empty rather than copying them out of the build output, so the bundle carries
   no site repository, session data files, tile caches or logs left by earlier test runs
 * Windows installer at: `Installer\Output\en-US`

## Agent guidance

If you are an agent working in this repository, read these before changing code:

 * [AGENTS.md](./AGENTS.md) — repository model, the build/test workflows, and the FDO/MapGuide
   memory-management rules that most defects here break
 * [CPP_STYLE.md](./CPP_STYLE.md) — the C++ style rules and the `FdoPtr`/`Ptr` ownership contract
 * [docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) — the leak catalogue: the shapes FDO leaks
   take, how to read a leak report, how to attribute one to a test, and which cycles are knowingly
   left alone
 * [docs/mapguide-php-decoupling.md](./docs/mapguide-php-decoupling.md) — how the web tier is wired to
   its bundled PHP 8.3/httpd 2.4, how to disable PHP on an existing httpd or IIS install, and what a
   bring-your-own PHP/httpd deployment needs
 * [docs/mapguide-aspnet-core-replacement.md](./docs/mapguide-aspnet-core-replacement.md) — whether one
   ASP.NET Core application can replace `mapadmin`, `schemareport`, the PHP viewer and Fusion, and what
   hosting looks like on IIS versus httpd

## Generating download table

From Linux or WSL2 session on Windows.

```
sha256sum * | awk '{print "||[https://download.osgeo.org/mapguide/releases/4.0.0/Final/" $2 " " $2 "]||" $1 "||"}'
```