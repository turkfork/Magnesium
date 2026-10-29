package turkfork.magnesium.client.renderer.device;

import java.lang.reflect.Method;

/**
 * Compatibility checks for other rendering mods. Everything is looked up
 * reflectively so Magnesium has no compile-time dependency on them.
 */
final class MagnesiumCompat {

    private static final long CACHE_NANOS = 500_000_000L;

    private static Object irisApi;
    private static Method irisShaderPackInUse;
    private static boolean irisResolved = false;

    private static boolean cachedShaderPack = false;
    private static long cachedAt = 0L;
    private static boolean warned = false;

    private MagnesiumCompat() {
    }

    /**
     * Iris replaces Sodium's terrain shader and render targets while a shader
     * pack is active, so the Metal terrain (which ports Sodium's own shader)
     * would be wrong. In that case Sodium's OpenGL path is left to draw.
     */
    static boolean shaderPackActive() {
        long now = System.nanoTime();
        if (cachedAt != 0L && now - cachedAt < CACHE_NANOS) {
            return cachedShaderPack;
        }
        cachedAt = now;
        boolean active = queryIris();
        if (active && !warned) {
            warned = true;
            System.out.println("[Magnesium] An Iris shader pack is active; Metal terrain is paused.");
        } else if (!active) {
            warned = false;
        }
        cachedShaderPack = active;
        return active;
    }

    private static boolean queryIris() {
        if (!irisResolved) {
            irisResolved = true;
            try {
                Class<?> api = Class.forName("net.irisshaders.iris.api.v0.IrisApi");
                irisApi = api.getMethod("getInstance").invoke(null);
                irisShaderPackInUse = api.getMethod("isShaderPackInUse");
            } catch (Throwable t) {
                irisApi = null; // Iris is not installed
            }
        }
        if (irisApi == null || irisShaderPackInUse == null) {
            return false;
        }
        try {
            return (Boolean) irisShaderPackInUse.invoke(irisApi);
        } catch (Throwable t) {
            return false;
        }
    }
}
