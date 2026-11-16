# docs

- `t3code-ui-texts.txt` —— 从上游 `apps/web/src/**/*.tsx` 提取的全部界面文案（2099 条），
  用于扩充 `apps/t3code/src/cmd/zh-CN.json` 汉化词表。提取方式是扫 JSX 文本节点与
  `title` / `placeholder` / `aria-label` / `label` / `alt` / `description` 属性。

  扩充流程：挑出想要的英文条目 → 在 `zh-CN.json` 里加 `"English": "中文"` →
  `bash apps/t3code/build.sh --arch x86`。补丁在应用启动时自动套用，无需手动改前端。
