@echo off
rem Root directory where this script resides (includes trailing backslash)
SET "SCRIPT_DIR=%~dp0"
SET MG_VER_MAJOR=4
SET MG_VER_MINOR=0
SET MG_VER_BUILD=0
SET FDO_BUILD_SRC=%SCRIPT_DIR%fdo-build\dbg64\Fdo
SET MG_BASE_DIR=%SCRIPT_DIR%MgDev
SET MG_LINUX_COMMON_LIBS=%SCRIPT_DIR%mgcommon\mapguideopensource-common.tar.gz
SET "FDO_CONFIG=Debug64"
SET "FDO_BASE_DIR=%MG_BASE_DIR%\Oem\FDO"
SET "FDO_BIN_DIR=%FDO_BASE_DIR%\Bin\%FDO_CONFIG%"
SET "FDO_LIB_DIR=%FDO_BASE_DIR%\Lib64\%FDO_CONFIG%"
rem Stage this configuration only: Inc is shared and config-neutral, and the other
rem configuration's Bin and Lib64 subdirectories are left in place so that a single
rem MgDev tree can hold and build both configurations.
if not exist "%FDO_BASE_DIR%\Bin" mkdir "%FDO_BASE_DIR%\Bin"
if not exist "%FDO_BASE_DIR%\Lib64" mkdir "%FDO_BASE_DIR%\Lib64"
if exist "%FDO_BIN_DIR%" rd /S /Q "%FDO_BIN_DIR%"
if exist "%FDO_LIB_DIR%" rd /S /Q "%FDO_LIB_DIR%"
mkdir "%FDO_BIN_DIR%"
mkdir "%FDO_LIB_DIR%"
xcopy /S /Y /I /Q "%FDO_BUILD_SRC%\Inc" "%FDO_BASE_DIR%\Inc"
xcopy /S /Y /I /Q "%FDO_BUILD_SRC%\Lib" "%FDO_LIB_DIR%"
xcopy /S /Y /I /Q "%FDO_BUILD_SRC%\Bin" "%FDO_BIN_DIR%"
svn info "%MG_BASE_DIR%" | perl revnum.pl > "%CD%\mapguide_%MG_VER_MAJOR%%MG_VER_MINOR%_revision.txt"
set /p MG_VER_REV= < "%CD%\mapguide_%MG_VER_MAJOR%%MG_VER_MINOR%_revision.txt"
pushd %MG_BASE_DIR%
cscript updateversion.vbs /major:%MG_VER_MAJOR% /minor:%MG_VER_MINOR% /point:%MG_VER_BUILD% /build:%MG_VER_REV%
call stampassemblies.bat %MG_VER_MAJOR%.%MG_VER_MINOR%.%MG_VER_BUILD%.%MG_VER_REV%
popd
pushd %MG_BASE_DIR%\Bindings
call setup_linux_native_libs.cmd %MG_LINUX_COMMON_LIBS%
popd
pause