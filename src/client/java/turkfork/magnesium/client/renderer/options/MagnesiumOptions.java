package turkfork.magnesium.client.renderer.options;

// Runtime configuration for Magnesium. Values are held in-memory so the
// Sodium settings tab can toggle them live. Freshly-launched defaults come
// from their corresponding -D system properties.
public final class MagnesiumOptions {

    private boolean metalEnabled;
    private boolean testFrame;

    public MagnesiumOptions() {
        this.metalEnabled =
                "true".equalsIgnoreCase(System.getProperty("magnesium.metal.enabled"));
        this.testFrame =
                "true".equalsIgnoreCase(System.getProperty("magnesium.testFrame"));
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
}