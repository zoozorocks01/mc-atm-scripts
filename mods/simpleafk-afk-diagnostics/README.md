# SimpleAFK AFK-Clear Diagnostics

Temporary server-side NeoForge 1.21.1 diagnostic mixin for SimpleAFK 1.5.2.
It logs the source of each actual AFK clear plus the current/baseline look
vectors and block positions. It never logs chat content and does not alter
SimpleAFK control flow. Remove it after one bounded reproduction.

Build with matching SimpleAFK, Sponge Mixin, and mapped Minecraft server jars
in `libs/`:

```sh
JAVA_HOME=/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home ./build.sh
```

Output: `build/simpleafk-afk-diagnostics-1.0.0.jar`.
