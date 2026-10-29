package turkfork.magnesium.client.renderer.device;

import me.jellysquid.mods.sodium.client.gl.buffer.GlBuffer;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferTarget;
import me.jellysquid.mods.sodium.client.gl.device.CommandList;
import me.jellysquid.mods.sodium.client.gl.device.DrawCommandList;
import me.jellysquid.mods.sodium.client.gl.device.RenderDevice;
import me.jellysquid.mods.sodium.client.gl.functions.DeviceFunctions;
import me.jellysquid.mods.sodium.client.gl.tessellation.GlAbstractTessellation;
import me.jellysquid.mods.sodium.client.gl.tessellation.GlTessellation;
import me.jellysquid.mods.sodium.client.gl.tessellation.TessellationBinding;
import org.lwjgl.opengl.GLCapabilities;
import turkfork.magnesium.client.renderer.MetalBridge;
import turkfork.magnesium.client.renderer.options.MagnesiumOptionPages;

import java.util.IdentityHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Magnesium's Metal-backed implementation of Sodium's {@link RenderDevice}.
 *
 * <p>For the current milestone Magnesium runs in <em>transition mode</em>: it
 * delegates the actual frame rendering to the bundled OpenGL
 * {@code GLRenderDevice} (so Sodium's GL path still works and the game stays
 * playable) while returning a {@link MagnesiumCommandList} that mirrors every
 * buffer operation into real Metal {@code MTLBuffer}s. This lets us validate
 * the Sodium → Magnesium → Metal translation against real chunk data before we
 * flip the on-screen draw path to Metal.
 *
 * <p>The Metal translation is only active when the system property
 * {@code magnesium.metal.enabled=true} is set. Otherwise Sodium uses its
 * normal OpenGL device and Magnesium does nothing.
 */
public final class MagnesiumRenderDevice implements RenderDevice {

    private final RenderDevice delegate;
    private final CommandList delegateCommandList;
    private final MagnesiumCommandList commandList;
    private final Map<GlBuffer, Long> bufferToMetal = new IdentityHashMap<>();
    private final AtomicLong metalBufferCount = new AtomicLong();
    private final AtomicLong metalBufferBytes = new AtomicLong();
    private long drawCount = 0L;

    /**
     * When {@code -Dmagnesium.metal.draw=true}, real Metal draws are issued for
     * Sodium's chunk batches against an offscreen Metal render target, with the
     * result dumped to a PNG for verification. The GL path continues to own the
     * on-screen framebuffer.
     *
     * <p>Once the warm-up delay has elapsed, exactly one complete terrain frame
     * (solid, cutout and translucent passes, in Sodium's order) is rendered
     * with the textured Metal pipelines and written out.
     */
    private boolean metalDrawWasEnabled = false;
    private volatile boolean captureDone = false;
    private boolean captureOpen = false;
    private long firstDrawNano = 0L;
    private long captureStartNano = 0L;
    private long tessVertexMetal = 0L;
    private long tessIndexMetal = 0L;

    /** A capture that never sees its translucent pass is abandoned after this long. */
    private static final long CAPTURE_TIMEOUT_NANOS = 2_000_000_000L;

    public MagnesiumRenderDevice() {
        this.delegate = new me.jellysquid.mods.sodium.client.gl.device.GLRenderDevice();
        // The wrapped OpenGL command list is the pre-built ImmediateCommandList
        // that GLRenderDevice constructs eagerly. Using it directly (instead of
        // going through delegate().createCommandList(), which asserts the
        // delegate is active) keeps Magnesium working even when the device is
        // installed partway through a render pass.
        this.delegateCommandList = prebuiltDelegateCommandList();
        this.commandList = new MagnesiumCommandList(this);
    }

    @Override
    public CommandList createCommandList() {
        return this.commandList;
    }

    RenderDevice getDelegate() {
        return this.delegate;
    }

    /**
     * Extract the wrapped GLRenderDevice's eagerly-built command list directly
     * from its {@code commandList} field. This bypasses
     * {@code createCommandList()}, which throws {@code checkDeviceActive()}
     * when the device is not currently active (e.g. after a mid-passes install).
     */
    private CommandList prebuiltDelegateCommandList() {
        try {
            java.lang.reflect.Field f =
                    me.jellysquid.mods.sodium.client.gl.device.GLRenderDevice.class
                            .getDeclaredField("commandList");
            f.setAccessible(true);
            return (CommandList) f.get(this.delegate);
        } catch (Throwable t) {
            // Fall back to the plain command list obtained normally; in an
            // active context this is equivalent.
            return this.delegate.createCommandList();
        }
    }

