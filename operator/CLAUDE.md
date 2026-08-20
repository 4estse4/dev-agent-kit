<!--
  WHY THIS EXISTS: Claude Code 2.1.x stock 바이너리의 Agent 툴 description에
  "Do not spawn agents unless the user asks" 가 하드코딩돼 있음 (strings로 확인, 2026-05).
  이 보수적 디폴트를 의도적으로 덮어쓰는 정책. user-level이라 모든 프로젝트에 적용됨.
  서브에이전트 동작이 평소와 다르면 이 파일부터 확인할 것.
-->

## Subagent usage policy

For every task that could warrant a subagent (Task/Agent tool), classify it first:

1. **Clearly inline** — narrow locate-then-read, I already hold the needed context, and finding the answer is not a wide search → proceed inline without asking.
2. **Clearly worth a subagent** — wide fan-out search where I only need the conclusion (not the raw evidence), or heavy context isolation that would otherwise bloat the main window → spawn it, then report in one line afterward: agent type, why, and what came back.
3. **Genuinely ambiguous** — large task but I may need the raw evidence in my own context to judge it, or the cost/benefit is close → do NOT spawn yet. State (a) my recommendation (subagent vs inline), (b) the one-sentence reason, (c) the rough cost tradeoff (extra context window + cold-start re-read vs. main-window savings). Then wait for my go.

Deciding question, always: do I need the raw evidence in my own context, AND is finding the answer a wide search? Both align → act (case 1 or 2). They conflict → ask (case 3). This overrides the stock "do not spawn unless asked" default — use on-demand judgment, don't wait for me to explicitly request a subagent each time.
