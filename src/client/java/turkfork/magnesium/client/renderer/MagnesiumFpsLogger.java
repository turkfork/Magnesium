package turkfork.magnesium.client.renderer;

import net.minecraft.client.Minecraft;
import turkfork.magnesium.client.renderer.device.MagnesiumRenderDevice;
import static turkfork.magnesium.client.renderer.options.MagnesiumOptionPages.OPTIONS;

/**
 * Periodically logs the current frame rate to the console.
 *
 * <p>Toggled and tuned from the Magnesium page in Sodium's settings; the initial
 * values come from {@code -Dmagnesium.fps.log=true} and
 * {@code -Dmagnesium.fps.log.period=N} seconds (default 10). When the
 * Metal translation device is installed, the message additionally reports the
 * number of Metal buffers, Metal buffer storage bytes and translated draw calls
 * routed through Magnesium so frame-rate behaviour can be correlated with the
 * state of the translation layer.
 */
public final class MagnesiumFpsLogger {

    private static int tickCounter = 0;

    private MagnesiumFpsLogger() {
    }

    /**
     * Called once after the Metal bridge is initialized. Prints a one-line
     * notice when the logger is enabled so the property is visible in logs.
     */
    public static void initialize() {
        if (OPTIONS.isFpsLogging()) {
            System.out.println(
                    "[Magnesium] Framerate logging enabled "
                            + "(every " + OPTIONS.getFpsLogPeriodSeconds() + "s).");
        }
    }

    /**
     * Called every client tick. Accumulates ticks and prints the current FPS
     * once every configured period.
     */
    public static void onTick() {
        // Read live so the Sodium settings page takes effect immediately.
        if (!OPTIONS.isFpsLogging()) {
            tickCounter = 0;
            return;
        }

        tickCounter++;

        if (tickCounter < OPTIONS.getFpsLogPeriodSeconds() * 20) {
            return;
        }
        tickCounter = 0;

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