using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using CodexTrustBridge;

// UIA objects never leave this MTA thread, enter the protocol, or survive a
// request. There are no event subscriptions or cross-thread AutomationElements.
// The external owner enforces the hard timeout and job memory budget, including
// a provider call that never returns. This is containment, not a leak diagnosis.
internal static class UiWorker
{
    private const int MaximumRoots = 16;
    private const int MaximumWindows = 128;
    private const int MaximumControls = 96;
    private const int MaximumDepth = 24;
    private const int MaximumCandidates = 16;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = Frames.MaximumBytes, RecursionLimit = 16 };
    private static readonly Dictionary<string, Proposal> Tokens = new Dictionary<string, Proposal>(StringComparer.Ordinal);
    private static readonly TreeWalker WindowWalker = new TreeWalker(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
    private static readonly TreeWalker DialogWalker = new TreeWalker(new OrCondition(
        // Keep the boundary itself in the filtered view. Without Window here,
        // GetNextSibling can normalize past the excluded dialog into other UI.
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window),
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem),
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)));
    private static long scanCount;
    private static long invocationCount;
    private static int sessionId;

    [MTAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 1 || args[0].Length > 128 || !args[0].StartsWith("CodexTrustBridge-", StringComparison.Ordinal)) return 64;
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.MTA) return 70;
        using (Process self = Process.GetCurrentProcess()) sessionId = self.SessionId;
        try
        {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", args[0], PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                pipe.Connect(10000);
                while (true)
                {
                    string frame = Frames.ReadAsync(pipe).GetAwaiter().GetResult();
                    Request request = Json.Deserialize<Request>(frame);
                    if (request == null || request.version != 1 || String.IsNullOrEmpty(request.id) || request.id.Length > 64)
                        throw new InvalidDataException("Invalid request envelope.");
                    Dictionary<string, object> response = new Dictionary<string, object>();
                    response["version"] = 1;
                    response["id"] = request.id;
                    response["ok"] = false;
                    try
                    {
                        if (request.operation == "scan")
                        {
                            Tokens.Clear();
                            int visited;
                            List<string> seen;
                            List<Rejection> rejections;
                            List<Proposal> proposals = Scan(request.roots, out visited, out seen, out rejections);
                            foreach (Proposal proposal in proposals) Tokens.Add(proposal.token, proposal);
                            response["candidates"] = proposals;
                            response["seenDialogs"] = seen;
                            response["rejectedDialogs"] = rejections;
                            response["visited"] = visited;
                            response["scanCount"] = ++scanCount;
                            response["ok"] = true;
                        }
                        else if (request.operation == "validate" || request.operation == "invoke")
                        {
                            Proposal proposal;
                            if (String.IsNullOrEmpty(request.token) || !Tokens.TryGetValue(request.token, out proposal))
                                throw new InvalidOperationException("Unknown or consumed action token.");
                            if (Stopwatch.GetTimestamp() - proposal.issuedTicks > Stopwatch.Frequency * 10L)
                            {
                                Tokens.Remove(request.token);
                                throw new InvalidOperationException("Expired action token.");
                            }
                            if (request.operation == "invoke")
                            {
                                // Consume before the first provider action. A failed Invoke is
                                // outcome-uncertain and is never blindly retried by this worker.
                                Tokens.Remove(request.token);
                                if (request.action != "approve" && request.action != "cancel")
                                    throw new InvalidDataException("Unknown dialog action.");
                            }
                            using (Process owner = VerifyRoot(proposal.root))
                            {
                                AutomationElement root = AutomationElement.FromHandle(new IntPtr(proposal.root.hwnd));
                                AutomationElement dialog = FindDialog(root, proposal.dialogId);
                                if (dialog == null) throw new ElementNotAvailableException("Dialog was closed or replaced.");
                                DialogShape shape = ReadShape(dialog, proposal.root);
                                if (shape.Fingerprint != proposal.fingerprint || shape.Folder != proposal.folder)
                                    throw new InvalidOperationException("Dialog changed since observation.");
                                if (request.operation == "invoke")
                                {
                                    InvokePattern pattern = request.action == "approve" ? shape.TrustInvoke : shape.CancelInvoke;
                                    // Refresh both controls and the path immediately before the
                                    // action. UIA itself cannot make UI changes transactional.
                                    DialogShape finalShape = ReadShape(dialog, proposal.root);
                                    if (finalShape.Fingerprint != proposal.fingerprint)
                                        throw new InvalidOperationException("Dialog changed before invocation.");
                                    pattern = request.action == "approve" ? finalShape.TrustInvoke : finalShape.CancelInvoke;
                                    pattern.Invoke();
                                    invocationCount++;
                                }
                            }
                            response["ok"] = true;
                            response["token"] = request.token;
                            response["action"] = request.action;
                            response["invocationCount"] = invocationCount;
                        }
                        else if (request.operation == "shutdown")
                        {
                            Tokens.Clear();
                            response["ok"] = true;
                            Frames.WriteAsync(pipe, Json.Serialize(response)).GetAwaiter().GetResult();
                            return 0;
                        }
                        else throw new InvalidDataException("Unknown operation.");
                    }
                    catch (Exception error)
                    {
                        response["error"] = error.GetType().Name + ": " + Short(error.Message, 512);
                        if (request.operation == "scan") Tokens.Clear();
                    }
                    response["managedHeapBytes"] = GC.GetTotalMemory(false);
                    response["gen0Collections"] = GC.CollectionCount(0);
                    response["gen1Collections"] = GC.CollectionCount(1);
                    response["gen2Collections"] = GC.CollectionCount(2);
                    response["apartment"] = "MTA";
                    response["cachedTokens"] = Tokens.Count;
                    Frames.WriteAsync(pipe, Json.Serialize(response)).GetAwaiter().GetResult();
                }
            }
        }
        catch (EndOfStreamException) { return 0; }
        catch { return 70; }
    }

    private static List<Proposal> Scan(RootDescriptor[] roots, out int visited, out List<string> seen, out List<Rejection> rejections)
    {
        visited = 0;
        seen = new List<string>();
        rejections = new List<Rejection>();
        if (roots == null || roots.Length > MaximumRoots) throw new InvalidDataException("Root count rejected.");
        List<Proposal> proposals = new List<Proposal>();
        foreach (RootDescriptor descriptor in roots)
        {
            using (Process process = VerifyRoot(descriptor))
            {
                AutomationElement root = AutomationElement.FromHandle(new IntPtr(descriptor.hwnd));
                int count = 0;
                foreach (AutomationElement window in Windows(root))
                {
                    count++;
                    if (!IsDialog(window)) continue;
                    string dialogId = Identity(window);
                    string dialogKey = descriptor.pid + "|" + descriptor.createdFileTimeUtc + "|" + dialogId;
                    if (seen.Count == 64) throw new InvalidDataException("Visible-dialog budget exceeded.");
                    seen.Add(dialogKey);
                    DialogShape shape;
                    try { shape = ReadShape(window, descriptor); }
                    catch (ElementNotAvailableException error) {
                        rejections.Add(new Rejection { dialogKey = dialogKey, reason = Short(error.Message, 512) });
                        continue;
                    }
                    catch (InvalidOperationException error) {
                        rejections.Add(new Rejection { dialogKey = dialogKey, reason = Short(error.Message, 512) });
                        continue; // Ambiguous dialogs never propose trust.
                    }
                    if (proposals.Count == MaximumCandidates) throw new InvalidDataException("Candidate budget exceeded.");
                    proposals.Add(new Proposal {
                        token = Guid.NewGuid().ToString("N"), root = descriptor, folder = shape.Folder,
                        dialogId = dialogId, dialogKey = dialogKey,
                        fingerprint = shape.Fingerprint, issuedTicks = Stopwatch.GetTimestamp()
                    });
                }
                visited += count;
            }
        }
        return proposals;
    }

    private static AutomationElement FindDialog(AutomationElement root, string identity)
    {
        AutomationElement result = null;
        foreach (AutomationElement window in Windows(root))
        {
            if (!IsDialog(window) || Identity(window) != identity) continue;
            if (result != null) throw new InvalidOperationException("Duplicate dialog identity.");
            result = window;
        }
        return result;
    }

    private static bool IsDialog(AutomationElement element)
    {
        AutomationElement.AutomationElementInformation current = element.Current;
        return current.ControlType == ControlType.Window && !current.IsOffscreen &&
            current.ClassName.IndexOf("codex-dialog", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static IEnumerable<AutomationElement> Windows(AutomationElement root)
    {
        if (IsDialog(root)) yield return root;
        foreach (AutomationElement window in Walk(root, WindowWalker, MaximumWindows, MaximumDepth)) yield return window;
    }

    private static IEnumerable<AutomationElement> Walk(AutomationElement root, TreeWalker walker, int maximum, int maximumDepth)
    {
        // A filtered view skips unrelated UIA controls at the provider boundary.
        // No FindAll(TrueCondition), materialized whole subtree, or element cache.
        if (root.FindFirst(TreeScope.Element, walker.Condition) == null)
            throw new InvalidDataException("UIA subtree boundary is excluded from its filtered view.");
        string rootIdentity = Identity(root);
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        Stack<Tuple<AutomationElement, int>> pending = new Stack<Tuple<AutomationElement, int>>();
        AutomationElement first = walker.GetFirstChild(root);
        if (first != null) pending.Push(Tuple.Create(first, 1));
        int count = 0;
        while (pending.Count != 0)
        {
            Tuple<AutomationElement, int> item = pending.Pop();
            if (++count > maximum || item.Item2 > maximumDepth)
                throw new InvalidDataException("UIA traversal budget exceeded.");
            string identity = Identity(item.Item1);
            if (identity == rootIdentity || !seen.Add(identity)) throw new InvalidDataException("Cyclic UIA provider traversal.");
            AutomationElement ancestor = item.Item1;
            bool contained = false;
            for (int hop = 0; hop < 64; hop++)
            {
                ancestor = TreeWalker.ControlViewWalker.GetParent(ancestor);
                if (ancestor == null) break;
                if (Identity(ancestor) == rootIdentity) { contained = true; break; }
            }
            if (!contained) throw new InvalidDataException("UIA provider traversal escaped the requested subtree.");
            yield return item.Item1;
            AutomationElement sibling = walker.GetNextSibling(item.Item1);
            if (sibling != null) pending.Push(Tuple.Create(sibling, item.Item2));
            // A nested dialog has its own independently validated path/buttons.
            // Never borrow those controls to authorize its parent dialog.
            AutomationElement child = Object.ReferenceEquals(walker, DialogWalker) &&
                item.Item1.Current.ControlType == ControlType.Window ? null : walker.GetFirstChild(item.Item1);
            if (child != null) pending.Push(Tuple.Create(child, item.Item2 + 1));
        }
    }

    private static DialogShape ReadShape(AutomationElement dialog, RootDescriptor root)
    {
        if (!IsDialog(dialog)) throw new InvalidOperationException("Not a visible Codex dialog.");
        List<AutomationElement> buttons = new List<AutomationElement>();
        List<string> paths = new List<string>();
        foreach (AutomationElement element in Walk(dialog, DialogWalker, MaximumControls, MaximumDepth))
        {
            AutomationElement.AutomationElementInformation current = element.Current;
            if (current.IsOffscreen) continue;
            if (current.ControlType == ControlType.ListItem)
            {
                string value = current.Name;
                if (value.Length > 32760) throw new InvalidOperationException("Folder display too long.");
                if (IsAbsoluteWindowsPath(value))
                {
                    string full = Path.GetFullPath(value);
                    if (full.Length > Path.GetPathRoot(full).Length) full = full.TrimEnd('\\', '/');
                    paths.Add(full.ToLowerInvariant());
                }
            }
            if (current.ControlType == ControlType.Button && current.IsEnabled) buttons.Add(element);
        }
        if (paths.Count != 1 || buttons.Count < 2) throw new InvalidOperationException("Ambiguous folder or button set.");
        AutomationElement trust = UniqueButton(buttons, new string[] { "信任文件夹", "Trust Folder", "Trust this folder" }, "bg-primary-solid");
        AutomationElement cancel = UniqueButton(buttons, new string[] { "取消", "Cancel" }, "bg-transparent");
        string trustId = Identity(trust), cancelId = Identity(cancel);
        if (trustId == cancelId) throw new InvalidOperationException("Trust and Cancel are identical.");
        object trustPattern, cancelPattern;
        if (!trust.TryGetCurrentPattern(InvokePattern.Pattern, out trustPattern) ||
            !cancel.TryGetCurrentPattern(InvokePattern.Pattern, out cancelPattern))
            throw new InvalidOperationException("Dialog controls do not support invocation.");
        // The descriptor's HWND/process/birth has already been checked against the
        // kernel. Providers may expose descendants using a different renderer PID;
        // identity remains anchored to the verified window and its live subtree.
        string fingerprint = Hash(Identity(dialog) + "\n" + paths[0] + "\n" + trustId + "\n" + cancelId +
            "\n" + trust.Current.Name + "\n" + cancel.Current.Name + "\n" + trust.Current.ClassName + "\n" + cancel.Current.ClassName);
        return new DialogShape { Folder = paths[0], Fingerprint = fingerprint,
            TrustInvoke = (InvokePattern)trustPattern, CancelInvoke = (InvokePattern)cancelPattern };
    }

    private static AutomationElement UniqueButton(List<AutomationElement> buttons, string[] names, string token)
    {
        List<AutomationElement> named = new List<AutomationElement>();
        foreach (AutomationElement button in buttons)
            if (Array.IndexOf(names, button.Current.Name) >= 0) named.Add(button);
        if (named.Count > 1) throw new InvalidOperationException("Duplicate named buttons.");
        if (named.Count == 1) return named[0];
        List<AutomationElement> classes = new List<AutomationElement>();
        foreach (AutomationElement button in buttons)
        {
            string[] tokens = button.Current.ClassName.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            if (Array.IndexOf(tokens, token) >= 0) classes.Add(button);
        }
        if (classes.Count != 1) throw new InvalidOperationException("Missing or ambiguous role button.");
        return classes[0];
    }

    private static Process VerifyRoot(RootDescriptor root)
    {
        if (root == null || root.pid <= 0 || root.hwnd == 0 || String.IsNullOrEmpty(root.executable) || root.executable.Length > 32760)
            throw new InvalidDataException("Invalid root identity.");
        long expectedCreation;
        if (!Int64.TryParse(root.createdFileTimeUtc, out expectedCreation)) throw new InvalidDataException("Invalid birth identity.");
        Process process = Process.GetProcessById(root.pid);
        try
        {
            if (process.StartTime.ToUniversalTime().ToFileTimeUtc() != expectedCreation ||
                process.SessionId != sessionId ||
                !String.Equals(process.MainModule.FileName, root.executable, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Root process identity changed.");
            uint pid;
            if (!IsWindow(new IntPtr(root.hwnd)) || GetWindowThreadProcessId(new IntPtr(root.hwnd), out pid) == 0 || pid != root.pid)
                throw new InvalidOperationException("Window no longer belongs to the expected process.");
            return process;
        }
        catch { process.Dispose(); throw; }
    }

    private static bool IsAbsoluteWindowsPath(string value)
    {
        return !String.IsNullOrWhiteSpace(value) &&
            ((value.Length >= 3 && Char.IsLetter(value[0]) && value[1] == ':' && (value[2] == '\\' || value[2] == '/')) ||
             value.StartsWith("\\\\", StringComparison.Ordinal));
    }

    private static string Identity(AutomationElement element)
    {
        int[] ids = element.GetRuntimeId();
        if (ids == null || ids.Length == 0 || ids.Length > 64) throw new InvalidOperationException("No reliable UIA runtime identity.");
        return String.Join(".", ids);
    }

    private static string Hash(string text)
    {
        using (SHA256 hash = SHA256.Create())
            return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", "").ToLowerInvariant();
    }
    private static string Short(string text, int length) { return text.Length <= length ? text : text.Substring(0, length); }

    public sealed class RootDescriptor
    { public int pid { get; set; } public string createdFileTimeUtc { get; set; } public long hwnd { get; set; } public string executable { get; set; } }
    public sealed class Request
    { public int version { get; set; } public string id { get; set; } public string operation { get; set; } public RootDescriptor[] roots { get; set; } public string token { get; set; } public string action { get; set; } }
    public sealed class Proposal
    {
        public string token { get; set; } public RootDescriptor root { get; set; } public string folder { get; set; }
        public string dialogId { get; set; } public string dialogKey { get; set; } public string fingerprint { get; set; }
        [ScriptIgnore] public long issuedTicks { get; set; }
    }
    public sealed class Rejection
    { public string dialogKey { get; set; } public string reason { get; set; } }
    private sealed class DialogShape
    { internal string Folder, Fingerprint; internal InvokePattern TrustInvoke, CancelInvoke; }

    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
}
