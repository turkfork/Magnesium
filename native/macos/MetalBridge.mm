#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <jni.h>

static id<MTLDevice> magnesiumDevice = nil;
static id<MTLCommandQueue> magnesiumCommandQueue = nil;

static NSWindow *magnesiumWindow = nil;
static BOOL magnesiumDiscoveryScheduled = NO;

static CAMetalLayer *magnesiumLayer = nil;
static BOOL magnesiumLayerScheduled = NO;

/*
 * Idempotently appends " - Magnesium" to the discovered window's title so it
 * is easy to tell the translated build apart from a stock Sodium run.
 */
static void MagnesiumAppendWindowSuffix(void) {
    if (magnesiumWindow == nil) {
        return;
    }

    NSString *title = magnesiumWindow.title ?: @"";
    NSString *suffix = @" - Magnesium";

    if ([title hasSuffix:suffix]) {
        return;
    }

    magnesiumWindow.title = [title stringByAppendingString:suffix];
    NSLog(@"[Magnesium] Window title updated: '%@'", magnesiumWindow.title);
}

/*
 * Runs on the AppKit main thread. Inspects all application windows and
 * selects the first visible window that has a content view.
 *
 * Does NOT modify the window, content view, or its layer.
 * Does NOT block the caller.
 */
void MagnesiumRunWindowDiscovery(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        NSArray<NSWindow *> *windows = application.windows;

        NSLog(@"[Magnesium] Window discovery: found %lu application windows.",
              (unsigned long)windows.count);

        for (NSWindow *window in windows) {
            NSView *contentView = window.contentView;

            if (contentView == nil) {
                NSLog(@"[Magnesium] Window '%@' has no content view; skipping.",
                      window.title);
                continue;
            }

            NSLog(@"[Magnesium] Window title: '%@'", window.title);
            NSLog(@"[Magnesium] Window visible: %@",
                  (window.isVisible ? @"YES" : @"NO"));
            NSLog(@"[Magnesium] Content view class: %@",
                  NSStringFromClass([contentView class]));

            CALayer *layer = contentView.layer;
            if (layer != nil) {
                NSLog(@"[Magnesium] Content view layer class: %@",
                      NSStringFromClass([layer class]));
            } else {
                NSLog(@"[Magnesium] Content view layer: (none)");
            }

            if (window.isVisible && contentView != nil) {
                magnesiumWindow = window;
                MagnesiumAppendWindowSuffix();
                NSLog(@"[Magnesium] Minecraft window discovered: '%@'",
                      magnesiumWindow.title);
                break;
            }
        }

        if (magnesiumWindow == nil) {
            NSLog(@"[Magnesium] No suitable Minecraft window yet.");
        }

        magnesiumDiscoveryScheduled = NO;
    }
}

/*
 * Runs on the AppKit main thread. Attaches a CAMetalLayer to the
 * discovered window's content view and obtains a CAMetalDrawable.
 *
 * This replaces the content view's existing (OpenGL-backed) layer, so
 * it takes over the on-screen presentation for this view.
 */
void MagnesiumAttachLayer(void) {
    @autoreleasepool {
        if (magnesiumWindow == nil) {
            NSLog(@"[Magnesium] Layer attach: no window discovered yet.");
            return;
        }

        NSView *view = magnesiumWindow.contentView;
        if (view == nil) {
            NSLog(@"[Magnesium] Layer attach: no content view.");
            return;
        }

        CAMetalLayer *layer = [CAMetalLayer layer];

        layer.device = magnesiumDevice;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.opaque = YES;
        layer.displaySyncEnabled = YES;

        CGFloat scale = 1.0;
        if (view.window != nil) {
            scale = view.window.backingScaleFactor;
        }

        CGSize pixels = [view convertRectToBacking:view.bounds].size;

        layer.contentsScale = scale;
        layer.drawableSize = CGSizeMake(pixels.width, pixels.height);

        magnesiumLayer = layer;

        view.wantsLayer = YES;
        view.layer = layer;

        NSLog(@"[Magnesium] CAMetalLayer attached. drawableSize=%.0fx%.0f scale=%.2f",
              pixels.width, pixels.height, scale);

        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable == nil) {
            NSLog(@"[Magnesium] Failed to obtain CAMetalDrawable.");
            return;
        }

        NSLog(@"[Magnesium] Drawable obtained. texture=%lux%lu pixelFormat=%lu",
              (unsigned long)drawable.texture.width,
              (unsigned long)drawable.texture.height,
              (unsigned long)drawable.texture.pixelFormat);
    }
}

/*
 * Runs on the AppKit main thread. Presents a single solid-color test
 * frame through the attached CAMetalLayer to prove the drawable path.
 */
void MagnesiumPresentTestFrame(void) {
    @autoreleasepool {
        if (magnesiumLayer == nil ||
            magnesiumDevice == nil ||
            magnesiumCommandQueue == nil) {
            NSLog(@"[Magnesium] Present test frame: layer/device/queue not ready.");
            return;
        }

        id<CAMetalDrawable> drawable = [magnesiumLayer nextDrawable];
        if (drawable == nil) {
            NSLog(@"[Magnesium] Present test frame: no drawable.");
            return;
        }

        MTLRenderPassDescriptor *pass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.45, 0.0, 0.55, 1.0);

        id<MTLCommandBuffer> commandBuffer =
            [magnesiumCommandQueue commandBuffer];

        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];

        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        NSLog(@"[Magnesium] Test frame presented (crimson).");
    }
}

/*
 * Metal buffer registry.
 *
 * Sodium's buffer objects (GlMutableBuffer / GlImmutableBuffer) are plain
 * Java objects that currently hold a GL handle. Magnesium keeps Sodium's
 * object graph intact and maps each buffer object to a real MTLBuffer via
 * a long handle issued by JNI. The registry lives on the native side so
 * JNI never has to pass Objective-C objects across the boundary.
 */
static NSMutableDictionary<NSNumber *, id<MTLBuffer>> *magnesiumBuffers = nil;
static int64_t magnesiumNextBufferId = 1;

void MagnesiumEnsureBufferRegistry(void) {
    if (magnesiumBuffers == nil) {
        @autoreleasepool {
            magnesiumBuffers = [NSMutableDictionary dictionary];
        }
    }
}

id<MTLBuffer> MagnesiumBufferForHandle(int64_t handle) {
    MagnesiumEnsureBufferRegistry();
    return magnesiumBuffers[@(handle)];
}

int64_t MagnesiumRegisterBuffer(id<MTLBuffer> buffer) {
    MagnesiumEnsureBufferRegistry();
    int64_t handle = magnesiumNextBufferId++;
    magnesiumBuffers[@(handle)] = buffer;
    return handle;
}

