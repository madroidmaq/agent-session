// 一次性脚本：生成用于 README 截图的英文 demo 页面。
// 做三件事：① 复制 template.html ② 把可见中文 UI 串换成英文
// ③ 注入一份脱敏的英文 mock 数据。产物 docs/demo.html 仅供截图，不参与 app 构建。
//   用法：node docs/make-demo.mjs
import { Buffer } from 'node:buffer';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const tplPath = join(here, '../Sources/AgentSession/Resources/template.html');
const demoSource = new Set(['claude', 'codex', 'grok']).has(process.env.AGENT_SESSION_DEMO_SOURCE)
  ? process.env.AGENT_SESSION_DEMO_SOURCE
  : 'claude';

// ——— 1. 英文 mock 数据（脱敏、虚构项目，体现核心功能）———
const clip = (text) => ({ text, clipped: false });
const ROOT = '/Users/dev/.claude/projects';

const mainTurns = [
  { role: 'user', kind: 'message', ts: '2026-06-22T08:58:10.000Z',
    text: clip('Add a dark mode toggle to the settings page. Persist the choice in localStorage and fall back to the system preference on first load.') },
  { role: 'assistant', kind: 'thinking', ts: '2026-06-22T08:58:22.000Z',
    text: clip('The settings page is a React component. Plan: read it, add a toggle wired to a new useTheme hook, persist to localStorage, and fall back to prefers-color-scheme on first load.') },
  { role: 'assistant', kind: 'text', ts: '2026-06-22T08:58:24.000Z',
    text: clip("I'll start by reading the current settings component to see how it's structured.") },
  { role: 'assistant', kind: 'tool_use', id: 'tu1', name: 'Read',
    ts: '2026-06-22T08:58:25.000Z',
    summary: '/Users/dev/acme-dashboard/src/components/Settings.tsx',
    input: { file_path: '/Users/dev/acme-dashboard/src/components/Settings.tsx' } },
  { role: 'tool', kind: 'tool_result', tool_use_id: 'tu1', is_error: false,
    ts: '2026-06-22T08:58:25.500Z',
    content: clip('export function Settings() {\n  return (\n    <section className="settings">\n      <h2>Settings</h2>\n      <ProfileForm />\n    </section>\n  );\n}') },
  { role: 'assistant', kind: 'text', ts: '2026-06-22T08:59:02.000Z',
    text: clip('Now I\'ll add a `ThemeToggle` to the settings section and a `useTheme` hook to own the state.') },
  { role: 'assistant', kind: 'tool_use', id: 'tu2', name: 'Edit',
    ts: '2026-06-22T08:59:03.000Z',
    summary: '/Users/dev/acme-dashboard/src/components/Settings.tsx',
    input: {
      file_path: '/Users/dev/acme-dashboard/src/components/Settings.tsx',
      old_string: '    <section className="settings">\n      <h2>Settings</h2>\n      <ProfileForm />\n    </section>',
      new_string: '    <section className="settings">\n      <h2>Settings</h2>\n      <ThemeToggle />\n      <ProfileForm />\n    </section>',
    } },
  { role: 'tool', kind: 'tool_result', tool_use_id: 'tu2', is_error: false,
    ts: '2026-06-22T08:59:03.500Z',
    content: clip('Applied 1 edit to src/components/Settings.tsx') },
  { role: 'assistant', kind: 'tool_use', id: 'tu3', name: 'Write',
    ts: '2026-06-22T08:59:40.000Z',
    summary: '/Users/dev/acme-dashboard/src/hooks/useTheme.ts',
    input: {
      file_path: '/Users/dev/acme-dashboard/src/hooks/useTheme.ts',
      content: "import { useEffect, useState } from 'react';\n\nexport function useTheme() {\n  const [theme, setTheme] = useState(() =>\n    localStorage.getItem('theme') ??\n    (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')\n  );\n\n  useEffect(() => {\n    document.documentElement.dataset.theme = theme;\n    localStorage.setItem('theme', theme);\n  }, [theme]);\n\n  return { theme, toggle: () => setTheme((t) => (t === 'dark' ? 'light' : 'dark')) };\n}\n",
    } },
  { role: 'tool', kind: 'tool_result', tool_use_id: 'tu3', is_error: false,
    ts: '2026-06-22T08:59:40.500Z',
    content: clip('Wrote 18 lines to src/hooks/useTheme.ts') },
  { role: 'assistant', kind: 'tool_use', id: 'tu4', name: 'Bash',
    ts: '2026-06-22T09:01:12.000Z', summary: 'npm run build',
    input: { command: 'npm run build', description: 'Type-check and build the project' } },
  { role: 'tool', kind: 'tool_result', tool_use_id: 'tu4', is_error: false,
    ts: '2026-06-22T09:01:14.000Z',
    content: clip('> acme-dashboard@1.4.0 build\n> vite build\n\nvite v5.2.0 building for production...\n✓ 312 modules transformed.\ndist/assets/index-9f2a.js   142.8 kB │ gzip: 46.1 kB\n✓ built in 1.84s') },
  { role: 'assistant', kind: 'tool_use', id: 'tu5', name: 'Agent',
    ts: '2026-06-22T09:02:00.000Z',
    summary: 'code-reviewer — Review the dark mode change',
    input: { subagent_type: 'code-reviewer', description: 'Review the dark mode change',
      prompt: 'Review the dark mode toggle change for correctness and accessibility.' },
    subagents: [{
      agent_type: 'code-reviewer', agent_id: 'ag1', num_user: 1, num_assistant: 2, num_tools: 1,
      turns: [
        { role: 'user', kind: 'message', ts: '2026-06-22T09:02:01.000Z',
          text: clip('Review the dark mode toggle change for correctness and accessibility.') },
        { role: 'assistant', kind: 'text', ts: '2026-06-22T09:02:30.000Z',
          text: clip('Reviewed `Settings.tsx` and `useTheme.ts`. Logic is correct and the localStorage fallback is sound. One accessibility nit below.') },
        { role: 'assistant', kind: 'tool_use', id: 'sub-tu1', name: 'Read',
          ts: '2026-06-22T09:02:10.000Z',
          summary: '/Users/dev/acme-dashboard/src/hooks/useTheme.ts',
          input: { file_path: '/Users/dev/acme-dashboard/src/hooks/useTheme.ts' } },
        { role: 'assistant', kind: 'text', ts: '2026-06-22T09:02:40.000Z',
          text: clip('**Finding:** the toggle button has no accessible name. Add `aria-label="Toggle dark mode"` so screen readers announce it. Otherwise LGTM.') },
      ],
    }] },
  { role: 'assistant', kind: 'text', ts: '2026-06-22T09:03:20.000Z',
    text: clip("Done. Dark mode is wired up:\n\n- **Toggle** added to the settings page, bound to a new `useTheme` hook.\n- **Persistence** via `localStorage` under the `theme` key.\n- **System fallback** using `prefers-color-scheme` on first load.\n\nThe build passes (`npm run build`, 1.84s). The `code-reviewer` agent flagged one a11y nit, so I added an `aria-label` to the toggle.") },
];

