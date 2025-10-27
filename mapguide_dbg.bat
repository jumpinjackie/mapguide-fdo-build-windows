SET INSTALL_DIR=C:\Workspace\mg-4.0-install\dbg64
SET MG_INSTALLER_DIR=C:\Workspace\mg-4.0\Installer
SET MG_BASE_DIR=C:\Workspace\mg-4.0\MgDev
SET MG_OUTPUT_DIR=%MG_BASE_DIR%\%TYPEBUILD%
SET MG_OUTPUT_DIR_SERVER=%MG_OUTPUT_DIR%\Server
SET MG_OUTPUT_DIR_WEB=%MG_OUTPUT_DIR%\Web
SET MG_OUTPUT_DIR_CSMAP=%MG_OUTPUT_DIR%\CS-Map
SET MG_OUTPUT_DIR_PDBS=%MG_OUTPUT_DIR%\pdbs
call "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat"
cd /D %MG_BASE_DIR%
call setenvironment64.bat debug
if not "%errorlevel%"=="0" goto error
call build.bat -a=build -w=all -o=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
call build.bat -a=install -w=all -o=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
cd /D %MG_INSTALLER_DIR%
call build.bat -a=prepare -source=%INSTALL_DIR%
if not "%errorlevel%"=="0" goto error
echo [notice]: We do not make installers in debug mode
rem call build.bat -a=generate -source=%INSTALL_DIR%
rem if not "%errorlevel%"=="0" goto error
rem call build.bat -source=%INSTALL_DIR%
rem if not "%errorlevel%"=="0" goto error

goto done

:error
echo [ERROR]: There was an error building the component
exit /B 1

:done