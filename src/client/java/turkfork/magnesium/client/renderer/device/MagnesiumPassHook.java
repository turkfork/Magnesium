package turkfork.magnesium.client.renderer.device;

import com.mojang.blaze3d.systems.RenderSystem;
import me.jellysquid.mods.sodium.client.render.chunk.terrain.TerrainRenderPass;
import turkfork.magnesium.client.renderer.MagnesiumDeviceInstaller;
import turkfork.magnesium.client.renderer.MetalBridge;

/**
 * Tracks which Sodium terrain pass is currently being drawn and gathers the
 * pass-wide shader state (fog, texcoord shrink) that the Metal chunk pipeline
 * needs. Written from {@code DefaultChunkRenderer.render} via
 * {@link turkfork.magnesium.client.mixin.DefaultChunkRendererMixin}, always on
 * the render thread, so no synchronization is needed.
 */
public final class MagnesiumPassHook {

    public static final int SOLID = 0;
    public static final int CUTOUT = 1;
    public static final int TRANSLUCENT = 2;

    private static final float[] PARAMS = new float[9];
    private static int kind = SOLID;
    private static boolean active = false;

    private MagnesiumPassHook() {
    }

    /**
     * Sodium's passes: SOLID (no discard), CUTOUT (fragment discard) and
     * TRANSLUCENT (the only reverse-order pass).
     */
    public static void beginPass(TerrainRenderPass pass) {
        if (pass.isReverseOrder()) {
            kind = TRANSLUCENT;
        } else if (pass.supportsFragmentDiscard()) {
            kind = CUTOUT;
        } else {
            kind = SOLID;
        }
        active = true;

        MagnesiumRenderDevice device = MagnesiumDeviceInstaller.getDevice();
        if (device != null) {
            device.onPassBegin(kind);
        }
    }

    public static void endPass() {
        active = false;
        MagnesiumRenderDevice device = MagnesiumDeviceInstaller.getDevice();
        if (device != null) {
            device.onPassEnd(kind);
        }
    }

    public static int kind() {
        return kind;
    }

    public static boolean isActive() {
        return active;
    }

    /**
     * Pushes the current pass kind and the fog / texcoord-shrink uniforms to
     * the native side. Fog values are read from {@link RenderSystem} exactly
     * as Sodium's {@code ChunkShaderFogComponent.Smooth.setup()} does.
     */
    static void pushPassState() {
        float[] fogColor = RenderSystem.getShaderFogColor();
        PARAMS[0] = fogColor[0];
        PARAMS[1] = fogColor[1];
        PARAMS[2] = fogColor[2];
        PARAMS[3] = fogColor[3];
        PARAMS[4] = RenderSystem.getShaderFogStart();
        PARAMS[5] = RenderSystem.getShaderFogEnd();
        PARAMS[6] = RenderSystem.getShaderFogShape().getIndex();
        PARAMS[7] = MagnesiumTextureSync.texCoordShrinkX();
        PARAMS[8] = MagnesiumTextureSync.texCoordShrinkY();
        MetalBridge.setChunkPassState(kind, PARAMS);
    }
}
