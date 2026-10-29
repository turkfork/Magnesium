package turkfork.magnesium.client.mixin;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.device.MagnesiumAtlasDirty;

/**
 * Brackets an animated sprite's upload so {@link NativeImageMixin} knows the
 * {@code NativeImage.upload} calls inside it are atlas animation frames.
 */
@Mixin(targets = "net.minecraft.client.renderer.texture.SpriteContents$Ticker")
public abstract class SpriteTickerMixin {

    @Inject(method = "tickAndUpload", at = @At("HEAD"))
    private void magnesium$begin(int x, int y, CallbackInfo ci) {
        MagnesiumAtlasDirty.capturing = true;
    }

    @Inject(method = "tickAndUpload", at = @At("RETURN"))
    private void magnesium$end(int x, int y, CallbackInfo ci) {
        MagnesiumAtlasDirty.capturing = false;
    }
}
