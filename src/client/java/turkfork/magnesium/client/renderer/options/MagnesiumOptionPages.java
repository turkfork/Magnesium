package turkfork.magnesium.client.renderer.options;

import com.google.common.collect.ImmutableList;
import me.jellysquid.mods.sodium.client.gui.options.OptionGroup;
import me.jellysquid.mods.sodium.client.gui.options.OptionImpl;
import me.jellysquid.mods.sodium.client.gui.options.OptionImpact;
import me.jellysquid.mods.sodium.client.gui.options.OptionPage;
import me.jellysquid.mods.sodium.client.gui.options.control.TickBoxControl;
import net.minecraft.network.chat.Component;

import java.util.List;

/**
 * Builds the "Magnesium" page shown inside the Sodium settings screen. The
 * page is registered by {@link turkfork.magnesium.client.mixin.SodiumOptionsGUIMixin}
 * when the Sodium options GUI is opened.
 */
public final class MagnesiumOptionPages {

    private MagnesiumOptionPages() {
    }

    /**
     * The single shared Magnesium options/storage pair used across the UI and
     * the renderer, so toggles here are reflected live everywhere.
     */
    public static final MagnesiumOptions OPTIONS = new MagnesiumOptions();
    public static final MagnesiumOptionsStorage STORAGE = new MagnesiumOptionsStorage(OPTIONS);

    static {
        // Apply previously-saved values from disk on top of the fresh defaults.
        MagnesiumOptionsStorage.loadInto(OPTIONS);
    }

    public static OptionPage general() {
        List<OptionGroup> groups = ImmutableList.of(
                OptionGroup.createBuilder()
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Metal translation"))
                                .setTooltip(Component.literal(
                                        "Mirror Sodium's buffer/draw calls into real Metal "
                                                + "MTLBuffer objects. Requires a restart to take "
                                                + "full effect."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setMetalEnabled,
                                        MagnesiumOptions::isMetalEnabled)
                                .setImpact(OptionImpact.HIGH)
                                .build())
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Test frame"))
                                .setTooltip(Component.literal(
                                        "Present a one-shot CAMetalLayer test frame when the "
                                                + "window is discovered (requires the Metal "
                                                + "translation to be disabled)."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setTestFrame,
                                        MagnesiumOptions::isTestFrame)
                                .build())
                        .build()
        );

        return new OptionPage(
                Component.literal("Magnesium"),
                ImmutableList.copyOf(groups));
    }
}