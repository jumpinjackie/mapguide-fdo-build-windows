<#
.SYNOPSIS
    Establishes a new baseline version for FDO and MapGuide.

.DESCRIPTION
    Bumps the version that the two source trees stamp into their binaries and the
    version the installer registers for the FDO providers.

    FDO has no version script of its own: its version is literal text in the .rc
    files, the StampVer command lines of the .vcxproj/.vcproj files, the provider
    info headers, the managed override assemblies, the providers.xml registries,
    the /usr/local/fdo-4.2.0 install prefix in the build scripts and the CMake
    variables, so this script stamps both FDO working copies (fdo-dbg and
    fdo-rel).

    The list of files that carry the version is captured from the commits that
    bumped FDO's baseline (r7529, "Ticket #926: Update FDO Trunk version to 4.2")
    and checked against the current trees, and it is kept in this script rather
    than discovered at run time: the trees hold ~27,000 versioned text files, and
    searching them on every run is what makes a bump slow. A file in the list
    that no longer exists is skipped, so both trees stay usable even if they have
    drifted. -Scan re-runs the search over the working copies to report any
    carrier the list has missed; it takes a couple of minutes per tree, and it
    reads the working copy only - no repository access is involved either way.

    MapGuide does have a version script: MgDev\updateversion.vbs and
    MgDev\stampassemblies.bat stamp the product version and the managed
    assemblies. This script only sets the MG_VER_MAJOR/MINOR/BUILD constants that
    mapguide_<cfg>_setup.bat feeds them, then runs that setup script, so the
    stamping stays in the tree's own hands. The setup script's fourth component
    is the SVN revision, which is why -MapGuideVersion takes a trailing 0.

    Nothing is rebuilt. Run fdo_rel.bat / fdo_dbg.bat afterwards to produce the
    binaries that carry the new version, then mapguide_rel_setup.bat (again, to
    restage the rebuilt FDO) and mapguide_rel.bat.

.PARAMETER MapGuideVersion
    The new MapGuide base version, as major.minor.point.0, e.g. 4.0.1.0. The
    fourth component has to be 0: mapguide_<cfg>_setup.bat replaces it with the
    SVN revision, so the binaries are stamped 4.0.1.<revision>.

.PARAMETER FdoVersion
    The new FDO version, e.g. 4.2.1.0. Provider names are major.minor only
    (OSGeo.SDF.4.2), so this changes the version and feature-data-objects
    version fields without renaming a provider.

.PARAMETER Configuration
    Which MapGuide setup script to run after the constants are set: Release
    (mapguide_rel_setup.bat, the default), Debug, or Both. The MapGuide tree is
    stamped once per run, so Both runs both setup scripts.

.PARAMETER SkipMapGuideSetup
    Only rewrite the version constants and literals; do not run the MapGuide
    setup script. The MapGuide binaries then keep the version they carry now.

.PARAMETER Scan
    Also search the FDO working copies for any file that still mentions the old
    version but is not in the known carrier list, and report it. This is the
    safety net for the list being out of date; it reads every text file in the
    trees, which takes a couple of minutes per tree, so it is off by default.

.EXAMPLE
    .\Bump-Version.ps1 -MapGuideVersion 4.0.1.0 -FdoVersion 4.2.1.0

.EXAMPLE
    .\Bump-Version.ps1 -MapGuideVersion 4.0.1.0 -FdoVersion 4.2.1.0 -WhatIf

    Show what would change without changing it.

.EXAMPLE
    .\Bump-Version.ps1 -MapGuideVersion 4.0.1.0 -FdoVersion 4.2.1.0 -Scan

    Bump, then check that no file outside the known list still carries the old
    version.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$MapGuideVersion,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$FdoVersion,

    [ValidateSet('Release', 'Debug', 'Both')]
    [string]$Configuration = 'Release',

    [switch]$SkipMapGuideSetup,

    [switch]$Scan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$FdoTrees = @('fdo-dbg', 'fdo-rel')
$MapGuideWrappers = @(
    'mapguide_dbg_setup.bat',
    'mapguide_rel_setup.bat',
    'mapguide_dbg.bat',
    'mapguide_rel.bat'
)
$InstallerWxs = Join-Path $RepoRoot 'Installer\Installers\MapGuide\MapGuide.wxs'

# Binary content, skipped by -Scan.
$FdoBinaryPattern = '\.(png|jpe?g|gif|ico|bmp|dll|exe|so|dylib|lib|a|o|obj|zip|gz|bz2|xz|7z|tar|cab|msi|nupkg|jar|class|pdb|PDB|cat|jgw|prj|dbf|shp|shx|cpg|tif|tiff|dt1|dt2|aux|ecw|mdb|bin|chm|pdf|woff2?|ttf|eot|svg)$'

