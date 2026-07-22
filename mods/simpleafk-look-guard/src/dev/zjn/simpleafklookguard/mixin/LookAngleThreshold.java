package dev.zjn.simpleafklookguard.mixin;

import net.minecraft.world.phys.Vec3;

final class LookAngleThreshold {
    static final double DELTA_SQUARED = 1.0e-12;

    private LookAngleThreshold() {
    }

    static boolean hasMeaningfulChange(Vec3 current, Object previous) {
        if (!(previous instanceof Vec3 last)) {
            return true;
        }
        return hasMeaningfulChange(current.x - last.x, current.y - last.y, current.z - last.z);
    }

    static boolean hasMeaningfulChange(double dx, double dy, double dz) {
        return dx * dx + dy * dy + dz * dz > DELTA_SQUARED;
    }
}
