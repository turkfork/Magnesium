package turkfork.magnesium.client.renderer;

public final class MetalBridge {

    private static boolean loaded = false;

    private MetalBridge() {
    }

    /**
     * Loads the native Magnesium Metal library.
     *
     * The library is resolved in this order:
     *
     * 1. An explicit path supplied through {@code -Dmagnesium.native.path}.
     * 2. The dylib bundled inside the mod jar, extracted to a temp file.
     */
    public static void load() {
        if (loaded) {
            return;
        }

        System.out.println("[Magnesium] Loading Metal native library...");

        String libraryPath = System.getProperty("magnesium.native.path");

        if (libraryPath == null || libraryPath.isBlank()) {
            libraryPath = extractBundledLibrary();
        }

        if (libraryPath == null) {
            throw new IllegalStateException(
                    "[Magnesium] No Metal native library found. Set "
                            + "-Dmagnesium.native.path=/path/to/libmagnesium.dylib "
                            + "or bundle the dylib inside the jar at "
                            + "native/macos/libmagnesium.dylib"
            );
        }

        try {
            System.out.println(
                    "[Magnesium] Native library path: " + libraryPath
            );

            System.load(libraryPath);

            loaded = true;

            System.out.println(
                    "[Magnesium] Metal native library loaded successfully."
            );

        } catch (UnsatisfiedLinkError e) {
            System.err.println(
                    "[Magnesium] Failed to load Metal native library:"
            );

            System.err.println(libraryPath);

            throw e;
        }
    }

    /**
     * Extracts the copy of {@code libmagnesium.dylib} bundled in the mod jar
     * to a temporary file and returns its path, or {@code null} if the jar
     * does not ship one.
     */
    private static String extractBundledLibrary() {
        String resource = "/native/macos/libmagnesium.dylib";

        try (java.io.InputStream in =
                     MetalBridge.class.getResourceAsStream(resource)) {
            if (in == null) {
                return null;
            }

            java.nio.file.Path target =
                    java.nio.file.Files.createTempFile("magnesium", ".dylib");
            java.nio.file.Files.copy(
                    in,
                    target,
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);

            target.toFile().deleteOnExit();

            System.out.println(
                    "[Magnesium] Extracted native library to: " + target
            );

            return target.toString();
        } catch (Exception e) {
            System.err.println(
                    "[Magnesium] Failed to extract bundled native library: "
                            + e
            );

            return null;
        }
    }

    /**
     * Initializes Metal and creates the default Metal device
     * and command queue.
     *
     * @return true if Metal initialized successfully
     */
    public static native boolean initialize();

    /**
     * Returns the name of the Metal GPU.
     *
     * @return Metal device name, or "Unknown" if unavailable
     */
    public static native String getDeviceName();

    /**
     * Schedules a non-blocking window discovery on the AppKit main thread.
     *
     * Safe to call from any thread. Once a window is discovered, further
     * calls become no-ops.
     */
    public static native void discoverWindow();

    /**
     * @return true if the Minecraft window has been discovered
     */
    public static native boolean isWindowDiscovered();

    /**
     * @return a human-readable description of the discovered window,
     *         or "(no window)" if none has been discovered
     */
    public static native String getWindowDescription();

    /**
     * Schedules a non-blocking CAMetalLayer attachment on the AppKit main
     * thread. Safe to call from any thread. No-op if already attached.
     */
    public static native void attachLayer();

    /**
     * @return true if the CAMetalLayer has been attached
     */
    public static native boolean isLayerAttached();

    /**
     * @return a human-readable description of the attached layer,
     *         or "(no layer)" if not attached
     */
    public static native String getLayerInfo();

    /**
     * Schedules presentation of a single solid-color test frame on the
     * AppKit main thread to prove the Metal drawable path.
     */
    public static native void presentTestFrame();

    /**
     * Renders one frame using the Metal renderer.
     */
    public static native void render();

    /**
     * Creates a shared-storage Metal buffer of the given size.
     *
     * @return a long handle identifying the Metal buffer, or 0 on failure
     */
    public static native long createBuffer(long size);

    /**
     * Uploads the contents of a direct ByteBuffer into a Metal buffer.
     */
    public static native void uploadBufferData(long handle, java.nio.ByteBuffer src);

    /**
     * Reallocates a Metal buffer to the given size (preserving no contents).
     */
    public static native void allocateBufferStorage(long handle, long size);

    /**
     * Copies bytes between two Metal buffers (mirrors GL glCopyBufferSubData).
     */
    public static native void copyBufferData(long srcHandle, long dstHandle,
                                             long srcOffset, long dstOffset,
                                             long length);


    /**
     * @return the mapped memory address (in native heap) of a Metal buffer,
     *         or 0 if not found
     */
    public static native long bufferMapContents(long handle);

    /**
     * Marks a range of a Metal buffer as modified (shared-storage no-op but
     * kept for API compatibility and future managed storage).
     */
    public static native void bufferDidModify(long handle, long offset, long length);

    /**
     * @return the length in bytes of a Metal buffer, or 0 if not found
     */
    public static native long bufferLength(long handle);

    /**
     * Deletes a Metal buffer, releasing its native resource.
     */
    public static native void deleteBuffer(long handle);

    /**
     * Copies bytes from a direct ByteBuffer into a Metal buffer at an offset.
     * Mirrors CPU-side writes into the GL mapped region.
     */
    public static native void writeBufferRange(long handle, long offset,
                                               java.nio.ByteBuffer src,
                                               int srcOffset, int length);

    /**
     * Opens an offscreen Metal capture pass at the given size for the current
     * model-view-projection (the chunk shader's u_ProjectionMatrix multiplied
     * by u_ModelViewMatrix, in column-major order).
     *
     * @return true if the capture encoder was opened
     */
    public static native boolean beginChunkCapture(int width, int height, float[] mvp);

    /**
     * Updates the model-view-projection used by the open chunk capture.
     */
    public static native void setChunkMvp(float[] mvp);

    /**
     * Issues real Metal {@code drawIndexedPrimitives} calls for a Sodium
     * {@code MultiDrawBatch}: element counts and base vertices are read
     * directly from the batch's native int arrays.
     */
    public static native void drawChunkBatch(long vertexHandle, long indexHandle,
                                             int indexTypeId,
                                             long pElementCount, long pBaseVertex,
                                             int elementCount,
                                             float ox, float oy, float oz);

    /**
     * Ends the open chunk capture, commits + waits for the GPU, and dumps the
     * offscreen render to a PNG file. Returns
     * {@code [subDraws, indices, coverageX1000, avgRX1000, avgGX1000, avgBX1000]}.
     */
    public static native long[] endChunkCapture(String pngPath);

    /**
     * Shuts down the Metal renderer and releases native resources.
     */
    public static native void shutdown();
}