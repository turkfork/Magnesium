package turkfork.magnesium.client.mixin;

import me.jellysquid.mods.sodium.client.render.chunk.shader.ChunkShaderInterface;
import org.joml.Matrix4fc;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.device.MagnesiumMatrixHook;

/**
 * Records the exact {@code u_ProjectionMatrix} and {@code u_ModelViewMatrix}
 * Sodium uploads to the chunk shader, so the Metal capture reproduces Sodium's
 * {@code gl_Position} with the unmodified matrices.
 */
@Mixin(ChunkShaderInterface.class)
public class ChunkShaderInterfaceMixin {

    @Inject(method = "setProjectionMatrix", at = @At("HEAD"))
    private void magnesium$captureProjection(Matrix4fc projection, CallbackInfo ci) {
        MagnesiumMatrixHook.captureProjection(projection);
    }

    @Inject(method = "setModelViewMatrix", at = @At("HEAD"))
    private void magnesium$captureModelView(Matrix4fc modelView, CallbackInfo ci) {
        MagnesiumMatrixHook.captureModelView(modelView);
    }
}