package dev.zjn.simpleafkdiagnostics.mixin;

import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Logs AFK-clear provenance without changing SimpleAFK's result or state. */
@Mixin(targets = "dk.magnusjensen.simpleafk.AFKPlayer", remap = false)
public abstract class AFKPlayerDiagnosticsMixin {
    @Shadow private boolean isAfk;
    @Shadow private ServerPlayer player;
    @Shadow private Vec3 lastLookAngle;
    @Shadow private BlockPos lastPosition;

    @Inject(method = "removeAfkStatus", at = @At("HEAD"), remap = false)
    private void simpleafkdiagnostics$recordClearPath(CallbackInfo ci) {
        // Match upstream's first branch: ordinary interactions call this method too.
        if (!ClearPath.shouldLog(isAfk)) return;
        Vec3 currentLook = player.getLookAngle();
        BlockPos currentPosition = player.blockPosition();
        String path = ClearPath.subscribedHandlerFromStack();
        if (path == null) {
            path = ClearPath.tickPath(!currentLook.equals(lastLookAngle), !currentPosition.equals(lastPosition));
        }
        System.out.println("[simpleafk-afk-diagnostics] clear path=" + path
            + " player=" + player.getUUID()
            + " look.current=" + currentLook + " look.baseline=" + lastLookAngle
            + " position.current=" + currentPosition + " position.baseline=" + lastPosition);
    }
}
