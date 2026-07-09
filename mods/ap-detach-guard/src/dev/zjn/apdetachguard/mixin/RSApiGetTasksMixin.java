package dev.zjn.apdetachguard.mixin;

import com.refinedmods.refinedstorage.api.autocrafting.status.TaskStatus;
import com.refinedmods.refinedstorage.api.network.Network;
import com.refinedmods.refinedstorage.api.network.autocrafting.AutocraftingNetworkComponent;
import de.srendi.advancedperipherals.common.addons.refinedstorage.RSApi;
import de.srendi.advancedperipherals.common.addons.refinedstorage.RSCraftJob;
import de.srendi.advancedperipherals.common.blocks.blockentities.RSBridgeEntity;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.ArrayList;
import java.util.List;

/**
 * Guards AdvancedPeripherals' getCraftingTasks against the poisoned-job NPE.
 *
 * AP keeps an RSCraftJob list per bridge entity; a job's backing RS task
 * reference can be invalidated while the job is still listed (observed live
 * 2026-07-08: pattern edits while a job was in flight; first NPE 15:59:59,
 * 937 repeats). AP 0.7.61b then dereferences it with no null check --
 * {@code task.getCraftingTask().info().id()} inside
 * {@code RSApi.getCraftingTasks} (RSApi.java:527) -- so EVERY
 * getCraftingTasks peripheral call throws, the manager's craft visibility
 * goes dark (activeCraftCount pinned at 0), and craft jobs die at ~20s with
 * "craft failed" while delivering late or not at all. Until this guard, the
 * only cure was rebooting the computer to purge the job list.
 *
 * This mixin replaces the method body with a faithful copy (verified against
 * the shipped 0.7.61b bytecode: getCraftingTasks(Network, RSBridgeEntity),
 * public static parseCraftingTask(RSCraftJob, TaskStatus,
 * AutocraftingNetworkComponent)) plus the single missing null check: a job
 * whose task reference is gone simply does not match any live status, exactly
 * as a fixed AP would behave. Remove once upstream fixes it
 * (github.com/IntelligenceModding/AdvancedPeripherals).
 */
@Mixin(value = RSApi.class, remap = false)
public abstract class RSApiGetTasksMixin {

    @Inject(method = "getCraftingTasks", at = @At("HEAD"), cancellable = true, remap = false)
    private static void apdetachguard$nullSafeGetCraftingTasks(Network network, RSBridgeEntity entity,
            CallbackInfoReturnable<List<Object>> cir) {
        List<Object> tasks = new ArrayList<>();
        AutocraftingNetworkComponent autocrafting = network.getComponent(AutocraftingNetworkComponent.class);

        outer:
        for (TaskStatus status : autocrafting.getStatuses()) {
            for (RSCraftJob job : entity.getJobs()) {
                TaskStatus jobTask = job.getCraftingTask();
                // The null check upstream forgot: a poisoned job matches nothing.
                if (jobTask != null && status.info().id().equals(jobTask.info().id())) {
                    tasks.add(RSApi.parseCraftingTask(job, status, autocrafting));
                    continue outer;
                }
            }
            tasks.add(RSApi.parseCraftingTask(null, status, autocrafting));
        }
        cir.setReturnValue(tasks);
    }
}
