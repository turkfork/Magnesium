package turkfork.magnesium.client.renderer.device;

import com.mojang.blaze3d.platform.Window;
import com.mojang.blaze3d.systems.RenderSystem;
import me.jellysquid.mods.sodium.client.gl.device.DrawCommandList;
import me.jellysquid.mods.sodium.client.gl.device.MultiDrawBatch;
import me.jellysquid.mods.sodium.client.gl.tessellation.GlIndexType;
import net.minecraft.client.Minecraft;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix4f;
import turkfork.magnesium.client.renderer.MetalBridge;

/**
 * Magnesium's draw-command list.
 *
 * <p>In this milestone the on-screen path is still owned by the OpenGL device
 * (so the game stays playable), but when {@code -Dmagnesium.metal.draw=true}
 * each Sodium chunk batch also issues <em>real</em> Metal
 * {@code drawIndexedPrimitives} calls against an offscreen Metal render target.
 * The Metal vertex/index buffers are the mirrors populated by
 * {@link MagnesiumBufferMapping} / the arena mirroring in
 * {@link MagnesiumCommandList}. The model-view-projection is built in Java the
 * same way Sodium builds {@code ChunkRenderMatrices.from(camera)} (projection x
 * camera rotation; translation is supplied per-region, captured from Sodium's
 * own render-region origin via {@link MagnesiumRegionHook} so the Metal
 * rasterization matches the GL one exactly without any GL state reads.
 * The offscreen result is dumped to a PNG once one full terrain frame (solid,
 * cutout, translucent; see {@link MagnesiumPassHook}) has been drawn, with
 * coverage/color statistics for verification.
 *
 * <p>This wrapper is deliberately allocation-free and lock-free on the render
 * thread for the common (disabled) path: each begin creates a fresh wrapper
 * that captures an immutable delegate, and per-draw accounting is a plain long.
 */
public final class MagnesiumDrawCommandList implements DrawCommandList {

    private static boolean reportedDraw = false;

    private final MagnesiumRenderDevice device;
    private final DrawCommandList delegate;
    private final float[] mvp = new float[16];
    private final float[] regionOffset = new float[3];
    private boolean mvpReady = false;

    MagnesiumDrawCommandList(MagnesiumRenderDevice device, DrawCommandList delegate) {
        this.device = device;
        this.delegate = delegate;
    }

    @Override
    public void multiDrawElementsBaseVertex(MultiDrawBatch batch, GlIndexType indexType) {
        this.device.recordDraws(batch.size());
        if (!reportedDraw) {
            reportedDraw = true;
            System.out.println(
                    "[Magnesium] Draw intercepted by Magnesium: "
                            + batch.size() + " sub-draws, indexType="
                            + indexType.getFormatId());
        }
        if (this.device.isMetalDrawEnabled()) {
            metalCaptureRasterize(batch, indexType);
        }
        this.delegate.multiDrawElementsBaseVertex(batch, indexType);
    }

    /**
     * Routes the batch through the offscreen Metal rasterizer when a capture
     * is active. Opens the capture lazily on the first batch, then issues real
     * Metal {@code drawIndexedPrimitives} calls using the per-region,
     * camera-relative offset captured by {@link MagnesiumRegionHook} and the
     * current tessellation's vertex (arena) + element (shared quad index) Metal
     * mirrors.
     */
    private void metalCaptureRasterize(MultiDrawBatch batch, GlIndexType indexType) {
        if (this.device.isMetalCaptureDone()) {
            return;
        }
        float[] origin = MagnesiumRegionHook.origin();
        Vec3 cameraPos = Minecraft.getInstance().gameRenderer.getMainCamera().getPosition();
        this.regionOffset[0] = origin[0] - (float) cameraPos.x;
        this.regionOffset[1] = origin[1] - (float) cameraPos.y;
        this.regionOffset[2] = origin[2] - (float) cameraPos.z;

        if (!this.device.isMetalCaptureOpen()) {
            if (!this.mvpReady && MagnesiumMatrixHook.isReady()) {
                System.arraycopy(
                        MagnesiumMatrixHook.combinedMvp(), 0, this.mvp, 0, this.mvp.length);
                this.mvpReady = true;
            }
            if (!this.mvpReady) {
                buildMvpFromCamera();
            }
            Window window = Minecraft.getInstance().getWindow();
            int width = Math.max(1, window.getWidth());
            int height = Math.max(1, window.getHeight());
            this.device.openMetalCapture(width, height, this.mvp);
            if (!this.device.isMetalCaptureOpen()) {
                return;
            }
            MetalBridge.setChunkMvp(this.mvp);
        }

        long vertexHandle = this.device.getTessellationVertexMetal();
        long indexHandle = this.device.getTessellationIndexMetal();
        if (vertexHandle == 0L || indexHandle == 0L) {
            return;
        }
        MetalBridge.drawChunkBatch(
                vertexHandle,
                indexHandle,
                indexType.getFormatId(),
                batch.pElementCount,
                batch.pBaseVertex,
                batch.size(),
                this.regionOffset[0],
                this.regionOffset[1],
                this.regionOffset[2]);
    }

    /**
     * Builds the model-view-projection matrix exactly as Sodium's
     * {@code ChunkRenderMatrices.from(camera)} does: projection is the current
     * vanilla projection matrix and model-view is the camera's rotation. The
     * camera translation is folded into {@code u_RegionOffset} per region, so
     * the Metal vertex transform ({@code mvp * (vertex + regionOffset)})
     * reproduces {@code gl_Position}.
     */
    private void buildMvpFromCamera() {
        Matrix4f projection = RenderSystem.getProjectionMatrix();
        Matrix4f modelView = new Matrix4f()
                .rotation(Minecraft.getInstance().gameRenderer.getMainCamera().rotation());
        Matrix4f combined = new Matrix4f();
        if (projection != null) {
            combined.set(projection);
        }
        combined.mul(modelView);
        combined.get(this.mvp);
        this.mvpReady = true;
    }

    @Override
    public void endTessellating() {
        this.delegate.endTessellating();
    }

    @Override
    public void flush() {
        this.delegate.flush();
    }

    @Override
    public void close() {
        this.delegate.close();
    }
}