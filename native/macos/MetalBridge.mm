#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <jni.h>
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/gl.h>
#include <IOSurface/IOSurface.h>
#include <atomic>

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
    if (getenv("MAGNESIUM_VERBOSE") != NULL) {
        NSLog(@"[Magnesium] Window title updated: '%@'", magnesiumWindow.title);
    }
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
 * Frame mode: the capture is a live per-frame render. The color target is
 * cleared to transparent, depth is kept, and both are blitted into shared
 * buffers that Java uploads to OpenGL for compositing.
 */
static BOOL magnesiumFrameMode = NO;
static uint64_t magnesiumSkippedDraws = 0;
static id<MTLBuffer> magnesiumFrameColorBuf = nil;
static id<MTLBuffer> magnesiumFrameDepthBuf = nil;

/*
 * Zero-copy frames: color and a packed 24-bit depth (second color attachment)
 * render into IOSurface-backed textures that OpenGL binds as rectangle
 * textures, so no readback or re-upload is needed.
 */
#define MAGNESIUM_GL_TEXTURE_RECTANGLE 0x84F5
static BOOL magnesiumZeroCopyRequested = NO;
static BOOL magnesiumZeroCopyActive = NO;
static IOSurfaceRef magnesiumSurfaceColor = NULL;
static IOSurfaceRef magnesiumSurfaceDepth = NULL;
static id<MTLTexture> magnesiumCapAux = nil;

/*
 * Split submission (zero-copy frames only): the solid and cutout passes are
 * committed as soon as they finish so the GPU works while the CPU builds the
 * rest of the frame. The translucent pass continues in a second command buffer
 * that loads the same attachments, and endChunkFrame waits only on that one.
 */
static BOOL magnesiumFrameSplit = NO;
static id<MTLCommandBuffer> magnesiumFirstHalf = nil;

