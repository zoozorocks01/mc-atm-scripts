package dev.zjn.simpleafklookguard.mixin;

public final class LookAngleThresholdTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        check(!LookAngleThreshold.hasMeaningfulChange(5e-7, 0, 0),
            "sub-threshold view-vector jitter must not clear AFK");
        check(LookAngleThreshold.hasMeaningfulChange(1e-4, 0, 0),
            "real look movement must still clear AFK");
        check(LookAngleThreshold.hasMeaningfulChange(0, 0, 2e-6),
            "strictly above the threshold must count as look movement");
        System.out.println("LOOK-ANGLE-THRESHOLD OK");
    }
}
