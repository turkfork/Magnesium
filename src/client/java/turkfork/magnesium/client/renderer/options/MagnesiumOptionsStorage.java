package turkfork.magnesium.client.renderer.options;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import me.jellysquid.mods.sodium.client.gui.options.storage.OptionStorage;
import net.fabricmc.loader.api.FabricLoader;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Persists {@link MagnesiumOptions} to {@code config/magnesium-options.json}
 * as pretty-printed JSON using Gson (bundled with Minecraft).
 *
 * <p>{@link #getData()} is the mutable live options object Sodium's UI reads
 * and writes; {@link #save()} flushes the current values to disk.
 */
public final class MagnesiumOptionsStorage implements OptionStorage<MagnesiumOptions> {

    private static final Gson GSON = new GsonBuilder()
            .setPrettyPrinting()
            .create();

    private static final String FILE_NAME = "magnesium-options.json";

    private final MagnesiumOptions data;

    public MagnesiumOptionsStorage(MagnesiumOptions data) {
        this.data = data;
    }

    @Override
    public MagnesiumOptions getData() {
        return this.data;
    }

    @Override
    public void save() {
        Path target = configPath();

        try {
            if (target.getParent() != null) {
                Files.createDirectories(target.getParent());
            }

            String json = GSON.toJson(this.data);
            Files.write(
                    target,
                    json.getBytes(StandardCharsets.UTF_8),
                    java.nio.file.StandardOpenOption.CREATE,
                    java.nio.file.StandardOpenOption.TRUNCATE_EXISTING,
                    java.nio.file.StandardOpenOption.WRITE);

            System.out.println("[Magnesium] Saved options to: " + target);
        } catch (IOException e) {
            System.err.println(
                    "[Magnesium] Failed to save options to " + target + ": " + e);
        }
    }

    /**
     * Loads the persisted options from disk into the given object (used once at
     * startup). If the file is missing or unreadable, the options keep their
     * default (system-property-derived) values.
     */
    public static void loadInto(MagnesiumOptions options) {
        Path source = configPath();

        if (!Files.exists(source)) {
            return;
        }

        try {
            String json = new String(
                    Files.readAllBytes(source),
                    StandardCharsets.UTF_8);

            MagnesiumOptions loaded = GSON.fromJson(json, MagnesiumOptions.class);

            if (loaded != null) {
                options.setMetalEnabled(loaded.isMetalEnabled());
                options.setTestFrame(loaded.isTestFrame());
                System.out.println("[Magnesium] Loaded options from: " + source);
            }
        } catch (Exception e) {
            System.err.println(
                    "[Magnesium] Failed to load options from " + source + ": " + e);
        }
    }

    private static Path configPath() {
        return FabricLoader.getInstance()
                .getConfigDir()
                .resolve(FILE_NAME);
    }
}