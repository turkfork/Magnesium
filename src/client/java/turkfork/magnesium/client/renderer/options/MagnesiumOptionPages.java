package turkfork.magnesium.client.renderer.options;

import com.google.common.collect.ImmutableList;
import me.jellysquid.mods.sodium.client.gui.options.OptionGroup;
import me.jellysquid.mods.sodium.client.gui.options.OptionImpl;
import me.jellysquid.mods.sodium.client.gui.options.OptionImpact;
import me.jellysquid.mods.sodium.client.gui.options.OptionPage;
import me.jellysquid.mods.sodium.client.gui.options.control.ControlValueFormatter;
import me.jellysquid.mods.sodium.client.gui.options.control.SliderControl;
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
                        .build(),
                OptionGroup.createBuilder()
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Offscreen Metal draw"))
                                .setTooltip(Component.literal(
                                        "Render one full terrain frame (solid, cutout, "
                                                + "translucent) through Metal into an offscreen "
                                                + "target and save it as magnesium-metal.png. "
                                                + "Turning this on again captures another frame. "
                                                + "Requires the Metal translation."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setMetalDraw,
                                        MagnesiumOptions::isMetalDraw)
                                .setImpact(OptionImpact.MEDIUM)
                                .build())
                        .add(OptionImpl.createBuilder(int.class, STORAGE)
                                .setName(Component.literal("Capture delay"))
                                .setTooltip(Component.literal(
                                        "Seconds to wait after the first terrain draw before "
                                                + "capturing, so nearby chunks can mesh and upload."))
                                .setControl(option -> new SliderControl(option, 0,
                                        MagnesiumOptions.MAX_CAPTURE_DELAY_SECONDS, 1,
                                        ControlValueFormatter.quantityOrDisabled("s", "None")))
                                .setBinding(MagnesiumOptions::setCaptureDelaySeconds,
                                        MagnesiumOptions::getCaptureDelaySeconds)
                                .build())
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Back-face culling"))
                                .setTooltip(Component.literal(
                                        "Cull back faces in the Metal terrain pass, as vanilla "
                                                + "does. Plants and dripstone are modelled with a "
                                                + "quad for each side, so leaving this off draws "
                                                + "both and causes artifacts."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setCullBackFaces,
                                        MagnesiumOptions::isCullBackFaces)
                                .build())
                        .build(),
                OptionGroup.createBuilder()
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Metal terrain rendering (experimental)"))
                                .setTooltip(Component.literal(
                                        "Render Sodium's terrain through Metal every frame and "
                                                + "composite it into the OpenGL framebuffer with "
                                                + "depth, so entities and the HUD still sort "
                                                + "correctly. Reads the frame back to the CPU, so "
                                                + "it is slow. Requires the Metal translation. "
                                                + "May not work with fabulous graphics."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setMetalRender,
                                        MagnesiumOptions::isMetalRender)
                                .setImpact(OptionImpact.HIGH)
                                .build())
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Disable OpenGL terrain draw (experimental)"))
                                .setTooltip(Component.literal(
                                        "Skip Sodium's OpenGL terrain draw calls entirely. "
                                                + "Without Metal terrain rendering also enabled, "
                                                + "no terrain is drawn at all. Requires the "
                                                + "Metal translation."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setDisableOpenGl,
                                        MagnesiumOptions::isDisableOpenGl)
                                .setImpact(OptionImpact.HIGH)
                                .build())
                        .build(),
                OptionGroup.createBuilder()
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("macOS menu bar integration"))
                                .setTooltip(Component.literal(
                                        "Rename the menu bar's \"java\" app menu to \"Minecraft\" "
                                                + "and add a Magnesium menu with quick toggles. "
                                                + "Requires a restart."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setMenuBar,
                                        MagnesiumOptions::isMenuBar)
                                .build())
                        .build(),
                OptionGroup.createBuilder()
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("F3 overlay info"))
                                .setTooltip(Component.literal(
                                        "Show the Magnesium section in the F3 debug overlay."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setDebugOverlay,
                                        MagnesiumOptions::isDebugOverlay)
                                .build())
                        .add(OptionImpl.createBuilder(Boolean.class, STORAGE)
                                .setName(Component.literal("Framerate logging"))
                                .setTooltip(Component.literal(
                                        "Periodically print the FPS and Metal buffer/draw "
                                                + "statistics to the console."))
                                .setControl(TickBoxControl::new)
                                .setBinding(MagnesiumOptions::setFpsLogging,
                                        MagnesiumOptions::isFpsLogging)
                                .build())
                        .add(OptionImpl.createBuilder(int.class, STORAGE)
                                .setName(Component.literal("Logging interval"))
                                .setTooltip(Component.literal(
                                        "Seconds between framerate log lines."))
                                .setControl(option -> new SliderControl(option, 1,
                                        MagnesiumOptions.MAX_FPS_LOG_PERIOD_SECONDS, 1,
                                        ControlValueFormatter.quantityOrDisabled("s", "Off")))
                                .setBinding(MagnesiumOptions::setFpsLogPeriodSeconds,
                                        MagnesiumOptions::getFpsLogPeriodSeconds)
                                .build())
                        .build()
        );

        return new OptionPage(
                Component.literal("Magnesium"),
                ImmutableList.copyOf(groups));
    }
}