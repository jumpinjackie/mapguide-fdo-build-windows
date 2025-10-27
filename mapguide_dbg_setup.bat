@echo off
rem Root directory where this script resides (includes trailing backslash)
SET "SCRIPT_DIR=%~dp0"
SET MG_VER_MAJOR=4
SET MG_VER_MINOR=0
SET MG_VER_BUILD=0
SET FDO_BUILD_SRC=%SCRIPT_DIR%fdo-build\dbg64\Fdo
SET MG_BASE_DIR=%SCRIPT_DIR%MgDev
SET MG_LINUX_COMMON_LIBS=%SCRIPT_DIR%mgcommon\mapguideopensource-common.tar.gz
SET FDO_BASE_DIR=%MG_BASE_DIR%\Oem\FDO
pushd %FDO_BASE_DIR%
if exist Bin rd /S /Q Bin
if exist Inc rd /S /Q Inc
if exist Lib64 rd /S /Q Lib64
mkdir Bin
xcopy /S /Y /I /Q %FDO_BUILD_SRC%\Inc Inc
xcopy /S /Y /I /Q %FDO_BUILD_SRC%\Lib Lib64
popd
pushd %FDO_BASE_DIR%\Bin
xcopy /S /Y /I /Q %FDO_BUILD_SRC%\Bin Debug64
popd
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