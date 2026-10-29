package turkfork.magnesium.client.renderer.device;

/** Mixed into NativeImage to expose its native pixel pointer. */
public interface MagnesiumPixelAccess {
    long magnesium$pixels();
}
