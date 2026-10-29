package turkfork.magnesium.client;

import net.fabricmc.api.ClientModInitializer;
import turkfork.magnesium.client.renderer.MagnesiumRenderer;

public class MagnesiumClient implements ClientModInitializer {

    @Override
    public void onInitializeClient() {
        System.out.println("[Magnesium] Initializing...");

        // The Metal translation layer is installed lazily on the first client
        // tick (see MagnesiumRenderer), once an OpenGL context and GL
        // capabilities are available in the render thread.
        MagnesiumRenderer.initialize();
    }
}