const session = (o) => ({
  source: demoSource, cwd: null, git_branch: null, skills: [], num_subagents: 0,
  turns: [], orphan_subagents: [], duration_ms: 0,
  num_assistant_msgs: 0, ...o,
});

const sessions = [
  session({
    id: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d', project: '-Users-dev-acme-dashboard',
    project_label: 'acme-dashboard', cwd: '/Users/dev/acme-dashboard', git_branch: 'feat/dark-mode',
    first_ts: '2026-06-22T08:58:10.000Z', last_ts: '2026-06-22T09:03:20.000Z', duration_ms: 310000,
    num_user_msgs: 1, num_assistant_msgs: 5, num_tool_calls: 5, num_subagents: 1,
    usage: { input_uncached: 18420, cache_create: 42300, cache_read: 180500, output: 9240,
      input_total: 241220, total: 250460, cache_pct: 75 },
    skills: ['code-review'], preview: 'Add a dark mode toggle to the settings page',
    turns: mainTurns,
  }),
  session({ id: 'b2c3d4e5-1111-4a7b-8c9d-aaaaaaaaaaaa', project: '-Users-dev-acme-dashboard',
    project_label: 'acme-dashboard', git_branch: 'fix/checkout-e2e',
    first_ts: '2026-06-21T15:02:00.000Z', last_ts: '2026-06-21T15:48:00.000Z',
    num_user_msgs: 4, num_assistant_msgs: 9, num_tool_calls: 12, skills: ['test-gen'],
    usage: { total: 132900 }, preview: 'Fix the flaky checkout E2E test' }),
  session({ id: 'c3d4e5f6-2222-4a7b-8c9d-bbbbbbbbbbbb', project: '-Users-dev-acme-dashboard',
    project_label: 'acme-dashboard', first_ts: '2026-06-20T11:00:00.000Z', last_ts: '2026-06-20T12:10:00.000Z',
    num_user_msgs: 6, num_assistant_msgs: 11, num_tool_calls: 9,
    usage: { total: 188400 }, preview: 'Refactor the API client to use fetch' }),
  session({ id: 'd4e5f6a7-3333-4a7b-8c9d-cccccccccccc', project: '-Users-dev-payments-api',
    project_label: 'payments-api', git_branch: 'feat/idempotency',
    first_ts: '2026-06-21T09:30:00.000Z', last_ts: '2026-06-21T10:40:00.000Z',
    num_user_msgs: 5, num_assistant_msgs: 14, num_tool_calls: 14, skills: ['code-review'],
    usage: { total: 274300 }, preview: 'Add idempotency keys to the charge endpoint' }),
  session({ id: 'e5f6a7b8-4444-4a7b-8c9d-dddddddddddd', project: '-Users-dev-payments-api',
    project_label: 'payments-api', first_ts: '2026-06-19T14:00:00.000Z', last_ts: '2026-06-19T16:05:00.000Z',
    num_user_msgs: 8, num_assistant_msgs: 22, num_tool_calls: 22,
    usage: { total: 401200 }, preview: 'Investigate the webhook retry storm' }),
  session({ id: 'f6a7b8c9-5555-4a7b-8c9d-eeeeeeeeeeee', project: '-Users-dev-ml-pipeline',
    project_label: 'ml-pipeline', first_ts: '2026-06-18T20:10:00.000Z', last_ts: '2026-06-18T20:55:00.000Z',
    num_user_msgs: 3, num_assistant_msgs: 7, num_tool_calls: 7,
    usage: { total: 96400 }, preview: 'Speed up the nightly feature job' }),
  session({ id: 'a7b8c9d0-6666-4a7b-8c9d-ffffffffffff', project: '-Users-dev-docs-site',
    project_label: 'docs-site', first_ts: '2026-06-17T10:00:00.000Z', last_ts: '2026-06-17T10:35:00.000Z',
    num_user_msgs: 2, num_assistant_msgs: 4, num_tool_calls: 4,
    usage: { total: 41800 }, preview: 'Migrate the docs to the new theme' }),
];

