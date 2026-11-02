# Builds the Windows 11 context-menu pieces into build\shell\:
#   TransformToShell.dll   (needs the MSVC C++ compiler: Visual Studio / Build Tools with "Desktop development with C++")
#   TransformTo.msix       (sparse package; makeappx + signtool come from the Microsoft.Windows.SDK.BuildTools NuGet)
#   TransformTo.cer        (public certificate the installer trusts)
# TransformTo.csproj embeds whatever is in build\shell\ into TransformTo.exe.
#
#   pwsh windows\ShellExtension\build.ps1 [-Pfx path\to\signing.pfx -Password ...] [-SkipDll]
param(
    [string]$Pfx = $env:SIGNING_PFX_PATH,
    [string]$Password = $env:SIGNING_PASSWORD,
    [switch]$SkipDll
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$out = Join-Path $root 'build\shell'
New-Item -ItemType Directory -Force $out | Out-Null

if (-not $SkipDll) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'MSVC not found. Install Visual Studio Build Tools with the C++ workload, or use -SkipDll.' }
    Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
    Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    $obj = Join-Path $out 'obj'
    New-Item -ItemType Directory -Force $obj | Out-Null
    cl.exe /nologo /std:c++17 /O2 /EHsc /MT /W4 /DUNICODE /D_UNICODE /LD "$PSScriptRoot\TransformToShell.cpp" "/Fo$obj\\" "/Fe$out\TransformToShell.dll" /link /NOLOGO
    if ($LASTEXITCODE) { throw "cl failed ($LASTEXITCODE)" }
    Remove-Item "$out\TransformToShell.lib", "$out\TransformToShell.exp" -ErrorAction SilentlyContinue
}

# makeappx/signtool from NuGet so no Windows SDK install is needed.
$sdkVersion = '10.0.26100.9457'
$tools = Join-Path $root "build\sdk\microsoft.windows.sdk.buildtools\$sdkVersion"
if (-not (Test-Path $tools)) {
    $nupkg = Join-Path $root "build\sdk\buildtools.zip"
    New-Item -ItemType Directory -Force (Split-Path $nupkg) | Out-Null
    Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools/$sdkVersion" -OutFile $nupkg -UseBasicParsing
    Expand-Archive $nupkg $tools -Force
    Remove-Item $nupkg
}
$bin = Get-ChildItem "$tools\bin" -Directory | Sort-Object Name | Select-Object -Last 1
$makeappx = Join-Path $bin.FullName 'x64\makeappx.exe'
$signtool = Join-Path $bin.FullName 'x64\signtool.exe'

$layout = Join-Path $out 'layout'
Remove-Item $layout -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $layout | Out-Null
Copy-Item "$PSScriptRoot\AppxManifest.xml" $layout
Copy-Item "$PSScriptRoot\Assets" $layout -Recurse

$msix = Join-Path $out 'TransformTo.msix'
& $makeappx pack /d $layout /p $msix /nv /o | Out-Null
if ($LASTEXITCODE) { throw "makeappx failed ($LASTEXITCODE)" }
Remove-Item $layout -Recurse -Force

if ($Pfx) {
    & $signtool sign /q /fd SHA256 /f $Pfx /p $Password $msix
    if ($LASTEXITCODE) { throw "signtool failed ($LASTEXITCODE)" }
    Write-Host 'Package signed.'
} else {
    Write-Warning 'No signing certificate given: the package is unsigned and Windows will refuse to install it.'
}
Copy-Item "$PSScriptRoot\TransformTo.cer" $out
Get-ChildItem $out -File | ForEach-Object { Write-Host "  $($_.Name)  $([math]::Round($_.Length / 1KB)) KB" }
