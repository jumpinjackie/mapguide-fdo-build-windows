@echo off
SET INSTALL_DIR=C:\Workspace\mg-4.0-install\rel64
SET MG_INSTALLER_DIR=C:\Workspace\mg-4.0\Installer
SET MG_BASE_DIR=C:\Workspace\mg-4.0\MgDev
SET MG_INSTANTSETUP_DIR=C:\Workspace\MgInstantSetup
SET MG_OUTPUT_DIR=%MG_BASE_DIR%\%TYPEBUILD%
SET MG_OUTPUT_DIR_SERVER=%MG_OUTPUT_DIR%\Server
SET MG_OUTPUT_DIR_WEB=%MG_OUTPUT_DIR%\Web
SET MG_OUTPUT_DIR_CSMAP=%MG_OUTPUT_DIR%\CS-Map
SET MG_OUTPUT_DIR_PDBS=%MG_OUTPUT_DIR%\pdbs
SET MG_VER_MAJOR=4
SET MG_VER_MINOR=0
SET MG_VER_BUILD=0
SET MG_VER_MAJOR_MINOR_BUILD=%MG_VER_MAJOR%.%MG_VER_MINOR%.%MG_VER_BUILD%
SET MG_VER_REV=0

if "%MG_RELEASE_LABEL%"=="" set MG_RELEASE_LABEL=Trunk
if "%BUILD_MAIN%"=="" set BUILD_MAIN=1
if "%BUILD_INSTALLER%"=="" set BUILD_INSTALLER=0
if "%BUILD_INSTANTSETUP%"=="" set BUILD_INSTANTSETUP=0

set /p MG_VER_REV= < "%CD%\mapguide_%MG_VER_MAJOR%%MG_VER_MINOR%_revision.txt"

echo MG_RELEASE_LABEL         = %MG_RELEASE_LABEL%
echo BUILD_MAIN               = %BUILD_MAIN%
echo BUILD_INSTALLER          = %BUILD_INSTALLER%
echo BUILD_INSTANTSETUP       = %BUILD_INSTANTSETUP%
echo MG_VER_MAJOR_MINOR_BUILD = %MG_VER_MAJOR_MINOR_BUILD%
echo MG_VER_REV               = %MG_VER_REV%

call "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
:build_main

cd /D %MG_BASE_DIR%
call setenvironment64.bat release
if not "%errorlevel%"=="0" goto error
call build.bat -a=build -w=all -o=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
call build.bat -a=install -w=all -o=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
cd /D %MG_INSTALLER_DIR%
call build.bat -a=prepare -source=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
if "%BUILD_INSTALLER%"=="1" goto make_installer
if "%BUILD_INSTANTSETUP%"=="1" goto make_instantsetup
goto done
:make_installer
cd /D %MG_INSTALLER_DIR%
call build.bat -a=generate -source=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
call build.bat -source=%INSTALL_DIR% -version=%MG_VER_MAJOR_MINOR_BUILD%.%MG_VER_REV% -name=MapGuideOpenSource-%MG_VER_MAJOR_MINOR_BUILD%.%MG_VER_REV%-%MG_RELEASE_LABEL%-x64 -title="MapGuide Open Source %MG_VER_MAJOR_MINOR_BUILD% %MG_RELEASE_LABEL%"
if not "%errorlevel%"=="0" goto error\
if "%BUILD_INSTANTSETUP%"=="1" goto make_instantsetup
goto done
:make_instantsetup
if not exist %INSTALL_DIR%\Setup mkdir %INSTALL_DIR%\Setup
cd /D %MG_INSTANTSETUP_DIR%
msbuild /p:Configuration=Release;Platform="Any CPU" MgInstantSetup.sln
if not "%errorlevel%"=="0" goto error
pushd %MG_INSTANTSETUP_DIR%\out\release
copy /Y *.exe %INSTALL_DIR%\Setup
copy /Y *.pdb %INSTALL_DIR%\Setup
copy /Y *.dll %INSTALL_DIR%\Setup
copy /Y *.config %INSTALL_DIR%\Setup
popd
:zip_mginstantsetup
cd /D %INSTALL_DIR%
7z a %INSTALL_DIR%\MapGuideOpenSource-%MG_VER_MAJOR_MINOR_BUILD%.%MG_VER_REV%-InstantSetup-x64.exe -mmt -mx5 -sfx7z.sfx CS-Map Server Web Setup Snapshot
7z a %INSTALL_DIR%\mapguideopensource-%MG_VER_MAJOR_MINOR_BUILD%.%MG_VER_REV%-pdbs.7z pdbs/**/*.pdb pdbs/*.pdb
goto done

:error
echo [ERROR]: There was an error building the component
exit /B 1

:done