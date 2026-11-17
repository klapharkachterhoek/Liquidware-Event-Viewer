#Requires -Version 5.1
<#
    Liquidware Event Viewer
    -----------------------
    Haalt eventlogs op van een of meer servers en toont de events van de
    gekozen bronnen (standaard de Liquidware-bronnen) in een overzicht.
    Doel: zien welke applicaties door Liquidware (whitelisting/blacklisting)
    worden tegengehouden.

    Servers, bronnen en standaardinstellingen staan in
    LiquidwareEventViewer.json (in dezelfde map als dit script).

    Starten:  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\LiquidwareEventViewer.ps1
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------------------
# Configuratie (JSON)
# ---------------------------------------------------------------------------
$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ConfigPath = Join-Path $ScriptDir 'LiquidwareEventViewer.json'
$AllLabel   = '(alle)'

function Get-DefaultConfig {
    [pscustomobject]@{
        Servers   = @()
        Sources   = @(
            'liquidware application restriction',
            'Liquidware data service',
            'Liquidware Events and Metrics Service'
        )
        HoursBack = 24
        MaxEvents = 500
        DarkMode  = $false
        ProfileUnityConfigs      = @()
        ActiveProfileUnityConfig = ''
    }
}

function Save-Config($Cfg) {
    $obj = [ordered]@{
        Servers   = @($Cfg.Servers)
        Sources   = @($Cfg.Sources)
        HoursBack = [int]$Cfg.HoursBack
        MaxEvents = [int]$Cfg.MaxEvents
        DarkMode  = [bool]$Cfg.DarkMode
        ProfileUnityConfigs      = @($Cfg.ProfileUnityConfigs)
        ActiveProfileUnityConfig = [string]$Cfg.ActiveProfileUnityConfig
    }
    $obj | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Read-Config {
    if (Test-Path $ConfigPath) {
        try {
            $c = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $hours = 24;  if ($c.HoursBack) { $hours = [int]$c.HoursBack }
            $max   = 500; if ($c.MaxEvents) { $max   = [int]$c.MaxEvents }
            return [pscustomobject]@{
                Servers   = @($c.Servers | Where-Object { $_ })
                Sources   = @($c.Sources | Where-Object { $_ })
                HoursBack = $hours
                MaxEvents = $max
                DarkMode  = [bool]$c.DarkMode
                ProfileUnityConfigs      = @($c.ProfileUnityConfigs | Where-Object { $_ })
                ActiveProfileUnityConfig = [string]$c.ActiveProfileUnityConfig
            }
        } catch {
            [System.Windows.MessageBox]::Show(
                "Het configuratiebestand kon niet worden gelezen:`n$ConfigPath`n`n$($_.Exception.Message)`n`nDe standaardconfiguratie wordt gebruikt.",
                'Configuratie', 'OK', 'Warning') | Out-Null
            return Get-DefaultConfig
        }
    }
    $cfg = Get-DefaultConfig
    Save-Config $cfg
    return $cfg
}

$script:Config = Read-Config

# ---------------------------------------------------------------------------
# Hulpfuncties
# ---------------------------------------------------------------------------
function Get-AppFromMessage([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    # Volledig pad (C:\... of \\server\...) naar een uitvoerbaar bestand
    $m = [regex]::Match($Text, '(?i)(?:[a-z]:\\|\\\\)[^\r\n"<>|*?]*?\.(?:exe|com|bat|cmd|ps1|vbs|js|msi|dll)\b')
    if ($m.Success) { return $m.Value }
    # Alleen een bestandsnaam
    $m = [regex]::Match($Text, '(?i)\b[\w\-.]+\.(?:exe|com|bat|cmd|ps1|vbs|msi)\b')
    if ($m.Success) { return $m.Value }
    return ''
}

function Get-FirstLine([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $line = ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Length -gt 250) { $line = $line.Substring(0, 250) + '...' }
    return $line.Trim()
}

function New-Xaml([string]$Xaml) {
    [xml]$x = $Xaml
    $reader = New-Object System.Xml.XmlNodeReader $x
    return [Windows.Markup.XamlReader]::Load($reader)
}

# ---------------------------------------------------------------------------
# ProfileUnity-configuratie (Application Restrictions)
# ---------------------------------------------------------------------------
# ProfileUnity-export: Configurations[].ApplicationRestrictions[]
#   Action: 0 = Allow (whitelist), 1 = Deny (blacklist)
#   Match : 0 = Contains, 1 = Equals, 2 = Hash, 3 = Starts With, 4 = Ends With, 5 = Signed
$PuMatchNames = @{ 0 = 'Contains'; 1 = 'Equals'; 2 = 'Hash'; 3 = 'Starts With'; 4 = 'Ends With'; 5 = 'Signed' }

$script:PuRules    = @()
$script:PuHasAllow = $false
$script:PuHasSignedAllow = $false
$script:PuCache    = @{}
$script:PuInfo     = ''

function Get-DictValue($Dict, [string]$Key) {
    if ($null -eq $Dict) { return $null }
    if ($Dict -is [System.Collections.IDictionary]) {
        if ($Dict.ContainsKey($Key)) { return $Dict[$Key] }
        return $null
    }
    return $Dict.$Key
}

function ConvertTo-PuNormPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"').Trim()
    $p = [Environment]::ExpandEnvironmentVariables($p)
    $p = $p -replace '/', '\'
    $p = $p -replace '^\\\\\?\\', ''
    return $p.ToLowerInvariant()
}

function Get-LeafName([string]$Path) {
    $i = $Path.LastIndexOf('\')
    if ($i -ge 0) { return $Path.Substring($i + 1) }
    return $Path
}

function Import-PuConfig([string]$Path) {
    $script:PuRules    = @()
    $script:PuHasAllow = $false
    $script:PuHasSignedAllow = $false
    $script:PuCache    = @{}
    $script:PuInfo     = ''
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        $script:PuInfo = 'Bestand niet gevonden'
        return
    }
    try {
        # JavaScriptSerializer i.p.v. ConvertFrom-Json: sneller en geen limiet bij grote exports
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $root = $ser.DeserializeObject((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
    } catch {
        $script:PuInfo = 'Kon bestand niet lezen'
        [System.Windows.MessageBox]::Show("ProfileUnity-configuratie kon niet worden gelezen:`n$Path`n`n$($_.Exception.Message)",
            'ProfileUnity-configuratie', 'OK', 'Warning') | Out-Null
        return
    }

    $configs = @(Get-DictValue $root 'Configurations')
    if ($configs.Count -eq 0 -or $null -eq $configs[0]) {
        if ($null -ne (Get-DictValue $root 'ApplicationRestrictions')) { $configs = @($root) } else { $configs = @() }
    }

    $rules = New-Object System.Collections.Generic.List[object]
    foreach ($cfg in $configs) {
        $cfgName = [string](Get-DictValue $cfg 'Name')
        foreach ($r in @(Get-DictValue $cfg 'ApplicationRestrictions')) {
            if ($null -eq $r) { continue }
            $filter     = Get-DictValue $r 'Filter'
            $filterName = ''
            if ($filter) { $filterName = [string](Get-DictValue $filter 'Name') }
            $match = [int](Get-DictValue $r 'Match')
            $value = [string](Get-DictValue $r 'Value')
            $rule = [pscustomobject]@{
                Sequence    = [int](Get-DictValue $r 'Sequence')
                Action      = [int](Get-DictValue $r 'Action')
                Match       = $match
                Value       = $value
                Norm        = $(if ($match -eq 5 -or $match -eq 2) { $value.Trim().ToLowerInvariant() } else { ConvertTo-PuNormPath $value })
                Description = [string](Get-DictValue $r 'Description')
                Disabled    = [bool](Get-DictValue $r 'Disabled')
                Filter      = $filterName
                Config      = $cfgName
            }
            $rules.Add($rule)
            if ($rule.Action -eq 0 -and -not $rule.Disabled) {
                $script:PuHasAllow = $true
                if ($rule.Match -eq 5 -or $rule.Match -eq 2) { $script:PuHasSignedAllow = $true }
            }
        }
    }
    $script:PuRules = @($rules | Sort-Object Config, Sequence)
    $active = @($script:PuRules | Where-Object { -not $_.Disabled })
    $allow  = @($active | Where-Object { $_.Action -eq 0 }).Count
    $deny   = @($active | Where-Object { $_.Action -eq 1 }).Count
    $script:PuInfo = "$($script:PuRules.Count) regels ($allow allow, $deny deny actief, $($script:PuRules.Count - $active.Count) uitgeschakeld)"
    if ($script:PuHasAllow) { $script:PuInfo += '  |  whitelist-modus: alles wat niet is toegestaan wordt geweigerd' }
}

function Format-PuRule($Rule) {
    $act = if ($Rule.Action -eq 0) { 'Allow' } else { 'Deny' }
    $txt = "#$($Rule.Sequence) $act $($PuMatchNames[$Rule.Match]) '$($Rule.Value)'"
    if ($Rule.Filter)   { $txt += " [filter: $($Rule.Filter)]" }
    if ($Rule.Disabled) { $txt += ' [uitgeschakeld]' }
    return $txt
}

function Get-PuStatus([string]$App) {
    if ($script:PuRules.Count -eq 0) { return @{ Lijst = ''; Regel = '' } }
    if ([string]::IsNullOrWhiteSpace($App)) { return @{ Lijst = 'Geen applicatie herkend'; Regel = '' } }

    $key = $App.ToLowerInvariant()
    if ($script:PuCache.ContainsKey($key)) { return $script:PuCache[$key] }

    $a        = ConvertTo-PuNormPath $App
    $nameOnly = -not $a.Contains('\')
    $leaf     = Get-LeafName $a
    $hits = New-Object System.Collections.Generic.List[object]

    foreach ($r in $script:PuRules) {
        $v = $r.Norm
        if (-not $v) { continue }
        $hit = $false
        switch ($r.Match) {
            0 { $hit = $a.Contains($v) }                                        # Contains
            1 { $hit = ($a -eq $v) -or ($nameOnly -and $leaf -eq (Get-LeafName $v)) }   # Equals
            3 { $hit = (-not $nameOnly) -and $a.StartsWith($v) }                # Starts With
            4 { $hit = $a.EndsWith($v) -or ($nameOnly -and $v.EndsWith('\' + $a)) }     # Ends With
            default { $hit = $false }                                           # Hash/Signed: niet te controleren
        }
        if ($hit) { $hits.Add($r) }
    }

    $allow    = @($hits | Where-Object { $_.Action -eq 0 -and -not $_.Disabled })
    $deny     = @($hits | Where-Object { $_.Action -eq 1 -and -not $_.Disabled })
    $disabled = @($hits | Where-Object { $_.Disabled })

    if ($deny.Count -gt 0 -and $allow.Count -gt 0) { $lijst = 'Whitelist + Blacklist' }
    elseif ($deny.Count -gt 0)                     { $lijst = 'Blacklist' }
    elseif ($allow.Count -gt 0)                    { $lijst = 'Whitelist' }
    elseif ($disabled.Count -gt 0)                 { $lijst = 'Alleen uitgeschakelde regel' }
    elseif ($script:PuHasAllow) {
        $lijst = 'Niet op whitelist'
        if ($script:PuHasSignedAllow) { $lijst += ' (Signed/Hash niet gecontroleerd)' }
    }
    else { $lijst = 'Niet in configuratie' }

    $result = @{ Lijst = $lijst; Regel = (($hits | ForEach-Object { Format-PuRule $_ }) -join '; ') }
    $script:PuCache[$key] = $result
    return $result
}

# ---------------------------------------------------------------------------
# Thema (licht / donker)
# ---------------------------------------------------------------------------
$Palettes = @{
    Light = @{
        Bg = '#F3F3F3'; PanelBg = '#E9E9E9'; ControlBg = '#FFFFFF'; Fg = '#1E1E1E'; SubtleFg = '#6E6E6E'
        BorderBr = '#ABADB3'; AltRow = '#F3F6FA'; HeaderBg = '#EDEFF2'; GridLine = '#E3E3E3'
        Hover = '#E5F1FB'; SelBg = '#CCE4F7'; Accent = '#0078D4'
    }
    Dark = @{
        Bg = '#1E1E1E'; PanelBg = '#2D2D30'; ControlBg = '#252526'; Fg = '#E6E6E6'; SubtleFg = '#9A9A9A'
        BorderBr = '#3F3F46'; AltRow = '#2D2D30'; HeaderBg = '#333337'; GridLine = '#3A3A3A'
        Hover = '#3E3E40'; SelBg = '#094771'; Accent = '#3794FF'
    }
}

# Stijlen gebruiken DynamicResource, zodat wisselen van thema direct zichtbaar is
$StylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

  <Style TargetType="GroupBox">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBr}"/>
  </Style>

  <Style TargetType="StatusBar">
    <Setter Property="Background" Value="{DynamicResource PanelBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
  </Style>

  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
  </Style>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="{DynamicResource ControlBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBr}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource Fg}"/>
    <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    <Setter Property="Padding" Value="2,1"/>
  </Style>

  <Style TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource ControlBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBr}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="1" CornerRadius="2">
            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Hover}"/>
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
            </Trigger>
            <Trigger Property="IsPressed" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SelBg}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <ControlTemplate x:Key="ComboToggle" TargetType="ToggleButton">
    <Border x:Name="Bd" Background="{DynamicResource ControlBg}" BorderBrush="{DynamicResource BorderBr}" BorderThickness="1">
      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0"
            Data="M0,0 L4,4 L8,0 Z" Fill="{DynamicResource Fg}"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
      </Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>

  <Style TargetType="ComboBox">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="MinHeight" Value="22"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Template="{StaticResource ComboToggle}" Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
            <ContentPresenter IsHitTestVisible="False" Margin="6,2,22,2" VerticalAlignment="Center"
                              Content="{TemplateBinding SelectionBoxItem}"
                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"
                   Focusable="False" PopupAnimation="Slide">
              <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}"
                      Background="{DynamicResource ControlBg}" BorderBrush="{DynamicResource BorderBr}" BorderThickness="1">
                <ScrollViewer>
                  <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                </ScrollViewer>
              </Border>
            </Popup>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="Transparent" Padding="6,3">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SelBg}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="ListBox">
    <Setter Property="Background" Value="{DynamicResource ControlBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBr}"/>
  </Style>

  <Style TargetType="ListBoxItem">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ListBoxItem">
          <Border x:Name="Bd" Background="Transparent" Padding="4,2">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource SelBg}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="DataGrid">
    <Setter Property="Background" Value="{DynamicResource ControlBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBr}"/>
    <Setter Property="RowBackground" Value="{DynamicResource ControlBg}"/>
    <Setter Property="AlternatingRowBackground" Value="{DynamicResource AltRow}"/>
    <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource GridLine}"/>
    <Setter Property="VerticalGridLinesBrush" Value="{DynamicResource GridLine}"/>
  </Style>

  <Style TargetType="DataGridColumnHeader">
    <Setter Property="Background" Value="{DynamicResource HeaderBg}"/>
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBr}"/>
    <Setter Property="BorderThickness" Value="0,0,1,1"/>
    <Setter Property="Padding" Value="6,4"/>
  </Style>

  <Style TargetType="DataGridCell">
    <Setter Property="BorderThickness" Value="0"/>
    <Style.Triggers>
      <Trigger Property="IsSelected" Value="True">
        <Setter Property="Background" Value="{DynamicResource SelBg}"/>
        <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource SelBg}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
