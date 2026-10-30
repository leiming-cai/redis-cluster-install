#!/usr/bin/env bash
# probe-cluster-execute.sh — prove the premise the napstarweb cluster branch
# stands on, against a REAL Redis cluster.
#
# The premise: in Redis Cluster mode, Spring Data Redis 2.7.18's
# RedisTemplate.executePipelined(...) throws UnsupportedOperationException and
# the callback never runs, so not a single Redis command is sent. The
# execute(...) overload works and routes each single-key command by slot.
#
# Everything else in the cluster branch (replacing the pipelined writers with
# execute(...) writers) rests on that one fact. It used to live only in a
# temporary directory, which the OS wipes; this script makes it reproducible
# instead of re-derivable.
#
# The probe is compiled against the classpath taken from napstarweb's own fat
# jar -- the dependency versions napstarweb actually ships -- not against
# whatever happens to be in the local maven repository. A probe run against
# different jars would be testing a different question.
#
# Usage (the host has no usable bash; see scripts/bench-consumer-write.sh for
# the containerised form of this pattern):
#   PROBE_JAR=<napstarweb fat jar> bash scripts/probe-cluster-execute.sh
#
# Env:
#   PROBE_JAR         napstarweb fat jar to take the classpath from. Default
#                     points at the application/backend build output.
#   CLASSPATH_JARS    directory of loose jars to compile against INSTEAD of
#                     extracting the fat jar. This is the fallback for when
#                     the fat jar has not been built; it tests the maven-repo
#                     versions, which is weaker evidence -- the script says so
#                     out loud when it is used.
#   JAVA_HOME          JDK 8 home. The probe must be built with JDK 8: the
#                     shipped napstarweb bytecode is Java 8, and SDR 2.7.18
#                     does not build/run under a newer javac target.
#   CLUSTERS          comma-separated cluster node list. Default the local
#                     e2e cluster.
#   PASSWORD          cluster requirepass.
#   CP_SEP            classpath separator. Defaults to ';' on Windows and ':'
#                     elsewhere -- the JDK's own separator, not a guess.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO_ROOT/lib/common.sh"

AB_DIR="${AB_DIR:-D:/javawork/1.2/cpscloud1.0/code/application/backend}"
PROBE_JAR="${PROBE_JAR:-$AB_DIR/napstarweb/web-controller/target/web-controller-1.0.14.jar}"
JAVA_HOME="${JAVA_HOME:-D:/java/java-se-8u42-ri}"
CLUSTERS="${CLUSTERS:-127.0.0.1:16379}"
PASSWORD="${PASSWORD:-CpsE2eClusterPw}"
PROBE_SRC="$REPO_ROOT/tests/probes/cluster-execute-probe.java"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# The classpath separator belongs to the JVM, not to this script. On Windows
# the separator is ';' and a Unix path list pasted in as-is would be read as
# ONE enormous filename, so the probe would not compile -- and the failure
# would look like a missing dependency rather than a wrong separator.
case "$(uname -s 2>/dev/null || echo Windows)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) CP_SEP="${CP_SEP:-;}" ;;
    *)                            CP_SEP="${CP_SEP:-:}" ;;
esac

# The jars the probe touches. spring-aop is NOT optional: RedisTemplate.execute
# reaches org.aopalliance.aop.Advice, which SDR 2.7.18 inlines into
# spring-aop. Without it the probe dies with NoClassDefFoundError and the run
# proves nothing about pipelines.
PROBE_JARS="spring-data-redis spring-data-commons spring-data-keyvalue \
jedis commons-pool2 spring-core spring-beans spring-context spring-tx \
spring-jcl spring-expression spring-aop jackson-databind jackson-core \
jackson-annotations slf4j-api"

log_info "probe source: $PROBE_SRC"
[ -f "$PROBE_SRC" ] || die "probe source not found: $PROBE_SRC"

[ -x "$JAVA_HOME/bin/javac" ] || die "JDK 8 not found at $JAVA_HOME (set JAVA_HOME)"