/*
 * Creates a shared-storage MTLBuffer of the given size. Returns a Java
 * long handle, or 0 on failure.
 */
int64_t MagnesiumCreateBuffer(NSUInteger length) {
    if (magnesiumDevice == nil) {
        NSLog(@"[Magnesium] createBuffer: no Metal device.");
        return 0;
    }
    // MetalCreateSystemDevice rejects zero-length shared buffers (returns nil),
    // but Sodium legitimately requests buffers with 0 initial capacity and
    // grows them later via uploadData/allocateBufferStorage. Clamp to a single
    // byte so these zero-length recordkeeping allocations yield a valid
    // MTLBuffer instead of silently failing.
    if (length == 0) {
        length = 1;
    }
    id<MTLBuffer> buffer =
        [magnesiumDevice newBufferWithLength:length
                                     options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        NSLog(@"[Magnesium] createBuffer: failed for length %lu.",
              (unsigned long)length);
        return 0;
    }
    return MagnesiumRegisterBuffer(buffer);
}

/*
 * Offscreen chunk rasterizer.
 *
 * Sodium's terrain batches are translated into real Metal draw calls against
 * an offscreen render target whose contents are read back and dumped to a PNG
 * file (with per-frame statistics) for verification. This exercises the real
 * Metal pipeline: the compact ChunkVertexComms decode, the region vertex/
 * index mirrors, and drawIndexedPrimitives.
 */
/* Pass kinds, matching MagnesiumPassHook on the Java side. */
enum {
    MagnesiumPassSolid = 0,
    MagnesiumPassCutout = 1,
    MagnesiumPassTranslucent = 2,
    MagnesiumPassCount = 3
};

static id<MTLRenderPipelineState> magnesiumChunkPipelines[MagnesiumPassCount] = { nil, nil, nil };
static id<MTLDepthStencilState> magnesiumDepthStates[MagnesiumPassCount] = { nil, nil, nil };
static id<MTLTexture> magnesiumBlockTexture = nil;
static id<MTLTexture> magnesiumLightTexture = nil;
static id<MTLTexture> magnesiumCapColor = nil;
static id<MTLTexture> magnesiumCapDepth = nil;
static NSUInteger magnesiumCapWidth = 0;
static NSUInteger magnesiumCapHeight = 0;
static id<MTLCommandBuffer> magnesiumCapCommandBuffer = nil;
static id<MTLRenderCommandEncoder> magnesiumCapEncoder = nil;
static BOOL magnesiumCaptureOpen = NO;
static uint64_t magnesiumCapIndices = 0;
static int64_t magnesiumCapSubDraws = 0;
static float magnesiumCapMvp[16];
static int magnesiumCapPass = MagnesiumPassSolid;
static BOOL magnesiumCullBackFaces = NO;

/*
 * Mirrors the ChunkShaderInterface uniforms that are not region-dependent:
 * u_TexCoordShrink and the smooth-fog uniforms (u_FogColor / u_FogStart /
 * u_FogEnd / u_FogShape). Layout must match ChunkUniforms in the MSL below.
 */
typedef struct {
    matrix_float4x4 mvp;
    vector_float3 regionOffset;
    vector_float2 texCoordShrink;
    vector_float4 fogColor;
    float fogStart;
    float fogEnd;
    int32_t fogShape;
} MagnesiumChunkUniforms;

static vector_float2 magnesiumTexCoordShrink = { 0.0f, 0.0f };
static vector_float4 magnesiumFogColor = { 0.0f, 0.0f, 0.0f, 0.0f };
static float magnesiumFogStart = 1.0e9f;
static float magnesiumFogEnd = 1.0e9f;
static int32_t magnesiumFogShape = 0;

/*
 * MSL port of Sodium 0.5.11's block_layer_opaque.vsh / .fsh with
 * CompactChunkVertex (stride 20): a_Position (2 x uint32), a_Color (4 x ubyte
 * normalized), a_TexCoord (2 x ushort), a_LightAndData (4 x ubyte: light.xy,
 * material, draw id). USE_FRAGMENT_DISCARD is the function constant at 0.
 */
