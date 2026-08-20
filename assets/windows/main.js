const {
  app,
  BrowserWindow,
  ipcMain,
  Notification,
  screen,
  shell,
} = require("electron");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const SUPPORT_DIR = path.join(app.getPath("appData"), "Codex Context Meter");
const MAX_TAIL_BYTES = 2 * 1024 * 1024;
const AUTOMATIC_HANDOFF_THRESHOLD = 80;
const AUTOMATIC_HANDOFF_ENABLED_DEFAULT = true;
let ringWindow;
let detailsWindow;
let currentSnapshot = null;
let accountQuota = null;
let accountQuotaFetchedAt = 0;
let hoverGeneration = 0;
let threadCache = [];
let threadCacheAt = 0;
let rolloutCache = new Map();
const handoffThreadsInFlight = new Set();
const taskHistoryCache = new Map();

const foregroundScript = String.raw`
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MeterWin32 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$h = [MeterWin32]::GetForegroundWindow()
$pidValue = 0
[void][MeterWin32]::GetWindowThreadProcessId($h, [ref]$pidValue)
$p = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
$title = New-Object System.Text.StringBuilder 1024
[void][MeterWin32]::GetWindowText($h, $title, 1024)
$rect = New-Object MeterWin32+RECT
[void][MeterWin32]::GetWindowRect($h, [ref]$rect)
$edit = $null
$menuCount = 0
try {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Edit
  )
  $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  $candidates = @()
  foreach ($item in $items) {
    $r = $item.Current.BoundingRectangle
    if ($r.Width -ge 260 -and $r.Height -ge 30) {
      $candidates += [pscustomobject]@{Left=$r.Left;Top=$r.Top;Right=$r.Right;Bottom=$r.Bottom;Width=$r.Width;Height=$r.Height}
    }
  }
  $edit = $candidates | Sort-Object @{Expression={$_.Top};Descending=$true}, @{Expression={$_.Width};Descending=$true} | Select-Object -First 1
  foreach ($label in @('模型','推理强度','速度','高级')) {
    $nameCondition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      $label
    )
    if ($null -ne $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)) {
      $menuCount += 1
    }
  }
} catch {}
[pscustomobject]@{
  processName=$p.ProcessName
  processPath=$p.Path
  title=$title.ToString()
  left=$rect.Left
  top=$rect.Top
  right=$rect.Right
  bottom=$rect.Bottom
  composer=$edit
  modelMenuOpen=($menuCount -ge 2)
} | ConvertTo-Json -Compress -Depth 4
`;

function execFile(file, args, timeout = 10_000) {
  return new Promise((resolve, reject) => {
    childProcess.execFile(file, args, { windowsHide: true, timeout }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });
}

async function foregroundInfo() {
  const output = await execFile(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", foregroundScript],
  );
  return JSON.parse(output.trim());
}

function isCodex(info) {
  return /^(codex|chatgpt)$/i.test(info?.processName || "");
}

function toDipRect(rect) {
  const topLeft = screen.screenToDipPoint({ x: Math.round(rect.left), y: Math.round(rect.top) });
  const bottomRight = screen.screenToDipPoint({ x: Math.round(rect.right), y: Math.round(rect.bottom) });
  return {
    left: topLeft.x,
    top: topLeft.y,
    right: bottomRight.x,
    bottom: bottomRight.y,
  };
}

async function refreshThreadCache() {
  if (Date.now() - threadCacheAt < 10_000) return;
  threadCacheAt = Date.now();
  const index = path.join(CODEX_HOME, "session_index.jsonl");
  let raw;
  try {
    raw = fs.readFileSync(index, "utf8");
  } catch {
    threadCache = [];
    return;
  }
  const byId = new Map();
  for (const line of raw.split(/\r?\n/)) {
    if (!line) continue;
    try {
      const item = JSON.parse(line);
      if (!item.id || !item.thread_name) continue;
      const previous = byId.get(item.id);
      if (!previous || String(previous.updated_at || "") <= String(item.updated_at || "")) {
        byId.set(item.id, {
          id: item.id,
          name: item.thread_name,
          updatedAt: Date.parse(item.updated_at || 0) || 0,
        });
      }
    } catch {}
  }
  threadCache = [...byId.values()];
  await refreshRolloutCache();
}

async function walk(directory, output = []) {
  let entries;
  try {
    entries = await fs.promises.readdir(directory, { withFileTypes: true });
  } catch {
    return output;
  }
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) await walk(fullPath, output);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) output.push(fullPath);
  }
  return output;
}

