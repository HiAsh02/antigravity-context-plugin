(() => {
  const POLL_MS = 1500;
  const $ = (id) => document.getElementById(id);
  const params = new URLSearchParams(location.search);

  let lastEtag = '';
  let lastData = null;
  const openGroups = new Set();

  function currentConv() {
    return window.sidecar?.conversationId || params.get('conversationId') || '';
  }

  async function getJson(path) {
    const f = window.sidecar?.fetch ? window.sidecar.fetch.bind(window.sidecar) : fetch;
    const res = await f(path, { method: 'GET' });
    if (!res.ok) throw new Error(`${path}: ${res.status}`);
    return res.json();
  }

  function syncScheme() {
    const probe = document.createElement('span');
    probe.style.cssText = 'position:absolute;visibility:hidden;color:var(--background, #f7f7f8)';
    document.documentElement.appendChild(probe);
    const c = getComputedStyle(probe).color;
    probe.remove();
    const nums = (c.match(/[\d.]+/g) || []).map(Number);
    if (nums.length < 3) return;
    const scale = c.startsWith('color(') ? 1 : 255;
    const [r, g, b] = nums.slice(0, 3).map((v) => v / scale);
    const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const theme = lum < 0.5 ? 'dark' : 'light';
    if (document.documentElement.dataset.theme !== theme) {
      document.documentElement.dataset.theme = theme;
    }
  }

  syncScheme();
  new MutationObserver(() => syncScheme()).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['style'],
  });

  const fmtNum = (n) => Number(n || 0).toLocaleString('en-US');
  const fmtPct = (n, digits = 2) => `${Number(n || 0).toFixed(digits)}%`;
  const fmtDelta = (d, compacted) => {
    if (compacted) return `${fmtNum(d)} 压缩`;
    return d >= 0 ? `+${fmtNum(d)}` : fmtNum(d);
  };

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;',
    }[c]));
  }

  function renderChart(steps, windowLimit, isNewSession) {
    const wrap = $('chart-wrap');
    const meta = $('chart-meta');
    if (!steps || steps.length === 0) {
      wrap.innerHTML = isNewSession
        ? '<div class="empty-note">新会话待发送首条消息…</div>'
        : '<div class="empty-note">等待模型调用数据…</div>';
      meta.textContent = '--';
      return;
    }

    const firstStep = steps[0].stepIndex;
    const lastStep = steps[steps.length - 1].stepIndex;
    const maxVal = Math.max(1000, ...steps.map((s) => s.activeTokens));
    meta.textContent = `Step ${firstStep} → ${lastStep} · 峰值 ${fmtNum(maxVal)}`;

    const w = 440;
    const h = 112;
    const padL = 6;
    const padR = 6;
    const padT = 14;
    const padB = 18;
    const plotW = w - padL - padR;
    const plotH = h - padT - padB;
    const yMax = Math.ceil(maxVal * 1.12);

    const pts = steps.map((s, idx) => {
      const x = steps.length === 1
        ? padL + plotW / 2
        : padL + (idx / (steps.length - 1)) * plotW;
      const y = padT + plotH - (s.activeTokens / yMax) * plotH;
      return { x, y, step: s };
    });

    const linePoints = pts.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ');
    const areaPath = pts.length === 1
      ? ''
      : `M ${pts[0].x.toFixed(1)} ${(padT + plotH).toFixed(1)} `
        + pts.map((p) => `L ${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(' ')
        + ` L ${pts[pts.length - 1].x.toFixed(1)} ${(padT + plotH).toFixed(1)} Z`;

    const midY = padT + plotH / 2;
    const midVal = Math.round(yMax / 2);

    const dots = pts.map((p, idx) => {
      const isLatest = idx === pts.length - 1;
      const cls = isLatest ? 'chart-dot latest' : (p.step.compacted ? 'chart-dot compact' : 'chart-dot');
      const r = isLatest ? 4 : (p.step.compacted ? 3.2 : 2.3);
      return `<circle class="${cls}" cx="${p.x.toFixed(1)}" cy="${p.y.toFixed(1)}" r="${r}"><title>Step ${p.step.stepIndex}: ${fmtNum(p.step.activeTokens)} tokens</title></circle>`;
    }).join('');

    wrap.innerHTML = `
      <svg class="chart-svg" viewBox="0 0 ${w} ${h}" aria-label="上下文增长趋势图">
        <defs>
          <linearGradient id="cm-area-grad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="var(--cm-base)" stop-opacity="0.26" />
            <stop offset="100%" stop-color="var(--cm-base)" stop-opacity="0.02" />
          </linearGradient>
        </defs>
        <line class="chart-grid" x1="${padL}" y1="${padT}" x2="${w - padR}" y2="${padT}" />
        <line class="chart-grid" x1="${padL}" y1="${midY.toFixed(1)}" x2="${w - padR}" y2="${midY.toFixed(1)}" />
        <line class="chart-grid" x1="${padL}" y1="${padT + plotH}" x2="${w - padR}" y2="${padT + plotH}" />
        <text class="chart-label" x="${padL}" y="${padT - 4}">${fmtNum(yMax)}</text>
        <text class="chart-label" x="${padL}" y="${midY - 3}">${fmtNum(midVal)}</text>
        <text class="chart-label" x="${padL}" y="${h - 4}">Step ${firstStep}</text>
        <text class="chart-label" x="${w - padR}" y="${h - 4}" text-anchor="end">Step ${lastStep} (${((steps[steps.length - 1].activeTokens / windowLimit) * 100).toFixed(1)}%)</text>
        ${areaPath ? `<path d="${areaPath}" fill="url(#cm-area-grad)" />` : ''}
        ${pts.length > 1 ? `<polyline class="chart-line" points="${linePoints}" />` : ''}
        ${dots}
      </svg>
    `;
  }

  function renderSteps(steps, isNewSession) {
    const body = $('steps-body');
    const meta = $('table-meta');
    if (!steps || steps.length === 0) {
      meta.textContent = isNewSession ? '新会话暂无调用记录' : '暂无调用记录';
      body.innerHTML = isNewSession
        ? '<tr><td colspan="6" class="empty-cell">新会话待发送首条消息，发送后将自动记录每步 Token 消耗</td></tr>'
        : '<tr><td colspan="6" class="empty-cell">暂无调用记录</td></tr>';
      return;
    }

    meta.textContent = `共 ${steps.length} 次调用 · 倒序展示`;
    const reversed = [...steps].reverse();
    $('steps-body').innerHTML = reversed.map((s) => {
      const deltaClass = s.compacted ? 'delta-compact' : 'delta-pos';
      return `
        <tr>
          <td><span class="step-badge">#${esc(s.stepIndex)}</span></td>
          <td class="num">${fmtNum(s.activeTokens)}</td>
          <td class="num ${deltaClass}">${esc(fmtDelta(s.deltaTokens, s.compacted))}</td>
          <td class="num">${fmtNum(s.cacheReadTokens)}</td>
          <td class="num">${fmtNum(s.inputTokens)}</td>
          <td class="num">${fmtNum(s.outputTokens)}</td>
        </tr>
      `;
    }).join('');
  }

  function renderBreakdown(bd, windowLimit) {
    const meta = $('bd-meta');
    const bar = $('bd-bar');
    const groups = $('bd-groups');
    if (!bd || !bd.total || !Array.isArray(bd.categories) || bd.categories.length === 0) {
      meta.textContent = '--';
      bar.innerHTML = '';
      groups.innerHTML = '<div class="empty-note">等待基础开销数据…</div>';
      return;
    }

    const winPct = windowLimit > 0 ? ((bd.total / windowLimit) * 100).toFixed(2) : '0.00';
    meta.textContent = bd.isEstimated
      ? `预计 ${fmtNum(bd.total)} tokens · 占窗口 ${winPct}%`
      : `${fmtNum(bd.total)} tokens · 占窗口 ${winPct}%`;

    bar.innerHTML = bd.categories.map((cat) => {
      const w = Math.max(0, cat.percentOfBase || 0);
      return `<div class="bd-seg" style="width:${w}%;background:${esc(cat.color)}" title="${esc(cat.label)}: ${fmtNum(cat.tokens)} tokens (${w}%)"></div>`;
    }).join('');

    const pluginsSummary = Array.isArray(bd.pluginsSummary) ? bd.pluginsSummary : [];

    groups.innerHTML = bd.categories.map((cat) => {
      const isOpen = openGroups.has(cat.id) ? ' open' : '';
      const itemsHtml = (cat.items || []).map((it) => `
        <div class="bd-item">
          <div class="bd-item-left">
            <span class="bd-item-name" title="${esc(it.name)}">${esc(it.name)}</span>
            ${it.meta ? `<span class="bd-item-meta" title="${esc(it.meta)}">${esc(it.meta)}</span>` : ''}
          </div>
          <span class="bd-item-val mono">${fmtNum(it.tokens)}</span>
        </div>
      `).join('');

      let extraHtml = '';
      if (cat.id === 'plugins' && pluginsSummary.length > 0) {
        const pluginRows = pluginsSummary.map((p) => `
          <div class="bd-item">
            <div class="bd-item-left">
              <span class="bd-item-name">${esc(p.name)}</span>
              <span class="bd-item-meta">${esc(p.components)}</span>
            </div>
            <span class="bd-item-val mono">${fmtNum(p.tokens)}</span>
          </div>
        `).join('');
        extraHtml = `<div class="bd-subhead">已启用插件归因汇总（按插件聚合，已计入上方 Skills / MCP / Rules 类）</div>${pluginRows}`;
      }

      const emptyItemHtml = (!itemsHtml && !extraHtml)
        ? '<div class="bd-item"><span class="bd-item-meta">无配置项</span><span class="bd-item-val mono">0</span></div>'
        : '';

      return `
        <details class="bd-group" data-bd-id="${esc(cat.id)}"${isOpen}>
          <summary class="bd-summary">
            <div class="bd-left">
              <span class="bd-chevron" aria-hidden="true">▶</span>
              <span class="bd-dot" style="background:${esc(cat.color)}"></span>
              <div class="bd-title-wrap">
                <div class="bd-title">${esc(cat.label)}</div>
                <div class="bd-desc">${esc(cat.desc)}</div>
              </div>
            </div>
            <div class="bd-right mono">${fmtNum(cat.tokens)}<small>${cat.percentOfBase}%</small></div>
          </summary>
          <div class="bd-items">${itemsHtml}${extraHtml}${emptyItemHtml}</div>
        </details>
      `;
    }).join('');

    groups.querySelectorAll('details.bd-group').forEach((el) => {
      el.addEventListener('toggle', () => {
        const id = el.dataset.bdId;
        if (!id) return;
        if (el.open) openGroups.add(id);
        else openGroups.delete(id);
      });
    });
  }

  function render(d) {
    if (!d) return;

    const badge = $('conv-badge');
    if (d.isNewSession) {
      badge.textContent = d.conversationId ? `${d.conversationId.slice(0, 8)} · 新会话` : '新会话';
      badge.title = d.conversationId
        ? `新会话 ID: ${d.conversationId}（尚未产生模型调用）`
        : '当前为新建空白对话，尚未产生模型调用';
      badge.style.color = 'var(--cm-growth)';
      badge.classList.remove('hidden');
    } else if (d.conversationId) {
      badge.textContent = d.conversationId.slice(0, 8);
      badge.title = `Session ID: ${d.conversationId}`;
      badge.style.color = '';
      badge.classList.remove('hidden');
    } else {
      badge.style.color = '';
      badge.classList.add('hidden');
    }

    $('used-pct').textContent = fmtPct(d.usedPercent, 2);
    $('hero-active').textContent = d.isNewSession
      ? `预计基准 ${fmtNum(d.activeContextTokens)} / ${fmtNum(d.windowLimit)}`
      : `${fmtNum(d.activeContextTokens)} / ${fmtNum(d.windowLimit)}`;
    $('hero-rem').textContent = `剩余 ${fmtNum(d.remainingTokens)} tokens (${fmtPct(d.remainingPercent, 2)})`;

    const compactPill = $('compact-pill');
    if (d.usedPercent >= 60) {
      compactPill.classList.remove('hidden');
    } else {
      compactPill.classList.add('hidden');
    }

    const track = $('bar-track');
    track.setAttribute('aria-valuenow', String(d.usedPercent));
    $('bar-base').style.width = `${Math.min(100, d.basePercent)}%`;

    const barGrowth = $('bar-growth');
    barGrowth.style.width = `${Math.min(100 - d.basePercent, d.growthPercent)}%`;
    barGrowth.classList.toggle('warn', d.usedPercent >= 60 && d.usedPercent < 85);
    barGrowth.classList.toggle('danger', d.usedPercent >= 85);

    $('leg-base').textContent = fmtNum(d.initialContextTokens);
    $('leg-growth').textContent = fmtNum(d.sessionGrowthTokens);
    $('leg-rem').textContent = fmtNum(d.remainingTokens);

    $('stat-base').textContent = `${fmtNum(d.initialContextTokens)}`;
    $('stat-base-sub').textContent = d.isNewSession
      ? `预计占窗口 ${fmtPct(d.basePercent, 2)} · System / Skills / Rules / MCP`
      : `占窗口 ${fmtPct(d.basePercent, 2)} · System / Skills / Rules / MCP`;

    $('stat-growth').textContent = `+${fmtNum(d.sessionGrowthTokens)}`;
    $('stat-growth-sub').textContent = `${d.userTurns} 轮提问 · ${d.plannerSteps} 次调用`;

    if (d.isNewSession) {
      $('stat-cache').textContent = '--';
      $('stat-cache-sub').textContent = '待发送首条消息';
      $('stat-cum').textContent = '0 输出';
      $('stat-cum-sub').textContent = '新会话尚未调用模型';
    } else {
      $('stat-cache').textContent = fmtPct(d.latestCacheHitRate, 1);
      $('stat-cache-sub').textContent = `缓存 ${fmtNum(d.latestCacheReadTokens)} · 新增 ${fmtNum(d.latestInputTokens)}`;
      $('stat-cum').textContent = `${fmtNum(d.cumulativeOutputTokens)} 输出`;
      $('stat-cum-sub').textContent = `总缓存命中 ${fmtPct(d.overallCacheHitRate, 1)} · 压缩 ${d.compactionCount} 次`;
    }

    renderBreakdown(d.baseBreakdown, d.windowLimit);
    renderChart(d.steps, d.windowLimit, d.isNewSession);
    renderSteps(d.steps, d.isNewSession);
  }

  async function poll() {
    const livePill = $('live-pill');
    const liveText = $('live-text');
    try {
      const qs = new URLSearchParams();
      const conv = currentConv();
      if (conv) qs.set('conversationId', conv);
      if (lastEtag) qs.set('etag', lastEtag);
      const data = await getJson(`/api/context?${qs.toString()}`);

      livePill.classList.remove('stale');
      if (data.updatedAt) {
        const dt = new Date(data.updatedAt);
        liveText.textContent = Number.isNaN(dt.getTime())
          ? 'Live'
          : `Live · ${dt.toLocaleTimeString('zh-CN', { hour12: false })}`;
      } else {
        liveText.textContent = 'Live';
      }

      if (data.unchanged) return;
      lastEtag = data.etag || '';
      lastData = data;
      render(lastData);
    } catch {
      livePill.classList.add('stale');
      liveText.textContent = 'Reconnecting…';
    }
  }

  poll();
  setInterval(poll, POLL_MS);
})();