</ResourceDictionary>
'@

# Donkere titelbalk (Windows 10 20H1+ / Windows 11); wordt genegeerd als het niet lukt
try {
    if (-not ('LwEventViewer.Dwm' -as [type])) {
        Add-Type -Namespace LwEventViewer -Name Dwm -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
    }
} catch { }

function Set-TitleBarTheme($Win) {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $Win).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $v = [int][bool]$script:Config.DarkMode
        [void][LwEventViewer.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
    } catch { }
}

function Set-ThemeBrushes($Win) {
    $p = if ($script:Config.DarkMode) { $Palettes.Dark } else { $Palettes.Light }
    foreach ($k in $p.Keys) {
        $color = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($p[$k])
        $brush = [System.Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        # Het echte .NET-object doorgeven (geen PSObject-wrapper), anders weigert WPF de brush
        $Win.Resources[$k] = $brush.PSObject.BaseObject
    }
    Set-TitleBarTheme $Win
}

function Initialize-Theme($Win) {
    $Win.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse($StylesXaml))
    $Win.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'Bg')
    $Win.SetResourceReference([System.Windows.Window]::ForegroundProperty, 'Fg')
    Set-ThemeBrushes $Win
    $Win.Add_SourceInitialized({ param($sender, $e) Set-TitleBarTheme $sender })
}

