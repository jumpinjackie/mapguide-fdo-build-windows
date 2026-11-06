# Replacing the MapGuide PHP web applications with one ASP.NET Core application

**Status: feasibility assessment and proposal.** Nothing here is implemented. It answers one question —
*can a single, modern ASP.NET Core application replace `mapadmin`, `schemareport`, the PHP viewer and
Fusion, on both IIS and Apache httpd, on Windows and Linux?* — and it is deliberately blunt about which
parts are already proven, which are merely plausible, and which are a rewrite rather than a port.

Read together with [mapguide-php-decoupling.md](./mapguide-php-decoupling.md): that document is about
removing the *dependency* on bundled PHP; this one is about removing the *need* for PHP at all.

## Contents

- [Verdict](#verdict)
- [1. What would be replaced](#1-what-would-be-replaced)
- [2. The .NET platform that already exists in this tree](#2-the-net-platform-that-already-exists-in-this-tree)
- [3. Why ASP.NET Core fits, and what "hosting" actually has to mean](#3-why-aspnet-core-fits-and-what-hosting-actually-has-to-mean)
- [4. The hosting story, per platform](#4-the-hosting-story-per-platform)
- [5. Proposed application architecture](#5-proposed-application-architecture)
- [6. Porting plan and effort, per application](#6-porting-plan-and-effort-per-application)
- [7. Porting mechanics: PHP to ASP.NET Core](#7-porting-mechanics-php-to-aspnet-core)
- [8. Risks and unknowns](#8-risks-and-unknowns)
- [9. Phasing and decision points](#9-phasing-and-decision-points)
- [10. Recommendation](#10-recommendation)
- [Appendix A — the evidence, in code](#appendix-a--the-evidence-in-code)
- [Appendix B — hosting configuration sketches](#appendix-b--hosting-configuration-sketches)
- [Appendix C — references](#appendix-c--references)

---

## Verdict

**Feasible, and less speculative than it sounds — but it is a porting program, not a platform bet.**

Three things are already true in this repository:

1. **The .NET binding is modern and multi-platform.** `OSGeo.MapGuide.Foundation`, `.Geometry`,
   `.PlatformBase`, `.MapGuideCommon`, `.Web` and `.Portable` are `netstandard2.0` assemblies with
   `win-x64` **and** `linux-x64` native interop, published as NuGet packages. A published package
   (`4.0.0.10185`) really does contain `libMgMapGuideCommon-4.0.0.so`, `libMgFoundation-4.0.0.so`,
   `libxerces-c-3.1.so`, `libACE.so.6.2.6` and the rest of the closure.
2. **The viewer has already been ported once.** `Web/src/mapviewerphp` is 36 files / 4,600 lines of
   PHP; `Web/src/mapviewernet` is 32 files / 4,399 lines of C# — the same application, file for file
   (`mainframe.php` 637 lines ↔ `mainframe.aspx` 642 lines). That is a working proof that the viewer
   logic is language-neutral and that the MapGuide API has no PHP-only idioms in it.
3. **Modern .NET is consumed by this tree already**, at `net6.0` and `net8.0`
   (`Bindings/src/Test/DotNet/src/TestRunner`, `Server/RepositoryAdmin/app`) — though there is no
   ASP.NET Core application yet. The repository's own `Bindings/TODO.txt` carries that as an open item:
   *"Implement a sample asp.net core application that confirms the feasibility of using mg-portable for
   web applications in addition to desktop applications."* So Phase 0 below is not a detour; it closes
   a known gap.

Two things are not true, and the plan has to account for them:

- **There is no supported, in-box ASP.NET Core module for Apache httpd, and Microsoft no longer
  documents Apache as a Linux host.** `learn.microsoft.com/aspnet/core/host-and-deploy/linux-apache`
  now redirects to the **Nginx** article. The httpd story is *reverse proxy to Kestrel*, not *run
  inside httpd*. Section 4 explains why that is a non-issue for MapGuide specifically, and what it
  would take to have a real module.
- **Fusion is not a port.** Its server side is ~19,900 lines of PHP across 91 files, its client is a
  JavaScript framework that calls those endpoints by path, and its plotting depends on TCPDF. Fusion is
  a separate product decision from the other three.

So: replacing `mapadmin` + `schemareport` + the PHP viewer with one ASP.NET Core app is a
**medium-confidence, three-to-four-month job for one experienced developer** (less with two, but not
linearly — see §6.6), with the viewer being the easy part. Adding Fusion roughly doubles it and needs
contract-level work, not just a language translation.

The target runtime should be **.NET 10 LTS** (supported to 2028-11-14). .NET 8 reaches end of support on
2026-11-10, three weeks from the date of this document, so the current `net8.0` project in the tree is
already due for a bump.

---

## 1. What would be replaced

| Application | Files | Lines | What it is | .NET analogue today |
|---|---|---|---|---|
| `Web/src/mapadmin` | 43 | 13,631 | Site administrator: users, groups, roles, server/service properties, logs, packages, unmanaged data, performance report | **None** |
| `Web/src/schemareport` | 11 | 1,347 | Schema explorer for a resource id; renders via XSLT | **None** |
| `Web/src/mapviewerphp` | 36 | 4,600 | PHP AJAX/DWF viewer (server-side page assembly; the browser side is `viewerfiles/`) | **`Web/src/mapviewernet`** (32 files, 4,399 lines, ASP.NET WebForms) |
| `Oem/fusion` | 91 | 19,879 | Fusion server endpoints (layers, widgets, print/plot, Redline, FeatureInfo, QuickPlot) | **None** — and see §6.4 |
| `Oem/fusion/lib/tcpdf` | 136 | 59,202 | PDF generation used by Fusion's print/plot | No direct equivalent; .NET PDF libraries exist |
| `Doc/samples` (`samples.php`, `phpsamples`, `phpviewersample`) | — | — | Developer samples | `samples.php` is a trivial landing page; the samples themselves are documentation |
| MapAgent (`mapagent.fcgi`, `mod_mgmapagent.so`, `isapi_MapAgent.dll`) | — | — | **Native** C++ HTTP endpoint for client-side map requests | **Not replaced** — see §3.3 |

Detail worth knowing before planning the work:

- `mapadmin`'s bulk is presentation, not logic: `serverdatafunctions.php` (2,436 lines) and
  `resizablepagecomponents.php` (2,198 lines) are an HTML/JS component library, and
  `performanceReport.php` (2,166 lines) is one screen. Across `mapadmin` and `schemareport` together the
  actual MapGuide API usage is small and uniform — `MgServerAdmin` (29 uses), `MgResourceIdentifier` (14),
  `MgSiteConnection` (10), `MgUserInformation` (6), `MgSite` (4), plus property/byte-source helpers.
- Everything `mapadmin` does goes **through the API**, not the filesystem: `downloadlogfile.php` uses
  `MgServerAdmin::GetLogFile`, `displaypackagelog.php` uses `GetPackageLog`, log paging uses
  `GetLogFiles`. There is no shared-filesystem assumption to preserve, so the replacement can be a
  remote web tier exactly like today's.
- `schemareport` **hardcodes `Administrator`/`admin`** in `main.php` and opens a site connection with
  it. It is a developer sample, not a product. Do not port it as-is — retire it or redesign it with
  the caller's credentials (see §6.2).

---

## 2. The .NET platform that already exists in this tree

This is the part that turns "wouldn't it be nice" into "this is mostly assembly".

### 2.1 The binding

| Package | Target | Natives shipped |
|---|---|---|
| `OSGeo.MapGuide.Foundation` | `netstandard2.0` | `libFoundationUnmanagedApi.so`, `libMgFoundation-4.0.0.so`, `libMgMdfModel-4.0.0.so`, `libACE.so.6.2.6`, `libxerces-c-3.1.so` |
| `OSGeo.MapGuide.Geometry` | `netstandard2.0` | `libGeometryUnmanagedApi.so`, `libMgGeometry-4.0.0.so` |
| `OSGeo.MapGuide.PlatformBase` | `netstandard2.0` | matching pair |
| `OSGeo.MapGuide.MapGuideCommon` | `netstandard2.0` | `libMapGuideCommonUnmanagedApi.so`, `libMgMapGuideCommon-4.0.0.so` |
| `OSGeo.MapGuide.Web` | `netstandard2.0` | `libWebUnmanagedApi.so`, `libMgHttpHandler-4.0.0.so`, `libMgWebApp-4.0.0.so`, `libMgWebSupport-4.0.0.so`, `liblib_json.so` |
| `MapGuideDotNetApi` | `netstandard2.0` | the legacy monolithic facade |

Both `win-x64` and `linux-x64` native folders exist in the published packages; the Windows rebuild in
this tree produces `win-x64` only (the locally built `10202`/`10203` packages have no `linux-x64`
folder), and `clean.bat` clears the staged `runtimes/linux-x64/native` tree — which is consistent with
the Linux natives being staged in from the sibling repo's container build before packing.

The API surface is the same API the PHP extension wraps, generated from the same
`MapGuideApiGen.xml`/`Constants.xml` by IMake and SWIG, so `MgServerAdmin`, `MgSite`,
`MgSiteConnection`, `MgUserInformation`, `MgResourceService`, `MgFeatureService`,
`MgRenderingService`, `MgDrawingService`, `MgMappingService`, `MgTileService` and friends are all
present. Nothing in `mapadmin` needs an API that the .NET binding does not have.

### 2.2 How it loads

- `OSGeo.MapGuide.MapGuideApi.MgInitializeWebTier(webConfigPath)` (in `OSGeo.MapGuide.Web`,
  `custom/EntryPoint.cs`) must be called once per process before anything else. Subsequent calls are
  no-ops.
- On Linux it first constructs an `MgCoordinateSystemFactory` and disposes it, with this comment:
  *"For non-Windows platforms at least, we need this line below to force the OSGeo.MapGuide.Geometry
  assembly to be loaded into the current AppDomain. Otherwise .net proxy class type resolution will
  break."* That is a workaround for the reflection-based class map below, and it is the first thing to
  re-test under ASP.NET Core.
- `Common/MgClassMap.cs` (auto-generated) resolves every `classId` to a .NET constructor by walking
  `AppDomain.CurrentDomain.GetAssemblies()` and `Type.GetType(name)`. **This has two consequences:**
  the OSGeo assemblies must be loaded before first use (normal for project references), and **trimming
  and Native AOT will break it** unless the assemblies are explicitly rooted.
- P/Invoke is plain `[DllImport("FoundationUnmanagedApi", EntryPoint="CSharp_...")]`; on Linux the
  loader resolves `libFoundationUnmanagedApi.so` from the NuGet `runtimes/linux-x64/native` folder,
  and the native libraries resolve their siblings through `$ORIGIN` RPATH. That is why the packages
  flatten the whole native closure into one directory.

### 2.3 Proof that .NET Core consumption works

| Project | Target | What it proves |
|---|---|---|
| `Bindings/src/Test/DotNet/src/TestRunner` | `net6.0` | a .NET Core console app consuming the five NuGet packages and exercising the API |
| `Server/RepositoryAdmin/app` | `net8.0` | a modern in-tree app: self-contained, single-file publish, `dotnet publish` wired into CMake |
| `Portable/OSGeo.MapGuide.Viewer` | `net6.0-windows;net48` | the WinForms viewer, multi-targeted |
| `Web/src/mapviewernet` | net48 + `MapGuideDotNetApi` | the viewer in C#, running today on IIS |

`RepositoryAdmin` is the packaging precedent to copy — but note it has **no** MapGuide reference, so
its `PublishTrimmed`/`PublishSingleFile` settings are not transferable as-is (see risk 2 in §8).

### 2.4 What is *not* proven

`Bindings/TODO.txt` lists these, all still unticked:

- `Verify test suite still passes (Linux)` — and it appears twice, once under the .NET binding and once
  under the PHP/Java section;
- `Remove monolithic binding upon verification of test suite across all supported platforms`;
- `Implement a sample asp.net core application that confirms the feasibility of using mg-portable for
  web applications in addition to desktop applications`.

and `Bindings/src/Managed/DotNet/README.md` still says the only supported Linux deployment target is
"Ubuntu 16.04 64-bit". The Linux natives are built and packaged, but **the .NET test suite has not been
signed off on Linux**, and nothing in the tree runs a Linux ASP.NET Core consumer. That is the first
thing a feasibility spike must close, and it is a day of work, not a month.

---

## 3. Why ASP.NET Core fits, and what "hosting" actually has to mean

### 3.1 The web tier is a client, not a server extension

This is the key architectural fact, and it is what makes the hosting question much smaller than it
first appears:

> The MapGuide web tier does not extend the web server. It **opens a TCP connection to the MapGuide
> Server** (Admin/Client/Site ports from `webconfig.ini`) and speaks MapGuide's own protocol. PHP,
> Java and .NET are three client libraries for the same server.

`mapadmin` proves it: it never touches the server's filesystem, it calls `MgServerAdmin::GetLogFile`
and friends. The viewer is the same: its server-side code calls the API directly, and only its
**client-side** JavaScript goes through the MapAgent for images and tiles.

So the only thing the application needs from a web server is *HTTP request in, HTTP response out* on a
socket. That is what Kestrel does, identically on Windows and Linux. There is no need — and no
supported mechanism — to embed CoreCLR in httpd.

### 3.2 What "hosting" therefore means

| Platform | Process model | Role of the existing web server |
|---|---|---|
| Windows + IIS | ANCM v2 in-process (app inside `w3wp.exe`) or out-of-process (`dotnet.exe`) | first-class host; can also host the ISAPI MapAgent |
| Windows + Apache | Kestrel in a Windows service | reverse proxy (`mod_proxy_http`); can also host `mod_mgmapagent` |
| Linux + Apache | Kestrel in a systemd unit | reverse proxy; can also host `mod_mgmapagent` |
| Any OS, no web server | Kestrel as a service | **none**, if the app answers `/mapagent` itself (§3.4) |

The MapAgent is the only reason a web server is still required, because the native
`mod_mgmapagent.so`/`isapi_MapAgent.dll` has to be hosted somewhere. That is a removable constraint —
see §3.4 — but during the migration the lowest-risk layout is: the .NET app owns the dynamic paths,
and `/mapagent` and static files stay with IIS/httpd.

### 3.3 What a real httpd module would require, and why not

An in-process Apache module would have to load `hostfxr`, create a .NET runtime per child process,
marshal `request_rec` and APR buckets into ASP.NET Core's `IFeatureCollection`, and reimplement the
ASP.NET Core Module's lifetime/handshake logic — for a process model (`mod_php`-style) that Apache has
been moving away from for a decade. There is no maintained project doing it, Microsoft does not ship
one, and the only thing it would buy over a loopback proxy is a few hundred microseconds per request.
Not worth it.

### 3.4 The app can also replace the MapAgent — which removes the last server dependency

This is easy to miss, and it changes the end state: **the .NET binding can execute MapAgent
operations in-process.**

Every MapAgent implementation — `mapagent.fcgi`, `MapAgent.exe`, `mod_mgmapagent.so`,
`isapi_MapAgent.dll` — is a thin adaptor. It parses the HTTP request into an `MgHttpRequestParam` and
`MgHttpHeader`, populates `MgHttpRequestMetadata` (client IP, agent, locale), calls
`MgHttpRequest::Execute()`, and writes out `MgHttpResponse`/`MgHttpResult`. `Web/src/CgiAgent` is the
whole of that for CGI in about 1,100 lines, including a debug echo mode.

The .NET binding exposes the same objects, including **`MgHttpRequest.Execute()`**
(`OSGeo.MapGuide.Web/MgHttpRequest.cs`), `MgHttpRequestParam`, `MgHttpHeader`, `MgHttpRequestMetadata`,
`MgHttpResponse` and `MgHttpResult`. So an ASP.NET Core endpoint can do the same thing in a few hundred
lines:

```csharp
// /mapagent/{anything} handler (sketch)
var req = new MgHttpRequest(agentUri);                       // agentUri drives URL rewriting
var p = req.GetRequestParam();
foreach (var (k, v) in query.Concat(form)) p.AddParameter(k, v);
var md = req.GetRequestMetadata();
md.SetPropertyValue("ClientIp", remoteIp);
md.SetPropertyValue("ClientAgent", userAgent);
md.SetPropertyValue("Locale", locale);
using MgHttpResponse resp = req.Execute();
// write resp.GetResult().GetStatusCode()/ContentType + the MgByteReader payload
```

What this buys:

- **No web server is required at all** — IIS/httpd become optional (for TLS, vhosts, Windows auth, or
  to keep serving legacy static paths), on Windows *and* Linux. That is the cleanest possible answer to
  the original "should have a hosting story in both IIS and httpd" question: the app does not need
  either.
- It is **faster** than the ISAPI/Apache module: no second native runtime, no interop boundary between
  the agent and `MgHttpHandler` — both live in the same process and library.
- One authentication model for pages *and* protocol endpoints.

What it costs, and why it is not automatically the right first move:

- The request/response mapping must be exact: parameter typing, POST body parsing
  (`multipart/form-data`, `application/x-www-form-urlencoded`), header pass-through, status codes,
  content types, and streaming `MgByteReader` payloads without buffering them in memory.
- Response URL rewriting depends on `agentUri`, so the deployed path must match what clients expect.
- Any MapAgent behavior that lives in the native adaptors rather than in `MgHttpRequest` has to be
  found and reproduced — the CGI agent is the reference implementation to read.
- It is a compatibility surface used by every client-side viewer and by third-party applications
  (OpenLayers, Fusion, Maestro, FDO Toolbox), so it needs its own conformance tests.

**Recommendation:** keep the native MapAgent for Phase 1–3 (zero risk, and it is already deployed), and
treat "MapAgent in the app" as a Phase 5 that unlocks the server-less deployment. Estimate 2–3 weeks
including conformance tests.

---

## 4. The hosting story, per platform

### 4.1 Windows / IIS — first class

- **Prerequisite:** the [.NET Hosting Bundle](https://dotnet.microsoft.com/permalink/dotnetcore-current-windows-runtime-bundle-installer)
  installs the ASP.NET Core Module v2 (ANCM) plus the runtime. If the app is published self-contained,
  the runtime is not needed but ANCM still is.
- **`web.config`** in the app directory points ANCM at the executable and chooses the hosting model.
- **In-process** (default) runs the app inside `w3wp.exe`: lowest latency, but a native access
  violation in a MapGuide library takes the worker process down. **Out-of-process** runs
  `dotnet MapGuide.Web.dll` as a child of ANCM and proxies to it: one extra hop, but native crashes are
  isolated and restartable, and you can attach a debugger to the app without touching IIS.
  **Recommendation: out-of-process** for a native-API-heavy app, at least until stability is proven.
- **App pool:** "No Managed Code", `startMode="AlwaysRunning"`, `idleTimeout=0`. The installer already
  sets `idleTimeout:00:00:00` and `recycling.disallowOverlappingRotation:True` for
  `MapGuide40AppPool` (`IIS7.wxs`, `SetAppPoolProp`); `startMode` is the addition.
- **Identity:** the app pool identity needs read/execute on the app directory (including the native
  DLLs) and on `webconfig.ini`, and network access to the MapGuide Server ports.
- **Startup cost:** loading ~150 MB of native libraries plus `MgInitializeWebTier` takes a second or
  two; with in-process hosting and `preloadEnabled`, warm the app at startup rather than on first
  request.

### 4.2 Windows / Apache — reverse proxy

- Run the app as a **Windows service** (`Microsoft.Extensions.Hosting.WindowsServices`,
  `builder.Services.AddWindowsService()`), listening on `http://127.0.0.1:8010` (or a named pipe, which
  `mod_proxy` cannot reach — use loopback).
- Proxy only the dynamic prefixes; leave `/mapagent` and static content with httpd:

  ```apache
  ProxyPreserveHost On
  ProxyPass        /mapguide/mapadmin      http://127.0.0.1:8010/mapguide/mapadmin
  ProxyPassReverse /mapguide/mapadmin      http://127.0.0.1:8010/mapguide/mapadmin
  # ... repeat for /schemareport, /mapviewerajax, /mapviewerdwf, /fusion
  ```

- `ProxyPreserveHost On` plus `UseForwardedHeaders` in the app are both needed, because MapGuide
  sessions record client IP and user agent (`MgUserInformation.SetClientIp/SetClientAgent`) and the
  PHP code already reads `HTTP_X_FORWARDED_FOR`, `REMOTE_ADDR`, `HTTP_USER_AGENT`.

### 4.3 Linux / Apache — reverse proxy, same shape

- Kestrel in a systemd unit, listening on `http://127.0.0.1:8010` or a Unix socket
  (`KestrelServerOptions.ListenUnixSocket`) with
  `ProxyPass /mapguide/mapadmin "unix:/run/mapguide/web.sock|http://localhost/mapguide/mapadmin"`.
- `mod_proxy` + `mod_proxy_http` only. If Blazor Server is ever chosen for the admin UI, add
  `mod_proxy_wstunnel` (or rely on `mod_proxy_http` Upgrade support in current 2.4.x) — another reason
  to prefer Razor Pages (§5.3).
- Microsoft's current Linux guidance is Nginx-based; Apache works the same way through generic
  `mod_proxy`, but it is not a documented ASP.NET Core host, so this combination is "supported by us"
  rather than "supported by Microsoft".

### 4.4 Linux without a web server

Kestrel + systemd is a complete deployment for the app, but the native MapAgent has no server to live
in. That is acceptable only if the app answers `/mapagent` itself (§3.4); otherwise the classic
viewer — whose JavaScript fetches map images from `mapagent.fcgi` — needs IIS or httpd alongside.

### 4.5 What every host must get right

| Concern | Where it is handled |
|---|---|
| Client IP / agent for MapGuide sessions | `UseForwardedHeaders` (trust the proxy's address only), `HttpContext.Connection.RemoteIpAddress`, `User-Agent` |
| Base path | `app.UsePathBase("/mapguide")` so generated URLs match the deployed prefix |
| HTTPS | terminate at IIS/httpd; the app listens on loopback HTTP |
| Auth cookie protection | persist the Data Protection key ring (and share it if more than one instance) |
| Health | `AddHealthChecks()` + `MapHealthChecks("/health")` for the proxy/service manager |
| Logging | `ILogger` to the Windows Event Log / journald; keep MapGuide's own logs separate |
| Config | `webconfig.ini` stays MapGuide's file; host settings in `appsettings.json` |
| CS.Map dictionaries | `MENTOR_DICTIONARY_PATH` must be set **before** `MgInitializeWebTier` |

---

## 5. Proposed application architecture

### 5.1 Shape

A **modular monolith** — one process, one deployment unit, feature folders per application:

```text
MgDev/Web/src/MapGuide.Web/
├─ MapGuide.Web.Host/            Program.cs, hosting model, Kestrel/service/systemd, health
├─ MapGuide.Web.Core/            MgInit, per-request site connection, auth, localization, options,
│                                error handling, forwarded headers, data protection
├─ MapGuide.Web.Admin/           /mapadmin        (feature folders per screen)
├─ MapGuide.Web.SchemaReport/    /schemareport
├─ MapGuide.Web.Viewer/          /mapviewerajax, /mapviewerdwf
└─ MapGuide.Web.Fusion/          /fusion          (phase 4, optional)
```

One process is not just convenient, it is the right engineering choice: `MgInitializeWebTier` is
process-global, and the native closure is well over 150 MB (`libMgGeometry` alone is 61 MB). Four
separate services would load four copies and multiply the memory footprint.

A single host also buys a genuine product improvement the PHP apps cannot offer: **one login across
admin, schema report and viewer**, one navigation frame, one theme, one error page.

### 5.2 Startup and request lifecycle

```csharp
// Program.cs — the only place MgInitializeWebTier is called
Environment.SetEnvironmentVariable("MENTOR_DICTIONARY_PATH", csMapDictionaryPath); // before init
MapGuideApi.MgInitializeWebTier(webConfigPath);                                    // once, process-wide

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<IMapGuideSessionFactory, MapGuideSessionFactory>();
builder.Services.AddScoped<MgSiteConnectionAccessor>();
...
```

Per request:

1. Resolve the authenticated session (cookie → MapGuide session id).
2. Create a fresh `MgSiteConnection`, `Open()` it with `MgUserInformation` carrying
   `SessionId`, locale, client IP and agent.
3. Do the work in a `using` scope — the .NET wrappers are `IDisposable` and wrap counted native
   objects, so the FDO/MapGuide ownership rules apply to this code exactly as they do to C++.
4. Return HTML/JSON/bytes.

### 5.3 UI technology

**Razor Pages + a few minimal APIs**, not Blazor Server, for the first cut:

- The PHP app is server-rendered forms with postbacks — Razor Pages is the literal ASP.NET Core
  equivalent, and the port stays mechanical.
- Blazor Server needs a persistent WebSocket circuit through the reverse proxy and a server-side state
  per user; it is a nice enhancement for specific screens (the map preview, the performance report
  chart) but it should not be the baseline.
- A SPA would throw away ten thousand lines of HTML that only need translating.

### 5.4 URL compatibility

The installer's Start-menu shortcuts and the documentation point at concrete PHP paths
(`/mapguide/mapadmin/login.php`, `/mapguide/samples.php`). Two options:

- **Serve the legacy paths** as the canonical routes (`/mapguide/mapadmin/login.php` stays), which
  keeps bookmarks, help links and `MapGuide.wxs` shortcuts working with zero changes; or
- **Rename and redirect**, and update `Shortcuts.wxs`, `Help` content and `MgInstantSetup` in the same
  change.

Recommendation: route the legacy paths to the new pages and 301 the handful that genuinely move. It
costs a route table and removes a whole class of "the shortcut is broken" reports.

### 5.5 Static content and the MapAgent

Keep the current split during migration:

```
/mapguide/            -> served by IIS/httpd (static: viewerfiles, stdicons, help, images)
/mapguide/mapagent/   -> native ISAPI (IIS) or mod_mgmapagent (httpd)   [Phase 5: the app]
/mapguide/mapadmin/        -> .NET app (proxy/ANCM)
/mapguide/schemareport/    -> .NET app
/mapguide/mapviewerajax/   -> .NET app
/mapguide/fusion/          -> .NET app (phase 4)
```

Once the app is stable it *can* take over static files (`UseStaticFiles`) and, per §3.4, the MapAgent
endpoint. Doing both would make a standalone Kestrel deployment — no IIS, no httpd — viable on either
OS. That is an optimization, not a dependency, and it should not be part of the first phase.

---

## 6. Porting plan and effort, per application

Estimates assume one developer who knows ASP.NET Core and learns the MapGuide API as they go; “weeks”
are working weeks including tests, not calendar promises.

### 6.1 `mapadmin` — 43 files, 13,631 lines

**The largest single piece of work, and the most mechanical.**

Its screens map one-to-one onto services that the .NET binding exposes:

| Screen group | Files | Behind it |
|---|---|---|
| Authentication / session | `login.php`, `sessionvars.php` | `MgSite.Open`, `MgSite.CreateSession`, `MgUserInformation` |
| Users | `adduser`, `edituser`, `usermanagement`, `assignroles` | `MgUserManagementService` |
| Groups / roles | `addgroup`, `editgroup`, `groupmanagement`, `grouprolemanagement`, `userrolemanagement` | same |
| Server / services | `servermanagement`, `serverproperties`, `servicesproperties`, `viewserverstatus*` | `MgServerAdmin.GetInformationProperties`, `SetInformationProperty` |
| Logs | `logmanagement`, `logproperties`, `viewcurrentlog*`, `downloadlogfile` | `MgServerAdmin.GetLogFiles/GetLogFile` |
| Packages | `makepackage`, `loadpackage`, `packagemanagement`, `displaypackagelog` | `MgServerAdmin.MakePackage/LoadPackage/GetPackageLog` |
| Unmanaged data | `add/editunmanageddata`, `unmanageddatamanagement` | `MgServerAdmin.GetUnmanagedDataMappings` |
| Performance report | `performanceReport*` (2,600+ lines) | `MgServerAdmin` profiling APIs + a temp file |
| WMS/WFS properties | `wmsproperties`, `wfsproperties` | `MgServerAdmin` information properties |

Notes that affect the estimate:

- ~4,600 of the 13,631 lines are the two HTML/JS component libraries; in ASP.NET Core these become a
  layout plus a handful of tag helpers/partials, not a line-for-line port.
- The performance report is a long-running server-side job held in a PHP session variable and polled
  from the page. In ASP.NET Core this becomes an `IHostedService` + a job id, which is both simpler and
  more robust — and it is the one screen worth *redesigning* rather than porting.
- The UI is 20 years old. A faithful port preserves training material and muscle memory; it also
  preserves the reason nobody wants to use it. Decide up front whether this is a port or a redesign;
  doing both at once is how these projects fail.

**Estimate: 6–8 weeks** (8–10 if the performance report is redesigned rather than translated).

### 6.2 `schemareport` — 11 files, 1,347 lines

Small, but it should not be ported as-is: `main.php` connects with a hardcoded
`Administrator`/`admin` and renders the schema through `displayschema.xsl`.

Two sensible outcomes:

- **Retire it.** The schema is visible in MapGuide Maestro, and the mapagent can return the same data.
- **Redesign it** as an authenticated screen inside the unified app: pick a resource, describe the
  schema, render with `XslCompiledTransform` (or directly as HTML), no hardcoded credentials.

**Estimate: 1–2 weeks.**

### 6.3 PHP viewer — 36 files, 4,600 lines

**The easy part, because the C# already exists.** `mapviewernet` is the same application in WebForms;
the port is:

- inline `<script runat="server">` and `<% %>` render blocks → Razor pages and tag helpers;
- `Request.QueryString`/`Request.Form`/`Response.Write` → `HttpContext.Request.Query`/`Form`,
  `Response.WriteAsync`;
- `InitializeWebTier()` → the host's singleton initialization;
- keep the query-string contract exactly (`SESSION`, `MAPNAME`, `LOCALE`, …) because the browser-side
  JavaScript in `viewerfiles/` is shared with the PHP and Java viewers and must not change.

Expect roughly a 1:1 translation: 4,399 C# lines in, 4,000–4,500 C#/Razor lines out.

**Estimate: 3–4 weeks.**

### 6.4 Fusion — 91 files, 19,879 lines (+ 59,202 lines of TCPDF)

**This is the decision that determines whether “single unified app” means “all apps” or “the three
apps that are worth it”.**

Fusion's server side is not a set of pages; it is a **server-side API for a JavaScript client**:

- `layers/MapGuide/php/*.php` (24 files, ~7,000 lines): `LoadMap`, `CreateSession`, `Query`, `Selection`,
  `Buffer`, `Legend`, `Measure`, `Print`, `SaveMap`, `SetLayers`, `GetSelectionProperties`,
  `UserManager`, `JSON`, `Utilities` — each called by the Fusion client with a specific parameter set
  and response format.
- `widgets/**/*.php` (44 files, ~9,100 lines): `FeatureInfo`, `Query`, `Redline`, `QuickPlot`, `Print`,
  `BufferPanel`, `AddWMSLayer`, `CoordinateTracker`, `Measure`, `GoogleStreetViewer`.
- Plotting/printing goes through TCPDF.

Porting means reimplementing that protocol in C# **and** keeping the client unchanged, or changing the
client too. The MapGuide API calls themselves translate cleanly (they are the same calls
`mapviewernet` already makes); the risk is the JSON/XML contract and the accumulated behavior of a
framework that has had no upstream maintainer for years.

Options, in order of cost:

1. **Port the endpoints only** (not the widgets' client-side JS), keeping the exact wire contract:
   ~3–4 months, high regression risk, needs a Fusion client test harness that does not exist.
2. **Reimplement Fusion's data layer as a small, documented JSON API** and adjust the Fusion client:
   ~2–3 months, but it breaks third-party widgets that call the PHP endpoints directly.
3. **Leave Fusion on PHP** while the other apps move, and keep PHP in the installer for Fusion alone:
   zero porting cost, but it defeats the decoupling goal — the PHP runtime stays.
4. **Deprecate Fusion** in favour of the existing `.NET`/Java viewers plus client-side templates, and
   remove it from the product: zero porting cost, but a product decision with users attached.

**Estimate: 3–5 months for option 1 or 2; options 3 and 4 are free and are policy, not engineering.**

### 6.5 Samples

`samples.php` is a 200-line landing page over directory checks; the PHP samples themselves are
documentation. Regenerate the landing page as a Razor page and drop the PHP samples when PHP goes.
**Estimate: days.**

### 6.6 Summary

| Work package | Estimate | Risk |
|---|---|---|
| Host + Core + packaging (Windows & Linux) | 2–3 weeks | low |
| Viewer port | 3–4 weeks | low — already exists in C# |
| `schemareport` (redesigned) | 1–2 weeks | low |
| `mapadmin` | 6–8 weeks | medium — size, parity |
| **Subtotal without Fusion or MapAgent** | **~3–4 months** | |
| Fusion | 3–5 months | **high** |
| MapAgent in the app (optional, §3.4) | 2–3 weeks | medium — wire compatibility |
| Installer/package changes | 2–3 weeks | low |

---

## 7. Porting mechanics: PHP to ASP.NET Core

The PHP apps use a small, conventional surface, which is why the port is mechanical:

| PHP | Where used | ASP.NET Core |
|---|---|---|
| `$_GET`, `$_POST`, `$_REQUEST` | 54 / 89 / 6 uses | `Request.Query`, `Request.Form`, `Request.Query`+`Form` |
| `$_COOKIE`, `$_FILES` | 6 / 6 uses | `Request.Cookies`, `IFormFile` |
| `$_SESSION` (`adminSession`, selected user/group/…, `webConfigFile`) | `sessionvars.php` | cookie authentication + `IDistributedCache` (or claims for the session id) |
| `header('Location: …')` | every screen | `RedirectToPage` |
| `include` / `require` | every screen | layouts, partials, DI |
| `$_SERVER['REMOTE_ADDR']`, `HTTP_X_FORWARDED_FOR`, `HTTP_USER_AGENT` | session attribution | `HttpContext.Connection.RemoteIpAddress`, forwarded-headers middleware, `Request.Headers.UserAgent` |
| `$_SERVER['REQUEST_URI']`, `PHP_SELF` | URL building (`GetSurroundVirtualPath`) | `Request.PathBase`, `Request.Path`, link tag helpers |
| `PHP_AUTH_USER` / `PHP_AUTH_PW` | `login.php` | an authentication handler (Basic or forms) |
| `DOMDocument` / `SimpleXML` | resource content, app definitions | `XDocument` / `XmlReader` |
| XSLT (`displayschema.xsl`) | `schemareport` | `XslCompiledTransform` |
| `libxml_disable_entity_loader(true)` | `fusion/templates/mapguide/index.php` | `XmlReaderSettings.DtdProcessing = Prohibit`, `XmlResolver = null` |
| `FormatMessage`/`GetLocalizedString` | all three apps | `MgLocalizer.GetString(id, locale)` (already used by `mapviewernet`) |
| `setcookie` | performance report | `Response.Cookies.Append` with `SameSite`/`HttpOnly`/`Secure` |

Two things to get right that PHP made implicit:

- **Disposal.** `MgSiteConnection`, `MgService`, `MgByteReader`, every `Mg*` object wraps a counted
  native object. `using` per request, never in a field of a singleton.
- **Initialization order.** `MENTOR_DICTIONARY_PATH` and `webconfig.ini` must be resolvable before
  `MgInitializeWebTier`; the Linux `MgCoordinateSystemFactory` warm-up must still happen before the
  first API call.

---

## 8. Risks and unknowns

| # | Risk | Why it matters | Mitigation |
|---|---|---|---|
| 1 | **Linux .NET support is packaged but unverified** | `Bindings/TODO.txt` still has "verify test suite still passes (Linux)" unticked; README says Ubuntu 16.04 | one-day spike: publish a .NET 10 console app on Ubuntu 24.04 against the NuGet packages, call `MgInitializeWebTier`, enumerate a site, render a map. Do this **before** committing to the plan |
| 2 | **Trimming / AOT breaks the class map** | `MgClassMap` resolves types by reflection over loaded assemblies | do not trim; if size forces it, root the OSGeo assemblies and add a smoke test that constructs one type per `classId` family |
| 3 | **Native crash kills the host** | a fault in a MapGuide DLL is an access violation, not an exception | prefer ANCM out-of-process / a Windows service; configure restart; consider a supervised process |
| 4 | **MapGuide session semantics** | `MgSite.CreateSession()` is server-side; the app must persist the id | auth cookie carrying the session id; no in-memory session state that a restart would lose |
| 5 | **Multi-instance deployments** | data-protection keys and MapGuide sessions must agree | persist/share the key ring; MapGuide sessions are server-side so any instance can use them |
| 6 | **Reverse-proxy client IP** | MapGuide records client IP/agent in the session and logs | forward headers, trust only the proxy |
| 7 | **Fusion contract** | third-party widgets call PHP endpoints directly | treat as a product decision (option 1–4 in §6.4) |
| 8 | **UX parity expectations** | 20-year-old admin UI, undocumented behavior | decide port vs redesign before starting; screenshot-driven parity tests |
| 9 | **.NET 8 is already EOL-bound** | 2026-11-10 | target .NET 10 LTS; bump `RepositoryAdmin` in the same change |
| 10 | **Older Windows servers** | .NET 10 supports Server 2012/2012-R2 only with ESU, 2016+ normally | if a customer runs 2012 R2 without ESU, the .NET 10 app is not an option for them; self-contained does not help, the OS support is the constraint |
| 11 | **Bundle size** | native closure well over 150 MB + self-contained runtime ~70 MB, vs ~120 MB of PHP today | comparable; use framework-dependent + hosting bundle on Windows if size matters |
| 12 | **Installer/prerequisite surface** | today the installer gates the .NET viewer on .NET Framework 4.0 (`NETFRAMEWORK40FULL`, `AspNetRegIIS`) | replace with a hosting-bundle check, or ship self-contained and require nothing |
| 13 | **Licensing** | the app itself would be LGPL-2.1 like the rest of the web tier | keep the existing headers and license file; no new dependencies with incompatible licenses |
| 14 | **MapAgent wire compatibility** (only if §3.4 is pursued) | every client-side viewer and third-party tool calls it; a subtle mismatch is a broken map | keep the native agent until the in-app one has conformance tests; use `CgiAgent` as the reference |

---

## 9. Phasing and decision points

**Phase 0 — spike (1–2 weeks, do this first).**
A throwaway `net10.0` Kestrel app that calls `MgInitializeWebTier`, logs in, lists users, and renders
one map — on **both** Windows and Ubuntu 24.04 — published self-contained. This single artifact
answers risks 1, 2, 3, 4 and 11. If it does not work on Linux, the plan changes materially and it is
better to know now.

**Phase 1 — host + read-only screens (3–4 weeks).**
`MapGuide.Web.Host` + `Core`, authentication, layout, the `schemareport` replacement, and the
installer/service plumbing. Ships something usable, and validates the deployment story end to end.

**Phase 2 — viewer (3–4 weeks).**
Port `mapviewernet` to Razor. At the end of this phase the PHP viewer, the .NET viewer and the app can
coexist behind different paths, which is the safety net for the rest of the migration.

**Phase 3 — `mapadmin` (6–8 weeks).**
Screen by screen, keeping the PHP `mapadmin` routable until each is signed off. This is where the PHP
dependency actually dies.

**Phase 4 — Fusion (product decision).**
Port, reimplement, leave on PHP, or retire. It is the only remaining thing that would keep PHP in the
installer.

**Phase 5 — fold the MapAgent into the app (optional, §3.4).**
At the end of this phase the deployment is one process on either OS with no IIS and no httpd. Worth
doing, but only after the app is trusted, and only with MapAgent conformance tests.

**Decision points:**

- *After Phase 0:* is Linux viable? If not, scope the plan to Windows-only and keep the PHP story for
  Linux (see the companion document).
- *Before Phase 3:* port or redesign `mapadmin`? (One or the other. Not both.)
- *Before Phase 4:* what is Fusion's product status?

---

## 10. Recommendation

1. **Yes, it is feasible — do Phase 0 now.** The binding, the packages and the viewer port already
   exist; the uncertainty is concentrated in the Linux runtime and the deployment model, and both are
   cheap to test.
2. **Target .NET 10 LTS and one modular-monolith app**, with Razor Pages. Do not split it into
   microservices and do not start with Blazor Server.
3. **Port the viewer by translating `mapviewernet`**, not by rewriting it. It is the cheapest proof
   that the approach works and it deletes 4,600 lines of PHP for the least effort.
4. **Treat `mapadmin` as a port with a deliberately limited redesign** (the performance report), and
   `schemareport` as a redesign, because the current one hardcodes `Administrator`/`admin`.
5. **Decide Fusion separately and early.** It is 20,000 lines of server-side API contract, it is the
   only piece that would keep PHP in the installer, and no amount of ASP.NET Core makes it cheap.
6. **Accept the hosting model as it is:** IIS is first-class; httpd is a reverse proxy and always will
   be. Because the web tier is a client of the MapGuide Server, that is not a compromise — it is the
   architecture the product already has.
7. **If "one process, no web server" is the real goal, fold the MapAgent into the app (Phase 5).**
   `MgHttpRequest.Execute()` in the managed binding makes it possible, the native agents are the
   reference implementation, and it is the only thing standing between this design and a single
   self-contained service on both operating systems.

---

## Appendix A — the evidence, in code

| Claim | Evidence |
|---|---|
| The .NET binding is `netstandard2.0` and packaged | `Bindings/src/Managed/DotNet/*/OSGeo.MapGuide.*.csproj` (`TargetFramework`, `GeneratePackageOnBuild`) |
| Linux natives are published | `MgDev/packages/Installed/osgeo.mapguide.*/4.0.0.10185/runtimes/linux-x64/native/*.so` |
| Windows build produces win-only packages; Linux natives are staged in | `MgDev/clean.bat` lines 10-15 delete `runtimes/linux-x64/native/*.so*` |
| A .NET Core consumer exists | `Bindings/src/Test/DotNet/src/TestRunner/TestRunner.csproj` (`net6.0`, PackageReference to the five packages) |
| A `net8.0` publish exists in-tree | `Server/RepositoryAdmin/app/MapGuide.RepositoryAdmin.csproj` (`PublishSingleFile`, `PublishTrimmed`, `SelfContained`) |
| The viewer was already ported | `Web/src/mapviewernet/*.aspx` vs `Web/src/mapviewerphp/*.php` — same file names, 4,399 vs 4,600 lines |
| Init is process-global, with a Linux warm-up | `Bindings/src/Managed/DotNet/OSGeo.MapGuide.Web/custom/EntryPoint.cs` |
| Type resolution is reflection-based | `Bindings/src/Managed/DotNet/Common/MgClassMap.cs` (`AppDomain.CurrentDomain.GetAssemblies()`) |
| Linux .NET is unverified in-tree | `Bindings/TODO.txt` — "Verify test suite still passes (Linux)" unticked |
| An ASP.NET Core sample is already a backlog item | `Bindings/TODO.txt` — "Implement a sample asp.net core application …" |
| `mapadmin` is API-only, no filesystem coupling | `Web/src/mapadmin/downloadlogfile.php` (`MgServerAdmin::GetLogFile`), `displaypackagelog.php`, `logmanagement.php` |
| `schemareport` hardcodes admin credentials | `Web/src/schemareport/main.php` (`$username = "Administrator"; $password = "admin";`) |
| The installer gates the .NET viewer on .NET Framework | `Installer/Libraries/MapGuide Web Extensions/MapGuideWebExtensions.wxs` (`NETFRAMEWORK40FULL`), `MapGuide.wxs` (`AspNetRegIIS`) |

## Appendix B — hosting configuration sketches

**IIS, out-of-process (`web.config` in the app root):**

```xml
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore processPath="dotnet"
                arguments=".\MapGuide.Web.dll"
                hostingModel="outofprocess"
                stdoutLogEnabled="false" />
  </system.webServer>
</configuration>
```

**Apache, Windows or Linux:**

```apache
LoadModule proxy_module        modules/mod_proxy.so
LoadModule proxy_http_module   modules/mod_proxy_http.so

ProxyPreserveHost On
ProxyPass        /mapguide/mapadmin      http://127.0.0.1:8010/mapguide/mapadmin
ProxyPassReverse /mapguide/mapadmin      http://127.0.0.1:8010/mapguide/mapadmin
ProxyPass        /mapguide/schemareport  http://127.0.0.1:8010/mapguide/schemareport
ProxyPassReverse /mapguide/schemareport  http://127.0.0.1:8010/mapguide/schemareport
ProxyPass        /mapguide/mapviewerajax http://127.0.0.1:8010/mapguide/mapviewerajax
ProxyPassReverse /mapguide/mapviewerajax http://127.0.0.1:8010/mapguide/mapviewerajax
# /mapguide/mapagent stays on mod_mgmapagent; static files stay with httpd
```

**systemd unit (Linux):**

```ini
[Unit]
Description=MapGuide Web (ASP.NET Core)
After=network.target

[Service]
Type=notify
WorkingDirectory=/opt/mapguide/web
ExecStart=/opt/mapguide/web/MapGuide.Web
User=mapguide
Group=mapguide
Environment=ASPNETCORE_URLS=http://127.0.0.1:8010
Environment=MENTOR_DICTIONARY_PATH=/opt/mapguide/csmap/Dictionaries
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`Type=notify` needs `builder.Host.UseSystemd()` (`Microsoft.Extensions.Hosting.Systemd`); drop it and use
`Type=simple` if the app does not reference that package.

**Windows service:**

```csharp
builder.Services.AddWindowsService(o => o.ServiceName = "MapGuideWeb");
```

## Appendix C — references

- .NET support policy and releases — <https://dotnet.microsoft.com/platform/support/policy/dotnet-core>
- .NET 10 lifecycle dates (LTS, EOL 2028-11-14) — <https://endoflife.date/dotnet>
- .NET 10 supported OS versions — <https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.md>
- Host ASP.NET Core on Windows with IIS — <https://learn.microsoft.com/aspnet/core/host-and-deploy/iis/>
- ASP.NET Core Module (ANCM) — <https://learn.microsoft.com/aspnet/core/host-and-deploy/aspnet-core-module>
- .NET Hosting Bundle — <https://learn.microsoft.com/aspnet/core/host-and-deploy/iis/hosting-bundle>
- Host ASP.NET Core on Linux with a reverse proxy — <https://learn.microsoft.com/aspnet/core/host-and-deploy/linux-nginx>
  (the former `linux-apache` article now redirects here; there is no Apache module)
- `mod_proxy` / `mod_proxy_http` — <https://httpd.apache.org/docs/2.4/mod/mod_proxy.html>
- Kestrel endpoints, including Unix sockets — <https://learn.microsoft.com/aspnet/core/fundamentals/servers/kestrel/endpoints>
- Windows service hosting — <https://learn.microsoft.com/aspnet/core/host-and-deploy/windows-service>
- Data Protection key management — <https://learn.microsoft.com/aspnet/core/security/data-protection/configuration/overview>
- Forwarded headers — <https://learn.microsoft.com/aspnet/core/host-and-deploy/proxy-load-balancer>
- Trimming and reflection (why `MgClassMap` matters) — <https://learn.microsoft.com/dotnet/core/deploying/trimming/incompatibilities>
