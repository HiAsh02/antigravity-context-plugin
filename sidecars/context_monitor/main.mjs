import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SidecarApp, Response } from 'sidecar_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WINDOW_LIMIT = 1048576;
const ID_RE = /^[0-9a-f-]{8,}$/i;

const STATIC = {
  '/styles.css': ['styles.css', 'text/css; charset=utf-8'],
  '/app.js': ['app.js', 'application/javascript; charset=utf-8'],
};

function findAppDataDir() {
  const dataDir = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR;
  if (dataDir) {
    for (let d = dataDir; d !== dirname(d); d = dirname(d)) {
      if (basename(d) !== 'sidecar_data') continue;
      const appData = dirname(d);
      if (existsSync(join(appData, 'brain'))) return appData;
    }
  }
  const fallback = join(homedir(), '.gemini', 'antigravity');
  if (existsSync(join(fallback, 'brain'))) return fallback;
  return '';
}

function findConfigDir() {
  const configDir = join(homedir(), '.gemini', 'config');
  return existsSync(configDir) ? configDir : '';
}

function safeReaddir(dir) {
  try {
    return readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

function safeReadText(filePath) {
  try {
    return readFileSync(filePath, 'utf-8');
  } catch {
    return '';
  }
}

function safeReadJson(filePath) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf-8'));
  } catch {
    return null;
  }
}

function estimateTokens(text) {
  if (!text) return 0;
  let cjk = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (
      (code >= 0x4e00 && code <= 0x9fff)
      || (code >= 0x3400 && code <= 0x4dbf)
      || (code >= 0x3000 && code <= 0x303f)
      || (code >= 0xff00 && code <= 0xffef)
    ) {
      cjk++;
    }
  }
  const rest = text.length - cjk;
  return Math.max(1, Math.round(cjk * 0.85 + rest / 3.8));
}

