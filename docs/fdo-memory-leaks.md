# FDO memory leaks: the idioms, the catalogue, and how each one was found

This is the reference for **why FDO code leaks and what the leak looks like**. It is written for
agents working in this repository, where the trees under `fdo-dbg`/`fdo-rel`/`MgDev` are edited but
the build is MSVC rather than a container.

**Provenance.** Everything catalogued here was found and fixed on the Linux side, in the sibling
[mapguide-fdo-docker-build](https://github.com/jumpinjackie/mapguide-fdo-docker-build) repository,
where the Debug build is AddressSanitizer/LeakSanitizer-instrumented and every provider suite's log
doubles as a leak report. The *tooling* references (log paths, the one-shot podman container, the
`SUMMARY: AddressSanitizer` blocks, byte totals) do not apply here; the *mechanisms* do, because they
are reference-counting bugs in shared source, and the same bugs surface in a Debug build on Windows
through the CRT debug heap or a refcount print. [AGENTS.md](../AGENTS.md#finding-a-leak-on-windows)
has the Windows tooling; this document has the patterns and the case studies.

Nothing here has yet been *proved* by a leak run on Windows: the tooling section is guidance built from
the platform's own facilities (the CRT debug heap, the VS Memory Usage tool, Application Verifier,
`Release()`'s return value), not a recipe this repository has already used end to end. The first agent
to run one should correct that section with what actually worked.

No MapGuide (`Mg*`) leak catalogue has been recorded — the rules below apply to `Ptr<T>`/`Mg*` just as
much, but every entry here is an `Fdo*` fix.

## The recurring shapes

These are the shapes that accounted for essentially every leak in the FDO Core and provider suites.
They are listed in rough order of how often they were the answer.

- **A counted reference held in a raw pointer.** `FdoXxx* p = obj->GetX();` with no matching release.
  Nothing looks wrong at the call site, and the object — plus everything it owns — survives. The
  getters that produced this were `GetItem`, `FindItem`, `GetExtent`, `GetGeometry`,
  `GetCharacterSet`, `GetProviderConnectionObject`, `GetPhysicalSchema`, `GetManager`,
  `CreateSchemaManager` and `GetItems`. It is the single most common leak after the next one.
- **`SmartCast<T>()` used inline.** `SmartCast()` exists so that its result can be handed to an
  `FdoPtr`; it AddRefs. `obj->SmartCast<T>()->Foo()` drops that reference and keeps the object (and
  whatever it owns — in one case a whole physical schema) alive.
- **A chained getter in test code.** `coll->GetItem(i)->GetFoo()`, `schemas->GetItem(0)->GetClasses()`,
  `GetClasses()->GetItem(name)`. Each link returns an AddRef'd pointer and each link leaks one
  reference. 25 of the 34 `GetItem(...)->` occurrences in the FDO Core test code were real leaks.
- **A `Create()` whose reference nobody owns.** `coll->Add(FdoPropertyValue::Create(...))` is the
  archetype: `Add()` AddRefs, so the collection owns its own reference and the one `Create()` handed
  back is lost (40 B per call). Also seen as `AddError(FdoSchemaException::Create(...))` in the schema
  XML layer, where every call site had to be wrapped in an `FdoSchemaExceptionP(...)`.
- **A caught exception that is neither rethrown nor released** — including the empty `catch (...)`,
  which loses the only reference to an `FdoException*` and its message buffer. This is what the
  "expected exception" tests leak: they assert on the message of an exception the provider throws and
  then fall out of the `catch` without releasing it.
- **A caught exception chained as a cause.** `FdoException::Create(message, cause)` and
  `SetCause(cause)` AddRef the cause, but the code that created it still holds a reference, so
  `FdoException::Create(msg, FdoException::Create(...))` leaks the inner exception unless the inner
  object's own reference is released.
- **A raw pointer that outlives an exception.** Resource release written on the normal path only
  (after the reader is built, after the schema is committed): an exception thrown in between leaks
  everything acquired so far. The SDF select/update commands and two schema-XML writers had this.
- **A destructor that does not exist.** A constructor that throws runs no destructor, so anything
  acquired on the way in must be released in a `catch (...) { ...; throw; }`.
- **A container of raw pointers that nobody releases.** `std::map::clear()`, `resize()` and a
  defaulted destructor do **not** release the values. A map populated with
  `FDO_SAFE_ADDREF(...)` leaked a whole schema collection per entry on `clear()`, and the MySQL PVC
  insert handler leaked every slot of an array it never emptied. Release the elements as the container
  is emptied.
- **A second call that overwrites the handles the first one set up.** `Open()` on an already-open
  connection that re-creates its environment, schema and databases leaks the previous set. The fix is
  to release the old state first — *not* to turn the second call into a no-op, because callers are
  allowed to change connection properties on a live connection and re-open to apply them.
- **A helper that holds a counted reference to the object that owns it.** A capability or processor
  created by a connection and stored in one of the connection's raw members, which in turn AddRefs the
  connection: the connection can never reach zero references, so its whole graph (schema manager,
  cached schema elements, DB handles, and for an expression capability the deep-copied
  standard-functions graph) leaks, and it leaks *once per connection*. The destructor cannot break it
  because it never runs.
- **Mutually referencing schema classes.** `FdoClassCollection` holds each class strongly,
  `FdoClassDefinition::m_baseClass` holds the base class strongly, and
  `FdoObjectPropertyDefinition::m_class` / `FdoAssociationPropertyDefinition::m_associatedClass` hold
  the property's class strongly. Any pair that references each other is a cycle that survives its
  schema. See [Cycles that are recorded, not fixed](#cycles-that-are-recorded-not-fixed).
- **Constructors and destructors that skip uninitialised state.** A constructor that leaves member
  slots indeterminate plus a destructor gated on `qid != -1`, an open connection or a non-NULL member
  leaks every slot that was never initialised.
- **A C failure path that returns an error without freeing what it just allocated.** A failed
  `mysql_real_connect` that returns without `mysql_close`, a `PQexec` result assigned over a previous
  one, a dropped `new[]` buffer. Provider driver code is C, so nothing is automatic.
- **A value the parser discards on its error path.** A grammar whose actions hand a freshly created
  object to a *second* owner (here `AddNode()`/`AddNodeToDelete()` AddRef into the parse context)
  leaves the parser holding a reference it only releases when the symbol reaches a reduction. A syntax
  error discards symbols instead, so every node on the stack at the error leaks — and for a grammar
  that asks "is this a constraint I understand?", an error is the normal answer, not an exceptional
  one. Fix it with `%destructor` declarations (see **Generated parsers** below); releasing the values
  from the parse context's abort path instead would over-release the nodes whose stack reference an
  action already consumed.
- **A recursion that re-references its own result.** A function that hands back an owned reference and
  then returns `FDO_SAFE_ADDREF(Recurse(...))` drops the reference the recursive call returned — one
  leaked reference per level of depth. This is what kept a WMS capabilities tree (and its whole style
  and CRS subtrees) alive after the commands that had looked a layer up.

## How to read a leak report

Records are aggregated by allocation stack, so a record shows the *allocating* frames, not the
ownership chain that failed to release the object. In a LeakSanitizer report the two classes of record
are named, and the naming is worth keeping even when the tool is not:

- **Direct** — the chunk is unreachable *and* not pointed to by any other leaked chunk. The root, and
  the `#1` frame in it is the allocation site to fix.
- **Indirect** — the chunk is unreachable but still pointed to by another leaked chunk. Its frames are
  the allocation path and are usually not the root cause: pick the record whose group has a *direct*
  sibling, because that one names the lost reference for the whole subtree.
- **No direct records at all** is the signature of a reference cycle, not of a missing `Release()`.

Practically, when the tool of the day does not classify (the CRT debug heap does not), ask the two
questions the classification encodes: *is anything still pointing at it?* (if nothing does, it is a
lost reference — fix the allocation site) and *is the only thing pointing at it another leaked
object?* (if so, find the root of that group first; the rest usually collapses).

The method that worked, repeatedly:

1. **Count before you touch anything** — records, and how many are direct. Run the suite yourself so
   the "before" figure is one you measured.
2. **Group the direct records** by their `#1` frame and by the test further down the stack. A family
   that repeats across tests is the cheapest win; a test-side ownership fix costs nothing and can
   remove most of the direct total at once.
3. **Then take the largest indirect group**, preferring a record with a direct sibling in the same
   group: that record names the lost reference for the whole subtree.
4. **Fix in batches and re-run the whole suite.** Expect the indirect graphs to collapse once their
   root direct record is gone (one MySQL report went from 359 KB to 46 KB off a single 416-byte root),
   and judge a fix by whole records — especially the direct-record count — not by small byte deltas,
   which drift between runs.
5. **Attribute a record to a test** by running one CppUnit registry at a time rather than the whole
   suite: `.\Run-FdoTests.ps1 -Test <suite> -Fixture <registry>` (an unmatched name runs zero tests,
   which the runner reports as a failure). The registry name is the class's named registration
   (`FdoSelectTest`, `SelectTests`, ...), or the class name for a hand-run of the executable
   (`UnitTest.exe SelectTest`, `UnitTest.exe GmlTest`). A suite runner loads providers *by name*
   through `providers.xml`, so after a provider edit the *provider* has to be rebuilt, not just the
   test.

## Instrumentation, when the report cannot name the lost reference

Two techniques did the work whenever the report only showed a surviving graph with no root:

- **Print the reference counts.** `FdoIDisposable::Release()` returns the new count, and the provider
  suites are the cheapest place to observe it: a multi-threaded test that printed the result of its
  final `Release()` showed all ten connections coming back as `1` instead of `0`, which is what turned
  "10 MB of leaked schema graph" into "the capabilities constructor AddRefs the connection that owns
  it". An object that should be destroyed but reports 1 has a reference you can find.
- **Override `AddRef`/`Release`** (plus constructor/destructor) on the suspect class to print `this`
  and a backtrace, gated on an environment variable, and run **one** registry. With virtual
  inheritance the traced `this` is offset-adjusted and will not match the allocator's address, so
  diff the set of constructor addresses against the set of destructor addresses: created minus
  destroyed is the leaked set. An object leaked through a *lost* reference shows balanced
  `AddRef`/`Release` and a surviving initial reference. Confirm the object actually recompiled with
  the instrumented header — a stale binary silently bypasses the overrides.

A worked example of the second technique, because the shape recurs: a report whose largest group sat
under a single 416-byte `FdoSmPhOwner` could not be explained by the owner itself — an owner can never
own its physical schema manager. But the physical schema manager's members (262 reserved-word map
nodes, two databases, tables, 59 columns) were all *below* the owner in the graph, which is only
possible through `FdoSmPhSchemaElement`'s **raw** `mpManager` back-pointer, which leak detectors
follow like any other pointer. The owner was genuinely unreachable, and its two lost references were
two `SmartCast()` calls used inline in test code. That is the general trick: **if class X can never own
class Y, yet Y's members sit in X's leak subtree, then X was reached through a raw back-pointer, and X
itself is the lost reference.**

## Leaks that were fixed

Each row is a real defect, the file(s) it lived in and the mechanism — the part worth recognising in
new code. Paths are relative to the FDO source root.

| Suite | Defect | Mechanism |
|---|---|---|
| FDO Core | `FdoDataValue::VldShift` dropped the source value when the conversion threw | A local holding the value was only released on the success path; the 7 call sites now go through a `VldShiftOrRelease()` that releases on the exception path too. |
| FDO Core | `FdoXmlElementMapping::mClassMapping` | The member was assigned from a getter without taking a reference while its owning type mapping already owned the object. Now documented and non-owning. |
| FDO Core | `FdoSchemaXmlError::Apply` | `mParms->GetItem(i)` returns an AddRef'd pointer the callee does not take ownership of; held in an `FdoStringElementP` local. |
| FDO Core | `FdoXmlPolygon::GetFdoGeometry` | The inner-ring reference came from a getter and was never released; now an `FdoPtr`. |
| FDO Core | `FdoXmlDeserializable::ReadXml` | The `mInternalReader` member kept the reader (and its SAX context) alive after the read, and leaked it outright when `Parse()` threw. Copied to a local and cleared before `Parse()`. |
| FDO Core | `FdoFeatureSchemaCollection::XmlEndDocument` | `CommitSchemas()` throws for an error document, so the release of the XML context that followed it never ran, leaving `collection → XML context → merge context → collection` alive. The context is detached into a local before the throwing call. |
| FDO Core | `FdoXmlLpCollection::Clear()` / `RemoveAt()` | The `GetItem()` result was a raw local that was never released, so every removed item kept one stray strong reference — enough to retain whole schema graphs. |
| FDO Core | `FdoXmlGeometryHandler::EndHandleGML3MultiGeometry` | The geometry was popped off a raw stack without releasing the reference `Create()` had returned (the destructor, the only other pop, does release). |
| FDO Core | `FdoSchemaXmlContext::RefClass2SchemaName` / `CheckWriteAssoc` | `AddError()` AddRefs its argument but does not take ownership; these were the last 2 of the 149 `AddError(Create(...))` sites not wrapped in an `FdoSchemaExceptionP`. |
| FDO Core | Chained getters on AddRef'ing collections in test code | `coll->GetItem(i)->GetFoo()` leaks the reference `GetItem()` returns; rewritten as `FdoStringElementP(coll->GetItem(i))->GetString()`. |
| FDO Core | `Create()` references never released in test code | Objects created in tests (`FilterParseTest`, `FilterTest`, `SchemaTest`) were used and dropped. |
| GDAL | `FdoRfpConnection::SetConfiguration` nested a parse failure as a cause without releasing the caught exception | The 3 `ReadXml` catch blocks now hold the caught exception in an `FdoPtr<FdoException>` before wrapping it, so the incoming reference is released even though the new exception owns the cause. This was the entire GDAL leak. |
| SDF | `SdfConnection::Open` nested a "not an SDF file" failure without releasing the caught exception | Same cause-ownership fix. |
| SDF | `SdfConnection::Open` re-initialised `m_env` / `m_dbSchema` / `m_dbExtendedInfo` on every call | A test that opens the same connection twice leaked the first open's SQLite database graphs — the largest SDF leak. `Open()` still re-runs its initialisation (a caller may change properties and re-open), but releases the previous open's state first. |
| SDF | `SdfUpdate::Execute` / `SdfSelect::Execute` only released the optimized filter on the success path | The filter is held in an `FdoPtr`, so a constraint violation raised while validating still releases it. |
| SDF | `FdoExpressionEngineUtilDataReader` constructor left raw members behind when it threw | A throwing constructor runs no destructor; the raw members are released in a `catch (...) { ...; throw; }`. |
| SDF | `SdfQueryOptimizer::recno_list_intersection` / `recno_list_union` returned from inside the merge loop / from the non-NULL branch | Two functions whose disposal the caller relies on, each with a `return` that skipped it. The union of "all features" with a list is still "all features", so it disposes of both inputs instead of leaking the one it does not return. |
| SDF | `SdfQueryOptimizer::ProcessSpatialCondition` shadowed `rl` / pushed no result for unusable extents | The inner `recno_list* rl = new recno_list;` hid the outer variable (leaked the R-Tree result *and* pushed NULL); the no-bounds branch left the filter and result stacks out of step, so `GetResult()` dropped the surplus entries. |
| SDF | `SdfDeletingFeatureReader` leaked the pending feature keys when it was not read to the end | The writers in `m_keysToDelete` were only freed by the `ReadNext()` that reports the end; the destructor now frees whatever is left, and `ReadNext()` clears the vector once it has disposed of them. |
| SDF | `SdfImpExtendedSelect::ExecuteScrollable` wrapped a `dynamic_cast` of an AddRef'd collection item in an `FdoPtr` | `FdoPtr<FdoComputedIdentifier> id = dynamic_cast<...>(selectList->GetItem(i))` dropped the reference `GetItem()` returned whenever the item was not a computed identifier. The item is held in an `FdoPtr<FdoIdentifier>` and the cast result is raw. |
| SDF | `FdoExpressionEngineImp::PushIdentifierValue` heap-copied a string property value for an API that copies again | The `FdoDataType_String` case allocated `new wchar_t[...]` and passed it to a function that only copies the text (7 records). |
| SDF | DateTime range-constraint values read into raw pointers | `FdoDataValue* valMin = pConstrR->GetMinValue();` dropped the reference the AddRef'ing getters return. Both are `FdoPtr` now. |
| SDF + SHP | `TestSubstrFunction`'s "expected error" catch never released the matched exception | Only the mismatch branch rethrew; the matched exception is now released. |
| SHP | `ShpConnection::GetLpSchema` nested a schema-not-found failure without releasing the caught exception | Same cause-ownership fix. |
| SHP | `ShpLpClassDefinition::ConvertLogicalToPhysical` overwrote `m_physicalColumns` | A class definition already populated by `ConvertPhysicalToLogical()` leaked its `ColumnInfo` (which owns a variable-length buffer from a custom `operator new`). |
| SHP | `ShpSelectAggregates::Execute` leaked `selAggrList` when no aggregate could be optimised | The empty list (and the one left by the non-optimizable path) is deleted before falling back to the generic path. |
| SHP | `ShpLpClassDefinition` constructor leaked its `ColumnInfo` when construction failed | The class registers itself with its parent schema at the end of the constructor, and that registration throws for a duplicate name; a throwing constructor runs no destructor, so the column info is freed in a `catch (...) { ...; throw; }` (and the member is nulled so the destructor cannot double free). |
| SHP | `ShpConnection::CreateSpatialContext` / `GetPhysicalSchema` dropped the reference `FindItem()` returns | `while (mSpatialContextColl->FindItem(newName))` discarded an AddRef'd spatial context per hit (two name-deduplication loops); each lookup is an `FdoPtr` on the iteration now. |
| SHP | `ShpLpClassDefinition::ConvertLogicalToPhysical` kept raw pointers around the spatial-context lookups used to write the PRJ file | `m_connection->GetSpatialContexts()` left the connection's collection AddRef'd forever (48 B) and `scs->GetItem(scName)` did the same for the spatial context just created (160 B, plus its WKT and name buffers). Both are `FdoPtr`s. |
| SHP | Test code did not release AddRef'ing getters and `Create()` results | `TestXYZMFunction` leaked the whole standard-functions graph returned by `GetExpressionCapabilities()` / `GetFunctions()`, and `AddXYZMFeature` leaked the locals it reassigned — ~570 KB of the SHP report. All are `FdoPtr`s now. |
| SHP | Test code swallowed the exception thrown by `FdoIConnection::Open()` | An empty `catch (...)` lost the `FdoException*` thrown from `InitConnectionPaths()`; both sites now catch `FdoException*`, release it and continue. |
| SHP | `FdoCommonFile::GetTempFile()` used `tempnam()` | The name `tempnam()` returns can be taken by another process between the call and the caller's own `open()`. The POSIX branch now builds an `idfXXXXXX` template for `mkstemp()` and closes and unlinks it before returning, so the name comes back in the same "unique, but not created yet" state the Windows branch already returned. |
| WFS | `FdoWfsConnection::Close` cleared `mSchemaMap` without releasing the collections the map owned | The map held raw pointers whose reference was added on insert, so `clear()` (and the defaulted destructor) dropped them instead of releasing them — a whole schema collection per cached class name. It now empties itself through a helper that releases every value and then clears, called by both `Close()` and the destructor. |
| WFS | `FdoWfsDescribeSchemaCommand` never released `mClassNames` | The command created its string collection into a raw member and had an empty destructor, so every DescribeSchema command leaked it; `SetClassNames` leaked the collection it replaced. The member is an `FdoStringsP` now. |
| WFS | Test code discarded `FdoISpatialContextReader::GetExtent()`'s first result | The getter returns a new `FdoByteArray` the caller owns, and the `_DEBUG` dump block called it twice and threw the first away (184 B plus the polygon buffer it wraps). |
| WMS | `FdoOwsHttpHandler::_translateError` passed a freshly created exception straight to `FdoException::SetCause` | `SetCause` takes a reference of its own (`FDO_SAFE_ADDREF(cause)`), so `e->SetCause(FdoException::Create(...))` leaked the cause: the creating reference was never dropped. The 3 HTTP-returned-error/default branches create the cause into a local, hand it to `SetCause`, and release it. |
| WMS | The suite's "this server used to work" tests threw their exception away | These tests assert that a *dead* server still fails, so they had replaced `catch (FdoException* e) { fail(e); }` with a bare `catch (...) { failed = true; }`, losing the exception `FdoOwsHttpHandler::Perform()` throws out of `FdoIConnection::Open()`. 15 such catches now name the exception, release it, and still record the failure — 6 of the suite's 7 direct leaks were one 40 B exception per test that reached a throwing `Open()`. |
| WMS | `FdoWmsConnection::FindLayer` leaked one reference per recursion level on the layer it found | Every style/CRS/select/spatial-extents command goes through this lookup, so a looked-up layer could no longer be freed once the capabilities tree was released, keeping its whole subtree alive. Found with reference tracing plus a registry of live layers dumped at each lifecycle point. |
| King Oracle | `FilterProcessorTests` started each test with a `DROP TABLE` cleanup whose failure it swallowed with a nameless catch | The `catch (FdoException *) { }` (3 places) lost the exception the SQL command throws when the table does not exist yet, leaking the exception object (40 B) and its message buffer (164 B) per test. Each catch names the exception and releases it. |
| MySQL | `FdoRdbmsPvcInsertHandler`'s uninitialised slots | The constructor left member slots indeterminate and the destructor was gated on `qid != -1`, so the 4.2 MB of cursors for features whose id was never assigned leaked. Initialise the slots; do not gate the destructor on state the constructor may not have set. |
| MySQL | `FdoRdbmsSelectCommand::GetOptimizedFeatureReader` leaked its aggregate-select list when it fell back to the generic reader | `FdoRdbmsConnection::GetOptimizedAggregateReader()` returns `NULL` for the base class *without* taking ownership of `selAggrList` (only the SQLServer override may consume it), so the list and its elements leaked on every non-optimizable aggregate select. Both are disposed when the returned reader is `NULL`. |
| MySQL | `mysql_connect` never closed the client handle when `mysql_real_connect` failed | The failure branch set an error and returned without `mysql_close()`-ing the handle `mysql_init()` had just allocated, so every failed connect (bad password, unknown host) leaked the client connection state. The sibling "unsupported version" branch already closed it. |
| MySQL | `FdoRdbmsMySqlFilterProcessor::HasNativeSupportedFunctionArguments` dropped the arguments collection of every `STDDEV` it inspected | `FdoFunction::GetArguments()` returns a counted reference and `(expr.GetArguments()->GetCount() > 1) ? false : true` dereferenced it inline. |
| MySQL | `SchemaMgrTests::testViews` released its static connection only when the test failed | The method re-creates its connection half-way through and the three `catch` blocks were the only places that deleted it, so a *passing* run leaked the second connection with its MySQL context, schema manager and cached physical schema objects (67 KB). |
| MySQL | Test code leaked connections, commands and readers by holding them in raw pointers | A helper held the connection from `GetProviderConnectionObject()` — an owned reference — in a raw pointer and never released it, and another did the same for an `FdoIInsert` and an `FdoIFeatureReader`. A leaked command keeps its AddRef'd connection alive (the command's constructor adds one), so the connection, its PVC processor and its whole schema/database graph survived the test: 3 connections, 1.3 MB. |
| MySQL | Test code swallowed the exception the provider throws for an unsupported function argument | Two tests assert that `EXTRACT`/`EXTRACTTODOUBLE` reject a string argument and wrapped the call in `catch (...) { test_failed = true; }`, losing the exception the select command throws (which wraps the underlying `FdoException`). Each of the 4 call sites now catches `FdoException*` first, releases it and still records the failure. |
| MySQL | Test code dropped the counted references `SmartCast()` returns for the owner and its character set | `owner->SmartCast<FdoSmPhMySqlOwner>()->GetCharacterSet()->SmartCast<FdoSmPhMySqlCharacterSet>()->GetCharLen()` left both the owner and the character set with an unowned reference. Because `FdoSmPhSchemaElement` keeps only a *raw* pointer to its physical schema manager, the one lost owner reference kept the whole physical schema (databases, owners, tables, columns, cached meta-schema) unreachable-but-alive — the 416-byte-root case described above, with ~331 KB hanging off it. |
| MySQL | `SmartCast()` results used inline leaked a reference to the physical schema manager | `GetManager().p->SmartCast<FdoSmPhGrdMgr>()->ClassifyDbObject(...)` (config class and property readers) and `GetPhysicalSchema()->SmartCast<FdoSmPhOdbcMgr>()->GetRdbiContext()` left an unowned reference per call, keeping the whole physical schema graph alive for the same reason as the row above. Each cast is loaded into a local first. |
| MySQL | Test helpers that did not release AddRef'ing getters and `Create()` results | A static connection re-created without disposing its schema manager; a constraint `ParseConstraint` returned; an expected-error branch that dropped the exception; a `char*` returned by `get_geometry_text()`. |
| MySQL | `FdoRdbmsMysqlFilterCapabilities` constructor AddRef'd the connection that owns it | The filter capabilities are stored in one of the connection's raw members, so a counted back-pointer made the connection unreachable at best, and leaked the whole per-connection graph ten times over (ten deep-copied standard-functions graphs, ten schema managers, ten sets of MySQL client handles). The back-pointer must be raw. |
| PostGIS | `postgis_execute()` overwrote `curs->stmt_result` instead of clearing it on re-execution | The cached PVC insert/update cursors run the same prepared statement once per row, so every row but the last leaked a libpq `PGresult` and everything it holds — the largest item in the PostGIS report. |
| PostGIS | Two `PQexec(conn, "COMMIT")` results in `postgis_run_sql` were discarded | The `(void)PQexec(...)` calls that close an open transaction before DDL threw their `PGresult` away, once per DDL statement. Every other `PQexec` in the driver already cleared its result. |
| PostGIS | `FdoRdbmsPostGisFilterProcessor::ProcessSpatialDistanceCondition` kept the counted reference `GetGeometry()` returns in a raw pointer | `geom = dynamic_cast<...>(spatialFilter->GetGeometry())` leaked the test geometry of every spatial and distance condition; the byte array `FdoGeometryValue::GetGeometry()` AddRefs was raw too and leaked with it. |
| PostGIS | The constraint grammar stranded the semantic values of every symbol the parser discards on a syntax error | `Utilities/Common/Src/Parse/yyConstraint.y`, `yyConstraint.cpp`, `yyConstraintWin.cpp` | Each node-producing nonterminal's value is an owned reference (created with `Create()`, then AddRef'd into the parse context by `AddNode()`/`AddNodeToDelete()`), and the parser never released its own copy when a syntax error discarded a partially built constraint — which is the *normal* path for the check clauses a provider skips. `%destructor` declarations for the 18 node-producing nonterminals, plus the equivalent destructor in both generated parsers, release it: 6 direct records and the 12 objects below them (888 B in 18 allocations) go, with no new record family. See **Generated parsers** below — the generated files could not be reproduced by today's generators and are hand-patched in step with the `.y`. |
| SQLite | The r8375 spatial-context test dropped the counted references of its `Create()` results and chained getters | `vals->Add(FdoPropertyValue::Create(...))` (40 B each, the only direct records) and `schemas->GetItem(0)->GetClasses()->GetItem(name)`. It also parked `GetGeometryProperty()` — which returns `FDO_SAFE_ADDREF(m_geometry)` — in a raw pointer, and that single lost reference into a deep-copied schema held the whole graph alive: 5,712 B in 75 records, 72 of them indirect, all in one test. Release the `Create()`s and the graph frees itself. |

