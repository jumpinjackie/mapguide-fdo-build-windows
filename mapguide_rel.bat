@echo off
REM Directory where this script resides (trailing backslash included)
SET SCRIPT_DIR=%~dp0
SET INSTALL_DIR=%SCRIPT_DIR%mg-install\rel64
SET MG_INSTALLER_DIR=%SCRIPT_DIR%Installer
SET MG_BASE_DIR=%SCRIPT_DIR%MgDev
SET MG_INSTANTSETUP_DIR=%SCRIPT_DIR%MgInstantSetup
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

REM ===========================================================================
REM  Release build wrapper.
REM
REM  Run with no arguments for the full release build (previous behaviour).
REM
REM  To (re)build only a subset, pass the standard MgDev build.bat options
REM  through. The most useful is -w (with), which selects the component:
REM
REM      mapguide_rel.bat -w=server      only the server tree, which is what
REM                                      Run-MgTests.ps1 exercises
REM      mapguide_rel.bat -w=web         only the web tier
REM      mapguide_rel.bat -w=allnodoc    everything except the documentation
REM
REM  The installer preparation step is skipped when a component other than
REM  all/allnodoc is selected: it packages a complete installation, so a
REM  partial one is not a valid input for it.
REM
REM  Run "mapguide_rel.bat -h" for the allowed -w values.
REM ===========================================================================
set "MG_COMPONENT=all"
set "COMPONENT_ARGS=-w all"
set "FORWARD_ARGS="

:parse_args
if "%~1"=="" goto args_parsed
if /I "%~1"=="-h"     goto show_help
if /I "%~1"=="-help"  goto show_help
if /I "%~1"=="-?"     goto show_help
if /I "%~1"=="-w"     goto get_component
if /I "%~1"=="-with"  goto get_component
set "FORWARD_ARGS=%FORWARD_ARGS% %~1"
shift
goto parse_args

REM cmd.exe splits an argument on '=', so "-w=server" arrives here as the two
REM parameters "-w" and "server", and both spellings end up on this path.
:get_component
if "%~2"=="" goto missing_component
set "MG_COMPONENT=%~2"
set "COMPONENT_ARGS=-w %~2"
shift
shift
goto parse_args

:args_parsed
set "MG_PREPARE=1"
set "MG_INSTALL=1"
if /I "%MG_COMPONENT%"=="all"      goto component_done
if /I "%MG_COMPONENT%"=="allnodoc" goto component_done
if /I "%MG_COMPONENT%"=="server"   goto component_installable
if /I "%MG_COMPONENT%"=="web"      goto component_installable
if /I "%MG_COMPONENT%"=="doc"      goto component_installable
REM build.bat has no install path for these, so this is a build-only selection.
echo [notice]: -w=%MG_COMPONENT% selected; build only, without the install or installer preparation steps
set "MG_PREPARE="
set "MG_INSTALL="
goto component_done

:component_installable
echo [notice]: -w=%MG_COMPONENT% selected; skipping the installer preparation step
set "MG_PREPARE="
:component_done

set /p MG_VER_REV= < "%CD%\mapguide_%MG_VER_MAJOR%%MG_VER_MINOR%_revision.txt"

echo MG_RELEASE_LABEL         = %MG_RELEASE_LABEL%
echo BUILD_MAIN               = %BUILD_MAIN%
echo BUILD_INSTALLER          = %BUILD_INSTALLER%
echo BUILD_INSTANTSETUP       = %BUILD_INSTANTSETUP%
echo MG_VER_MAJOR_MINOR_BUILD = %MG_VER_MAJOR_MINOR_BUILD%
echo MG_VER_REV               = %MG_VER_REV%

SET VSDEVCMD=
if exist "C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\18\Enterprise\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\18\Professional\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" if exist "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" SET "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
if "%VSDEVCMD%"=="" goto error_no_vsdevcmd
call "%VSDEVCMD%"
:build_main

cd /D %MG_BASE_DIR%
call setenvironment64.bat release
if not "%errorlevel%"=="0" goto error
call build.bat -a=build %COMPONENT_ARGS% -o=%INSTALL_DIR%%FORWARD_ARGS%
if not "%errorlevel%"=="0" goto error
if not defined MG_INSTALL goto done
call build.bat -a=install %COMPONENT_ARGS% -o=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
if not defined MG_PREPARE goto done
cd /D %MG_INSTALLER_DIR%
call build.bat -a=prepare -build=Release64 -source=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
if "%BUILD_INSTALLER%"=="1" goto make_installer
if "%BUILD_INSTANTSETUP%"=="1" goto make_instantsetup
goto done
:make_installer
cd /D %MG_INSTALLER_DIR%
call build.bat -a=generate -build=Release64 -source=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
call build.bat -build=Release64 -source=%INSTALL_DIR% -version=%MG_VER_MAJOR_MINOR_BUILD%.%MG_VER_REV% -name=MapGuideOpenSource-%MG_VER_MAJOR_MINOR_BUILD%.%MG_VER_REV%-%MG_RELEASE_LABEL%-x64 -title="MapGuide Open Source %MG_VER_MAJOR_MINOR_BUILD% %MG_RELEASE_LABEL%"
if not "%errorlevel%"=="0" goto error
if "%BUILD_INSTANTSETUP%"=="1" goto make_instantsetup
goto done
:make_instantsetup
if not exist %INSTALL_DIR%\Setup mkdir %INSTALL_DIR%\Setup
cd /D %MG_INSTANTSETUP_DIR%
msbuild /restore /p:Configuration=Release;Platform="Any CPU" MgInstantSetup.sln
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

:missing_component
echo [ERROR]: -w requires a component name (run this wrapper with -h for the list)
exit /B 1

:show_help
echo.
echo mapguide_rel.bat - Release build wrapper
echo.
echo Usage:
echo     mapguide_rel.bat [options]
echo.
echo With no options the full release build is performed: every component,
echo the server and web installation, and the installer preparation step.
echo.
echo Wrapper specific options:
echo     -h, -help, -?        Show this help and exit.
echo.
echo All other options are forwarded to MgDev\build.bat unchanged. The most
echo useful forwarded option is -w or -with, which selects the component:
echo.
echo     all                  every component (default)
echo     allnodoc             every component except the documentation
echo     server               the server tree - this is what
echo                          Run-MgTests.ps1 exercises
echo     web                  the web tier
echo     doc                  the developer's guide and the Sheboygan samples
echo.
echo Build-only selections, because build.bat has no install path for them:
echo.
echo     oem                  the OEM libraries (CS-Map)
echo     bindings             the .NET and Java bindings
echo     portable             mg-portable
echo.
echo A component other than all/allnodoc skips the installer preparation step,
echo because it packages a complete installation.
echo.
echo Examples:
echo     mapguide_rel.bat -w=server       Rebuild only the server tree
echo     mapguide_rel.bat -w=allnodoc     Full build without the documentation
echo     mapguide_rel.bat                 Full release build
echo.
echo Release and Debug cannot be built at the same time; build the
echo configurations one at a time and re-run mapguide_rel_setup.bat after
echo every FDO build.
echo.
exit /B 0

:error_no_vsdevcmd
echo [ERROR]: Could not find VsDevCmd.bat from Visual Studio 2026 or Visual Studio 2022
exit /B 1

:error
echo [ERROR]: There was an error building the component
exit /B 1

:done