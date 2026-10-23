# Decoupling the MapGuide web tier from its bundled PHP

**Status: proposal.** Nothing in this document is implemented. It records what the current trees
actually do, what can be done today to an existing installation, and the shape of a "bring your own
PHP/httpd" future with the file-by-file changes each option needs.

Two questions are answered:

1. **How do I turn PHP off completely on a machine that already has MapGuide installed**, for both the
   bundled httpd and IIS, accepting the loss of `mapadmin`, `schemareport`, Fusion and the PHP viewer?
2. **How do we stop bundling PHP (and httpd) at all**, so a distribution package can use its own PHP
   and Apache, and a Windows deployment can use Apache Lounge + windows.php.net builds?

Everything below is derived from the sources in this repository. The exact upstream ABI rules are
quoted with links in [Appendix C](#appendix-c--upstream-references). The disable procedures in
[Part 1](#part-1--turning-php-off-on-an-existing-installation) have **not** been executed against a
live installation — this build host has no MapGuide installation and no `httpd.exe` — so treat the
first run as a rehearsal and keep the backups the procedure asks for.

The obvious follow-on question — *can the PHP applications themselves be replaced, so that PHP is not
needed at all?* — is answered separately in
[mapguide-aspnet-core-replacement.md](./mapguide-aspnet-core-replacement.md).

## Contents

- [What is bundled, and where it is wired](#what-is-bundled-and-where-it-is-wired)
- [What actually depends on PHP](#what-actually-depends-on-php)
- [Part 1 — Turning PHP off on an existing installation](#part-1--turning-php-off-on-an-existing-installation)
- [Part 2 — Bring your own PHP/httpd](#part-2--bring-your-own-phphttpd)
- [Risks and open questions](#risks-and-open-questions)
- [Appendix A — the two ABI contracts, in detail](#appendix-a--the-two-abi-contracts-in-detail)
- [Appendix B — artifacts and names](#appendix-b--artifacts-and-names)
- [Appendix C — upstream references](#appendix-c--upstream-references)

---

## What is bundled, and where it is wired

### Windows: the installer

The Windows installer carries two full web servers and a PHP runtime, and configures whichever one
the user picked. The pieces that matter:

| What | Where it lives in the repo |
|---|---|
| PHP runtime zip (`php-8.3.26-nts-Win32-vs16-x64.zip`) | `Installer/Support/Web/x64/` |
| Apache httpd zip (`httpd-2.4.65-250724-Win64-VS17.zip`) | `Installer/Support/Web/x64/` |
| `mod_fcgid.so` 2.3.10, `mod_jk.so` 1.2.50 | `Installer/Support/Web/x64/` (`MODULE_VERSIONS.txt`) |
| `php.ini` and `httpd.conf` templates | `Installer/Support/Web/x64/configs/{Php,Apache2}` |
| Version pins and the unpack/config steps | `Installer/build.bat`: `PHP_VERSION=8.3.26` (line 87), `PHP_TS_PACKAGE` (92), `:prepare` block (roughly 200-248) |
| WiX features and the `Php` directory | `Installer/Libraries/MapGuide Web Extensions/MapGuideWebExtensions.wxs`: `PHPLOCATION` (42), `WebExtPhpComponent` (43), `WebExtPhpFeature` (118) |
| Install-time config actions | `Installer/Libraries/MapGuide Web Extensions/Apache.wxs` (`UpdateApacheConfig`, `UpdatePhpIni`), `IIS7.wxs` (`CreateFastCgi`, `CreatePhpScriptMapping`) |
| The config actions themselves | `Installer/Custom/apache_actions/apache_actions.cpp` |
| The PHP extension build | `MgDev/Bindings/src/Bindings/Php/PhpApi.vcxproj`, linking `php8.lib` from `$(PHP_LIB)` |
| The PHP headers used to build it | `MgDev/Oem/php` (the *devel pack*, with ACE-conflict patches) |
| The Apache headers used to build the module | `MgDev/Oem/httpd` (2.4.52 headers and `.lib`s, with ACE-conflict patches) |

The resulting layout under `C:\Program Files\OSGeo\MapGuide\Web\` is:

```text
Web\
├─ Apache24\            bundled httpd 2.4.65 (Apache Lounge, VS17)
│  ├─ bin\httpd.exe
│  ├─ conf\httpd.conf   rewritten at install time by apache_actions!UpdateApacheConfig
│  └─ modules\          mod_fcgid.so, mod_jk.so, mod_mgmapagent.so
├─ Php\                 bundled PHP 8.3.26 NTS
│  ├─ php-cgi.exe, php.exe, php8.dll, ...
│  ├─ php.ini           copied from Support\Web\x64\configs\Php
│  └─ ext\              php_MapGuideApi.dll plus a copy of every Mg*.dll
├─ Tomcat\
├─ Temp\
└─ www\                 the web tier itself
   ├─ mapagent\         mapagent.fcgi, isapi_MapAgent.dll, MapAgent.exe, test forms
   ├─ mapviewerphp\     PHP viewer (ajaxviewer.php, dwfviewer.php, ~36 files)
   ├─ mapviewernet\     ASP.NET viewer
   ├─ mapviewerjava\    JSP viewer (Tomcat)
   ├─ mapadmin\         PHP site administrator (43 files)
   ├─ schemareport\     PHP schema report (11 files)
   ├─ fusion\           Fusion (server-side PHP under templates\, layers\, widgets\)
   ├─ phpsamples\, phpviewersample\, samples.php
   └─ webconfig.ini
```

Service names come from `MG_VERSION_MAJOR_MINOR` (`4.0`): **`ApacheMapGuide4.0`** and
**`TomcatMapGuide4.0`** (`Installer/Libraries/MapGuide Web Extensions/Apache.wxs`).
The product registry key is `HKLM\SOFTWARE\OSGeo\MapGuide\4.0.0` (`MG_REG_KEY` in `Installer/build.bat`).

Two properties decide what the installer wires up, and **they are read only at install time** — editing
the registry afterwards changes nothing:

- `MGWEB_CONFIG` = `APACHE` | `IIS` | `MANUAL` (`Installer/Installers/MapGuide/MapGuide.wxs` line 11)
- `APACHE_API_TYPE` / `IIS_API_TYPE` = `PHP` | `JAVA` | `DOTNET`

### Linux: the CMake build

There is no Linux installer here; the sibling
[mapguide-fdo-docker-build](https://github.com/jumpinjackie/mapguide-fdo-docker-build) owns Ubuntu
packaging, but every input it uses is in this tree:

| What | Where |
|---|---|
| Vendored source tarballs (`php-8.3.26.tar.bz2`, `httpd-2.4.65.tar.bz2`, apr, apr-util, tomcat, tomcat-connectors) | `MgDev/Oem/LinuxApt/` |
| Extraction and versions | `MgDev/cmake_linuxapt.sh` (`PHP_VER=8.3.26` line 133) |
| Header discovery | `MgDev/cmake/modules/FindLinuxApt.cmake` — looks **only** under the extracted tarball |
| `php.ini` template | `MgDev/cmake/configs/php.ini.in` (`extension_dir` line 763, `extension=MapGuideApi` at ~955) |
| Apache snippet template | `MgDev/cmake/configs/mapguide.conf.in` (`AddHandler application/x-httpd-php .php`) |
| Install layout | `MgDev/Oem/LinuxApt/CMakeLists.txt` — `php.ini` into `webserverextensions/php/lib` |
| Packaging split | `MgDev/cmake_package.sh` — a `mapguideopensource-httpd` deb containing `apache2 php tomcat` (line 321) |

So on Linux the web tier is a self-contained `webserverextensions/{apache2,php,tomcat}` tree, which is
why distribution packaging currently can't use the distro's PHP.

---

## What actually depends on PHP

Almost nothing. This is the most important fact in the document, because it means "turn PHP off" is a
contained change with a known blast radius.

| Capability | Needs PHP? | Why |
|---|---|---|
| MapGuide Server, FDO providers, CS-Map | No | separate process, no web server involved |
| MapAgent — `mapagent.fcgi` (CGI), `mod_mgmapagent.so` (httpd), `isapi_MapAgent.dll` (IIS) | **No** | native C++; the module is compiled against the httpd API, not PHP |
| .NET API and `mapviewernet` viewer | No | .NET binding |
| Java API and `mapviewerjava` viewer | No | Tomcat/JSP |
| `webconfig.ini` | No | read by all three language bindings |
| PHP API (`php_MapGuideApi.dll` / `libphp_MapGuideApi.so`) | **Yes** | the only real runtime coupling |
| `mapviewerphp` (PHP AJAX/DWF viewer) | Yes | |
| `mapadmin` (site administrator) | Yes | `login.php` calls `MgInitializeWebTier()` |
| `schemareport` | Yes | |
| Fusion | Yes | `templates/mapguide/index.php`, `layers/*/php/*.php` (~45 server-side files), TCPDF |
| `phpsamples`, `phpviewersample`, `samples.php`, `www/mapagent/*.php` test forms | Yes | |

The practical consequence: **disabling PHP removes the PHP viewer, the site administrator, schema
reporting, Fusion and the samples — and nothing else.** The MapAgent, the Server, the .NET API and the
Java API keep working.

Two product notes:

- On **IIS**, the .NET viewer is a genuine replacement. Its files (`www\mapviewernet`) are installed by
  default; only the IIS *application* configuration is conditional on `IIS_API_TYPE=DOTNET`
  (`MapGuide.wxs` line 397 removes `WebExtMapViewerASPXFeature` for Apache, or for IIS without .NET).
  Re-pointing `/mapguide/mapviewerajax` at `mapviewernet` is therefore possible after the fact.
- On **httpd**, there is no .NET viewer. Without PHP the only viewer road left is the Java viewer
  (Tomcat) — or an external client. Say so before disabling, because "the demo site is blank" is the
  kind of surprise that gets a change rolled back.

### The one real coupling

`php_MapGuideApi` is a native extension. PHP loads it into its own process and passes Zend structures
across the boundary, so the extension is tied to the **PHP build**, not merely to "PHP 8". The rules
(see [Appendix A](#appendix-a--the-two-abi-contracts-in-detail)) are:

- **PHP minor version** — `ZEND_MODULE_API_NO` changes per X.Y. PHP 8.3 is `20230831`, 8.4 is
  `20240924`, 8.5 is `20250925`.
- **NTS vs ZTS** — the module entry records `zts`; a non-thread-safe build and a thread-safe build are
  not interchangeable.
- **Debug vs release** — the module entry records `zend_debug`.
- **Windows toolset** — PHP's build ID is `API<number>,<TS|NTS>[,debug][,VS16|VS17|…]`, and the compiler
  ID is included **only on Windows**. An extension built with the wrong toolset generation is refused
  at load with "Module compiled with build ID=… PHP compiled with build ID=… These options need to
  match", even when the API number is right. The import library is `php8.lib` (NTS) or `php8ts.lib`
  (ZTS).

**Patch releases are interchangeable.** 8.3.26 and 8.3.35 both declare API `20230831`, so a
`php8.dll` swap inside the 8.3 series does not require rebuilding the extension. That single fact is
what makes both the emergency mitigation and the "let the distro patch PHP" plan work.

The build currently encodes the coupling in three places: `$(PHP_SRC)`/`$(PHP_LIB)` in
`setenvironment64.bat`, the literal `php8.lib` in `PhpApi.vcxproj`, and the patched headers in
`MgDev/Oem/php`. All three have to become parameters for a "bring your own" build.

---

## Part 1 — Turning PHP off on an existing installation

### Which option to pick

| Option | Effort | Keeps the apps | Use when |
|---|---|---|---|
| **A. Hot-swap the PHP runtime** (8.3.x → 8.3.y) | minutes | yes | the advisory is fixed in a released 8.3.x — **always try this first** |
| **B. Disable PHP on the web server** (this section) | ~30 min | no | there is no fixed 8.3.x yet, or you cannot take the change risk |
| **C. Sledgehammer** | ~5 min | no | many hosts, or you want a single policy knob |

### 1.1 Before you start

- **Find out what the installer configured**, rather than guessing from the URL you use:

  ```powershell
  Get-ItemProperty 'HKLM:\SOFTWARE\OSGeo\MapGuide\4.0.0' |
      Select-Object MGWEB_CONFIG, IIS_API_TYPE, VIRTUALDIR, APP_POOL_NAME
  ```

  `MGWEB_CONFIG` is `APACHE`, `IIS` or `MANUAL`; `IIS_API_TYPE` is `PHP` or `DOTNET`. Both are written
  at install time only (`MapGuideWebExtensions.wxs`, `WebExtensionsComponent`).
- **Back up** `Web\Apache24\conf\httpd.conf` (and `web.config`, if any) and note the output of
  `httpd.exe -M` / `appcmd list config /section:system.webServer/handlers`, so you can restore.
- **Do not delete `Web\Php\` and call it done.** The MSI owns those files; a repair or a minor upgrade
  will put them back. Disable at the web server, which the MSI does not touch.
- **Deleting the handler is not enough.** With no handler, `.php` becomes a *static* file: httpd and
  IIS will happily serve the source. Every procedure below therefore denies `.php` outright as well.
  That deny is the actual kill switch; the handler removal is what stops `php-cgi.exe` from being
  launched at all.
- Decide about `mapadmin` first. It is the only in-tree user management UI. Alternatives:
  MapGuide Maestro (desktop, present in this workspace) for users/roles and server status/logs, or the
  MapAgent `ServerAdmin` service driven from a small script.

### 1.2 Apache httpd (bundled httpd 2.4.65)

Everything happens in `C:\Program Files\OSGeo\MapGuide\Web\Apache24\conf\httpd.conf`. The installer has
already substituted every `%MG_*%` placeholder, so the lines to remove look like this (the four
`AliasMatch` lines are what `%MG_PHP_API%` prefixed at install time):

```apache
LoadModule fcgid_module modules/mod_fcgid.so
FcgidInitialEnv PHPRC "C:/Program Files/OSGeo/MapGuide/Web/Php"
AddHandler fcgid-script .php
FcgidWrapper "C:/Program Files/OSGeo/MapGuide/Web/Php/php-cgi.exe" .php
```

**Step 1 — comment out the FastCGI module and the PHP wiring.** `FcgidInitialEnv` and `FcgidWrapper`
are `mod_fcgid` directives: once `LoadModule fcgid_module` is commented out, leaving either behind
makes httpd fail on start with `Invalid command 'FcgidWrapper'`. Comment all four lines together.

**Step 2 — comment out the four `mapviewerajax`/`mapviewerdwf` `AliasMatch` lines** (they point at
`www/mapviewerphp`). With PHP denied they would 403 anyway; removing them keeps the error honest.

**Step 3 — deny `.php` globally.** Put this at the end of `httpd.conf`, at top level, outside any
`<Directory>` block. `<FilesMatch>` applies to every request, including the `Alias`-mapped tree:

```apache
<FilesMatch "(?i)\.(php[0-9]*|phtml|phar|phps)$">
    Require all denied
</FilesMatch>
```

**Step 4 — test and restart.**

```powershell
$httpd = 'C:\Program Files\OSGeo\MapGuide\Web\Apache24\bin\httpd.exe'
& $httpd -t                       # "Syntax OK" or it refuses to start
& $httpd -M | Select-String fcgid # expect no output
Restart-Service ApacheMapGuide4.0
```

**Step 5 (optional but recommended) — stop the runtime existing.** A renamed binary cannot be
launched by a stale handler or a forgotten config file, and is trivially reversible:

```powershell
Stop-Service ApacheMapGuide4.0
$php = 'C:\Program Files\OSGeo\MapGuide\Web\Php'
Rename-Item "$php\php-cgi.exe" 'php-cgi.exe.disabled'
Rename-Item "$php\php.exe"     'php.exe.disabled'
Start-Service ApacheMapGuide4.0
```

Leave `php8.dll`, `ext\`, and `php.ini` in place — they are inert without a PHP host, and leaving them
makes rollback a rename.

**Step 6 — verify** (see [1.5](#15-verification)).

The same three edits apply on Linux, where the bundled `webserverextensions/apache2/conf/mapguide/mapguide.conf`
plays the role of `httpd.conf`: remove the PHP `AddHandler`, remove the `mapviewerphp` rewrites, and add
the `<FilesMatch>` deny. The engine itself is switched off where the distro enables it
(`a2dismod php8.3`, or stop the `php8.3-fpm` unit), which is the Linux equivalent of commenting out
`mod_fcgid`.

### 1.3 IIS

IIS is configured in two scopes, and the split matters:

- `system.webServer/fastCgi` is **machine scope** (`overrideModeDefault="Deny"`); a site or application
  cannot change it. Removing a FastCGI application is a server-wide act.
- `system.webServer/handlers` is written by the installer at the *MapGuide application* scope
  (`MapGuideIIS7_I_CreatePhpScriptMapping`, `IIS7.wxs` line 39) for `*.php` →
  `<install>\Web\Php\php-cgi.exe`, handler name `MapGuide_4.0_PHP_via_FastCGI`
  (`PHP_FCGI_HANDLER_NAME`, `MapGuide.wxs` line 36).
- `system.webServer/security/requestFiltering` is delegated, so `.php` can be denied per site/app.

The **surgical** procedure removes MapGuide's own mapping and denies `.php` in the MapGuide
application. The handler may still exist at server scope (a previous PHP install, PHP Manager, Web
Platform Installer); the request-filtering deny is what makes that irrelevant, because it runs before
handler mapping.

```bat
set APPCMD=%windir%\system32\inetsrv\appcmd.exe
set SITE=Default Web Site
set VD=mapguide

rem 0. if a section reports "locked", unlock it once (the installer already unlocks handlers):
rem    %APPCMD% unlock config /section:handlers

rem 1. stop MapGuide's own *.php mapping (application scope)
%APPCMD% set config "%SITE%/%VD%" /section:system.webServer/handlers /-"[name='MapGuide_4.0_PHP_via_FastCGI']"

rem 2. deny .php outright; requests now fail with 404.7 instead of being served as text
%APPCMD% set config "%SITE%/%VD%" /section:system.webServer/security/requestFiltering /+"fileExtensions.[fileExtension='.php',allowed='False']"

rem 3. either repoint the viewer at the ASP.NET viewer ...
%APPCMD% set app "%SITE%/%VD%/mapviewerajax" /physicalPath:"C:\Program Files\OSGeo\MapGuide\Web\www\mapviewernet"
rem    ... or remove the viewer application:
rem    %APPCMD% delete app "%SITE%/%VD%/mapviewerajax"
```

**Optional, machine scope** — remove the FastCGI application so nothing on the box can start that
`php-cgi.exe`. Note this is global: any other application using the same `php-cgi.exe` path loses it
too (on a dedicated MapGuide host, that is exactly what you want).

```bat
%APPCMD% set config /section:system.webServer/fastCgi /-"[fullPath='C:\Program Files\OSGeo\MapGuide\Web\Php\php-cgi.exe']"
```

**Restart.** Handler and request-filtering changes are picked up by the worker process; a change to
`fastCgi` needs WAS to re-read it. The reliable way:

```powershell
iisreset /restart     # or: net stop was /y && net start w3svc
```

**Sledgehammer (all sites, all applications).** Enumerate first, then remove every `*.php` handler and
every FastCGI application; finally deny `.php` at machine scope:

```powershell
Import-Module WebAdministration

# What is actually there?
Get-WebHandler | Where-Object { $_.Path -like '*.php' } | Format-Table Name, Path, ScriptProcessor
Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/fastCgi/*' |
    Select-Object fullPath, arguments

# Remove every *.php handler (repeat at IIS:\Sites and IIS:\Sites\<site> if a level overrides)
Get-WebHandler | Where-Object { $_.Path -like '*.php' } | Remove-WebHandler

# Remove every FastCGI application
Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/fastCgi/*' |
    ForEach-Object {
        Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter 'system.webServer/fastCgi' -Name '.' `
            -AtElement @{ fullPath = $_.fullPath }
    }

# ... and no static serving of .php either
Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
    -Filter 'system.webServer/security/requestFiltering/fileExtensions' `
    -Name '.' -Value @{ fileExtension = '.php'; allowed = $false }

iisreset /restart
```

This is the "globally disabling PHP" option the brief mentions, and it is the only one that survives
someone re-pointing an application at a PHP script later.

### 1.4 What you lose

| URL | Before | After |
|---|---|---|
| `/mapguide/mapagent/mapagent.fcgi?...` | works | **works** |
| `/mapguide/mapviewerajax/ajaxviewer.php` | PHP viewer | 403 (httpd) / 404.7 (IIS) unless repointed at `mapviewernet` |
| `/mapguide/mapadmin/login.php` | site admin | 403 / 404.7 |
| `/mapguide/schemareport/...` | schema report | 403 / 404.7 |
| `/mapguide/fusion/...` | Fusion apps | 403 / 404.7 |
| `/mapguide/samples.php`, `phpsamples/`, `phpviewersample/` | samples | 403 / 404.7 |
| `/mapguide/mapviewernet/ajaxviewer.aspx` (IIS) | ASP.NET viewer | **works** (needs ASP.NET registered) |

### 1.5 Verification

From the web server host. `403` (httpd) or `404.7` (IIS) is the expected answer for every `.php` URL;
a `200` with PHP source in the body is a failure, not a success.

```powershell
$base = 'http://localhost:8008/mapguide'   # IIS: http://localhost/mapguide
'/mapadmin/login.php',
'/mapviewerajax/ajaxviewer.php',
'/schemareport/',
'/fusion/',
'/samples.php' | ForEach-Object {
    $u = $base + $_
    $code = (curl.exe -s -o NUL -w "%{http_code}" $u)
    "{0,-40} {1}" -f $_, $code
}

# MapAgent is native and must still answer (an XML error is a pass; a 404 is not)
curl.exe -s "$base/mapagent/mapagent.fcgi?OPERATION=GETSITEVERSION&VERSION=1.0.0&LOCALE=en"
```

Also confirm no PHP process is running after a request storm:

```powershell
Get-Process php-cgi -ErrorAction SilentlyContinue   # expect nothing
```

and that the server did not silently fall back to static serving:

```powershell
curl.exe -s "$base/mapadmin/login.php" | Select-String 'MgInitializeWebTier'   # must be empty
```

### 1.6 Rollback

- httpd: restore `httpd.conf` from the backup, rename the two `.exe` files back, `httpd -t`,
  `Restart-Service ApacheMapGuide4.0`.
- IIS: re-add the handler and FastCGI app, or simply repair the MSI
  (`msiexec /fa <product>.msi`) which restores the install-time configuration. Re-point
  `mapviewerajax` back at `www\mapviewerphp` first, or the ASP.NET viewer keeps serving.

### 1.7 The fastest mitigation: hot-swap the PHP runtime

If the advisory is fixed in any 8.3.x release, this is a 5-minute change that keeps every PHP app
working: the extension depends on the **minor** version (API `20230831`) and, on Windows, on the
toolset generation (all 8.3.x builds are VS16), and neither changes inside the 8.3 series.

1. Download `php-8.3.y-nts-Win32-vs16-x64.zip` from windows.php.net. **It must be the `vs16`, NTS,
   x64 build** — the extension was linked against `php8.lib` from an NTS VS16 build.
2. Stop `ApacheMapGuide4.0` (or stop the IIS application pool).
3. `Rename-Item Web\Php Web\Php.old`; extract the new zip into `Web\Php`.
4. Copy the pieces that are MapGuide's, not PHP's, from `Web\Php.old`:
   - `php.ini` (the installer's tuned copy), having reviewed any `extension=` lines the new version
     renamed;
   - `ext\php_MapGuideApi.dll`;
   - the `Mg*.dll` set in `Web\Php\` **and** in `Web\Php\ext\` (the build deliberately duplicates them
     — `MgDev/build.bat` lines 357-360 — because the extension's own directory is what Windows uses to
     resolve its imports).
5. Start the service, then prove the extension loaded:

```powershell
& 'C:\Program Files\OSGeo\MapGuide\Web\Php\php-cgi.exe' -i |
    Select-String 'PHP Version|Thread Safety|PHP API|MapGuideApi'
```

`MapGuideApi => enabled` is the extension's own `phpinfo()` row (`MgDev/Bindings/src/Bindings/Php/php.i`).
If the row is missing, PHP printed a "Module compiled with module API=..." warning at startup: the
swap crossed a minor version or picked a TS build, and `php_MapGuideApi.dll` must be rebuilt.

Keep the `Web\Php.old` directory until the apps have been exercised; rollback is a rename.

**Why this is the right first move.** It is the only mitigation that does not trade functionality for
safety, it is reversible in seconds, and it is the same operation a distribution performs for you on
Linux (Ubuntu backports PHP security fixes into the distro's 8.3 package). Turning PHP off should be
the fallback for "no fixed 8.3 exists yet", not the default.

### 1.8 Problems in the current bundle worth fixing regardless

These are observations from reading the shipped configuration. They are not the reason for the
advisory, but they are the reason a "disable PHP" drill is worth doing now rather than during an
incident.

1. **The bundle is nine patch releases behind.** `PHP_VERSION=8.3.26` (`Installer/build.bat`);
   the current release in the 8.3 series is **8.3.35** (2026-09-24). PHP 8.3 left active support on
   2025-12-31 and is in security-fix-only mode until 2027-12-31, so every fix that matters arrives as
   an out-of-band 8.3.x release that this tree will not pick up on its own.
2. **The install-time `php.ini` edit is a no-op.** `apache_actions!UpdatePhpIni` searches for the
   literal string `"; cgi.force_redirect = 1"` (`Installer/Custom/apache_actions/apache_actions.cpp`),
   but the shipped `php.ini` contains `;cgi.force_redirect = 1` — no space after the semicolon
   (`Installer/Support/Web/x64/configs/Php/php.ini` line 783). The replacement never matches. That is
   lucky rather than harmful: the PHP manual says `cgi.force_redirect` should stay **on** for Apache
   (Apache sets `REDIRECT_STATUS`) and must be turned **off** for IIS, so the substitution it was
   trying to make was aimed at the wrong server. The lesson is the maintenance model, not the value:
   patching an installed `php.ini` by string search is unverifiable and silently does nothing. Ship the
   intended values in the file and delete the branch.
3. **`cgi.fix_pathinfo` is left at its default** (line 803 is commented). For a `php-cgi.exe`-based
   deployment this is the setting behind years of path-info and argument-injection bugs; set
   `cgi.fix_pathinfo=0` explicitly if PHP must stay.
4. **`expose_php = On`** (line 400) advertises the exact version in every response header. Set `Off`.
5. **`session.use_strict_mode = 0`** (line 1365) and **`session.cookie_httponly` empty** (line 1404)
   weaken `mapadmin` sessions. `1` and `1` cost nothing.
6. **`php.exe`, `php-win.exe` and `phpdbg.exe` are shipped** next to `php-cgi.exe` but are not used by
   the web tier. Not shipping them removes three interpreters from the box.
7. **The PHP registry key is written for the wrong version.** `MapGuide.wxs` line 21 sets
   `PHP_VERSION` to `5.6.40`, so `WebExtPhpComponent` writes
   `HKLM\SOFTWARE\PHP\5.6.40\IniFilePath`. PHP 8.3 does not read that key (the deployment relies on
   `FcgidInitialEnv PHPRC`), so it is dead configuration that misleads the next reader. Either derive it
   from the real series or drop the component.
8. **`AddHandler cgi-script exe`** is set on the whole `www` tree by the bundled `httpd.conf`. It is
   there for the CGI MapAgent, but it also means any `.exe` that ever lands under `www` is executable.
   Worth narrowing to `mapagent/` while the file is open.
9. **The build says "Thread Safe" but ships non-thread-safe PHP.** `Installer/build.bat` defines
   `PHP_TS_PACKAGE` (line 92) and prints `[prepare] Unpack PHP (Thread Safe)` (line 231), while the
   package is `php-8.3.26-nts-...`. This is exactly the mistake a bring-your-own build cannot afford,
   because a TS extension will not load into an NTS PHP. Rename the variable to `PHP_NTS_PACKAGE`.

---

## Part 2 — Bring your own PHP/httpd

### 2.1 What "bring your own" can and cannot mean

It cannot mean one binary that runs against "PHP 8" in general. It can mean:

> **The PHP extension is built per PHP minor (and per NTS/ZTS, and per Windows toolset), against the
> headers of the PHP the user actually runs; the web server integration is described as configuration,
> not installed as files.**

That is exactly how every distribution packages PHP extensions, and it is achievable here.

There are three delivery models, and they are complementary rather than alternatives:

| Model | Windows | Ubuntu | Effort |
|---|---|---|---|
| **A. Files-only / external web tier** — installer ships content, extension, module and a wiring recipe; never touches a server | new installer mode | new packaging split | small, highest value |
| **B. System packages** — build against `php-config`/`apxs`, depend on the distro's PHP/Apache | n/a | `php-dev`, `apache2-dev` | medium |
| **C. BYO binaries** — point the build at Apache Lounge and windows.php.net builds, produce the extension per target | `MAPGUIDE_PHP_DEV_ROOT`, `MAPGUIDE_HTTPD_ROOT` | n/a | medium |

Model A is the one to do first: it needs no new build matrix, and it is the only model that helps the
*existing* installer, because an external deployment is just a bundled deployment with the server
configuration steps skipped.

### 2.2 Model A — the external (files-only) web tier

**Windows.** Add a fourth value to `MGWEB_CONFIG`: `EXTERNAL` (or reuse `MANUAL`, but rename it, because
"manual" today still installs PHP and httpd). In that mode the installer:

1. installs `www\` unchanged (the app files are PHP source either way);
2. installs the MapGuide native DLLs and the extension for the selected PHP into
   `Web\Php\ext\` — **this directory becomes "MapGuide's PHP artifacts", not "the PHP runtime"**;
3. installs `mod_mgmapagent.so` and a `httpd-mapguide.conf` snippet instead of a whole `Apache24`;
4. runs **no** `UpdateApacheConfig`, **no** Apache/Tomcat service actions and **no** IIS
   `fastCgi`/handler actions;
5. writes a `BYO-WEBTIER.txt` into `Web\` containing the two recipes from this document.

That the two halves of `Web\Php` are currently one WiX component is the main structural obstacle: the
harvest is `$(var.MgSource)\Web\Php\**\*` (`HarvestFiles.wxs` line 13). Split it into
`group_PHPFILES` (the runtime: `php*.exe`, `php8.dll`, `ext\php_*.dll`) and
`group_PHPEXTENSIONFILES` (`php_MapGuideApi.dll`, `Mg*.dll`, `php.ini`). Only the first group is
bundled; the second is always installed.

**Ubuntu.** The equivalent split is already visible in the package list: `mapguideopensource-httpd`
contains `apache2 php tomcat` (`cmake_package.sh` line 321). Replace it with:

- `mapguideopensource-webextensions` — `www\`, web-tier libraries, `webconfig.ini` (unchanged);
- `mapguideopensource-php` — `libphp_MapGuideApi.so` + `conf.d` snippet, `Depends: php8.3-common`
  (or the distro's current series); the extension is installed into the distro's extension directory,
  which is what `php-config --extension-dir` reports;
- `mapguideopensource-apache` — `mod_mgmapagent.so` + `mapguide.conf`, `Depends: apache2`;
- drop `php`, `tomcat`, `apache2` from `webserverextensions/` entirely.

Then a normal Ubuntu deployment is: `apt install mapguideopensource-webextensions
mapguideopensource-php mapguideopensource-apache`, enable the distro PHP SAPI (mod_php or php-fpm), and
`a2enconf mapguide`. Apache/PHP security updates become `apt upgrade`'s job — which is the entire
point.

### 2.3 Model B — system packages on Ubuntu

Concretely, the build must stop looking in `Oem/LinuxApt` and start asking the system:

**`cmake/modules/FindPHP.cmake` (new)**

```cmake
# Replaces the PHP half of FindLinuxApt.cmake.
find_program(PHP_CONFIG_EXECUTABLE NAMES php-config php-config8.3 php-config8.4)
if (PHP_CONFIG_EXECUTABLE)
    execute_process(COMMAND ${PHP_CONFIG_EXECUTABLE} --includes
                    OUTPUT_VARIABLE _inc OUTPUT_STRIP_TRAILING_WHITESPACE)
    separate_arguments(PHP_INCLUDE_DIRS NATIVE_COMMAND "${_inc}")   # -I/usr/include/php/20230831 ...
    execute_process(COMMAND ${PHP_CONFIG_EXECUTABLE} --extension-dir
                    OUTPUT_VARIABLE PHP_EXTENSION_DIR OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${PHP_CONFIG_EXECUTABLE} --version
                    OUTPUT_VARIABLE PHP_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${PHP_CONFIG_EXECUTABLE} --configure-options
                    OUTPUT_VARIABLE PHP_CONFIGURE_OPTIONS)
    string(FIND "${PHP_CONFIGURE_OPTIONS}" "maintainer-zts" _zts)
    if (NOT _zts EQUAL -1)
        message(FATAL_ERROR "Found a ZTS PHP; MapGuide's PHP extension is built for NTS.")
    endif()
endif()
```

**`cmake/modules/FindApache.cmake` (new)**

```cmake
find_program(APXS_EXECUTABLE NAMES apxs apxs2)
execute_process(COMMAND ${APXS_EXECUTABLE} -q INCLUDEDIR   OUTPUT_VARIABLE HTTPD_INCLUDE_DIR ...)
execute_process(COMMAND ${APXS_EXECUTABLE} -q LIBEXECDIR   OUTPUT_VARIABLE HTTPD_MODULE_DIR ...)
execute_process(COMMAND ${APXS_EXECUTABLE} -q SYSCONFDIR   OUTPUT_VARIABLE HTTPD_SYSCONFDIR ...)
# ap_config.h and httpd.h are directly in INCLUDEDIR; apr.h is there too on Debian/Ubuntu
```

Notes that matter:

- **No `libphp` link.** On Linux a PHP extension is a shared object that resolves Zend symbols from the
  running PHP binary. The current `target_link_libraries(... ${PHP_LIBRARY} ...)` is harmless only
  because `${PHP_LIBRARY}` is empty; it must not become a link against `libphp.so`, which the distro
  does not ship as a linkable library.
- **Extension location.** `extension=/usr/lib/mapguide/libphp_MapGuideApi.so` (an absolute path) is
  legal and avoids touching the distro's `extension_dir`. That is the least invasive option; the nicest
  is installing into `php-config --extension-dir` so that a plain `extension=MapGuideApi` works.
- **RPATH.** The extension currently sets `INSTALL_RPATH "$ORIGIN:$ORIGIN/../../lib64"`
  (`Bindings/src/Bindings/Php/CMakeLists.txt`), which assumes the `webserverextensions` layout. For a
  distro install, set an absolute RPATH to the MapGuide library directory at configure time (or add a
  `php-fpm` systemd drop-in with `LD_LIBRARY_PATH`). Without this the extension fails to load with
  "undefined symbol" for the first `Mg*` library.
- **`php.ini`.** Do not ship a full `php.ini` — ship a single-line `conf.d/99-mapguide.ini`. The full
  file in `MgDev/cmake/configs/php.ini.in` exists only to control a PHP we own.
- **SAPI choice.** Debian/Ubuntu build every SAPI (`apache2`, `fpm`, `cgi`, `cli`) from one **NTS**
  PHP per series — `php8.3-dev`'s `main/php_config.h` literally contains `/* #undef ZTS */` — and the
  `libapache2-mod-php8.3` postinst switches Apache to `mpm_prefork` (a non-thread-safe module cannot run
  under a threaded MPM). So one extension build serves `mod_php`, `php-fpm` and the CLI. The PHP
  manual's own advice is to prefer `php-fpm` + `mod_proxy_fcgi` for new deployments. Do not take the
  NTS part on faith: `php-config --configure-options` either contains `--enable-maintainer-zts` or it
  does not, and the `FindPHP.cmake` sketch below fails the configure step if it does.
- **Concrete Ubuntu 24.04 values**, so the snippet is not abstract: `php-config8.3 --extension-dir` is
  `/usr/lib/php/20230831`, `--includes` points at `/usr/include/php/20230831/{,main,TSRM,Zend,ext…}`,
  and `--version` reports `8.3.6` — Ubuntu keeps the upstream base version and backports security fixes
  into the distro revision, which is exactly the behavior that makes "let the distro patch PHP" work.

**The `mapguide.conf` snippet** loses its PHP line (`AddHandler application/x-httpd-php .php`) because
mod_php or `proxy:fcgi` provides it, and keeps the MapAgent handler and the Fusion/viewer rewrites:

```apache
LoadModule mgmapagent_module /usr/lib/apache2/modules/mod_mgmapagent.so
<Directory /usr/share/mapguide/www>
  AddHandler mgmapagent_handler fcgi
  Require all granted
</Directory>
# mod_php:
#   the distro's php8.3 module already maps .php
# php-fpm instead:
#   <FilesMatch "\.php$">
#     SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost"
#   </FilesMatch>
```

### 2.4 Model C — BYO binaries on Windows

The build side is closer than it looks, because both vendor zips ship what a module build needs:

- `httpd-2.4.65-...-VS17.zip` contains **`Apache24\include`** (`httpd.h`, `ap_config.h`, `ap_mmn.h`,
  `ap_release.h`, the APR headers) and **`Apache24\lib`** (`libhttpd.lib`, `libapr-1.lib`,
  `libaprutil-1.lib`). `ApacheAgent.vcxproj` already consumes `$(HTTPD_SRC)\include` and
  `$(HTTPD_LIB)`; pointing those at a copy of the Lounge distribution is enough. No source build.
- `php-8.3.26-...-vs16-x64.zip` contains **`dev\php8.lib`**, and the devel pack
  (`php-devel-pack-8.3.26-nts-Win32-vs16-x64.zip`, see `MgDev/Oem/php/PROVENANCE.txt`) supplies the
  headers. So a complete PHP development input is two zips from windows.php.net.

What has to change:

1. **Parameterize the environment** (`MgDev/setenvironment64.bat`):

   ```bat
   rem Bring-your-own overrides; the defaults stay exactly as they are today
   if not defined MAPGUIDE_PHP_DEV_ROOT   set "MAPGUIDE_PHP_DEV_ROOT=%MG_OEM%\php"
   if not defined MAPGUIDE_HTTPD_ROOT     set "MAPGUIDE_HTTPD_ROOT=%MG_OEM%\httpd"
   set "PHP_SRC=%MAPGUIDE_PHP_DEV_ROOT%\include"
   set "PHP_LIB=%MAPGUIDE_PHP_DEV_ROOT%\lib"
   set "PHP_LIBNAME=php8.lib"
   if "%MAPGUIDE_PHP_TS%"=="1" set "PHP_LIBNAME=php8ts.lib"
   set "HTTPD_SRC=%MAPGUIDE_HTTPD_ROOT%"
   set "HTTPD_LIB=%MAPGUIDE_HTTPD_ROOT%\lib64"
   ```

   Note the Lounge layout is flat (`include\apr.h`, `lib\libapr-1.lib`) whereas the vendored
   `Oem/httpd` puts the import libs in `lib64`. Support both, or normalize when copying.

2. **Parameterize the project** (`PhpApi.vcxproj`): replace the literal `php8.lib` in both
   configurations with `$(PHP_LIBNAME)`, add `ZTS` to `PreprocessorDefinitions` when
   `MAPGUIDE_PHP_TS=1`, and keep `$(PHP_SRC)\ext\w32api` (it exists only in some packs).

3. **Re-apply the header patches to the build copy, never to the installation.** Both vendored trees
   exist because of the same collision: ACE and PHP/APR both define `uid_t`, `gid_t`, `pid_t`,
   `key_t`, and `struct iovec` (`MgDev/Oem/php/CHANGES.TXT`, `MgDev/Oem/httpd/CHANGES.TXT`). A BYO
   build must copy the target headers into the build tree and apply the same guards there. Longer
   term, fix the collision in MapGuide's own translation units by including the MapGuide headers before
   PHP/APR (what `php.i` already does with `MapGuideCommon.h`) so that no patch is needed.

4. **Stop shipping the runtime in the installer** (`Installer/build.bat` `:prepare`, `HarvestFiles.wxs`)
   and ship the extension instead. The installer needs one new input: the **PHP minor** the user runs.
   Ask for the `php-cgi.exe` path and derive it:

   ```powershell
   & $phpCgi -i | Select-String 'PHP API|Thread Safety|PHP Version'
   # PHP API => 20230831   => 8.3
   # Thread Safety => disabled  => NTS (the only supported mode today)
   ```

   then install the matching prebuilt `php_MapGuideApi-8.3-nts-vs16-x64.dll`. Load it from an extra
   ini directory rather than by editing the user's `php.ini`:

   ```ini
   ; <install>\Web\Php\conf.d\mapguide.ini
   extension_dir = "C:\Program Files\OSGeo\MapGuide\Web\Php\ext"
   extension   = php_MapGuideApi
   ```

   `PHP_INI_SCAN_DIR` is honoured by PHP on Windows and Linux, so the FastCGI process can be started
   with `PHP_INI_SCAN_DIR=<install>\Web\Php\conf.d` (`FcgidInitialEnv` with mod_fcgid, or the
   equivalent for `mod_proxy_fcgi`) while `PHPRC` keeps pointing at the user's own PHP directory and
   their settings still apply.

5. **Wire the handler to a path, not to a directory.** `IIS7.wxs` hardcodes
   `[PHPLOCATION]php-cgi.exe` in `CreateFastCgi` and `CreatePhpScriptMapping`. Introduce
   `PHP_FCGI_PATH` and use it in both — then the same custom action serves bundled and BYO
   deployments, and an external deployment still gets the handler it needs.

6. **Drop `mod_fcgid` where it can be dropped.** It is a third-party module whose last Apache release
   was 2.3.9 in 2013 (the 2.3.10 in `MODULE_VERSIONS.txt` is Apache Lounge's vendor build), so every
   httpd update means hunting a matching binary. On Linux `php-fpm` + `mod_proxy_fcgi` has no
   functional gap and is the documented choice. On **Windows** it is not that simple: there is no
   `php-fpm.exe`, and `mod_proxy_fcgi` does not spawn its backend, so it needs a managed
   `php-cgi.exe -b 127.0.0.1:9000` FastCGI listener (a service, or a scheduled task) before it can
   replace `mod_fcgid`. Decide per platform; do not assume the Linux answer transfers.

### 2.5 The change list, file by file

**Windows installer**

| File | Change |
|---|---|
| `Installer/build.bat` | add `-webtier=bundled` / `-webtier=external`; guard the `:prepare` unpacks; define `PHP_SERIES`/`PHP_VCVER` instead of one opaque `PHP_VERSION`; pass `MgWebTier` to MSBuild |
| `Installer/Installers/MapGuide/MapGuide.wxs` | accept `MgWebTier`; add `EXTERNAL` to the web-server dialog; set `PHP_FCGI_PATH`; fix `PHP_VERSION` (5.6.40 → real series) or drop the registry component; condition the Apache/PHP config actions on `MGWEB_CONFIG<>"EXTERNAL"` |
| `Installer/Libraries/MapGuide Web Extensions/MapGuideWebExtensions.wxs` | split `group_PHPFILES` into runtime + MapGuide artifacts; `WebExtPhpFeature` → `AllowAbsent="yes"`; condition the `Php`-runtime feature on the bundled mode |
| `Installer/Libraries/MapGuide Web Extensions/HarvestFiles.wxs` | split the `Web\Php` harvest; add the same split for `Web\Apache24` (module + conf vs whole server) |
| `Installer/Libraries/MapGuide Web Extensions/Apache.wxs` | use `[PHP_FCGI_PATH]`; skip service install/start and `httpd.conf` rewriting in external mode |
| `Installer/Libraries/MapGuide Web Extensions/IIS7.wxs` | use `[PHP_FCGI_PATH]`; skip `CreateFastCgi`/`CreatePhpScriptMapping` when the user owns the server |
| `Installer/Custom/apache_actions/apache_actions.cpp` | remove the `cgi.force_redirect` string patch; add a `ValidatePhpInstall` action that parses `php-cgi -i` and aborts on a minor/NTS mismatch |
| `Installer/Support/Web/x64/configs/Php/php.ini` | `expose_php=Off`, `cgi.fix_pathinfo=0`, `session.use_strict_mode=1`, `session.cookie_httponly=1`; add `cgi.force_redirect` explicitly if it is still needed |

**MapGuide build**

| File | Change |
|---|---|
| `MgDev/setenvironment64.bat` | `MAPGUIDE_PHP_DEV_ROOT`, `MAPGUIDE_HTTPD_ROOT`, `PHP_LIBNAME`, `MAPGUIDE_PHP_TS`; fix the stale "php5ts.lib" wording in the sanity-check message |
| `MgDev/Bindings/src/Bindings/Php/PhpApi.vcxproj` | `$(PHP_LIBNAME)`; optional `ZTS` define |
| `MgDev/Bindings/src/Bindings/Php/CMakeLists.txt` | install to `${PHP_EXTENSION_DIR}`; absolute RPATH; no `libphp` link; `INTERNAL_PHP` switch |
| `MgDev/Web/src/ApacheAgent/ApacheAgent.vcxproj` | tolerate the Lounge header layout (flat `include`, `lib`); document the two layouts |
| `MgDev/cmake/modules/FindLinuxApt.cmake` | split into `FindPHP.cmake` + `FindApache.cmake` (via `php-config`/`apxs`), keeping the tarball path as the `INTERNAL_*` fallback |
| `MgDev/cmake/configs/php.ini.in` | only used when `INTERNAL_PHP`; add a new one-line `mapguide-php.ini.in` for the external case |
| `MgDev/cmake/configs/mapguide.conf.in` | drop `AddHandler application/x-httpd-php`; add a commented `proxy:fcgi` example |
| `MgDev/Oem/LinuxApt/CMakeLists.txt` | guard the `php.ini` install with `INTERNAL_PHP` |
| `MgDev/prepare_webtier_components.bat` | accept a pre-populated `Oem/httpd` and document which layout it expects |
| `MgDev/cmake_package.sh` | replace the `httpd` component with `-webextensions` / `-php` / `-apache`; drop `php`, `tomcat`, `apache2` from the bundled tree |
| `MgDev/UPDATING_WEBTIER_COMPONENTS.md` | rewrite around "which PHP series/toolset do we build for", not "which zip do we drop in"; the "download the VS17 build" instruction is already stale — Apache Lounge ships VS18 and expects the module to be rebuilt against it |

### 2.6 Release engineering: the artifact matrix

One extension binary cannot serve every PHP build, so the release has to publish a small matrix, named
by the ABI it targets:

```text
php_MapGuideApi-8.3-nts-vs16-x64.dll     ZEND_MODULE_API_NO 20230831   (bundled today)
php_MapGuideApi-8.3-ts-vs16-x64.dll      for a mod_php/TS deployment
php_MapGuideApi-8.4-nts-vs17-x64.dll     ZEND_MODULE_API_NO 20240924
libphp_MapGuideApi-20230831.so           Ubuntu 24.04 / Debian 12 (PHP 8.3, NTS)
libphp_MapGuideApi-<api>.so              the next distro series
```

Rules:

- Build one extension per **PHP minor × NTS/ZTS × toolset**; treat patch releases as free.
- Stamp the target API into the artifact (file name and `VS_VERSIONINFO`/a `phpinfo()` row) so the
  installer can refuse a mismatch instead of the user seeing a startup warning.
- Keep the **library** versions independent of the PHP matrix: the MapGuide API the extension wraps is
  the same in every row.
- When a new PHP minor appears (8.5 is already out), the matrix gains a row; nothing else changes. That
  is the measure of whether the decoupling worked.
- The "which PHP do we support" policy belongs in `UPDATING_WEBTIER_COMPONENTS.md`, not in a build
  script: today it is implicit in a zip file name.

### 2.7 Suggested phasing

1. **Now — mitigation.** Bump `PHP_VERSION` to the current 8.3.x, regenerate the devel pack, and hot
   swap the runtime. No ABI risk, no code change beyond the version pin. In the same pass, apply the
   `php.ini` hardening from [1.8](#18-problems-in-the-current-bundle-worth-fixing-regardless).
2. **Next — external mode (Model A).** Split the harvest, add `MGWEB_CONFIG=EXTERNAL`, ship
   `BYO-WEBTIER.txt`. This is what makes "use the server you already have" possible without a build
   matrix, and it is small because the install actions already exist and only need conditions.
3. **Then — build against system PHP/httpd (Model B/C).** `FindPHP.cmake`/`FindApache.cmake`,
   `MAPGUIDE_PHP_DEV_ROOT`, `PHP_LIBNAME`, the absolute-path install rules. At that point the Windows
   installer no longer needs to ship PHP and the Ubuntu package no longer needs to vendor it.
4. **Later — product decisions.** Fusion's server-side PHP, `mapadmin` and `schemareport` need an owner.
   Until they have one, any PHP-free deployment loses them; that is acceptable for a mitigation, but it
   is not a product strategy.

---

## Risks and open questions

| Risk | Why it matters | Mitigation |
|---|---|---|
| A PHP minor bump (8.3 → 8.4) silently breaks the extension | API number changes; the loader refuses the module | one build per minor; installer validates `php-cgi -i`; document the matrix |
| Windows PHP builds change toolset (8.3 = VS16, 8.4 = VS17) | mismatched CRT across a DLL boundary | build per toolset; never copy a DLL between configurations |
| Apache Lounge changes module magic, ABI or toolset (it ships VS18 builds now) | `mod_mgmapagent.so` fails to load | build against the target's `include`/`lib` (the zip ships both) and test `httpd -M`; a newer host loads an older-toolset module, not the reverse |
| Disabling PHP becomes permanent by accident | `mapadmin`/Fusion quietly disappear and nobody notices until an incident | record the disable in the machine's change log; the verification in [1.5](#15-verification) is the acceptance test |
| Ubuntu LTS point releases backport PHP patches | the extension keeps working across them | this is the *benefit*; only a minor bump needs a rebuild |
| `mod_fcgid` replacement | one more dependency to patch | move to `mod_proxy_fcgi` |
| Fusion is PHP-only in-tree | it is the most visible casualty | decide: port its server endpoints to MapAgent calls, or make it an optional package |
| `mapadmin` has no in-tree replacement | user/role administration | Maestro, or a MapAgent `ServerAdmin` client |

Open questions that need an owner before Model A ships:

1. Does an `EXTERNAL` install still need an empty `Web\Php\` directory, or should the extension live
   under `Web\www\mapagent\`-style shared location? (Recommendation: keep `Web\Php` as "MapGuide's PHP
   artifacts" — it costs nothing and keeps the current paths valid.)
2. Do we support ZTS at all? Nothing in the tree is built for it today, and the only reason to bother is
   `mod_php` on a distro that builds PHP thread-safe (Debian/Ubuntu's does not, for `mod_php`).
3. Is the PHP viewer still a product feature, or a sample? That answer decides whether an Apache-only,
   PHP-free Windows deployment is supported at all (it has no viewer).
4. Who validates a BYO install end to end? The matrix in [2.6](#26-release-engineering-the-artifact-matrix)
   is only useful if something runs it.

---

## Appendix A — the two ABI contracts, in detail

### PHP

From `php-src` `Zend/zend_modules.h` (8.3):

```c
#define ZEND_MODULE_API_NO 20230831
#define STANDARD_MODULE_HEADER_EX sizeof(zend_module_entry), ZEND_MODULE_API_NO, ZEND_DEBUG, USING_ZTS
#define ZEND_MODULE_BUILD_ID "API" ZEND_TOSTR(ZEND_MODULE_API_NO) ZEND_BUILD_TS ZEND_BUILD_DEBUG ZEND_BUILD_SYSTEM ZEND_BUILD_EXTRA
```

`zend_module_entry` therefore carries the API number, the debug flag and the ZTS flag, and a build-ID
string. `ext/standard/dl.c` refuses the module when `zend_api` differs ("Module compiled with module
API=… PHP compiled with module API=… These options need to match") **and** when `build_id` differs
("Module compiled with build ID=…"). `ZEND_BUILD_SYSTEM`, the part after the debug suffix, is
`"," PHP_COMPILER_ID` — i.e. `,VS16` or `,VS17` — and only on Windows. This is why:

- the **minor** version is the compatibility boundary, not the patch version;
- an NTS extension cannot be loaded by a ZTS PHP (or the reverse);
- a Debug extension cannot be loaded by a Release PHP;
- a Windows extension built by a different toolset generation cannot be loaded, even at the same API
  number. That is stricter than the usual "MSVC 2015+ is binary compatible" rule, and it is the
  extension loader, not the C++ ABI, that enforces it.

The MapGuide extension is compiled with `ZEND_DEBUG=0`, `PHP_WIN32`, `ZEND_WIN32` and links `php8.lib`
(`PhpApi.vcxproj`) — i.e. NTS release. `php.i` has no ZTS/TSRMLS handling, and nothing in the tree
builds a TS variant.

PHP's own support policy (php.net): two years of active support, then two years of critical security
fixes only. 8.3 was released 2023-11-23, left active support on 2025-12-31 and is security-only until
2027-12-31; 8.4 is supported until 2028-12-31.

### Apache

`mod_mgmapagent.so` includes `httpd.h`, `http_config.h`, `ap_config.h`, `util_script.h`, and uses
`apr_pool_t`/`apr_table_t`/`request_rec`. It links the server's import libraries
(`libhttpd.lib`, `libapr-1.lib`, `libaprutil-1.lib`, `ApacheAgent.vcxproj`). The server checks the
module's magic number on load; for 2.4.65 (`Apache24\include\ap_mmn.h` in the bundled zip):

```c
#define MODULE_MAGIC_NUMBER_MAJOR 20120211
#define MODULE_MAGIC_NUMBER_MINOR 141
```

`server/config.c` compares `m->version` (which is `MODULE_MAGIC_NUMBER_MAJOR`) and nothing else, so the
minor is recorded but never enforced. The tree already relies on this: `MgDev/Oem/httpd` is **2.4.52**
headers and import libraries (`MgDev/Oem/httpd/PROVENANCE.txt`), while the installer ships **2.4.65** —
a 13-patch-release gap — and the module loads.

Two caveats: the minor being advisory is a statement about *intent* (the `ap_mmn.h` log records at
least one accidental API break inside 2.4, in `proxy_worker_shared`, which does not affect a module
that only uses `request_rec`/`apr_pool_t`/`apr_table_t`), and on Windows the direction matters. Apache
Lounge currently ships VS18 binaries and states that a VS17/VS16/VS15/VS14 module can be used inside
the VS18 binary; the reverse (an older httpd loading a newer-toolset module) is not covered by that
statement. Build the module against the headers and import libraries of the server it will run under —
which the Lounge zip supplies.

---

## Appendix B — artifacts and names

| Name | Value | Source |
|---|---|---|
| Bundled PHP | 8.3.26, NTS, VS16, x64 | `Installer/build.bat` line 87 |
| Bundled httpd | 2.4.65, Apache Lounge build 250724, VS17 | `Installer/build.bat` lines 84-89 |
| `mod_fcgid` / `mod_jk` | 2.3.10 / 1.2.50 | `Installer/Support/Web/x64/MODULE_VERSIONS.txt` |
| PHP extension (Release) | `php_MapGuideApi.dll`, output to `MgDev/packages/php/Release/x64` | `PhpApi.vcxproj`, `build.bat` |
| PHP extension (Debug) | `php_MapGuideApid.dll` | `PhpApi.vcxproj` |
| Extension install paths | `Web\Php\ext\` (Windows), `webserverextensions/lib64` (Linux `php.ini`) | `build.bat` 357-360, `php.ini.in` 763 |
| Apache module | `mod_mgmapagent.so` (Windows: `Web\Apache24\modules`; Linux: `apache2/modules`) | `build.bat` 245, `ApacheAgent/CMakeLists.txt` |
| Apache service | `ApacheMapGuide4.0` | `Apache.wxs` |
| Install root | `%ProgramFiles%\OSGeo\MapGuide` | `MapGuide.wxs` 851-856 |
| Registry key | `HKLM\SOFTWARE\OSGeo\MapGuide\4.0.0` | `Installer/build.bat` 53 |

---

## Appendix C — upstream references

- PHP supported versions and support policy — <https://www.php.net/supported-versions.php>
- PHP 8.3 EOL dates (2027-12-31) and latest release — <https://endoflife.date/php>
- `ZEND_MODULE_API_NO` and the module entry fields —
  <https://github.com/php/php-src/blob/PHP-8.3/Zend/zend_modules.h>
- Build-ID construction (TS/NTS, debug, Windows compiler ID) —
  <https://github.com/php/php-src/blob/PHP-8.3/Zend/zend_build.h>
- Load-time API/build-ID check — <https://github.com/php/php-src/blob/PHP-8.3/ext/standard/dl.c>
- Which extension binary to download (version, thread safety, architecture, debug) —
  <https://www.php.net/manual/en/install.pecl.php>
- Windows PHP downloads (NTS/VS16 8.3 builds, devel packs) — <https://windows.php.net/download/>
- `mod_php`, prefork and "use FPM for new deployments" — <https://www.php.net/manual/en/install.apache2.php>
- PHP `cgi.force_redirect` (on for Apache, off for IIS) —
  <https://www.php.net/manual/en/ini.core.php#ini.cgi.force-redirect>
- PHP config search order (`PHPRC`) — <https://www.php.net/manual/en/install.ini.php>
- PHP `extension` directive and absolute paths — <https://www.php.net/manual/en/ini.core.php#ini.extension>
- Debian PHP packaging (`debian/rules`: one NTS build for all SAPIs) —
  <https://salsa.debian.org/php-team/php/-/blob/debian/main/8.3/debian/rules>
- Debian PHP layout and `phpenmod` — <https://wiki.debian.org/PHP>
- Apache Lounge httpd builds (VS18, includes `include/` and `lib/`) —
  <https://www.apachelounge.com/download/>
- `ap_mmn.h` module magic numbers and the compatibility log —
  <https://github.com/apache/httpd/blob/2.4.x/include/ap_mmn.h>
- `mod_proxy_fcgi` — <https://httpd.apache.org/docs/2.4/mod/mod_proxy_fcgi.html>
- `mod_fcgid` (last ASF release 2.3.9, 2013) — <https://httpd.apache.org/mod_fcgid/>
- MSVC 2015+ binary compatibility — <https://learn.microsoft.com/en-us/cpp/porting/binary-compat-2015-2017>
- IIS `<fastCgi>` and `<handlers>` configuration —
  <https://learn.microsoft.com/en-us/iis/configuration/system.webserver/fastcgi/> and
  <https://learn.microsoft.com/en-us/iis/configuration/system.webserver/handlers/>
- IIS request filtering `<fileExtensions>` —
  <https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/requestfiltering/fileextensions/>