## Cycles that are recorded, not fixed

These leaks cannot be fixed by releasing "harder" — every participant in the cycle holds a legitimate
reference, and breaking it changes what the class means by "owns". They are documented so that a
future pass recognises them instead of rediscovering them:

- **`FdoClassDefinition` ↔ `FdoClassDefinition`** (~221 KB, FDO Core). `FdoClassCollection` owns each
  class strongly, `FdoClassDefinition::m_baseClass` owns the base class strongly, and
  `FdoObjectPropertyDefinition::m_class` / `FdoAssociationPropertyDefinition::m_associatedClass` own
  the property's class strongly. Any mutually referencing pair is a cycle. Proven by refcount
  instrumentation: each leaked class sits at exactly `1 (owning collection) + holders`, where
  `holders` is the number of leaked classes pointing at it. Upstream candidates: `FdoClassDefinition`
  (`m_baseClass`), `FdoObjectPropertyDefinition` (`m_class`),
  `FdoAssociationPropertyDefinition` (`m_associatedClass`). A fix means either making class→class
  references weak (with on-demand resolution) or having schema teardown clear them, which changes what
  a class does when it outlives its schema.
- **SDF and WFS residues.** What remains after the SDF connection fixes is the connection's SQLite
  database graph and the `FdoClassDefinition` graphs reachable from it; the WFS residue is the same
  `FdoClassDefinition` family, allocated under the FDO XML/schema layer with no provider frame in the
  chain. Same semantic change needed.
