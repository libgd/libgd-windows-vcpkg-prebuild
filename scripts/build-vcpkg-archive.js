const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function run(command, args, options = {}) {
  console.log(`>> ${command} ${args.join(" ")}`);
  const result = spawnSync(command, args, {
    stdio: "inherit",
    shell: false,
    ...options,
  });

  if (result.status !== 0) {
    throw new Error(`Command failed with exit code ${result.status}: ${command}`);
  }
}

function runWithRetry(command, args, attempts = 3, delaySeconds = 60, options = {}) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      run(command, args, options);
      return;
    } catch (error) {
      if (attempt === attempts) {
        throw error;
      }

      console.warn(`Attempt ${attempt} of ${attempts} failed: ${error.message}`);
      console.log(`Waiting ${delaySeconds} seconds before retrying...`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delaySeconds * 1000);
    }
  }
}

function mkdirp(directory) {
  fs.mkdirSync(directory, { recursive: true });
}

function rmrf(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function resolveCommand(command) {
  if (fs.existsSync(command)) {
    return command;
  }
  return command;
}

function download(url, outputPath) {
  const args = ["-L", "--fail", "--retry", "3", "--retry-delay", "10", "-o", outputPath];
  if (process.env.GITHUB_TOKEN && url.startsWith("https://github.com/")) {
    args.push("-H", `Authorization: Bearer ${process.env.GITHUB_TOKEN}`);
  }
  args.push(url);
  runWithRetry("curl.exe", args);
}

function extractSingleDirectory(archivePath, destinationPath) {
  rmrf(destinationPath);
  mkdirp(destinationPath);
  run("7z", ["x", archivePath, `-o${destinationPath}`]);

  const entries = fs.readdirSync(destinationPath, { withFileTypes: true });
  const directories = entries.filter((entry) => entry.isDirectory());
  if (directories.length !== 1) {
    throw new Error(`Expected exactly one top-level source directory in ${archivePath}, found ${directories.length}.`);
  }
  return path.join(destinationPath, directories[0].name);
}

function copyDirectory(sourcePath, destinationPath) {
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Copy source does not exist: ${sourcePath}`);
  }
  rmrf(destinationPath);
  mkdirp(path.dirname(destinationPath));
  fs.cpSync(sourcePath, destinationPath, { recursive: true, force: true });
}

function customBuild(buildConfig, context) {
  const name = buildConfig.name || "custom-build";
  const sourceUrl = buildConfig.sourceUrl;
  const buildType = buildConfig.buildType || "Release";
  const cmakeOptions = buildConfig.cmakeOptions || [];
  const requiredFiles = buildConfig.requiredFiles || [];
  const copyDirectories = buildConfig.copyDirectories || [];

  if (!sourceUrl) {
    throw new Error(`Custom build '${name}' does not define sourceUrl.`);
  }

  const customRoot = path.join(context.workDir, "custom-builds");
  const downloadDir = path.join(customRoot, "downloads");
  const extractDir = path.join(customRoot, `${name}-src`);
  const buildDir = path.join(customRoot, `${name}-build`);
  const sourceArchivePath = path.join(downloadDir, `${name}${path.extname(new URL(sourceUrl).pathname)}`);
  const vcpkgRoot = path.dirname(context.vcpkgExe);
  const vcpkgToolchain = path.join(vcpkgRoot, "scripts", "buildsystems", "vcpkg.cmake");

  if (!fs.existsSync(vcpkgToolchain)) {
    throw new Error(`Could not find vcpkg CMake toolchain file: ${vcpkgToolchain}`);
  }

  mkdirp(downloadDir);
  console.log(`Downloading custom build '${name}' from ${sourceUrl}`);
  download(sourceUrl, sourceArchivePath);

  console.log(`Extracting custom build '${name}'`);
  const sourceDir = extractSingleDirectory(sourceArchivePath, extractDir);
  rmrf(buildDir);

  const configureArgs = [
    "-S", sourceDir,
    "-B", buildDir,
    "-G", "Ninja",
    `-DCMAKE_BUILD_TYPE=${buildType}`,
    `-DCMAKE_INSTALL_PREFIX=${context.tripletDir}`,
    `-DCMAKE_TOOLCHAIN_FILE=${vcpkgToolchain}`,
    `-DVCPKG_TARGET_TRIPLET=${context.triplet}`,
    `-DVCPKG_INSTALLED_DIR=${context.installedDir}`,
  ];

  for (const option of cmakeOptions) {
    const text = String(option || "");
    if (text.length === 0) {
      continue;
    }
    configureArgs.push(text.startsWith("-D") ? text : `-D${text}`);
  }

  console.log(`Configuring custom build '${name}'`);
  run("cmake", configureArgs);
  console.log(`Building custom build '${name}'`);
  run("cmake", ["--build", buildDir, "--config", buildType]);
  console.log(`Installing custom build '${name}'`);
  run("cmake", ["--install", buildDir, "--config", buildType]);

  for (const requiredFile of requiredFiles) {
    const requiredPath = path.join(context.tripletDir, requiredFile);
    if (!fs.existsSync(requiredPath)) {
      throw new Error(`Custom build '${name}' completed, but required file is missing: ${requiredPath}`);
    }
  }

  for (const copy of copyDirectories) {
    copyDirectory(path.join(context.tripletDir, copy.source), path.join(context.tripletDir, copy.destination));
  }
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) {
      continue;
    }
    args[arg.slice(2)] = argv[index + 1];
    index += 1;
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const archiveName = args.archiveName;
if (!archiveName) {
  throw new Error("--archiveName is required.");
}

const repoRoot = path.resolve(__dirname, "..");
const configPath = path.resolve(args.configPath || path.join(repoRoot, "vcpkg-archives.json"));
const workDir = path.resolve(args.workDir || path.join(process.env.RUNNER_TEMP || process.env.TEMP || ".", "vcpkg-archive-work"));
const outputDir = path.resolve(args.outputDir || path.join(process.cwd(), "artifacts"));
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const archive = config.archives.find((item) => item.archiveName === archiveName);

if (!archive) {
  throw new Error(`Archive '${archiveName}' is not defined in ${configPath}.`);
}

const packages = archive.packages || [];
const customBuilds = archive.customBuilds || [];
if (packages.length === 0) {
  throw new Error(`Archive '${archiveName}' does not define any packages.`);
}

const triplet = archive.triplet;
const vcpkgExe = resolveCommand(config.vcpkgExecutable || "C:\\vcpkg\\vcpkg.exe");
const installedDir = path.join(workDir, "installed");
const tripletDir = path.join(installedDir, triplet);
const outputPath = path.join(outputDir, archiveName);

console.log(`Loaded ${config.archives.length} archive definitions from ${configPath}`);
console.log(`Archive: ${archiveName}`);
console.log(`Triplet: ${triplet}`);
console.log(`vcpkg executable: ${vcpkgExe}`);
console.log(`Packages: ${packages.join(", ")}`);
console.log(`Custom builds: ${customBuilds.length}`);
if (customBuilds.length > 0) {
  console.log(`Custom build names: ${customBuilds.map((item) => item.name || "custom-build").join(", ")}`);
}
console.log(`Output: ${outputPath}`);

for (const cacheDir of [process.env.VCPKG_DOWNLOADS, process.env.VCPKG_DEFAULT_BINARY_CACHE]) {
  if (cacheDir) {
    mkdirp(cacheDir);
  }
}

rmrf(workDir);
mkdirp(workDir);
mkdirp(outputDir);

const installArgs = ["install", ...packages, "--triplet", triplet, `--x-install-root=${installedDir}`, "--clean-after-build"];
console.log("Running vcpkg install with up to 3 attempts.");
runWithRetry(vcpkgExe, installArgs);

if (!fs.existsSync(tripletDir)) {
  throw new Error(`vcpkg completed, but expected package directory was not found: ${tripletDir}`);
}

for (const buildConfig of customBuilds) {
  customBuild(buildConfig, { workDir, installedDir, tripletDir, triplet, vcpkgExe });
}

rmrf(outputPath);
run("7z", ["a", "-t7z", "-mx=9", outputPath, triplet], { cwd: installedDir });
run("7z", ["t", outputPath]);
console.log(`Created ${outputPath}`);
