package dev.zjn.simpleafkdiagnostics.mixin;

final class ClearPath {
    private ClearPath() {
    }

    static boolean shouldLog(boolean isAfk) {
        return isAfk;
    }

    static String subscribedHandler(String className, String methodName) {
        if (!"dk.magnusjensen.simpleafk.NeoforgeSimpleAFK".equals(className)) return null;
        return switch (methodName) {
            case "onPlayerLeftClickBlock" -> "event:left-click-block";
            case "onPlayerLeftClickEmpty" -> "event:left-click-empty";
            case "onPlayerRightClickEmpty" -> "event:right-click-empty";
            case "onPlayerRightClickBlock" -> "event:right-click-block";
            case "onPlayerRightClickItem" -> "event:right-click-item";
            case "onPlayerInteractEntity" -> "event:interact-entity";
            case "onPlayerAttackEntity" -> "event:attack-entity";
            case "onPlayerMessage" -> "event:chat";
            default -> null;
        };
    }

    static String subscribedHandlerFromStack() {
        return StackWalker.getInstance().walk(frames -> frames
            .map(frame -> subscribedHandler(frame.getClassName(), frame.getMethodName()))
            .filter(path -> path != null)
            .findFirst()
            .orElse(null));
    }

    static String tickPath(boolean lookChanged, boolean positionChanged) {
        if (lookChanged && positionChanged) return "tick:look+position";
        if (lookChanged) return "tick:look";
        if (positionChanged) return "tick:position";
        return "unknown";
    }
}