- **The schema-manager error/association cycle** (MySQL, and the bulk of the PostGIS remainder):
  the logical class and property definitions, their FDO-level counterparts, and the errors collected
  against them (`FdoSmLpObjectPropertyDefinition::AddReferenceLoopError` → `FdoSmError` →
  `FdoSchemaException`), built by the association and deliberate-error tests. Breaking it needs the
  error/association ownership in the schema manager to change.
- **The parser's error path** — *fixed*, and worth knowing about because it is the one leak family
  here whose fix is not visible in the compiled code you are reading. Six direct records (3
  `FdoIdentifier`s, 3 `FdoDataValueCollection`s) were stranded while parsing a check clause that turns
  out not to be a constraint the parser understands, which the constraint reader treats as normal. The
  grammar's own reference (the `$$` of the reduction that created it) was never released because on a
  syntax error the enclosing reductions never run, so their `FDO_SAFE_RELEASE($1)` cleanup never
  happens. It cannot be fixed from `FdoCommonParse::Abort()` (releasing twice there over-releases
  nodes whose grammar reference *was* consumed before the error, and releasing "down to one reference"
  corrupts nodes reachable from another discarded node); the fix is `%destructor` declarations in
  `yyConstraint.y` for the node-producing nonterminals, mirrored by hand into both generated parsers.
  See the next section before touching it.