# ---------------------------------------------------------------------------
# Hoofdvenster
# ---------------------------------------------------------------------------
$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Liquidware Event Viewer" Height="780" Width="1280"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12">
  <DockPanel Margin="8">
    <StatusBar DockPanel.Dock="Bottom">
      <StatusBarItem><TextBlock x:Name="StatusText" Text="Gereed"/></StatusBarItem>
    </StatusBar>

    <GroupBox Header="Ophalen" DockPanel.Dock="Top" Padding="6">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="70"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Servers:" FontWeight="SemiBold" Margin="0,3"/>
        <WrapPanel x:Name="ServerPanel" Grid.Column="1" Margin="0,3"/>

        <TextBlock Text="Bronnen:" FontWeight="SemiBold" Grid.Row="1" Margin="0,3"/>
        <WrapPanel x:Name="SourcePanel" Grid.Row="1" Grid.Column="1" Margin="0,3"/>

        <StackPanel Grid.Row="2" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,8,0,0">
          <TextBlock Text="Periode:" VerticalAlignment="Center"/>
          <ComboBox x:Name="PeriodBox" Width="140" Margin="6,0"/>
          <TextBlock Text="Max. events per server/bron:" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <TextBox x:Name="MaxEventsBox" Width="60" Margin="6,0" VerticalContentAlignment="Center"/>
          <Button x:Name="FetchButton"   Content="Events ophalen"      Padding="14,4" Margin="12,0,0,0" FontWeight="SemiBold"/>
          <Button x:Name="ConfigButton"  Content="Configuratie..."     Padding="12,4" Margin="6,0,0,0"/>
          <Button x:Name="SummaryButton" Content="Overzicht per applicatie" Padding="12,4" Margin="6,0,0,0"/>
          <Button x:Name="ExportButton"  Content="Exporteren (CSV)"    Padding="12,4" Margin="6,0,0,0"/>
          <CheckBox x:Name="DarkModeBox" Content="Donkere modus" VerticalAlignment="Center" Margin="16,0,0,0"/>
        </StackPanel>

        <StackPanel Grid.Row="3" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,8,0,0">
          <TextBlock Text="ProfileUnity-configuratie:" VerticalAlignment="Center" FontWeight="SemiBold"/>
          <ComboBox x:Name="PuConfigBox" Width="340" Margin="6,0"/>
          <TextBlock x:Name="PuInfoText" VerticalAlignment="Center" Margin="6,0,0,0" Foreground="{DynamicResource SubtleFg}"/>
        </StackPanel>
      </Grid>
    </GroupBox>

    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,8,0,6">
      <TextBlock Text="Filter bron:" VerticalAlignment="Center"/>
      <ComboBox x:Name="SourceFilterBox" Width="280" Margin="6,0"/>
      <TextBlock Text="Server:" VerticalAlignment="Center" Margin="10,0,0,0"/>
      <ComboBox x:Name="ServerFilterBox" Width="160" Margin="6,0"/>
      <TextBlock Text="Niveau:" VerticalAlignment="Center" Margin="10,0,0,0"/>
      <ComboBox x:Name="LevelFilterBox" Width="110" Margin="6,0"/>
      <TextBlock Text="Lijst:" VerticalAlignment="Center" Margin="10,0,0,0"/>
      <ComboBox x:Name="ListFilterBox" Width="190" Margin="6,0"/>
      <TextBlock Text="Zoeken:" VerticalAlignment="Center" Margin="10,0,0,0"/>
      <TextBox x:Name="SearchBox" Width="240" Margin="6,0" VerticalContentAlignment="Center"/>
      <CheckBox x:Name="AppOnlyBox" Content="Alleen events met applicatie" VerticalAlignment="Center" Margin="10,0,0,0"/>
    </StackPanel>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="3*"/>
        <RowDefinition Height="6"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <DataGrid x:Name="EventGrid" AutoGenerateColumns="False" IsReadOnly="True"
                SelectionMode="Single" CanUserSortColumns="True"
                GridLinesVisibility="Horizontal"
                HeadersVisibility="Column">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Tijd"       Binding="{Binding Tijd}"       Width="135"/>
          <DataGridTextColumn Header="Server"     Binding="{Binding Server}"     Width="120"/>
          <DataGridTextColumn Header="Bron"       Binding="{Binding Bron}"       Width="220"/>
          <DataGridTextColumn Header="Niveau"     Binding="{Binding Niveau}"     Width="80"/>
          <DataGridTextColumn Header="Event ID"   Binding="{Binding EventID}"    Width="65"/>
          <DataGridTextColumn Header="Applicatie" Binding="{Binding Applicatie}" Width="260"/>
          <DataGridTextColumn Header="Lijst"      Binding="{Binding Lijst}"      Width="150"/>
          <DataGridTextColumn Header="Bericht"    Binding="{Binding Samenvatting}" Width="*"/>
        </DataGrid.Columns>
      </DataGrid>

      <GridSplitter Grid.Row="1" Height="6" HorizontalAlignment="Stretch" Background="{DynamicResource BorderBr}"/>

      <TextBox x:Name="DetailBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
    </Grid>
  </DockPanel>
