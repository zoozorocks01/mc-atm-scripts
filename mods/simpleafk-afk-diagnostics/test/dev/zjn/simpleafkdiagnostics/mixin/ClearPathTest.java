package dev.zjn.simpleafkdiagnostics.mixin;

public final class ClearPathTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        String owner = "dk.magnusjensen.simpleafk.NeoforgeSimpleAFK";
        check("event:left-click-block".equals(ClearPath.subscribedHandler(owner, "onPlayerLeftClickBlock")), "left click block");
        check("event:left-click-empty".equals(ClearPath.subscribedHandler(owner, "onPlayerLeftClickEmpty")), "left click empty");
        check("event:right-click-empty".equals(ClearPath.subscribedHandler(owner, "onPlayerRightClickEmpty")), "right click empty");
        check("event:right-click-block".equals(ClearPath.subscribedHandler(owner, "onPlayerRightClickBlock")), "right click block");
        check("event:right-click-item".equals(ClearPath.subscribedHandler(owner, "onPlayerRightClickItem")), "right click item");
        check("event:interact-entity".equals(ClearPath.subscribedHandler(owner, "onPlayerInteractEntity")), "interact entity");
        check("event:attack-entity".equals(ClearPath.subscribedHandler(owner, "onPlayerAttackEntity")), "attack entity");
        check("event:chat".equals(ClearPath.subscribedHandler(owner, "onPlayerMessage")), "chat without content");
        check(ClearPath.subscribedHandler(owner, "onPlayerTick") == null, "tick is not an event handler");
        check("tick:look".equals(ClearPath.tickPath(true, false)), "tick look");
        check("tick:position".equals(ClearPath.tickPath(false, true)), "tick position");
        check("tick:look+position".equals(ClearPath.tickPath(true, true)), "tick both");
        System.out.println("CLEAR-PATH OK");
    }
}