- **The FDO Core XML/deserialization cycles** — `collection → XML context → merge context →
  collection` was detached before the throwing call in the fixed cases; any remaining ones need the
  same kind of semantic change.

## How `FdoCommonParse` owns the nodes the grammar builds

Worth knowing before blaming (or trusting) the constraint/filter parsers, because their reference
counts look odd when read one action at a time. `FdoCommonParse` is the context object the generated
parsers are handed (`Utilities\Common\Inc\Parse\Parse.h`), and it has two collections: `m_nodes`
(what `AddNode()`/`Node_Add()` fills) and `m_nodesToDelete` (what `AddNodeToDelete()` fills — the
`ORConstraint` rules use it for the value collections they assemble and copy from). Both are released
by `Clean()`, which runs after a successful parse and after `Abort()`; `Abort()` itself only clears
`m_nodes` (its commented-out loop that released each node *twice* is the failed attempt to compensate
for the ownership rule below).

The rule every node-producing action follows is: create the node with `Create()` (one reference,
owned by the grammar), hand it to `AddNode()`/`AddNodeToDelete()` (which AddRefs it into the context —
two references), and leave the grammar's copy in the semantic value. From there:

- The context's reference is released by `Clean()` (success) or `Abort()`+`Clean()` (failure).
- The grammar's reference is released by whichever parent rule consumes the value with
  `FDO_SAFE_RELEASE($n)`, or transferred into `m_root` by `SetRoot()` in the `fdo : Constraint` action
  — that one is a *transfer*, not an AddRef, which is why nothing on the `YYACCEPT` path may release
  the start symbol's value.
