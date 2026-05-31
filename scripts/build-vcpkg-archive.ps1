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

        [string[]] $Arguments = @(),

        [int] $Attempts = 3,

        [int] $DelaySeconds = 60
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

function Invoke-DownloadFileWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,

        [Parameter(Mandatory = $true)]
        [string] $OutputPath,

        [int] $Attempts = 3,

        [int] $DelaySeconds = 60
    )

    $curl = Resolve-RequiredCommand "curl.exe"
    $downloadArgs = @("-L", "--fail", "--retry", "3", "--retry-delay", "10", "-o", $OutputPath)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -and $Url -like "https://github.com/*") {
        $downloadArgs += @("-H", "Authorization: Bearer $env:GITHUB_TOKEN")
    }

    $downloadArgs += $Url
    Invoke-NativeCommandWithRetry -FilePath $curl -Arguments $downloadArgs -Attempts $Attempts -DelaySeconds $DelaySeconds
}

function Expand-CustomSourceArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ArchivePath,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force

    [object[]] $sourceDirectories = @(Get-ChildItem -LiteralPath $DestinationPath -Directory)
    if ($sourceDirectories.Length -ne 1) {
        throw "Expected exactly one top-level source directory in '$ArchivePath', found $($sourceDirectories.Length)."
    }

    return $sourceDirectories[0].FullName
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Key,

        [object] $Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Key) {
        return $Object.$Key
    }

    return $Default
}

function Invoke-CustomCMakeBuild {
    param(
        [Parameter(Mandatory = $true)]
        [object] $BuildConfig,

        [Parameter(Mandatory = $true)]
        [string] $Triplet,

        [Parameter(Mandatory = $true)]
        [string] $InstalledDir,

        [Parameter(Mandatory = $true)]
        [string] $TripletDir,

        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [string] $VcpkgExe
    )

    $cmake = Resolve-RequiredCommand "cmake"
    $name = [string] (Get-ConfigValue -Object $BuildConfig -Key "name" -Default "custom-build")
    $sourceUrl = [string] (Get-ConfigValue -Object $BuildConfig -Key "sourceUrl" -Default "")
    $buildType = [string] (Get-ConfigValue -Object $BuildConfig -Key "buildType" -Default "Release")
    [object[]] $cmakeOptions = @(Get-ConfigValue -Object $BuildConfig -Key "cmakeOptions" -Default @())
    [object[]] $requiredFiles = @()
    [object[]] $copyDirectories = @()

    $requiredFilesValue = Get-ConfigValue -Object $BuildConfig -Key "requiredFiles" -Default $null
    if ($null -ne $requiredFilesValue) {
        $requiredFiles = @($requiredFilesValue)
    }

    $copyDirectoriesValue = Get-ConfigValue -Object $BuildConfig -Key "copyDirectories" -Default $null
    if ($null -ne $copyDirectoriesValue) {
        $copyDirectories = @($copyDirectoriesValue)
    }

    if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
        throw "Custom build '$name' does not define sourceUrl."
    }

    if ([string]::IsNullOrWhiteSpace($buildType)) {
        throw "Custom build '$name' defines an empty buildType."
    }

    $customRoot = Join-Path $WorkDir "custom-builds"
    $downloadDir = Join-Path $customRoot "downloads"
    $extractDir = Join-Path $customRoot "$name-src"
    $buildDir = Join-Path $customRoot "$name-build"
    $archiveExtension = [System.IO.Path]::GetExtension(([System.Uri] $sourceUrl).AbsolutePath)
    $sourceArchivePath = Join-Path $downloadDir "$name$archiveExtension"
    $vcpkgRoot = Split-Path -Parent $VcpkgExe
    $vcpkgToolchain = Join-Path $vcpkgRoot "scripts\buildsystems\vcpkg.cmake"

    if (-not (Test-Path -LiteralPath $vcpkgToolchain)) {
        throw "Could not find vcpkg CMake toolchain file: $vcpkgToolchain"
    }

    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    Write-Host "Downloading custom build '$name' from $sourceUrl"
    Invoke-DownloadFileWithRetry -Url $sourceUrl -OutputPath $sourceArchivePath

    Write-Host "Extracting custom build '$name'"
    $sourceDir = Expand-CustomSourceArchive -ArchivePath $sourceArchivePath -DestinationPath $extractDir

    if (Test-Path -LiteralPath $buildDir) {
        Remove-Item -LiteralPath $buildDir -Recurse -Force
    }

    $configureArgs = @(
        "-S", $sourceDir,
        "-B", $buildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$buildType",
        "-DCMAKE_INSTALL_PREFIX=$TripletDir",
        "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=$Triplet",
        "-DVCPKG_INSTALLED_DIR=$InstalledDir"
    )

    foreach ($option in $cmakeOptions) {
        $optionText = [string] $option
        if ([string]::IsNullOrWhiteSpace($optionText)) {
            continue
        }

        if ($optionText.StartsWith("-D")) {
            $configureArgs += $optionText
        }
        else {
            $configureArgs += "-D$optionText"
        }
    }

    Write-Host "Configuring custom build '$name'"
    Invoke-NativeCommand $cmake @configureArgs

    Write-Host "Building custom build '$name'"
    Invoke-NativeCommand $cmake "--build" $buildDir "--config" $buildType

    Write-Host "Installing custom build '$name'"
    Invoke-NativeCommand $cmake "--install" $buildDir "--config" $buildType

    foreach ($requiredFile in $requiredFiles) {
        $requiredPath = Join-Path $TripletDir ([string] $requiredFile)
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Custom build '$name' completed, but required file is missing: $requiredPath"
        }
    }

    foreach ($copyDirectory in $copyDirectories) {
        $sourceRelativePath = [string] (Get-ConfigValue -Object $copyDirectory -Key "source" -Default "")
        $destinationRelativePath = [string] (Get-ConfigValue -Object $copyDirectory -Key "destination" -Default "")

        if ([string]::IsNullOrWhiteSpace($sourceRelativePath) -or [string]::IsNullOrWhiteSpace($destinationRelativePath)) {
            throw "Custom build '$name' has an invalid copyDirectories entry."
        }

        $sourcePath = Join-Path $TripletDir $sourceRelativePath
        $destinationPath = Join-Path $TripletDir $destinationRelativePath

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Custom build '$name' copy source does not exist: $sourcePath"
        }

        if (Test-Path -LiteralPath $destinationPath) {
            Remove-Item -LiteralPath $destinationPath -Recurse -Force
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }
}

