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

Consequences:

- `FdoPtr<T> x = obj->GetX();` — correct: the getter's addref'd pointer is taken over by `x`.
- `m_X = value; FDO_SAFE_ADDREF(m_X.p);` — correct: the assignment attaches, so the explicit
  addref is what gives `m_X` its own owned reference.
- `return FDO_SAFE_ADDREF(m_X.p);` — correct: hands an owned reference to the caller.
- `FdoPtr<T> x = obj->GetX(); FDO_SAFE_ADDREF(x.p);` — **wrong**: over-retains (leaks), since
  `x` already owns the reference the getter returned.
- `catch (FdoException*) { }` (or a nameless `catch (...)`) — **wrong**: the caught exception and its
  message buffer are leaked. Name the exception, assert on it, then release it.
- `coll->Add(FdoX::Create(...))` — **wrong**: `Add()` AddRefs its argument, so it does not consume
  the reference `Create()` returned. Give every `Create()` a home:
  `FdoPtr<FdoX> x = FdoX::Create(...); coll->Add(x);`

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
Fixing one means changing what the class means by "owns", which is why the catalogued cycle cases in
[docs/fdo-memory-leaks.md](./docs/fdo-memory-leaks.md) are recorded rather than patched.

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
