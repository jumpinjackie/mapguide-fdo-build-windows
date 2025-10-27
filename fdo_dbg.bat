SET FDOORACLE=C:\Workspace\fdo_rdbms_thirdparty\oracle_x64\instantclient_12_2\sdk
SET FDOMYSQL=C:\Workspace\fdo_rdbms_thirdparty\mysql_x64
SET FDOPOSTGRESQL=C:\Workspace\fdo_rdbms_thirdparty\pgsql
cd /D C:\Workspace\fdo-4.2-dbg
call setenvironment.bat x86_amd64
call build_thirdparty.bat -p=x64 -c=debug -a=buildinstall -a=buildinstall -o=C:\Workspace\fdo-build\dbg64
if not "%errorlevel%"=="0" goto error
call build.bat -p=x64 -c=debug -a=buildinstall -a=buildinstall -o=C:\Workspace\fdo-build\dbg64
if not "%errorlevel%"=="0" goto error
goto done
:error
echo [ERROR]: There was an error building the component
exit /B 1
:done