    Map<GlBuffer, Long> getBufferToMetal() {
        return this.bufferToMetal;
    }

    CommandList getDelegateCommandList() {
        return this.delegateCommandList;
    }

    /**
     * Opens a draw command list on the underlying OpenGL device for the given
     * tessellation. The wrapped GL device drives the actual on-screen rendering
     * in this transition milestone. Uses the pre-built delegate command list
     * instead of {@code createCommandList()} so it is not subject to the
     * device-activity assertion.
     *
     * <p>A fresh wrapper is returned for each tessellation. Sodium retains the
     * returned {@link DrawCommandList} and calls
     * {@code multiDrawElementsBaseVertex()} against it while it remains valid,
     * so each wrapper must capture its own immutable delegate draw list rather
     * than reusing a shared, mutable instance (which would corrupt concurrent
     * or retained use).
     */
    DrawCommandList beginDelegatedDraw(GlTessellation tessellation) {
        resolveTessellationBuffers(tessellation);
        DrawCommandList delegateDraw =
                this.delegateCommandList.beginTessellating(tessellation);
        return new MagnesiumDrawCommandList(this, delegateDraw);
    }

    /**
     * Resolves the Metal handles of the current tessellation's vertex (arena)
     * and element (shared quad index) buffers. Used as the vertex/index sources
     * for the offscreen Metal capture.
     */
    private void resolveTessellationBuffers(GlTessellation tessellation) {
        this.tessVertexMetal = 0L;
        this.tessIndexMetal = 0L;
        try {
            java.lang.reflect.Field f =
                    GlAbstractTessellation.class.getDeclaredField("bindings");
            f.setAccessible(true);
            TessellationBinding[] bindings = (TessellationBinding[]) f.get(tessellation);
            if (bindings != null) {
                for (TessellationBinding binding : bindings) {
                    if (binding.target() == GlBufferTarget.ARRAY_BUFFER) {
                        this.tessVertexMetal = this.metalOf(binding.buffer());
                    } else if (binding.target() == GlBufferTarget.ELEMENT_BUFFER) {
                        this.tessIndexMetal = this.metalOf(binding.buffer());
                    }
                }
            }
        } catch (Throwable t) {
            // Diagnostics only; the capture is skipped when handles are missing.
        }
    }

    long metalOf(GlBuffer buffer) {
        Long handle = this.bufferToMetal.get(buffer);
        return handle == null ? 0L : handle;
    }

    /**
     * Whether the offscreen Metal draw is switched on. Turning the option off
     * and on again re-arms the capture: the "done" latch is cleared and a new
     * warm-up starts.
     */
    boolean isMetalDrawEnabled() {
        boolean enabled = MagnesiumOptionPages.OPTIONS.isMetalDraw();
        if (enabled && !this.metalDrawWasEnabled) {
            this.captureDone = false;
            this.firstDrawNano = 0L;
        }
        this.metalDrawWasEnabled = enabled;
        return enabled;
    }

    boolean isMetalCaptureDone() {
        return this.captureDone;
    }

    boolean isMetalCaptureOpen() {
        return this.captureOpen;
    }

    long getTessellationVertexMetal() {
        return this.tessVertexMetal;
    }

    long getTessellationIndexMetal() {
        return this.tessIndexMetal;
    }