async function refreshRolloutCache() {
  const files = [
    ...(await walk(path.join(CODEX_HOME, "sessions"))),
    ...(await walk(path.join(CODEX_HOME, "archived_sessions"))),
  ];
  const knownIds = new Set(threadCache.map((entry) => entry.id));
  for (const file of files) {
    const match = file.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\.jsonl$)/i);
    if (match && knownIds.has(match[0])) rolloutCache.set(match[0], file);
  }
}

function chooseThread(windowTitle) {
  const titleMatches = threadCache.filter((entry) => windowTitle?.includes(entry.name));
  if (titleMatches.length) {
    return titleMatches.sort((a, b) => b.updatedAt - a.updatedAt)[0];
  }
  const candidates = [];
  for (const entry of threadCache) {
    const rollout = rolloutCache.get(entry.id);
    if (!rollout) continue;
    try {
      candidates.push({ entry, modified: fs.statSync(rollout).mtimeMs });
    } catch {}
  }
  return candidates.sort((a, b) => b.modified - a.modified)[0]?.entry || null;
}

function readTail(file) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - MAX_TAIL_BYTES);
    const buffer = Buffer.alloc(size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    let text = buffer.toString("utf8");
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
    return text;
  } finally {
    fs.closeSync(fd);
  }
}

function modelDisplayName(raw) {
  const names = {
    "gpt-5.3-codex-spark": "GPT-5.3 Codex Spark",
    "gpt-5.6-sol": "GPT-5.6 Sol",
    "gpt-5.6-terra": "GPT-5.6 Terra",
  };
  return names[String(raw).toLowerCase()] || raw;
}

function median(values) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function estimateCurrentTask(startedAt, latestCompletedAt, completedDurations) {
  if (!startedAt || (latestCompletedAt && startedAt <= latestCompletedAt)) return null;
  const samples = completedDurations
    .filter((duration) => duration >= 5_000 && duration <= 4 * 60 * 60_000)
    .slice(0, 12);
  const elapsed = Math.max(0, Date.now() - startedAt);
  if (samples.length < 2) {
    return {
      startedAt,
      elapsedMilliseconds: elapsed,
      estimatedCompletionAt: null,
      confidence: null,
      sampleCount: samples.length,
    };
  }
  const baseline = median(samples);
  const longerSamples = samples.filter((duration) => duration > elapsed);
  let estimatedTotal;
  if (baseline > elapsed) estimatedTotal = baseline;
  else if (longerSamples.length) estimatedTotal = median(longerSamples);
  else estimatedTotal = Math.max(elapsed * 1.25, elapsed + 60_000);
  estimatedTotal = Math.min(
    Math.max(estimatedTotal, elapsed + 15_000),
    Math.max(elapsed + 15_000, 4 * 60 * 60_000),
  );
  return {
    startedAt,
    elapsedMilliseconds: elapsed,
    estimatedCompletionAt: startedAt + estimatedTotal,
    confidence: samples.length >= 6 ? "中" : "低",
    sampleCount: samples.length,
  };
}

