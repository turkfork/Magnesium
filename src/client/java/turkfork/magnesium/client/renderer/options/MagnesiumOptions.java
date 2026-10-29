package turkfork.magnesium.client.renderer.options;

// Runtime configuration for Magnesium. Values are held in-memory so the
// Sodium settings tab can toggle them live. Freshly-launched defaults come
// from their corresponding -D system properties.
public final class MagnesiumOptions {

    public static final int MAX_CAPTURE_DELAY_SECONDS = 30;
    public static final int MAX_FPS_LOG_PERIOD_SECONDS = 60;

    private boolean metalEnabled;
    private boolean testFrame;
    private boolean metalDraw;
    private int captureDelaySeconds;
    private boolean cullBackFaces;
    private boolean fpsLogging;
    private int fpsLogPeriodSeconds;
    private boolean debugOverlay;

    public MagnesiumOptions() {
        this.metalEnabled =
                "true".equalsIgnoreCase(System.getProperty("magnesium.metal.enabled"));
        this.testFrame =
                "true".equalsIgnoreCase(System.getProperty("magnesium.testFrame"));
        this.metalDraw = Boolean.getBoolean("magnesium.metal.draw");
        this.captureDelaySeconds = (int) (Long.getLong("magnesium.metal.draw.warmupMs", 3000L) / 1000L);
        this.cullBackFaces = false;
        this.fpsLogging = Boolean.getBoolean("magnesium.fps.log");
        this.fpsLogPeriodSeconds = Integer.getInteger("magnesium.fps.log.period", 10);
        this.debugOverlay = true;
        this.clamp();
    }

    /** Pulls out-of-range values (hand-edited config, bad -D values) back into range. */
    public void clamp() {
        this.captureDelaySeconds = Math.max(0, Math.min(MAX_CAPTURE_DELAY_SECONDS, this.captureDelaySeconds));
        this.fpsLogPeriodSeconds = Math.max(1, Math.min(MAX_FPS_LOG_PERIOD_SECONDS, this.fpsLogPeriodSeconds));
    }

    /** Copies every persisted value from {@code other}. */
    public void copyFrom(MagnesiumOptions other) {
        this.metalEnabled = other.metalEnabled;
        this.testFrame = other.testFrame;
        this.metalDraw = other.metalDraw;
        this.captureDelaySeconds = other.captureDelaySeconds;
        this.cullBackFaces = other.cullBackFaces;
        this.fpsLogging = other.fpsLogging;
        this.fpsLogPeriodSeconds = other.fpsLogPeriodSeconds;
        this.debugOverlay = other.debugOverlay;
        this.clamp();
    }

    public boolean isMetalEnabled() {
        return this.metalEnabled;
    }

    public void setMetalEnabled(boolean metalEnabled) {
        this.metalEnabled = metalEnabled;
    }

    public boolean isTestFrame() {
        return this.testFrame;
    }

    public void setTestFrame(boolean testFrame) {
        this.testFrame = testFrame;
    }

    public boolean isMetalDraw() {
        return this.metalDraw;
    }

    public void setMetalDraw(boolean metalDraw) {
        this.metalDraw = metalDraw;
    }

    public int getCaptureDelaySeconds() {
        return this.captureDelaySeconds;
    }

    public void setCaptureDelaySeconds(int seconds) {
        this.captureDelaySeconds = seconds;
        this.clamp();
    }

    public boolean isCullBackFaces() {
        return this.cullBackFaces;
    }

    public void setCullBackFaces(boolean cullBackFaces) {
        this.cullBackFaces = cullBackFaces;
    }

    public boolean isFpsLogging() {
        return this.fpsLogging;
    }

    public void setFpsLogging(boolean fpsLogging) {
        this.fpsLogging = fpsLogging;
    }

    public int getFpsLogPeriodSeconds() {
        return this.fpsLogPeriodSeconds;
    }

    public void setFpsLogPeriodSeconds(int seconds) {
        this.fpsLogPeriodSeconds = seconds;
        this.clamp();
    }

    public boolean isDebugOverlay() {
        return this.debugOverlay;
    }

    public void setDebugOverlay(boolean debugOverlay) {
        this.debugOverlay = debugOverlay;
    }
}