$resolvedConfigPath = (Resolve-Path $ConfigPath).Path
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
[object[]] $archives = @(Get-ConfigValue -Object $config -Key "archives" -Default @())
[object[]] $archive = @($archives | Where-Object { (Get-ConfigValue -Object $_ -Key "archiveName" -Default "") -eq $ArchiveName })

if ($archive.Length -ne 1) {
    $knownArchives = (($archives | ForEach-Object { Get-ConfigValue -Object $_ -Key "archiveName" -Default "" }) -join ", ")
    throw "Archive '$ArchiveName' is not defined in $resolvedConfigPath. Known archives: $knownArchives"
}

$archive = $archive[0]
[object[]] $packages = @(Get-ConfigValue -Object $archive -Key "packages" -Default @())
[object[]] $customBuilds = @()

$customBuildsValue = Get-ConfigValue -Object $archive -Key "customBuilds" -Default $null
if ($null -ne $customBuildsValue) {
    $customBuilds = @($customBuildsValue)
}

if ($packages.Length -eq 0) {
    throw "Archive '$ArchiveName' does not define any packages."
}

$triplet = [string] (Get-ConfigValue -Object $archive -Key "triplet" -Default "")
$vcpkgExecutable = [string] (Get-ConfigValue -Object $config -Key "vcpkgExecutable" -Default "C:\vcpkg\vcpkg.exe")

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
Write-Host "Custom builds: $($customBuilds.Length)"
if ($customBuilds.Length -gt 0) {
    Write-Host "Custom build names: $(($customBuilds | ForEach-Object { Get-ConfigValue -Object $_ -Key "name" -Default "custom-build" }) -join ', ')"
}
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
Invoke-NativeCommandWithRetry -FilePath $vcpkgExe -Arguments $installArgs -Attempts 3 -DelaySeconds 60

if (-not (Test-Path -LiteralPath $tripletDir)) {
    throw "vcpkg completed, but expected package directory was not found: $tripletDir"
}

foreach ($customBuild in $customBuilds) {
    Invoke-CustomCMakeBuild -BuildConfig $customBuild -Triplet $triplet -InstalledDir $installedDir -TripletDir $tripletDir -WorkDir $WorkDir -VcpkgExe $vcpkgExe
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
