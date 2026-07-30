using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;
using System.Web.Script.Serialization;

namespace CodexContextMeterNative {
  internal static class NativeMethods {
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    internal struct Rect { public int Left, Top, Right, Bottom; }
  }

  internal sealed class Snapshot {
    internal string ThreadId, ThreadName, ModelName, RawModelName, RolloutPath;
    internal long UsedTokens, ContextWindow, FreshInput, CachedInput, RegularOutput, ReasoningOutput;
    internal double UsedPercent { get { return ContextWindow <= 0 ? 0 : Math.Min(100, UsedTokens * 100.0 / ContextWindow); } }
    internal bool TaskRunning;
    internal DateTime? TaskStartedAt, LastCompactionAt;
  }

  internal sealed class MeterState {
    public bool AutomaticHandoffEnabled = true;
    public int AutomaticHandoffThreshold = 80;
    public Dictionary<string, string> Completed = new Dictionary<string, string>();
    public Dictionary<string, bool> Pending = new Dictionary<string, bool>();
  }

  internal static class Json {
    internal static readonly JavaScriptSerializer Parser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    internal static Dictionary<string, object> Obj(object value) { return value as Dictionary<string, object>; }
    internal static Dictionary<string, object> GetObj(Dictionary<string, object> root, string key) {
      object value; return root != null && root.TryGetValue(key, out value) ? Obj(value) : null;
    }
    internal static string GetString(Dictionary<string, object> root, string key) {
      object value; return root != null && root.TryGetValue(key, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
    }
    internal static long GetLong(Dictionary<string, object> root, string key) {
      object value; long parsed;
      return root != null && root.TryGetValue(key, out value) && value != null && long.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), out parsed) ? parsed : 0;
    }
  }

  internal sealed class RingForm : Form {
    internal Snapshot Snapshot;
    internal event Action Hovered;
    internal RingForm() {
      FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
      Width = 32; Height = 28; BackColor = Color.Magenta; TransparencyKey = Color.Magenta;
      StartPosition = FormStartPosition.Manual;
      MouseEnter += delegate { if (Hovered != null) Hovered(); };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void OnPaint(PaintEventArgs e) {
      base.OnPaint(e);
      e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      var bounds = new Rectangle(6, 4, 20, 20);
      using (var basePen = new Pen(Color.FromArgb(218, 224, 221), 3)) e.Graphics.DrawEllipse(basePen, bounds);
      var used = Snapshot == null ? 0 : Snapshot.UsedPercent;
      var color = used >= 90 ? Color.FromArgb(239, 91, 91) : used >= 75 ? Color.FromArgb(240, 180, 77) : Color.FromArgb(24, 184, 147);
      using (var pen = new Pen(color, 3)) { pen.StartCap = pen.EndCap = System.Drawing.Drawing2D.LineCap.Round; e.Graphics.DrawArc(pen, bounds, -90, (float)(used * 3.6)); }
      using (var brush = new SolidBrush(Color.FromArgb(45, 67, 58))) e.Graphics.FillEllipse(brush, 14, 12, 4, 4);
    }
  }

  internal sealed class DetailsForm : Form {
    readonly Label used = Label("0.0%", 16, 42, 220, 38, 26, true);
    readonly Label counts = Label("等待 Codex 对话", 18, 83, 320, 24, 12, false);
    readonly ProgressBar progress = new ProgressBar { Left = 18, Top = 112, Width = 328, Height = 7, Maximum = 1000 };
    readonly Label remaining = Label("上下文剩余", 18, 135, 328, 24, 13, false);
    readonly CheckBox handoff = new CheckBox { Left = 18, Top = 169, Width = 210, Height = 24, Text = "自动创建新任务", Checked = true };
    readonly Label thresholdLabel = Label("已用阈值 80%", 238, 169, 108, 24, 12, false);
    readonly TrackBar threshold = new TrackBar { Left = 12, Top = 196, Width = 340, Minimum = 50, Maximum = 95, TickFrequency = 5, Value = 80 };
    readonly Label task = Label("当前任务：—", 18, 247, 328, 24, 13, false);
    readonly Label metrics = Label("", 18, 280, 328, 150, 13, false);
    readonly Label source = Label("真实只读数据", 18, 472, 328, 24, 11, false);
    internal event Action<bool> HandoffChanged;
    internal event Action<int> ThresholdChanged;
    internal DetailsForm() {
      FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; Width = 366; Height = 520;
      BackColor = Color.FromArgb(247, 248, 247); StartPosition = FormStartPosition.Manual;
      Padding = new Padding(0); Font = new Font("Microsoft YaHei UI", 9F);
      var title = Label("上下文用量", 18, 13, 260, 26, 14, true);
      var close = new Button { Left = 326, Top = 8, Width = 30, Height = 28, FlatStyle = FlatStyle.Flat, Text = "×", TabStop = false };
      close.FlatAppearance.BorderSize = 0; close.Click += delegate { Hide(); };
      Controls.AddRange(new Control[] { title, close, used, counts, progress, remaining, handoff, thresholdLabel, threshold, task, metrics, source });
      handoff.CheckedChanged += delegate { if (HandoffChanged != null) HandoffChanged(handoff.Checked); };
      threshold.ValueChanged += delegate { thresholdLabel.Text = "已用阈值 " + threshold.Value + "%"; if (ThresholdChanged != null) ThresholdChanged(threshold.Value); };
      MouseLeave += delegate { var p = PointToClient(Cursor.Position); if (!ClientRectangle.Contains(p)) Hide(); };
    }
    static Label Label(string text, int x, int y, int w, int h, int size, bool bold) {
      return new Label { Text = text, Left = x, Top = y, Width = w, Height = h, AutoEllipsis = true, Font = new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular) };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    internal void ApplyState(MeterState state) {
      handoff.Checked = state.AutomaticHandoffEnabled;
      threshold.Value = Math.Max(threshold.Minimum, Math.Min(threshold.Maximum, state.AutomaticHandoffThreshold));
    }
    internal void Apply(Snapshot s, MeterState state) {
      if (s == null) return;
      used.Text = s.UsedPercent.ToString("0.0", CultureInfo.InvariantCulture) + "%";
      counts.Text = "上下文已用  " + Compact(s.UsedTokens) + " / " + Compact(s.ContextWindow);
      progress.Value = Math.Max(0, Math.Min(1000, (int)Math.Round(s.UsedPercent * 10)));
      remaining.Text = "●  上下文剩余                         " + Compact(Math.Max(0, s.ContextWindow - s.UsedTokens)) + "   " + (100 - s.UsedPercent).ToString("0.0") + "%";
      task.Text = s.TaskRunning && s.TaskStartedAt.HasValue ? "当前任务：已运行 " + Duration(DateTime.UtcNow - s.TaskStartedAt.Value) : "当前任务：等待输入";
      metrics.Text = "新输入                                      " + Compact(s.FreshInput) + "\r\n\r\n" +
        "缓存输入                                    " + Compact(s.CachedInput) + "\r\n\r\n" +
        "普通输出                                    " + Compact(s.RegularOutput) + "\r\n\r\n" +
        "推理输出                                    " + Compact(s.ReasoningOutput) + "\r\n\r\n" +
        "当前模型                                    " + (s.ModelName ?? "—");
      source.Text = "✓ 真实只读数据 · " + s.ThreadName;
      handoff.Checked = state.AutomaticHandoffEnabled;
      threshold.Value = Math.Max(50, Math.Min(95, state.AutomaticHandoffThreshold));
    }
    static string Compact(long n) { return n >= 1000000 ? (n / 1000000d).ToString("0.##") + "M" : n >= 1000 ? (n / 1000d).ToString(n >= 100000 ? "0" : "0.0") + "K" : n.ToString(); }
    static string Duration(TimeSpan t) { return t.TotalHours >= 1 ? ((int)t.TotalHours) + "小时 " + t.Minutes + "分" : t.Minutes > 0 ? t.Minutes + "分 " + t.Seconds + "秒" : t.Seconds + "秒"; }
  }

  internal sealed class MeterApplication : ApplicationContext {
    readonly string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    readonly string supportDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Codex Context Meter");
    readonly RingForm ring = new RingForm();
    readonly DetailsForm details = new DetailsForm();
    readonly System.Windows.Forms.Timer positionTimer = new System.Windows.Forms.Timer { Interval = 250 };
    readonly System.Windows.Forms.Timer dataTimer = new System.Windows.Forms.Timer { Interval = 3000 };
    readonly object gate = new object();
    MeterState state;
    Snapshot current;
    bool refreshing, handingOff;

    internal MeterApplication() {
      state = LoadState(); details.ApplyState(state);
      ring.Hovered += delegate { if (current != null) { details.Show(); details.BringToFront(); } };
      details.HandoffChanged += delegate(bool enabled) { state.AutomaticHandoffEnabled = enabled; SaveState(); };
      details.ThresholdChanged += delegate(int value) { state.AutomaticHandoffThreshold = value; SaveState(); };
      positionTimer.Tick += delegate { Position(); }; dataTimer.Tick += delegate { RefreshData(); };
      positionTimer.Start(); dataTimer.Start(); RefreshData();
    }

    void Position() {
      var h = NativeMethods.GetForegroundWindow(); uint pid; NativeMethods.GetWindowThreadProcessId(h, out pid);
      Process process;
      try { process = Process.GetProcessById((int)pid); } catch { HideAll(); return; }
      if (!string.Equals(process.ProcessName, "Codex", StringComparison.OrdinalIgnoreCase) && !string.Equals(process.ProcessName, "ChatGPT", StringComparison.OrdinalIgnoreCase)) { HideAll(); return; }
      NativeMethods.Rect rect; if (!NativeMethods.GetWindowRect(h, out rect)) { HideAll(); return; }
      Rectangle anchor = new Rectangle(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
      try {
        var root = AutomationElement.FromHandle(h);
        var edits = root.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
        var best = edits.Cast<AutomationElement>().Select(x => x.Current.BoundingRectangle).Where(x => x.Width >= 260 && x.Height >= 30).OrderByDescending(x => x.Top).ThenByDescending(x => x.Width).FirstOrDefault();
        if (!best.IsEmpty) anchor = Rectangle.FromLTRB((int)best.Left, (int)best.Top, (int)best.Right, (int)best.Bottom);
      } catch { }
      var x = anchor.Right - 245; var y = anchor.Bottom - 37;
      ring.Location = new Point(x, y); details.Location = new Point(x + 32 - details.Width, y - details.Height);
      if (current != null && !ring.Visible) ring.Show(); ring.Invalidate();
    }

    void HideAll() { ring.Hide(); details.Hide(); }

    void RefreshData() {
      if (refreshing) return; refreshing = true;
      ThreadPool.QueueUserWorkItem(delegate {
        try {
          var h = NativeMethods.GetForegroundWindow(); var titleBuilder = new StringBuilder(1024); NativeMethods.GetWindowText(h, titleBuilder, titleBuilder.Capacity);
          var snapshot = ReadSnapshot(titleBuilder.ToString());
          if (snapshot == null) return;
          current = snapshot;
          ring.BeginInvoke((Action)delegate { ring.Snapshot = snapshot; ring.Invalidate(); details.Apply(snapshot, state); });
          ConsiderHandoff(snapshot);
        } catch { } finally { refreshing = false; }
      });
    }

    Snapshot ReadSnapshot(string windowTitle) {
      var indexPath = Path.Combine(codexHome, "session_index.jsonl"); if (!File.Exists(indexPath)) return null;
      var threads = new List<Tuple<string, string, DateTime>>();
      foreach (var line in File.ReadLines(indexPath)) {
        try { var o = Json.Obj(Json.Parser.DeserializeObject(line)); var id = Json.GetString(o, "id"); var name = Json.GetString(o, "thread_name"); DateTime at; DateTime.TryParse(Json.GetString(o, "updated_at"), null, DateTimeStyles.AdjustToUniversal, out at); if (!string.IsNullOrEmpty(id) && !string.IsNullOrEmpty(name)) threads.Add(Tuple.Create(id, name, at)); } catch { }
      }
      var chosen = threads.Where(x => windowTitle.IndexOf(x.Item2, StringComparison.OrdinalIgnoreCase) >= 0).OrderByDescending(x => x.Item3).FirstOrDefault() ?? threads.OrderByDescending(x => x.Item3).FirstOrDefault();
      if (chosen == null) return null;
      var rollout = FindRollout(chosen.Item1); if (rollout == null) return null;
      return ParseRollout(rollout, chosen.Item1, chosen.Item2);
    }

    string FindRollout(string id) {
      foreach (var root in new[] { Path.Combine(codexHome, "sessions"), Path.Combine(codexHome, "archived_sessions") }) {
        if (!Directory.Exists(root)) continue;
        try { var file = Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories).FirstOrDefault(x => Path.GetFileNameWithoutExtension(x).IndexOf(id, StringComparison.OrdinalIgnoreCase) >= 0); if (file != null) return file; } catch { }
      }
      return null;
    }

    Snapshot ParseRollout(string file, string id, string name) {
      var info = new FileInfo(file); var start = Math.Max(0, info.Length - 2 * 1024 * 1024); string text;
      using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) { stream.Seek(start, SeekOrigin.Begin); using (var reader = new StreamReader(stream, Encoding.UTF8)) { text = reader.ReadToEnd(); } }
      var lines = text.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries); Dictionary<string, object> usage = null; long context = 0; string model = null, rawModel = null; DateTime? started = null, completed = null, compacted = null;
      for (var i = lines.Length - 1; i >= 0; i--) {
        try {
          var root = Json.Obj(Json.Parser.DeserializeObject(lines[i])); var type = Json.GetString(root, "type"); var payload = Json.GetObj(root, "payload"); if (payload == null) continue;
          if (model == null && type == "turn_context") { rawModel = Json.GetString(payload, "model"); model = DisplayModel(rawModel); }
          var eventType = Json.GetString(payload, "type"); DateTime ts; DateTime.TryParse(Json.GetString(root, "timestamp"), null, DateTimeStyles.AdjustToUniversal, out ts);
          if (!compacted.HasValue && type == "event_msg" && eventType == "context_compacted") compacted = ts;
          if (!started.HasValue && type == "event_msg" && eventType == "task_started") started = ts;
          if (!completed.HasValue && type == "event_msg" && eventType == "task_complete") completed = ts;
          if (usage == null && type == "event_msg" && eventType == "token_count") { var tokenInfo = Json.GetObj(payload, "info"); usage = Json.GetObj(tokenInfo, "last_token_usage"); context = Json.GetLong(tokenInfo, "model_context_window"); }
        } catch { }
      }
      if (usage == null || context <= 0) return null;
      var input = Json.GetLong(usage, "input_tokens"); var cached = Json.GetLong(usage, "cached_input_tokens"); var output = Json.GetLong(usage, "output_tokens"); var reasoning = Json.GetLong(usage, "reasoning_output_tokens");
      return new Snapshot { ThreadId = id, ThreadName = name, RolloutPath = file, RawModelName = rawModel, ModelName = model, UsedTokens = Json.GetLong(usage, "total_tokens"), ContextWindow = context, FreshInput = Math.Max(0, input - cached), CachedInput = cached, RegularOutput = Math.Max(0, output - reasoning), ReasoningOutput = reasoning, TaskStartedAt = started, TaskRunning = started.HasValue && (!completed.HasValue || started.Value > completed.Value), LastCompactionAt = compacted };
    }

    void ConsiderHandoff(Snapshot s) {
      if (!state.AutomaticHandoffEnabled || state.Completed.ContainsKey(s.ThreadId)) return;
      if (s.UsedPercent >= state.AutomaticHandoffThreshold) state.Pending[s.ThreadId] = true;
      bool pending; if (!state.Pending.TryGetValue(s.ThreadId, out pending) || !pending || s.TaskRunning || handingOff) { SaveState(); return; }
      handingOff = true; SaveState();
      ThreadPool.QueueUserWorkItem(delegate {
        try { var package = BuildHandoff(s); var newId = CreateNextThread(s, package.Item1, package.Item2); state.Completed[s.ThreadId] = newId; state.Pending[s.ThreadId] = false; SaveState(); Process.Start("codex://threads/" + newId); }
        catch (Exception ex) { File.AppendAllText(Path.Combine(supportDir, "handoff-error.log"), DateTime.UtcNow.ToString("o") + " " + ex + Environment.NewLine); }
        finally { handingOff = false; }
      });
    }

    Tuple<string, string> BuildHandoff(Snapshot s) {
      var cwd = ""; var messages = new List<Tuple<string, string>>();
      foreach (var line in File.ReadLines(s.RolloutPath)) {
        try {
          var root = Json.Obj(Json.Parser.DeserializeObject(line)); var payload = Json.GetObj(root, "payload"); if (payload == null) continue;
          if (Json.GetString(root, "type") == "session_meta" && string.IsNullOrEmpty(cwd)) cwd = Json.GetString(payload, "cwd") ?? "";
          if (Json.GetString(root, "type") != "response_item" || Json.GetString(payload, "type") != "message") continue;
          var role = Json.GetString(payload, "role"); object contentValue; if (role != "user" && role != "assistant" || !payload.TryGetValue("content", out contentValue)) continue;
          var parts = contentValue as object[]; if (parts == null) continue; var builder = new StringBuilder();
          foreach (var partValue in parts) { var part = Json.Obj(partValue); var kind = Json.GetString(part, "type"); if (kind == "input_text" || kind == "output_text") builder.AppendLine(Json.GetString(part, "text")); }
          if (builder.Length > 0) messages.Add(Tuple.Create(role, Truncate(builder.ToString(), 1600)));
        } catch { }
      }
      if (string.IsNullOrEmpty(cwd)) throw new InvalidOperationException("无法读取项目目录");
      var recent = messages.Skip(Math.Max(0, messages.Count - 12)).ToList(); var latestUser = recent.LastOrDefault(x => x.Item1 == "user");
      var nextName = NextThreadName(s.ThreadName); var markdown = "# Codex 自动交接包\r\n\r\n来源任务：" + s.ThreadName + "\r\n来源 Thread ID：" + s.ThreadId + "\r\n生成时间：" + DateTime.UtcNow.ToString("o") + "\r\n触发依据：真实使用率 " + s.UsedPercent.ToString("0.0") + "% 达到 " + state.AutomaticHandoffThreshold + "% 阈值。\r\n\r\n## 用户目标\r\n\r\n" + (latestUser == null ? "请读取来源任务并继续最后一项要求。" : latestUser.Item2) + "\r\n\r\n## 已完成与进行中\r\n\r\n这是同一项工作的后续任务。先检查工作区、Git 状态和实际文件，再从未完成处继续；不要只回复已收到。\r\n\r\n## 关键文件/路径\r\n\r\n- 项目目录：" + cwd + "\r\n- 来源记录：" + s.RolloutPath + "\r\n\r\n## 禁止事项\r\n\r\n- 不读取 ~/.codex/auth.json。\r\n- 不写 Codex SQLite。\r\n- 保留全部未提交修改。\r\n- 不伪造状态、进度或上下文百分比。\r\n\r\n## 验证结果\r\n\r\n- 上下文：" + s.UsedTokens + " / " + s.ContextWindow + " tokens。\r\n\r\n## 下一步\r\n\r\n1. 读取本交接包。\r\n2. 在项目目录检查现状。\r\n3. 继续来源任务最后一项工作。\r\n\r\n## 最近对话摘录\r\n\r\n" + string.Join("\r\n\r\n", recent.Select(x => "### " + (x.Item1 == "user" ? "用户" : "Codex") + "\r\n" + x.Item2).ToArray());
      Directory.CreateDirectory(Path.Combine(supportDir, "handoffs")); File.WriteAllText(Path.Combine(supportDir, "handoffs", s.ThreadId + "-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + ".md"), markdown, Encoding.UTF8);
      return Tuple.Create(cwd, markdown + "\n\n下一任务名称：" + nextName);
    }

    string CreateNextThread(Snapshot s, string cwd, string handoff) {
      var exe = LocateCodex(); if (exe == null) throw new FileNotFoundException("找不到 Codex 官方本机程序");
      using (var p = new Process()) {
        p.StartInfo = new ProcessStartInfo(exe, "app-server --stdio") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        p.Start(); Request(p, 1, "initialize", new Dictionary<string, object> { { "clientInfo", new Dictionary<string, object> { { "name", "codex-context-meter-native" }, { "version", "1.4" } } } });
        p.StandardInput.WriteLine(Json.Parser.Serialize(new Dictionary<string, object> { { "method", "initialized" }, { "params", new Dictionary<string, object>() } }));
        var startParams = new Dictionary<string, object> { { "cwd", cwd } }; if (!string.IsNullOrEmpty(s.RawModelName)) startParams["model"] = s.RawModelName;
        var start = Json.Obj(Request(p, 2, "thread/start", startParams)); var thread = Json.GetObj(start, "thread"); var id = Json.GetString(thread, "id"); if (string.IsNullOrEmpty(id)) throw new InvalidOperationException("未返回新任务 ID");
        Request(p, 3, "thread/name/set", new Dictionary<string, object> { { "threadId", id }, { "name", NextThreadName(s.ThreadName) } });
        Request(p, 4, "turn/start", new Dictionary<string, object> { { "threadId", id }, { "input", new object[] { new Dictionary<string, object> { { "type", "text" }, { "text", "这是来源任务的同一工作续接。请完整读取交接包，检查项目现状后立即从未完成处继续：\n\n" + handoff } } } } });
        try { p.Kill(); } catch { } return id;
      }
    }

    object Request(Process p, int id, string method, object parameters) {
      p.StandardInput.WriteLine(Json.Parser.Serialize(new Dictionary<string, object> { { "id", id }, { "method", method }, { "params", parameters } })); p.StandardInput.Flush();
      var until = DateTime.UtcNow.AddSeconds(30); while (DateTime.UtcNow < until) { var remaining = until - DateTime.UtcNow; var read = p.StandardOutput.ReadLineAsync(); if (!read.Wait(remaining)) throw new TimeoutException("Codex App Server 请求超时：" + method); var line = read.Result; if (line == null) break; try { var root = Json.Obj(Json.Parser.DeserializeObject(line)); object responseId; if (root != null && root.TryGetValue("id", out responseId) && Convert.ToInt32(responseId) == id) { object error; if (root.TryGetValue("error", out error) && error != null) throw new InvalidOperationException(Json.Parser.Serialize(error)); object result; return root.TryGetValue("result", out result) ? result : new Dictionary<string, object>(); } } catch (InvalidOperationException) { throw; } catch { } } throw new TimeoutException("Codex App Server 请求超时：" + method);
    }

    string LocateCodex() {
      var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); var candidates = new[] { Path.Combine(local, "Programs", "Codex", "resources", "codex.exe"), Path.Combine(local, "Programs", "ChatGPT", "resources", "codex.exe"), Path.Combine(local, "Programs", "Codex", "codex.exe") }; return candidates.FirstOrDefault(File.Exists);
    }
    string NextThreadName(string source) { var clean = source.Trim(); var lastSpace = clean.LastIndexOf(' '); int n; return lastSpace > 0 && int.TryParse(clean.Substring(lastSpace + 1), out n) ? clean.Substring(0, lastSpace + 1) + (n + 1) : clean + " 2"; }
    static string DisplayModel(string raw) { if (raw == null) return null; return CultureInfo.InvariantCulture.TextInfo.ToTitleCase(raw.Replace('-', ' ')); }
    static string Truncate(string value, int limit) { value = (value ?? "").Trim(); return value.Length > limit ? value.Substring(0, limit) + "\n…（摘录已截断）" : value; }

    string StatePath { get { return Path.Combine(supportDir, "state-native.json"); } }
    MeterState LoadState() { try { return Json.Parser.Deserialize<MeterState>(File.ReadAllText(StatePath, Encoding.UTF8)) ?? new MeterState(); } catch { return new MeterState(); } }
    void SaveState() { lock (gate) { Directory.CreateDirectory(supportDir); File.WriteAllText(StatePath, Json.Parser.Serialize(state), Encoding.UTF8); } }
  }

  internal static class Program {
    [STAThread] static void Main() { Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); Application.Run(new MeterApplication()); }
  }
}
