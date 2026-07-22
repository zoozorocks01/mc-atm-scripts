# SimpleAFK Look Guard

Tiny server-side NeoForge 1.21.1 mixin for SimpleAFK 1.5.2.

SimpleAFK clears AFK when `AFKPlayer.hasPlayerLookedAround` sees an exact
`Vec3.equals` difference. Tiny server-side look-vector jitter therefore looks
like real player activity. This patch treats only a vector delta above `1e-6`
(squared delta `1e-12`) as a look change. Normal movement handling is untouched.

Build locally with the matching SimpleAFK, Sponge Mixin, and mapped Minecraft
server jars in `libs/`:

```sh
JAVA_HOME=/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home ./build.sh
```

The build runs the jitter regression and writes
`build/simpleafk-look-guard-1.0.0.jar`. Deployment requires Zach's explicit
approval and a normal server restart.