static IOSurfaceRef MagnesiumCreateSurface(NSUInteger w, NSUInteger h) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(w),
        (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(((w * 4 + 63) / 64) * 64),
        (id)kIOSurfacePixelFormat: @(0x42475241) /* 'BGRA' */
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static void MagnesiumReleaseSurfaces(void) {
    if (magnesiumSurfaceColor != NULL) { CFRelease(magnesiumSurfaceColor); magnesiumSurfaceColor = NULL; }
    if (magnesiumSurfaceDepth != NULL) { CFRelease(magnesiumSurfaceDepth); magnesiumSurfaceDepth = NULL; }
}

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
     "// Solid and cutout are not blended in vanilla, so their alpha must not leave\n"
     "// the pass (the GL composite treats color as premultiplied).\n"
     "constant bool kForceOpaque [[function_constant(1)]];\n"
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
     "    float4 position [[position, invariant]];\n"
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
     "struct ChunkFragOut {\n"
     "    float4 color [[color(0)]];\n"
     "    // 24-bit depth packed into RGB for the zero-copy composite.\n"
     "    float4 depth [[color(1)]];\n"
     "};\n"
     "\n"
     "fragment ChunkFragOut chunkFragment(\n"
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
     "    if (is_function_constant_defined(kForceOpaque) && kForceOpaque) {\n"
     "        diffuse.a = 1.0f;\n"
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
     "    ChunkFragOut out;\n"
     "    out.color = diffuse;\n"
     "    uint d24 = uint(clamp(in.position.z, 0.0f, 1.0f) * 16777215.0f + 0.5f);\n"
     "    out.depth = float4(float((d24 >> 16u) & 0xFFu),\n"
     "                       float((d24 >> 8u) & 0xFFu),\n"
     "                       float(d24 & 0xFFu), 255.0f) / 255.0f;\n"
     "    return out;\n"
     "}\n";

static BOOL MagnesiumEnsureChunkPipeline(void) {
    if (magnesiumChunkPipelines[MagnesiumPassTranslucent] != nil) {
        return YES;
    }

    NSError *error = nil;
    /* Coplanar overlay quads (grass sides, dripstone) need bit-identical
     * positions across draws, so no fast-math reassociation. */
    MTLCompileOptions *compileOptions = [[MTLCompileOptions alloc] init];
    compileOptions.fastMathEnabled = NO;
    compileOptions.preserveInvariance = YES;
    id<MTLLibrary> library =
        [magnesiumDevice newLibraryWithSource:kMagnesiumChunkMSL
                                      options:compileOptions
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
        BOOL forceOpaque = !translucent;
        [constants setConstantValue:&forceOpaque
                               type:MTLDataTypeBool
                            atIndex:1];

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
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.colorAttachments[1].pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.colorAttachments[1].blendingEnabled = NO;
        /* Translucent geometry does not write depth. */
        desc.colorAttachments[1].writeMask =
            translucent ? MTLColorWriteMaskNone : MTLColorWriteMaskAll;
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

/* Opens the continuation encoder after the first half was committed. */
static BOOL MagnesiumReopenEncoder(void) {
    if (!magnesiumFrameSplit) {
        return NO;
    }
    if (magnesiumCapEncoder != nil) {
        return YES;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = magnesiumCapColor;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[1].texture = magnesiumCapAux;
    pass.colorAttachments[1].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[1].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = magnesiumCapDepth;
    pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    magnesiumCapCommandBuffer = [magnesiumCommandQueue commandBuffer];
    magnesiumCapEncoder = [magnesiumCapCommandBuffer renderCommandEncoderWithDescriptor:pass];
    if (magnesiumCapEncoder == nil) {
        return NO;
    }
    [magnesiumCapEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [magnesiumCapEncoder setCullMode:magnesiumCullBackFaces ? MTLCullModeBack : MTLCullModeNone];
    MagnesiumApplyPassState();
    return YES;
}

static void MagnesiumSetCapMatrices(const jfloat *mvp) {
    if (mvp != NULL) {
        memcpy(magnesiumCapMvp, mvp, sizeof(magnesiumCapMvp));
    }
}

static void MagnesiumResetCaptureState(void) {
    magnesiumCapEncoder = nil;
    magnesiumCapCommandBuffer = nil;
    magnesiumFrameSplit = NO;
    magnesiumFirstHalf = nil;
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


/*
 * macOS menu bar integration.
 *
 * GLFW builds a default menu bar titled after the process ("java"). This
 * renames it to the requested app name and adds a "Magnesium" menu. Menu
 * actions never call into Java directly: they set bits in an atomic mask that
 * the Java client tick drains with pollMenuActions(), and check marks are
 * driven by states Java pushes through setMenuState().
 */
enum {
    MagnesiumMenuToggleMetalRender = 0,
    MagnesiumMenuToggleDisableGl = 1,
    MagnesiumMenuCaptureFrame = 2,
    MagnesiumMenuToggleOverlay = 3,
    MagnesiumMenuToggleFpsLog = 4,
    MagnesiumMenuActionCount = 5
};

static std::atomic<int32_t> magnesiumMenuPending(0);
static BOOL magnesiumMenuStates[MagnesiumMenuActionCount] = { NO, NO, NO, NO, NO };
static NSString *magnesiumMenuGameDir = nil;
static NSString *magnesiumMenuConfigDir = nil;
static NSString *magnesiumMenuVersion = nil;
static BOOL magnesiumMenuInstalled = NO;

@interface MagnesiumMenuTarget : NSObject
- (void)fire:(NSMenuItem *)item;
- (void)showGameFolder:(id)sender;
- (void)showConfigFolder:(id)sender;
- (void)showAbout:(id)sender;
@end

@implementation MagnesiumMenuTarget

- (void)fire:(NSMenuItem *)item {
    if (item.tag >= 0 && item.tag < MagnesiumMenuActionCount) {
        magnesiumMenuPending.fetch_or(1 << item.tag);
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.tag >= 0 && item.tag < MagnesiumMenuActionCount &&
        item.tag != MagnesiumMenuCaptureFrame) {
        item.state = magnesiumMenuStates[item.tag] ? NSControlStateValueOn
                                                   : NSControlStateValueOff;
    }
    return YES;
}

- (void)showGameFolder:(id)sender {
    if (magnesiumMenuGameDir != nil) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:magnesiumMenuGameDir]];
    }
}

- (void)showConfigFolder:(id)sender {
    if (magnesiumMenuConfigDir != nil) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:magnesiumMenuConfigDir]];
    }
}