function readTaskHistory(file) {
  let history = taskHistoryCache.get(file) || {
    offset: 0,
    remainder: Buffer.alloc(0),
    latestStartedAt: null,
    latestCompletedAt: null,
    completedDurations: [],
  };
  const size = fs.statSync(file).size;
  if (size < history.offset) {
    history = {
      offset: 0,
      remainder: Buffer.alloc(0),
      latestStartedAt: null,
      latestCompletedAt: null,
      completedDurations: [],
    };
  }
  const fd = fs.openSync(file, "r");
  try {
    let position = history.offset;
    let pending = history.remainder;
    const chunk = Buffer.alloc(1024 * 1024);
    while (position < size) {
      const length = fs.readSync(fd, chunk, 0, Math.min(chunk.length, size - position), position);
      if (!length) break;
      position += length;
      pending = Buffer.concat([pending, chunk.subarray(0, length)]);
      let start = 0;
      for (;;) {
        const newline = pending.indexOf(0x0a, start);
        if (newline < 0) break;
        const line = pending.subarray(start, newline).toString("utf8");
        start = newline + 1;
        if (!line.includes('"task_')) continue;
        let root;
        try {
          root = JSON.parse(line);
        } catch {
          continue;
        }
        const payload = root.payload || {};
        if (root.type !== "event_msg") continue;
        if (payload.type === "task_started") {
          history.latestStartedAt = Date.parse(root.timestamp);
        } else if (payload.type === "task_complete") {
          history.latestCompletedAt = Date.parse(root.timestamp);
          const duration = Number(payload.duration_ms);
          if (Number.isFinite(duration) && duration > 0) {
            history.completedDurations.push(duration);
            history.completedDurations = history.completedDurations.slice(-12);
          }
        }
      }
      pending = pending.subarray(start);
    }
    history.offset = size;
    history.remainder = pending;
    taskHistoryCache.set(file, history);
    return history;
  } finally {
    fs.closeSync(fd);
  }
}

function parseRollout(file, thread) {
  const lines = readTail(file).split(/\r?\n/).filter(Boolean);
  let usage;
  let contextWindow;
  let modelName;
  let rawModelName;
  let lastCompactionAt;
  let latestTaskStartedAt;
  let latestTaskCompletedAt;
  const completedTaskDurations = [];
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    let root;
    try {
      root = JSON.parse(lines[index]);
    } catch {
      continue;
    }
    const payload = root.payload || {};
    if (!modelName && root.type === "turn_context" && payload.model) {
      rawModelName = payload.model;
      modelName = modelDisplayName(payload.model);
    }
    if (!lastCompactionAt && root.type === "event_msg" && payload.type === "context_compacted") {
      lastCompactionAt = root.timestamp;
    }
    if (!latestTaskStartedAt && root.type === "event_msg" && payload.type === "task_started") {
      latestTaskStartedAt = Date.parse(root.timestamp);
    }
    if (root.type === "event_msg" && payload.type === "task_complete") {
      if (!latestTaskCompletedAt) latestTaskCompletedAt = Date.parse(root.timestamp);
      const duration = Number(payload.duration_ms);
      if (completedTaskDurations.length < 12 && Number.isFinite(duration) && duration > 0) {
        completedTaskDurations.push(duration);
      }
    }
    if (!usage && root.type === "event_msg" && payload.type === "token_count") {
      const info = payload.info || {};
      const last = info.last_token_usage;
      if (last && Number(info.model_context_window) > 0) {
        usage = last;
        contextWindow = Number(info.model_context_window);
      }
    }
  }
  if (!usage) return null;
  const input = Number(usage.input_tokens || 0);
  const cached = Number(usage.cached_input_tokens || 0);
  const output = Number(usage.output_tokens || 0);
  const reasoning = Number(usage.reasoning_output_tokens || 0);
  const total = Number(usage.total_tokens || 0);
  const usedPercent = Math.max(0, Math.min(100, (total / contextWindow) * 100));
  const history = readTaskHistory(file);
  return {
    threadId: thread.id,
    threadName: thread.name,
    modelName,
    rawModelName,
    usedTokens: total,
    contextWindow,
    usedPercent,
    remainingTokens: Math.max(0, contextWindow - total),
    remainingPercent: Math.max(0, 100 - usedPercent),
    freshInputTokens: Math.max(0, input - cached),
    cachedInputTokens: cached,
    regularOutputTokens: Math.max(0, output - reasoning),
    reasoningOutputTokens: reasoning,
    lastCompactionAt,
    taskEstimate: estimateCurrentTask(
      history.latestStartedAt || latestTaskStartedAt,
      history.latestCompletedAt || latestTaskCompletedAt,
      history.completedDurations.length
        ? history.completedDurations
        : completedTaskDurations,
    ),
  };
}

