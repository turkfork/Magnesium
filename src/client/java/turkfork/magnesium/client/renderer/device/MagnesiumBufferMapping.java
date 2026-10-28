package turkfork.magnesium.client.renderer.device;

import me.jellysquid.mods.sodium.client.gl.buffer.GlBuffer;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferMapping;
import turkfork.magnesium.client.renderer.MetalBridge;

import java.nio.ByteBuffer;

/**
 * A {@link GlBufferMapping} that mirrors every CPU-side buffer write into the
 * corresponding Metal buffer.
 *
 * <p>Sodium writes vertex and index data through {@link GlBufferMapping}
 * instances returned by {@code CommandList.mapBuffer}: either via
 * {@link #write(ByteBuffer, int)} (the mapped staging buffer's persistent
 * mapping) or by writing into {@link #getMemoryBuffer()} directly before
 * {@code CommandList.unmap} (the shared quad index buffer). Mirroring both
 * keep the Metal buffer contents in sync with the GL buffer, which is the data
 * prerequisite for real Metal draw calls on the chunk vertex arena.
 */
public final class MagnesiumBufferMapping extends GlBufferMapping {

    private final long metalHandle;
    private final long mapOffset;
    private final int mapLength;

    MagnesiumBufferMapping(
            GlBuffer buffer,
            ByteBuffer map,
            long metalHandle,
            long mapOffset,
            int mapLength
    ) {
        super(buffer, map);
        this.metalHandle = metalHandle;
        this.mapOffset = mapOffset;
        this.mapLength = mapLength;
    }

    @Override
    public void write(ByteBuffer src, int len) {
        super.write(src, len);
        if (this.metalHandle != 0L && src != null && src.remaining() > 0) {
            MetalBridge.writeBufferRange(
                    this.metalHandle,
                    this.mapOffset + len,
                    src,
                    src.position(),
                    src.remaining());
        }
    }

    long getMetalHandle() {
        return this.metalHandle;
    }

    long getMapOffset() {
        return this.mapOffset;
    }

    int getMapLength() {
        return this.mapLength;
    }
}