function parseFrontmatter(content) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(content);
  if (!match) return { name: '', description: '' };
  const fm = match[1];
  const lines = fm.split(/\r?\n/);
  let name = '';
  let description = '';

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const nameMatch = /^name\s*:\s*(.+)$/.exec(line);
    if (nameMatch && !name) {
      name = nameMatch[1].trim().replace(/^["']|["']$/g, '');
      continue;
    }
    const descMatch = /^description\s*:\s*(.*)$/.exec(line);
    if (descMatch && !description) {
      const val = descMatch[1].trim();
      if (val === '>-' || val === '>' || val === '|-' || val === '|') {
        const parts = [];
        for (let j = i + 1; j < lines.length; j++) {
          const next = lines[j];
          if (/^[ \t]+\S/.test(next) || (next.trim() === '' && parts.length > 0)) {
            if (next.trim() !== '') parts.push(next.trim());
            i = j;
          } else {
            break;
          }
        }
        description = parts.join(' ');
      } else {
        description = val.replace(/^["']|["']$/g, '');
      }
    }
  }
  return { name, description };
}

function resolveTranscript(requestedConvId) {
  const appData = findAppDataDir();
  const conv = (requestedConvId && ID_RE.test(requestedConvId)) ? requestedConvId : '';
  if (!appData || !conv) {
    return { conversationId: conv, path: '', mtimeMs: 0, size: -1, isNewSession: true };
  }
  const target = join(appData, 'brain', conv, '.system_generated', 'logs', 'transcript.jsonl');
  if (existsSync(target)) {
    try {
      const s = statSync(target);
      return { conversationId: conv, path: target, mtimeMs: s.mtimeMs, size: s.size, isNewSession: false };
    } catch {
      // Transcript not readable yet
    }
  }
  return { conversationId: conv, path: '', mtimeMs: 0, size: -1, isNewSession: true };
}

const breakdownCache = new Map();

function computeBaseBreakdown(initialContextTokens) {
  const rawTotal = Math.max(0, Number(initialContextTokens) || 0);
  const isEstimated = rawTotal === 0;
  const cacheKey = isEstimated ? 'est' : String(rawTotal);

  const cacheHit = breakdownCache.get(cacheKey);
  if (cacheHit && Date.now() - cacheHit.ts < 5000) {
    return cacheHit.value;
  }

  const appData = findAppDataDir();
  const configDir = findConfigDir();
  const userConfig = configDir ? (safeReadJson(join(configDir, 'config.json')) || {}) : {};
  const pluginStates = userConfig.plugins && typeof userConfig.plugins === 'object' ? userConfig.plugins : {};

  // 1. Discover plugins (user + builtin) and determine active status
  const pluginMap = new Map(); // dir -> { dir, name, displayName, root, isBuiltin, enabled, mcpServers, skillsTokens, mcpTokens, rulesTokens, skillCount, mcpToolCount }
  const pluginRoots = [];
  if (configDir) pluginRoots.push({ dir: join(configDir, 'plugins'), isBuiltin: false });
  if (appData) pluginRoots.push({ dir: join(appData, 'builtin', 'plugins'), isBuiltin: true });

  for (const rootInfo of pluginRoots) {
    for (const entry of safeReaddir(rootInfo.dir)) {
      if (!entry.isDirectory()) continue;
      const dirName = entry.name;
      if (pluginMap.has(dirName)) continue;
      const pRoot = join(rootInfo.dir, dirName);
      const manifest = safeReadJson(join(pRoot, 'plugin.json')) || {};
      const state = pluginStates[dirName];
      const enabled = state && typeof state.enabled === 'boolean'
        ? state.enabled
        : !Boolean(manifest.disabled);

      const mcpCfg = safeReadJson(join(pRoot, 'mcp_config.json'));
      const mcpServers = mcpCfg?.mcpServers && typeof mcpCfg.mcpServers === 'object'
        ? Object.keys(mcpCfg.mcpServers)
        : [];

      pluginMap.set(dirName, {
        dir: dirName,
        name: manifest.name || dirName,
        displayName: manifest.displayName || manifest.name || dirName,
        root: pRoot,
        isBuiltin: rootInfo.isBuiltin,
        enabled,
        mcpServers,
        skillsTokens: 0,
        mcpTokens: 0,
        rulesTokens: 0,
        skillCount: 0,
        mcpToolCount: 0,
      });
    }
  }

  // 2. Rules / Instructions
  const rulesItems = [];
  let rulesTokens = 0;

  if (configDir) {
    for (const fname of ['GEMINI.md', 'AGENTS.md']) {
      const fpath = join(configDir, fname);
      const text = safeReadText(fpath);
      if (text) {
        const tk = estimateTokens(text);
        rulesTokens += tk;
        rulesItems.push({ name: fname, meta: '全局用户规则 (~/.gemini/config)', tokens: tk });
      }
    }
  }

  for (const p of pluginMap.values()) {
    if (!p.enabled) continue;
    const rulesDir = join(p.root, 'rules');
    for (const f of safeReaddir(rulesDir)) {
      if (!f.isFile() || !f.name.endsWith('.md')) continue;
      const text = safeReadText(join(rulesDir, f.name));
      if (!text) continue;
      const tk = estimateTokens(text);
      rulesTokens += tk;
      p.rulesTokens += tk;
      rulesItems.push({ name: `${p.name}/${f.name}`, meta: '插件规则', tokens: tk });
    }
  }

  // 3. MCP Servers & Tool Schemas
  const mcpItems = [];
  let mcpTokens = 0;
  if (appData) {
    const mcpRoot = join(appData, 'mcp');
    for (const srvEntry of safeReaddir(mcpRoot)) {
      if (!srvEntry.isDirectory()) continue;
      const srvDirName = srvEntry.name;
      const srvPath = join(mcpRoot, srvDirName);
      let ownerPlugin = null;
      for (const p of pluginMap.values()) {
        if (!p.enabled) continue;
        if (srvDirName.startsWith(`${p.name}_`) || p.mcpServers.some((s) => srvDirName === `${p.name}_${s}`)) {
          ownerPlugin = p;
          break;
        }
      }

      for (const f of safeReaddir(srvPath)) {
        if (!f.isFile()) continue;
        if (!f.name.endsWith('.json') && f.name !== 'instructions.md') continue;
        const text = safeReadText(join(srvPath, f.name));
        if (!text) continue;
        const tk = estimateTokens(text);
        mcpTokens += tk;
        if (ownerPlugin) {
          ownerPlugin.mcpTokens += tk;
          if (f.name.endsWith('.json')) ownerPlugin.mcpToolCount++;
        }
        const label = f.name === 'instructions.md' ? `${srvDirName}/instructions.md` : f.name.replace(/\.json$/, '');
        const meta = ownerPlugin ? `MCP (${ownerPlugin.name})` : `MCP (${srvDirName})`;
        mcpItems.push({ name: label, meta, tokens: tk });
      }
    }
  }

  // 4. Skills (Standalone + Enabled Plugins + Built-in)
  const skillsItems = [];
  let skillsTokens = 0;
  const seenSkillNames = new Set();

  function addSkill(skillDir, sourceLabel, ownerPlugin) {
    const skillFile = join(skillDir, 'SKILL.md');
    const content = safeReadText(skillFile);
    if (!content) return;
    const { name, description } = parseFrontmatter(content);
    const skillName = name || basename(skillDir);
    if (seenSkillNames.has(skillName)) return;
    seenSkillNames.add(skillName);

    const injectedLine = `- ${skillName} (${skillFile}): ${description}`;
    const summaryTokens = estimateTokens(injectedLine);
    const fullTokens = estimateTokens(content);

    skillsTokens += summaryTokens;
    if (ownerPlugin) {
      ownerPlugin.skillsTokens += summaryTokens;
      ownerPlugin.skillCount++;
    }
    skillsItems.push({
      name: skillName,
      meta: `${sourceLabel} · 全文约 ${fullTokens.toLocaleString('en-US')} tokens`,
      tokens: summaryTokens,
    });
  }

  if (configDir) {
    const userSkillsDir = join(configDir, 'skills');
    for (const d of safeReaddir(userSkillsDir)) {
      if (d.isDirectory()) addSkill(join(userSkillsDir, d.name), '用户独立 Skill', null);
    }
  }

  for (const p of pluginMap.values()) {
    if (!p.enabled) continue;
    const pSkillsDir = join(p.root, 'skills');
    for (const d of safeReaddir(pSkillsDir)) {
      if (d.isDirectory()) addSkill(join(pSkillsDir, d.name), `插件 ${p.name}`, p);
    }
  }

  if (appData) {
    const builtinSkillsDir = join(appData, 'builtin', 'skills');
    for (const d of safeReaddir(builtinSkillsDir)) {
      if (d.isDirectory()) addSkill(join(builtinSkillsDir, d.name), '系统内置 Skill', null);
    }
  }

  // 5. Plugins catalog & System Core / Native Tools (non-overlapping sum == total)
  const DEFAULT_SYSTEM_TOKENS = 10900;
  let pluginsCatalogTokens = 880;
  let systemTokens = DEFAULT_SYSTEM_TOKENS;
  let total = rawTotal;

  if (isEstimated) {
    total = rulesTokens + mcpTokens + skillsTokens + pluginsCatalogTokens + systemTokens;
  } else {
    let customSum = rulesTokens + mcpTokens + skillsTokens;
    if (customSum > total) {
      const scale = total / customSum;
      rulesTokens = Math.round(rulesTokens * scale);
      mcpTokens = Math.round(mcpTokens * scale);
      skillsTokens = Math.max(0, total - rulesTokens - mcpTokens);
      pluginsCatalogTokens = 0;
    } else {
      pluginsCatalogTokens = Math.min(880, Math.max(0, total - customSum));
    }
    systemTokens = Math.max(0, total - (rulesTokens + mcpTokens + skillsTokens + pluginsCatalogTokens));
  }

  const nativeToolsTokens = Math.round(systemTokens * 0.56);
  const corePromptTokens = Math.max(0, systemTokens - nativeToolsTokens);

  const systemItems = [
    { name: '内置工具声明 (19 Native Tools)', meta: 'run_command / read_file / browser / swarm 等工具 Schema', tokens: nativeToolsTokens },
    { name: '系统核心协议指令 (System Prompt)', meta: '身份、安全准则、Plan/Execute 协议与输出规范', tokens: corePromptTokens },
  ];

  const pluginsItems = [
    { name: '推荐插件目录 (<featured_plugins>)', meta: '系统内置 Marketplace 推荐目录摘要', tokens: pluginsCatalogTokens },
  ];

  const pluginsSummary = [...pluginMap.values()]
    .filter((p) => p.enabled)
    .map((p) => {
      const combined = p.skillsTokens + p.mcpTokens + p.rulesTokens;
      const parts = [];
      if (p.skillCount > 0) parts.push(`${p.skillCount} Skill`);
      if (p.mcpToolCount > 0) parts.push(`${p.mcpToolCount} MCP 工具`);
      if (p.rulesTokens > 0) parts.push('Rules');
      if (parts.length === 0) parts.push('Sidecar / 轻量化插件');
      return {
        name: p.name,
        displayName: p.displayName,
        isBuiltin: p.isBuiltin,
        components: parts.join(' · '),
        tokens: combined,
      };
    })
    .sort((a, b) => b.tokens - a.tokens);

  const sortByTokens = (arr) => [...arr].sort((a, b) => b.tokens - a.tokens);
  const pctOf = (tk, denom) => (denom > 0 ? Number(((tk / denom) * 100).toFixed(1)) : 0);

  const categories = [
    {
      id: 'system',
      label: '系统核心与内置工具',
      desc: 'System Prompt + 19 个内置工具声明',
      color: 'var(--cm-base)',
      tokens: systemTokens,
      percentOfBase: pctOf(systemTokens, total),
      percentOfWindow: Number(((systemTokens / WINDOW_LIMIT) * 100).toFixed(2)),
      items: systemItems,
    },
    {
      id: 'skills',
      label: '技能摘要 (Skills)',
      desc: `共 ${skillsItems.length} 个 Skill（按首轮注入摘要计算）`,
      color: '#8b5cf6',
      tokens: skillsTokens,
      percentOfBase: pctOf(skillsTokens, total),
      percentOfWindow: Number(((skillsTokens / WINDOW_LIMIT) * 100).toFixed(2)),
      items: sortByTokens(skillsItems),
    },
    {
      id: 'rules',
      label: '指令与规则 (Rules)',
      desc: 'GEMINI.md 与启用插件规则文件',
      color: '#10b981',
      tokens: rulesTokens,
      percentOfBase: pctOf(rulesTokens, total),
      percentOfWindow: Number(((rulesTokens / WINDOW_LIMIT) * 100).toFixed(2)),
      items: sortByTokens(rulesItems),
    },
    {
      id: 'mcp',
      label: 'MCP 服务与工具 Schema',
      desc: `${mcpItems.length} 个 MCP 定义与说明文件`,
      color: '#f59e0b',
      tokens: mcpTokens,
      percentOfBase: pctOf(mcpTokens, total),
      percentOfWindow: Number(((mcpTokens / WINDOW_LIMIT) * 100).toFixed(2)),
      items: sortByTokens(mcpItems),
    },
    {
      id: 'plugins',
      label: '插件目录与组件汇总 (Plugins)',
      desc: `${pluginsSummary.length} 个已启用插件`,
      color: '#ec4899',
      tokens: pluginsCatalogTokens,
      percentOfBase: pctOf(pluginsCatalogTokens, total),
      percentOfWindow: Number(((pluginsCatalogTokens / WINDOW_LIMIT) * 100).toFixed(2)),
      items: pluginsItems,
    },
  ];

  const result = { total, isEstimated, categories, pluginsSummary };
  breakdownCache.clear();
  breakdownCache.set(cacheKey, { ts: Date.now(), value: result });
  return result;
}

const USER_INPUT_RE = /^\{"step_index"\s*:\s*\d+\s*,\s*"source"\s*:\s*"[^"]*"\s*,\s*"type"\s*:\s*"USER_INPUT"/;
const PLANNER_RE = /^\{"step_index"\s*:\s*(\d+)\s*,\s*"source"\s*:\s*"[^"]*"\s*,\s*"type"\s*:\s*"PLANNER_RESPONSE"/;
const HEADER_SLICE_RE = /^(.*?),(?:"content"|"thinking"|"tool_calls"|"media"|"truncated_fields")\s*:/;

function extractInt(str, key) {
  const m = new RegExp(`"${key}"\\s*:\\s*(\\d+)`).exec(str);
  return m ? Number(m[1]) : 0;
}

function extractStr(str, key) {
  const m = new RegExp(`"${key}"\\s*:\\s*"([^"]+)"`).exec(str);
  return m ? m[1] : '';
}

const parsedCache = new Map();

function buildNewSessionPayload(convId, userTurns = 0) {
  const baseBreakdown = computeBaseBreakdown(0);
  const estBase = baseBreakdown.total;
  const basePercent = Number(((estBase / WINDOW_LIMIT) * 100).toFixed(2));
  const remainingTokens = Math.max(0, WINDOW_LIMIT - estBase);
  const remainingPercent = Number(Math.max(0, 100 - basePercent).toFixed(2));

  return {
    conversationId: convId || '',
    isNewSession: true,
    windowLimit: WINDOW_LIMIT,
    updatedAt: '',
    userTurns,
    plannerSteps: 0,
    compactionCount: 0,
    initialContextTokens: estBase,
    activeContextTokens: estBase,
    sessionGrowthTokens: 0,
    remainingTokens,
    usedPercent: basePercent,
    remainingPercent,
    basePercent,
    growthPercent: 0,
    latestStep: 0,
    latestCreatedAt: '',
    latestInputTokens: 0,
    latestCacheReadTokens: 0,
    latestOutputTokens: 0,
    latestCacheHitRate: 0,
    cumulativeInputTokens: 0,
    cumulativeCacheReadTokens: 0,
    cumulativeOutputTokens: 0,
    overallCacheHitRate: 0,
    baseBreakdown,
    steps: [],
  };
}

function parseTranscript(info) {
  if (info.isNewSession || !info.path || info.size < 0) {
    return buildNewSessionPayload(info.conversationId, 0);
  }

  const cacheKey = `${info.mtimeMs}:${info.size}`;
  const hit = parsedCache.get(info.path);
  if (hit && hit.key === cacheKey) return hit.data;

  const text = readFileSync(info.path, 'utf-8');
  const lines = text.split(/\r?\n/);

  let userTurns = 0;
  const rawSteps = [];

  for (const line of lines) {
    if (!line) continue;
    if (USER_INPUT_RE.test(line)) {
      userTurns++;
      continue;
    }
    const pm = PLANNER_RE.exec(line);
    if (!pm) continue;

    const stepIndex = Number(pm[1]);
    const sliceMatch = HEADER_SLICE_RE.exec(line);
    const header = sliceMatch ? sliceMatch[1] : line;

    const createdAt = extractStr(header, 'created_at');
    const inputTokens = extractInt(header, 'input_tokens');
    const cacheReadTokens = extractInt(header, 'cache_read_tokens');
    const outputTokens = extractInt(header, 'output_tokens');
    const activeTokens = inputTokens + cacheReadTokens;

    rawSteps.push({
      stepIndex,
      createdAt,
      inputTokens,
      cacheReadTokens,
      outputTokens,
      activeTokens,
    });
  }

  let compactionCount = 0;
  let cumulativeInputTokens = 0;
  let cumulativeCacheReadTokens = 0;
  let cumulativeOutputTokens = 0;
  const steps = [];

  for (let i = 0; i < rawSteps.length; i++) {
    const curr = rawSteps[i];
    cumulativeInputTokens += curr.inputTokens;
    cumulativeCacheReadTokens += curr.cacheReadTokens;
    cumulativeOutputTokens += curr.outputTokens;

    const prev = i > 0 ? rawSteps[i - 1] : null;
    const deltaTokens = prev ? curr.activeTokens - prev.activeTokens : curr.activeTokens;
    const compacted = Boolean(prev && prev.activeTokens - curr.activeTokens > 2000);
    if (compacted) compactionCount++;

    steps.push({
      ...curr,
      deltaTokens,
      compacted,
    });
  }

  const plannerSteps = steps.length;
  if (plannerSteps === 0) {
    const emptyData = buildNewSessionPayload(info.conversationId, userTurns);
    parsedCache.clear();
    parsedCache.set(info.path, { key: cacheKey, data: emptyData });
    return emptyData;
  }

  const first = steps[0];
  const latest = steps[plannerSteps - 1];

  const initialContextTokens = first ? first.activeTokens : 0;
  const activeContextTokens = latest ? latest.activeTokens : 0;
  const sessionGrowthTokens = Math.max(0, activeContextTokens - initialContextTokens);
  const remainingTokens = Math.max(0, WINDOW_LIMIT - activeContextTokens);

  const usedPercent = Number(((activeContextTokens / WINDOW_LIMIT) * 100).toFixed(2));
  const remainingPercent = Number(Math.max(0, 100 - usedPercent).toFixed(2));
  const baseTokensClamped = Math.min(initialContextTokens, activeContextTokens);
  const basePercent = Number(((baseTokensClamped / WINDOW_LIMIT) * 100).toFixed(2));
  const growthPercent = Number(Math.max(0, usedPercent - basePercent).toFixed(2));

  const latestCacheHitRate = latest
    ? Number(((latest.cacheReadTokens / Math.max(1, activeContextTokens)) * 100).toFixed(1))
    : 0;
  const totalCumulativePrompt = cumulativeInputTokens + cumulativeCacheReadTokens;
  const overallCacheHitRate = totalCumulativePrompt > 0
    ? Number(((cumulativeCacheReadTokens / totalCumulativePrompt) * 100).toFixed(1))
    : 0;

  const baseBreakdown = computeBaseBreakdown(initialContextTokens);

  const data = {
    conversationId: info.conversationId,
    isNewSession: false,
    windowLimit: WINDOW_LIMIT,
    updatedAt: latest?.createdAt || new Date(info.mtimeMs).toISOString(),
    userTurns,
    plannerSteps,
    compactionCount,
    initialContextTokens,
    activeContextTokens,
    sessionGrowthTokens,
    remainingTokens,
    usedPercent,
    remainingPercent,
    basePercent,
    growthPercent,
    latestStep: latest ? latest.stepIndex : 0,
    latestCreatedAt: latest ? latest.createdAt : '',
    latestInputTokens: latest ? latest.inputTokens : 0,
    latestCacheReadTokens: latest ? latest.cacheReadTokens : 0,
    latestOutputTokens: latest ? latest.outputTokens : 0,
    latestCacheHitRate,
    cumulativeInputTokens,
    cumulativeCacheReadTokens,
    cumulativeOutputTokens,
    overallCacheHitRate,
    baseBreakdown,
    steps,
  };

  parsedCache.clear();
  parsedCache.set(info.path, { key: cacheKey, data });
  return data;
}

const app = new SidecarApp();

app.page('/', () => readFileSync(join(__dirname, 'index.html'), 'utf-8'));

for (const [route, [file, contentType]] of Object.entries(STATIC)) {
  app.api(route, () => new Response(readFileSync(join(__dirname, file), 'utf-8'), { contentType }), 'GET');
}

app.api('/api/context', (data) => {
  const requestedConv = typeof data?.conversationId === 'string' ? data.conversationId.trim() : '';
  const info = resolveTranscript(requestedConv);
  const etag = info.isNewSession
    ? `new:${requestedConv || 'blank'}`
    : `${info.conversationId}|${info.mtimeMs}:${info.size}`;
  if (data?.etag && data.etag === etag) {
    return { conversationId: info.conversationId || null, unchanged: true, etag };
  }
  const parsed = parseTranscript(info);
  return { ...parsed, etag };
}, 'GET');

app.run();
