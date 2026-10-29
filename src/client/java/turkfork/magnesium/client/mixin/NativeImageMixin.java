package turkfork.magnesium.client.mixin;

import com.mojang.blaze3d.platform.NativeImage;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.device.MagnesiumAtlasDirty;
import turkfork.magnesium.client.renderer.device.MagnesiumPixelAccess;

/**
 * Copies the pixels of an animated sprite frame as Minecraft uploads it to the
 * block atlas. Reading them from the CPU-side image avoids a GL readback (and
 * the pipeline stall that comes with it) when mirroring the atlas to Metal.
 */
@Mixin(NativeImage.class)
public abstract class NativeImageMixin implements MagnesiumPixelAccess {

    @Shadow
    private long pixels;

    @Shadow
    public abstract int getWidth();

    @Override
    public long magnesium$pixels() {
        return this.pixels;
    }

    @Inject(method = "upload(IIIIIIIZZZZ)V", at = @At("HEAD"))
    private void magnesium$captureUpload(int level, int x, int y, int skipX, int skipY,
                                         int width, int height, boolean blur, boolean clamp,
                                         boolean mipmap, boolean autoClose, CallbackInfo ci) {
        if (MagnesiumAtlasDirty.capturing && this.pixels != 0L) {
            MagnesiumAtlasDirty.addTile(level, x, y, width, height,
                    this.pixels, this.getWidth(), skipX, skipY);
        }
    }
}