- A symbol that never reaches a reduction has neither consumer: a syntax error discards it, so the
  grammar's reference is stranded. That is the leak `%destructor` declarations fix, and the reason the
  destructors must not run on the accept path.

Consequences when editing a grammar:

- Add a node-producing nonterminal and it needs a `%destructor` entry in the `.y`, **and** a matching
  case in both generated parsers' destructor switches (the generated files are what compile; see the
  next section for the symbol numbers).
- Values that are *not* owned references must not be given a destructor: the lexer fills only the
  union member a token actually carries (a borrowed `FdoString*` for identifiers and literals, a value
  for the numeric tokens), so several token symbols share union slots they never assign.
- The constraint parser's error path is not exotic: a provider schema reader asks it "is this check
  clause a constraint I understand?", and the answer is legitimately "no" (PostGIS's
  `FdoSmPhRdPostGisConstraintReader` skips what it cannot parse). The other three grammars
  (`yyFilter`, `yyExpression`, `yyFgft`) use the same create-then-`AddNode` pattern and so share the
  latent strand-a-value-on-error risk, but no suite has reported a leak from them — fix those only
  with a test that actually fails part-way through a parse, since the suites stay green either way.
- To reach the other parsers' error paths, run the FDO Core registries that parse rather than
  describe: `UnitTest.exe FilterParseTest`, `FilterTest`, `ExpressionTest`, or through the runner with
  `.\Run-FdoTests.ps1 -Test FdoCore -Fixture FilterParseTest, FilterTest, ExpressionTest` (`-Test
  FdoCore` alone runs them all; `Run-FdoTests.ps1 -List` prints each suite's working directory and
  executable).