function truncateText(value, limit = 1600) {
  const text = String(value || "").trim();
  return text.length > limit ? `${text.slice(0, limit)}\n…（摘录已截断）` : text;
}

function normalizeThreadName(name) {
  let value = String(name || "").trim();
  while (value.endsWith("（自动交接）")) value = value.slice(0, -"（自动交接）".length).trim();
  return value || "Codex 任务";
}

function nextThreadName(sourceName) {
  const source = normalizeThreadName(sourceName);
  const match = source.match(/^(.*?)(\s+)([0-9]+)$/);
  if (!match) return `${source} 2`;
  const [, base, separator, numberText] = match;
  let maximum = Number(numberText);
  for (const entry of threadCache) {
    const candidate = normalizeThreadName(entry.name);
    const candidateMatch = candidate.match(/^(.*?)(\s+)([0-9]+)$/);
    if (candidateMatch && candidateMatch[1] === base) maximum = Math.max(maximum, Number(candidateMatch[3]));
  }
  return `${base}${separator}${maximum + 1}`;
}

function buildAutomaticHandoff(rollout, snapshot) {
  const lines = fs.readFileSync(rollout, "utf8").split(/\r?\n/);
  let cwd;
  const messages = [];
  for (const line of lines) {
    if (!line) continue;
    let root;
    try {
      root = JSON.parse(line);
    } catch {
      continue;
    }
    const payload = root.payload || {};
    if (!cwd && root.type === "session_meta" && payload.cwd) cwd = payload.cwd;
    if (
      root.type !== "response_item"
      || payload.type !== "message"
      || !["user", "assistant"].includes(payload.role)
      || !Array.isArray(payload.content)
    ) continue;
    const text = payload.content
      .filter((item) => ["input_text", "output_text"].includes(item.type))
      .map((item) => item.text || "")
      .join("\n")
      .trim();
    if (text) messages.push({ role: payload.role, text: truncateText(text) });
  }
  if (!cwd) throw new Error("无法读取当前任务的项目目录");
  const recent = messages.slice(-12);
  const latestUser = [...recent].reverse().find((item) => item.role === "user")?.text
    || "未能从本机记录提取，请先读取来源任务。";
  const assistantNotes = recent
    .filter((item) => item.role === "assistant")
    .slice(-4)
    .map((item) => `- ${item.text}`)
    .join("\n") || "- 暂无可提取的完成回显。";
  const transcript = recent
    .map((item) => `### ${item.role === "user" ? "用户" : "Codex"}\n${item.text}`)
    .join("\n\n");
  const nextName = nextThreadName(snapshot.threadName);
  const markdown = `# Codex 自动交接包

来源任务：${snapshot.threadName}
来源 Thread ID：${snapshot.threadId}
生成时间：${new Date().toISOString()}
触发依据：上下文仪表读取到真实使用率 ${snapshot.usedPercent.toFixed(1)}%，达到 ${AUTOMATIC_HANDOFF_THRESHOLD}% 阈值。

## 用户目标

${latestUser}

## 已完成

以下是来源任务最近的 Codex 回显，属于本机记录摘录，接手后必须结合 Git 状态和文件实际内容复核：
${assistantNotes}

## 进行中

这是同一项工作的后续任务，不是一个空白的新对话。必须把本交接包视为来源任务的工作状态：先检查工作区和运行状态，随后直接继续处理来源任务最后一项用户要求，避免重复已经完成的工作或只回复“已收到”。

## 关键文件/路径

- 项目目录：${cwd}
- 来源任务记录：${rollout}
- 本交接包由 Codex 上下文仪表在本机生成。

## 重要决定

- 只以上下文仪表的真实百分比触发自动交接。
- 当前任务完成后才创建下一任务，不中断原子操作。
- 使用 Codex 官方 App Server 创建任务，并使用已注册的 \`codex://threads/<threadId>\` 打开。

## 禁止事项

- 不读取 \`~/.codex/auth.json\`。
- 不写 Codex SQLite。
- 不伪造状态、进度、额度或上下文百分比。
- 保留全部未提交修改，不做破坏性 Git 操作。
- 未经用户明确要求，不发送外部消息，不归档、中断或删除其他任务。

## 验证结果

- 交接触发值：${snapshot.usedPercent.toFixed(1)}%。
- 上下文窗口：${snapshot.usedTokens} / ${snapshot.contextWindow} tokens。
- 交接包内容来自本机只读 rollout；“已完成”仍需按实际文件和测试结果复核。

## 下一步

1. 完整读取本交接包。
2. 在项目目录执行 \`git status\`，保留所有既有修改。
3. 复核最后一项用户要求、现有代码和验证结果。
4. 从未完成处继续执行实际工作，修改后执行相应验证；不要等待用户重复说明任务。

## 最近对话摘录

${transcript}
`;
  return {
    sourceThreadId: snapshot.threadId,
    sourceThreadName: snapshot.threadName,
    nextThreadName: nextName,
    cwd,
    markdown,
  };
}