# The files that carry the FDO version, relative to the root of each FDO working copy.
#
# Captured from the commit that bumped FDO's baseline to 4.2 (r7529, "Ticket #926: Update FDO
# Trunk version to 4.2"), which is the authority on what a baseline bump covers, then extended
# with the carriers that were added after it (the CMake build scripts, the odbc provider comment,
# the message resources) and trimmed to the files that exist in both working copies today.
#
# Deliberately absent: Thirdparty/gdal's NEWS, its gifdataset.cpp and its GeoPackage notes, whose
# "4.2.0" is giflib's and spatialite's version, and Thirdparty/openssl's IA-64 assembler, where
# "4,2,0,0" is an ar.pfs register allocation. -Scan skips Thirdparty for that reason: it reads every
# other text file, requires the version to stand on its own (so 4.2.15 and 4.2.1.2 do not count), and
# reports the files that mention the old version but are not in this list. Run it after adding to the
# list; a bump does not call it.
$FdoVersionPaths = @(
    'build_linux.sh',
    'build_thirdparty.sh',
    'cmake_bootstrap.sh',
    'cmake_package.sh',
    'createtarzipbinfiles.bat',
    'createtarzipbinfiles2.bat',
    'createtarzipfiles.bat',
    'createtarzipfiles.sh',
    'Fdo\Managed\Project\MgCommon.vcproj',
    'Fdo\Managed\Project\MgCommon.vcxproj',
    'Fdo\Managed\Project\MgFDO.vcproj',
    'Fdo\Managed\Project\MgFDO.vcxproj',
    'Fdo\Managed\Project\MgGeometry.vcproj',
    'Fdo\Managed\Project\MgGeometry.vcxproj',
    'Fdo\Managed\Project\MgSpatial.vcproj',
    'Fdo\Managed\Project\MgSpatial.vcxproj',
    'Fdo\Managed\Src\OSGeo\Common\AssemblyVersion.cpp',
    'Fdo\Managed\Src\OSGeo\Common\MgCommon.rc',
    'Fdo\Managed\Src\OSGeo\FDO\AssemblyVersion.cpp',
    'Fdo\Managed\Src\OSGeo\FDO\mgFDO.rc',
    'Fdo\Managed\Src\OSGeo\Geometry\AssemblyVersion.cpp',
    'Fdo\Managed\Src\OSGeo\Geometry\MgGeometry.rc',
    'Fdo\Managed\Src\OSGeo\Spatial\AssemblyVersion.cpp',
    'Fdo\Managed\Src\OSGeo\Spatial\MgSpatial.rc',
    'Fdo\Python\build_linux.sh',
    'Fdo\Python\FdoWrapper.vcproj',
    'Fdo\Python\Makefile',
    'Fdo\Python\Resource\FdoWrapper.rc',
    'Fdo\Python\UnitTest\providers.xml',
    'Fdo\Python\UnitTest\Src\ClientServicesTest.py',
    'Fdo\Python\UnitTest\UnitTests.sh',
    'Fdo\UnitTest\ClientServicesTest.h',
    'Fdo\Unmanaged\Common.vcproj',
    'Fdo\Unmanaged\Common.vcxproj',
    'Fdo\Unmanaged\Fdo.vcproj',
    'Fdo\Unmanaged\Fdo.vcxproj',
    'Fdo\Unmanaged\Geometry.vcproj',
    'Fdo\Unmanaged\Geometry.vcxproj',
    'Fdo\Unmanaged\Message.vcproj',
    'Fdo\Unmanaged\Message.vcxproj',
    'Fdo\Unmanaged\Spatial.vcproj',
    'Fdo\Unmanaged\Spatial.vcxproj',
    'Fdo\Unmanaged\Src\Common\Common.rc',
    'Fdo\Unmanaged\Src\Fdo\ClientServices\RegistryUtility.cpp',
    'Fdo\Unmanaged\Src\Fdo\Fdo.rc',
    'Fdo\Unmanaged\Src\Geometry\Geometry.rc',
    'Fdo\Unmanaged\Src\Message\MessageStatic.rc',
    'Fdo\Unmanaged\Src\Spatial\Spatial.rc',
    'install\buildall.sh',
    'install\buildfdocore.sh',
    'install\buildfdoprovider.sh',
    'install\dpkgfdocore.sh',
    'install\dpkgfdoprovider.sh',
    'OpenSourceBuild__README.txt',
    'providers.cmake.linux.xml',
    'providers.windows.template.xml',
    'providers.xml',
    'Providers\ArcSDE\build_linux.sh',
    'Providers\ArcSDE\configure',
    'Providers\ArcSDE\configure.in',
    'Providers\ArcSDE\Src\Message\ArcSDEMessage.vcproj',
    'Providers\ArcSDE\Src\Message\ArcSDEMessage.vcxproj',
    'Providers\ArcSDE\Src\Message\ArcSDEMessageStatic.rc',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider.h',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider.rc',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider.vcproj',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider.vcxproj',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider91.rc',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider91.vcproj',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider91.vcxproj',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider92.rc',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider92.vcproj',
    'Providers\ArcSDE\Src\Provider\ArcSDEProvider92.vcxproj',
    'Providers\GDAL\build_linux.sh',
    'Providers\GDAL\config.status',
    'Providers\GDAL\configure',
    'Providers\GDAL\configure.in',
    'Providers\GDAL\Src\FdoRfpGlobals.h',
    'Providers\GDAL\Src\Message\RFPMessage.vcproj',
    'Providers\GDAL\Src\Message\RFPMessage.vcxproj',
    'Providers\GDAL\Src\Overrides\RFPOverrides.rc',
    'Providers\GDAL\Src\Overrides\RFPOverrides.vcproj',
    'Providers\GDAL\Src\Overrides\RFPOverrides.vcxproj',
    'Providers\GDAL\Src\Provider\RFP.vcproj',
    'Providers\GDAL\Src\Provider\RFP.vcxproj',
    'Providers\GDAL\Src\Provider\RFPProvider.rc',
    'Providers\GDAL\Src\UnitTest\providers.xml',
    'Providers\GenericRdbms\build_linux.sh',
    'Providers\GenericRdbms\configure',
    'Providers\GenericRdbms\configure.in',
    'Providers\GenericRdbms\Managed\Project\MgMySqlOverrides.vcproj',
    'Providers\GenericRdbms\Managed\Project\MgMySqlOverrides.vcxproj',
    'Providers\GenericRdbms\Managed\Project\MgOdbcOverrides.vcproj',
    'Providers\GenericRdbms\Managed\Project\MgOdbcOverrides.vcxproj',
    'Providers\GenericRdbms\Managed\Project\MgRdbms.vcproj',
    'Providers\GenericRdbms\Managed\Project\MgRdbms.vcxproj',
    'Providers\GenericRdbms\Managed\Project\MgRdbmsOverrides.vcproj',
    'Providers\GenericRdbms\Managed\Project\MgRdbmsOverrides.vcxproj',
    'Providers\GenericRdbms\Managed\Project\MgSQLServerSpatialOverrides.vcproj',
    'Providers\GenericRdbms\Managed\Project\MgSQLServerSpatialOverrides.vcxproj',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\AssemblyVersion.cpp',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\MgRdbms.rc',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\AssemblyVersion.cpp',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\MgRdbmsOverrides.rc',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\MySQL\AssemblyVersion.cpp',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\MySQL\MgMySqlOverrides.rc',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\ODBC\AssemblyVersion.cpp',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\ODBC\MgOdbcOverrides.rc',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\SQLServerSpatial\AssemblyVersion.cpp',
    'Providers\GenericRdbms\Managed\Src\OSGeo\FDO\Providers\Rdbms\Override\SQLServerSpatial\MgSqlServerOverrides.rc',
    'Providers\GenericRdbms\Nls\fdordbms.vcproj',
    'Providers\GenericRdbms\Nls\fdordbms.vcxproj',
    'Providers\GenericRdbms\Nls\fdordbmsmsgStatic.rc',
    'Providers\GenericRdbms\Src\MySQL\Fdo\FdoRdbmsMySqlProviderInfo.h',
    'Providers\GenericRdbms\Src\MySQL\MySql.rc',
    'Providers\GenericRdbms\Src\MySQL\MySql.vcproj',
    'Providers\GenericRdbms\Src\MySQL\MySql.vcxproj',
    'Providers\GenericRdbms\Src\MySQL\SchemaMgr\MySqlOverrides.rc',
    'Providers\GenericRdbms\Src\MySQL\SchemaMgr\MySqlOverrides.vcproj',
    'Providers\GenericRdbms\Src\MySQL\SchemaMgr\MySqlOverrides.vcxproj',
    'Providers\GenericRdbms\Src\ODBC\Fdo\FdoRdbmsOdbcProviderInfo.h',
    'Providers\GenericRdbms\Src\ODBC\Odbc.cpp',
    'Providers\GenericRdbms\Src\ODBC\Odbc.rc',
    'Providers\GenericRdbms\Src\ODBC\Odbc.vcproj',
    'Providers\GenericRdbms\Src\ODBC\Odbc.vcxproj',
    'Providers\GenericRdbms\Src\ODBC\SchemaMgr\OdbcOverrides.rc',
    'Providers\GenericRdbms\Src\ODBC\SchemaMgr\OdbcOverrides.vcproj',
    'Providers\GenericRdbms\Src\ODBC\SchemaMgr\OdbcOverrides.vcxproj',
    'Providers\GenericRdbms\Src\PostGis\Fdo\FdoRdbmsPostGisProviderInfo.h',
    'Providers\GenericRdbms\Src\PostGis\PostGIS.rc',
    'Providers\GenericRdbms\Src\PostGis\PostGIS.vcproj',
    'Providers\GenericRdbms\Src\PostGis\PostGIS.vcxproj',
    'Providers\GenericRdbms\Src\PostGis\SchemaMgr\PostGISOverrides.rc',
    'Providers\GenericRdbms\Src\PostGis\SchemaMgr\PostGISOverrides.vcproj',
    'Providers\GenericRdbms\Src\PostGis\SchemaMgr\PostGISOverrides.vcxproj',
    'Providers\GenericRdbms\Src\SchemaMgr\RdbmsOverrides.rc',
    'Providers\GenericRdbms\Src\SchemaMgr\RdbmsOverrides.vcproj',
    'Providers\GenericRdbms\Src\SchemaMgr\RdbmsOverrides.vcxproj',
    'Providers\GenericRdbms\Src\SQLServerSpatial\Fdo\FdoRdbmsSqlServerProviderInfo.h',
    'Providers\GenericRdbms\Src\SQLServerSpatial\SchemaMgr\SQLServerSpatialOverrides.rc',
    'Providers\GenericRdbms\Src\SQLServerSpatial\SchemaMgr\SQLServerSpatialOverrides.vcproj',
    'Providers\GenericRdbms\Src\SQLServerSpatial\SchemaMgr\SQLServerSpatialOverrides.vcxproj',
    'Providers\GenericRdbms\Src\SQLServerSpatial\SQLServerSpatial.rc',
    'Providers\GenericRdbms\Src\SQLServerSpatial\SQLServerSpatial.vcproj',
    'Providers\GenericRdbms\Src\SQLServerSpatial\SQLServerSpatial.vcxproj',
    'Providers\GenericRdbms\Src\UnitTest\providers.xml',
    'Providers\GenericRdbms\Src\UnitTest\schemaGenConfig1c_master.txt',
    'Providers\KingOracle\build_linux.sh',
    'Providers\KingOracle\config.status',
    'Providers\KingOracle\configure.in',
    'Providers\KingOracle\src\KgOraUnitTest\providers.xml',
    'Providers\KingOracle\src\Provider\KgOraProvider.h',
    'Providers\OGR\build_linux.sh',
    'Providers\OGR\compile.sh',
    'Providers\OGR\configure',
    'Providers\OGR\configure.in',
    'Providers\OGR\Src\Provider\OgrProvider.h',
    'Providers\OGR\Src\Provider\OGRProvider.rc',
    'Providers\OGR\Src\Provider\OGRProvider.vcproj',
    'Providers\OGR\Src\Provider\OGRProvider.vcxproj',
    'Providers\OGR\Src\UnitTest\providers.xml',
    'Providers\SDF\build_linux.sh',
    'Providers\SDF\configure',
    'Providers\SDF\configure.in',
    'Providers\SDF\Src\Message\SDFMessage.vcproj',
    'Providers\SDF\Src\Message\SDFMessage.vcxproj',
    'Providers\SDF\Src\Message\SDFMessageStatic.rc',
    'Providers\SDF\Src\Provider\SDF.rc',
    'Providers\SDF\Src\Provider\SDF.vcproj',
    'Providers\SDF\Src\Provider\SDF.vcxproj',
    'Providers\SDF\Src\Provider\SDFProvider.h',
    'Providers\SDF\Src\UnitTest\providers.xml',
    'Providers\SHP\build_linux.sh',
    'Providers\SHP\configure',
    'Providers\SHP\configure.in',
    'Providers\SHP\Managed\Project\MgShapeOverrides.vcproj',
    'Providers\SHP\Managed\Project\MgShapeOverrides.vcxproj',
    'Providers\SHP\Managed\Src\OSGeo\FDO\Providers\SHP\Override\AssemblyVersion.cpp',
    'Providers\SHP\Managed\Src\OSGeo\FDO\Providers\SHP\Override\MgShapeOverrides.rc',
    'Providers\SHP\Src\Message\ShpMessage.vcproj',
    'Providers\SHP\Src\Message\ShpMessage.vcxproj',
    'Providers\SHP\Src\Message\ShpMessageStatic.rc',
    'Providers\SHP\Src\Overrides\FdoShpOverrides.rc',
    'Providers\SHP\Src\Overrides\ShpOverrides.vcproj',
    'Providers\SHP\Src\Overrides\ShpOverrides.vcxproj',
    'Providers\SHP\Src\Provider\ShpProvider.h',
    'Providers\SHP\Src\Provider\ShpProvider.rc',
    'Providers\SHP\Src\Provider\ShpProvider.vcproj',
    'Providers\SHP\Src\Provider\ShpProvider.vcxproj',
    'Providers\SHP\Src\UnitTest\providers.xml',
    'Providers\SHP\Src\UnitTest\runTests.sh',
    'Providers\SQLite\build_linux.sh',
    'Providers\SQLite\configure',
    'Providers\SQLite\configure.in',
    'Providers\SQLite\Src\Provider\SQLiteProvider.h',
    'Providers\SQLite\Src\Provider\SQLiteProvider.rc',
    'Providers\SQLite\Src\Provider\SQLiteProvider.vcproj',
    'Providers\SQLite\Src\Provider\SQLiteProvider.vcxproj',
    'Providers\SQLite\Src\UnitTest\providers.xml',
    'Providers\WFS\build_linux.sh',
    'Providers\WFS\configure',
    'Providers\WFS\configure.in',
    'Providers\WFS\Src\Message\WFSMessage.vcproj',
    'Providers\WFS\Src\Message\WFSMessage.vcxproj',
    'Providers\WFS\Src\Message\WFSMessageStatic.rc',
    'Providers\WFS\Src\Provider\FdoWfsProvider.h',
    'Providers\WFS\Src\Provider\FdoWfsProvider.rc',
    'Providers\WFS\Src\Provider\WFSProvider.vcproj',
    'Providers\WFS\Src\Provider\WFSProvider.vcxproj',
    'Providers\WFS\Src\UnitTest\providers.xml',
    'Providers\WMS\build_linux.sh',
    'Providers\WMS\configure',
    'Providers\WMS\configure.in',
    'Providers\WMS\Managed\Project\MgWmsOverrides.vcproj',
    'Providers\WMS\Managed\Project\MgWmsOverrides.vcxproj',
    'Providers\WMS\Managed\Src\OSGeo\FDO\Providers\WMS\Override\AssemblyVersion.cpp',
    'Providers\WMS\Managed\Src\OSGeo\FDO\Providers\WMS\Override\MgWmsOverrides.rc',
    'Providers\WMS\Src\Message\FdoWmsMessageStatic.rc',
    'Providers\WMS\Src\Message\WMSMessage.vcproj',
    'Providers\WMS\Src\Message\WMSMessage.vcxproj',
    'Providers\WMS\Src\Overrides\FdoWmsOverrides.rc',
    'Providers\WMS\Src\Overrides\WMSOverrides.vcproj',
    'Providers\WMS\Src\Overrides\WMSOverrides.vcxproj',
    'Providers\WMS\Src\Provider\FdoWmsGlobals.h',
    'Providers\WMS\Src\Provider\FdoWmsProvider.rc',
    'Providers\WMS\Src\Provider\WMSProvider.vcproj',
    'Providers\WMS\Src\Provider\WMSProvider.vcxproj',
    'Providers\WMS\Src\UnitTest\providers.xml',
    'run_tests.sh',
    'runtestbuild.bat',
    'runtestbuild.sh',
    'setenvironment.sh',
    'Thirdparty\Sqlite3.3.13\configure',
    'Thirdparty\Sqlite3.3.13\configure.in',
    'Thirdparty\util\stampver\readme.txt',
    'Utilities\Common\FDOProviderTemplate\Setup Files\Wizard\Templates\1033\MessageStatic.rc',
    'Utilities\Common\FDOProviderTemplate\Setup Files\Wizard\Templates\1033\Provider.h',
    'Utilities\Common\FDOProviderTemplate\Setup Files\Wizard\Templates\1033\Provider.rc',
    'Utilities\Common\FDOProviderTemplate\Setup Files\Wizard\Templates\1033\providers.xml',
    'Utilities\Common\Managed\Src\OSGeo\FDO\Providers\Common\app.rc',
    'Utilities\Common\Managed\Src\OSGeo\FDO\Providers\Common\AssemblyInfo.cpp',
    'Utilities\ExpressionEngine\ExpressionEngine.vcproj',
    'Utilities\ExpressionEngine\ExpressionEngine.vcxproj',
    'Utilities\ExpressionEngine\Src\ExpressionEngine.rc',
    'Utilities\ODBCDriver\Src\Driver\ODBCDriver.vcproj',
    'Utilities\ODBCDriver\Src\Setup\ODBCSetup.vcproj',
    'Utilities\OWS\FdoOws.rc',
    'Utilities\OWS\OWS.vcproj',
    'Utilities\OWS\OWS.vcxproj',
    'Utilities\SchemaMgr\Nls\SmMessageStatic.rc',
    'Utilities\SchemaMgr\SmMessage.vcproj',
    'Utilities\SchemaMgr\SmMessage.vcxproj'
)

