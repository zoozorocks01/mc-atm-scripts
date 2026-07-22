#!/bin/sh
set -eu

cd "$(dirname "$0")"
VERSION="1.0.0"
LIBS="${SAFD_LIBS:-libs}"

jdk_ok() { [ -x "$1/bin/javac" ] && [ -x "$1/bin/java" ] && [ -f "$1/release" ]; }
if [ -n "${JAVA_HOME:-}" ] && jdk_ok "$JAVA_HOME"; then
  JBIN="$JAVA_HOME/bin"
elif jdk_ok /usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home; then
  JBIN="/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home/bin"
else
  echo "build.sh: set JAVA_HOME to a JDK 21 home" >&2
  exit 1
fi

AFK_JAR=$(ls "$LIBS"/simpleafk-neoforge-1.21.1-1.5.2.jar)
MIXIN_JAR=$(ls "$LIBS"/*mixin*.jar | head -1)
MC_JAR=$(ls "$LIBS"/server-*-srg.jar | head -1)
CP="$AFK_JAR:$MIXIN_JAR:$MC_JAR"

rm -rf build
mkdir -p build/classes build/test-classes build/jar
"$JBIN/javac" --release 21 -proc:none -cp "$CP" -d build/classes src/dev/zjn/simpleafkdiagnostics/mixin/*.java
"$JBIN/javac" --release 21 -proc:none -cp "build/classes:$CP" -d build/test-classes test/dev/zjn/simpleafkdiagnostics/mixin/*.java
"$JBIN/java" -cp "build/classes:build/test-classes:$CP" dev.zjn.simpleafkdiagnostics.mixin.ClearPathTest
cp -R build/classes/. build/jar/
cp -R resources/. build/jar/
"$JBIN/jar" --create --file "build/simpleafk-afk-diagnostics-$VERSION.jar" -C build/jar .
echo "built: build/simpleafk-afk-diagnostics-$VERSION.jar"
