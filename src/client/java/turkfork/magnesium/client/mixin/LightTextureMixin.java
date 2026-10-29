package turkfork.magnesium.client.mixin;

import com.mojang.blaze3d.platform.NativeImage;
import net.minecraft.client.renderer.LightTexture;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.device.MagnesiumAtlasDirty;

/** Captures the light map from its CPU-side image instead of reading GL back. */
@Mixin(LightTexture.class)
public abstract class LightTextureMixin {

    @Shadow
    private boolean updateLightTexture;

    @Shadow
    private NativeImage lightPixels;

    @Unique
    private boolean magnesium$wasDirty;

    @Inject(method = "updateLightTexture", at = @At("HEAD"))
    private void magnesium$head(float partialTick, CallbackInfo ci) {
        this.magnesium$wasDirty = this.updateLightTexture;
    }

    @Inject(method = "updateLightTexture", at = @At("RETURN"))
    private void magnesium$capture(float partialTick, CallbackInfo ci) {
        if (this.magnesium$wasDirty) {
            MagnesiumAtlasDirty.setLight(this.lightPixels);
        }
    }
}