function ConvertTo-FdoLiterals {
    param([string]$Version)
    $p = $Version.Split('.')
    [pscustomobject]@{
        Version = $Version
        Comma   = ($p -join ',')
        Dotted  = ($p -join '.')
        Short   = ($p[0..2] -join '.')
        Padded  = ($p[0..2] -join '.') + '.' + $p[3].PadLeft(4, '0')
    }
}

function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [pscustomobject]@{ Text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3); Encoding = (New-Object System.Text.UTF8Encoding($true)) }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [pscustomobject]@{ Text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2); Encoding = (New-Object System.Text.UnicodeEncoding($false, $true)) }
    }
    return [pscustomobject]@{ Text = [System.Text.Encoding]::UTF8.GetString($bytes); Encoding = (New-Object System.Text.UTF8Encoding($false)) }
}

function Save-TextFile {
    param([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding)
    [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ("--- $Title " + ('-' * [Math]::Max(3, 78 - $Title.Length))) -ForegroundColor Yellow
}

function Write-Field {
    param([string]$Name, [string]$Value, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host ('  {0,-28}: {1}' -f $Name, $Value) -ForegroundColor $Color
}

function Write-Note {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::DarkGray)
    Write-Host "  $Text" -ForegroundColor $Color
}

function Format-Elapsed {
    param([TimeSpan]$Elapsed)
    if ($Elapsed.TotalMinutes -ge 1) {
        return ('{0}m {1:N0}s' -f [Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds)
    }
    return ('{0:N1}s' -f $Elapsed.TotalSeconds)
}

function Update-FdoTree {
    param(
        [string]$Tree,
        [pscustomobject]$Current,
        [pscustomobject]$Target
    )

    $root = Join-Path $RepoRoot $Tree
    $changed = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $fromList = 0
    $watch = [Diagnostics.Stopwatch]::StartNew()

    Write-Note ("Checking the {0:N0} known carrier files ..." -f $FdoVersionPaths.Count)
    $apply = $PSCmdlet.ShouldProcess("$Tree ($($FdoVersionPaths.Count) known carrier file(s))", "bump FDO $($Current.Dotted) to $($Target.Dotted)")

    foreach ($rel in $FdoVersionPaths) {
        $path = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$missing.Add($rel)
            continue
        }

        $file = Read-TextFile -Path $path
        $text = $file.Text
        $text = $text.Replace($Current.Comma, $Target.Comma)
        $text = $text.Replace($Current.Padded, $Target.Padded)
        $text = $text.Replace($Current.Dotted, $Target.Dotted)
        $text = $text.Replace($Current.Short, $Target.Short)
        if ($text -eq $file.Text) { continue }

        $extension = [System.IO.Path]::GetExtension($rel)
        if (-not $extension) { $extension = [System.IO.Path]::GetFileName($rel) }
        [void]$changed.Add([pscustomobject]@{ Path = $rel; Type = $extension })
        $fromList++

        Write-Verbose "  rewrote $rel"
        if ($apply) {
            Save-TextFile -Path $path -Text $text -Encoding $file.Encoding
        }
    }

    # The CMake build takes its version from these variables rather than from a literal.
    $cmake = Join-Path $RepoRoot "$Tree\CMakeLists.txt"
    if (Test-Path -LiteralPath $cmake) {
        $file = Read-TextFile -Path $cmake
        $text = [regex]::Replace($file.Text, '(?m)^(\s*set\(FDO_VERSION_RELEASE\s+)\d+(\s*\)\s*)$', "`${1}$($Target.Dotted.Split('.')[2])`${2}")
        if ($text -ne $file.Text) {
            [void]$changed.Add([pscustomobject]@{ Path = 'CMakeLists.txt'; Type = 'CMakeLists.txt' })
            Write-Verbose '  rewrote CMakeLists.txt (FDO_VERSION_RELEASE)'
            if ($apply) {
                Save-TextFile -Path $cmake -Text $text -Encoding $file.Encoding
            }
        }
    }

    [pscustomobject]@{
        Tree     = $Tree
        Known    = $FdoVersionPaths.Count
        Changed  = $changed
        FromList = $fromList
        Missing  = $missing
        Elapsed  = $watch.Elapsed
    }
}

function Find-UnlistedFdoCarriers {
    # The safety net for the captured list: search the working copy for files that still mention the
    # old version but are not in the list. Reads files only, so no repository access is involved.
    # Vendored third-party sources are skipped: the 4.2.x numbers in them (openssl RFC sections, gdal,
    # libcurl) are their own, and the boundary guards keep a number like 4.2.15 out of the results.
    param([string]$Tree, [pscustomobject]$Current)

    $root = Join-Path $RepoRoot $Tree
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Note 'Walking the working copy to look for carriers the list does not know ...'
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.svn\\' -and $_.FullName -notmatch '\\Thirdparty\\' -and $_.FullName -notmatch $FdoBinaryPattern -and $_.Length -lt 2MB })
    Write-Note ("{0:N0} file(s) to search  ({1})" -f $files.Count, (Format-Elapsed $watch.Elapsed))

    $watch.Restart()
    $pattern = '(?<![\d.])' + [regex]::Escape($Current.Dotted) + '(?![\d.])' + '|' +
        '(?<![\d.])' + [regex]::Escape($Current.Comma) + '(?![\d.])' + '|' +
        '(?<![\d.])' + [regex]::Escape($Current.Short) + '(?![\d.])'
    $hits = @(Select-String -LiteralPath $files.FullName -Pattern $pattern -List -ErrorAction SilentlyContinue)
    Write-Note ("{0:N0} file(s) still mention the old version  ({1})" -f $hits.Count, (Format-Elapsed $watch.Elapsed))

    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $FdoVersionPaths) { [void]$known.Add($p) }

    return @($hits | ForEach-Object {
        $rel = $_.Path.Substring($root.Length + 1)
        if (-not $known.Contains($rel)) {
            [pscustomobject]@{ Path = $rel; Sample = $_.Line.Trim() }
        }
    })
}

function Update-MapGuideWrappers {
    param([pscustomobject]$Current, [pscustomobject]$Target)

    $changed = 0
    foreach ($name in $MapGuideWrappers) {
        $path = Join-Path $RepoRoot $name
        $file = Read-TextFile -Path $path
        $text = $file.Text
        $text = [regex]::Replace($text, '(?m)^(SET MG_VER_MAJOR=)\d+(\s*)$', "`${1}$($Target.Major)`${2}")
        $text = [regex]::Replace($text, '(?m)^(SET MG_VER_MINOR=)\d+(\s*)$', "`${1}$($Target.Minor)`${2}")
        $text = [regex]::Replace($text, '(?m)^(SET MG_VER_BUILD=)\d+(\s*)$', "`${1}$($Target.Point)`${2}")
        if ($text -eq $file.Text) { continue }

        Write-Verbose "  rewrote $name"
        if ($PSCmdlet.ShouldProcess($path, "set MapGuide $($Target.Major).$($Target.Minor).$($Target.Point)")) {
            Save-TextFile -Path $path -Text $text -Encoding $file.Encoding
        }
        $changed++
    }
    return $changed
}

function Update-InstallerFdoVersion {
    param([pscustomobject]$Current, [pscustomobject]$Target)

    $file = Read-TextFile -Path $InstallerWxs
    $text = [regex]::Replace($file.Text, '(<Property Id="FDO_VERSION"[^>]*Value=")[^"]*(")', "`${1}$($Target.Dotted)`${2}")
    if ($text -eq $file.Text) { return $false }

    if ($PSCmdlet.ShouldProcess($InstallerWxs, "set FDO_VERSION to $($Target.Dotted)")) {
        Save-TextFile -Path $InstallerWxs -Text $text -Encoding $file.Encoding
    }
    return $true
}

function Get-CurrentMapGuideVersion {
    $file = Read-TextFile -Path (Join-Path $RepoRoot 'mapguide_rel.bat')
    $major = [regex]::Match($file.Text, '(?m)^SET MG_VER_MAJOR=(\d+)').Groups[1].Value
    $minor = [regex]::Match($file.Text, '(?m)^SET MG_VER_MINOR=(\d+)').Groups[1].Value
    $point = [regex]::Match($file.Text, '(?m)^SET MG_VER_BUILD=(\d+)').Groups[1].Value
    if (-not ($major -and $minor -and $point)) {
        throw 'Could not read MG_VER_MAJOR/MG_VER_MINOR/MG_VER_BUILD from mapguide_rel.bat'
    }
    [pscustomobject]@{ Major = $major; Minor = $minor; Point = $point; Text = "$major.$minor.$point" }
}

function Get-CurrentFdoVersion {
    param([string]$Tree)
    $registry = Join-Path $RepoRoot "$Tree\providers.xml"
    if (-not (Test-Path -LiteralPath $registry)) { return $null }
    $match = [regex]::Match((Read-TextFile -Path $registry).Text, '<FeatureDataObjectsVersion>([0-9.]+)</FeatureDataObjectsVersion>')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

# ---------------------------------------------------------------------------
# Validate the request against what the trees currently carry.
# ---------------------------------------------------------------------------

$totalWatch = [Diagnostics.Stopwatch]::StartNew()

Write-Section 'Bump-Version'
Write-Field 'Repository' $RepoRoot
Write-Field 'MapGuide requested' $MapGuideVersion
Write-Field 'FDO requested' $FdoVersion
Write-Field 'FDO trees' ($FdoTrees -join ', ')
Write-Field 'FDO carrier files' ("$($FdoVersionPaths.Count) per tree (captured list)")
Write-Field 'MapGuide setup' $(if ($SkipMapGuideSetup) { 'skipped (-SkipMapGuideSetup)' } else { $Configuration })
Write-Field 'Deep scan' $(if ($Scan) { 'yes (-Scan)' } else { 'no (-Scan to verify the list)' })
Write-Field 'Installer' $InstallerWxs
if ($WhatIfPreference) {
    Write-Field 'Mode' 'WhatIf - nothing will be written' ([ConsoleColor]::Cyan)
}

$mapGuideParts = $MapGuideVersion.Split('.')
if ($mapGuideParts[3] -ne '0') {
    throw "-MapGuideVersion $MapGuideVersion must end in .0: mapguide_<cfg>_setup.bat stamps the SVN revision as the fourth component, so the base version is major.minor.point."
}

Write-Section 'Current versions'
$currentMapGuide = Get-CurrentMapGuideVersion
$targetMapGuide = [pscustomobject]@{ Major = $mapGuideParts[0]; Minor = $mapGuideParts[1]; Point = $mapGuideParts[2]; Text = "$($mapGuideParts[0]).$($mapGuideParts[1]).$($mapGuideParts[2])" }
Write-Field 'MapGuide wrappers' $currentMapGuide.Text
foreach ($wrapper in $MapGuideWrappers) {
    Write-Note $wrapper
}

$currentFdoVersions = [ordered]@{}
foreach ($tree in $FdoTrees) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $tree))) {
        Write-Warning "$tree is not present; skipping it."
        continue
    }
    $currentFdoVersions[$tree] = Get-CurrentFdoVersion -Tree $tree
    $found = if ($currentFdoVersions[$tree]) { $currentFdoVersions[$tree] } else { '(not found in providers.xml)' }
    Write-Field "FDO $tree" $found
}

