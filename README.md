# Magnesium

Magnesium is an experimental Minecraft rendering project focused on bringing a native Apple Metal rendering backend to Minecraft Java Edition on macOS.

## Setup

For setup instructions, please see the [Fabric Documentation](https://docs.fabricmc.net/develop/getting-started/creating-a-project#setting-up) for the IDE you are using.

## Baseline Performance

The following benchmark was recorded before Magnesium takes over Minecraft's rendering backend.

**System**
- Mac mini (2024)
- Apple M4
- 16 GB RAM
- 256 GB storage
- macOS 27.0 Developer Beta
- Minecraft 1.20.1

**Mods**
- Sodium 0.5.11
- Fabric API

**Test**
- Creative mode
- Flying continuously
- Generating new chunks

**Result**

> **240 FPS**

This serves as the initial performance baseline for Magnesium.

Future benchmarks will compare Sodium's OpenGL rendering path against Magnesium's native Metal renderer under the same conditions.

## License

This project is available under the CC0 license. Feel free to learn from it, modify it, and incorporate it into your own projects.