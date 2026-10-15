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
 2. (If you want multi-platform .net packges, otherwise skip) Copy the `-common-` tarball for `generic` into `mgcommon` as `mapguideopensource-common.tar.gz`
 3. If wanting to build Windows Installer, set an environment variable `BUILD_INSTALLER` to `1`
 4. If wanting to build InstantSetup bundle, set an environment variable `BUILD_INSTANTSETUP` to `1`
 5. If wanting a different relase label than `Trunk`, set an environment variable `MG_RELEASE_LABEL` to your desired label (eg. `Beta2`, `RC1`, `Final`, etc)
 6. Build FDO trunk: `fdo_rel.bat`
 7. Setup MG build: `mapguide_rel_setup.bat`
   *  Generates a `mapguide_40_revision.txt` containing the SVN HEAD revision number. This file is needed for next step
 8. Run MG build: `mapguide_rel.bat`

## Limitations

Debug and Release builds of MapGuide cannot be made simultaneously. If you need both Debug and Release builds, you need to do it one at a time.

## SQL Server Spatial performance levers (`FDO_SQS_PERF`)

Two behaviours of the SQL Server Spatial provider and its ODBC driver are shaped by the way the FDO
test suite exercises them: the physical-schema catalog query (`sys.objects`, the "database object"
query) is re-executed for every catalog lookup, and `SQLDescribeParam()` is called for every bound
parameter, which costs a server round trip each. Together they are the largest source of the SQL
Server traffic in the `SqlServerSpatial` FDO unit-test suite and a large part of why that suite is
several times slower than the equivalent MySQL/PostGIS suites — see
[HANDOFF-SqlServerSpatial-Performance.md](./HANDOFF-SqlServerSpatial-Performance.md). Both can be
avoided, and both are opt-in behind one flag:

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
~24 min to ~9m30s, both `OK` (see the handoff's §11 and §13 for the measurements).

Both paths are also leak-checked: with `FDO_CRT_LEAK_CHECK=1` the fixture leaks the same 7 blocks
(~8 KB) of pre-existing global state with the flag on as with it off, against ~5.5 MB leaked before
the schema-manager catalog reader's field lookups were made ownership-correct (see the handoff's
§16, which also records the full suite at 8m 12.0 s after that fix).

The provider and driver changes live in the gitignored FDO SVN tree, so they are also kept as a
patch at [fdo-sqs-perf.patch](./fdo-sqs-perf.patch) (apply with `svn patch` from `fdo-dbg`).

## Batch parameter values / bulk insert for SQL Server Spatial (parked)

Separate from the round-trip work above: an external client's "bulk copy" feature asks a provider for
`FdoIInsert::GetBatchParameterValues()` and, when a provider answers, sends many features through one
insert command. The SQL Server Spatial provider answers `NULL`, so those inserts go one row per
`Execute()`.

This has been investigated but **not implemented**: the findings, the two candidate paths (an ODBC
parameter-array batch that the RDBI/ODBC layers already have the plumbing for, and a BCP-backed bulk
insert behind a new optional RDBI capability), the identity/transaction obstacles, the ABI check under
the current `freeze` mode, and the open questions for the client are all parked in
[HANDOFF-SqlServerSpatial-BulkInsert.md](./HANDOFF-SqlServerSpatial-BulkInsert.md).

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

The provider and driver changes live in the gitignored FDO SVN tree, so they are also kept as a patch at
[fdo-timeouts.patch](./fdo-timeouts.patch) (apply with `svn patch` from `fdo-dbg`; the same change is in
`fdo-rel`). The diagnosis, the repeated measurements and the MapGuide-side analysis are in
[HANDOFF-FdoTicket880-Timeouts.md](./HANDOFF-FdoTicket880-Timeouts.md), and the two throwaway probes whose
numbers are quoted above are in [probes/](./probes), each documenting its own usage in its header
comment.

One thing this does not fix, because it is not in the provider: the ticket's "all other requests were
blocked" is MapGuide holding its manager-wide `sm_mutex` across `FdoIConnection::Open()` -
`MgFdoConnectionManager::Open()` takes the guard and the blocking `Open()` happens inside it - so one
dead server parks every other FDO request in the process until the connect gives up. The connection
timeout above only bounds how long that is.

That lock is the connection pool's, not FDO's: it guards the provider registry, the per-provider slot
counters and the connection cache's in-use flags, and the pool slot is already reserved before the open
begins - so it is scoped wider than the state it protects. Narrowing it (and the analysis behind that
claim, including why the recursive mutex and the reservation/claim steps have to stay as they are) is in
[the handoff](./HANDOFF-FdoTicket880-Timeouts.md#6-the-mapguide-half-analysed-not-changed).

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

Those three test files live in the gitignored FDO SVN tree, so the change is also kept as a patch at
[fdo-connectioninfo-datastore.patch](./fdo-connectioninfo-datastore.patch).

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

Those files live in the gitignored FDO SVN tree, so the change is also kept as a patch at
[fdo-postgis-extra-schema.patch](./fdo-postgis-extra-schema.patch) (apply with `svn patch` from
`fdo-dbg`).

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
readme (`OpenSourceBuild__README.txt`, in its Windows ODBC unit-test section) — is also kept as a
patch at [fdo-odbc-access-suite.patch](./fdo-odbc-access-suite.patch).

## Leak checking an FDO suite from the command line (`FDO_CRT_LEAK_CHECK`)

The Debug suites link the debug CRT, and the cppunit test host that the GenericRdbms suites use
(`Thirdparty\cppunit\HostApp\TestMain.cpp` — the `main` of `UnitTestSQLServerSpatial.exe`,
`UnitTestPostGIS.exe`, `UnitTestMySQL.exe` and the ODBC ones) already turns the CRT's leak check on
with `_CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF)`. By default that report is
written to the *debugger's* output, which a plain command-line run discards. Set
`FDO_CRT_LEAK_CHECK=1` to send it to stderr instead, so it appears in the console output and in the
log the runner tees:

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

The test-host change lives in the gitignored FDO SVN tree, so it is also kept as a patch at
[fdo-crt-leak-check.patch](./fdo-crt-leak-check.patch).

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
 * InstantSetup bundle at: `mg-install\rel64`
 * Windows installer at: `Installer\Output\en-US`

## Agent guidance

If you are an agent working in this repository, read these before changing code:

 * [AGENTS.md](./AGENTS.md) — repository model, the build/test workflows, and the FDO/MapGuide
   memory-management rules that most defects here break
 * [CPP_STYLE.md](./CPP_STYLE.md) — the C++ style rules and the `FdoPtr`/`Ptr` ownership contract
 * [docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) — the leak catalogue: the shapes FDO leaks
   take, how to read a leak report, how to attribute one to a test, and which cycles are knowingly
   left alone

## Generating download table

From Linux or WSL2 session on Windows.

```
sha256sum * | awk '{print "||[https://download.osgeo.org/mapguide/releases/4.0.0/Final/" $2 " " $2 "]||" $1 "||"}'
```