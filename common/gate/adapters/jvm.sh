#!/usr/bin/env bash
# JVM 게이트. CWD = 빌드 루트(settings.gradle* 또는 pom.xml 이 있는 곳). lib.sh 는 이미 source 됨.
#
# 빌드는 빌드 도구가, 린트는 독립 바이너리가 맡는다 — Go 와 같은 모양이다.
# 진입점이 언어가 아니라 빌드 도구(Gradle·Maven)라서 어댑터가 하나다.
#
# **린트가 보장되는 것은 Kotlin 뿐이다.** Java 는 지금 다루지 않는다 — 킷이 린터를
# 꽂아주는 다른 언어들(Go·TS·Kotlin·Python)과 달리 Java 는 빈 채로 두었다.
# Java 소스가 있어도 gradle check / mvn verify 로 **컴파일과 테스트는** 돌지만,
# 프로젝트가 checkstyle 등을 스스로 켜지 않았다면 린트는 0이다.
# 필요해지면 checkstyle 독립 CLI 를 ktlint 와 같은 모양으로 붙이면 된다.
#
#   린트   ktlint 를 직접 부른다. 독립 실행 바이너리를 배포하고 .editorconfig 를 규칙
#          소스로 읽으므로, 프로젝트가 빌드 스크립트에 무엇을 등록했든 킷이 린트를
#          보장할 수 있다. (spotless 처럼 빌드에 붙는 도구는 아래 check/verify 가 잡는다.)
#   빌드   Gradle 의 `check` · Maven 의 `verify` 한 곳에만 붙는다. 프로젝트가 켠 품질
#          플러그인이 스스로 갈고리를 거는 표준 집계 지점이다.
#
# 린트가 빌드 도구 판정보다 **앞에** 있는 것은 의도다. gradle 이 없다고 린트까지
# 건너뛰면, 빌드 도구가 없는 환경에서 게이트가 조용히 아무것도 안 하게 된다.

# 린트는 빌드 도구를 거치지 않고 직접 돈다 — golangci-lint 와 같은 모양이다.
# ktlint 는 독립 실행 바이너리를 배포하고 .editorconfig 를 규칙 소스로 읽으므로,
# 프로젝트가 빌드 스크립트에 무엇을 등록했든 상관없이 킷이 린트를 보장할 수 있다.
# (spotless 를 켠 프로젝트라면 그쪽은 아래 check/verify 로 함께 잡힌다.)
if ls ./*.kt ./*.kts >/dev/null 2>&1 || find . -name '*.kt' -not -path './build/*' -print -quit 2>/dev/null | grep -q .; then
  if gate_have ktlint; then
    gate_run "ktlint" ktlint --relative
  else
    gate_skip "ktlint"
  fi
fi

# --lint 모드는 여기서 끝난다 — gradle check / mvn verify 는 컴파일과 테스트라
# 커밋 단계에 두기엔 비싸다. 린트(ktlint)는 위에서 이미 돌았다.
[ "${GATE_LINT_ONLY:-0}" = 1 ] && { return 0 2>/dev/null || exit 0; }

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