if ($currentFdoVersions.Count -eq 0) { throw 'Neither FDO working copy is present.' }
$distinctFdo = @($currentFdoVersions.Values | Where-Object { $_ } | Select-Object -Unique)
if ($distinctFdo.Count -gt 1) {
    throw "The FDO working copies disagree about the current version: $(($currentFdoVersions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '). Bring them in step first."
}
$currentFdo = if ($distinctFdo.Count -eq 1) { ConvertTo-FdoLiterals -Version $distinctFdo[0] } else { $null }
$targetFdo = ConvertTo-FdoLiterals -Version $FdoVersion

Write-Section 'Plan'
Write-Field 'MapGuide' "$($currentMapGuide.Text) -> $($targetMapGuide.Text)  (binaries are stamped $($targetMapGuide.Text).<revision>)"
Write-Field 'FDO' "$(if ($currentFdo) { $currentFdo.Dotted } else { '(unknown)' }) -> $($targetFdo.Dotted)  (provider names stay $($targetFdo.Version.Split('.')[0]).$($targetFdo.Version.Split('.')[1]))"
Write-Note "FDO rewrites four-component $($targetFdo.Dotted), $($targetFdo.Comma) and $($targetFdo.Padded), plus three-component $($targetFdo.Short), in the captured carrier list."
Write-Note 'Per-file detail is available with -Verbose.'