## Generated parsers: the `.y` is the input, but the generated file is what compiles

`Utilities/Common/Src/Parse/yyConstraint.y`, `Fdo/Unmanaged/Src/Fdo/Parse/yy{Filter,Expression}.y` and
`Fdo/Unmanaged/Src/Geometry/Parse/yyFgft.y` are the grammar inputs. The FDO tree carries
`build_parse.sh` (Linux) and `build_parse.bat` (Windows), which run the generator plus the `script*` sed
pipelines that rename the parser's symbols into the `fdo_constraint_yy`-style namespace and move its
globals into the shared `FdoCommonParse` context — but the **generated `yy*.cpp` is what is checked
into SVN and compiled**, and the checked-in copies are old enough that today's generators no longer
reproduce them:

- The `yy*Win.cpp` files (the ones this repository compiles) are **GNU Bison 1.875** output;
  `FdoCommon.vcproj` carries a custom build step that regenerates them from the `.y` with whatever
  `bison` is on the local `PATH`, so the `.y` is authoritative for a regenerating build but a modern
  bison would produce a very different file.
- The Linux `yy*.cpp` files are **byacc 1.9** (FreeBSD yacc) output, while current distros ship byacc
  2.0 or GNU bison 3.8, whose skeletons differ by ~1,000 lines and whose new globals the sed pipeline
  does not rewrite.

So the working rule: **change the `.y` (it records the intent and is what a regeneration consumes) and
then hand-apply the equivalent change to the generated parsers**, keeping the variants' symbol numbers
straight — bison numbers the constraint grammar's nonterminals `65`-`82` (from its `yytname`), byacc
numbers them `314`-`331` and needs a `yystos[state]` table that byacc 1.9 does not emit. A grammar-rule
change with no generated-file change does nothing at all.

A leak in the parser's error handling is in this category: only `%destructor` declarations release the
values yacc discards on a syntax error, and those generate code into the files above.
