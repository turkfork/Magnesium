package turkfork.magnesium.client.renderer;

import net.minecraft.client.Minecraft;
import turkfork.magnesium.client.renderer.device.MagnesiumRenderDevice;

/**
 * Periodically logs the current frame rate to the console.
 *
 * <p>Enabled with {@code -Dmagnesium.fps.log=true}. The logging interval can be
 * tuned with {@code -Dmagnesium.fps.log.period=N} seconds (default 10). When the
 * Metal translation device is installed, the message additionally reports the
 * number of Metal buffers, Metal buffer storage bytes and translated draw calls
 * routed through Magnesium so frame-rate behaviour can be correlated with the
 * state of the translation layer.
 */
public final class MagnesiumFpsLogger {

    private static final boolean ENABLED = Boolean.getBoolean("magnesium.fps.log");

    private static final int PERIOD_SECONDS;
    private static final int PERIOD_TICKS;

    static {
        int period = 10;
        String raw = System.getProperty("magnesium.fps.log.period");
        if (raw != null) {
            try {
                period = Math.max(1, Integer.parseInt(raw.trim()));
            } catch (NumberFormatException ignored) {
                // keep the default period
            }
        }
        PERIOD_SECONDS = period;
        PERIOD_TICKS = PERIOD_SECONDS * 20;
    }

    private static boolean started = false;
    private static int tickCounter = 0;

    private MagnesiumFpsLogger() {
    }

    /**
     * Called once after the Metal bridge is initialized. Prints a one-line
     * notice when the logger is enabled so the property is visible in logs.
     */
    public static void initialize() {
        if (!ENABLED) {
            return;
        }
        started = true;
        System.out.println(
                "[Magnesium] Framerate logging enabled "
                        + "(every " + PERIOD_SECONDS + "s).");
    }

    /**
     * Called every client tick. Accumulates ticks and prints the current FPS
     * once every configured period.
     */
    public static void onTick() {
        if (!started) {
            return;
        }

        tickCounter++;

        if (tickCounter % PERIOD_TICKS != 0) {
            return;
        }

        int fps = Minecraft.getInstance().getFps();

        StringBuilder line = new StringBuilder(96);
        line.append("[Magnesium] FPS: ").append(fps);

        MagnesiumRenderDevice device = MagnesiumDeviceInstaller.getDevice();
        if (device != null) {
            line.append(" | Metal: ")
                    .append(device.getMetalBufferCount())
                    .append(" MTLBuffers, ")
                    .append(device.getMetalBufferBytes())
                    .append(" bytes | draws routed: ")
                    .append(device.getDrawCount());
        }

        System.out.println(line);
    }
}