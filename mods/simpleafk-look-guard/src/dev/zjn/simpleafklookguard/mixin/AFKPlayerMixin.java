package dev.zjn.simpleafklookguard.mixin;

import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * SimpleAFK 1.5.2 clears AFK from an exact {@link Vec3#equals(Object)} result
 * in AFKPlayer.hasPlayerLookedAround. Preserve the original null behavior but
 * ignore vector noise below one millionth of a unit-vector component.
 */
@Mixin(targets = "dk.magnusjensen.simpleafk.AFKPlayer", remap = false)
public abstract class AFKPlayerMixin {
    @Redirect(
        method = "hasPlayerLookedAround",
        at = @At(value = "INVOKE", target = "Lnet/minecraft/world/phys/Vec3;equals(Ljava/lang/Object;)Z"),
        remap = false
    )
    private boolean simpleafklookguard$thresholdedLookEquals(Vec3 current, Object previous) {
        return !LookAngleThreshold.hasMeaningfulChange(current, previous);
    }
}
