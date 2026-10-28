package turkfork.magnesium.client.renderer;

import turkfork.magnesium.client.renderer.device.MagnesiumRenderDevice;

import java.util.List;

/**
 * Builds the Magnesium section shown in Minecraft's F3 debug overlay (the left
 * text). The block has its own title bar and aligned label/value rows so it
 * reads cleanly alongside the vanilla sections. Reads live state from the Metal
 * translation layer without touching Sodium's internals.
 */
public final class MagnesiumDebugInfo {

    private static final String TITLE_BAR =
            "\u00a77---------------[ \u00a7rMagnesium \u00a75(Metal)\u00a7r \u00a77]----------------";

    private MagnesiumDebugInfo() {
    }

    /** Appends the Magnesium section to the F3 overlay's left-hand list. */
    public static void appendTo(List<String> list) {
        MagnesiumRenderDevice device = MagnesiumDeviceInstaller.getDevice();
        boolean enabled = MagnesiumDeviceInstaller.isEnabled();

        list.add("");
        list.add(TITLE_BAR);
        list.add(row("Translation", enabled ? "\u00a7aENABLED" : "\u00a7cdisabled"));

        if (!enabled) {
            list.add("    \u00a77Add \u00a7f-Dmagnesium.metal.enabled=true");
            list.add("    \u00a77Sodium keeps rendering via OpenGL.");
            return;
        }

        if (device == null) {
            list.add("    \u00a7cDevice not installed yet (first tick pending).");
            list.add("    \u00a74Status code: 0xDEADBEEF");
            appendCloseBar(list);
            return;
        }

        list.add(row("GPU", "\u00a7f" + nominal(MetalBridge.getDeviceName(), "unknown")));

        list.add(row("MTLBuffers", "\u00a7f" + device.getMetalBufferCount()));
        list.add(row("Buffer size", "\u00a7f" + bytes(device.getMetalBufferBytes())));
        list.add(row("Draws", "\u00a7f" + device.getDrawCount() + " batches"));

        if (MetalBridge.isWindowDiscovered()) {
            list.add(row("Window", "\u00a7f" + MetalBridge.getWindowDescription()));
        } else {
            list.add(row("Window", "\u00a78not discovered"));
        }

        if (MetalBridge.isLayerAttached()) {
            list.add(row("Layer", "\u00a7f" + MetalBridge.getLayerInfo()));
        }

        appendCloseBar(list);
    }

    private static void appendCloseBar(List<String> list) {
        list.add("\u00a77------------------------------------------------------");
    }

    /** Pads the label to a fixed width so the values line up in a column. */
    private static String row(String label, String value) {
        String pad = " ".repeat(Math.max(0, 16 - label.length()));
        return "    \u00a77" + label + ":" + pad + value;
    }

    private static String nominal(String value, String fallback) {
        return (value == null || value.isBlank()) ? fallback : value;
    }

    private static String bytes(long value) {
        if (value >= 1024L * 1024L * 1024L) {
            return String.format("%.2f GiB", value / (1024.0 * 1024.0 * 1024.0));
        }
        if (value >= 1024L * 1024L) {
            return String.format("%.2f MiB", value / (1024.0 * 1024.0));
        }
        if (value >= 1024L) {
            return String.format("%.2f KiB", value / 1024.0);
        }
        return value + " B";
    }
}