- (void)showAbout:(id)sender {
    NSDictionary *options = @{
        @"ApplicationName": @"Magnesium",
        @"ApplicationVersion": magnesiumMenuVersion ?: @"dev",
        @"Version": @"",
        @"Credits": [[NSAttributedString alloc]
            initWithString:@"An experimental Metal rendering backend for Sodium on macOS."]
    };
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

@end

static MagnesiumMenuTarget *magnesiumMenuTarget = nil;

static NSMenuItem *MagnesiumAddItem(NSMenu *menu, NSString *title, SEL action, NSInteger tag) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = magnesiumMenuTarget;
    item.tag = tag;
    [menu addItem:item];
    return item;
}

/*
 * Runs on the AppKit main thread. Returns NO if GLFW has not created the main
 * menu yet, so the caller can retry.
 */
static BOOL MagnesiumInstallMenuBar(NSString *appName) {
    @autoreleasepool {
        if (magnesiumMenuInstalled) {
            return YES;
        }
        NSMenu *mainMenu = NSApp.mainMenu;
        if (mainMenu == nil || mainMenu.numberOfItems == 0) {
            return NO;
        }

        NSString *oldName = [[NSProcessInfo processInfo] processName];

        /* The bold title in the menu bar comes from the bundle name. */
        [[NSProcessInfo processInfo] setProcessName:appName];
        NSMutableDictionary *info =
            (NSMutableDictionary *)[[NSBundle mainBundle] infoDictionary];
        if ([info isKindOfClass:[NSMutableDictionary class]]) {
            info[@"CFBundleName"] = appName;
            info[@"CFBundleDisplayName"] = appName;
        }

        /* Rename the app menu and its "About java" / "Hide java" / "Quit java" items. */
        NSMenuItem *appItem = [mainMenu itemAtIndex:0];
        appItem.title = appName;
        NSMenu *appMenu = appItem.submenu;
        if (appMenu != nil) {
            appMenu.title = appName;
            if (oldName.length > 0 && ![oldName isEqualToString:appName]) {
                for (NSMenuItem *item in appMenu.itemArray) {
                    if ([item.title rangeOfString:oldName].location != NSNotFound) {
                        item.title = [item.title stringByReplacingOccurrencesOfString:oldName
                                                                           withString:appName];
                    }
                }
            }
        }

        magnesiumMenuTarget = [[MagnesiumMenuTarget alloc] init];

        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Magnesium"];
        menu.autoenablesItems = YES;
        MagnesiumAddItem(menu, @"Metal Terrain Rendering (Experimental)",
                         @selector(fire:), MagnesiumMenuToggleMetalRender);
        MagnesiumAddItem(menu, @"Disable OpenGL Terrain Draw (Experimental)",
                         @selector(fire:), MagnesiumMenuToggleDisableGl);
        [menu addItem:[NSMenuItem separatorItem]];
        MagnesiumAddItem(menu, @"Capture Metal Frame to PNG",
                         @selector(fire:), MagnesiumMenuCaptureFrame);
        [menu addItem:[NSMenuItem separatorItem]];
        MagnesiumAddItem(menu, @"F3 Overlay Info",
                         @selector(fire:), MagnesiumMenuToggleOverlay);
        MagnesiumAddItem(menu, @"Framerate Logging",
                         @selector(fire:), MagnesiumMenuToggleFpsLog);
        [menu addItem:[NSMenuItem separatorItem]];
        MagnesiumAddItem(menu, @"Show Game Folder", @selector(showGameFolder:), 100);
        MagnesiumAddItem(menu, @"Show Config Folder", @selector(showConfigFolder:), 101);
        [menu addItem:[NSMenuItem separatorItem]];
        MagnesiumAddItem(menu, @"About Magnesium", @selector(showAbout:), 102);

        NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Magnesium"
                                                      action:nil
                                               keyEquivalent:@""];
        root.submenu = menu;

        /* Keep GLFW's trailing Window menu last. */
        NSInteger index = mainMenu.numberOfItems;
        if (index > 1) {
            index -= 1;
        }
        [mainMenu insertItem:root atIndex:index];

        magnesiumMenuInstalled = YES;
        NSLog(@"[Magnesium] Menu bar installed (app name '%@', was '%@').", appName, oldName);
        return YES;
    }
}

