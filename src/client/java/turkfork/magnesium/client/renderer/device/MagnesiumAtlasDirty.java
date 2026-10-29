package turkfork.magnesium.client.renderer.device;

import com.mojang.blaze3d.platform.NativeImage;
import org.lwjgl.system.MemoryUtil;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Pixel data captured on the CPU as Minecraft rewrites the animated parts of
 * the block atlas and the light map, waiting to be mirrored to Metal.
 */
public final class MagnesiumAtlasDirty {

    /** Set while an animated sprite is uploading (see SpriteTickerMixin). */
    public static volatile boolean capturing = false;

    /** Capture only once the Metal mirror exists; otherwise nothing would drain it. */
    static volatile boolean enabled = false;

    private static final int MAX_TILES = 4096;

    record Tile(int level, int x, int y, int width, int height, ByteBuffer rgba) {
    }

    private static final List<Tile> TILES = new ArrayList<>();
    private static boolean overflow = false;
    private static ByteBuffer light = null;

    private static boolean remirror = false;

    private MagnesiumAtlasDirty() {
    }

    /** Copies a sub-rectangle of a NativeImage's RGBA pixels. */
    public static synchronized void addTile(int level, int x, int y, int width, int height,
                                            long pixels, int imageWidth, int skipX, int skipY) {
        if (!enabled || width <= 0 || height <= 0) {
            return;
        }
        if (TILES.size() >= MAX_TILES) {
            clearTiles();
            overflow = true;
            return;
        }
        ByteBuffer out = MemoryUtil.memAlloc(width * height * 4);
        for (int row = 0; row < height; row++) {
            long src = pixels + ((long) (skipY + row) * imageWidth + skipX) * 4L;
            MemoryUtil.memCopy(src, MemoryUtil.memAddress(out, row * width * 4), (long) width * 4L);
        }
        TILES.add(new Tile(level, x, y, width, height, out));
    }

    /** Copies the 16x16 light map image. */
    public static synchronized void setLight(NativeImage image) {
        if (!enabled) {
            return;
        }
        int size = image.getWidth() * image.getHeight() * 4;
        if (light == null || light.capacity() != size) {
            if (light != null) {
                MemoryUtil.memFree(light);
            }
            light = MemoryUtil.memAlloc(size);
        }
        long pixels = ((MagnesiumPixelAccess) (Object) image).magnesium$pixels();
        if (pixels == 0L) {
            return;
        }
        MemoryUtil.memCopy(pixels, MemoryUtil.memAddress(light), size);
        lightDirty = true;
    }

    private static boolean lightDirty = false;

    static synchronized List<Tile> drainTiles() {
        if (TILES.isEmpty()) {
            return List.of();
        }
        List<Tile> copy = new ArrayList<>(TILES);
        TILES.clear();
        return copy;
    }

    /** Asks for the whole atlas to be mirrored again (after a resource reload). */
    public static synchronized void requestRemirror() {
        remirror = true;
    }

    /** @return true once if tiles were dropped and the atlas must be mirrored again */
    static synchronized boolean takeOverflow() {
        boolean o = overflow || remirror;
        overflow = false;
        remirror = false;
        return o;
    }

    /** @return the pending light map pixels (valid until the next call), or null */
    static synchronized ByteBuffer takeLight() {
        if (!lightDirty) {
            return null;
        }
        lightDirty = false;
        return light;
    }

    static synchronized void clearTiles() {
        for (Tile t : TILES) {
            MemoryUtil.memFree(t.rgba());
        }
        TILES.clear();
    }
}
