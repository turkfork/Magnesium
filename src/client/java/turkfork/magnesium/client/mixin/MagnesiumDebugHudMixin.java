package turkfork.magnesium.client.mixin;

import net.minecraft.client.gui.components.DebugScreenOverlay;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import turkfork.magnesium.client.renderer.MagnesiumDebugInfo;

import java.util.List;

/**
 * Injects Magnesium's live status into Minecraft's F3 debug overlay by
 * appending lines to the left-hand text produced by
 * {@link DebugScreenOverlay#getGameInformation()}.
 */
@Mixin(DebugScreenOverlay.class)
public class MagnesiumDebugHudMixin {

    @Inject(method = "getGameInformation", at = @At("RETURN"), remap = true)
    private void magnesium$appendDebugLines(
            CallbackInfoReturnable<List<String>> cir) {
        List<String> lines = cir.getReturnValue();
        if (lines != null) {
            MagnesiumDebugInfo.appendTo(lines);
        }
    }
}