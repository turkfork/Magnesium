<div align="center">

<img src="assets/magnesium%20banner.png" alt="Magnesium" width="100%">

**A Metal backend for Minecraft on macOS, built as an addon to [Sodium](https://github.com/CaffeineMC/sodium-fabric).**

![Minecraft 1.20.1](https://img.shields.io/badge/Minecraft-1.20.1-62b47a?style=flat-square)
![Sodium 0.5.11](https://img.shields.io/badge/Sodium-0.5.11-46b8a0?style=flat-square)
![Fabric](https://img.shields.io/badge/Loader-Fabric-dbd0b4?style=flat-square)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Metal-8e8e93?style=flat-square&logo=apple&logoColor=white)
![Status](https://img.shields.io/badge/status-experimental-e8a33d?style=flat-square)
![License CC0](https://img.shields.io/badge/license-CC0-lightgrey?style=flat-square)

</div>

---

> [!WARNING]
> Magnesium is an experiment. It works, and it is not faster than Sodium's OpenGL path yet. Expect rough edges, and keep OpenGL as your fallback.

## What it is

macOS only ships a legacy OpenGL 4.1 driver that Apple stopped developing years ago. Magnesium asks whether Minecraft can use Metal instead, without rewriting Sodium.

It doesn't replace Sodium or ship a second renderer. It sits underneath Sodium's existing GL abstractions and translates them to Metal.

```
Minecraft
   ↓
Sodium rendering pipeline        (unchanged)
   ↓
Magnesium translation layer      (replaces Sodium's RenderDevice)
   ↓
Metal  ·  MTLBuffer  MTLTexture  MTLRenderPipelineState  MTLCommandBuffer
   ↓
Apple GPU
```

Sodium sends almost all of its OpenGL through three interfaces, `RenderDevice`, `CommandList` and `DrawCommandList`. Magnesium installs its own implementations of them, mirrors every buffer operation into a real `MTLBuffer`, and draws terrain with real Metal draw calls. The full write-up is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Status

| | |
|---|---|
| ✅ | Sodium's buffers, uploads, copies and mapped writes mirrored to `MTLBuffer`s |
| ✅ | Terrain drawn through Metal, with a port of Sodium's chunk shader to Metal Shading Language |
| ✅ | Solid, cutout and translucent passes, each with its own pipeline and depth state |
| ✅ | Texture atlas (all mip levels) and light map, with animated water, lava and fire |
| ✅ | Smooth fog, texture-coordinate shrink and back-face culling matching vanilla |
| ✅ | Zero-copy hand-off to OpenGL through IOSurface, with a readback fallback |
| ✅ | Solid and cutout work submitted to the GPU early, so the CPU only waits on the translucent pass |
| ✅ | Falls back to OpenGL terrain on repeated Metal failures, and pauses while an Iris shader pack is active |
| ✅ | Settings page inside Sodium's video options, plus a native macOS menu bar |
| 🚧 | Presenting straight through a `CAMetalLayer` (Milestone 3) |
| 🚧 | Faster than OpenGL |

**How a frame works today.** Metal draws the terrain into an IOSurface-backed target, along with a packed 24-bit depth. OpenGL reads those surfaces and composites them into Minecraft's framebuffer, so entities, the sky, the UI and the terrain all sort correctly. The solid and cutout passes are submitted to the GPU as soon as they finish, but the CPU still waits for the translucent pass once per frame, and that wait is why this isn't faster yet. Removing it means presenting through a `CAMetalLayer` and compositing everything else into that frame.

## Requirements

- A Mac with **Apple Silicon**
- **macOS 26+** (see `fabric.mod.json`)
- **Minecraft 1.20.1**, [Fabric Loader](https://fabricmc.net/) and Fabric API
- **[Sodium 0.5.11](https://modrinth.com/mod/sodium)**
- Java 17 or newer to run, JDK 21 to build

## Install

1. Download `magnesium-<version>.jar` from the [Releases](../../releases) page.
2. Put it in your `mods` folder with Sodium 0.5.11 and Fabric API.
3. Launch the game and open **Options → Video Settings → Magnesium**.

## Settings

Everything lives on the **Magnesium** page in Sodium's video settings. Settings are saved to `config/magnesium-options.json`.

| Setting | What it does |
|---|---|
| **Metal terrain rendering** *(experimental)* | Renders terrain through Metal every frame and composites it into the scene |
| **Disable OpenGL terrain draw** *(experimental)* | Skips Sodium's own OpenGL terrain draw, so only Metal draws terrain |
| **Back-face culling** | Culls back faces as vanilla does. Plants and dripstone need it |
| **Offscreen Metal draw** and **Capture delay** | One-shot Metal render with a PNG dump after a delay, for debugging |
| **F3 overlay info** | Shows live Metal buffer counts and sizes |
| **Framerate logging** | Prints FPS and Metal statistics to the log at a chosen interval |
| **macOS menu bar integration** | Renames the app menu to *Minecraft* and adds a *Magnesium* menu |

The *Magnesium* menu in the menu bar can toggle Metal rendering, toggle the OpenGL draw, capture a frame to PNG, show the overlay and open the game and config folders.

### System properties

| Property | Effect |
|---|---|
| `-Dmagnesium.nozerocopy=true` | Skip IOSurface sharing and use the CPU readback path |
| `-Dmagnesium.native.path=/path/libmagnesium.dylib` | Load the native library from a path instead of the copy bundled in the jar |

Set the environment variable `MAGNESIUM_VERBOSE=1` for per-buffer and window-title logging.

## Building

```bash
# Build the mod jar (build/libs/)
./gradlew build

# Run a development client
./gradlew runClient
```

The native library is prebuilt and bundled, so you only need to rebuild it after changing `native/macos/MetalBridge.mm`:

```bash
JH=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
clang++ -std=c++17 -fobjc-arc -dynamiclib -arch arm64 -O2 -mmacosx-version-min=11.0 \
  -I$JH/include -I$JH/include/darwin \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  -framework OpenGL -framework IOSurface \
  native/macos/MetalBridge.mm -o native/macos/libmagnesium.dylib

cp native/macos/libmagnesium.dylib src/client/resources/native/macos/
```

Pushing a tag that starts with `v` (for example `v1.0.0`) makes GitHub Actions build the jar and publish it as a release.

## Project layout

```
native/macos/MetalBridge.mm      Metal device, buffers, MSL shaders, IOSurface, menu bar (JNI)
src/client/java/…/renderer/
  device/                        RenderDevice, CommandList, DrawCommandList, texture sync, GL composite
  options/                       Sodium settings page and persistence
  MetalBridge.java               JNI declarations
src/client/java/…/mixin/         Hooks into Sodium, sprite animation and the light map
ARCHITECTURE.md                  How Sodium's GL seams map to Metal
```

## Baseline performance

Recorded **before** Magnesium takes over rendering, as the number to beat.

| | |
|---|---|
| Machine | Mac mini (2024), Apple M4, 16 GB |
| OS | macOS 27.0 Developer Beta |
| Game | Minecraft 1.20.1 · Sodium 0.5.11 · Fabric API |
| Test | Creative mode, flying continuously, generating new chunks |
| **Result** | **240 FPS** |

Future benchmarks will compare Sodium's OpenGL path with Magnesium's Metal path under the same conditions.

## License

Released under [CC0 1.0](LICENSE). Learn from it, modify it, and use it in your own projects.
