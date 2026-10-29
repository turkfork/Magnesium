package turkfork.magnesium.client.renderer.device;

import me.jellysquid.mods.sodium.client.util.TextureUtil;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL12;
import org.lwjgl.opengl.GL13;
import org.lwjgl.system.MemoryUtil;
import turkfork.magnesium.client.renderer.MetalBridge;

import java.nio.ByteBuffer;

/**
 * Mirrors the two textures the terrain shader samples into Metal textures: the
 * block atlas ({@code u_BlockTex}, slot 0, all mip levels) and the light map
 * ({@code u_LightTex}, slot 1). The pixels are read back from the live OpenGL
 * textures (restoring the GL texture bindings afterwards), so Metal samples
 * exactly what Sodium's GL path samples.
 *
 * <p>The atlas is only re-uploaded when its GL id or dimensions change; the
 * light map is re-read on every {@link #sync()} because it is rewritten as the
 * game's light texture updates.
 */
final class MagnesiumTextureSync {

    private static final int SLOT_BLOCK = 0;
    private static final int SLOT_LIGHT = 1;

    /** Matches {@code RenderDevice.getSubTexelPrecisionBits()} on macOS. */
    private static final int SUB_TEXEL_PRECISION_BITS = 4;
    private static final double TEXCOORD_EPSILON = 3.0517578125E-5;

    private static int atlasId = -1;
    private static int atlasWidth = -1;
    private static int atlasHeight = -1;
    private static float shrinkX = 0.0f;
    private static float shrinkY = 0.0f;

    private MagnesiumTextureSync() {
    }

    static float texCoordShrinkX() {
        return shrinkX;
    }

    static float texCoordShrinkY() {
        return shrinkY;
    }

    /** @return true if both textures are available on the Metal side */
    static boolean sync() {
        int prevActive = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
        int prevBinding = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        try {
            return syncAtlas(TextureUtil.getBlockTextureId())
                    && syncLightMap(TextureUtil.getLightTextureId());
        } finally {
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, prevBinding);
            GL13.glActiveTexture(prevActive);
        }
    }

    private static boolean syncAtlas(int id) {
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, id);
        int width = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_WIDTH);
        int height = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_HEIGHT);
        if (width <= 0 || height <= 0) {
            return false;
        }
        if (id == atlasId && width == atlasWidth && height == atlasHeight) {
            return true;
        }

        int maxLevel = GL11.glGetTexParameteri(GL11.GL_TEXTURE_2D, GL12.GL_TEXTURE_MAX_LEVEL);
        int fullChain = 31 - Integer.numberOfLeadingZeros(Math.max(width, height));
        int levels = Math.min(Math.max(maxLevel, 0), fullChain) + 1;

        if (!MetalBridge.createTexture(SLOT_BLOCK, width, height, levels)) {
            return false;
        }
        for (int level = 0; level < levels; level++) {
            int w = Math.max(1, width >> level);
            int h = Math.max(1, height >> level);
            upload(SLOT_BLOCK, level, w, h);
        }

        atlasId = id;
        atlasWidth = width;
        atlasHeight = height;

        // Same expression as ChunkShaderInterface.setupState() for u_TexCoordShrink.
        double precision = 1 << SUB_TEXEL_PRECISION_BITS;
        shrinkX = (float) (TEXCOORD_EPSILON - 1.0 / width / precision);
        shrinkY = (float) (TEXCOORD_EPSILON - 1.0 / height / precision);

        System.out.println("[Magnesium] Mirrored block atlas to Metal: "
                + width + "x" + height + ", " + levels + " mip levels.");
        return true;
    }

    private static boolean syncLightMap(int id) {
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, id);
        int width = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_WIDTH);
        int height = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_HEIGHT);
        if (width <= 0 || height <= 0) {
            return false;
        }
        if (!MetalBridge.createTexture(SLOT_LIGHT, width, height, 1)) {
            return false;
        }
        upload(SLOT_LIGHT, 0, width, height);
        return true;
    }

    /** Reads the currently bound GL texture level and uploads it to Metal. */
    private static void upload(int slot, int level, int width, int height) {
        ByteBuffer pixels = MemoryUtil.memAlloc(width * height * 4);
        try {
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 1);
            GL11.glGetTexImage(GL11.GL_TEXTURE_2D, level, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, pixels);
            MetalBridge.uploadTextureLevel(slot, level, width, height, pixels);
        } finally {
            MemoryUtil.memFree(pixels);
        }
    }
}
