// ESLint flat config.
// 원칙: 포맷은 Prettier 에 맡기고, 여기서는 정확성 + 프로젝트 하드룰만 다룬다.
// 리뷰 체크리스트에 문장으로 적히던 것을 여기로 내린다.
//
// 필요 패키지:
//   eslint typescript-eslint @eslint/js eslint-plugin-react-hooks eslint-plugin-jsx-a11y
import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';
import jsxA11y from 'eslint-plugin-jsx-a11y';

export default tseslint.config(
  { ignores: ['dist/**', 'build/**', 'coverage/**', 'node_modules/**', 'eslint.config.js'] },

  js.configs.recommended,
  // strictTypeChecked 는 recommendedTypeChecked 보다 강하다. 초기 도입에서
  // 노이즈가 크면 recommendedTypeChecked 로 낮추되, 낮췄다는 사실을 기록한다.
  ...tseslint.configs.recommendedTypeChecked,

  {
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    plugins: { 'react-hooks': reactHooks, 'jsx-a11y': jsxA11y },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // 접근성 — 리뷰에서 사람이 눈으로 보던 항목을 기계로 내린다.
      ...jsxA11y.flatConfigs.recommended.rules,

      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/consistent-type-imports': [
        'error',
        { prefer: 'type-imports', fixStyle: 'inline-type-imports' },
      ],

      // ── 프로젝트 하드룰 코드화 ──
      // 산문 규칙은 에이전트가 "지키려 노력"하지만, 린트 규칙은 어기면 빌드가 깨진다.
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
      // 금지 라이브러리가 생기면 여기에 적는다.
      // 'no-restricted-imports': ['error', { paths: [{ name: 'axios', message: 'fetch 를 쓴다' }] }],
    },
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
