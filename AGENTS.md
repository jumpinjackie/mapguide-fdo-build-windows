# Agent Instructions for mapguide-fdo-build-windows

## Overview

This repository is a Windows build and test environment for MapGuide Open Source 4.0 and Feature Data
Objects (FDO) 4.2. It is a **virtual monorepo**: it orchestrates the build of two externally-versioned
source trees (Subversion working copies, not submodules) plus the MapGuide installer tooling, using
batch wrappers around each tree's own build system, and it carries a unified FDO unit-test runner.
Everything runs on the host with MSVC — there are no containers, and only x64 is supported.

Read [Memory management](#memory-management) before writing FDO or MapGuide code. Nearly every defect
an agent introduced in the sibling Linux repo
([mapguide-fdo-docker-build](https://github.com/jumpinjackie/mapguide-fdo-docker-build)) was a **lost
counted reference**, and the rules that prevent them are identical on both platforms — the code is the
same code. [CPP_STYLE.md](./CPP_STYLE.md) is the ownership contract;
[docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) is the catalogue of real leaks, the shapes they
take, and how each one was found.

## Current cycle

**API/ABI mode: `freeze`** — FDO upstream; mirrors the sibling
[mapguide-fdo-docker-build](https://github.com/jumpinjackie/mapguide-fdo-docker-build), which owns the
mode because both repos build the same FDO sources. Rules for each mode:
[Policy gate](#policy-gate-which-mode-are-we-in).

## Repository model

### Durable vs. generated content

Durable content (edited and committed to git):

- `README.md` — requirements, the thirdparty layout, the build sequence
- `*.bat` — the build wrappers and their flag handling
- `Run-FdoTests.ps1` — the FDO unit-test runner, including its suite table
- `revnum.pl` — SVN revision extractor used by `mapguide_*_setup.bat`
- `*Init.txt` — the init files the database-backed suites need
- `docs/**` — the memory-leak catalogue
- `AGENTS.md`, `CPP_STYLE.md` — this file and the C++/ownership rules

Generated content (never hand-edited; gitignored — see `.gitignore`):

- `fdo-dbg/`, `fdo-rel/` — the two SVN checkouts of the FDO tree (Debug and Release)
- `MgDev/`, `Installer/`, `MgInstantSetup/` — the SVN checkouts of the MapGuide trees
- `fdo_rdbms_thirdparty/` — MySQL, PostgreSQL and Oracle client headers and libraries (supplied by hand)
- `fdo-build/`, `mg-install/`, `mgcommon/` — build and packaging output
- `testlogs/` — the runner's tee'd logs
- `mapguide_4*_revision.txt` — stamped by `mapguide_*_setup.bat`

When a build flag has to change, change the wrapper `.bat` that owns it. `fdo_dbg.bat`/`fdo_rel.bat`
set the thirdparty environment variables, then parse and forward options to the tree's own `build.bat`;
a build run by hand with different flags is not reproducible for the next agent.

### Source trees

| Path | Product | SVN branch |
|---|---|---|
| `fdo-dbg` | FDO (Debug tree) | `branches/4.2` |
| `fdo-rel` | FDO (Release tree; a second checkout, or a copy of the first) | `branches/4.2` |
| `MgDev` | MapGuide Open Source | `branches/4.0/MgDev` |
| `Installer` | MapGuide installer | `trunk/Installer` |
| `MgInstantSetup` | InstantSetup bundle | `trunk/Tools/MgInstantSetup` |

Rules for working with the source trees:

- You may edit files under `MgDev` and the FDO trees, but you must **never commit changes upstream**.
  Do not run `svn commit`, or any svn command that writes to the repository. `svn update` / `svn info`
  are fine.
- `MgDev\Oem\FDO` is a **staging copy** written by `mapguide_*_setup.bat` out of
  `fdo-build\{dbg64,rel64}\Fdo` (`Inc`/`Lib` → `Oem\FDO\{Inc,Lib64}`, `Bin` → `Oem\FDO\Bin\{Debug64,Release64}`).
  It is overwritten on every setup run: never edit it, and never treat it as a source tree.
- Debug and Release builds of MapGuide cannot be made simultaneously — `mg-install\dbg64` and
  `mg-install\rel64` are built one at a time. The same applies to the two FDO trees.
- Both source trees are C++11 (the same sources build under the CMake-based Linux build in the sibling
  repo, which pins `CMAKE_CXX_STANDARD 11`), so do not introduce newer language features.
- Fixes that land in the sibling repo's FDO working copies have to be mirrored here, because the two
  repos build the same upstream branch and neither commits to SVN. The sibling exports its uncommitted
  FDO diff as `patches/pending.patch`; from each FDO tree root (`fdo-dbg` **and** `fdo-rel`) run
  `svn patch <path-to-pending.patch>`, after `svn update`-ing to at least the revision its
  `(revision N)` headers name. Its currently-pending set is the NULL-`this` fixes in
  `FdoInternalDataValue::Compare` / `FdoDataValue::Compare` and the nullable `SmartCast` call sites
  (see [CPP_STYLE.md](./CPP_STYLE.md)) — delete this sentence once they are committed upstream.

### Source of truth and history

- The **local SVN working copies are the only source of truth**: `fdo-dbg`/`fdo-rel` for FDO
  (`https://svn.osgeo.org/fdo/branches/4.2`) and `MgDev` for MapGuide
  (`https://svn.osgeo.org/mapguide/branches/4.0/MgDev`). Search and read them in place (grep, glob,
  LSP); the Debug copy is enough for reading code.
- The GitHub repositories `jumpinjackie/fdo` and `jumpinjackie/fdo_cmake` are **unofficial by-products
  of abandoned SVN→Git experiments**. They are not authoritative, may be stale or divergent, and must
  **not** be used as a point of reference or cited for behaviour, capabilities or history.
- For history, query the working copy with the read-only SVN commands instead of any mirror:
  `svn log [-l N] [-r REV] path`, `svn blame`, `svn diff -r A:B`, `svn cat -r REV path`, `svn info`.
  Never `svn commit` (see the commit rule above).

## Requirements

See [README.md](./README.md) for the full list — SWIG 4.3.1 with `SWIG_DIR` set, Java 8 with
`JAVA_HOME`, Apache Ant with `ANT_HOME`, Visual Studio 2022/2026 (MSVC 2019 toolset), 7-zip and Perl on
the `PATH`, WiX, docfx, Python 3 with Sphinx — and for the required `fdo_rdbms_thirdparty` layout
(MySQL client headers/libs, Oracle Instant Client 12c, PostgreSQL headers/libs).

`fdo_dbg.bat`/`fdo_rel.bat` derive `FDOORACLE`, `FDOMYSQL` and `FDOPOSTGRESQL` from
`fdo_rdbms_thirdparty` themselves; the individual suite runners need those variables already set if
they are invoked directly.

## Common workflows

### Build FDO

```
fdo_dbg.bat                 REM Debug tree  -> fdo-build\dbg64
fdo_rel.bat                 REM Release tree -> fdo-build\rel64
```

Both wrappers accept the tree's own options, most usefully `-w=<component>` to build a subset
(`-w=fdo`, `-w=mysql`, `-w=postgresql`, ...), `-ntp` to skip the third-party build for a faster
incremental rebuild, and `-h` for the exhaustive list:

```
fdo_rel.bat -ntp -w=postgresql      REM just the PostgreSQL (PostGIS) provider + unit tests
```

### Build MapGuide

```
mapguide_dbg_setup.bat      REM stage FDO + stamp versions, then:
mapguide_dbg.bat
```

`mapguide_rel_setup.bat` / `mapguide_rel.bat` are the Release equivalents (`mg-install\rel64`). The
setup step must be re-run after every FDO build, because it is what copies the FDO SDK into
`MgDev\Oem\FDO`. `BUILD_INSTALLER=1` and `BUILD_INSTANTSETUP=1` add the installer and InstantSetup
bundles; `MG_RELEASE_LABEL` sets the release label (default `Trunk`).

### Test

```
.\Run-FdoTests.ps1 -List                         REM show the suites and the command each would run
.\Run-FdoTests.ps1 -Test Sqlite                  REM one suite, Debug tree
.\Run-FdoTests.ps1 -Configuration Release -Test Gdal, Ogr, Wms
.\Run-FdoTests.ps1 -Test Odbc                    REM all ODBC sub-suites
.\Run-FdoTests.ps1 -Test SqlServerSpatial -Fixture FdoSelectTest   REM one fixture, not the whole suite
```

- `-Configuration` selects the tree (`Debug` → `fdo-dbg`, `Release` → `fdo-rel`); the default is
  `Debug`.
- `-Test` takes one or more suite names (case-insensitive): `FdoCore`, `Gdal`, `MySql`, `OdbcAccess`,
  `OdbcDbase`, `OdbcExcel`, `OdbcMySql`, `OdbcOracle`, `OdbcSqlServer`, `OdbcText`, `Ogr`, `PostGis`,
  `Sdf`, `Shp`, `Sqlite`, `SqlServerSpatial`, `Wfs`, `Wms`, plus the pseudo-names `All` (the default)
  and `Odbc`.
- Each suite's combined output is streamed and tee'd to `testlogs\<Log>` (`Dbg64_UnitTestSQLite.txt`
  and so on). The script exits non-zero if any suite failed, and reports `SKIPPED` when the working
  directory or the executable is missing — a skipped suite is a build that has not been done, not a
  pass.
- A suite is judged first by its exit code, with the tee'd log as a second signal: if the log reports
  CppUnit failures (`!!!FAILURES!!!` or `Failures !!!`) while the executable exited 0, the suite is
  reported as `FAILED` rather than `OK`. That covers an executable which does not propagate CppUnit's
  result to its exit code — the GDAL provider's did not.
- The suites that need a database read their connection details from the matching `*Init.txt` next to
  this file; the runner passes it as `initfiletest=...`.
- **Prefer a single fixture over the whole suite while iterating.** `-Fixture <registry>` (with exactly
  one `-Test` suite) runs only the named CppUnit registries, e.g.
  `.\Run-FdoTests.ps1 -Test SqlServerSpatial -Fixture FdoSelectTest` — about a minute, versus the
  ~24 min the full suite takes. The registry name is the class's `CPPUNIT_TEST_SUITE_NAMED_REGISTRATION` name
  (`FdoSelectTest`, `FdoFilterTest`, `SelectTests`, ...); a name that matches nothing runs zero tests,
  which the runner reports as a failure rather than a false pass.
  `.\Run-FdoTests.ps1 -List` prints each suite's `WorkDir` and executable for hand-runs.

WFS and WMS query live public servers, so they depend on hosts that come and go; treat their failures
as environmental until proven otherwise.

## Memory management

FDO and MapGuide both use intrusive reference counting with custom smart pointers, and both hide their
destructors, so a leaked reference is *never* reclaimed by anything else. The full contract is in
[CPP_STYLE.md](./CPP_STYLE.md); in short:

- `FdoPtr(T*)` **attaches** — it takes over the reference you hand it and does not AddRef. The copy
  constructor and copy-assignment *do* AddRef. So `FdoPtr<T> x = obj->GetX();` is correct (the getter's
  reference is taken over), while `FdoPtr<T> x = obj->GetX(); FDO_SAFE_ADDREF(x.p);` leaks.
- Every `Create()`, every `Get*`/`Find*` and `SmartCast<T>()` hands back a reference **you** own:
  `GetItem`, `FindItem`, `GetExtent`, `GetGeometry`, `GetGeometryProperty`, `GetClasses`,
  `GetCharacterSet`, `GetPhysicalSchema`, `GetManager`, `CreateSchemaManager`,
  `FdoFunction::GetArguments`, ...
- `FdoCollection::Add()`, `Insert()` and `SetItem()` AddRef what they are given, so
  `coll->Add(FdoX::Create(...))` loses the `Create()` reference. Give every `Create()` a home:
  `FdoPtr<FdoX> x = FdoX::Create(...); coll->Add(x);`
- Never dereference a counted getter inline (`coll->GetItem(i)->GetName()`,
  `obj->SmartCast<T>()->Foo()`), and never chain them — `schemas->GetItem(0)->GetClasses()->GetItem(n)`
  drops one reference per link. The chained form reads like ordinary member access, which is why it
  keeps coming back: `FdoCollection::GetItem()`, `FdoNamedCollection::GetItem()` and the schema
  manager's own `FdoSmCollection::GetItem()` all end in `FDO_SAFE_ADDREF(m_list[index])`, so the
  reference is the caller's no matter how the collection is owned. In a per-row or per-lookup path the
  leak is multiplied by the workload — ten `fields->GetItem(name)->SetFieldValue(...)` calls in a
  reader's `ReadNext()` leaked 48,844 blocks / 5.5 MB in one 24-test fixture
  ([docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md)). Hold each result in a `Ptr` local, or use
  the owning class's own helper (`FdoSmPhReadWrite::SetString()` is the schema manager's
  look-up-and-release version).
- Child-to-parent and helper-to-owner back-pointers must be **raw**. A counted reference in the
  direction that points *back* at the owner is a cycle, and the owner's destructor can never run to
  break it.
- Containers of raw pointers (`std::map::clear()`, a defaulted destructor) do not release their
  elements.
- Name and release caught exceptions. A `catch (...)` or a nameless `catch (FdoException*)` loses the
  exception and its message buffer, and an exception chained as a cause is AddRef'd by the new
  exception without the creating reference being released. A constructor that throws runs no
  destructor.
- In C provider code, every failure path must free what that path allocated.

`FdoIDisposable::Release()` returns the new reference count ("value for debugging use only"), which
makes it the cheapest leak probe available: print it at teardown and an object that should be gone
shows `1`.

## Finding a leak on Windows

A Debug build is required for all of these; a Release run will not report anything.

1. **Read the code against the rules above first.** Most of the catalogued leaks are lost references
   that are visible on inspection — an unwrapped `Create()`, a chained getter, a raw member pointing
   back at its owner. [docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md#the-recurring-shapes) is
   the checklist.
2. **CRT debug heap.** The Debug configurations link `MultiThreadedDebugDLL` (the debug CRT, `/MDd`
   — see `Utilities\Common\FdoCommon.vcxproj`), so the CRT's own leak check is available. With
   `_CRTDBG_MAP_ALLOC` defined before `<crtdbg.h>` and
   `_CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF)` set in the suite's `main` — each
   suite has its own, e.g. `Providers\SQLite\Src\UnitTest\UnitTest.cpp` — the Debug CRT dumps every
   block still allocated at exit, with the `new` site's file and line. Expect noise: deliberately-live
   global and singleton state appears in that dump, so compare against a run of the *unmodified* tree
   and only chase the difference. `_CrtMemCheckpoint` / `_CrtMemDifference` around a single test
   pinpoints what that test allocates and keeps, which is the precise version of the same idea.

   The GenericRdbms suites (`UnitTestSQLServerSpatial.exe`, `UnitTestPostGIS.exe`, `UnitTestMySQL.exe`,
   the ODBC ones) get their `main` from the cppunit test host
   `Thirdparty\cppunit\HostApp\TestMain.cpp`, which already sets that flag — but the CRT writes the
   report to the *debugger's* output, so a plain command-line run shows nothing. With
   `FDO_CRT_LEAK_CHECK=1` in the environment it is written to stderr instead and therefore lands in
   the run's console output and in `testlogs\<Log>`; the report gives block counts and sizes rather
   than file/line for code inside the provider DLLs, so identify those by size
   (`sizeof(<type>)`) and use the refcount instrumentation below when you need to know *who* holds
   the object. `_CRTDBG_MAP_ALLOC` names a file and line only for translation units that define it,
   and an allocation hook installed in the test host fires for that module's debug-allocator calls
   and not the provider's — adding the mapping to the suspect provider TU is what gets that TU
   named. MSVC has no LeakSanitizer, so there is no ASan-style alternative on Windows. See
   [README.md](./README.md#leak-checking-an-fdo-suite-from-the-command-line-fdo_crt_leak_check).
3. **Visual Studio's Memory Usage tool** (Debug, native heap snapshots) or **Application Verifier**
   (Basics → Leak) for a second, independent view; **Dr. Memory** (`drmemory -- <exe>`) works for
   runs that cannot use the debug heap.
4. **Reference-count instrumentation** — the technique that produced the hardest fixes, because it
   names the *holder* rather than the allocation. Override `AddRef`/`Release` (plus the constructor
   and destructor) on the suspect class to print `this` and a backtrace, then compare the set of
   constructor addresses with the set of destructor addresses: whatever is created and never
   destroyed is the leaked set, and its event history says whether the reference was *lost* (balanced
   AddRef/Release plus a surviving initial reference) or *retained in a cycle*. Printing the count
   returned by the final `Release()` of a set of objects is the quickest version of this.
5. **MSVC AddressSanitizer** (`/fsanitize=address`, VS 2019 16.9+) does **not** detect leaks —
   `/fsanitize=leak` does not exist on MSVC — but it is worth having when a *leak* fix turns into a
   crash, because a double release is exactly what the `FdoPtr` double-attach trap produces.

Then reason about the report the way the Linux pass did: a record shows the allocating frames, not the
ownership chain, and the two useful questions are *is anything still pointing at it?* (nothing → lost
reference, fix the allocation site) and *is the only thing pointing at it another leaked object?*
(then find the root of that group; the rest usually collapses). Group the records by allocation frame
and by the test that ran, fix in batches, re-run the whole suite, and judge by whole records rather
than small size deltas. Before/after a fix, compare the *sets of record signatures* (the top few
frames of each) rather than the totals: a fix must remove records and add none, and that check is
what catches a change that trades a leak for a worse one. Suites you did not touch must come back
with the same record counts they had before.
[docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md#how-to-read-a-leak-report) has the details and
the case studies.

## Generated parsers: the `.y` files are inputs, but they are inert in this build

The four grammars — `Utilities\Common\Src\Parse\yyConstraint.y`, `Fdo\Unmanaged\Src\Fdo\Parse\yyFilter.y`
and `yyExpression.y`, and `Fdo\Unmanaged\Src\Geometry\Parse\yyFgft.y` — are the inputs to the
`build_parse.bat` pipeline (`bison -y -ldv` plus the `script3`/`script*` sed scripts, which rename the
parser's symbols into the `fdo_constraint_yy`-style namespace and move its globals into the shared
`FdoCommonParse` context). **That pipeline does not run in a normal build here**: every one of the four
custom build steps is marked `ExcludedFromBuild="true"` for all configurations in *both* project
formats (`FdoCommon.vcproj`/`.vcxproj` for the constraint grammar, `Fdo.vcproj`/`.vcxproj` for the
filter and expression grammars, `Geometry.vcproj`/`.vcxproj` for FGF). So:

- The checked-in generated files are the source of truth: `Src\Parse\yy*Win.cpp` (which is what
  `FdoCommon.vcxproj` compiles) and `Inc\Parse\yy*Win.h`. **A grammar change that is not mirrored
  into them does nothing at all.**
- Do not re-enable those custom steps casually. The sed scripts and `Parse.h` are written for **GNU
  Bison 1.875** output — they rewrite that skeleton's globals (`yyss`/`yyvs`/`yychar`/`yylval`/…) into
  the `FdoCommonParse` context members, including the Windows-only fixed-size stack arrays — and a
  current bison (3.x) emits a different skeleton with a parameterless `yyparse` and function-local
  lookahead state, which the pipeline and the callers do not expect. The same is true of the Linux
  copies, which are byacc 1.9 output while distros now ship byacc 2.0.
- So a grammar change is a *hand* change in the generated file(s), keeping the two variants' symbol
  numbers straight (bison numbers this grammar's nonterminals `65`-`82`, byacc `314`-`331`).
  [docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md#generated-parsers-the-y-is-the-input-but-the-generated-file-is-what-compiles)
  has the details, and the `%destructor` work recorded there is the worked example — including why a
  leak in the parser's *error* handling cannot be fixed from `FdoCommonParse::Abort()`.

## Platform notes

- A Win32 `CRITICAL_SECTION` is **recursive**: the owning thread may enter it again. FDO provider code
  in this tree is written against that behaviour (the SQLite provider's `CriticalSectionHolder` is
  re-entered by the same thread through the metadata build). A lock that a thread takes twice is free
  here and a deadlock on Linux, where the same shim is a `pthread_mutex_t`; the sibling repo carries
  that shim and the r7133/r7150 history. When adding a lock to provider code, say whether it depends on
  recursion, so the other platform can be kept in step.
- `wchar_t` is 16-bit here and 32-bit on Linux/GCC, and the same sources build on both. Do not bake a
  character width into size or copy arithmetic; use the existing `A2W`/`W2A`/`SLOW` helpers.
- Paths inside the wrappers are relative to the script directory (`%~dp0`), **except** for the
  MapGuide ones: `mapguide_dbg_setup.bat`/`mapguide_rel_setup.bat` write `mapguide_40_revision.txt`
  into `%CD%` and `mapguide_dbg.bat`/`mapguide_rel.bat` read it back from `%CD%`, so those four must be
  run from the repository root or the version stamping silently uses the wrong file (or none).
- Platform initialisation is split in the FDO sources and must stay split: GCC builds run
  `__attribute__((constructor))` hooks, Windows uses `DllMain`, and the two live in opposite arms of
  `#ifndef _WIN32`/`#else` in `Fdo.cpp`, `GeometryDll.cpp` and the GenericRdbms providers.
  `__attribute__((visibility(...)))` and friends are GCC/Clang only, so moving one out of its guard
  breaks this build; the hook names are unique because default visibility interposes by link order on
  ELF, so do not "tidy" those either.

## FDO API/ABI compatibility

A provider is a separate DLL that the core loads at runtime, so core and providers have an ABI
relationship even though they ship from one tree. Most changes under the FDO trees cannot affect it —
and knowing which ones can is what makes an "is this a breaking change?" question quick to answer.

### What is actually public

The shipped surface is what `fdo-build\{dbg64,rel64}` produces — the `Inc`/`Lib64`/`Bin` trees that
`mapguide_*_setup.bat` stages into `MgDev\Oem\FDO`. Judge it from the project files rather than from
directory names, because some of it never forms a boundary at all:

- `Utilities\SchemaMgr` is a **static library** in both project formats (`SchemaMgr.vcxproj` →
  `ConfigurationType>StaticLibrary`; the legacy `SchemaMgr.vcproj` is `4`), so it is linked into each
  provider rather than shared. Its headers are a compile-time boundary only and cannot break a binary
  swap.
- `Utilities\TestCommon` is test scaffolding and is not shipped. The provider-internal headers under
  `Providers\**` are not part of the SDK include tree either.

The provider↔core contract is a single symbol, `CreateConnection`, resolved with `GetProcAddress` /
`dlsym` (see `Fdo\Unmanaged\Src\Fdo\ClientServices\ProviderDef.h`). `_load`/`_unload` are not part of
it, and on Windows those hooks do not exist at all — this platform initialises through `DllMain`.

### Same source is not the same ABI

This is the rule that actually bites when swapping DLLs, and it has no Linux counterpart:

- A provider DLL and `FDO.dll` must come from the **same toolset and the same flag flavour**. Mixing
  `/MD` with `/MDd`, or differing `_ITERATOR_DEBUG_LEVEL`, gives link-time mismatch diagnostics where
  the objects are static and mismatched heaps — or worse — across a DLL boundary where they are not.
  Copying a DLL between two configurations of the same source is therefore not a compatibility test.

### Checking a change

1. **Source.** `svn diff -r A:B --summarize` in the FDO tree, then keep only the paths under an `Inc`
   directory. For those, `svn diff -r A:B <paths> | grep -E '^[-+].*virtual'` answers the question that
   matters most: was a virtual function added, removed or reordered?
2. **Layout.** `cl /d1reportSingleClassLayout<Name>` (or `/d1reportAllClassLayout`) prints the real
   member offsets *and* the vtable slot order, which is a stronger check than a `sizeof` probe. Use it
   whenever a class in a shipped header gains, loses or reorders a member.
3. **Exports.** `dumpbin /exports <dll>` — or `llvm-readobj --coff-exports` / `objdump -p` — over the
   old and new build. A removed export is only a break if something imported it, so look for an import
   of it in the DLLs that consume it before reporting one.
4. **Layout-neutral by construction**, and therefore not worth a check: `FdoPtr<T>` holds exactly one
   `T*`, so an `FdoPtr<X>` member becoming a plain `X*` keeps its size, alignment and offset, and
   adding a `static` member function — or an override of a virtual that already exists in a base class
   — does not change the vtable. Adding a **data member** to a class in a shipped header is the change
   that is not safe, and neither is appending a virtual "at the end": that still breaks every provider
   that implements the interface.

### Policy gate: which mode are we in?

The mode is the line in [Current cycle](#current-cycle) at the top of this file. Read it before
touching anything under an `Inc` directory of `fdo-dbg`/`fdo-rel`, before removing or renaming anything
a shipped DLL exports, and state the mode you assumed when you report the change.

- **`freeze`** — the maintenance cycle. The checks above are mandatory for anything that could reach
  the shipped surface, and a change that would break it is escalated, not made: if a task seems to need
  one, stop and ask rather than reformulating the task so that it avoids the question.
- **`additive`** — still shipping, no longer changing shape. New interfaces, new classes and new
  non-virtual members are fine; changing an existing virtual in any way, or a data member of a shipped
  class, is not.
- **`free`** — feature development. Change the surface deliberately, but not silently: name the removed
  or renamed symbols and the changed layouts in the change description. The sibling repo has to land
  the same source change at the same time — `mapguide` consumes the FDO SDK out of
  `fdo-build\{dbg64,rel64}`, so an FDO provider-ABI break invalidates every provider and both products
  must be rebuilt and released together.

An explicit instruction in the task overrides the line for that task only; say which one you followed.

## Code style

- **Batch files** — `@echo off`, quote every path (`set "VAR=%~dp0..."`), assert with
  `if errorlevel 1` / `if not exist`, and follow the existing wrappers' `:parse_args` loop for options.
  A wrapper that only sets up an environment or forwards flags should not duplicate the build
  commands of the script it calls.
- **PowerShell** — `Run-FdoTests.ps1` is the model: `[CmdletBinding()]`, a `param` block with
  `ValidateSet`, a data table for the per-suite details, and no interactive prompts so it can run
  unattended.
- **C++** — see [CPP_STYLE.md](./CPP_STYLE.md), which applies to edits under `MgDev` and the FDO trees.

## Validation (definition of done)

- **Script-only changes** — run the change end to end at least once (build or test the smallest thing
  that exercises it) and check `git status` for files the scripts wrote outside the gitignored paths.
- **Source-tree changes (FDO or `MgDev`)** — build the affected tree (`fdo_rel.bat -ntp -w=<component>`
  for a provider, or the relevant MapGuide configuration) and run the affected suite with
  `.\Run-FdoTests.ps1 -Test <suite>` — or, while iterating, a single fixture with
  `-Fixture <registry>` — in the matching configuration. Report the suite's result
  (`OK (n)`) rather than just "it built".
- **Release vs Debug** — a Debug pass does not validate the Release build, and here it is weaker
  still: Debug and Release also differ in CRT flavour and `_ITERATOR_DEBUG_LEVEL`, so the two are
  different runtimes, not the same runtime at different speed. Optimisation also removes the NULL-`this`
  guards a Debug build keeps (see [CPP_STYLE.md](./CPP_STYLE.md#null-this-optimisation-and-release-builds)).
  Because the two configurations cannot be built simultaneously here, treat the second one as a planned
  pass rather than an afterthought.
- **Shipped-header changes** — check the [current mode](#current-cycle) first, then
  [FDO API/ABI compatibility](#fdo-apiabi-compatibility) for how to tell whether the shipped surface
  actually moved.
- **Memory-leak fixes** — state which rule above the defect broke, fix it, re-run the affected suite
  in Debug, and say what the leak probe showed before and after (a refcount, a `_CrtMemDifference`
  delta, or the record count). Add a row to [docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) for
  anything new.
- **Locking or ownership changes** — reproduce the failure first, and show the affected suite green
  afterwards. A lock or a back-pointer that only exists for one platform cannot be signed off by
  reading the diff.

## Known issues

- Debug and Release MapGuide builds cannot be made simultaneously; build them one at a time, and
  re-run `mapguide_*_setup.bat` after every FDO build.
- WFS and WMS suites query live public servers and fail for environmental reasons.
- The ODBC sub-suites need their `*Init.txt` files to be correct for the machine, and the Oracle,
  MySQL and PostGIS suites need `fdo_rdbms_thirdparty` populated and the matching environment
  variables set.
- The Microsoft Access (ACE) ODBC driver stops accepting connections part-way through a long-lived
  process (Jet error -1036, "Too many client tasks"). The budget belongs to the ACE engine, so the
  ACE Excel, dBASE and Text drivers share it, and what spends it is connections that overlap — one
  at a time is unlimited. The Access suite is therefore run as one process per fixture, and its
  prefabricated datastore is restored from the pristine copies in the tree before every run — the
  Access Delete fixture removes `EMPLOYEES` rows without putting them back. Both
  behaviours live in the `OdbcAccess` entry of `Run-FdoTests.ps1`, and
  [README.md](./README.md#the-odbc-access-suite-runs-one-fixture-per-process-odbcaccess) has the
  measurements. The FDO-tree part (the registry name `MessageTest` needs to be a chunk on its own,
  and the same note added to the tree's `OpenSourceBuild__README.txt`) is kept as
  `fdo-odbc-access-suite.patch`.
- No `*Init.txt` here sets `datastore`, so the database-backed suites derive their data store name
  as `fdo_<Windows account>` (`fdo_user` on this machine) and create it on demand. A different
  account, or a recreated database container, therefore starts from an empty data store; the suite
  copes because the connection-info test creates it first (see
  [README.md](./README.md#test-data-stores-are-named-after-the-windows-account-fdo_account) and
  `fdo-connectioninfo-datastore.patch`).
- The MapGuide installer requires WiX, and the InstantSetup bundle requires the .NET SDK; neither is
  needed to build or test the C++ trees.
- The GDAL provider's Windows message project has never merged anything but the static RC template, so
  its message table is empty and GDAL error text reaches clients only through the default strings
  compiled into the `NlsMsgGet*` calls. Adding or parameterising a message in `GRFPMessage.mc`
  (e.g. `GRFP_95_CANNOT_GET_IMAGE_INFO`, `GRFP_111`–`114`) therefore changes nothing in the Windows
  catalogue until that project is wired up like the other providers'.
