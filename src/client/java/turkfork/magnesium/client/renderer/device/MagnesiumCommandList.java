package turkfork.magnesium.client.renderer.device;

import me.jellysquid.mods.sodium.client.gl.array.GlVertexArray;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBuffer;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferMapping;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferStorageFlags;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferTarget;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferUsage;
import me.jellysquid.mods.sodium.client.gl.buffer.GlImmutableBuffer;
import me.jellysquid.mods.sodium.client.gl.buffer.GlMutableBuffer;
import me.jellysquid.mods.sodium.client.gl.buffer.GlBufferMapFlags;
import me.jellysquid.mods.sodium.client.gl.device.CommandList;
import me.jellysquid.mods.sodium.client.gl.device.DrawCommandList;
import me.jellysquid.mods.sodium.client.gl.sync.GlFence;
import me.jellysquid.mods.sodium.client.gl.tessellation.GlPrimitiveType;
import me.jellysquid.mods.sodium.client.gl.tessellation.GlTessellation;
import me.jellysquid.mods.sodium.client.gl.tessellation.TessellationBinding;
import me.jellysquid.mods.sodium.client.gl.util.EnumBitField;
import turkfork.magnesium.client.renderer.MetalBridge;

import java.nio.ByteBuffer;
import java.util.IdentityHashMap;
import java.util.Map;

/**
 * Magnesium's translation implementation of Sodium's {@link CommandList}.
 *
 * <p>Every buffer operation is mirrored to a real Metal buffer (via the native
 * {@link MetalBridge}) while the wrapped OpenGL command list still drives the
 * actual rendering. This exercises the Sodium → Magnesium → Metal translation
 * against real chunk data without breaking the live GL rendering path.
 */
public final class MagnesiumCommandList implements CommandList {

    private final MagnesiumRenderDevice device;
    private final Map<GlBuffer, Long> bufferToMetal;

    MagnesiumCommandList(MagnesiumRenderDevice device) {
        this.device = device;
        this.bufferToMetal = device.getBufferToMetal();
    }

    /**
     * The wrapped OpenGL command list. This is the pre-built
     * {@code GLRenderDevice} command list captured at device construction; it
     * is reused for every operation and is not subject to the device-activity
     * assertion that {@code GLRenderDevice.createCommandList()} applies.
     */
    private CommandList delegate() {
        return this.device.getDelegateCommandList();
    }

    private long metalOf(GlBuffer buffer) {
        Long handle = this.bufferToMetal.get(buffer);
        return handle == null ? 0L : handle;
    }

    @Override
    public GlMutableBuffer createMutableBuffer() {
        GlMutableBuffer buffer = delegate().createMutableBuffer();
        // The Metal mirror is deferred until the first real data allocation or
        // upload. Mutable buffers are typically allocated with zero or unknown
        // capacity at creation time, so creating (and later resizing) a Metal
        // buffer here would only waste allocations.
        this.bufferToMetal.put(buffer, 0L);
        return buffer;
    }

    @Override
    public GlImmutableBuffer createImmutableBuffer(
            long size,
            EnumBitField<GlBufferStorageFlags> flags) {
        GlImmutableBuffer buffer = delegate().createImmutableBuffer(size, flags);
        long handle = MetalBridge.createBuffer(size);
        this.bufferToMetal.put(buffer, handle);
        this.device.recordMetalBuffer(size);
        return buffer;
    }

    @Override
    public GlTessellation createTessellation(
            GlPrimitiveType primitiveType,
            TessellationBinding[] bindings) {
        return delegate().createTessellation(primitiveType, bindings);
    }

    @Override
    public void bindVertexArray(GlVertexArray array) {
        delegate().bindVertexArray(array);
    }

    @Override
    public void uploadData(GlMutableBuffer buffer, ByteBuffer data, GlBufferUsage usage) {
        delegate().uploadData(buffer, data, usage);
        if (data == null) {
            return;
        }
        int length = data.remaining();
        long handle = this.metalOf(buffer);
        if (handle == 0L) {
            if (length <= 0) {
                return;
            }
            handle = MetalBridge.createBuffer(length);
            if (handle != 0L) {
                this.bufferToMetal.put(buffer, handle);
                this.device.recordMetalBuffer(length);
            }
        }
        if (handle != 0L) {
            MetalBridge.uploadBufferData(handle, data);
        }
    }

