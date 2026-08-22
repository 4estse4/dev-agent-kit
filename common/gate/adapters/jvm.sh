#!/usr/bin/env bash
# JVM 게이트. CWD = 빌드 루트(settings.gradle* 또는 pom.xml 이 있는 곳). lib.sh 는 이미 source 됨.
#
# 진입점이 언어가 아니라 빌드 도구다 — 그래서 이 어댑터 하나가 Kotlin 과 Java 를 함께 덮는다.
# 개별 품질 도구(spotless·ktlint·detekt·checkstyle)를 여기서 열거하지 않는다.
# 프로젝트가 무엇을 켰는지는 프로젝트가 안다. Gradle 의 `check` 와 Maven 의 `verify` 가
# 그 도구들이 스스로 갈고리를 거는 표준 집계 지점이므로, 거기 한 번만 붙는다.
# (킷이 도구를 열거하면 프로젝트가 도구를 바꿀 때마다 킷을 고쳐야 한다.)

# 래퍼가 있으면 래퍼를 쓴다. 프로젝트가 래퍼를 커밋하는 이유가 버전 고정인데
# 시스템 설치본을 쓰면 그 고정이 무의미해지고, 사람마다 다른 버전으로 검사하게 된다.
if [ -x ./gradlew ]; then
  _jvm_cmd=(./gradlew)
elif [ -f build.gradle ] || [ -f build.gradle.kts ] || [ -f settings.gradle ] || [ -f settings.gradle.kts ]; then
  gate_have gradle || { gate_skip "gradle(미설치·래퍼없음)"; return 0 2>/dev/null || exit 0; }
  _jvm_cmd=(gradle)
elif [ -x ./mvnw ]; then
  _jvm_cmd=(./mvnw)
elif [ -f pom.xml ]; then
  gate_have mvn || { gate_skip "maven(미설치·래퍼없음)"; return 0 2>/dev/null || exit 0; }
  _jvm_cmd=(mvn)
else
  gate_skip "jvm(빌드 파일을 찾지 못함)"; return 0 2>/dev/null || exit 0
fi

gate_have java || { gate_skip "java(미설치)"; return 0 2>/dev/null || exit 0; }

case "${_jvm_cmd[0]}" in
  *gradlew|gradle)
    # --no-daemon: CI 러너에서 데몬이 남으면 잡이 안 끝난다. 로컬에서도 게이트는 단발이다.
    # AI_KIT_GRADLE_TASKS 로 프로젝트가 태스크를 바꿀 수 있다(게이트를 포크하지 않고).
    # shellcheck disable=SC2086
    gate_run "gradle ${AI_KIT_GRADLE_TASKS:-check}" \
      "${_jvm_cmd[@]}" --no-daemon --console=plain ${AI_KIT_GRADLE_TASKS:-check}
    ;;
  *mvnw|mvn)
    # verify 는 test 이후 단계까지 돈다 — 품질 플러그인이 붙는 곳이 대개 거기다.
    # shellcheck disable=SC2086
    gate_run "maven ${AI_KIT_MAVEN_GOALS:-verify}" \
      "${_jvm_cmd[@]}" -B ${AI_KIT_MAVEN_GOALS:-verify}
    ;;
esac
unset _jvm_cmd