function writeAutomaticHandoff(handoff) {
  const directory = path.join(SUPPORT_DIR, "handoffs");
  fs.mkdirSync(directory, { recursive: true });
  const file = path.join(directory, `${handoff.sourceThreadId}-${Date.now()}.md`);
  fs.writeFileSync(file, handoff.markdown, "utf8");
  return file;
}

async function createNextThread(executable, handoff, modelName) {
  if (!executable) throw new Error("找不到 Codex 官方本机程序");
  const processHandle = childProcess.spawn(executable, ["app-server", "--stdio"], {
    windowsHide: true,
    stdio: ["pipe", "pipe", "ignore"],
  });
  const lines = readline.createInterface({ input: processHandle.stdout });
  const pending = new Map();
  const failAll = (error) => {
    for (const item of pending.values()) item.reject(error);
    pending.clear();
  };
  lines.on("line", (line) => {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    const item = pending.get(message.id);
    if (!item) return;
    pending.delete(message.id);
    if (message.error) item.reject(new Error(message.error.message || "Codex App Server 错误"));
    else item.resolve(message.result || {});
  });
  lines.on("close", () => failAll(new Error("Codex App Server 未返回结果")));
  const request = (id, method, params = {}) => new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Codex App Server 请求超时：${method}`));
    }, 30_000);
    pending.set(id, {
      resolve: (value) => {
        clearTimeout(timeout);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timeout);
        reject(error);
      },
    });
    processHandle.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
  });
  try {
    await request(1, "initialize", {
      clientInfo: { name: "codex-context-meter", version: "1.3" },
    });
    processHandle.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
    const startParams = { cwd: handoff.cwd };
    if (modelName) startParams.model = modelName;
    const started = await request(2, "thread/start", startParams);
    const threadId = started.thread?.id;
    if (!threadId) throw new Error("Codex App Server 未返回新任务 ID");
    await request(3, "thread/name/set", {
      threadId,
      name: handoff.nextThreadName,
    });
    await request(4, "turn/start", {
      threadId,
      input: [{
        type: "text",
        text: `这是由 Codex 上下文仪表在来源任务达到 80% 后创建的同一工作续接任务，不是空白对话。\n不要要求用户重复说明，也不要只确认收到。请完整读取以下交接包，在其中指定的项目目录检查现状后，立刻从未完成处继续实际工作：\n\n${handoff.markdown}`,
      }],
    });
    return threadId;
  } finally {
    lines.close();
    processHandle.kill();
  }
}

function locateCodexExecutable(info) {
  const candidates = [];
  if (info?.processPath) {
    const base = path.dirname(info.processPath);
    candidates.push(
      path.join(base, "resources", "codex.exe"),
      path.join(base, "Resources", "codex.exe"),
      path.join(base, "codex.exe"),
    );
  }
  if (process.env.LOCALAPPDATA) {
    candidates.push(
      path.join(process.env.LOCALAPPDATA, "Programs", "Codex", "resources", "codex.exe"),
      path.join(process.env.LOCALAPPDATA, "Programs", "ChatGPT", "resources", "codex.exe"),
    );
  }
  return candidates.find((candidate) => fs.existsSync(candidate));
}

function parseQuotaWindow(value) {
  if (!value || value.usedPercent == null) return null;
  return {
    remainingPercent: Math.max(0, Math.min(100, 100 - Number(value.usedPercent))),
    durationMinutes: value.windowDurationMins == null ? null : Number(value.windowDurationMins),
    resetsAt: value.resetsAt ? Number(value.resetsAt) * 1000 : null,
  };
}

async function fetchAccountQuota(executable) {
  if (!executable) return null;
  return new Promise((resolve) => {
    const processHandle = childProcess.spawn(executable, ["app-server", "--stdio"], {
      windowsHide: true,
      stdio: ["pipe", "pipe", "ignore"],
    });
    const lines = readline.createInterface({ input: processHandle.stdout });
    const timeout = setTimeout(() => {
      processHandle.kill();
      resolve(null);
    }, 20_000);
    let initialized = false;
    const finish = (value) => {
      clearTimeout(timeout);
      lines.close();
      processHandle.kill();
      resolve(value);
    };
    lines.on("line", (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      if (message.id === 1 && message.result && !initialized) {
        initialized = true;
        processHandle.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
        processHandle.stdin.write(`${JSON.stringify({ id: 2, method: "account/rateLimits/read" })}\n`);
      } else if (message.id === 2) {
        const result = message.result || {};
        const byId = result.rateLimitsByLimitId || {};
        const selected = byId.codex || Object.values(byId)[0] || result.rateLimits;
        if (!selected) return finish(null);
        finish({
          primary: parseQuotaWindow(selected.primary),
          secondary: parseQuotaWindow(selected.secondary),
          individualLimit: selected.individualLimit
            ? {
                limit: selected.individualLimit.limit,
                used: selected.individualLimit.used,
                remainingPercent: Number(selected.individualLimit.remainingPercent),
              }
            : null,
          creditBalance: selected.credits?.balance ?? null,
        });
      }
    });
    processHandle.stdin.write(
      `${JSON.stringify({
        id: 1,
        method: "initialize",
        params: { clientInfo: { name: "codex-context-meter", version: "1.1" } },
      })}\n`,
    );
  });
}

function stateFile() {
  return path.join(SUPPORT_DIR, "state.json");
}

function readState() {
  try {
    return JSON.parse(fs.readFileSync(stateFile(), "utf8"));
  } catch {
    return {};
  }
}

function writeState(state) {
  fs.mkdirSync(SUPPORT_DIR, { recursive: true });
  fs.writeFileSync(stateFile(), JSON.stringify(state, null, 2));
}

function notifyCompaction(snapshot) {
  if (!snapshot.lastCompactionAt) return;
  const state = readState();
  const key = `compaction:${snapshot.threadId}`;
  const previous = state[key];
  if (previous && Date.parse(snapshot.lastCompactionAt) > Date.parse(previous)) {
    new Notification({
      title: "Codex 上下文已重置",
      body: `${snapshot.threadName} 已完成上下文压缩，当前使用 ${snapshot.usedPercent.toFixed(1)}%。`,
    }).show();
  }
  state[key] = snapshot.lastCompactionAt;
  writeState(state);
}

function automaticHandoffStatus(snapshot) {
  if (!snapshot) return "inactive";
  const state = readState();
  if (state.automaticHandoffEnabled === false) return "disabled";
  const triggerPercent = Number(state[`handoffTrigger:${snapshot.threadId}`]);
  if (state[`handoffCompleted:${snapshot.threadId}`]
      && Number.isFinite(triggerPercent)
      && triggerPercent >= AUTOMATIC_HANDOFF_THRESHOLD
      && triggerPercent <= 100) return "completed";
  if (handoffThreadsInFlight.has(snapshot.threadId)) return "creating";
  if (state[`handoffPending:${snapshot.threadId}`]) {
    return snapshot.taskEstimate ? "waiting_for_task_completion" : "pending";
  }
  return "inactive";
}

async function considerAutomaticHandoff(snapshot, rollout, executable) {
  const state = readState();
  const pendingKey = `handoffPending:${snapshot.threadId}`;
  const completedKey = `handoffCompleted:${snapshot.threadId}`;
  const noticeKey = `handoffPendingNotice:${snapshot.threadId}`;
  const attemptKey = `handoffLastAttempt:${snapshot.threadId}`;
  const triggerKey = `handoffTrigger:${snapshot.threadId}`;
  if (state.automaticHandoffEnabled === false) {
    state[pendingKey] = false;
    writeState(state);
    return;
  }
  const triggerPercent = Number(state[triggerKey]);
  if (state[completedKey]
      && Number.isFinite(triggerPercent)
      && triggerPercent >= AUTOMATIC_HANDOFF_THRESHOLD
      && triggerPercent <= 100) return;
  if (state[completedKey]) delete state[completedKey];
  if (snapshot.usedPercent >= AUTOMATIC_HANDOFF_THRESHOLD) {
    if (!state[pendingKey]) state[triggerKey] = snapshot.usedPercent;
    state[pendingKey] = true;
  }
  if (!state[pendingKey]) return;
  if (snapshot.taskEstimate) {
    if (!state[noticeKey]) {
      state[noticeKey] = true;
      new Notification({
        title: "Codex 上下文已达到 80%，准备创建新任务",
        body: `${snapshot.threadName} 将在当前任务安全完成后保存交接包并创建新任务。`,
      }).show();
    }
    writeState(state);
    return;
  }
  if (handoffThreadsInFlight.has(snapshot.threadId)) return;
  if (state[attemptKey] && Date.now() - Number(state[attemptKey]) < 5 * 60_000) return;

  state[attemptKey] = Date.now();
  writeState(state);
  handoffThreadsInFlight.add(snapshot.threadId);
  sendSnapshot();
  try {
    const handoff = buildAutomaticHandoff(rollout, snapshot);
    const handoffFile = writeAutomaticHandoff(handoff);
    const newThreadId = await createNextThread(executable, handoff, snapshot.rawModelName);
    const latestState = readState();
    latestState[completedKey] = newThreadId;
    latestState[pendingKey] = false;
    writeState(latestState);
    try {
      await shell.openExternal(`codex://threads/${newThreadId}`);
      new Notification({
        title: "Codex 已创建新任务",
        body: "已保存交接包并打开下一任务。",
      }).show();
    } catch {
      new Notification({
        title: "Codex 新任务已创建",
        body: `交接包已保存到 ${handoffFile}，但任务链接未能自动打开。`,
      }).show();
    }
  } catch (error) {
    new Notification({
      title: "Codex 自动交接失败",
      body: `${error.message || error}。交接将在 5 分钟后重试。`,
    }).show();
  } finally {
    handoffThreadsInFlight.delete(snapshot.threadId);
    sendSnapshot();
  }
}

