package turkfork.magnesium.client.mixin;

import me.jellysquid.mods.sodium.client.gui.SodiumOptionsGUI;
import me.jellysquid.mods.sodium.client.gui.options.OptionPage;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import turkfork.magnesium.client.renderer.options.MagnesiumOptionPages;

import java.util.List;

/**
 * Registers the "Magnesium" page as a tab inside the Sodium settings screen by
 * appending it to the GUI's page list once the constructor has finished
 * building Sodium's own pages.
 */
@Mixin(SodiumOptionsGUI.class)
public class SodiumOptionsGUIMixin {

    @Shadow
    @Final
    private List<OptionPage> pages;

    @Inject(method = "<init>", at = @At("RETURN"))
    private void magnesium$addPage(CallbackInfo ci) {
        this.pages.add(MagnesiumOptionPages.general());
    }
}