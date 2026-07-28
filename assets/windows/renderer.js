const palette = {
  green: "#18b893",
  blue: "#4b8eff",
  purple: "#7357ff",
  yellow: "#f0b44d",
  gray: "#9ba4b3",
};

function compact(value) {
  if (!Number.isFinite(value)) return "—";
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 1 : 2)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value >= 100_000 ? 0 : 1)}K`;
  return String(Math.round(value));
}

function percent(value, digits = 1) {
  return `${Number(value).toFixed(digits)}%`;
}

function duration(milliseconds) {
  const total = Math.max(0, Math.round(milliseconds / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  if (hours > 0) return `${hours}小时 ${minutes}分`;
  if (minutes > 0) return `${minutes}分 ${seconds}秒`;
  return `${seconds}秒`;
}

function completionTime(timestamp) {
  return new Date(timestamp).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

function handoffStatus(status) {
  const labels = {
    waiting_for_task_completion: "等待当前任务",
    creating: "正在交接",
    completed: "已完成",
    failed: "失败待重试",
    retry_wait: "等待重试",
    pending: "待交接",
  };
  return labels[status] || "未触发";
}

function addRow(container, { color, label, value, secondary, help }) {
  const row = document.createElement("div");
  row.className = "metric-row";
  row.innerHTML = `
    <span class="dot" style="--row-color:${color}"></span>
    <span class="label"></span>
    ${help ? '<span class="help">ⓘ</span>' : ""}
    <span class="spacer"></span>
    ${secondary ? '<span class="secondary"></span>' : ""}
    <span class="value"></span>
  `;
  row.querySelector(".label").textContent = label;
  row.querySelector(".value").textContent = value;
  if (secondary) row.querySelector(".secondary").textContent = secondary;
  if (help) row.querySelector(".help").title = help;
  container.appendChild(row);
}

function section(container, title) {
  const label = document.createElement("div");
  label.className = "section-label";
  label.textContent = title;
  container.appendChild(label);
}

function quotaLabel(window, fallback) {
  const minutes = window?.durationMinutes;
  if (!minutes) return fallback;
  if (minutes >= 6 * 24 * 60 && minutes <= 8 * 24 * 60) return "每周额度剩余";
  if (minutes === 24 * 60) return "每日额度剩余";
  if (minutes % 60 === 0 && minutes <= 48 * 60) return `${minutes / 60} 小时额度剩余`;
  return fallback;
}

function resetText(timestamp) {
  if (!timestamp) return "";
  return `重置 ${new Date(timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
}

function renderRing(snapshot) {
  const progress = document.getElementById("ring-progress");
  const used = snapshot?.usedPercent ?? 0;
  const color = used >= 90 ? "#ef5b5b" : used >= 75 ? palette.yellow : palette.green;
  progress.style.setProperty("--progress", `${Math.min(100, used)}%`);
  progress.style.setProperty("--ring-color", color);
  document.getElementById("meter-ring").title = snapshot
    ? `${percent(used)} · ${compact(snapshot.usedTokens)} / ${compact(snapshot.contextWindow)} 上下文已使用`
    : "等待 Codex 对话";
}

function renderDetails(snapshot) {
  if (!snapshot) return;
  document.getElementById("used-percent").textContent = percent(snapshot.usedPercent);
  document.getElementById("used-count").textContent =
    `已使用  ${compact(snapshot.usedTokens)} / ${compact(snapshot.contextWindow)}`;
  document.getElementById("usage-fill").style.width = `${snapshot.usedPercent}%`;
  document.getElementById("source-label").textContent = `真实只读数据 · ${snapshot.threadName}`;

  const rows = document.getElementById("metric-rows");
  rows.replaceChildren();
  addRow(rows, {
    color: palette.green,
    label: "上下文剩余",
    value: percent(snapshot.remainingPercent),
    secondary: compact(snapshot.remainingTokens),
  });
  addRow(rows, {
    color: palette.yellow,
    label: "自动交接",
    value: handoffStatus(snapshot.automaticHandoffStatus),
    secondary: `阈值 ${snapshot.automaticHandoffThreshold || 80}%`,
    help: "只按仪表读取到的真实上下文比例触发。达到 80% 后等待当前任务完成，再保存标准交接包、新建并打开下一任务；读取不到精确比例时不触发。",
  });
  if (snapshot.taskEstimate) {
    section(rows, "当前任务");
    addRow(rows, {
      color: palette.blue,
      label: "已运行",
      value: duration(snapshot.taskEstimate.elapsedMilliseconds),
    });
    const task = snapshot.taskEstimate;
    addRow(rows, {
      color: palette.purple,
      label: "预计完成",
      value: task.estimatedCompletionAt
        ? `约 ${completionTime(task.estimatedCompletionAt)}`
        : "暂无法可靠估算",
      secondary: task.confidence ? `可信度 ${task.confidence}` : null,
      help: task.sampleCount >= 2
        ? `根据同一对话最近 ${task.sampleCount} 个已完成任务的真实耗时估算，不是 Codex 官方承诺。`
        : "当前对话的历史完成样本不足，暂不生成时间。",
    });
  }
  section(rows, "技术明细");
  const technical = [
    [palette.purple, "新输入", snapshot.freshInputTokens, "本轮需要模型重新读取和处理的输入 Token。"],
    [palette.blue, "缓存输入", snapshot.cachedInputTokens, "与之前内容重复、由系统缓存复用的输入 Token。"],
    [palette.yellow, "普通输出", snapshot.regularOutputTokens, "最终显示在对话中的回答 Token。"],
    [palette.green, "推理输出", snapshot.reasoningOutputTokens, "模型生成答案前用于内部推理的 Token。"],
  ];
  for (const [color, label, value, help] of technical) {
    if (value > 0) addRow(rows, { color, label, value: compact(value), help });
  }
  if (snapshot.modelName) {
    addRow(rows, {
      color: palette.gray,
      label: "当前模型",
      value: snapshot.modelName,
      help: "本次对话当前使用的模型，不代表账户总额度。",
    });
  }
  const quota = snapshot.accountQuota;
  if (quota) {
    section(rows, "设置额度");
    if (quota.individualLimit) {
      addRow(rows, {
        color: palette.green,
        label: "额度剩余",
        value: percent(quota.individualLimit.remainingPercent, 0),
        secondary: `${quota.individualLimit.used} / ${quota.individualLimit.limit}`,
      });
    }
    if (quota.primary) {
      addRow(rows, {
        color: palette.green,
        label: quotaLabel(quota.primary, "短时额度剩余"),
        value: percent(quota.primary.remainingPercent, 0),
        secondary: resetText(quota.primary.resetsAt),
      });
    }
    if (quota.secondary) {
      addRow(rows, {
        color: palette.blue,
        label: quotaLabel(quota.secondary, "长期额度剩余"),
        value: percent(quota.secondary.remainingPercent, 0),
        secondary: resetText(quota.secondary.resetsAt),
      });
    }
    if (quota.creditBalance != null) {
      addRow(rows, {
        color: palette.yellow,
        label: "额外购买额度",
        value: String(quota.creditBalance),
        help: "账户额外购买或获赠的可用额度；0 不影响周期额度。",
      });
    }
  }
}

const isRing = document.body.classList.contains("ring-page");
const source = isRing ? "ring" : "details";
document.body.addEventListener("mouseenter", () => window.contextMeter.setHovered(source, true));
document.body.addEventListener("mouseleave", () => window.contextMeter.setHovered(source, false));
window.contextMeter.onSnapshot((snapshot) => {
  if (isRing) renderRing(snapshot);
  else renderDetails(snapshot);
});

if (isRing) {
  document.getElementById("meter-ring").addEventListener("click", () => {
    window.contextMeter.setHovered("ring", true);
  });
} else {
  document.getElementById("close-details").addEventListener("click", () => {
    window.contextMeter.closeDetails();
  });
}
