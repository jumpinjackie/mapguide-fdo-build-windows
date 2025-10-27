@echo off
REM Use the directory where this script resides as the base (includes trailing backslash)
set "SCRIPT_DIR=%~dp0"

set "FDOORACLE=%SCRIPT_DIR%fdo_rdbms_thirdparty\oracle_x64\instantclient_12_2\sdk"
set "FDOMYSQL=%SCRIPT_DIR%fdo_rdbms_thirdparty\mysql_x64"
set "FDOPOSTGRESQL=%SCRIPT_DIR%fdo_rdbms_thirdparty\pgsql"

cd /D "%SCRIPT_DIR%fdo-rel"
call setenvironment.bat x86_amd64
call build_thirdparty.bat -p=x64 -c=release -a=buildinstall -a=buildinstall -o="%SCRIPT_DIR%fdo-build\rel64"
if not "%errorlevel%"=="0" goto error
call build.bat -p=x64 -c=release -a=buildinstall -a=buildinstall -o="%SCRIPT_DIR%fdo-build\rel64"
if not "%errorlevel%"=="0" goto error
goto done
:error
echo [ERROR]: There was an error building the component
exit /B 1
:done