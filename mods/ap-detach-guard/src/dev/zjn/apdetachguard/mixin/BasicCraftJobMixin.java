package dev.zjn.apdetachguard.mixin;

import dan200.computercraft.api.peripheral.IComputerAccess;
import dan200.computercraft.api.peripheral.NotAttachedException;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * Guards AdvancedPeripherals' craft-job event dispatch against the detached-computer
 * server crash.
 *
 * AP keeps a computer's craft jobs ticking after the computer detaches (reboot, chunk
 * unload, block broken) and fires each state change at it via
 * {@code IComputerAccess.queueEvent}, with no attachment check and no try/catch. CC
 * throws {@link NotAttachedException} from that call, which escapes into
 * {@code RSBridgeEntity.handleTick} (or RS's task-status listener) on the SERVER
 * thread and crashes the whole server tick. Verified against AP 1.21.1-0.7.61b:
 * both {@code BasicCraftJob.fireEvent} overloads contain exactly one such invoke.
 *
 * This redirect wraps that single call site in a try/catch: a job whose computer is
 * gone simply drops its event and purges through AP's normal lifecycle instead of
 * killing the server. Remove this mod once upstream fixes it
 * (github.com/IntelligenceModding/AdvancedPeripherals).
 */
@Mixin(targets = "de.srendi.advancedperipherals.common.util.inventory.BasicCraftJob", remap = false)
public abstract class BasicCraftJobMixin {

    @Redirect(
        method = {
            "fireEvent(ZLde/srendi/advancedperipherals/common/util/StatusConstants;)V",
            "fireEvent(ZLjava/lang/String;)V"
        },
        at = @At(
            value = "INVOKE",
            target = "Ldan200/computercraft/api/peripheral/IComputerAccess;queueEvent(Ljava/lang/String;[Ljava/lang/Object;)V",
            remap = false
        ),
        remap = false
    )
    private void apdetachguard$guardQueueEvent(IComputerAccess computer, String event, Object[] arguments) {
        try {
            computer.queueEvent(event, arguments);
        } catch (NotAttachedException ignored) {
            // The issuing computer is gone; there is nowhere to deliver the event.
            // Swallowing it here is exactly what a fixed AP would do.
        }
    }
}
