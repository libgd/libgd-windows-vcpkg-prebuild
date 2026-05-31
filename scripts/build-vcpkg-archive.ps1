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

function Invoke-NativeCommandWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [int] $Attempts = 3,

        [int] $DelaySeconds = 60,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-NativeCommand $FilePath @Arguments
            return
        }
        catch {
            if ($attempt -eq $Attempts) {
                throw
            }

            Write-Warning "Attempt $attempt of $Attempts failed: $($_.Exception.Message)"
            Write-Host "Waiting $DelaySeconds seconds before retrying..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
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
$vcpkgExecutable = if ($config.PSObject.Properties.Name -contains "vcpkgExecutable") { [string] $config.vcpkgExecutable } else { "C:\vcpkg\vcpkg.exe" }

if ([string]::IsNullOrWhiteSpace($triplet)) {
    throw "Archive '$ArchiveName' does not define a triplet."
}

if ([string]::IsNullOrWhiteSpace($vcpkgExecutable)) {
    throw "Config '$resolvedConfigPath' defines an empty vcpkgExecutable."
}

$installedDir = Join-Path $WorkDir "installed"
$tripletDir = Join-Path $installedDir $triplet
$outputPath = Join-Path $OutputDir $ArchiveName

Write-Host "Archive: $ArchiveName"
Write-Host "Triplet: $triplet"
Write-Host "vcpkg executable: $vcpkgExecutable"
Write-Host "Packages: $($packages -join ', ')"
Write-Host "Output: $outputPath"

if ($WhatIfPreference) {
    Write-Host "WhatIf: validated config and command inputs; skipping vcpkg install and archive creation."
    return
}

$vcpkgExe = if (Test-Path -LiteralPath $vcpkgExecutable) { (Resolve-Path $vcpkgExecutable).Path } else { Resolve-RequiredCommand $vcpkgExecutable }
$sevenZip = Resolve-RequiredCommand "7z"

foreach ($cacheDir in @($env:VCPKG_DOWNLOADS, $env:VCPKG_DEFAULT_BINARY_CACHE)) {
    if (-not [string]::IsNullOrWhiteSpace($cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($WorkDir, "recreate vcpkg archive work directory")) {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$installArgs = @("install") + $packages + @("--triplet", $triplet, "--x-install-root=$installedDir", "--clean-after-build")
Write-Host "Running vcpkg install with up to 3 attempts."
Invoke-NativeCommandWithRetry $vcpkgExe -Attempts 3 -DelaySeconds 60 @installArgs

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