static NSString *kMagnesiumChunkMSL =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "\n"
     "constant bool kUseFragmentDiscard [[function_constant(0)]];\n"
     "\n"
     "struct ChunkUniforms {\n"
     "    float4x4 mvp;\n"
     "    float3 regionOffset;\n"
     "    float2 texCoordShrink;\n"
     "    float4 fogColor;\n"
     "    float fogStart;\n"
     "    float fogEnd;\n"
     "    int fogShape;\n"
     "};\n"
     "\n"
     "struct ChunkVertOut {\n"
     "    float4 position [[position]];\n"
     "    float4 color;\n"
     "    float2 texCoord;\n"
     "    float mipBias;\n"
     "    float alphaCutoff;\n"
     "    float fragDistance;\n"
     "};\n"
     "\n"
     "constexpr sampler lightSampler(coord::normalized, address::clamp_to_edge,\n"
     "                               filter::linear);\n"
     "constexpr sampler blockSampler(coord::normalized, address::clamp_to_edge,\n"
     "                               mag_filter::nearest, min_filter::nearest,\n"
     "                               mip_filter::linear);\n"
     "\n"
     "constant float kAlphaCutoff[4] = { 0.0f, 0.1f, 0.5f, 1.0f };\n"
     "\n"
     "// _deinterleave_u20x3: hi holds bits 10..19, lo bits 0..9, per axis.\n"
     "inline float3 decodePosition(uint hi, uint lo) {\n"
     "    uint x = (((hi >> 0u) & 0x3FFu) << 10u) | ((lo >> 0u) & 0x3FFu);\n"
     "    uint y = (((hi >> 10u) & 0x3FFu) << 10u) | ((lo >> 10u) & 0x3FFu);\n"
     "    uint z = (((hi >> 20u) & 0x3FFu) << 10u) | ((lo >> 20u) & 0x3FFu);\n"
     "    return float3(x, y, z) * (32.0f / 1048576.0f) - 8.0f;\n"
     "}\n"
     "\n"
     "inline float fragDistanceFor(int shape, float3 p) {\n"
     "    if (shape == 1) {\n"
     "        return max(length(p.xz), abs(p.y));\n"
     "    }\n"
     "    return length(p);\n"
     "}\n"
     "\n"
     "vertex ChunkVertOut chunkVertex(\n"
     "        const device uint32_t* verts [[buffer(0)]],\n"
     "        constant ChunkUniforms& unif [[buffer(1)]],\n"
     "        texture2d<float> lightTex [[texture(1)]],\n"
     "        uint vid [[vertex_id]]) {\n"
     "    uint off = vid * 5u;\n"
     "    uint hi           = verts[off + 0u];\n"
     "    uint lo           = verts[off + 1u];\n"
     "    uint colorBits    = verts[off + 2u];\n"
     "    uint texBits      = verts[off + 3u];\n"
     "    uint lightAndData = verts[off + 4u];\n"
     "\n"
     "    float3 local = decodePosition(hi, lo);\n"
     "\n"
     "    // LocalSectionIndex packing for the section coordinate.\n"
     "    uint drawId = (lightAndData >> 24u) & 0xFFu;\n"
     "    uint cx = (drawId >> 5u) & 7u;\n"
     "    uint cy = drawId & 3u;\n"
     "    uint cz = (drawId >> 2u) & 7u;\n"
     "    float3 position = local + float3(cx, cy, cz) * 16.0f + unif.regionOffset;\n"
     "\n"
     "    ChunkVertOut out;\n"
     "    out.fragDistance = fragDistanceFor(unif.fogShape, position);\n"
     "\n"
     "    float4 clip = unif.mvp * float4(position, 1.0f);\n"
     "    // Remap GL [-1,1] clip-space depth to Metal's [0,1] before the\n"
     "    // rasterizer divides by w and maps to the depth range.\n"
     "    clip.z = clip.z * 0.5f + 0.5f * clip.w;\n"
     "    out.position = clip;\n"
     "\n"
     "    float4 vertColor = float4(colorBits & 0xFFu,\n"
     "                              (colorBits >> 8u) & 0xFFu,\n"
     "                              (colorBits >> 16u) & 0xFFu,\n"
     "                              (colorBits >> 24u) & 0xFFu) / 255.0f;\n"
     "    float2 lightCoord = float2(lightAndData & 0xFFu,\n"
     "                               (lightAndData >> 8u) & 0xFFu) / 256.0f;\n"
     "    out.color = vertColor * lightTex.sample(lightSampler, lightCoord, level(0));\n"
     "\n"
     "    // 15-bit texcoord with the sign bit of the shrink bias in bit 15.\n"
     "    float2 texCoord = float2(texBits & 0x7FFFu, (texBits >> 16u) & 0x7FFFu) / 32768.0f;\n"
     "    float2 texBias = float2(((texBits >> 15u) & 1u) != 0u ? 1.0f : -1.0f,\n"
     "                            ((texBits >> 31u) & 1u) != 0u ? 1.0f : -1.0f);\n"
     "    out.texCoord = texBias * unif.texCoordShrink + texCoord;\n"
     "\n"
     "    uint material = (lightAndData >> 16u) & 0xFFu;\n"
     "    out.mipBias = ((material & 1u) != 0u) ? 0.0f : -4.0f;\n"
     "    out.alphaCutoff = kAlphaCutoff[(material >> 1u) & 3u];\n"
     "    return out;\n"
     "}\n"
     "\n"
     "fragment float4 chunkFragment(\n"
     "        ChunkVertOut in [[stage_in]],\n"
     "        constant ChunkUniforms& unif [[buffer(1)]],\n"
     "        texture2d<float> blockTex [[texture(0)]]) {\n"
     "    float4 diffuse = blockTex.sample(blockSampler, in.texCoord, bias(in.mipBias));\n"
     "\n"
     "    if (is_function_constant_defined(kUseFragmentDiscard) && kUseFragmentDiscard) {\n"
     "        if (diffuse.a < in.alphaCutoff) {\n"
     "            discard_fragment();\n"
     "        }\n"
     "    }\n"
     "\n"
     "    diffuse.rgb *= in.color.rgb;\n"
     "    diffuse.rgb *= in.color.a;\n"
     "\n"
     "    // _linearFog\n"
     "    if (in.fragDistance > unif.fogStart) {\n"
     "        float factor = in.fragDistance < unif.fogEnd\n"
     "            ? smoothstep(unif.fogStart, unif.fogEnd, in.fragDistance) : 1.0f;\n"
     "        diffuse.rgb = mix(diffuse.rgb, unif.fogColor.rgb, factor * unif.fogColor.a);\n"
     "    }\n"
     "    return diffuse;\n"
     "}\n";