const DATA = {
  generated_at: '2026-06-22T09:05:00.000Z', root: ROOT,
  scope: { project: null, session: null, since: '2026-06-15T00:00:00.000Z', all: true,
    total_matched: sessions.length, shown: sessions.length },
  controls: { since: '7d', project: null,
    projects: ['acme-dashboard', 'payments-api', 'ml-pipeline', 'docs-site'] },
  sessions,
};

// ——— 2. 中文 UI 串 → 英文（按“具体→通用”排序，避免子串误伤）———
const REPLACEMENTS = [
  ['最近 7 天', 'Last 7 days'], ['最近 24 小时', 'Last 24 hours'],
  ['最近 30 天', 'Last 30 days'], ['全部时间', 'All time'],
  ['全部项目', 'All projects'], ['时间范围', 'Time range'],
  ['会话信息（Token / 缓存）', 'Session info (tokens / cache)'],
  ['查看 skill 内容', 'View skill content'], ['主 Agent', 'Main Agent'],
  ['查看对话 →', 'View thread →'], ['无统计数据', 'no stats'],
  ['这个 Agent 没有可显示的对话。', 'This agent has no conversation to show.'],
  ['展开全部', 'Expand all'], ['折叠全部', 'Collapse all'], ['ⓘ 详细', 'ⓘ Details'],
  ['目录 · ', 'Outline · '], ['轮对话', 'turns'],
  ['在当前 Agent 内搜索…（回车跳下一处）', 'Search this agent… (Enter to jump)'],
  ['工具详情', 'Tool details'],
  ['点击中栏对话里的工具，查看它的详情。', 'Click a tool in the conversation to see its details.'],
  ['工具 · ', 'Tool · '], ['工具调用', 'Tool calls'],
  ['Token 用量（本会话，不含 subagent）', 'Token usage (this session, excl. subagents)'],
  ['输入 · 未缓存', 'Input · uncached'], ['输入 · 写入缓存', 'Input · cache write'],
  ['输入 · 读取缓存', 'Input · cache read'], ['缓存覆盖率', 'Cache coverage'],
  ['读取缓存 / 总输入', 'Cache read / total input'], ['会话统计', 'Session stats'],
  ['会话信息', 'Session info'], ['总计', 'Total'], ['输出', 'Output'],
  ['回复', 'Replies'], ['时长', 'Duration'], ['分支', 'Branch'],
  ['收起工具栏', 'Collapse panel'],
  ['~/.claude/projects — 概览', '~/.claude/projects — Overview'],
  ['会话回看', 'Session Replay'], ['项目分布', 'Projects'], ['最近会话', 'Recent sessions'],
  ['段会话', 'sessions'], ['个项目', ' projects'], ['段对话', 'conversations'],
  ['未找到该会话。', 'Session not found.'],
  ['这个范围内还没有会话。试试 ', 'No sessions in this range. Try '],
  ['这个范围内还没有会话。', 'No sessions in this range.'],
  ['☰ 会话', '☰ Sessions'], ['工具 ⚙', 'Tools ⚙'],
  ['− 原内容', '− Before'], ['+ 新内容', '+ After'], ['写入内容', 'Content'],
  ['筛选会话…（标题 / 项目 / skill）', 'Filter sessions… (title / project / skill)'],
  ['加载中…', 'Loading…'], ['无匹配', 'no match'], [' 处`', ' matches`'],
  ['已复制', 'Copied'], ['复制', 'Copy'],
  ['… 已截断，原文 ', '… truncated, '], [' 字符</span>', ' chars</span>'],
  [' 字符</div>', ' chars</div>'],
  [' 轮 · ', ' turns · '], [' 工具', ' tools'],
  // 顺序有意义：'未知时间' 必须先于 '时间' 被替换，否则只剩 '未知Time'。
  ['未知时间', 'Unknown time'], ['时间', 'Time'],
  [' 行`', ' lines`'],
  ['session-viewer', 'AgentSession'],
];