function positionWindows(info) {
  const target = info.composer
    ? toDipRect({
        left: info.composer.Left ?? info.composer.left,
        top: info.composer.Top ?? info.composer.top,
        right: info.composer.Right ?? info.composer.right,
        bottom: info.composer.Bottom ?? info.composer.bottom,
      })
    : toDipRect(info);
  const ringX = Math.round(target.right - (info.modelMenuOpen ? 305 : 245));
  const ringY = Math.round(target.bottom - 37);
  ringWindow.setBounds({ x: ringX, y: ringY, width: 32, height: 28 }, false);
  detailsWindow.setBounds(
    {
      x: ringX + 32 - 366,
      y: ringY - 520,
      width: 366,
      height: 520,
    },
    false,
  );
}

function sendSnapshot() {
  const state = readState();
  const payload = currentSnapshot
    ? {
        ...currentSnapshot,
        accountQuota,
        automaticHandoffThreshold: AUTOMATIC_HANDOFF_THRESHOLD,
        automaticHandoffEnabled: state.automaticHandoffEnabled ?? AUTOMATIC_HANDOFF_ENABLED_DEFAULT,
        automaticHandoffStatus: automaticHandoffStatus(currentSnapshot),
      }
    : null;
  ringWindow?.webContents.send("snapshot", payload);
  detailsWindow?.webContents.send("snapshot", payload);
}

