package turkfork.magnesium.client.renderer;

import me.jellysquid.mods.sodium.client.gl.device.RenderDevice;
import turkfork.magnesium.client.renderer.device.MagnesiumRenderDevice;
import turkfork.magnesium.client.renderer.options.MagnesiumOptionPages;

import java.lang.reflect.Field;
import sun.misc.Unsafe;

/**
 * Decides whether Magnesium's Metal translation layer should replace Sodium's
 * OpenGL {@link RenderDevice}.
 *
 * <p>The Metal translation is enabled only when the system property
 * {@code magnesium.metal.enabled=true} is passed (as a JVM argument). When
 * disabled, Sodium keeps using its normal OpenGL device and Magnesium does not
 * touch the rendering pipeline.
 *
 * <p>We install by reflectively rewriting {@link RenderDevice#INSTANCE}.
 * Because that field is initialized with {@code new GLRenderDevice()} (a
 * non-constant expression) rather than a compile-time constant, it is not
 * constant-folded by the JIT, so a reflective write performed early is reliably
 * observed by all later {@code RenderDevice.INSTANCE} reads.
 */
public final class MagnesiumDeviceInstaller {

    private static final String ENABLE_PROPERTY = "magnesium.metal.enabled";
    private static volatile boolean installed = false;
    private static volatile boolean disabledLogged = false;
    private static volatile MagnesiumRenderDevice device;

    private static final String DEVICE_CLASS =
            "me.jellysquid.mods.sodium.client.gl.device.RenderDevice";
    private static final String DEVICE_FIELD = "INSTANCE";

    private MagnesiumDeviceInstaller() {
    }

    public static boolean isEnabled() {
        return MagnesiumOptionPages.OPTIONS.isMetalEnabled();
    }

    /**
     * The installed Magnesium device, or {@code null} if the Metal translation
     * is disabled or has not been installed yet.
     */
    public static MagnesiumRenderDevice getDevice() {
        return device;
    }

    /**
     * Replaces {@code RenderDevice.INSTANCE} with a {@link MagnesiumRenderDevice}
     * when the Metal translation is enabled; otherwise does nothing. Must be
     * called on the render thread once an OpenGL context (GL capabilities) is
     * available, because loading {@code RenderDevice} eagerly constructs a
     * {@code GLRenderDevice} during its static initializer.
     *
     * <p>Called every client tick. If Metal translation is currently disabled
     * it returns without marking the install as done, so that toggling it on
     * later (before any world is loaded, e.g. from the main menu) succeeds on a
     * subsequent tick. Once installed it is never refreshed.
     */
    public static void installNow() {
        if (installed) {
            return;
        }

        if (!isEnabled()) {
            if (!disabledLogged) {
                disabledLogged = true;
                System.out.println(
                        "[Magnesium] Metal translation disabled (add "
                                + "-D" + ENABLE_PROPERTY + "=true to enable). "
                                + "Using Sodium's OpenGL device.");
            }
            return;
        }

        try {
            Class<?> deviceClass = Class.forName(DEVICE_CLASS);
            Field instanceField = deviceClass.getDeclaredField(DEVICE_FIELD);
            instanceField.setAccessible(true);

            // On modern JDKs (12+; we run on 17/21) the reflective
            // Field.modifiers hack is gone (NoSuchFieldException), and setting
            // a static final field via Field#set throws IllegalAccessException.
            // Write straight through the static field backing the INSTANCE
            // constant using Unsafe, which ignores the final flag and is not
            // const-folded (INSTANCE is assigned new GLRenderDevice(), not a
            // compile-time constant).
            Field unsafeField = Unsafe.class.getDeclaredField("theUnsafe");
            unsafeField.setAccessible(true);
            Unsafe unsafe = (Unsafe) unsafeField.get(null);

            MagnesiumRenderDevice device = new MagnesiumRenderDevice();
            Object base = unsafe.staticFieldBase(instanceField);
            long offset = unsafe.staticFieldOffset(instanceField);
            unsafe.putObject(base, offset, device);

            MagnesiumDeviceInstaller.device = device;
            installed = true;

            System.out.println(
                    "[Magnesium] Metal translation enabled. "
                            + "Installed MagnesiumRenderDevice over Sodium's "
                            + "OpenGL RenderDevice.");
        } catch (Throwable t) {
            System.err.println(
                    "[Magnesium] Failed to install MagnesiumRenderDevice: "
                            + t);
        }
    }
}