# ---------------------------------------------------------------------------
# FDO: stamp the captured carrier list in both working copies.
# ---------------------------------------------------------------------------

$fdoResults = @()
if ($currentFdo -and $currentFdo.Dotted -ne $targetFdo.Dotted) {
    foreach ($tree in @($currentFdoVersions.Keys)) {
        Write-Section "FDO: $tree"
        $result = Update-FdoTree -Tree $tree -Current $currentFdo -Target $targetFdo
        $fdoResults += $result

        Write-Field 'Known carrier files' $result.Known
        Write-Field 'Carrier files rewritten' $result.FromList ([ConsoleColor]::Green)
        if ($result.Changed.Count -gt $result.FromList) { Write-Field 'CMakeLists.txt' 'rewritten (FDO_VERSION_RELEASE)' }
        Write-Field 'Listed but absent' $result.Missing.Count
        Write-Field 'Elapsed' (Format-Elapsed $result.Elapsed)

        if ($result.Missing.Count -gt 0) {
            Write-Note 'These entries of the list do not exist in this tree (skipped):'
            $result.Missing | Select-Object -First 10 | ForEach-Object { Write-Note "  $_" }
        }
        if ($result.Changed.Count -gt 0) {
            Write-Note 'By file type:'
            $result.Changed | Group-Object Type | Sort-Object Count -Descending | ForEach-Object {
                Write-Note ('  {0,-16} {1,4}' -f $_.Name, $_.Count)
            }
        }
    }
}
else {
    Write-Section 'FDO'
    Write-Field 'Action' 'already at the requested version; nothing to stamp'
}

