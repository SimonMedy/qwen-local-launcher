#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('QwenMenuRenderer' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Drawing.dll','System.Windows.Forms.dll') -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public sealed class QwenMenuRenderer : ToolStripProfessionalRenderer
{
    private static readonly Color Surface = Color.FromArgb(31, 32, 35);
    private static readonly Color Hover = Color.FromArgb(43, 45, 49);
    private static readonly Color Text = Color.FromArgb(242, 243, 245);
    private static readonly Color Muted = Color.FromArgb(181, 186, 193);
    private static readonly Color Divider = Color.FromArgb(64, 66, 73);

    public QwenMenuRenderer() : base(new ProfessionalColorTable())
    {
        RoundedEdges = false;
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(Surface); }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        var rect = new Rectangle(5, 2, Math.Max(0, e.Item.Width - 10), Math.Max(0, e.Item.Height - 4));
        using (var path = RoundedRect(rect, 6))
        using (var brush = new SolidBrush(Hover))
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.FillPath(brush, path);
        }
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        using (var pen = new Pen(Divider))
        {
            int y = e.Item.Height / 2;
            e.Graphics.DrawLine(pen, 10, y, Math.Max(10, e.Item.Width - 10), y);
        }
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        if (Equals(e.Item.Tag, "qwen-header")) e.TextColor = Text;
        else if (Equals(e.Item.Tag, "qwen-subtle")) e.TextColor = Muted;
        else e.TextColor = e.Item.Enabled ? Text : Color.FromArgb(114, 118, 125);
        base.OnRenderItemText(e);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        e.ArrowColor = e.Item.Enabled ? Text : Color.FromArgb(114, 118, 125);
        base.OnRenderArrow(e);
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
"@
}

function Set-QwenRoundedRegion {
    param([Parameter(Mandatory)][System.Windows.Forms.ContextMenuStrip]$Menu)
    if ($Menu.Width -lt 2 -or $Menu.Height -lt 2) { return }
    $radius = 12; $d = $radius * 2; $w = $Menu.Width; $h = $Menu.Height
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
        $path.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
        $path.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
        $path.CloseFigure()
        if ($Menu.Region) { $Menu.Region.Dispose() }
        $Menu.Region = New-Object System.Drawing.Region($path)
    } finally { $path.Dispose() }
}

function Set-QwenMenuTheme {
    param([Parameter(Mandatory)][System.Windows.Forms.ContextMenuStrip]$Menu)
    $Menu.Renderer = New-Object QwenMenuRenderer
    $Menu.BackColor = [System.Drawing.Color]::FromArgb(31, 32, 35)
    $Menu.ForeColor = [System.Drawing.Color]::FromArgb(242, 243, 245)
    $Menu.ShowImageMargin = $false
    $Menu.ShowCheckMargin = $false
    $Menu.ShowItemToolTips = $true
    $Menu.DropShadowEnabled = $true
    $Menu.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
    $Menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $Menu.MinimumSize = New-Object System.Drawing.Size(300, 0)

    if ($Menu.Items.Count -gt 0) {
        $Menu.Items[0].Tag = 'qwen-header'
        $Menu.Items[0].Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
        $Menu.Items[0].Padding = New-Object System.Windows.Forms.Padding(10, 7, 10, 5)
    }
    if ($Menu.Items.Count -gt 1 -and -not ($Menu.Items[1] -is [System.Windows.Forms.ToolStripSeparator])) {
        $Menu.Items[1].Tag = 'qwen-subtle'
        $Menu.Items[1].Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $Menu.Items[1].Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 7)
    }
    foreach ($item in $Menu.Items) {
        if ($item -is [System.Windows.Forms.ToolStripSeparator]) { $item.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 5); continue }
        if (-not $item.Tag) { $item.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6) }
        if ($item -is [System.Windows.Forms.ToolStripMenuItem] -and $item.HasDropDownItems) {
            $item.DropDown.Renderer = $Menu.Renderer
            $item.DropDown.BackColor = $Menu.BackColor
            $item.DropDown.ForeColor = $Menu.ForeColor
            $item.DropDown.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
            $item.DropDown.Font = $Menu.Font
            foreach ($sub in $item.DropDownItems) { if ($sub -isnot [System.Windows.Forms.ToolStripSeparator]) { $sub.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6) } }
        }
    }

    $startup = $Menu.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and $_.Text -in @('Start with Windows','Launch at Windows startup','Launch at Windows startup  ✓') } | Select-Object -First 1
    if ($startup) { $startup.ToolTipText = 'Launches the tray app when you sign in to Windows. It does not start the model automatically.' }
    $change = $Menu.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and $_.Text -eq 'Change llama.cpp...' } | Select-Object -First 1
    if ($change) { $change.ToolTipText = 'Switch llama-server.exe without editing config files.' }

    $Menu.add_Opening({
        $startupItem = $this.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripMenuItem] -and $_.Text -match '^(Start with Windows|Launch at Windows startup)' } | Select-Object -First 1
        if ($startupItem) { $startupItem.Text = if ($startupItem.Checked) { 'Launch at Windows startup  ✓' } else { 'Launch at Windows startup' } }
        Set-QwenRoundedRegion -Menu $this
    })
    $Menu.add_SizeChanged({ Set-QwenRoundedRegion -Menu $this })
    Set-QwenRoundedRegion -Menu $Menu
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
