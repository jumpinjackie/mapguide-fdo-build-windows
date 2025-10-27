@echo off
SET MG_LINUX_COMMON_LIBS=C:\Workspace\mgcommon\mapguideopensource-common.tar.gz
SET MG_BASE_DIR=C:\Workspace\mg-4.0\MgDev
SET FDO_BUILD_SRC=C:\Workspace\fdo-build\dbg64\Fdo
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
pushd %MG_BASE_DIR%/Bindings
call setup_linux_native_libs.cmd %MG_LINUX_COMMON_LIBS%
popd
pause