if ($Scan) {
    $unlisted = @()
    foreach ($tree in $FdoTrees) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $tree))) { continue }
        Write-Section "Deep scan: $tree"
        $found = @(Find-UnlistedFdoCarriers -Tree $tree -Current $currentFdo)
        Write-Field 'Carriers outside the list' $found.Count $(if ($found.Count -gt 0) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green })
        $unlisted += $found
    }
    if ($unlisted.Count -gt 0) {
        Write-Note 'Confirm each of these is not the FDO version, then add the ones that are to $FdoVersionPaths:'
        $unlisted | Group-Object Path | ForEach-Object {
            Write-Note ("  {0}" -f $_.Name) ([ConsoleColor]::Yellow)
            Write-Note ("    {0}" -f $_.Group[0].Sample)
        }
    }
}

# ---------------------------------------------------------------------------
# Installer and MapGuide constants.
# ---------------------------------------------------------------------------

Write-Section 'Installer and MapGuide version constants'

$installerText = Read-TextFile -Path $InstallerWxs
$installerVersion = [regex]::Match($installerText.Text, '<Property Id="FDO_VERSION"[^>]*Value="([^"]*)"').Groups[1].Value
if (Update-InstallerFdoVersion -Current $currentFdo -Target $targetFdo) {
    Write-Field 'Installer FDO_VERSION' "$installerVersion -> $($targetFdo.Dotted)" ([ConsoleColor]::Green)
}
else {
    Write-Field 'Installer FDO_VERSION' "$installerVersion (unchanged)"
}
$small = [regex]::Match($installerText.Text, '<Property Id="FDO_VERSION_SMALL"[^>]*Value="([^"]*)"').Groups[1].Value
Write-Note "FDO_VERSION_SMALL stays $small - it forms the OSGeo.<provider>.$small names FdoRegUtil registers."

