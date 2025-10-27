# mapguide-fdo-build-windows

Ready-to-go build environment for MapGuide and FDO on Windows

Currently targets:

 * MapGuide Open Source 4.0
 * FDO 4.2

## Requirements

 * Visual Studio 2022 with MSVC 2019 compiler and .net 6+ SDK workloads enabled
 * Java 8 SDK (Must have `JAVA_HOME` environment variable set)
 * 7-zip (The `7z` executable must be globally accessible from the command-line)
 * Perl (The `perl` executable must be globally accessible from the command-line)
 * WiX Toolset
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

## Generating download table

From Linux or WSL2 session on Windows.

```
sha256sum * | awk '{print "||[https://download.osgeo.org/mapguide/releases/4.0.0/Final/" $2 " " $2 "]||" $1 "||"}'
```