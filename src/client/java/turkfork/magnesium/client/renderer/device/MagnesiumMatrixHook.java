package turkfork.magnesium.client.renderer.device;

import org.joml.Matrix4f;
import org.joml.Matrix4fc;

/**
 * Captures the exact chunk-shader matrices Sodium uploads before each terrain
 * batch ({@code u_ProjectionMatrix} and {@code u_ModelViewMatrix}, fed through
 * {@code ChunkShaderInterface.setProjectionMatrix/setModelViewMatrix}). Using
 * these matrices verbatim in the Metal vertex shader reproduces Sodium's
 * {@code gl_Position} exactly, avoiding any reconstruction of the camera view
 * transform (handedness, axis conventions, or coincidental state mismatches)
 * on the Java side.
 *
 * <p>All values are written on the render thread immediately before the batch
 * draw, so no synchronization is needed.
 */
public final class MagnesiumMatrixHook {

    private static final Matrix4f PROJECTION = new Matrix4f();
    private static final Matrix4f MODEL_VIEW = new Matrix4f();
    private static final float[] COMBINED = new float[16];
    private static volatile boolean ready = false;

    private MagnesiumMatrixHook() {
    }

    public static void captureProjection(Matrix4fc projection) {
        PROJECTION.set(projection);
    }

    public static void captureModelView(Matrix4fc modelView) {
        MODEL_VIEW.set(modelView);
        Matrix4f combined = new Matrix4f(PROJECTION);
        combined.mul(MODEL_VIEW);
        combined.get(COMBINED);
        ready = true;
    }

    /** Column-major {@code projection * modelView} (matches Sodium's GLSL). */
    public static float[] combinedMvp() {
        return COMBINED.clone();
    }

    public static boolean isReady() {
        return ready;
    }
}