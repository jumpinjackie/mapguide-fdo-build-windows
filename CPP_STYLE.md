# C++ Code Style Guidelines

Applies to edits under `MgDev`, `fdo-dbg` and `fdo-rel`.

## Language standard

Both products' sources are built as **C++11**:

- The CMake-based Linux build (the sibling [mapguide-fdo-docker-build](https://github.com/jumpinjackie/mapguide-fdo-docker-build)
  environment) pins it: `set (CMAKE_CXX_STANDARD 11)` in each tree's top-level `CMakeLists.txt`.
- MSVC compiles C++14 by default, so a C++14/17-only construct will build here and break the other
  platform.

Keep any new code within C++11.

`wchar_t` is 16-bit on MSVC and 32-bit on GCC/Linux, and the same sources compile on both. Do not
assume a character width in size or copy arithmetic — use the existing `A2W`/`W2A`/`SLOW` helpers.

## Comments

Comment on the code and on what it does, not on who noticed. FDO ships to many clients that this
repository does not build, so a comment must not name a downstream consumer other than MapGuide:

- State the **observable effect**: the class definition a reader returns carries empty
  `fdo:geometricTypes` / `fdo:geometryTypes` attributes, so a consumer sees a geometry property that
  allows no geometry types — not "this broke application X".
- **MapGuide is the one exception**, because `MgDev` is in this repository and shares the change: name
  it when the comment explains what MapGuide code here does with the result
  (`MgServerFeatureUtil::SerializeToXml`, the schema a `SELECTFEATURES` response carries).
- The same holds in test code, including the comment on a regression test: say what FDO must return,
  and at most what MapGuide does with it. A defect reported from outside is described as a broken FDO
  contract, with the reporting product left in the commit message rather than the source.

A comment is documentation, so it is written in **US English**: *behavior*, *initialization*,
*optimize*, *catalog*, *parameterize*, *summarize*, not *behaviour*, *initialisation*, *optimise*,
*catalogue*, *parameterise*, *summarise*. Keep an identifier or a quoted string spelled as the code
or the upstream report has it.

## Memory management

Both trees use intrusive reference counting with custom smart pointers. Never `delete` these
objects directly — their destructors are protected and lifetime is managed via `AddRef` / `Release`.

`FdoPtr<>` and `Ptr<>` are reserved exclusively for reference-counted FDO (`Fdo*`) and MapGuide
(`Mg*`) classes. Do not use them for standard library types or for types from third-party
libraries — those have their own (or no) ownership model.

### Ownership contract

- `FdoPtr(T*)` and `FdoPtr::operator=(T*)` **attach without adding a reference** — they take
  ownership of the reference being handed over.
- `FdoPtr`'s copy constructor and copy-assignment **do** add a reference (shared ownership).
- FDO getters and collections (`GetX()`, `GetItem`, `FindItem`, `Add`) **return addref'd
  pointers** — the caller owns the returned reference.
- `FdoIDisposable::GetRefCount()` — and the count `AddRef()` / `Release()` return — is the only way to
  tell whether you are the sole owner of an object, which is what decides whether a child may be
  detached and deleted rather than released.

Consequences:

- `FdoPtr<T> x = obj->GetX();` — correct: the getter's addref'd pointer is taken over by `x`.
- `m_X = value; FDO_SAFE_ADDREF(m_X.p);` — correct: the assignment attaches, so the explicit
  addref is what gives `m_X` its own owned reference.
- `return FDO_SAFE_ADDREF(m_X.p);` — correct: hands an owned reference to the caller.
- `FdoPtr<T> x = obj->GetX(); FDO_SAFE_ADDREF(x.p);` — **wrong**: over-retains (leaks), since
  `x` already owns the reference the getter returned.
- `FdoIdentifier* idf = dynamic_cast<FdoIdentifier*>(left.p); other = idf;` — **wrong**: the assignment
  attaches, so the object still has only the single reference `left` holds, and it dies with `left`.
  This is a **use-after-free**, the mirror image of the over-retain above, and it is silent where it is
  written: the fault arrives later, inside whatever destructor next releases the structure the object
  belonged to (a filter tree, a collection), so the crashing stack names the teardown rather than the
  borrow. Anything read out of an `FdoPtr` — `.p`, a `dynamic_cast` / `static_cast` of it, a member
  reached through it — is a *borrow*, not an owned reference: `FDO_SAFE_ADDREF` it before storing it
  anywhere that outlives that `FdoPtr`, or keep the `FdoPtr` alive for as long as the borrow is used.
- Releasing or walking a structure whose depth grows with its content needs an explicit worklist rather
  than the recursive destructor (or a recursive `Process`): a filter tree carries one node per term, so
  a selection of a few thousand features is a few thousand stack frames. Detach and delete a child only
  when `GetRefCount() == 1`; release anything shared normally, as its other owners expect.
- `catch (FdoException*) { }` (or a nameless `catch (...)`) — **wrong**: the caught exception and its
  message buffer are leaked. Name the exception, assert on it, then release it.
- `coll->Add(FdoX::Create(...))` — **wrong**: `Add()` AddRefs its argument, so it does not consume
  the reference `Create()` returned. Give every `Create()` a home:
  `FdoPtr<FdoX> x = FdoX::Create(...); coll->Add(x);`
- `cmd->SetFilter(FdoFilter::Parse(text))`, `applySchema->SetFeatureSchema(GetSchema())`,
  `cmd->SetFeatureClassName(FdoIdentifier::Create(name))` — **wrong**: an FDO `Set*` does not consume
  the reference you pass (it AddRefs or copies it), so the reference `Create()`/`Parse()` returned is
  lost — a parsed filter, an identifier, or an entire schema graph. Name the argument first:
  `FdoPtr<FdoFilter> f = FdoFilter::Parse(text); cmd->SetFilter(f);`. The string overloads —
  `SetFilter(FdoString*)`, `SetFeatureClassName(FdoString*)` — are different in kind: they parse inside
  the command, so the reference those parses create is the command's own and nothing of the caller's is
  involved. A setter's ownership is a property of its implementation (and of the provider's override of
  it), not of the interface it implements: read the one you are calling before you rely on it.