// ——— 3. 组装 ———
let html = readFileSync(tplPath, 'utf8');
// README 截图默认使用 Claude Code；本地可用 AGENT_SESSION_DEMO_SOURCE=codex/grok
// 验证来源特定的 transcript grammar。原生 App 则由 UserDefaults + session.source 驱动。
html = html.replace('<html lang="zh">', `<html lang="en" class="ui-${demoSource}">`);
for (const [from, to] of REPLACEMENTS) html = html.split(from).join(to);

const json = Buffer.from(JSON.stringify(DATA), 'utf8').toString('base64');
html = html.replace(
  '<script id="session-data" type="application/json" data-encoding="base64">e30=</script>',
  `<script id="session-data" type="application/json" data-encoding="base64">${json}</script>`);

// 截图辅助：进入主会话详情，并自动在右栏展开 Edit 工具卡片。
html = html.replace('</body>', `<script>
  window.addEventListener('load', () => setTimeout(() => {
    document.querySelector('.srow[data-id]')?.click();
    setTimeout(() => {
      const anchors = [...document.querySelectorAll('.tool-anchor[data-tool]')];
      const edit = anchors.find(a => a.querySelector('.ta-name')?.textContent === 'Edit');
      (edit || anchors[0])?.click();
    }, 80);
  }, 120));
</script></body>`);

const out = join(here, 'demo.html');
writeFileSync(out, html);
console.log('wrote', out);