/* Retries every 0.5s for up to 30s while GLFW is still starting up. */
static void MagnesiumInstallMenuBarWithRetry(NSString *appName, int attemptsLeft) {
    if (MagnesiumInstallMenuBar(appName)) {
        return;
    }
    if (attemptsLeft <= 0) {
        NSLog(@"[Magnesium] Menu bar: gave up, no main menu appeared.");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MagnesiumInstallMenuBarWithRetry(appName, attemptsLeft - 1);
    });
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

/* Uploads RGBA8 pixels into a sub-rectangle of one mip level. */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_uploadTextureRegion(
    JNIEnv *env,
    jclass clazz,
    jint slot,
    jint level,
    jint x,
    jint y,
    jint width,
    jint height,
    jobject src
) {
    @autoreleasepool {
        id<MTLTexture> texture = (slot == 0) ? magnesiumBlockTexture
                               : (slot == 1) ? magnesiumLightTexture : nil;
        if (texture == nil || src == NULL || level < 0 || x < 0 || y < 0 ||
            width <= 0 || height <= 0 ||
            (NSUInteger)level >= texture.mipmapLevelCount) {
            return;
        }
        NSUInteger mipW = MAX((NSUInteger)1, texture.width >> level);
        NSUInteger mipH = MAX((NSUInteger)1, texture.height >> level);
        if ((NSUInteger)(x + width) > mipW || (NSUInteger)(y + height) > mipH) {
            return;
        }
        void *base = env->GetDirectBufferAddress(src);
        jlong cap = (jlong)env->GetDirectBufferCapacity(src);
        if (base == NULL || cap < (jlong)width * height * 4) {
            return;
        }
        [texture replaceRegion:MTLRegionMake2D((NSUInteger)x, (NSUInteger)y,
                                               (NSUInteger)width, (NSUInteger)height)
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

        BOOL wantZeroCopy = magnesiumFrameMode && magnesiumZeroCopyRequested;
        if ((NSUInteger)width != magnesiumCapWidth ||
            (NSUInteger)height != magnesiumCapHeight ||
            magnesiumCapColor == nil ||
            wantZeroCopy != magnesiumZeroCopyActive) {
            MagnesiumReleaseSurfaces();
            magnesiumCapColor = nil;
            magnesiumCapAux = nil;

            MTLTextureDescriptor *colorDesc =
                [[MTLTextureDescriptor alloc] init];
            colorDesc.pixelFormat = MTLPixelFormatBGRA8Unorm;
            colorDesc.width = (NSUInteger)width;
            colorDesc.height = (NSUInteger)height;
            colorDesc.usage =
                MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

            if (wantZeroCopy) {
                magnesiumSurfaceColor = MagnesiumCreateSurface(width, height);
                magnesiumSurfaceDepth = MagnesiumCreateSurface(width, height);
                if (magnesiumSurfaceColor != NULL && magnesiumSurfaceDepth != NULL) {
                    magnesiumCapColor =
                        [magnesiumDevice newTextureWithDescriptor:colorDesc
                                                        iosurface:magnesiumSurfaceColor
                                                            plane:0];
                    magnesiumCapAux =
                        [magnesiumDevice newTextureWithDescriptor:colorDesc
                                                        iosurface:magnesiumSurfaceDepth
                                                            plane:0];
                }
                if (magnesiumCapColor == nil || magnesiumCapAux == nil) {
                    NSLog(@"[Magnesium] IOSurface targets failed; using readback.");
                    MagnesiumReleaseSurfaces();
                    magnesiumCapColor = nil;
                    magnesiumCapAux = nil;
                    wantZeroCopy = NO;
                    magnesiumZeroCopyRequested = NO;
                }
            }
            if (magnesiumCapColor == nil) {
                magnesiumCapColor =
                    [magnesiumDevice newTextureWithDescriptor:colorDesc];
                magnesiumCapAux =
                    [magnesiumDevice newTextureWithDescriptor:colorDesc];
            }
            magnesiumZeroCopyActive = wantZeroCopy;

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
            magnesiumFrameColorBuf = nil;
            magnesiumFrameDepthBuf = nil;
        }

        if (magnesiumFrameMode && !magnesiumZeroCopyActive &&
            magnesiumFrameColorBuf == nil) {
            NSUInteger bytes = magnesiumCapWidth * magnesiumCapHeight * 4;
            magnesiumFrameColorBuf =
                [magnesiumDevice newBufferWithLength:bytes
                                             options:MTLResourceStorageModeShared];
            magnesiumFrameDepthBuf =
                [magnesiumDevice newBufferWithLength:bytes
                                             options:MTLResourceStorageModeShared];
            if (magnesiumFrameColorBuf == nil || magnesiumFrameDepthBuf == nil) {
                NSLog(@"[Magnesium] frame readback buffers failed (%lu bytes).",
                      (unsigned long)bytes);
                return JNI_FALSE;
            }
        }

        if (magnesiumCapColor == nil || magnesiumCapAux == nil || magnesiumCapDepth == nil) {
            return JNI_FALSE;
        }

        if (magnesiumCapEncoder != nil) {
            [magnesiumCapEncoder endEncoding];
        }
        magnesiumFrameSplit = NO;
        magnesiumFirstHalf = nil;

        MTLRenderPassDescriptor *pass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = magnesiumCapColor;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = magnesiumFrameMode
            ? MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
            : MTLClearColorMake(0.30, 0.55, 0.70, 1.0);
        pass.colorAttachments[1].texture = magnesiumCapAux;
        pass.colorAttachments[1].loadAction = MTLLoadActionClear;
        pass.colorAttachments[1].storeAction = MTLStoreActionStore;
        pass.colorAttachments[1].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
        pass.depthAttachment.texture = magnesiumCapDepth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction =
            magnesiumFrameMode ? MTLStoreActionStore : MTLStoreActionDontCare;
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
        if (magnesiumCaptureOpen && magnesiumCapEncoder == nil) {
            MagnesiumReopenEncoder();
        }
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

        if (magnesiumCapSubDraws == 0L && !magnesiumFrameMode) {
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

        /* Sodium emits one draw per visible face range of a section. Ranges that are
         * adjacent in the arena (next base == this base + its quads * 4 vertices) and
         * share the quad index buffer produce exactly the same triangles as one
         * larger draw, so merge them to cut the number of encoded draw calls. */
        const NSUInteger indexStride = (indexType == MTLIndexTypeUInt16) ? 2u : 4u;
        int32_t runBase = 0;
        int64_t runCount = 0;
        auto emit = [&]() {
            if (runCount <= 0) {
                return;
            }
            /* Never encode a draw that reads outside the mirrors: Sodium's batches are
             * quad lists, so the highest vertex touched is base + (count / 6) * 4. */
            uint64_t indexBytes = (uint64_t)runCount * indexStride;
            uint64_t vertexEnd = ((uint64_t)(runBase < 0 ? 0 : runBase) + (uint64_t)(runCount / 6) * 4u) * 20u;
            if (runBase < 0 || indexBytes > indexBuffer.length || vertexEnd > vertexBuffer.length) {
                if (magnesiumSkippedDraws++ < 5) {
                    NSLog(@"[Magnesium] skipped out-of-range draw: count=%lld base=%d "
                          "(index mirror %lu bytes, vertex mirror %lu bytes)",
                          (long long)runCount, runBase, (unsigned long)indexBuffer.length,
                          (unsigned long)vertexBuffer.length);
                }
            } else {
                [magnesiumCapEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                                indexCount:(NSUInteger)runCount
                                                 indexType:indexType
                                               indexBuffer:indexBuffer
                                         indexBufferOffset:0
                                             instanceCount:1
                                                baseVertex:runBase
                                              baseInstance:0];
                magnesiumCapIndices += (uint64_t)runCount;
            }
            runCount = 0;
        };

        for (int i = 0; i < elementCount; i++) {
            int32_t count = counts[i];
            int32_t base = bases[i];
            if (count <= 0) {
                continue;
            }
            if (runCount > 0 && (runCount % 6) == 0 && (count % 6) == 0 &&
                (int64_t)base == (int64_t)runBase + (runCount / 6) * 4 &&
                runCount + count < INT32_MAX) {
                runCount += count;
                continue;
            }
            emit();
            runBase = base;
            runCount = count;
        }
        emit();
        magnesiumCapSubDraws += elementCount;
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_setChunkFrameMode(
    JNIEnv *env,
    jclass clazz,
    jboolean frameMode
) {
    magnesiumFrameMode = (frameMode == JNI_TRUE) ? YES : NO;
}

/*
 * Ends a frame-mode capture: commits the pass, blits color and depth into the
 * shared readback buffers, and waits for the GPU. Returns false if nothing
 * usable was produced.
 */
JNIEXPORT jint JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_endChunkFrame(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {
        BOOL haveTail = (magnesiumCapEncoder != nil && magnesiumCapCommandBuffer != nil);
        BOOL haveHead = (magnesiumFrameSplit && magnesiumFirstHalf != nil);
        if (!magnesiumCaptureOpen ||
            (!haveTail && !haveHead) ||
            (!magnesiumZeroCopyActive &&
             (magnesiumFrameColorBuf == nil || magnesiumFrameDepthBuf == nil))) {
            MagnesiumResetCaptureState();
            return 0;
        }

        id<MTLCommandBuffer> last = magnesiumFirstHalf;
        if (haveTail) {
            [magnesiumCapEncoder endEncoding];

            NSUInteger w = magnesiumCapWidth;
            NSUInteger h = magnesiumCapHeight;
            if (!magnesiumZeroCopyActive) {
                id<MTLBlitCommandEncoder> blit = [magnesiumCapCommandBuffer blitCommandEncoder];
                [blit copyFromTexture:magnesiumCapColor
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(w, h, 1)
                             toBuffer:magnesiumFrameColorBuf
                    destinationOffset:0
               destinationBytesPerRow:w * 4
             destinationBytesPerImage:w * h * 4];
                [blit copyFromTexture:magnesiumCapDepth
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(w, h, 1)
                             toBuffer:magnesiumFrameDepthBuf
                    destinationOffset:0
               destinationBytesPerRow:w * 4
             destinationBytesPerImage:w * h * 4
                              options:MTLBlitOptionDepthFromDepthStencil];
                [blit endEncoding];
            }
            [magnesiumCapCommandBuffer commit];
            last = magnesiumCapCommandBuffer;
        }

        /* Buffers on one queue execute in order, so the last one covers both halves. */
        [last waitUntilCompleted];

        BOOL ok = (last.status == MTLCommandBufferStatusCompleted) &&
                  (magnesiumFirstHalf == nil ||
                   magnesiumFirstHalf.status == MTLCommandBufferStatusCompleted);
        if (!ok) {
            NSLog(@"[Magnesium] frame command buffer failed: %@",
                  last.error.localizedDescription ?: magnesiumFirstHalf.error.localizedDescription);
        }
        MagnesiumResetCaptureState();
        return !ok ? 0 : (magnesiumZeroCopyActive ? 2 : 1);
    }
}

/*
 * Commits the work encoded so far without waiting (zero-copy frame mode only),
 * so the GPU can start on the solid and cutout passes. Later draws continue in
 * a second command buffer. Returns false if nothing was committed.
 */
JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_flushChunkFrame(
    JNIEnv *env,
    jclass clazz
) {
    @autoreleasepool {
        if (!magnesiumCaptureOpen || !magnesiumFrameMode || !magnesiumZeroCopyActive ||
            magnesiumFrameSplit || magnesiumCapEncoder == nil ||
            magnesiumCapCommandBuffer == nil) {
            return JNI_FALSE;
        }
        [magnesiumCapEncoder endEncoding];
        [magnesiumCapCommandBuffer commit];
        magnesiumFirstHalf = magnesiumCapCommandBuffer;
        magnesiumCapEncoder = nil;
        magnesiumCapCommandBuffer = nil;
        magnesiumFrameSplit = YES;
        return JNI_TRUE;
    }
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_setFrameZeroCopy(
    JNIEnv *env,
    jclass clazz,
    jboolean zeroCopy
) {
    magnesiumZeroCopyRequested = (zeroCopy == JNI_TRUE) ? YES : NO;
}

/*
 * Binds an IOSurface (0 = color, 1 = packed depth) to the GL rectangle texture
 * currently bound on the calling thread's CGL context. Must be re-run after
 * every frame the surface is rewritten.
 */
JNIEXPORT jboolean JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_bindFrameSurface(
    JNIEnv *env,
    jclass clazz,
    jint which
) {
    IOSurfaceRef surface = (which == 0) ? magnesiumSurfaceColor : magnesiumSurfaceDepth;
    CGLContextObj ctx = CGLGetCurrentContext();
    if (surface == NULL || ctx == NULL || !magnesiumZeroCopyActive) {
        return JNI_FALSE;
    }
    CGLError err = CGLTexImageIOSurface2D(
        ctx, MAGNESIUM_GL_TEXTURE_RECTANGLE, GL_RGBA,
        (GLsizei)IOSurfaceGetWidth(surface), (GLsizei)IOSurfaceGetHeight(surface),
        GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surface, 0);
    if (err != kCGLNoError) {
        NSLog(@"[Magnesium] CGLTexImageIOSurface2D failed: %s", CGLErrorString(err));
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

/* Address of the shared readback buffer: 0 = color (RGBA8), 1 = depth (R32F). */
JNIEXPORT jlong JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_frameBufferAddress(
    JNIEnv *env,
    jclass clazz,
    jint which
) {
    id<MTLBuffer> buffer = (which == 0) ? magnesiumFrameColorBuf : magnesiumFrameDepthBuf;
    return (buffer == nil) ? 0 : (jlong)(intptr_t)[buffer contents];
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

        if (pixels != NULL) {
            uint8_t *q = (uint8_t *)pixels;
            for (NSUInteger i = 0; i < w * h; i++, q += 4) {
                uint8_t t = q[0]; q[0] = q[2]; q[2] = t; /* BGRA -> RGBA */
            }
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


JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_installMenuBar(
    JNIEnv *env,
    jclass clazz,
    jstring appName,
    jstring version,
    jstring gameDir,
    jstring configDir
) {
    auto toNS = [&](jstring str) -> NSString * {
        if (str == NULL) {
            return nil;
        }
        const char *chars = env->GetStringUTFChars(str, NULL);
        if (chars == NULL) {
            return nil;
        }
        NSString *result = [NSString stringWithUTF8String:chars];
        env->ReleaseStringUTFChars(str, chars);
        return result;
    };

    NSString *name = toNS(appName) ?: @"Minecraft";
    magnesiumMenuVersion = toNS(version);
    magnesiumMenuGameDir = toNS(gameDir);
    magnesiumMenuConfigDir = toNS(configDir);

    dispatch_async(dispatch_get_main_queue(), ^{
        MagnesiumInstallMenuBarWithRetry(name, 60);
    });
}

/* Drains and returns the bitmask of menu actions chosen since the last call. */
JNIEXPORT jint JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_pollMenuActions(
    JNIEnv *env,
    jclass clazz
) {
    return (jint)magnesiumMenuPending.exchange(0);
}

JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_setMenuState(
    JNIEnv *env,
    jclass clazz,
    jint action,
    jboolean on
) {
    if (action >= 0 && action < MagnesiumMenuActionCount) {
        magnesiumMenuStates[action] = (on == JNI_TRUE) ? YES : NO;
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

/*
 * Re-applies the " - Magnesium" title suffix on the main thread. Minecraft
 * resets the window title (e.g. when entering a world), which drops it.
 * Idempotent, so it is safe to call repeatedly.
 */
JNIEXPORT void JNICALL
Java_turkfork_magnesium_client_renderer_MetalBridge_refreshWindowTitle(
    JNIEnv *env,
    jclass clazz
) {
    if (magnesiumWindow == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        MagnesiumAppendWindowSuffix();
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
        if (getenv("MAGNESIUM_VERBOSE") != NULL) {
            NSLog(@"[Magnesium] createBuffer: size=%lld handle=%lld",
                  (long long)size, (long long)handle);
        }
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
        magnesiumFrameColorBuf = nil;
        magnesiumFrameDepthBuf = nil;
        MagnesiumReleaseSurfaces();
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
