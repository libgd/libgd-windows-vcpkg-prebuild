# libgd-windows-vcpkg-prebuild
Prebuilt binaries for all libgd dependencies for Windows:
- [x] x64-windows
- [x] x86-windows
- [x] arm64-windows
- [ ] x64-uwp
- [ ] arm-uwp

## Rebuilding archives

The archives are rebuilt by the `Build Windows vcpkg archives` GitHub Actions
workflow. It can be started manually, and it also runs when the archive config,
build script, or workflow changes on `main`.

Dependency versions are pinned by the vcpkg ref in `vcpkg-archives.json`. To add
or update dependencies, edit that file and push the change. The workflow builds
the configured triplets and commits changed `.7z` archives back to `main`, which
keeps the existing raw GitHub download URLs used by libgd Windows CI working.

`amd64_arm64-windows.7z` intentionally contains a top-level `arm64-windows`
directory, matching the current libgd CI extraction behavior.