</Window>
'@

$window = New-Xaml $MainXaml
foreach ($name in 'StatusText','ServerPanel','SourcePanel','PeriodBox','MaxEventsBox','FetchButton',
                  'ConfigButton','SummaryButton','ExportButton','SourceFilterBox','ServerFilterBox',
                  'LevelFilterBox','SearchBox','AppOnlyBox','EventGrid','DetailBox','DarkModeBox',
                  'PuConfigBox','PuInfoText','ListFilterBox') {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}
Initialize-Theme $window
$DarkModeBox.IsChecked = [bool]$script:Config.DarkMode

$script:Results = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:View    = $null

function Set-Status([string]$Text) {
    $StatusText.Text = $Text
    # UI laten bijwerken tijdens lange acties
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Update-SelectionPanels {
    $ServerPanel.Children.Clear()
    foreach ($s in $script:Config.Servers) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $s; $cb.IsChecked = $true; $cb.Margin = '0,0,16,0'
        [void]$ServerPanel.Children.Add($cb)
    }
    $SourcePanel.Children.Clear()
    foreach ($s in $script:Config.Sources) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $s; $cb.IsChecked = $true; $cb.Margin = '0,0,16,0'
        [void]$SourcePanel.Children.Add($cb)
    }

    $PeriodBox.Items.Clear()
    $periods = @(
        @{ L = 'Laatste uur';      H = 1   },
        @{ L = 'Laatste 4 uur';    H = 4   },
        @{ L = 'Laatste 24 uur';   H = 24  },
        @{ L = 'Laatste 3 dagen';  H = 72  },
        @{ L = 'Laatste 7 dagen';  H = 168 },
        @{ L = 'Laatste 30 dagen'; H = 720 }
    )
    $hasDefault = $false
    foreach ($p in $periods) {
        if ($p.H -eq $script:Config.HoursBack) { $hasDefault = $true }
    }
    if (-not $hasDefault) {
        $periods += @{ L = "Laatste $($script:Config.HoursBack) uur"; H = $script:Config.HoursBack }
    }
    foreach ($p in ($periods | Sort-Object { $_.H })) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem
        $ci.Content = $p.L; $ci.Tag = $p.H
        [void]$PeriodBox.Items.Add($ci)
        if ($p.H -eq $script:Config.HoursBack) { $PeriodBox.SelectedItem = $ci }
    }
    $MaxEventsBox.Text = [string]$script:Config.MaxEvents
}

