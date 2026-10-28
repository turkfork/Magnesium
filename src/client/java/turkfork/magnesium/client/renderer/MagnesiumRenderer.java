package turkfork.magnesium.client.renderer;

import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import turkfork.magnesium.client.renderer.options.MagnesiumOptionPages;

public final class MagnesiumRenderer {

    private static boolean discoveryLogged = false;
    private static boolean layerLogged = false;
    private static boolean testFrameEnabled = false;

    private MagnesiumRenderer() {
    }

    public static void initialize() {
        String os = System.getProperty("os.name");

        if (!os.equalsIgnoreCase("Mac OS X")
                && !os.equalsIgnoreCase("macOS")) {
            System.out.println("[Magnesium] Metal is only supported on macOS.");
            return;
        }

        System.out.println("[Magnesium] macOS detected.");

        MetalBridge.load();

        if (!MetalBridge.initialize()) {
            System.err.println("[Magnesium] Metal initialization failed.");
            return;
        }

        System.out.println(
                "[Magnesium] Metal device: "
                        + MetalBridge.getDeviceName()
        );

        System.out.println("[Magnesium] Metal renderer initialized.");

        MagnesiumFpsLogger.initialize();

        // The one-shot CAMetalLayer test frame (purple frame) is an optional,
        // self-contained experiment, not part of the renderer path.
        testFrameEnabled = MagnesiumOptionPages.OPTIONS.isTestFrame();
        if (testFrameEnabled) {
            System.out.println("[Magnesium] Test-frame mode enabled.");
        }

        startWindowDiscovery();
    }

    /**
     * Hooks the Minecraft client tick to discover the real game window without
     * blocking the render thread or the AppKit main thread. Window discovery is
     * pure logging and is harmless. The optional CAMetalLayer + test frame only
     * runs when {@code -Dmagnesium.testFrame=true} is set, keeping normal runs
     * fully on the OpenGL/Sodium path.
     */
    private static void startWindowDiscovery() {
        ClientTickEvents.END_CLIENT_TICK.register(client -> {
            // The Metal translation layer must not be installed during mod
            // init: loading me.jellysquid...RenderDevice eagerly runs its
            // <clinit>, which constructs a GLRenderDevice and requires the
            // current thread to have an active OpenGL context (GL
            // capabilities). That is not ready until the first tick, so defer
            // installation here.
            MagnesiumDeviceInstaller.installNow();
            MagnesiumFpsLogger.onTick();

            if (!MetalBridge.isWindowDiscovered()) {
                MetalBridge.discoverWindow();
                return;
            }

            if (!discoveryLogged) {
                discoveryLogged = true;
                System.out.println(
                        "[Magnesium] Minecraft window discovered: "
                                + MetalBridge.getWindowDescription()
                );

                if (!testFrameEnabled || MagnesiumDeviceInstaller.isEnabled()) {
                    // Do not attach the CAMetalLayer during a normal run or
                    // while the Metal translation layer is active; that would
                    // freeze the on-screen path.
                    return;
                }

                MetalBridge.attachLayer();
            }

            if (!testFrameEnabled || MagnesiumDeviceInstaller.isEnabled()) {
                return;
            }

            if (!MetalBridge.isLayerAttached()) {
                MetalBridge.attachLayer();
                return;
            }

            if (!layerLogged) {
                layerLogged = true;
                System.out.println(
                        "[Magnesium] Layer attached: "
                                + MetalBridge.getLayerInfo()
                );
                MetalBridge.presentTestFrame();
            }
        });
    }
}
