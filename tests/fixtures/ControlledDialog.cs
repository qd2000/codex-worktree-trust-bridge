using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;

// Test-only executable. It is deliberately NOT named ChatGPT and has no Codex
// package identity, so the installed bridge cannot select it. Every action is a
// counter in an explicitly supplied isolated fixture directory, never trust.
internal static class ControlledDialog
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static Dictionary<string, object> configuration;
    private static string directory;
    private static Window window;
    private static DialogPanel dialog;
    private static int approved, cancelled, sequence = -1;
    private static string mode = "valid";
    private static string folder;
    private static readonly Stopwatch Lifetime = Stopwatch.StartNew();

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 1) return 64;
        string path = Path.GetFullPath(args[0]);
        directory = Path.GetDirectoryName(path);
        configuration = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
        folder = Convert.ToString(configuration["folder"]);
        int seconds = Convert.ToInt32(configuration["seconds"]);
        int noiseCount = Convert.ToInt32(configuration["noise"]);
        if (seconds < 1 || seconds > 8000 || noiseCount < 0 || noiseCount > 3000) return 64;
        Application application = new Application();
        window = new Window {
            Title = "Trust Bridge controlled acceptance fixture", Width = 600, Height = 460,
            ShowInTaskbar = false, ShowActivated = false, WindowStartupLocation = WindowStartupLocation.Manual,
            Left = 40, Top = 40
        };
        DockPanel content = new DockPanel();
        dialog = new DialogPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(dialog, Dock.Top);
        content.Children.Add(dialog);
        StackPanel noise = new StackPanel();
        for (int i = 0; i < noiseCount; i++) noise.Children.Add(new TextBlock { Text = "Controlled background element " + i });
        content.Children.Add(new ScrollViewer { Content = noise, Height = 100 });
        window.Content = content;
        BuildDialog();
        window.Loaded += delegate { Publish(); };
        DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += delegate {
            if (Lifetime.Elapsed.TotalSeconds >= seconds) { window.Close(); return; }
            string command = Path.Combine(directory, "command.json");
            if (!File.Exists(command)) return;
            try {
                if (new FileInfo(command).Length > 8192) return;
                Dictionary<string, object> input = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(command));
                int requested = Convert.ToInt32(input["sequence"]);
                if (requested <= sequence) return;
                string requestedMode = Convert.ToString(input["mode"]);
                if (Array.IndexOf(new string[] { "valid", "duplicate-trust", "two-paths", "closed", "no-cancel", "disabled-trust" }, requestedMode) < 0) return;
                if (input.ContainsKey("folder")) folder = Convert.ToString(input["folder"]);
                mode = requestedMode;
                sequence = requested;
                BuildDialog();
                Publish();
            } catch (IOException) { } catch (ArgumentException) { }
        };
        timer.Start();
        application.Run(window);
        timer.Stop();
        return 0;
    }

    private static void BuildDialog()
    {
        dialog.Children.Clear();
        dialog.Visibility = mode == "closed" ? Visibility.Collapsed : Visibility.Visible;
        dialog.Children.Add(new TextBlock { Text = "Controlled folder trust prompt", FontSize = 18 });
        ListBox paths = new ListBox { Height = 80 };
        ListBoxItem item = new ListBoxItem { Content = folder };
        AutomationProperties.SetName(item, folder);
        paths.Items.Add(item);
        if (mode == "two-paths") {
            ListBoxItem second = new ListBoxItem { Content = folder + "-ambiguous" };
            AutomationProperties.SetName(second, folder + "-ambiguous");
            paths.Items.Add(second);
        }
        dialog.Children.Add(paths);
        Button trust = new Button { Content = "Trust Folder", Height = 30, IsEnabled = mode != "disabled-trust" };
        AutomationProperties.SetName(trust, "Trust Folder");
        trust.Click += delegate { approved++; Publish(); };
        dialog.Children.Add(trust);
        if (mode == "duplicate-trust") {
            Button duplicate = new Button { Content = "Trust Folder", Height = 30 };
            AutomationProperties.SetName(duplicate, "Trust Folder");
            duplicate.Click += delegate { approved++; Publish(); };
            dialog.Children.Add(duplicate);
        }
        if (mode != "no-cancel") {
            Button cancel = new Button { Content = "Cancel", Height = 30 };
            AutomationProperties.SetName(cancel, "Cancel");
            cancel.Click += delegate { cancelled++; Publish(); };
            dialog.Children.Add(cancel);
        }
    }

    private static void Publish()
    {
        using (Process process = Process.GetCurrentProcess()) {
            Dictionary<string, object> result = new Dictionary<string, object> {
                { "pid", process.Id }, { "createdFileTimeUtc", process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() },
                { "hwnd", new WindowInteropHelper(window).Handle.ToInt64() }, { "executable", process.MainModule.FileName },
                { "approved", approved }, { "cancelled", cancelled }, { "sequence", sequence }, { "mode", mode }
            };
            string output = Path.Combine(directory, "status.json");
            string temporary = output + ".tmp";
            File.WriteAllText(temporary, Json.Serialize(result), new UTF8Encoding(false));
            if (File.Exists(output)) File.Replace(temporary, output, null); else File.Move(temporary, output);
        }
    }

    private sealed class DialogPanel : StackPanel
    {
        protected override AutomationPeer OnCreateAutomationPeer() { return new DialogPeer(this); }
    }
    private sealed class DialogPeer : FrameworkElementAutomationPeer
    {
        internal DialogPeer(DialogPanel owner) : base(owner) { }
        protected override string GetClassNameCore() { return "codex-dialog controlled-fixture"; }
        protected override AutomationControlType GetAutomationControlTypeCore() { return AutomationControlType.Window; }
        protected override bool IsControlElementCore() { return true; }
        protected override bool IsContentElementCore() { return true; }
        protected override List<AutomationPeer> GetChildrenCore()
        {
            List<AutomationPeer> peers = new List<AutomationPeer>();
            foreach (UIElement child in ((DialogPanel)Owner).Children) {
                AutomationPeer peer = UIElementAutomationPeer.CreatePeerForElement(child);
                if (peer != null) peers.Add(peer);
            }
            return peers;
        }
    }
}