async function refresh() {
  let info;
  try {
    info = await foregroundInfo();
  } catch {
    ringWindow.hide();
    detailsWindow.hide();
    return;
  }
  if (!isCodex(info)) {
    ringWindow.hide();
    detailsWindow.hide();
    return;
  }
  await refreshThreadCache();
  const thread = chooseThread(info.title);
  const rollout = thread && rolloutCache.get(thread.id);
  if (!thread || !rollout) {
    ringWindow.hide();
    detailsWindow.hide();
    return;
  }
  let snapshot;
  try {
    snapshot = parseRollout(rollout, thread);
  } catch {
    snapshot = null;
  }
  if (!snapshot) {
    ringWindow.hide();
    detailsWindow.hide();
    return;
  }
  notifyCompaction(snapshot);
  currentSnapshot = snapshot;
  void considerAutomaticHandoff(
    snapshot,
    rollout,
    locateCodexExecutable(info),
  );
  positionWindows(info);
  ringWindow.showInactive();
  sendSnapshot();

  if (Date.now() - accountQuotaFetchedAt > 5 * 60_000) {
    accountQuotaFetchedAt = Date.now();
    accountQuota = await fetchAccountQuota(locateCodexExecutable(info));
    sendSnapshot();
  }
}

function createWindow(file, width, height) {
  const window = new BrowserWindow({
    width,
    height,
    show: false,
    frame: false,
    transparent: true,
    resizable: false,
    focusable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  window.setAlwaysOnTop(true, "floating");
  window.setVisibleOnAllWorkspaces(true);
  window.loadFile(file);
  window.webContents.on("did-finish-load", sendSnapshot);
  return window;
}

function setHovered(hovered) {
  hoverGeneration += 1;
  const generation = hoverGeneration;
  if (hovered) {
    if (currentSnapshot) {
      detailsWindow.showInactive();
      sendSnapshot();
    }
    return;
  }
  setTimeout(() => {
    if (generation === hoverGeneration) detailsWindow.hide();
  }, 350);
}

app.whenReady().then(() => {
  app.setLoginItemSettings({ openAtLogin: true });
  ringWindow = createWindow("ring.html", 32, 28);
  detailsWindow = createWindow("details.html", 366, 520);
  ipcMain.on("hover", (_event, message) => setHovered(Boolean(message?.hovered)));
  ipcMain.on("close-details", () => {
    hoverGeneration += 1;
    detailsWindow.hide();
  });
  ipcMain.on("set-automatic-handoff-enabled", (_event, enabled) => {
    const state = readState();
    state.automaticHandoffEnabled = Boolean(enabled);
    writeState(state);
    sendSnapshot();
  });
  refresh();
  setInterval(refresh, 3_000);
});

app.on("window-all-closed", () => {});
