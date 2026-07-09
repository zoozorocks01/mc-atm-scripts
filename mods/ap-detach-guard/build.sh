#!/bin/sh
# Build ap-detach-guard without gradle: compile the one mixin class against the
# server's own jars, then package. Produces build/ap-detach-guard-<version>.jar.
#
# Deps (fetch from the live server if the defaults are missing):
#   scp zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/mods/AdvancedPeripherals-1.21.1-0.7.61b.jar libs/
#   scp zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/mods/cc-tweaked-1.21.1-forge-1.117.1.jar libs/
#   scp "zjn-home-two:~/LocalServers/ATM10-server-7.0-intel-test/libraries/net/fabricmc/sponge-mixin/0.15.2+mixin.0.8.7/sponge-mixin-0.15.2+mixin.0.8.7.jar" libs/
#
# Env overrides: JAVA_HOME, APDG_LIBS (dir holding the three jars above).
set -eu

cd "$(dirname "$0")"
VERSION="1.1.0"
LIBS="${APDG_LIBS:-libs}"
JBIN="${JAVA_HOME:-/usr/local/opt/openjdk@21}/bin"

AP_JAR=$(ls "$LIBS"/AdvancedPeripherals-*.jar | head -1)
CC_JAR=$(ls "$LIBS"/cc-tweaked-*.jar | head -1)
MIXIN_JAR=$(ls "$LIBS"/*mixin*.jar | head -1)
# RSApiGetTasksMixin compiles against Refined Storage API types (Network,
# TaskStatus, AutocraftingNetworkComponent) — ship refinedstorage-neoforge and
# refined-types alongside the other jars.
RS_JAR=$(ls "$LIBS"/refinedstorage-neoforge-*.jar | head -1)
RT_JAR=$(ls "$LIBS"/refined-types-*.jar 2>/dev/null | head -1 || true)

rm -rf build/classes build/jar
mkdir -p build/classes
# -proc:none: sponge-mixin bundles a refmap annotation processor that needs ASM;
# we use remap=false string targets, so no refmap and no processor.
"$JBIN/javac" --release 21 -proc:none \
  -cp "$AP_JAR:$CC_JAR:$MIXIN_JAR:$RS_JAR${RT_JAR:+:$RT_JAR}" \
  -d build/classes \
  src/dev/zjn/apdetachguard/mixin/*.java

mkdir -p build/jar
cp -R build/classes/. build/jar/
cp -R resources/. build/jar/
"$JBIN/jar" --create --file "build/ap-detach-guard-$VERSION.jar" -C build/jar .

echo "built: build/ap-detach-guard-$VERSION.jar"
"$JBIN/jar" --list --file "build/ap-detach-guard-$VERSION.jar"
