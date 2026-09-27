// ESLint flat config.
// 원칙: 포맷은 Prettier 에 맡기고, 여기서는 정확성 + 프로젝트 하드룰만 다룬다.
// 리뷰 체크리스트에 문장으로 적히던 것을 여기로 옮긴다.
//
// 필요 패키지:
//   eslint typescript-eslint @eslint/js eslint-plugin-react-hooks
// 선택 패키지:
//   eslint-plugin-jsx-a11y  ← 설치돼 있을 때만 접근성 규칙이 켜진다 (아래 참조)
import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';

// 접근성 린트는 선택이다. eslint-plugin-jsx-a11y 6.10.2 는 peer 가 eslint ^9 까지라
// eslint 10 에서는 --legacy-peer-deps 없이 설치되지 않는다(2026-08 확인).
// 하드 의존으로 두면 설정 자체가 로드 실패하므로, 있으면 켜고 없으면 조용히 건너뛴다.
// peer 범위가 갱신되면 devDependencies 에 추가하기만 하면 자동으로 켜진다.
let jsxA11y = null;
try {
  jsxA11y = (await import('eslint-plugin-jsx-a11y')).default;
} catch {
  // 미설치 — 접근성 규칙 없이 진행한다.
}

export default tseslint.config(
  {
    ignores: [
      'dist/**',
      'build/**',
      'coverage/**',
      'node_modules/**',
      'eslint.config.js',
    ],
  },

  js.configs.recommended,
  // recommendedTypeChecked 를 쓴다. 더 엄격한 strictTypeChecked 로 올리거나
  // 이보다 낮추면 그 사실을 기록한다.
  ...tseslint.configs.recommendedTypeChecked,

  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: {
      'react-hooks': reactHooks,
      ...(jsxA11y ? { 'jsx-a11y': jsxA11y } : {}),
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // 접근성 — 리뷰에서 사람이 눈으로 보던 항목을 린트 규칙으로 옮긴다(설치돼 있을 때만).
      ...(jsxA11y ? jsxA11y.flatConfigs.recommended.rules : {}),

      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/consistent-type-imports': [
        'error',
        { prefer: 'type-imports', fixStyle: 'inline-type-imports' },
      ],

      // ── 프로젝트 하드룰 코드화 ──
      // 산문 규칙은 에이전트가 "지키려 노력"하지만, 린트 규칙은 어기면 게이트가 실패한다.
      'no-restricted-syntax': [
        'error',
        {
          // FE 경계: 백엔드 호스트를 하드코딩하지 않는다. 상대경로만.
          selector: 'Literal[value=/^https?:\\u002F\\u002F/]',
          message:
            'FE 는 절대 URL 을 쓰지 않는다 — 상대경로(/api·/sse)만 쓴다. ' +
            '문서 링크 등 예외는 이 줄에 eslint-disable-next-line 과 사유를 단다.',
        },
      ],
      // FE 경계: 프론트는 Vertex/GCP SDK 를 임포트하지 않는다.
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: [
                '@google-cloud/*',
                '@google/genai',
                'google-auth-library',
                'googleapis',
              ],
              message:
                'FE 는 외부 클라우드 SDK 를 직접 쓰지 않는다 — 모든 외부 호출·인증은 backend.',
            },
          ],
        },
      ],
    },
  },

  {
    // 빌드 설정 파일은 절대 URL(dev 프록시 대상 등)이 정상이다.
    files: ['*.config.{ts,js,mts,mjs}', 'vite.config.*', 'vitest.setup.*'],
    rules: { 'no-restricted-syntax': 'off' },
  },

  {
    files: ['**/*.test.{ts,tsx}', '**/*.spec.{ts,tsx}'],
    rules: {
      // 테스트는 rejection 을 expect 로 읽는 것이 정상이다.
      '@typescript-eslint/no-floating-promises': 'off',
      // 테스트 픽스처에 절대 URL 이 들어가는 것은 정상.
      'no-restricted-syntax': 'off',
    },
  },
);
