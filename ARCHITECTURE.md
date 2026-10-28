# Magnesium — Sodium → Metal Translation Architecture

Magnesium is a compatibility/translation backend for Sodium 0.5.11 (Minecraft 1.20.1).
It does **not** replace Sodium or implement an independent renderer. It sits underneath
Sodium's existing GL abstractions and translates them to Metal.

```
Minecraft
   ↓
Sodium rendering pipeline   (unchanged)
   ↓
Magnesium compatibility layer   (replaces RenderDevice boundary)
   ↓
Metal resources
   ├── MTLBuffer
   ├── MTLTexture
   ├── MTLRenderPipelineState
   ├── MTLDepthStencilState
   └── MTLCommandBuffer
   ↓
CAMetalLayer
   ↓
Apple GPU
```

## Verified architecture (from Sodium 0.5.11 bytecode)

Sodium funnels almost all OpenGL through three interfaces:

- `me.jellysquid.mods.sodium.client.gl.device.RenderDevice` — singleton `INSTANCE`
  (set to `new GLRenderDevice()` in the interface static initializer).
- `me.jellysquid.mods.sodium.client.gl.device.CommandList` — buffer / VAO / tessellation /
  upload / map / fence operations.
- `me.jellysquid.mods.sodium.client.gl.device.DrawCommandList` — `multiDrawElementsBaseVertex`.

### Primary seam — `CommandList`

| Method | GL call (current only impl) |
|---|---|
| `createMutableBuffer` | `new GlMutableBuffer()` → `glGenBuffers` |
| `createImmutableBuffer` | `new GlImmutableBuffer` → `glBufferStorage` |
| `allocateStorage` | `glBufferData(GL_ARRAY_BUFFER, size, usage)` |
| `uploadData` | `glBufferData(GL_ARRAY_BUFFER, data, usage)` |
| `bindBuffer` | `glBindBuffer` |
| `copyBufferSubData` | `glCopyBufferSubData` |
| `bindVertexArray` | `glBindVertexArray` |
| `unbindVertexArray` | `glBindVertexArray(0)` |
| `createTessellation` | builds a `GlVertexArrayTessellation` |
| `mapBuffer` / `unmap` / `flushMappedRange` | `glMapBufferRange` / `glUnmapBuffer` / `glFlushMappedBufferRange` |
| `createFence` | `glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE)` |
| `deleteBuffer` / `deleteVertexArray` | `glDeleteBuffers` / `glDeleteVertexArrays` |
| `beginTessellating` | binds the VAO, returns `DrawCommandList` |

### Draw path — `DrawCommandList`

- `multiDrawElementsBaseVertex(MultiDrawBatch, GlIndexType)` →
  `GL32C.nglMultiDrawElementsBaseVertex(...)`. This is the only terrain draw call.
- `MultiDrawBatch` holds native arrays: `pElementCount`, `pElementPointer` (always 0),
  `pBaseVertex`. Each sub-draw is one face range; index buffer shared from offset 0;
  per-face range expressed via `pBaseVertex` (vertex units).

### GL spots hardcoded in Sodium's own classes (must be mixed in, not behind the interface)

- `GlBuffer` / `GlVertexArray` constructors call `glGenBuffers()` / `glGenVertexArrays()`
  directly.
- `GlAbstractTessellation.bindAttributes()` emits `glVertexAttrib{IPointer}` +
  `glEnableVertexAttribArray` directly.
- `MultiDrawBatch` allocates native pointer arrays; the draw itself is GL-specific.

### Vertex format — `CompactChunkVertex` (stride 20 bytes)

| Attribute | Offset | Format |
|---|---|---|
| POSITION_MATERIAL_MESH | 0 | 4 × UNSIGNED_SHORT (int) |
| COLOR_SHADE | 8 | 4 × UNSIGNED_BYTE (normalized) |
| BLOCK_TEXTURE | 12 | 2 × UNSIGNED_SHORT |
| LIGHT_TEXTURE | 16 | 2 × UNSIGNED_SHORT (int) |

### Buffer layout

- `GlBufferArena` — one large persistent `GlMutableBuffer` (capacity in vertex units ×
  stride 20) + free segment list; `resize` relocates via `copyBufferSubData`.
- `SharedQuadIndexBuffer` — shared UNSIGNED_INT index buffer reused by every region
  via `baseVertex`.
- `MappedStagingBuffer` — 16 MiB immutable persistent buffer for CPU upload.

### Texture contract (chunk/terrain)

- unit 0 = block/terrain atlas (`u_BlockTex`), unit 1 = light texture (`u_LightTex`).
- Bind happens in `ChunkShaderInterface.setupState()` via `GlStateManager`.

### Render passes (terrain)

| Pass | RenderLayer | notes |
|---|---|---|
| SOLID | getSolid | depth test/write on, blend off |
| CUTOUT | getCutout | fragment discard on |
| TRANSLUCENT | getTranslucent | alpha blend, depth-write off, reverse order |

Sodium never calls glClear / glViewport / glfwSwapBuffers / glDepthFunc / glBlendFunc —
vanilla Minecraft owns the frame + default framebuffer. A Metal backend must own the
CAMetalLayer drawable and reproduce depth/blend/cull state per pass.

## Milestone plan

1. **Milestone 1 (current):** Replace the `RenderDevice` boundary with a
   `MagnesiumRenderDevice` + `MagnesiumCommandList` + `MagnesiumDrawCommandList`.
   Translate the vertex-buffer/arena upload path to real `MTLBuffer`s. Run in a
   *transition mode* (default off) so Sodium's GL path still renders and the game is
   playable — the Metal buffers are created/validated with real chunk data but are not
   yet the on-screen path.

2. **Milestone 2:** Redirect `GlAbstractTessellation.bindAttributes()` and the
   `multiDrawElementsBaseVertex` draw path to a `MTLRenderCommandEncoder` +
   `MTLRenderPipelineState` (MSL translation of `block_layer_opaque`), rendering into a
   Metal render target.

3. **Milestone 3:** Own the CAMetalLayer as the final frame target; reproduce depth /
   blend / cull per `RenderLayer`; mirror `glViewport` + swap.

4. **Milestone 4:** Textures (atlas as `MTLTexture`), fences/pacing, and residency.

## Constraint notes

- Do not fork/rewrite Sodium. Keep Sodium code intact.
- Prefer mixins/hooks at the `RenderDevice`/`CommandList` boundary.
- Preserve the normal OpenGL path while Magnesium is incomplete (transition mode).
- Once a subsystem is migrated, do not call OpenGL for it.