    @Override
    public void copyBufferSubData(GlBuffer src, GlBuffer dst, long readOffset, long writeOffset, long length) {
        delegate().copyBufferSubData(src, dst, readOffset, writeOffset, length);
        long srcHandle = this.metalOf(src);
        long dstHandle = this.metalOf(dst);
        if (srcHandle != 0L && dstHandle != 0L) {
            MetalBridge.copyBufferData(srcHandle, dstHandle, readOffset, writeOffset, length);
        }
    }

    @Override
    public void bindBuffer(GlBufferTarget target, GlBuffer buffer) {
        delegate().bindBuffer(target, buffer);
    }

    @Override
    public void unbindVertexArray() {
        delegate().unbindVertexArray();
    }

    @Override
    public void allocateStorage(GlMutableBuffer buffer, long size, GlBufferUsage usage) {
        delegate().allocateStorage(buffer, size, usage);
        if (size <= 0) {
            return;
        }
        long handle = this.metalOf(buffer);
        if (handle == 0L) {
            handle = MetalBridge.createBuffer(size);
            if (handle != 0L) {
                this.bufferToMetal.put(buffer, handle);
                this.device.recordMetalBuffer(size);
            }
        } else {
            MetalBridge.allocateBufferStorage(handle, size);
        }
    }

    @Override
    public void deleteBuffer(GlBuffer buffer) {
        long handle = this.bufferToMetal.remove(buffer);
        if (handle != 0L) {
            MetalBridge.deleteBuffer(handle);
        }
        delegate().deleteBuffer(buffer);
    }

    @Override
    public void deleteVertexArray(GlVertexArray array) {
        delegate().deleteVertexArray(array);
    }

    @Override
    public void flush() {
        this.device.closeMetalCaptureIfOpen();
        delegate().flush();
    }

    @Override
    public DrawCommandList beginTessellating(GlTessellation tessellation) {
        return this.device.beginDelegatedDraw(tessellation);
    }

    @Override
    public void deleteTessellation(GlTessellation tessellation) {
        delegate().deleteTessellation(tessellation);
    }

    @Override
    public void close() {
        this.device.closeMetalCaptureIfOpen();
        delegate().close();
    }

    @Override
    public GlBufferMapping mapBuffer(
            GlBuffer buffer,
            long offset,
            long length,
            EnumBitField<GlBufferMapFlags> flags) {
        GlBufferMapping mapping = delegate().mapBuffer(buffer, offset, length, flags);
        long handle = this.metalOf(buffer);
        if (handle == 0L && length > 0) {
            handle = MetalBridge.createBuffer(length);
            if (handle != 0L) {
                this.bufferToMetal.put(buffer, handle);
                this.device.recordMetalBuffer(length);
            }
        }
        if (handle != 0L && mapping != null) {
            return new MagnesiumBufferMapping(
                    buffer,
                    mapping.getMemoryBuffer(),
                    handle,
                    offset,
                    (int) length);
        }
        return mapping;
    }

    @Override
    public void unmap(GlBufferMapping mapping) {
        if (mapping instanceof MagnesiumBufferMapping magnesiumMapping) {
            long handle = magnesiumMapping.getMetalHandle();
            int mapLength = magnesiumMapping.getMapLength();
            if (handle != 0L && mapLength > 0) {
                MetalBridge.writeBufferRange(
                        handle,
                        magnesiumMapping.getMapOffset(),
                        magnesiumMapping.getMemoryBuffer(),
                        0,
                        mapLength);
            }
        }
        delegate().unmap(mapping);
    }

    @Override
    public void flushMappedRange(GlBufferMapping mapping, int offset, int length) {
        if (mapping instanceof MagnesiumBufferMapping magnesiumMapping) {
            long handle = magnesiumMapping.getMetalHandle();
            if (handle != 0L && length > 0) {
                MetalBridge.writeBufferRange(
                        handle,
                        magnesiumMapping.getMapOffset() + offset,
                        magnesiumMapping.getMemoryBuffer(),
                        offset,
                        length);
            }
        }
        delegate().flushMappedRange(mapping, offset, length);
    }

    @Override
    public GlFence createFence() {
        return delegate().createFence();
    }
}
