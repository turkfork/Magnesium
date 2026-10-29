package turkfork.magnesium.client.mixin;

import net.minecraft.client.renderer.texture.SpriteLoader;
import net.minecraft.client.renderer.texture.TextureAtlas;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.device.MagnesiumAtlasDirty;

/** An atlas upload means a resource reload: the Metal copy must be rebuilt. */
@Mixin(TextureAtlas.class)
public abstract class TextureAtlasMixin {

    @Inject(method = "upload", at = @At("RETURN"))
    private void magnesium$atlasReloaded(SpriteLoader.Preparations preparations, CallbackInfo ci) {
        MagnesiumAtlasDirty.requestRemirror();
    }
}
