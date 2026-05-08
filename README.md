# Rombadil.OpenAL.Soft.Native

OpenAL Soft v1.25.1 binaries for win-x64, linux-x64 and osx-arm64

https://github.com/kcat/openal-soft/releases/tag/1.25.1

## Building

The win-x64 and linux-x64 artifacts are produced by
[`scripts/build-win64-linux64.sh`](scripts/build-win64-linux64.sh), intended
to run on a fresh Ubuntu EC2 instance (24.04 or 26.04). It cross-compiles
the Windows DLL with MinGW-w64, builds the Linux `.so` natively, and stages
both under `~/build-artifacts/runtimes/`.

```
bash scripts/build-win64-linux64.sh
```

The osx-arm64 binary is produced by
[`scripts/build-osx-arm64.sh`](scripts/build-osx-arm64.sh), intended to run
on a fresh Apple Silicon Mac (macOS 11+). An AWS `mac2.metal` /
`mac2-m2.metal` EC2 instance works, as does any M-series Mac.

```
bash scripts/build-osx-arm64.sh
```