static BOOL MagnesiumEnsureChunkPipeline(void) {
    if (magnesiumChunkPipelines[MagnesiumPassTranslucent] != nil) {
        return YES;
    }

    NSError *error = nil;
    id<MTLLibrary> library =
        [magnesiumDevice newLibraryWithSource:kMagnesiumChunkMSL
                                      options:nil
                                        error:&error];
    if (library == nil) {
        NSLog(@"[Magnesium] chunk pipeline: MSL compile failed: %@",
              error.localizedDescription);
        return NO;
    }

    for (int pass = 0; pass < MagnesiumPassCount; pass++) {
        BOOL discard = (pass == MagnesiumPassCutout);
        BOOL translucent = (pass == MagnesiumPassTranslucent);

        MTLFunctionConstantValues *constants =
            [[MTLFunctionConstantValues alloc] init];
        [constants setConstantValue:&discard
                               type:MTLDataTypeBool
                            atIndex:0];

        id<MTLFunction> vertexFn =
            [library newFunctionWithName:@"chunkVertex"
                          constantValues:constants
                                   error:&error];
        id<MTLFunction> fragmentFn =
            [library newFunctionWithName:@"chunkFragment"
                          constantValues:constants
                                   error:&error];
        if (vertexFn == nil || fragmentFn == nil) {
            NSLog(@"[Magnesium] chunk pipeline: missing entry points: %@",
                  error.localizedDescription);
            return NO;
        }

        MTLRenderPipelineDescriptor *desc =
            [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertexFn;
        desc.fragmentFunction = fragmentFn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        if (translucent) {
            /* Vanilla translucent layer:
             * glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA) */
            MTLRenderPipelineColorAttachmentDescriptor *att = desc.colorAttachments[0];
            att.blendingEnabled = YES;
            att.rgbBlendOperation = MTLBlendOperationAdd;
            att.alphaBlendOperation = MTLBlendOperationAdd;
            att.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            att.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            att.sourceAlphaBlendFactor = MTLBlendFactorOne;
            att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        } else {
            desc.colorAttachments[0].blendingEnabled = NO;
        }

        magnesiumChunkPipelines[pass] =
            [magnesiumDevice newRenderPipelineStateWithDescriptor:desc
                                                            error:&error];
        if (magnesiumChunkPipelines[pass] == nil) {
            NSLog(@"[Magnesium] chunk pipeline %d: state creation failed: %@",
                  pass, error.localizedDescription);
            return NO;
        }

        /* Vanilla uses GL_LEQUAL; translucent geometry tests but does not write depth. */
        MTLDepthStencilDescriptor *ds = [[MTLDepthStencilDescriptor alloc] init];
        ds.depthCompareFunction = MTLCompareFunctionLessEqual;
        ds.depthWriteEnabled = translucent ? NO : YES;
        magnesiumDepthStates[pass] =
            [magnesiumDevice newDepthStencilStateWithDescriptor:ds];
    }

    NSLog(@"[Magnesium] chunk pipelines ready (solid/cutout/translucent).");
    return YES;
}

/* Binds the pipeline, depth state and textures for the current pass. */
static void MagnesiumApplyPassState(void) {
    if (magnesiumCapEncoder == nil) {
        return;
    }
    int pass = magnesiumCapPass;
    [magnesiumCapEncoder setRenderPipelineState:magnesiumChunkPipelines[pass]];
    [magnesiumCapEncoder setDepthStencilState:magnesiumDepthStates[pass]];
    [magnesiumCapEncoder setFragmentTexture:magnesiumBlockTexture atIndex:0];
    [magnesiumCapEncoder setVertexTexture:magnesiumLightTexture atIndex:1];
}

static void MagnesiumSetCapMatrices(const jfloat *mvp) {
    if (mvp != NULL) {
        memcpy(magnesiumCapMvp, mvp, sizeof(magnesiumCapMvp));
    }
}

static void MagnesiumResetCaptureState(void) {
    magnesiumCapEncoder = nil;
    magnesiumCapCommandBuffer = nil;
    magnesiumCaptureOpen = NO;
    magnesiumCapIndices = 0;
    magnesiumCapSubDraws = 0;
}

static inline simd_float3 MagnesiumDecodeCompactPosition(uint hi, uint lo) {
    /* Matches CompactChunkVertex/block_layer vsh: hi = bits 10..19, lo = bits
     * 0..9 per axis; 20-bit quantized in [-8, 24) block space. */
    uint x = (((hi >> 0u) & 0x3FFu) << 10u) | ((lo >> 0u) & 0x3FFu);
    uint y = (((hi >> 10u) & 0x3FFu) << 10u) | ((lo >> 10u) & 0x3FFu);
    uint z = (((hi >> 20u) & 0x3FFu) << 10u) | ((lo >> 20u) & 0x3FFu);
    return simd_make_float3((float)x, (float)y, (float)z) * (32.0f / 1048576.0f) - 8.0f;
}

extern "C" {

/* Copies bytes from a direct ByteBuffer into a Metal buffer at an offset. */

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_writeBufferRange(
    JNIEnv *env,
    jclass clazz,
    jlong handle,
    jlong offset,
    jobject src,
    jint srcOffset,
    jint length
) {
    @autoreleasepool {
        if (handle == 0 || src == NULL || length <= 0) {
            return;
        }
        id<MTLBuffer> buffer = MagnesiumBufferForHandle((int64_t)handle);
        if (buffer == nil) {
            return;
        }
        void *base = env->GetDirectBufferAddress(src);
        if (base == NULL) {
            return;
        }
        jlong cap = (jlong)env->GetDirectBufferCapacity(src);
        if (srcOffset < 0 || (jlong)srcOffset + length > cap) {
            return;
        }
        if ((NSUInteger)(offset + (jlong)length) > buffer.length) {
            return;
        }
        memcpy((char *)[buffer contents] + offset,
               (const char *)base + srcOffset,
               (size_t)length);
        [buffer didModifyRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
    }
}

/*
 * Creates (or replaces) a sampled RGBA8 texture. Slot 0 is the block atlas
 * (u_BlockTex), slot 1 is the light map (u_LightTex).
 */
JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_createTexture(
    JNIEnv *env,
    jclass clazz,
    jint slot,
    jint width,
    jint height,
    jint mipLevels
) {
    @autoreleasepool {
        if (magnesiumDevice == nil || width <= 0 || height <= 0 ||
            mipLevels <= 0 || (slot != 0 && slot != 1)) {
            return JNI_FALSE;
        }
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
        desc.width = (NSUInteger)width;
        desc.height = (NSUInteger)height;
        desc.mipmapLevelCount = (NSUInteger)mipLevels;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [magnesiumDevice newTextureWithDescriptor:desc];
        if (texture == nil) {
            NSLog(@"[Magnesium] createTexture: failed slot=%d %dx%d mips=%d.",
                  slot, width, height, mipLevels);
            return JNI_FALSE;
        }
        if (slot == 0) {
            magnesiumBlockTexture = texture;
        } else {
            magnesiumLightTexture = texture;
        }
        return JNI_TRUE;
    }
}

/* Uploads tightly packed RGBA8 pixels for one mip level of a texture slot. */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_uploadTextureLevel(
    JNIEnv *env,
    jclass clazz,
    jint slot,
    jint level,
    jint width,
    jint height,
    jobject src
) {
    @autoreleasepool {
        id<MTLTexture> texture = (slot == 0) ? magnesiumBlockTexture
                               : (slot == 1) ? magnesiumLightTexture : nil;
        if (texture == nil || src == NULL || level < 0 ||
            (NSUInteger)level >= texture.mipmapLevelCount) {
            return;
        }
        void *base = env->GetDirectBufferAddress(src);
        jlong cap = (jlong)env->GetDirectBufferCapacity(src);
        if (base == NULL || cap < (jlong)width * height * 4) {
            return;
        }
        [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                   mipmapLevel:(NSUInteger)level
                     withBytes:base
                   bytesPerRow:(NSUInteger)width * 4];
    }
}

/*
 * Selects the terrain pass (0 solid, 1 cutout, 2 translucent) and supplies
 * the pass-wide uniforms: params = [fogR, fogG, fogB, fogA, fogStart, fogEnd,
 * fogShape, texCoordShrinkX, texCoordShrinkY].
 */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_setChunkPassState(
    JNIEnv *env,
    jclass clazz,
    jint passKind,
    jfloatArray params
) {
    @autoreleasepool {
        if (passKind < 0 || passKind >= MagnesiumPassCount ||
            params == NULL || env->GetArrayLength(params) != 9) {
            return;
        }
        jfloat p[9];
        env->GetFloatArrayRegion(params, 0, 9, p);
        magnesiumFogColor = simd_make_float4(p[0], p[1], p[2], p[3]);
        magnesiumFogStart = p[4];
        magnesiumFogEnd = p[5];
        magnesiumFogShape = (int32_t)p[6];
        magnesiumTexCoordShrink = simd_make_float2(p[7], p[8]);

        if (magnesiumCapPass != passKind) {
            magnesiumCapPass = passKind;
            if (magnesiumCaptureOpen) {
                MagnesiumApplyPassState();
            }
        }
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_setChunkCulling(
    JNIEnv *env,
    jclass clazz,
    jboolean cullBackFaces
) {
    magnesiumCullBackFaces = (cullBackFaces == JNI_TRUE) ? YES : NO;
}

JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_beginChunkCapture(
    JNIEnv *env,
    jclass clazz,
    jint width,
    jint height,
    jfloatArray mvp
) {
    @autoreleasepool {
        if (!MagnesiumEnsureChunkPipeline() ||
            magnesiumDevice == nil ||
            magnesiumCommandQueue == nil ||
            magnesiumBlockTexture == nil ||
            magnesiumLightTexture == nil) {
            return JNI_FALSE;
        }

        if (mvp != NULL) {
            jsize n = env->GetArrayLength(mvp);
            if (n == 16) {
                jfloat *f = env->GetFloatArrayElements(mvp, NULL);
                if (f != NULL) {
                    MagnesiumSetCapMatrices(f);
                    env->ReleaseFloatArrayElements(mvp, f, JNI_ABORT);
                }
            }
        }

        if ((NSUInteger)width != magnesiumCapWidth ||
            (NSUInteger)height != magnesiumCapHeight ||
            magnesiumCapColor == nil) {
            MTLTextureDescriptor *colorDesc =
                [[MTLTextureDescriptor alloc] init];
            colorDesc.pixelFormat = MTLPixelFormatRGBA8Unorm;
            colorDesc.width = (NSUInteger)width;
            colorDesc.height = (NSUInteger)height;
            colorDesc.usage =
                MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            magnesiumCapColor =
                [magnesiumDevice newTextureWithDescriptor:colorDesc];

            MTLTextureDescriptor *depthDesc =
                [[MTLTextureDescriptor alloc] init];
            depthDesc.pixelFormat = MTLPixelFormatDepth32Float;
            depthDesc.width = (NSUInteger)width;
            depthDesc.height = (NSUInteger)height;
            depthDesc.usage = MTLTextureUsageRenderTarget;
            magnesiumCapDepth =
                [magnesiumDevice newTextureWithDescriptor:depthDesc];

            magnesiumCapWidth = (NSUInteger)width;
            magnesiumCapHeight = (NSUInteger)height;
        }

        if (magnesiumCapColor == nil || magnesiumCapDepth == nil) {
            return JNI_FALSE;
        }

        if (magnesiumCapEncoder != nil) {
            [magnesiumCapEncoder endEncoding];
        }

        MTLRenderPassDescriptor *pass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = magnesiumCapColor;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(0.30, 0.55, 0.70, 1.0);
        pass.depthAttachment.texture = magnesiumCapDepth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        pass.depthAttachment.clearDepth = 1.0;

        magnesiumCapCommandBuffer =
            [magnesiumCommandQueue commandBuffer];
        magnesiumCapEncoder =
            [magnesiumCapCommandBuffer renderCommandEncoderWithDescriptor:pass];
        magnesiumCapPass = MagnesiumPassSolid;
        MagnesiumApplyPassState();
        [magnesiumCapEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [magnesiumCapEncoder setCullMode:magnesiumCullBackFaces ? MTLCullModeBack : MTLCullModeNone];

        magnesiumCaptureOpen = YES;
        magnesiumCapIndices = 0;
        magnesiumCapSubDraws = 0;

        return JNI_TRUE;
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_setChunkMvp(
    JNIEnv *env,
    jclass clazz,
    jfloatArray mvp
) {
    @autoreleasepool {
        if (mvp == NULL) {
            return;
        }
        jsize n = env->GetArrayLength(mvp);
        if (n != 16) {
            return;
        }
        jfloat *f = env->GetFloatArrayElements(mvp, NULL);
        if (f != NULL) {
            MagnesiumSetCapMatrices(f);
            env->ReleaseFloatArrayElements(mvp, f, JNI_ABORT);
        }
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_drawChunkBatch(
    JNIEnv *env,
    jclass clazz,
    jlong vertexHandle,
    jlong indexHandle,
    jint indexTypeId,
    jlong pElementCount,
    jlong pBaseVertex,
    jint elementCount,
    jfloat ox,
    jfloat oy,
    jfloat oz
) {
    @autoreleasepool {
        if (!magnesiumCaptureOpen ||
            magnesiumCapEncoder == nil ||
            elementCount <= 0 ||
            pElementCount == 0 ||
            pBaseVertex == 0) {
            return;
        }

        id<MTLBuffer> vertexBuffer = MagnesiumBufferForHandle((int64_t)vertexHandle);
        id<MTLBuffer> indexBuffer = MagnesiumBufferForHandle((int64_t)indexHandle);
        if (vertexBuffer == nil || indexBuffer == nil) {
            NSLog(@"[Magnesium] drawChunkBatch: missing vertex/index mirror "
                  "(vertex=%ld index=%ld).", (long)vertexHandle, (long)indexHandle);
            return;
        }

        MTLIndexType indexType;
        switch (indexTypeId) {
            case 5123: /* GL_UNSIGNED_SHORT */
                indexType = MTLIndexTypeUInt16;
                break;
            default:   /* GL_UNSIGNED_INT (Sodium chunk batches) */
                indexType = MTLIndexTypeUInt32;
                break;
        }

        simd_float4 cols[4];
        cols[0] = simd_make_float4(magnesiumCapMvp[0], magnesiumCapMvp[1],
                                   magnesiumCapMvp[2], magnesiumCapMvp[3]);
        cols[1] = simd_make_float4(magnesiumCapMvp[4], magnesiumCapMvp[5],
                                   magnesiumCapMvp[6], magnesiumCapMvp[7]);
        cols[2] = simd_make_float4(magnesiumCapMvp[8], magnesiumCapMvp[9],
                                   magnesiumCapMvp[10], magnesiumCapMvp[11]);
        cols[3] = simd_make_float4(magnesiumCapMvp[12], magnesiumCapMvp[13],
                                   magnesiumCapMvp[14], magnesiumCapMvp[15]);
        matrix_float4x4 m;
        m.columns[0] = cols[0];
        m.columns[1] = cols[1];
        m.columns[2] = cols[2];
        m.columns[3] = cols[3];

        MagnesiumChunkUniforms uniforms;
        uniforms.mvp = m;
        uniforms.regionOffset = simd_make_float3(ox, oy, oz);
        uniforms.texCoordShrink = magnesiumTexCoordShrink;
        uniforms.fogColor = magnesiumFogColor;
        uniforms.fogStart = magnesiumFogStart;
        uniforms.fogEnd = magnesiumFogEnd;
        uniforms.fogShape = magnesiumFogShape;
        [magnesiumCapEncoder setVertexBytes:&uniforms
                                     length:sizeof(uniforms)
                                    atIndex:1];
        [magnesiumCapEncoder setFragmentBytes:&uniforms
                                       length:sizeof(uniforms)
                                      atIndex:1];
        [magnesiumCapEncoder setVertexBuffer:vertexBuffer
                                      offset:0
                                     atIndex:0];

        const int32_t *counts = (const int32_t *)(intptr_t)pElementCount;
        const int32_t *bases = (const int32_t *)(intptr_t)pBaseVertex;

        if (magnesiumCapSubDraws == 0L) {
            NSLog(@"[Magnesium] capMvp={%.3f,%.3f,%.3f,%.3f, %.3f,%.3f,%.3f,%.3f, %.3f,%.3f,%.3f,%.3f, %.3f,%.3f,%.3f,%.3f}",
                  magnesiumCapMvp[0], magnesiumCapMvp[1], magnesiumCapMvp[2], magnesiumCapMvp[3],
                  magnesiumCapMvp[4], magnesiumCapMvp[5], magnesiumCapMvp[6], magnesiumCapMvp[7],
                  magnesiumCapMvp[8], magnesiumCapMvp[9], magnesiumCapMvp[10], magnesiumCapMvp[11],
                  magnesiumCapMvp[12], magnesiumCapMvp[13], magnesiumCapMvp[14], magnesiumCapMvp[15]);
            int32_t count0 = counts[0];
            int32_t base0 = bases[0];
            NSLog(@"[Magnesium] first draw: count=%d base=%d regionOffset=(%.1f,%.1f,%.1f)",
                  count0, base0, ox, oy, oz);
            const uint32_t *vb = (const uint32_t *)[vertexBuffer contents];
            if (vb != NULL && base0 >= 0) {
                for (int k = 0; k < 8 && (base0 + k) * 5u + 4u < vertexBuffer.length / 4u; k++) {
                    uint32_t o = (uint32_t)(base0 + k) * 5u;
                    simd_float3 loc = MagnesiumDecodeCompactPosition(vb[o], vb[o + 1u]);
                    NSLog(@"[Magnesium] v[%d] hi=%08x lo=%08x color=%08x tex=%08x light=%08x -> local=(%.2f,%.2f,%.2f)",
                          k, vb[o], vb[o + 1u], vb[o + 2u], vb[o + 3u], vb[o + 4u],
                          loc.x, loc.y, loc.z);
                }
                /* Clip-space projection of the first few decoded vertices with
                 * the capture MVP + region offset, to see if they are on-screen. */
                simd_float4 cols[4];
                for (int c = 0; c < 4; c++) {
                    cols[c] = simd_make_float4(magnesiumCapMvp[c * 4 + 0],
                                               magnesiumCapMvp[c * 4 + 1],
                                               magnesiumCapMvp[c * 4 + 2],
                                               magnesiumCapMvp[c * 4 + 3]);
                }
                matrix_float4x4 mvp;
                mvp.columns[0] = cols[0];
                mvp.columns[1] = cols[1];
                mvp.columns[2] = cols[2];
                mvp.columns[3] = cols[3];
                for (int k = 0; k < 6 && (base0 + k) * 5u + 4u < vertexBuffer.length / 4u; k++) {
                    uint32_t vo = (uint32_t)(base0 + k) * 5u;
                    simd_float3 loc = MagnesiumDecodeCompactPosition(vb[vo], vb[vo + 1u]);
                    uint32_t drawId = (vb[vo + 4u] >> 24u) & 0xFFu;
                    uint32_t cx = (drawId >> 5u) & 7u;
                    uint32_t cy = drawId & 3u;
                    uint32_t cz = (drawId >> 2u) & 7u;
                    simd_float3 world = simd_make_float3(loc.x + (float)cx * 16.0f + ox,
                                                         loc.y + (float)cy * 16.0f + oy,
                                                         loc.z + (float)cz * 16.0f + oz);
                    simd_float4 p = simd_mul(mvp, simd_make_float4(world, 1.0f));
                    NSLog(@"[Magnesium] clip[%d] world=(%.1f,%.1f,%.1f) -> ndc=(%.2f,%.2f,%.2f) w=%.2f",
                          k, world.x, world.y, world.z,
                          (p.w != 0.0f) ? p.x / p.w : 0.0f,
                          (p.w != 0.0f) ? p.y / p.w : 0.0f,
                          (p.w != 0.0f) ? p.z / p.w : 0.0f,
                          p.w);
                }
            }
            const uint32_t *ib = (const uint32_t *)[indexBuffer contents];
            if (ib != NULL) {
                NSLog(@"[Magnesium] index[0..11]=%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u bytes=%lu",
                      ib[0], ib[1], ib[2], ib[3], ib[4], ib[5],
                      ib[6], ib[7], ib[8], ib[9], ib[10], ib[11],
                      (unsigned long)indexBuffer.length);
            }
            /* Bounding box of decoded positions (local + section origin) over
             * the mirrored arena, to distinguish empty/garbage vertex data. */
            const uint32_t *arena = (const uint32_t *)[vertexBuffer contents];
            size_t verts = vertexBuffer.length / 20u;
            if (arena != NULL && verts > 0) {
                size_t limit = verts < 300000u ? verts : 300000u;
                float minx = 1e9f, miny = 1e9f, minz = 1e9f;
                float maxx = -1e9f, maxy = -1e9f, maxz = -1e9f;
                uint32_t nonzero = 0;
                for (size_t v = 0; v < limit; v++) {
                    uint32_t o = (uint32_t)v * 5u;
                    uint32_t hi = arena[o], lo = arena[o + 1u];
                    if (hi != 0u || lo != 0u) {
                        nonzero++;
                    }
                    simd_float3 loc = MagnesiumDecodeCompactPosition(hi, lo);
                    uint32_t drawId = (arena[o + 4u] >> 24u) & 0xFFu;
                    uint32_t cx = (drawId >> 5u) & 7u;
                    uint32_t cy = drawId & 3u;
                    uint32_t cz = (drawId >> 2u) & 7u;
                    float px = loc.x + (float)cx * 16.0f;
                    float py = loc.y + (float)cy * 16.0f;
                    float pz = loc.z + (float)cz * 16.0f;
                    if (px < minx) minx = px;
                    if (py < miny) miny = py;
                    if (pz < minz) minz = pz;
                    if (px > maxx) maxx = px;
                    if (py > maxy) maxy = py;
                    if (pz > maxz) maxz = pz;
                }
                NSLog(@"[Magnesium] arena bbox over %lu/%zu verts (%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f) nonzero=%u",
                      (unsigned long)limit, verts, minx, miny, minz, maxx, maxy, maxz, nonzero);
            }
        }

        for (int i = 0; i < elementCount; i++) {
            int32_t count = counts[i];
            int32_t base = bases[i];
            if (count <= 0) {
                continue;
            }
            [magnesiumCapEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                            indexCount:count
                                             indexType:indexType
                                           indexBuffer:indexBuffer
                                     indexBufferOffset:0
                                         instanceCount:1
                                            baseVertex:base
                                          baseInstance:0];
            magnesiumCapIndices += (uint64_t)count;
        }
        magnesiumCapSubDraws += elementCount;
    }
}

JNIEXPORT jlongArray JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_endChunkCapture(
    JNIEnv *env,
    jclass clazz,
    jstring pngPath
) {
    @autoreleasepool {
        jlongArray result = env->NewLongArray(6);
        jlong zeros[6] = { 0, 0, 0, 0, 0, 0 };
        if (result != NULL) {
            env->SetLongArrayRegion(result, 0, 6, zeros);
        }

        if (!magnesiumCaptureOpen ||
            magnesiumCapEncoder == nil ||
            magnesiumCapCommandBuffer == nil) {
            MagnesiumResetCaptureState();
            return result;
        }

        [magnesiumCapEncoder endEncoding];
        [magnesiumCapCommandBuffer commit];
        [magnesiumCapCommandBuffer waitUntilCompleted];

        NSUInteger w = magnesiumCapWidth;
        NSUInteger h = magnesiumCapHeight;
        NSUInteger bpr = w * 4;
        void *pixels = calloc(h, bpr);

        if (pixels != NULL) {
            [magnesiumCapColor getBytes:pixels
                            bytesPerRow:bpr
                             fromRegion:MTLRegionMake2D(0, 0, w, h)
                            mipmapLevel:0];
        }

        int64_t drawn = 0;
        int64_t rAccum = 0, gAccum = 0, bAccum = 0;
        int64_t coverageX1000 = 0, avgRX1000 = 0, avgGX1000 = 0, avgBX1000 = 0;

        if (pixels != NULL) {
            // Clear color bytes are (77, 140, 178) for (0.30, 0.55, 0.70).
            const uint8_t *p = (const uint8_t *)pixels;
            for (NSUInteger i = 0; i < w * h; i++) {
                uint8_t pr = p[0], pg = p[1], pb = p[2];
                p += 4;
                if (pr == 77 && pg == 140 && pb == 178) {
                    continue;
                }
                drawn++;
                rAccum += pr;
                gAccum += pg;
                bAccum += pb;
            }
            if (drawn > 0) {
                coverageX1000 = (drawn * 1000) / (int64_t)(w * h);
                avgRX1000 = (rAccum * 1000) / drawn;
                avgGX1000 = (gAccum * 1000) / drawn;
                avgBX1000 = (bAccum * 1000) / drawn;
            }

            if (pngPath != NULL) {
                const char *path = env->GetStringUTFChars(pngPath, NULL);
                if (path != NULL) {
                    NSBitmapImageRep *rep =
                        [[NSBitmapImageRep alloc]
                            initWithBitmapDataPlanes:NULL
                                         pixelsWide:(NSInteger)w
                                         pixelsHigh:(NSInteger)h
                                      bitsPerSample:8
                                    samplesPerPixel:4
                                           hasAlpha:YES
                                           isPlanar:NO
                                     colorSpaceName:NSCalibratedRGBColorSpace
                                        bytesPerRow:(NSInteger)bpr
                                       bitsPerPixel:32];
                    if (rep != NULL) {
                        memcpy([rep bitmapData], pixels, h * bpr);
                        NSData *png =
                            [rep representationUsingType:NSBitmapImageFileTypePNG
                                              properties:@{}];
                        NSString *nsPath =
                            [NSString stringWithUTF8String:path];
                        BOOL written =
                            [png writeToFile:nsPath atomically:YES];
                        NSLog(@"[Magnesium] Capture PNG %@: written=%@",
                              nsPath, (written ? @"YES" : @"NO"));
                    }
                    env->ReleaseStringUTFChars(pngPath, path);
                }
            }

            free(pixels);
        }

        jlong vals[6] = {
            (jlong)magnesiumCapSubDraws,
            (jlong)magnesiumCapIndices,
            (jlong)coverageX1000,
            (jlong)avgRX1000,
            (jlong)avgGX1000,
            (jlong)avgBX1000
        };

        if (result != NULL) {
            env->SetLongArrayRegion(result, 0, 6, vals);
        }

        MagnesiumResetCaptureState();
        return result;
    }
}

JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_initialize(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {
        NSLog(@"[Magnesium] Initializing Metal...");

        if (magnesiumDevice != nil &&
            magnesiumCommandQueue != nil) {
            NSLog(@"[Magnesium] Metal is already initialized.");
            return JNI_TRUE;
        }

        magnesiumDevice = MTLCreateSystemDefaultDevice();

        if (magnesiumDevice == nil) {
            NSLog(@"[Magnesium] Failed to create Metal device.");
            return JNI_FALSE;
        }

        NSLog(
            @"[Magnesium] Metal device: %@",
            [magnesiumDevice name]
        );

        magnesiumCommandQueue =
            [magnesiumDevice newCommandQueue];

        if (magnesiumCommandQueue == nil) {
            NSLog(
                @"[Magnesium] Failed to create Metal command queue."
            );

            magnesiumDevice = nil;

            return JNI_FALSE;
        }

        NSLog(@"[Magnesium] Metal command queue created.");

        NSLog(
            @"[Magnesium] Metal initialized successfully."
        );

        return JNI_TRUE;
    }
}

JNIEXPORT jstring JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_getDeviceName(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {

        if (magnesiumDevice == nil) {
            return env->NewStringUTF("Unknown");
        }

        NSString *name =
            [magnesiumDevice name];

        if (name == nil) {
            return env->NewStringUTF("Unknown");
        }

        return env->NewStringUTF(
            [name UTF8String]
        );
    }
}

/*
 * Schedules window discovery to run on the AppKit main thread.
 *
 * Safe to call from any thread. Does not block. The actual window
 * inspection happens asynchronously on the main queue.
 */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_discoverWindow(
    JNIEnv *env,
    jclass clazz
) {
    if (magnesiumWindow != nil || magnesiumDiscoveryScheduled) {
        return;
    }

    magnesiumDiscoveryScheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        MagnesiumRunWindowDiscovery();
    });
}

JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_isWindowDiscovered(
    JNIEnv *env,
    jclass clazz
) {
    return (magnesiumWindow != nil) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_getWindowDescription(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {

        if (magnesiumWindow == nil) {
            return env->NewStringUTF("(no window)");
        }

        NSString *description =
            [NSString stringWithFormat:
                @"title='%@' contentView=%@ visible=%@",
                magnesiumWindow.title,
                NSStringFromClass(
                    [magnesiumWindow.contentView class]
                ),
                (magnesiumWindow.isVisible ? @"YES" : @"NO")];

        return env->NewStringUTF(
            [description UTF8String]
        );
    }
}

/*
 * Schedules CAMetalLayer attachment on the AppKit main thread.
 *
 * Safe to call from any thread. Does not block. No-op if the layer is
 * already attached or an attach is already scheduled.
 */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_attachLayer(
    JNIEnv *env,
    jclass clazz
) {
    if (magnesiumLayer != nil || magnesiumLayerScheduled) {
        return;
    }

    magnesiumLayerScheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        MagnesiumAttachLayer();
    });
}

JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_isLayerAttached(
    JNIEnv *env,
    jclass clazz
) {
    return (magnesiumLayer != nil) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_getLayerInfo(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {

        if (magnesiumLayer == nil) {
            return env->NewStringUTF("(no layer)");
        }

        NSString *info =
            [NSString stringWithFormat:
                @"CAMetalLayer attached drawableSize=%.0fx%.0f scale=%.2f",
                magnesiumLayer.drawableSize.width,
                magnesiumLayer.drawableSize.height,
                magnesiumLayer.contentsScale];

        return env->NewStringUTF([info UTF8String]);
    }
}

/*
 * Schedules presentation of a single test frame on the main thread.
 */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_presentTestFrame(
    JNIEnv *env,
    jclass clazz
) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MagnesiumPresentTestFrame();
    });
}

JNIEXPORT jlong JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_createBuffer(
    JNIEnv *env,
    jclass clazz,
    jlong size
) {
    @autoreleasepool {
        if (size < 0) {
            return 0;
        }
        int64_t handle = MagnesiumCreateBuffer((NSUInteger)size);
        if (handle == 0) {
            return 0;
        }
        NSLog(@"[Magnesium] createBuffer: size=%lld handle=%lld",
              (long long)size, (long long)handle);
        return (jlong)handle;
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_uploadBufferData(
    JNIEnv *env,
    jclass clazz,
    jlong handle,
    jobject src
) {
    @autoreleasepool {
        if (handle == 0 || src == NULL) {
            return;
        }
        id<MTLBuffer> buffer = MagnesiumBufferForHandle((int64_t)handle);
        if (buffer == nil) {
            return;
        }
        jlong length = (jlong)env->GetDirectBufferCapacity(src);
        if (length <= 0) {
            return;
        }
        void *srcPtr = env->GetDirectBufferAddress(src);
        if (srcPtr == NULL) {
            return;
        }
        size_t copyLen = (size_t)MIN((jlong)buffer.length, length);
        memcpy([buffer contents], srcPtr, copyLen);
        [buffer didModifyRange:NSMakeRange(0, buffer.length)];
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_allocateBufferStorage(
    JNIEnv *env,
    jclass clazz,
    jlong handle,
    jlong size
) {
    @autoreleasepool {
        if (handle == 0) {
            return;
        }
        id<MTLBuffer> buffer = MagnesiumBufferForHandle((int64_t)handle);
        if (buffer == nil) {
            return;
        }
        // Zero-length shared buffers are invalid on Metal; treat as no-op just
        // like an unchanged size, and be defensive about other invalid sizes.
        if ((NSUInteger)size <= 0 || buffer.length == (NSUInteger)size) {
            return;
        }
        id<MTLBuffer> replacement =
            [magnesiumDevice newBufferWithLength:(NSUInteger)size
                                         options:MTLResourceStorageModeShared];
        if (replacement == nil) {
            NSLog(@"[Magnesium] allocateBufferStorage: failed size=%lld.",
                  (long long)size);
            return;
        }
        MagnesiumEnsureBufferRegistry();
        magnesiumBuffers[@(handle)] = replacement;
    }
}

/*
 * Copies bytes from one Metal buffer to another (shared memory), mirroring
 * GL glCopyBufferSubData used by Sodium's arena resize.
 */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_copyBufferData(
    JNIEnv *env,
    jclass clazz,
    jlong srcHandle,
    jlong dstHandle,
    jlong srcOffset,
    jlong dstOffset,
    jlong length
) {
    @autoreleasepool {
        if (srcHandle == 0 || dstHandle == 0 || length <= 0) {
            return;
        }
        id<MTLBuffer> src = MagnesiumBufferForHandle((int64_t)srcHandle);
        id<MTLBuffer> dst = MagnesiumBufferForHandle((int64_t)dstHandle);
        if (src == nil || dst == nil) {
            return;
        }
        if ((NSUInteger)(srcOffset + length) > src.length ||
            (NSUInteger)(dstOffset + length) > dst.length) {
            return;
        }
        memcpy((char *)[dst contents] + dstOffset,
               (const char *)[src contents] + srcOffset,
               (size_t)length);
        [dst didModifyRange:NSMakeRange((NSUInteger)dstOffset, (NSUInteger)length)];
    }
}

JNIEXPORT jlong JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_bufferMapContents(
    JNIEnv *env,
    jclass clazz,
    jlong handle
) {
    @autoreleasepool {
        if (handle == 0) {
            return 0;
        }
        id<MTLBuffer> buffer = MagnesiumBufferForHandle((int64_t)handle);
        if (buffer == nil) {
            return 0;
        }
        return (jlong)(intptr_t)[buffer contents];
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_bufferDidModify(
    JNIEnv *env,
    jclass clazz,
    jlong handle,
    jlong offset,
    jlong length
) {
    @autoreleasepool {
        if (handle == 0) {
            return;
        }
        id<MTLBuffer> buffer = MagnesiumBufferForHandle((int64_t)handle);
        if (buffer == nil) {
            return;
        }
        [buffer didModifyRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
    }
}

JNIEXPORT jlong JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_bufferLength(
    JNIEnv *env,
    jclass clazz,
    jlong handle
) {
    id<MTLBuffer> buffer = MagnesiumBufferForHandle((int64_t)handle);
    return (buffer == nil) ? 0 : (jlong)buffer.length;
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_deleteBuffer(
    JNIEnv *env,
    jclass clazz,
    jlong handle
) {
    @autoreleasepool {
        if (handle == 0) {
            return;
        }
        MagnesiumEnsureBufferRegistry();
        [magnesiumBuffers removeObjectForKey:@(handle)];
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_render(
    JNIEnv *env,
    jclass clazz
) {
    /*
     * Reserved for the Metal frame renderer.
     *
     * Frames are currently presented through presentTestFrame.
     */
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_shutdown(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {

        NSLog(
            @"[Magnesium] Shutting down Metal..."
        );

        for (int i = 0; i < MagnesiumPassCount; i++) {
            magnesiumChunkPipelines[i] = nil;
            magnesiumDepthStates[i] = nil;
        }
        magnesiumBlockTexture = nil;
        magnesiumLightTexture = nil;
        magnesiumLayer = nil;
        magnesiumWindow = nil;
        magnesiumCommandQueue = nil;
        magnesiumDevice = nil;

        @autoreleasepool {
            magnesiumBuffers = nil;
        }

        NSLog(
            @"[Magnesium] Metal shut down."
        );
    }
}

}
