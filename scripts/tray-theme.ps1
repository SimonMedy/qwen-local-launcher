#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('QwenPopupForm' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Drawing.dll','System.Windows.Forms.dll') -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class QwenPopupForm : Form
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public QwenPopupForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(24, 25, 28);
        ForeColor = Color.FromArgb(242, 243, 245);
        DoubleBuffered = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        TopMost = true;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ClassStyle |= 0x00020000;
            return cp;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        try
        {
            int dark = 1;
            DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));
            int corner = 2;
            DwmSetWindowAttribute(Handle, 33, ref corner, sizeof(int));
            int noBorder = unchecked((int)0xFFFFFFFE);
            DwmSetWindowAttribute(Handle, 34, ref noBorder, sizeof(int));
        }
        catch { }
    }
}

public sealed class QwenMenuButton : Control
{
    private bool hovered;
    private bool isChecked;
    private bool showChevron;
    private string secondaryText = "";

    public bool IsChecked { get { return isChecked; } set { isChecked = value; Invalidate(); } }
    public bool ShowChevron { get { return showChevron; } set { showChevron = value; Invalidate(); } }
    public string SecondaryText { get { return secondaryText; } set { secondaryText = value ?? ""; Invalidate(); } }

    public QwenMenuButton()
    {
        Height = 40;
        Cursor = Cursors.Hand;
        BackColor = Color.Transparent;
        ForeColor = Color.FromArgb(242, 243, 245);
        DoubleBuffered = true;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovered = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        if (hovered && Enabled)
        {
            Rectangle r = new Rectangle(0, 1, Width - 1, Height - 2);
            using (GraphicsPath path = Rounded(r, 8))
            using (SolidBrush brush = new SolidBrush(Color.FromArgb(42, 43, 47)))
                e.Graphics.FillPath(brush, path);
        }

        Color primary = Enabled ? ForeColor : Color.FromArgb(100, 104, 112);
        Color secondary = Enabled ? Color.FromArgb(156, 163, 175) : Color.FromArgb(82, 86, 94);
        Rectangle textRect = new Rectangle(12, 0, Math.Max(20, Width - 112), Height);
        TextRenderer.DrawText(e.Graphics, Text, Font, textRect, primary,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);

        if (!String.IsNullOrEmpty(secondaryText))
        {
            Rectangle secondaryRect = new Rectangle(Math.Max(110, Width - 150), 0, 118, Height);
            TextRenderer.DrawText(e.Graphics, secondaryText, Font, secondaryRect, secondary,
                TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis);
        }

        if (showChevron)
        {
            using (Pen pen = new Pen(secondary, 1.8f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                int x = Width - 19;
                int y = Height / 2;
                e.Graphics.DrawLine(pen, x - 3, y - 4, x + 1, y);
                e.Graphics.DrawLine(pen, x + 1, y, x - 3, y + 4);
            }
        }

        if (isChecked)
        {
            using (Pen pen = new Pen(Color.FromArgb(88, 184, 255), 2.0f))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                int x = Width - 23;
                int y = Height / 2;
                e.Graphics.DrawLine(pen, x - 6, y, x - 2, y + 4);
                e.Graphics.DrawLine(pen, x - 2, y + 4, x + 5, y - 5);
            }
        }
    }

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        GraphicsPath path = new GraphicsPath();
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

$script:QwenSurface = [Drawing.Color]::FromArgb(24, 25, 28)
$script:QwenText = [Drawing.Color]::FromArgb(242, 243, 245)
$script:QwenMuted = [Drawing.Color]::FromArgb(156, 163, 175)
$script:QwenDivider = [Drawing.Color]::FromArgb(58, 60, 67)
$script:QwenAccent = [Drawing.Color]::FromArgb(88, 184, 255)
$script:QwenDanger = [Drawing.Color]::FromArgb(242, 102, 116)

function Get-QwenUIFontName {
    try {
        $fonts = New-Object Drawing.Text.InstalledFontCollection
        if ($fonts.Families.Name -contains 'Segoe UI Variable Text') { return 'Segoe UI Variable Text' }
    } catch {}
    return 'Segoe UI'
}

function New-QwenPopupForm {
    $form = New-Object QwenPopupForm
    $form.Width = 360
    $form.BackColor = $script:QwenSurface
    $form.ForeColor = $script:QwenText
    $form.Font = New-Object Drawing.Font((Get-QwenUIFontName), 10)
    return $form
}

function New-QwenPopupLabel {
    param([string]$Text, [float]$Size = 10, [bool]$Bold = $false, [Drawing.Color]$Color = $script:QwenText)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.AutoEllipsis = $true
    $label.UseCompatibleTextRendering = $false
    $label.BackColor = $script:QwenSurface
    $label.ForeColor = $Color
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font((Get-QwenUIFontName), $Size, $style)
    return $label
}

function New-QwenPopupButton {
    param([string]$Text, [string]$SecondaryText = '', [switch]$Chevron)
    $button = New-Object QwenMenuButton
    $button.Text = $Text
    $button.SecondaryText = $SecondaryText
    $button.ShowChevron = $Chevron.IsPresent
    $button.Font = New-Object Drawing.Font((Get-QwenUIFontName), 10)
    return $button
}

function New-QwenPopupDivider {
    $divider = New-Object Windows.Forms.Panel
    $divider.Height = 1
    $divider.BackColor = $script:QwenDivider
    return $divider
}

function Show-QwenPopupAtCursor {
    param([Parameter(Mandatory)][Windows.Forms.Form]$Form)
    $point = [Windows.Forms.Cursor]::Position
    $screen = [Windows.Forms.Screen]::FromPoint($point).WorkingArea
    $x = $point.X - $Form.Width + 14
    $y = $point.Y - $Form.Height - 12
    if ($x -lt $screen.Left + 6) { $x = $screen.Left + 6 }
    if ($x + $Form.Width -gt $screen.Right - 6) { $x = $screen.Right - $Form.Width - 6 }
    if ($y -lt $screen.Top + 6) { $y = [Math]::Min($point.Y + 12, $screen.Bottom - $Form.Height - 6) }
    $Form.Location = New-Object Drawing.Point($x, $y)
    if (-not $Form.Visible) { $Form.Show() }
    $Form.Activate()
}

function Register-QwenTrayTheme {
    # Theme helpers are loaded by tray-bootstrap. The popup is built by tray-app.
}
