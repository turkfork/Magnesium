package turkfork.magnesium.client.renderer;

import net.fabricmc.loader.api.FabricLoader;
import turkfork.magnesium.client.renderer.device.MagnesiumRenderDevice;
import turkfork.magnesium.client.renderer.options.MagnesiumOptionPages;
import turkfork.magnesium.client.renderer.options.MagnesiumOptions;

/**
 * Drives the native macOS menu bar integration.
 *
 * <p>The native side renames the app menu and adds a "Magnesium" menu. Menu
 * choices arrive as a bitmask that is drained on the client tick, so options
 * are only ever changed on the game thread. Check marks are pushed back to the
 * native side every few ticks so they follow changes made in Sodium's settings
 * too.
 */
public final class MagnesiumMenuBar {

    private static final String APP_NAME = "Minecraft";

    // Must match the action ids in MetalBridge.mm.
    private static final int TOGGLE_METAL_RENDER = 0;
    private static final int TOGGLE_DISABLE_GL = 1;
    private static final int CAPTURE_FRAME = 2;
    private static final int TOGGLE_OVERLAY = 3;
    private static final int TOGGLE_FPS_LOG = 4;

    private static boolean installed = false;
    private static int tickCounter = 0;

    private MagnesiumMenuBar() {
    }

    /** Installs the menu bar once (no-op if disabled in the options). */
    public static void install() {
        if (installed || !MagnesiumOptionPages.OPTIONS.isMenuBar()) {
            return;
        }
        String version = FabricLoader.getInstance()
                .getModContainer("magnesium")
                .map(container -> container.getMetadata().getVersion().getFriendlyString())
                .orElse("dev");
        MetalBridge.installMenuBar(
                APP_NAME,
                version,
                FabricLoader.getInstance().getGameDir().toAbsolutePath().toString(),
                FabricLoader.getInstance().getConfigDir().toAbsolutePath().toString());
        installed = true;
        pushStates();
        System.out.println("[Magnesium] macOS menu bar integration requested.");
    }

    public static void onTick() {
        if (!installed) {
            return;
        }
        int mask = MetalBridge.pollMenuActions();
        if (mask != 0) {
            handle(mask);
            pushStates();
        } else if (++tickCounter % 10 == 0) {
            pushStates();
        }
    }

    private static void handle(int mask) {
        MagnesiumOptions options = MagnesiumOptionPages.OPTIONS;
        if (has(mask, TOGGLE_METAL_RENDER)) {
            options.setMetalRender(!options.isMetalRender());
        }
        if (has(mask, TOGGLE_DISABLE_GL)) {
            options.setDisableOpenGl(!options.isDisableOpenGl());
        }
        if (has(mask, CAPTURE_FRAME)) {
            options.setMetalDraw(true);
            MagnesiumRenderDevice device = MagnesiumDeviceInstaller.getDevice();
            if (device != null) {
                device.rearmCapture();
            } else {
                System.out.println("[Magnesium] Capture requested, but the Metal "
                        + "translation is not enabled.");
            }
        }
        if (has(mask, TOGGLE_OVERLAY)) {
            options.setDebugOverlay(!options.isDebugOverlay());
        }
        if (has(mask, TOGGLE_FPS_LOG)) {
            options.setFpsLogging(!options.isFpsLogging());
        }
        MagnesiumOptionPages.STORAGE.save();
    }

    private static boolean has(int mask, int action) {
        return (mask & (1 << action)) != 0;
    }

    private static void pushStates() {
        MagnesiumOptions options = MagnesiumOptionPages.OPTIONS;
        MetalBridge.setMenuState(TOGGLE_METAL_RENDER, options.isMetalRender());
        MetalBridge.setMenuState(TOGGLE_DISABLE_GL, options.isDisableOpenGl());
        MetalBridge.setMenuState(TOGGLE_OVERLAY, options.isDebugOverlay());
        MetalBridge.setMenuState(TOGGLE_FPS_LOG, options.isFpsLogging());
    }
}
