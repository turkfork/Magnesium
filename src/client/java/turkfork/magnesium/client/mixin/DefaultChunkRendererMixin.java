package turkfork.magnesium.client.mixin;

import me.jellysquid.mods.sodium.client.render.chunk.DefaultChunkRenderer;
import me.jellysquid.mods.sodium.client.render.chunk.region.RenderRegion;
import me.jellysquid.mods.sodium.client.render.chunk.shader.ChunkShaderInterface;
import me.jellysquid.mods.sodium.client.render.viewport.CameraTransform;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.device.MagnesiumRegionHook;

/**
 * Captures the render region origin right before Sodium uploads it as the
 * {@code u_RegionOffset} chunk-shader uniform, so the Metal side can reproduce
 * the exact camera-relative vertex transform without touching GL state.
 */
@Mixin(DefaultChunkRenderer.class)
public class DefaultChunkRendererMixin {

    @Inject(method = "setModelMatrixUniforms", at = @At("HEAD"))
    private static void magnesium$captureRegionOrigin(
            ChunkShaderInterface shader,
            RenderRegion region,
            CameraTransform camera,
            CallbackInfo ci) {
        MagnesiumRegionHook.captureOrigin(
                region.getOriginX(), region.getOriginY(), region.getOriginZ());
    }
}