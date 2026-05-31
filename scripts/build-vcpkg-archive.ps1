[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $ArchiveName,

    [string] $ConfigPath = (Join-Path $PSScriptRoot "..\vcpkg-archives.json"),

    [string] $WorkDir = $(if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP "vcpkg-archive-work" } else { Join-Path ([System.IO.Path]::GetTempPath()) "vcpkg-archive-work" }),

    [string] $OutputDir = (Join-Path (Get-Location) "artifacts")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    Write-Host ">> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

function Resolve-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found on PATH."
    }

    return $command.Source
}

$resolvedConfigPath = (Resolve-Path $ConfigPath).Path
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$archive = @($config.archives | Where-Object { $_.archiveName -eq $ArchiveName })

if ($archive.Count -ne 1) {
    $knownArchives = ($config.archives.archiveName -join ", ")
    throw "Archive '$ArchiveName' is not defined in $resolvedConfigPath. Known archives: $knownArchives"
}

$archive = $archive[0]
$packages = @($archive.packages)

if ($packages.Count -eq 0) {
    throw "Archive '$ArchiveName' does not define any packages."
}

$triplet = [string] $archive.triplet
$vcpkgRepository = [string] $config.vcpkgRepository
$vcpkgRef = [string] $config.vcpkgRef

if ([string]::IsNullOrWhiteSpace($triplet)) {
    throw "Archive '$ArchiveName' does not define a triplet."
}

if ([string]::IsNullOrWhiteSpace($vcpkgRepository)) {
    throw "Config '$resolvedConfigPath' does not define vcpkgRepository."
}

if ([string]::IsNullOrWhiteSpace($vcpkgRef)) {
    throw "Config '$resolvedConfigPath' does not define vcpkgRef."
}

$vcpkgRoot = Join-Path $WorkDir "vcpkg"
$installedDir = Join-Path $vcpkgRoot "installed"
$tripletDir = Join-Path $installedDir $triplet
$outputPath = Join-Path $OutputDir $ArchiveName

Write-Host "Archive: $ArchiveName"
Write-Host "Triplet: $triplet"
Write-Host "vcpkg repository: $vcpkgRepository"
Write-Host "vcpkg ref: $vcpkgRef"
Write-Host "Packages: $($packages -join ', ')"
Write-Host "Output: $outputPath"

if ($WhatIfPreference) {
    Write-Host "WhatIf: validated config and command inputs; skipping vcpkg clone, install, and archive creation."
    return
}

$git = Resolve-RequiredCommand "git"
$sevenZip = Resolve-RequiredCommand "7z"

if ($PSCmdlet.ShouldProcess($WorkDir, "recreate vcpkg archive work directory")) {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Push-Location $WorkDir
try {
    Invoke-NativeCommand $git "init" "vcpkg"
    Push-Location $vcpkgRoot
    try {
        Invoke-NativeCommand $git "remote" "add" "origin" $vcpkgRepository
        Invoke-NativeCommand $git "fetch" "--depth" "1" "origin" $vcpkgRef
        Invoke-NativeCommand $git "checkout" "--detach" "FETCH_HEAD"

        Invoke-NativeCommand (Join-Path $vcpkgRoot "bootstrap-vcpkg.bat") "-disableMetrics"

        $vcpkgExe = Join-Path $vcpkgRoot "vcpkg.exe"
        $installArgs = @("install") + $packages + @("--triplet", $triplet, "--clean-after-build")
        Invoke-NativeCommand $vcpkgExe @installArgs
    }
    finally {
        Pop-Location
    }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $tripletDir)) {
    throw "vcpkg completed, but expected package directory was not found: $tripletDir"
}

if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -LiteralPath $outputPath -Force
}

Push-Location $installedDir
try {
    Invoke-NativeCommand $sevenZip "a" "-t7z" "-mx=9" $outputPath $triplet
}
finally {
    Pop-Location
}

Invoke-NativeCommand $sevenZip "t" $outputPath
Write-Host "Created $outputPath"
