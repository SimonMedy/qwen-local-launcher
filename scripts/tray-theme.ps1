#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('QwenMenuRenderer' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Drawing.dll','System.Windows.Forms.dll') -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class QwenMenuRenderer : ToolStripProfessionalRenderer
{
    private static readonly Color Surface = Color.FromArgb(25, 26, 29);
    private static readonly Color Hover = Color.FromArgb(39, 41, 46);
    private static readonly Color Text = Color.FromArgb(245, 246, 247);
    private static readonly Color Muted = Color.FromArgb(157, 163, 173);
    private static readonly Color Disabled = Color.FromArgb(92, 97, 106);
    private static readonly Color Divider = Color.FromArgb(53, 56, 63);
    private static readonly Color Accent = Color.FromArgb(90, 183, 255);

    public QwenMenuRenderer() : base(new ProfessionalColorTable()) { RoundedEdges = false; }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(Surface); }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var rect = new Rectangle(4, 2, Math.Max(0, e.Item.Width - 8), Math.Max(0, e.Item.Height - 4));
        using (var path = RoundedRect(rect, 7))
        using (var brush = new SolidBrush(Hover)) {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.FillPath(brush, path);
        }
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        using (var pen = new Pen(Divider)) {
            int y = e.Item.Height / 2;
            e.Graphics.DrawLine(pen, 12, y, Math.Max(12, e.Item.Width - 12), y);
        }
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        if (Equals(e.Item.Tag, "qwen-header")) e.TextColor = Text;
        else if (Equals(e.Item.Tag, "qwen-subtle")) e.TextColor = Muted;
        else e.TextColor = e.Item.Enabled ? Text : Disabled;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        e.ArrowColor = e.Item.Enabled ? Muted : Disabled;
        base.OnRenderArrow(e);
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        if (!(e.Item is ToolStripMenuItem) || !((ToolStripMenuItem)e.Item).Checked) return;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int x = Math.Max(8, e.Item.Width - 27);
        int y = e.Item.Height / 2;
        using (var pen = new Pen(Accent, 2.0f)) {
            pen.StartCap = LineCap.Round;
            pen.EndCap = LineCap.Round;
            g.DrawLines(pen, new [] { new Point(x, y), new Point(x + 4, y + 4), new Point(x + 11, y - 4) });
        }
    }

    private static GraphicsPath RoundedRect(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public static class QwenDwmMenu
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    public static void Apply(IntPtr hwnd, int borderColorRef)
    {
        if (hwnd == IntPtr.Zero) return;
        try {
            int corner = 2; // DWMWCP_ROUND
            DwmSetWindowAttribute(hwnd, 33, ref corner, sizeof(int));
            int border = borderColorRef;
            DwmSetWindowAttribute(hwnd, 34, ref border, sizeof(int));
        } catch { }
    }
}
"@
}

$script:QwenMenuRenderer = New-Object QwenMenuRenderer
$script:QwenSurface = [System.Drawing.Color]::FromArgb(25, 26, 29)
$script:QwenText = [System.Drawing.Color]::FromArgb(245, 246, 247)
$script:QwenBorderColorRef = (58 -bor (60 -shl 8) -bor (67 -shl 16))

function Set-QwenDropDownTheme {
    param([Parameter(Mandatory)][System.Windows.Forms.ToolStripDropDown]$DropDown)

    $DropDown.Renderer = $script:QwenMenuRenderer
    $DropDown.BackColor = $script:QwenSurface
    $DropDown.ForeColor = $script:QwenText
    $DropDown.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 6)
    $DropDown.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    if ($DropDown -is [System.Windows.Forms.ToolStripDropDownMenu]) {
        $DropDown.ShowImageMargin = $false
        $DropDown.ShowCheckMargin = $false
    }

    foreach ($item in $DropDown.Items) {
        if ($item -is [System.Windows.Forms.ToolStripSeparator]) {
            $item.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
            continue
        }
        $item.Padding = New-Object System.Windows.Forms.Padding(10, 6, 28, 6)
        if ($item -is [System.Windows.Forms.ToolStripMenuItem]) {
            $item.DropDown.Renderer = $script:QwenMenuRenderer
            $item.add_DropDownOpening({ Set-QwenDropDownTheme -DropDown $this.DropDown })
            $item.add_DropDownOpened({
                Set-QwenDropDownTheme -DropDown $this.DropDown
                [QwenDwmMenu]::Apply($this.DropDown.Handle, $script:QwenBorderColorRef)
            })
        }
    }
}

function Set-QwenMenuTheme {
    param([Parameter(Mandatory)][System.Windows.Forms.ContextMenuStrip]$Menu)

    $Menu.Renderer = $script:QwenMenuRenderer
    $Menu.BackColor = $script:QwenSurface
    $Menu.ForeColor = $script:QwenText
    $Menu.ShowImageMargin = $false
    $Menu.ShowCheckMargin = $false
    $Menu.ShowItemToolTips = $true
    $Menu.DropShadowEnabled = $true
    $Menu.Padding = New-Object System.Windows.Forms.Padding(7, 7, 7, 7)
    $Menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $Menu.MinimumSize = New-Object System.Drawing.Size(320, 0)

    if ($Menu.Items.Count -gt 0) {
        $Menu.Items[0].Tag = 'qwen-header'
        $Menu.Items[0].Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
        $Menu.Items[0].Padding = New-Object System.Windows.Forms.Padding(10, 7, 20, 4)
    }
    if ($Menu.Items.Count -gt 1 -and -not ($Menu.Items[1] -is [System.Windows.Forms.ToolStripSeparator])) {
        $Menu.Items[1].Tag = 'qwen-subtle'
        $Menu.Items[1].Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $Menu.Items[1].Padding = New-Object System.Windows.Forms.Padding(10, 1, 20, 7)
    }

    Set-QwenDropDownTheme -DropDown $Menu

    $startup = $Menu.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and $_.Text -match '^(Start with Windows|Launch at Windows startup)' } | Select-Object -First 1
    if ($startup) { $startup.ToolTipText = 'Launches only the tray app when you sign in. It does not start the model.' }

    $Menu.add_Opening({
        Set-QwenDropDownTheme -DropDown $this
        $startupItem = $this.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and $_.Text -match '^(Start with Windows|Launch at Windows startup)' } | Select-Object -First 1
        if ($startupItem) { $startupItem.Text = if ($startupItem.Checked) { 'Launch at Windows startup  ✓' } else { 'Launch at Windows startup' } }
    })
    $Menu.add_Opened({ [QwenDwmMenu]::Apply($this.Handle, $script:QwenBorderColorRef) })
}

function Register-QwenTrayTheme {
    $script:QwenThemeApplied = $false
    $handler = [System.EventHandler]{
        if ($script:QwenThemeApplied) { return }
        $menuVar = Get-Variable -Name Menu -Scope Script -ErrorAction SilentlyContinue
        if ($menuVar -and $menuVar.Value -is [System.Windows.Forms.ContextMenuStrip]) {
            Set-QwenMenuTheme -Menu $menuVar.Value
            $script:QwenThemeApplied = $true
        }
    }
    [System.Windows.Forms.Application]::add_Idle($handler)
}