    /**
     * Opens the offscreen Metal capture for the current tessellation. Supplies
     * the model-view-projection matrix (the chunk shader's
     * {@code u_ProjectionMatrix * u_ModelViewMatrix}, column-major) and the
     * framebuffer size. Only opens at the start of a frame (the solid pass),
     * after the warm-up delay, and once the atlas and light map are mirrored.
     */
    void openMetalCapture(int width, int height, float[] mvp) {
        if (this.captureOpen || this.captureDone) {
            return;
        }
        if (this.tessVertexMetal == 0L || this.tessIndexMetal == 0L) {
            return;
        }
        long now = System.nanoTime();
        if (this.firstDrawNano == 0L) {
            this.firstDrawNano = now;
        }
        if (MagnesiumPassHook.kind() != MagnesiumPassHook.SOLID
                || now - this.firstDrawNano < MagnesiumOptionPages.OPTIONS.getCaptureDelaySeconds() * 1_000_000_000L) {
            return;
        }
        if (!MagnesiumTextureSync.sync()) {
            return;
        }
        MetalBridge.setChunkCulling(MagnesiumOptionPages.OPTIONS.isCullBackFaces());
        if (MetalBridge.beginChunkCapture(width, height, mvp)) {
            this.captureOpen = true;
            this.captureStartNano = now;
            MagnesiumPassHook.pushPassState();
        }
    }

    /** Called when Sodium starts drawing a terrain pass. */
    void onPassBegin(int kind) {
        if (!this.captureOpen) {
            return;
        }
        if (kind == MagnesiumPassHook.SOLID
                || System.nanoTime() - this.captureStartNano > CAPTURE_TIMEOUT_NANOS) {
            // The frame wrapped (or never produced a translucent pass).
            this.finishMetalCapture();
            return;
        }
        MagnesiumPassHook.pushPassState();
    }

    /** Called when Sodium finishes drawing a terrain pass. */
    void onPassEnd(int kind) {
        if (this.captureOpen && kind == MagnesiumPassHook.TRANSLUCENT) {
            this.finishMetalCapture();
        }
    }

    /**
     * Commits the Metal encoder, reads the offscreen render back, dumps a PNG,
     * prints verification statistics, and latches the "done" flag so later
     * frames are skipped.
     */
    private void finishMetalCapture() {
        this.captureOpen = false;
        this.captureDone = true;
        String pngPath = System.getProperty(
                "magnesium.metal.draw.png",
                new java.io.File(System.getProperty("user.dir"), "magnesium-metal.png").getPath());
        long[] stats = MetalBridge.endChunkCapture(pngPath);
        if (stats != null) {
            System.out.printf(
                    "[Magnesium] Metal chunk capture: subDraws=%d indices=%d coverage=%.1f%% avgColor=(%d,%d,%d) png=%s%n",
                    stats[0], stats[1],
                    stats[2] / 1000.0,
                    stats[3] / 1000, stats[4] / 1000, stats[5] / 1000,
                    pngPath);
        }
    }

    /**
     * Records that a Metal buffer has been created/allocated, returning the
     * running total of Metal buffer bytes managed by Magnesium.
     */
    long recordMetalBuffer(long size) {
        this.metalBufferCount.incrementAndGet();
        this.metalBufferBytes.addAndGet(Math.max(0L, size));
        return this.metalBufferBytes.get();
    }

    public long getMetalBufferCount() {
        return this.metalBufferCount.get();
    }

    public long getMetalBufferBytes() {
        return this.metalBufferBytes.get();
    }

    /** Records that a batch of sub-draws was routed through Magnesium. */
    void recordDraws(long subDraws) {
        this.drawCount += subDraws;
    }

    public long getDrawCount() {
        return this.drawCount;
    }

    @Override
    public void makeActive() {
        this.delegate.makeActive();
    }

    @Override
    public void makeInactive() {
        this.delegate.makeInactive();
    }

    @Override
    public GLCapabilities getCapabilities() {
        return this.delegate.getCapabilities();
    }

    @Override
    public DeviceFunctions getDeviceFunctions() {
        return this.delegate.getDeviceFunctions();
    }

    /**
     * Returns the number of sub-texel precision bits used by the texture
     * sampler when computing per-texel biases.
     *
     * <p>This method is part of the Sodium 0.5.13 {@code RenderDevice}
     * interface (it plugs the seam that newer Sodium uses for per-atlas texel
     * precision). The value follows Sodium's own semantics: 4 bits on macOS
     * and 8 bits elsewhere (Minecraft's atlas filtering needs finer sub-texel
     * precision on Apple drivers), and Iris also relies on it via
     * {@code IrisChunkShaderInterface.setupState()}. This codebase targets
     * macOS (Apple M-series), so we return 4.
     */
    @Override
    public int getSubTexelPrecisionBits() {
        return 4;
    }
}
