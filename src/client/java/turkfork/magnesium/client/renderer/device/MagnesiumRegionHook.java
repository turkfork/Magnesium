package turkfork.magnesium.client.renderer.device;

/**
 * Captures the {@code u_RegionOffset} source value (the current render region's
 * world-space origin in block coordinates) that Sodium applies right before a
 * chunk draw batch executes. Sodium reads this from
 * {@code ChunkShaderInterface.setRegionOffset(...)} via
 * {@code DefaultChunkRenderer.setModelMatrixUniforms}, which is mixed into by
 * {@link turkfork.magnesium.client.mixin.DefaultChunkRendererMixin} — no GL
 * state reads are needed, so this is safe to call mid-pipeline even when Iris
 * has its own program bound.
 *
 * <p>All reads and writes happen on the render thread, immediately adjacent to
 * Sodium's own uniform setup, so synchronization is unnecessary.
 */
public final class MagnesiumRegionHook {

    private static final float[] ORIGIN = new float[3];

    private MagnesiumRegionHook() {
    }

    public static void captureOrigin(float x, float y, float z) {
        ORIGIN[0] = x;
        ORIGIN[1] = y;
        ORIGIN[2] = z;
    }

    public static float[] origin() {
        return ORIGIN.clone();
    }
}