- `insert->GetPropertyValues()->Add(prop)`, `update->GetPropertyValues()->Clear()`,
  `rows->GetItem(0)->SetFieldValue(...)` — **wrong**: the reference a counted getter returns belongs
  to the caller whether the call through it reads or writes. Hold the collection first:
  `FdoPtr<FdoPropertyValueCollection> values = insert->GetPropertyValues(); values->Add(prop);`.

### SmartCast and the vetted usages of FdoPtr

`SmartCast<T>()` (on `FdoSmDisposable` and friends) also **returns an AddRef'd pointer** — it exists
so the result can be handed straight to an `FdoPtr`:

- `FdoSmPhMySqlOwnerP owner = base->SmartCast<FdoSmPhMySqlOwner>();` — correct.
- `base->SmartCast<FdoSmPhMySqlOwner>()->GetName()` — **wrong**: the cast's reference is dropped and
  never released. Anything the object owns — potentially a whole schema graph — stays alive.

The same applies to dereferencing any AddRef'ing getter inline
(`expr.GetArguments()->GetCount()`, `->FindItem(x)->GetName()`, `geomClass->GetGeometryProperty()->GetName()`):
load it into an `FdoPtr` first, or release it explicitly. A **chain** of them
(`schemas->GetItem(0)->GetClasses()->GetItem(name)`) drops one reference per link.

This includes the *internal* schema-manager collections — `FdoSmCollection::GetItem()`,
`FdoSmNamedCollection::GetItem()` and the `Sm/Ph` row/field collections all end in
`FDO_SAFE_ADDREF(m_list[index])`, so `ROW->GetFields()`, `fields->GetItem(L"name")` and
`rows->GetItem(0)` each hand back a reference the caller owns just like the public FDO collections do.
In a per-row or per-lookup path that is one leaked reference per row per getter: ten
`fields->GetItem(name)->SetFieldValue(...)` calls in a reader's `ReadNext()` leaked 48,844 blocks /
5.5 MB in one 24-test fixture. Prefer the owning class's own helpers — `FdoSmPhReadWrite::SetString()`,
`GetString()`, `GetField()` look the field up, hold it in an `FdoSmPhFieldP` and release it —
otherwise hold each result in a `Ptr` local.

`FdoPtr<>` is vetted **only** as a local variable or as a class member — never as an STL container
element or a function parameter, and do not introduce new code that returns one by value. Where
existing code already returns an `Fdo<X>P`, take the result into an `FdoPtr` local (or a member) and
let the local release it. For a raw-pointer boundary, use `FDO_SAFE_ADDREF`/`FDO_SAFE_RELEASE`.