function Set-ComboItems($Combo, $Items) {
    $current = $Combo.SelectedItem
    $Combo.Items.Clear()
    [void]$Combo.Items.Add($AllLabel)
    foreach ($i in $Items) { [void]$Combo.Items.Add($i) }
    if ($current -and $Combo.Items.Contains($current)) { $Combo.SelectedItem = $current }
    else { $Combo.SelectedIndex = 0 }
}

function Update-FilterLists {
    $sources = @($script:Config.Sources) + @($script:Results | ForEach-Object { $_.Bron })
    $sources = $sources | Where-Object { $_ } | Sort-Object -Unique
    Set-ComboItems $SourceFilterBox $sources

    $servers = @($script:Config.Servers) + @($script:Results | ForEach-Object { $_.Server })
    $servers = $servers | Where-Object { $_ } | Sort-Object -Unique
    Set-ComboItems $ServerFilterBox $servers

    $levels = @($script:Results | ForEach-Object { $_.Niveau }) | Where-Object { $_ } | Sort-Object -Unique
    Set-ComboItems $LevelFilterBox $levels

    $lists = @($script:Results | ForEach-Object { $_.Lijst }) | Where-Object { $_ } | Sort-Object -Unique
    Set-ComboItems $ListFilterBox $lists
}

function Get-VisibleItems {
    $items = New-Object System.Collections.Generic.List[object]
    if ($script:View) { foreach ($i in $script:View) { $items.Add($i) } }
    return ,$items
}

function Update-Count {
    $visible = Get-VisibleItems
    $apps = @($visible | Where-Object { $_.Applicatie } | ForEach-Object { $_.Applicatie.ToLower() } | Sort-Object -Unique).Count
    $StatusText.Text = "Getoond: $($visible.Count) van $($script:Results.Count) events  |  Unieke applicaties in selectie: $apps"
}

