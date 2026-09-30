@echo off
REM Use the directory where this script resides as the base (includes trailing backslash)
set "SCRIPT_DIR=%~dp0"

set "FDOORACLE=%SCRIPT_DIR%fdo_rdbms_thirdparty\oracle_x64\instantclient_12_2\sdk"
set "FDOMYSQL=%SCRIPT_DIR%fdo_rdbms_thirdparty\mysql_x64"
set "FDOPOSTGRESQL=%SCRIPT_DIR%fdo_rdbms_thirdparty\pgsql"

REM ===========================================================================
REM  Release build wrapper.
REM
REM  Run with no arguments for the full release build (previous behaviour).
REM
REM  To (re)build only a subset, pass the standard build.bat options through.
REM  The most useful is -w (with), which selects which component(s) to build:
REM
REM      fdo_rel.bat -w=postgresql     only the PostgreSQL (PostGIS) provider
REM                                    and its unit tests
REM      fdo_rel.bat -w=fdo            only the FDO core
REM      fdo_rel.bat -w=mysql          only the MySQL provider
REM
REM  -w may be repeated to select several components, e.g.
REM
REM      fdo_rel.bat -w=postgresql -w=fdo
REM
REM  Run "fdo_rel.bat -h" for the exhaustive list of allowed -w values.
REM
REM  Extra option understood by this wrapper only (NOT forwarded to build.bat):
REM
REM      -ntp | -nothirdparty          skip the third-party build. Those
REM                                    libraries rarely change, so use this for
REM                                    faster incremental rebuilds.
REM
REM  Example - rebuild just the PostgreSQL provider + unit tests:
REM
REM      fdo_rel.bat -ntp -w=postgresql
REM
REM  Any other option is forwarded to fdo-rel\build.bat unchanged (see
REM  "build.bat -h" for the full list).
REM ===========================================================================

set "SKIP_THIRDPARTY="
set "FORWARD_ARGS="

:parse_args
if "%~1"=="" goto args_parsed
if /I "%~1"=="-h"            goto show_help
if /I "%~1"=="-help"         goto show_help
if /I "%~1"=="-?"            goto show_help
if /I "%~1"=="-ntp"          goto mark_skip_thirdparty
if /I "%~1"=="-nothirdparty" goto mark_skip_thirdparty
set "FORWARD_ARGS=%FORWARD_ARGS% %~1"
shift
goto parse_args

:mark_skip_thirdparty
set "SKIP_THIRDPARTY=1"
shift
goto parse_args

:args_parsed
cd /D "%SCRIPT_DIR%fdo-rel"
call setenvironment.bat x86_amd64

if defined SKIP_THIRDPARTY goto build_fdo
call build_thirdparty.bat -p=x64 -c=release -a=buildinstall -a=buildinstall -o="%SCRIPT_DIR%fdo-build\rel64"
if not "%errorlevel%"=="0" goto error

:build_fdo
call build.bat -p=x64 -c=release -a=buildinstall -a=buildinstall -o="%SCRIPT_DIR%fdo-build\rel64"%FORWARD_ARGS%
if not "%errorlevel%"=="0" goto error
goto done

:error
echo [ERROR]: There was an error building the component
exit /B 1

:done
exit /B 0

:show_help
echo.
echo fdo_rel.bat - release build wrapper
echo.
echo Usage:
echo     fdo_rel.bat [options]
echo.
echo With no options the full release build is performed: third-party libraries
echo followed by all FDO components. This is the previous behaviour.
echo.
echo Wrapper specific options:
echo     -h, -help, -?        Show this help and exit.
echo     -ntp, -nothirdparty  Skip the third-party build. The third-party
echo                          libraries rarely change, so use this for faster
echo                          incremental rebuilds.
echo.
echo All other options are forwarded to fdo-rel\build.bat unchanged.
echo.
echo The most useful forwarded option is -w or -with, which selects which
echo component to build. The first -w clears the default selection, each
echo additional -w adds to it. Values are case sensitive and must be lower case.
echo.
echo     fdo           FDO core and utilities
echo     all           the FDO core plus every provider listed below
echo     providers     every provider listed below, but NOT the FDO core
echo.
echo     shp           Shapefile provider
echo     sdf           SDF provider
echo     sqlite        SQLite provider
echo     wfs           WFS provider
echo     wms           WMS provider
echo     gdal          GDAL provider
echo     ogr           OGR provider
echo     odbc          ODBC provider
echo     mysql         MySQL provider
echo     postgresql    PostgreSQL/PostGIS provider and its unit tests
echo     kingoracle    King Oracle provider
echo     sqlspatial    SQL Server Spatial provider
echo     arcsde        ArcSDE provider
echo.
echo Some providers are only built when their prerequisite is available,
echo otherwise the build silently skips them:
echo     mysql, postgresql     need FDOMYSQL / FDOPOSTGRESQL
echo     kingoracle            needs FDOORACLE
echo     arcsde                needs SDEHOME
echo.
echo Examples:
echo     fdo_rel.bat -ntp -w=postgresql      Rebuild just the PostgreSQL provider
echo     fdo_rel.bat -w=postgresql -w=fdo    Rebuild PostgreSQL and the FDO core
echo     fdo_rel.bat -w=providers            Rebuild all providers
echo     fdo_rel.bat -w=all                  Rebuild everything
echo     fdo_rel.bat                         Full release build
echo.
echo For the complete list of forwarded options run: fdo-rel\build.bat -h
echo.
exit /B 0