CP=""
if [ -n "${CLASSPATH_JARS:-}" ]; then
    # Fallback mode: loose jars. Weaker evidence than the fat jar, so say so.
    [ -d "$CLASSPATH_JARS" ] || die "CLASSPATH_JARS is not a directory: $CLASSPATH_JARS"
    log_warn "using CLASSPATH_JARS=$CLASSPATH_JARS INSTEAD of the fat jar"
    log_warn "the probe is then testing the maven-repo versions, not the versions napstarweb ships"
    # Newline-delimited, never space-delimited: a jar path may contain a space.
    found=""
    for name in $PROBE_JARS; do
        hit="$(find "$CLASSPATH_JARS" -name "${name}-*.jar" -type f 2>/dev/null | sort | head -n 1)"
        [ -n "$hit" ] || die "no jar matching ${name}-*.jar under $CLASSPATH_JARS"
        found="$found$hit
"
    done
    CP="$(printf '%s' "$found" | tr -d '\r' | grep -v '^$' | paste -sd "$CP_SEP" -)"
else
    [ -f "$PROBE_JAR" ] \
        || die "fat jar not found: $PROBE_JAR (set PROBE_JAR, set CLASSPATH_JARS, or build napstarweb first)"

    log_info "extracting BOOT-INF/lib from $PROBE_JAR"
    # The JDK's own `jar` tool, not `unzip`: this script already requires a
    # JDK, so requiring one more external binary would be a dependency the
    # Windows host does not necessarily have (it has no unzip).
    #
    # The version in the jar name is not known here, so ask the archive itself
    # for the matching entry instead of hard-coding a version that would
    # silently rot on the next dependency bump.
    all_entries="$("$JAVA_HOME/bin/jar" tf "$PROBE_JAR")" \
        || die "cannot list $PROBE_JAR"
    extract_args=""
    for name in $PROBE_JARS; do
        entry="$(printf '%s\n' "$all_entries" | grep -E "^BOOT-INF/lib/${name}-[^/]*\.jar$" | head -n 1)"
        [ -n "$entry" ] || die "fat jar has no BOOT-INF/lib/${name}-*.jar"
        extract_args="$extract_args $entry"
    done
    # shellcheck disable=SC2086
    ( cd "$WORK_DIR" && "$JAVA_HOME/bin/jar" xf "$PROBE_JAR" $extract_args ) \
        || die "failed to extract BOOT-INF/lib from $PROBE_JAR"

    found=""
    for name in $PROBE_JARS; do
        hit="$(find "$WORK_DIR/BOOT-INF/lib" -name "${name}-*.jar" -type f 2>/dev/null | head -n 1)"
        [ -n "$hit" ] || die "extracted no jar for $name"
        found="$found$hit
"
    done
    CP="$(printf '%s' "$found" | tr -d '\r' | grep -v '^$' | paste -sd "$CP_SEP" -)"
fi

[ -n "$CP" ] || die "empty classpath"

log_info "classpath:"
# A `for j in $(...)` loop would split a path containing a space into two
# bogus entries. The classpath is printed for the record -- it is the evidence
# of WHICH versions the probe ran against -- so it has to be printed accurately.
printf '%s' "$CP" | tr "$CP_SEP" '\n' | while IFS= read -r j; do
    [ -n "$j" ] && log_info "  $j"
done

log_info "compiling the probe"
"$JAVA_HOME/bin/javac" -encoding UTF-8 -cp "$CP" -d "$WORK_DIR" "$PROBE_SRC" \
    || die "probe compile failed"

log_info "running the probe against $CLUSTERS"
# -Dfile.encoding=UTF-8: on JDK 8 the JVM's default charset comes from the
# platform locale, and a Windows or C-locale console turns the probe's Chinese
# output into mojibake. That is cosmetic, but it makes a PASSING run look
# broken, which is worse than no output at all.
"$JAVA_HOME/bin/java" -Dfile.encoding=UTF-8 -cp "$WORK_DIR$CP_SEP$CP" \
    ClusterExecuteProbe "$CLUSTERS" "$PASSWORD"
rc=$?
[ "$rc" -eq 0 ] || die "probe exited with $rc"

log_ok "PROBE OK"