$FilterPredicate = [Predicate[object]]{
    param($item)
    $src = $SourceFilterBox.SelectedItem
    if ($src -and $src -ne $AllLabel -and $item.Bron -ne $src) { return $false }
    $srv = $ServerFilterBox.SelectedItem
    if ($srv -and $srv -ne $AllLabel -and $item.Server -ne $srv) { return $false }
    $lvl = $LevelFilterBox.SelectedItem
    if ($lvl -and $lvl -ne $AllLabel -and $item.Niveau -ne $lvl) { return $false }
    $lst = $ListFilterBox.SelectedItem
    if ($lst -and $lst -ne $AllLabel -and $item.Lijst -ne $lst) { return $false }
    if ($AppOnlyBox.IsChecked -and -not $item.Applicatie) { return $false }
    $q = $SearchBox.Text
    if (-not [string]::IsNullOrWhiteSpace($q)) {
        $hay = "$($item.Server) $($item.Bron) $($item.EventID) $($item.Applicatie) $($item.Lijst) $($item.Regel) $($item.Bericht)"
        if ($hay.IndexOf($q.Trim(), [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Set-Results($List) {
    $script:Results = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($i in $List) { $script:Results.Add($i) }
    $EventGrid.ItemsSource = $script:Results
    $script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Results)
    $script:View.Filter = $FilterPredicate
    Update-FilterLists
    Update-Count
}

function Invoke-Refilter {
    if ($script:View) { $script:View.Refresh(); Update-Count }
}

# ---------------------------------------------------------------------------
# Events ophalen
# ---------------------------------------------------------------------------
function Invoke-Fetch {
    $servers = @($ServerPanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Content })
    $sources = @($SourcePanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Content })
    if ($servers.Count -eq 0) { [System.Windows.MessageBox]::Show('Selecteer minimaal een server.', 'Ophalen') | Out-Null; return }
    if ($sources.Count -eq 0) { [System.Windows.MessageBox]::Show('Selecteer minimaal een bron.', 'Ophalen') | Out-Null; return }

    $hours = 24
    if ($PeriodBox.SelectedItem) { $hours = [int]$PeriodBox.SelectedItem.Tag }
    $max = 0
    if (-not [int]::TryParse($MaxEventsBox.Text, [ref]$max) -or $max -lt 1) { $max = 500; $MaxEventsBox.Text = '500' }
    $start = (Get-Date).AddHours(-$hours)

    $list   = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    $FetchButton.IsEnabled = $false
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        foreach ($server in $servers) {
            foreach ($src in $sources) {
                Set-Status "Ophalen: $server  -  $src ..."
                try {
                    $filter = @{ ProviderName = $src; StartTime = $start }
                    $evts = Get-WinEvent -ComputerName $server -FilterHashtable $filter -MaxEvents $max -ErrorAction Stop
                    foreach ($e in $evts) {
                        $msg = $e.Message
                        if ([string]::IsNullOrWhiteSpace($msg)) {
                            # Geen berichttekst beschikbaar (bijv. message-DLL ontbreekt): ruwe eigenschappen tonen
                            $msg = (@($e.Properties | ForEach-Object { $_.Value }) -join ' | ')
                        }
                        $app = Get-AppFromMessage $msg
                        $pu  = Get-PuStatus $app
                        $list.Add([pscustomobject]@{
                            Tijd         = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                            Server       = $server
                            Bron         = $e.ProviderName
                            Niveau       = $e.LevelDisplayName
                            EventID      = $e.Id
                            Applicatie   = $app
                            Lijst        = $pu.Lijst
                            Regel        = $pu.Regel
                            Samenvatting = Get-FirstLine $msg
                            Logboek      = $e.LogName
                            Bericht      = $msg
                        })
                    }
                } catch {
                    $fqid = [string]$_.FullyQualifiedErrorId
                    $em   = $_.Exception.Message
                    if ($fqid -like 'NoMatchingEventsFound*') {
                        # Geen events in deze periode: geen fout
                    } elseif ($fqid -like '*Provider*' -or $em -match 'event provider|gebeurtenisprovider') {
                        $errors.Add("$server  -  bron '$src' bestaat niet op deze server")
                    } else {
                        $errors.Add("$server  -  $src : $em")
                    }
                }
            }
        }
    } finally {
        $FetchButton.IsEnabled = $true
        $window.Cursor = $null
    }

    $sorted = $list | Sort-Object Tijd -Descending
    Set-Results $sorted
    $DetailBox.Text = ''

    if ($errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show(
            "Niet alles kon worden opgehaald:`n`n" + ($errors -join "`n") +
            "`n`nTip: controleer of de server bereikbaar is, of je rechten hebt (Event Log Readers / admin) en of de firewallregel 'Remote Event Log Management' aan staat.",
            'Ophalen', 'OK', 'Warning') | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Configuratiescherm
# ---------------------------------------------------------------------------
$ConfigXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Configuratie" Height="660" Width="760" ResizeMode="CanResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="12">
  <Grid Margin="10">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="10"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <GroupBox Header="Servers" Padding="6">
      <DockPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,6,0,0">
          <Button x:Name="RemoveServerBtn" Content="Verwijderen" DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"/>
          <Button x:Name="AddServerBtn" Content="Toevoegen" DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"/>
          <TextBox x:Name="NewServerBox" VerticalContentAlignment="Center" ToolTip="Servernaam (Enter = toevoegen)"/>
        </DockPanel>
        <ListBox x:Name="ServerList" SelectionMode="Extended"/>
      </DockPanel>
    </GroupBox>

    <GroupBox Header="Bronnen (event source / provider)" Grid.Column="2" Padding="6">
      <DockPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,6,0,0">
          <Button x:Name="RemoveSourceBtn" Content="Verwijderen" DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"/>
          <Button x:Name="AddSourceBtn" Content="Toevoegen" DockPanel.Dock="Right" Padding="8,2" Margin="6,0,0,0"/>
          <TextBox x:Name="NewSourceBox" VerticalContentAlignment="Center" ToolTip="Naam van de bron (Enter = toevoegen)"/>
        </DockPanel>
        <ListBox x:Name="SourceList" SelectionMode="Extended"/>
      </DockPanel>
    </GroupBox>

    <GroupBox Header="ProfileUnity-configuraties (JSON-export uit de ProfileUnity-console)" Grid.Row="1" Grid.ColumnSpan="3" Padding="6" Margin="0,10,0,0" Height="150">
      <DockPanel>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,6,0,0">
          <Button x:Name="AddPuBtn" Content="Bladeren..." Padding="8,2"/>
          <Button x:Name="RemovePuBtn" Content="Verwijderen" Padding="8,2" Margin="6,0,0,0"/>
        </StackPanel>
        <ListBox x:Name="PuList" SelectionMode="Extended"/>
      </DockPanel>
    </GroupBox>

    <StackPanel Grid.Row="2" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,10,0,0">
      <TextBlock Text="Standaard periode (uren):" VerticalAlignment="Center"/>
      <TextBox x:Name="DefaultHoursBox" Width="60" Margin="6,0,20,0" VerticalContentAlignment="Center"/>
      <TextBlock Text="Standaard max. events per server/bron:" VerticalAlignment="Center"/>
      <TextBox x:Name="DefaultMaxBox" Width="60" Margin="6,0" VerticalContentAlignment="Center"/>
    </StackPanel>

    <DockPanel Grid.Row="3" Grid.ColumnSpan="3" Margin="0,12,0,0" LastChildFill="False">
      <TextBlock x:Name="PathText" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="{DynamicResource SubtleFg}" TextTrimming="CharacterEllipsis" MaxWidth="420"/>
      <Button x:Name="CancelBtn" Content="Annuleren" DockPanel.Dock="Right" Padding="14,4" Margin="6,0,0,0" IsCancel="True"/>
      <Button x:Name="SaveBtn" Content="Opslaan" DockPanel.Dock="Right" Padding="14,4" FontWeight="SemiBold"/>
    </DockPanel>
  </Grid>
</Window>
'@

function Add-ListItem($Collection, $TextBox) {
    $v = $TextBox.Text.Trim()
    if (-not $v) { return }
    foreach ($existing in $Collection) {
        if ($existing -ieq $v) { $TextBox.Clear(); return }
    }
    $Collection.Add($v)
    $TextBox.Clear()
    $TextBox.Focus() | Out-Null
}

function Remove-ListItems($Collection, $ListBox) {
    foreach ($sel in @($ListBox.SelectedItems)) { [void]$Collection.Remove($sel) }
}

function Add-PuConfigFile {
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = 'ProfileUnity-configuratie (*.json)|*.json|Alle bestanden (*.*)|*.*'
    $ofd.Multiselect = $true
    $ofd.Title = 'ProfileUnity-configuratie (JSON) kiezen'
    if ($ofd.ShowDialog()) {
        foreach ($f in $ofd.FileNames) {
            $exists = $false
            foreach ($e in $script:Cfg.PuItems) { if ($e -ieq $f) { $exists = $true } }
            if (-not $exists) { $script:Cfg.PuItems.Add($f) }
        }
    }
}

function Save-ConfigFromDialog {
    $c = $script:Cfg
    $h = 0; $m = 0
    if (-not [int]::TryParse($c.DefaultHoursBox.Text, [ref]$h) -or $h -lt 1) {
        [System.Windows.MessageBox]::Show('Vul een geldig aantal uren in (1 of hoger).', 'Configuratie') | Out-Null; return
    }
    if (-not [int]::TryParse($c.DefaultMaxBox.Text, [ref]$m) -or $m -lt 1) {
        [System.Windows.MessageBox]::Show('Vul een geldig maximum aantal events in (1 of hoger).', 'Configuratie') | Out-Null; return
    }
    $new = [pscustomobject]@{
        Servers   = @($c.ServerItems)
        Sources   = @($c.SourceItems)
        HoursBack = $h
        MaxEvents = $m
        DarkMode  = [bool]$script:Config.DarkMode
        ProfileUnityConfigs      = @($c.PuItems)
        ActiveProfileUnityConfig = ''
    }
    # Actieve ProfileUnity-config behouden als die nog in de lijst staat
    foreach ($pu in $c.PuItems) {
        if ($pu -ieq [string]$script:Config.ActiveProfileUnityConfig) { $new.ActiveProfileUnityConfig = $pu }
    }
    try {
        Save-Config $new
    } catch {
        [System.Windows.MessageBox]::Show("Opslaan mislukt:`n$($_.Exception.Message)", 'Configuratie', 'OK', 'Error') | Out-Null
        return
    }
    $c.Saved = $true
    $c.Dlg.Close()
}

function Show-ConfigDialog {
    $dlg = New-Xaml $ConfigXaml
    $dlg.Owner = $window
    Initialize-Theme $dlg

    # Status van de dialoog in script-scope, zodat de event handlers erbij kunnen
    $c = @{ Dlg = $dlg; Saved = $false }
    foreach ($n in 'RemoveServerBtn','AddServerBtn','NewServerBox','ServerList','RemoveSourceBtn','AddSourceBtn',
                   'NewSourceBox','SourceList','DefaultHoursBox','DefaultMaxBox','PathText','CancelBtn','SaveBtn',
                   'PuList','AddPuBtn','RemovePuBtn') {
        $c[$n] = $dlg.FindName($n)
    }
    $c.ServerItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    $c.SourceItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    foreach ($s in $script:Config.Servers) { $c.ServerItems.Add($s) }
    foreach ($s in $script:Config.Sources) { $c.SourceItems.Add($s) }
    $c.PuItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    foreach ($s in $script:Config.ProfileUnityConfigs) { $c.PuItems.Add($s) }
    $c.PuList.ItemsSource = $c.PuItems
    $c.ServerList.ItemsSource = $c.ServerItems
    $c.SourceList.ItemsSource = $c.SourceItems
    $c.DefaultHoursBox.Text = [string]$script:Config.HoursBack
    $c.DefaultMaxBox.Text   = [string]$script:Config.MaxEvents
    $c.PathText.Text        = "Opgeslagen in: $ConfigPath"
    $c.PathText.ToolTip     = $ConfigPath
    $script:Cfg = $c

    $c.AddServerBtn.Add_Click({ Add-ListItem $script:Cfg.ServerItems $script:Cfg.NewServerBox })
    $c.AddSourceBtn.Add_Click({ Add-ListItem $script:Cfg.SourceItems $script:Cfg.NewSourceBox })
    $c.RemoveServerBtn.Add_Click({ Remove-ListItems $script:Cfg.ServerItems $script:Cfg.ServerList })
    $c.RemoveSourceBtn.Add_Click({ Remove-ListItems $script:Cfg.SourceItems $script:Cfg.SourceList })
    $c.NewServerBox.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Add-ListItem $script:Cfg.ServerItems $script:Cfg.NewServerBox } })
    $c.NewSourceBox.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Add-ListItem $script:Cfg.SourceItems $script:Cfg.NewSourceBox } })
    $c.ServerList.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Delete') { Remove-ListItems $script:Cfg.ServerItems $script:Cfg.ServerList } })
    $c.SourceList.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Delete') { Remove-ListItems $script:Cfg.SourceItems $script:Cfg.SourceList } })
    $c.AddPuBtn.Add_Click({ Add-PuConfigFile })
    $c.RemovePuBtn.Add_Click({ Remove-ListItems $script:Cfg.PuItems $script:Cfg.PuList })
    $c.PuList.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Delete') { Remove-ListItems $script:Cfg.PuItems $script:Cfg.PuList } })
    $c.SaveBtn.Add_Click({ Save-ConfigFromDialog })
    $c.CancelBtn.Add_Click({ $script:Cfg.Dlg.Close() })

    $c.NewServerBox.Focus() | Out-Null
    [void]$dlg.ShowDialog()

    if ($c.Saved) {
        # Nieuwe waarden direct opnieuw inladen uit het JSON-bestand
        $script:Config = Read-Config
    }
    return $c.Saved
}

