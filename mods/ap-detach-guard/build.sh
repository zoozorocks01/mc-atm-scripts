#!/bin/sh
# Build ap-detach-guard without gradle: compile the one mixin class against the
# server's own jars, then package. Produces build/ap-detach-guard-<version>.jar.
#
# Deps (fetch from the live server if the defaults are missing; paths shown for
# the intel test server -- on macpro swap the ATM10-server-7.0-* dir):
#   scp zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/mods/AdvancedPeripherals-1.21.1-0.7.61b.jar libs/
#   scp zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/mods/cc-tweaked-1.21.1-forge-1.117.1.jar libs/
#   scp zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/mods/refinedstorage-neoforge-2.0.6.jar libs/
#   scp zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/mods/refined-types-1.21.1-0.3.0.jar libs/
#   scp "zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/libraries/net/fabricmc/sponge-mixin/0.15.2+mixin.0.8.7/sponge-mixin-0.15.2+mixin.0.8.7.jar" libs/
#   scp "zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/libraries/net/minecraft/server/1.21.1-*/server-1.21.1-*-srg.jar" libs/
#
# Env overrides: JAVA_HOME, APDG_LIBS (dir holding the jars listed above).
set -eu

cd "$(dirname "$0")"
VERSION="1.1.0"
LIBS="${APDG_LIBS:-libs}"

# Resolve a real JDK 21 home. A valid JDK home has bin/javac AND a release file;
# this guard rejects JAVA_HOME=/usr -- macOS ships a /usr/bin/javac *stub* that
# hangs indefinitely when it is forced to act as the compiler (observed on macpro
# 2026-07-09). Prefer an explicit valid JAVA_HOME, else macOS java_home (temurin
# on macpro), else the Homebrew openjdk path used on the intel host.
apdg_jdk_ok() { [ -x "$1/bin/javac" ] && [ -f "$1/release" ]; }
if [ -n "${JAVA_HOME:-}" ] && apdg_jdk_ok "$JAVA_HOME"; then
  JBIN="$JAVA_HOME/bin"
elif [ -x /usr/libexec/java_home ] && JH="$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home 2>/dev/null)" && apdg_jdk_ok "$JH"; then
  JBIN="$JH/bin"
elif apdg_jdk_ok /usr/local/opt/openjdk@21; then
  JBIN="/usr/local/opt/openjdk@21/bin"
else
  echo "build.sh: no JDK 21 found; set JAVA_HOME to a JDK home (needs bin/javac + release)" >&2
  exit 1
fi

AP_JAR=$(ls "$LIBS"/AdvancedPeripherals-*.jar | head -1)
CC_JAR=$(ls "$LIBS"/cc-tweaked-*.jar | head -1)
MIXIN_JAR=$(ls "$LIBS"/*mixin*.jar | head -1)
# RSApiGetTasksMixin compiles against Refined Storage API types (Network,
# TaskStatus, AutocraftingNetworkComponent) — ship refinedstorage-neoforge and
# refined-types alongside the other jars.
RS_JAR=$(ls "$LIBS"/refinedstorage-neoforge-*.jar | head -1)
RT_JAR=$(ls "$LIBS"/refined-types-*.jar 2>/dev/null | head -1 || true)
# RSApiGetTasksMixin -> RSBridgeEntity.getJobs(): resolving that call drags in
# RSBridgeEntity's supertype chain, which reaches net.minecraft.world.WorldlyContainer.
# Without the mapped Minecraft server jar javac can't close the hierarchy; the *joint*
# compile of both mixins then spins in multi-minute error-recovery (silent, no output)
# instead of failing fast. The mixin bytecode references no MC type, so any mapped
# server jar (server-<ver>-srg.jar carries named net.minecraft.* classes) is fine.
MC_JAR=$(ls "$LIBS"/server-*-srg.jar | head -1)

rm -rf build/classes build/jar
mkdir -p build/classes
# -proc:none: sponge-mixin bundles a refmap annotation processor that needs ASM;
# we use remap=false string targets, so no refmap and no processor.
"$JBIN/javac" --release 21 -proc:none \
  -cp "$AP_JAR:$CC_JAR:$MIXIN_JAR:$RS_JAR${RT_JAR:+:$RT_JAR}:$MC_JAR" \
  -d build/classes \
  src/dev/zjn/apdetachguard/mixin/*.java

mkdir -p build/jar
cp -R build/classes/. build/jar/
cp -R resources/. build/jar/
"$JBIN/jar" --create --file "build/ap-detach-guard-$VERSION.jar" -C build/jar .

echo "built: build/ap-detach-guard-$VERSION.jar"
"$JBIN/jar" --list --file "build/ap-detach-guard-$VERSION.jar"
