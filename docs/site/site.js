// AgentDeck site: language toggle, theme switcher, copy buttons, menu bar clock, reveal on scroll.
(() => {
  const zh = {
    "nav.features": "功能",
    "nav.skills": "技能",
    "nav.themes": "主题",
    "nav.privacy": "隐私",
    "nav.install": "安装",
    "hero.eyebrow": "免费开源的菜单栏工具，适用于 Claude Code 和 Codex · macOS",
    "fi.limits.k": "额度",
    "fi.limits": "5 小时额度和每周额度，附重置时间",
    "fi.alerts.k": "提醒",
    "fi.alerts": "快到上限时发通知",
    "fi.usage.k": "用量",
    "fi.usage": "每日热力图，会话、消息和 token 统计",
    "fi.models.k": "模型",
    "fi.models": "按模型、按天统计 token",
    "fi.skills.k": "技能",
    "fi.skills": "Claude Code 和 Codex 共同管理一个技能库",
    "fi.widget.k": "小组件",
    "fi.widget": "桌面小组件，有小、中、大三种尺寸",
    "fi.themes.k": "配色",
    "fi.themes": "五套配色，各有亮色和暗色",
    "fi.export.k": "导出",
    "fi.export": "把概览存成图片",
    "fi.publish.k": "发布",
    "fi.publish": "可选：把用量卡片发到 GitHub 主页或个人网站",
    "fi.cli.k": "命令行",
    "fi.cli": "解析日志、导出数据和管理技能的命令行工具",
    "index.title": "全部功能",

    "hero.title1": "额度用了多少，",
    "hero.title2": "在菜单栏里看。",
    "hero.lede": "AgentDeck 读取 Claude Code 和 Codex 在你 Mac 上写下的日志，显示 5 小时额度和每周额度用了多少、什么时候重置，还能统一管理两个工具的技能。不用注册账号。",
    "hero.cta1": "下载",
    "hero.cta2": "功能",
    "spec.tracks": "支持",
    "spec.runs": "系统",
    "spec.network": "联网",
    "spec.none": "不联网",
    "spec.price": "价格",
    "spec.free": "免费，开源",
    "strip.tools": "个工具：Claude Code、Codex",
    "strip.network": "个账号要注册，也不收集数据",
    "strip.themes": "套配色，有亮色和暗色",
    "strip.folder": "个数据文件夹：~/.agentdeck",
    "features.kicker": "功能",
    "features.title1": "功能",
    "features.title2": "",
    "f.limits.title": "5 小时额度和每周额度",
    "f.limits.body": "百分比和 token 数并排显示，旁边写着重置时间。Codex 的数字来自它自己的日志；Claude 的数字每 5 分钟向 Claude 查询一次，和 Claude Code 的 /usage 一样；关掉联网时，按本地日志估算。",
    "f.overview.title": "每日用量热力图",
    "f.overview.body": "会话数、消息数、token 总量、活跃天数、最常用的时段和模型，可以按工具和时间范围筛选。",
    "f.models.title": "按模型统计",
    "f.models.body": "按模型、按天统计 token。Claude Code 会把同一条回复写成好几行日志，AgentDeck 只算一次。",
    "f.widget.title": "桌面小组件",
    "f.widget.body": "有小、中、大三种尺寸，显示倒计时、每项额度和最近两周每天的 token。",
    "f.publish.title": "公开用量（可选）",
    "f.publish.body": "默认关闭。打开后，可以把用量卡片发到 GitHub 主页，或者给个人网站生成一份数据文件。里面只有汇总数字，没有路径、提示词和项目名。每次推送前会先给你看改了什么。",
    "skills.kicker": "技能",
    "skills.title1": "Claude Code 和 Codex",
    "skills.title2": "共用一个技能库。",
    "skills.sub": "两个工具各有自己的技能文件夹。AgentDeck 把技能放在 ~/.agentdeck/skills 里统一管理，每个技能给哪个工具用，打开对应的开关就行。点一下技能名，能看到它在每个位置的路径，直接打开 SKILL.md 或在 Finder 里显示。",
    "s1.title": "按工具开关",
    "s1.body": "同一个技能可以只给 Claude Code、只给 Codex，或者两个都给。Claude Code 拿到的是一份副本，因为 Claude 桌面端会跳过链接过去的文件夹；Codex 拿到的是链接。在技能库里改了技能，副本会跟着更新。",
    "s2.title": "导入已有的技能",
    "s2.body": "可以从两个工具的技能文件夹、本地文件夹或 git 仓库导入。遇到同名但内容不同的技能，会并排显示差异，由你决定留哪一份。",
    "s3.title": "改动前先列计划",
    "s3.body": "每次改动前，AgentDeck 先列出要做什么。被替换的文件会备份，附一份 RESTORE.txt 写明怎么恢复。技能库本身是 git 仓库，每次修改都有记录。",
    "s4.title": "不改内置技能",
    "s4.body": "Codex 自带的技能、插件里的技能和 Claude 桌面端的技能只显示，不修改。一个技能包在列表里显示为一行。",
    "themes.kicker": "主题",
    "themes.title1": "五套配色",
    "themes.title2": "",
    "themes.sub": "在“设置 › Appearance”里切换。每套都有亮色和暗色，跟随系统外观。",
    "themes.dark": "暗色",
    "themes.light": "亮色",
    "privacy.kicker": "隐私",
    "privacy.title1": "数据只留在你的 Mac 上",
    "privacy.title2": "",
    "p1.title": "只读",
    "p1.body": "AgentDeck 只读取 Claude Code 和 Codex 本来就会写的日志，解析结果存进本地数据库。Claude Code 会删掉 30 天前的记录，但 AgentDeck 里的历史还在。",
    "p2.title": "不收集数据",
    "p2.body": "不需要账号，没有统计分析。AgentDeck 只在两种情况下联网：用你的 Claude Code 登录查询 Claude 额度（可以在设置里关掉），以及你打开发布功能后执行 git push。",
    "p3.title": "一个文件夹",
    "p3.body": "AgentDeck 的数据都在 ~/.agentdeck 里。要备份或删除，处理这一个文件夹就行。",
    "install.kicker": "安装",
    "install.title1": "安装",
    "install.title2": "",
    "install.sub": "需要 macOS 14 或更高版本。可以直接下载 App，也可以从源码构建。",
    "install.tab1": "直接下载",
    "install.tab2": "从源码构建",
    "install.meta": "最新版 · Apple 芯片 · macOS 14+",
    "install.download": "下载",
    "install.d1": "解压后，把 AgentDeck 拖进“应用程序”文件夹。",
    "install.d2": "第一次打开时，macOS 会提示无法验证开发者，因为这个 App 没有经过苹果公证。打开<strong>系统设置 › 隐私与安全性</strong>，点<strong>仍要打开</strong>，以后就不会再问。",
    "install.d3": "打开后，AgentDeck 的面板会出现在菜单栏图标下方。",
    "install.cli": "需要 Swift 6。装了 Command Line Tools 就够了，不需要 Xcode。",
    "install.after": "在自己 Mac 上构建的版本，打开时不用去“隐私与安全性”确认。从 Spotlight 再打开一次 AgentDeck，会出现一个可以调整大小的窗口。",
    "copy": "复制",
    "copied": "已复制",
    "footer.note": "与 Anthropic 和 OpenAI 无关。",
  };

  const store = {
    get(key) { try { return localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch { /* private mode */ } },
  };

  // Language. English lives in the HTML; Chinese replaces it and can be undone from the saved copy.
  const nodes = [...document.querySelectorAll("[data-i18n], [data-i18n-html]")];
  const english = new Map(nodes.map((node) => [node, node.innerHTML]));
  const toggle = document.querySelector("[data-lang-toggle]");
  let lang = store.get("lang") || ((navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en");

  function applyLanguage() {
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    for (const node of nodes) {
      const key = node.dataset.i18n || node.dataset.i18nHtml;
      node.innerHTML = lang === "zh" && zh[key] ? zh[key] : english.get(node);
    }
    toggle.textContent = lang === "zh" ? "EN" : "中文";
    toggle.setAttribute("aria-label", lang === "zh" ? "Switch to English" : "切换到中文");
  }
  toggle.addEventListener("click", () => {
    lang = lang === "zh" ? "en" : "zh";
    store.set("lang", lang);
    applyLanguage();
  });
  applyLanguage();

  // Theme switcher.
  const image = document.querySelector("[data-theme-img]");
  const swatches = [...document.querySelectorAll(".swatch")];
  const modes = [...document.querySelectorAll("[data-mode]")];
  let theme = "claude";
  let mode = "dark";
  // Preload so switching is instant.
  for (const t of swatches.map((s) => s.dataset.theme)) {
    for (const m of ["dark", "light"]) new Image().src = `site/img/theme-${t}-${m}.webp`;
  }
  function showTheme() {
    swatches.forEach((s) => s.setAttribute("aria-checked", String(s.dataset.theme === theme)));
    modes.forEach((b) => b.setAttribute("aria-checked", String(b.dataset.mode === mode)));
    image.classList.add("swapping");
    const next = `site/img/theme-${theme}-${mode}.webp`;
    const name = swatches.find((s) => s.dataset.theme === theme).textContent.trim();
    setTimeout(() => {
      image.src = next;
      image.alt = `AgentDeck's Overview tab in the ${name} theme, ${mode}`;
      image.classList.remove("swapping");
    }, 120);
  }
  swatches.forEach((s) => s.addEventListener("click", () => { theme = s.dataset.theme; showTheme(); }));
  modes.forEach((b) => b.addEventListener("click", () => { mode = b.dataset.mode; showTheme(); }));
  // Arrow keys move within each radio group.
  for (const group of [swatches, modes]) {
    group.forEach((button, index) => button.addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      const next = group[(index + step + group.length) % group.length];
      next.focus();
      next.click();
    }));
  }

  // Install tabs.
  const tabs = [...document.querySelectorAll('[role="tab"]')];
  function selectTab(tab) {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    }
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectTab(tab));
    tab.addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (!step) return;
      const next = tabs[(index + step + tabs.length) % tabs.length];
      next.focus();
      selectTab(next);
    });
  });
  document.querySelectorAll("[data-open-tab]").forEach((link) => link.addEventListener("click", () => {
    selectTab(document.getElementById(`tab-${link.dataset.openTab}`));
  }));

  // Copy buttons.
  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = lang === "zh" ? zh.copied : "Copied";
        button.classList.add("done");
        setTimeout(() => {
          button.textContent = lang === "zh" ? zh.copy : "Copy";
          button.classList.remove("done");
        }, 1600);
      } catch { /* clipboard blocked: the command stays selectable */ }
    });
  });

  // The fake menu bar: a live clock and a countdown that ticks.
  const clock = document.querySelector("[data-clock]");
  const ticker = document.querySelector("[data-ticker]");
  let claude = 3 * 60 + 10;
  let codex = 1 * 60 + 50;
  const hm = (minutes) => `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}`;
  function tick() {
    const now = new Date();
    clock.textContent = now.toLocaleString(lang === "zh" ? "zh-CN" : "en-US", { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false });
    ticker.innerHTML = `CC 46% ${hm(claude)}&nbsp;&nbsp;CX 38% ${hm(codex)}`;
  }
  tick();
  setInterval(() => {
    claude = claude > 0 ? claude - 1 : 300;
    codex = codex > 0 ? codex - 1 : 300;
    tick();
  }, 6000);

  // Reveal on scroll.
  const reveal = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window) || matchMedia("(prefers-reduced-motion: reduce)").matches) {
    reveal.forEach((el) => el.classList.add("in"));
  } else {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      }
    }, { rootMargin: "0px 0px -8% 0px" });
    reveal.forEach((el, i) => { el.style.transitionDelay = `${(i % 4) * 60}ms`; observer.observe(el); });
  }
})();