# ---------------------------------------------------------------------------
# Overzicht per applicatie
# ---------------------------------------------------------------------------
function Show-Summary {
    $visible = Get-VisibleItems
    $withApp = @($visible | Where-Object { $_.Applicatie })
    if ($withApp.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Er zijn (in de huidige filter) geen events waarin een applicatie is herkend.', 'Overzicht') | Out-Null
        return
    }
    $rows = $withApp | Group-Object { $_.Applicatie.ToLower() } | ForEach-Object {
        $g = $_.Group
        $times = $g | ForEach-Object { $_.Tijd } | Sort-Object
        [pscustomobject]@{
            Applicatie  = $g[0].Applicatie
            Lijst       = $g[0].Lijst
            Aantal      = $_.Count
            Servers     = (($g | ForEach-Object { $_.Server } | Sort-Object -Unique) -join ', ')
            Bronnen     = (($g | ForEach-Object { $_.Bron } | Sort-Object -Unique) -join ', ')
            EersteKeer  = $times[0]
            LaatsteKeer = $times[-1]
            Regel       = $g[0].Regel
        }
    } | Sort-Object Aantal -Descending

    $sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Overzicht per applicatie" Height="500" Width="1000"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="12">
  <DockPanel Margin="8">
    <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0" LastChildFill="False">
      <Button x:Name="CloseBtn" Content="Sluiten" DockPanel.Dock="Right" Padding="14,4" IsCancel="True"/>
      <Button x:Name="ExportSumBtn" Content="Exporteren (CSV)" DockPanel.Dock="Right" Padding="12,4" Margin="0,0,6,0"/>
    </DockPanel>
    <DataGrid x:Name="SumGrid" IsReadOnly="True" AutoGenerateColumns="True"
              GridLinesVisibility="Horizontal" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $sw = New-Xaml $sx
    $sw.Owner = $window
    Initialize-Theme $sw
    $script:SumWin  = $sw
    $script:SumRows = @($rows)
    $sw.FindName('SumGrid').ItemsSource = $script:SumRows
    $sw.FindName('CloseBtn').Add_Click({ $script:SumWin.Close() })
    $sw.FindName('ExportSumBtn').Add_Click({ Export-Rows $script:SumRows 'Liquidware-applicaties' })
    [void]$sw.ShowDialog()
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
function Export-Rows($Rows, [string]$BaseName) {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV-bestand (*.csv)|*.csv'
    $dlg.FileName = "$BaseName-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    if ($dlg.ShowDialog()) {
        try {
            $Rows | Export-Csv -Path $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
            $StatusText.Text = "Geexporteerd naar $($dlg.FileName)"
        } catch {
            [System.Windows.MessageBox]::Show("Exporteren mislukt:`n$($_.Exception.Message)", 'Export', 'OK', 'Error') | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# ProfileUnity-configuratie koppelen aan de resultaten
# ---------------------------------------------------------------------------
function Update-PuConfigBox {
    $script:PuPopulating = $true
    try {
        $PuConfigBox.Items.Clear()
        $none = New-Object System.Windows.Controls.ComboBoxItem
        $none.Content = '(geen)'; $none.Tag = ''
        [void]$PuConfigBox.Items.Add($none)
        $PuConfigBox.SelectedItem = $none
        foreach ($f in $script:Config.ProfileUnityConfigs) {
            $ci = New-Object System.Windows.Controls.ComboBoxItem
            $ci.Content = Split-Path -Path $f -Leaf
            $ci.Tag     = $f
            $ci.ToolTip = $f
            [void]$PuConfigBox.Items.Add($ci)
            if ($f -ieq [string]$script:Config.ActiveProfileUnityConfig) { $PuConfigBox.SelectedItem = $ci }
        }
    } finally {
        $script:PuPopulating = $false
    }
}

function Set-ActivePuConfig {
    $path = [string]$script:Config.ActiveProfileUnityConfig
    if ($path) { Set-Status "ProfileUnity-configuratie laden: $path ..." }
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        Import-PuConfig $path
    } finally {
        $window.Cursor = $null
    }
    $PuInfoText.Text = $script:PuInfo
    # Bestaande resultaten opnieuw beoordelen
    foreach ($item in $script:Results) {
        $s = Get-PuStatus $item.Applicatie
        $item.Lijst = $s.Lijst
        $item.Regel = $s.Regel
    }
    $EventGrid.Items.Refresh()
    Update-FilterLists
    Invoke-Refilter
    if (-not $path) { Update-Count }
}

# ---------------------------------------------------------------------------
# Events koppelen
# ---------------------------------------------------------------------------
$FetchButton.Add_Click({ Invoke-Fetch })

$ConfigButton.Add_Click({
    if (Show-ConfigDialog) {
        Update-SelectionPanels
        Update-PuConfigBox
        Set-ActivePuConfig
        $StatusText.Text = 'Configuratie opgeslagen.'
    }
})

$SummaryButton.Add_Click({ Show-Summary })

$DarkModeBox.Add_Click({
    $script:Config.DarkMode = [bool]$DarkModeBox.IsChecked
    Set-ThemeBrushes $window
    try { Save-Config $script:Config } catch { }
})

$ExportButton.Add_Click({
    $visible = Get-VisibleItems
    if ($visible.Count -eq 0) { [System.Windows.MessageBox]::Show('Er is niets om te exporteren.', 'Export') | Out-Null; return }
    Export-Rows ($visible | Select-Object Tijd, Server, Bron, Niveau, EventID, Applicatie, Lijst, Regel, Logboek, Bericht) 'Liquidware-events'
})

$SourceFilterBox.Add_SelectionChanged({ Invoke-Refilter })
$ServerFilterBox.Add_SelectionChanged({ Invoke-Refilter })
$LevelFilterBox.Add_SelectionChanged({ Invoke-Refilter })
$ListFilterBox.Add_SelectionChanged({ Invoke-Refilter })

$PuConfigBox.Add_SelectionChanged({
    if ($script:PuPopulating) { return }
    $sel = $PuConfigBox.SelectedItem
    $path = ''
    if ($sel) { $path = [string]$sel.Tag }
    $script:Config.ActiveProfileUnityConfig = $path
    try { Save-Config $script:Config } catch { }
    Set-ActivePuConfig
})
$SearchBox.Add_TextChanged({ Invoke-Refilter })
$AppOnlyBox.Add_Click({ Invoke-Refilter })

$EventGrid.Add_SelectionChanged({
    $sel = $EventGrid.SelectedItem
    if ($sel) {
        $DetailBox.Text = "Tijd:       $($sel.Tijd)`r`nServer:     $($sel.Server)`r`nBron:       $($sel.Bron)`r`nLogboek:    $($sel.Logboek)`r`nNiveau:     $($sel.Niveau)`r`nEvent ID:   $($sel.EventID)`r`nApplicatie: $($sel.Applicatie)`r`nLijst:      $($sel.Lijst)`r`nRegel(s):   $($sel.Regel)`r`n`r`n$($sel.Bericht)"
    } else {
        $DetailBox.Text = ''
    }
})

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
Update-SelectionPanels
Set-Results @()
Update-PuConfigBox
Set-ActivePuConfig
$StatusText.Text = "Gereed. Configuratie: $ConfigPath"
[void]$window.ShowDialog()
