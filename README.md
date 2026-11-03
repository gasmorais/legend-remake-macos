# Legend Remake for macOS

Native macOS launcher for Legend Remake. It stores multiple accounts in the Keychain, runs a local asset cache proxy with prefetch and starts the game engine on the Adobe AIR runtime.

## Stack

- Swift (language mode 5), SwiftUI
- Network framework for the local cache proxy and HTTP server
- Keychain Services for account credentials
- Adobe AIR SDK 51.4 or newer for the game engine runtime
- Python 3 for the engine patch tool
- `swiftc`, `lipo` and `codesign`, with no Xcode project

## Requirements

- macOS 14 or later
- Xcode Command Line Tools
- Python 3
- A copy of the official Legend Remake launcher, for `Engine.swf` and its icons
- AIR SDK 51.4 or newer for macOS

`Engine.swf`, the icons and the AIR runtime are not versioned.

## Build

```bash
LEGEND_DIR=<official launcher folder> AIR_SDK=<AIR SDK folder> ./build.sh
```

`LEGEND_DIR` and `AIR_SDK` are needed only while `Resources/` does not have those files yet. The script builds `arm64` and `x86_64` binaries, merges them into a universal binary, patches the engine, bundles the AIR runtime and signs the app ad hoc. The output is `../Legend Remake.app`. Set `OUT` to use another path.

## Project structure

```
Sources/     SwiftUI app, launcher API, cache proxy, disk cache, downloader and engine session
Resources/   Info.plist and the AIR application descriptor
Tools/       patch_engine.py, patches ActionScript bytecode in Engine.swf at build time
build.sh     Imports dependencies, builds, patches and signs the app
```

## Notice

This is an unofficial project, not affiliated with the Legend Remake publisher. Game code, art and data belong to their respective owners.