Because `FdoPtr(T*)` *attaches*, **two `FdoPtr`s must never be built from the same raw pointer** —
each one will release on destruction, so the object is released twice for one `AddRef`:

```cpp
FdoPtr<FdoExpression> expr = filter.GetGeometry();           // owns the +1 the getter returned
FdoPtr<FdoGeometryValue> geom = dynamic_cast<FdoGeometryValue*>(expr.p);   // WRONG: attaches it again
```

The second pointer is a *borrow*; keep it raw (or copy the `FdoPtr`, which AddRefs). The symptom of
getting this wrong is not a leak but a crash — the object is destroyed early and something else is
still pointing at it.

### Reference cycles

Child-to-parent back-pointers must be **raw, non-owning** pointers. A counted reference in one
direction plus a raw (or non-releasing) member in the other is a reference cycle: the object can
never reach zero references, so it survives for the life of the process.

The same rule applies to a helper an object creates and stores in one of its own members (a
capability, a processor, a context): the helper may hold its creator only through a **raw**
back-pointer, because the creator already owns the helper.

Cycle members are not fixable by releasing "harder" — every participant has a legitimate reference.
Fixing one means changing what the class means by "owns", which is why the cataloged cycle cases in
[docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) are recorded rather than patched.

### NULL `this`, optimization and Release builds

A member function must never be entered on a NULL object. That is undefined behavior, and the
optimizer is entitled to assume `this` is never NULL, so it may delete an `if (this)`-style guard and
then dereference the pointer anyway. Code that survives a Debug build can therefore fault in a Release
build. MSVC is no different from GCC in principle — it assumes `this` is non-null just as readily — but
it is less predictable about *when* it elides the check, so a Debug pass here is not evidence of
anything.

Two idioms in the FDO sources depend on a NULL object being tolerated, and each has produced a
Release-only crash in the sibling Linux build of this same code:

- `FdoDataValue::Compare` cannot cope with a NULL operand — the `(!this)` test at its head is dead
  code. A NULL *value* has to go through `FdoInternalDataValue::Compare`, which is the gateway that
  tests for it.
- `SmartCast<T>(true)` is documented as usable on a NULL object, because `dynamic_cast(NULL)` is NULL
  and `FDO_SAFE_RELEASE(NULL)` is a no-op. Once `this` *is* the object pointer, though, the NULL guard
  inside `FDO_SAFE_RELEASE` is dead code, and that is the guard that gets removed. Anything that may be
  NULL — the result of a `FindItem()` that can fail, for example — must be cast through
  `FdoSmDisposable::SafeSmartCast<T>( pObject, true )` rather than `pObject->SmartCast<T>( true )`.
  That is exactly the "Returns NULL if this cannot be cast to type T" contract `SmartCast` already
  documents.

Carrying these fixes into the FDO trees here (`fdo-dbg` and `fdo-rel`) is covered by the "Source trees"
rules in [AGENTS.md](./AGENTS.md).

### FDO

- Wrap FDO interface pointers in `FdoPtr<T>` (defined in `Fdo\Unmanaged\Inc\Common\Ptr.h`),
  or the `Fdo<T>P` convenience typedefs (for example `FdoClassP`).
- Use `FDO_SAFE_ADDREF` / `FDO_SAFE_RELEASE` for raw pointers (defined in
  `Fdo\Unmanaged\Inc\Common\IDisposable.h`).
- FDO interfaces derive from `FdoIDisposable`.
- `FdoCollection::Add()`, `Insert()` and `SetItem()` AddRef what they are given — the caller keeps
  its own reference and has to release it.
- `FdoIDisposable::Release()` returns the new reference count ("value for debugging use only"), which
  makes it the cheapest leak probe there is: print it at teardown and an object that should be gone
  will show a count of 1.

### MapGuide

- Wrap `Mg*` objects in `Ptr<T>` (defined in `Common\Foundation\System\Ptr.h`).
- Use `SAFE_ADDREF` / `SAFE_RELEASE`.
- `Mg*` objects derive from `MgGuardDisposable` (or `MgDisposable`).
- When MapGuide code touches FDO objects, use `FdoPtr` / `FDO_SAFE_*` on them.

### Standard library smart pointers

- `std::shared_ptr` / `std::unique_ptr` are fine for anything that is **not** an `Fdo*` or
  `Mg*` class — use whichever construct is appropriate.
- Do **not** use `std::shared_ptr` on `Fdo*` / `Mg*` objects — it double-owns the refcount.