if ($currentMapGuide.Text -ne $targetMapGuide.Text) {
    $changed = Update-MapGuideWrappers -Current $currentMapGuide -Target $targetMapGuide
    Write-Field 'MapGuide wrappers' "$($currentMapGuide.Text) -> $($targetMapGuide.Text) in $changed file(s)" ([ConsoleColor]::Green)
    $MapGuideWrappers | ForEach-Object { Write-Note "  $_" }
}
else {
    Write-Field 'MapGuide wrappers' "$($currentMapGuide.Text) (unchanged)"
}

# ---------------------------------------------------------------------------
# MapGuide: let the tree's own scripts do the stamping.
# ---------------------------------------------------------------------------

$setupScripts = switch ($Configuration) {
    'Release' { @('mapguide_rel_setup.bat') }
    'Debug'   { @('mapguide_dbg_setup.bat') }
    'Both'    { @('mapguide_rel_setup.bat', 'mapguide_dbg_setup.bat') }
}

Write-Section 'MapGuide stamping'
if ($SkipMapGuideSetup -or $WhatIfPreference) {
    Write-Field 'Action' 'skipped; run mapguide_<cfg>_setup.bat to stamp the tree'
}
else {
    foreach ($script in $setupScripts) {
        if (-not $PSCmdlet.ShouldProcess($script, 'run MapGuide setup')) { continue }
        Write-Field 'Running' $script
        Write-Note 'Its output follows (updateversion.vbs, stampassemblies.bat and the FDO staging).'
        Write-Host ''
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Push-Location $RepoRoot
        try {
            # The setup scripts end in `pause`; an empty stdin makes that a no-op.
            & $env:ComSpec /c "call `"$script`" < nul"
            $code = $LASTEXITCODE
            if ($code -ne 0) { throw "$script failed with exit code $code" }
        }
        finally {
            Pop-Location
        }
        Write-Host ''
        Write-Field 'Finished' "$script in $(Format-Elapsed $watch.Elapsed) (exit $code)" ([ConsoleColor]::Green)
    }

    $productVersion = Join-Path $RepoRoot 'MgDev\Common\ProductVersion.h'
    if (Test-Path -LiteralPath $productVersion) {
        $stamped = [regex]::Match((Read-TextFile -Path $productVersion).Text, 'const STRING ProductVersion = L"([^"]*)"').Groups[1].Value
        Write-Field 'Stamped ProductVersion' $stamped ([ConsoleColor]::Green)
    }
    $revisionFile = Join-Path $RepoRoot ("mapguide_{0}{1}_revision.txt" -f $targetMapGuide.Major, $targetMapGuide.Minor)
    if (Test-Path -LiteralPath $revisionFile) {
        Write-Field 'Revision file' ("{0} = {1}" -f (Split-Path $revisionFile -Leaf), (Get-Content -LiteralPath $revisionFile | Select-Object -First 1))
    }
}

# ---------------------------------------------------------------------------
# What changed, and what to do next.
# ---------------------------------------------------------------------------

Write-Section 'Summary'
foreach ($result in $fdoResults) {
    Write-Field "FDO $($result.Tree)" ("{0} of {1} carrier file(s) rewritten" -f $result.FromList, $result.Known)
}
Write-Field 'FDO version' $targetFdo.Dotted
Write-Field 'FDO provider names' "$($targetFdo.Version.Split('.')[0]).$($targetFdo.Version.Split('.')[1]) (unchanged)"
Write-Field 'Installer FDO_VERSION' $targetFdo.Dotted
Write-Field 'MapGuide base version' $targetMapGuide.Text
Write-Field 'Total elapsed' (Format-Elapsed $totalWatch.Elapsed)

Write-Host ''
Write-Host '  Nothing has been rebuilt. Next steps:' -ForegroundColor Yellow
Write-Note 'fdo_rel.bat                 rebuild FDO so the binaries carry the new version'
Write-Note 'fdo_dbg.bat                 the same for the Debug tree, if you build Debug'
Write-Note 'mapguide_rel_setup.bat      restage the rebuilt FDO into MgDev\Oem\FDO'
Write-Note 'mapguide_rel.bat            rebuild MapGuide (BUILD_INSTALLER=1 for the MSI)'
