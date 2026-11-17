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
    }
}

function Save-Config($Cfg) {
    $obj = [ordered]@{
        Servers   = @($Cfg.Servers)
        Sources   = @($Cfg.Sources)
        HoursBack = [int]$Cfg.HoursBack
        MaxEvents = [int]$Cfg.MaxEvents
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
                AlternatingRowBackground="#F3F6FA" GridLinesVisibility="Horizontal"
                HeadersVisibility="Column">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Tijd"       Binding="{Binding Tijd}"       Width="135"/>
          <DataGridTextColumn Header="Server"     Binding="{Binding Server}"     Width="120"/>
          <DataGridTextColumn Header="Bron"       Binding="{Binding Bron}"       Width="220"/>
          <DataGridTextColumn Header="Niveau"     Binding="{Binding Niveau}"     Width="80"/>
          <DataGridTextColumn Header="Event ID"   Binding="{Binding EventID}"    Width="65"/>
          <DataGridTextColumn Header="Applicatie" Binding="{Binding Applicatie}" Width="260"/>
          <DataGridTextColumn Header="Bericht"    Binding="{Binding Samenvatting}" Width="*"/>
        </DataGrid.Columns>
      </DataGrid>

      <GridSplitter Grid.Row="1" Height="6" HorizontalAlignment="Stretch" Background="#DDD"/>

      <TextBox x:Name="DetailBox" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"/>
    </Grid>
  </DockPanel>
</Window>
'@

$window = New-Xaml $MainXaml
foreach ($name in 'StatusText','ServerPanel','SourcePanel','PeriodBox','MaxEventsBox','FetchButton',
                  'ConfigButton','SummaryButton','ExportButton','SourceFilterBox','ServerFilterBox',
                  'LevelFilterBox','SearchBox','AppOnlyBox','EventGrid','DetailBox') {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

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
    if ($AppOnlyBox.IsChecked -and -not $item.Applicatie) { return $false }
    $q = $SearchBox.Text
    if (-not [string]::IsNullOrWhiteSpace($q)) {
        $hay = "$($item.Server) $($item.Bron) $($item.EventID) $($item.Applicatie) $($item.Bericht)"
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
                        $list.Add([pscustomobject]@{
                            Tijd         = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                            Server       = $server
                            Bron         = $e.ProviderName
                            Niveau       = $e.LevelDisplayName
                            EventID      = $e.Id
                            Applicatie   = Get-AppFromMessage $msg
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
        Title="Configuratie" Height="520" Width="720" ResizeMode="CanResize"
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

    <StackPanel Grid.Row="1" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,10,0,0">
      <TextBlock Text="Standaard periode (uren):" VerticalAlignment="Center"/>
      <TextBox x:Name="DefaultHoursBox" Width="60" Margin="6,0,20,0" VerticalContentAlignment="Center"/>
      <TextBlock Text="Standaard max. events per server/bron:" VerticalAlignment="Center"/>
      <TextBox x:Name="DefaultMaxBox" Width="60" Margin="6,0" VerticalContentAlignment="Center"/>
    </StackPanel>

    <DockPanel Grid.Row="2" Grid.ColumnSpan="3" Margin="0,12,0,0" LastChildFill="False">
      <TextBlock x:Name="PathText" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="Gray" TextTrimming="CharacterEllipsis" MaxWidth="420"/>
      <Button x:Name="CancelBtn" Content="Annuleren" DockPanel.Dock="Right" Padding="14,4" Margin="6,0,0,0" IsCancel="True"/>
      <Button x:Name="SaveBtn" Content="Opslaan" DockPanel.Dock="Right" Padding="14,4" FontWeight="SemiBold"/>
    </DockPanel>
  </Grid>
</Window>
'@

function Show-ConfigDialog {
    $dlg = New-Xaml $ConfigXaml
    $dlg.Owner = $window
    $c = @{}
    foreach ($n in 'RemoveServerBtn','AddServerBtn','NewServerBox','ServerList','RemoveSourceBtn','AddSourceBtn',
                   'NewSourceBox','SourceList','DefaultHoursBox','DefaultMaxBox','PathText','CancelBtn','SaveBtn') {
        $c[$n] = $dlg.FindName($n)
    }

    $serverItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    $sourceItems = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    foreach ($s in $script:Config.Servers) { $serverItems.Add($s) }
    foreach ($s in $script:Config.Sources) { $sourceItems.Add($s) }
    $c.ServerList.ItemsSource = $serverItems
    $c.SourceList.ItemsSource = $sourceItems
    $c.DefaultHoursBox.Text = [string]$script:Config.HoursBack
    $c.DefaultMaxBox.Text   = [string]$script:Config.MaxEvents
    $c.PathText.Text        = "Opgeslagen in: $ConfigPath"
    $c.PathText.ToolTip     = $ConfigPath

    $addItem = {
        param($Collection, $TextBox)
        $v = $TextBox.Text.Trim()
        if (-not $v) { return }
        foreach ($existing in $Collection) {
            if ($existing -ieq $v) { $TextBox.Clear(); return }
        }
        $Collection.Add($v)
        $TextBox.Clear()
        $TextBox.Focus() | Out-Null
    }
    $removeItems = {
        param($Collection, $ListBox)
        foreach ($sel in @($ListBox.SelectedItems)) { [void]$Collection.Remove($sel) }
    }

    $c.AddServerBtn.Add_Click({ & $addItem $serverItems $c.NewServerBox }.GetNewClosure())
    $c.AddSourceBtn.Add_Click({ & $addItem $sourceItems $c.NewSourceBox }.GetNewClosure())
    $c.RemoveServerBtn.Add_Click({ & $removeItems $serverItems $c.ServerList }.GetNewClosure())
    $c.RemoveSourceBtn.Add_Click({ & $removeItems $sourceItems $c.SourceList }.GetNewClosure())
    $c.NewServerBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $addItem $serverItems $c.NewServerBox } }.GetNewClosure())
    $c.NewSourceBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $addItem $sourceItems $c.NewSourceBox } }.GetNewClosure())
    $c.ServerList.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Delete') { & $removeItems $serverItems $c.ServerList } }.GetNewClosure())
    $c.SourceList.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Delete') { & $removeItems $sourceItems $c.SourceList } }.GetNewClosure())

    $result = @{ Saved = $false }
    $c.SaveBtn.Add_Click({
        $h = 0; $m = 0
        if (-not [int]::TryParse($c.DefaultHoursBox.Text, [ref]$h) -or $h -lt 1) {
            [System.Windows.MessageBox]::Show('Vul een geldig aantal uren in (1 of hoger).', 'Configuratie') | Out-Null; return
        }
        if (-not [int]::TryParse($c.DefaultMaxBox.Text, [ref]$m) -or $m -lt 1) {
            [System.Windows.MessageBox]::Show('Vul een geldig maximum aantal events in (1 of hoger).', 'Configuratie') | Out-Null; return
        }
        $new = [pscustomobject]@{
            Servers   = @($serverItems)
            Sources   = @($sourceItems)
            HoursBack = $h
            MaxEvents = $m
        }
        try {
            Save-Config $new
        } catch {
            [System.Windows.MessageBox]::Show("Opslaan mislukt:`n$($_.Exception.Message)", 'Configuratie', 'OK', 'Error') | Out-Null
            return
        }
        # Let op: binnen een GetNewClosure()-scriptblock verwijst $script: niet naar
        # het hoofdscript. Daarom alleen de vlag zetten; het herladen gebeurt hieronder.
        $result.Saved = $true
        $dlg.Close()
    }.GetNewClosure())
    $c.CancelBtn.Add_Click({ $dlg.Close() }.GetNewClosure())

    $c.NewServerBox.Focus() | Out-Null
    [void]$dlg.ShowDialog()

    if ($result.Saved) {
        # Nieuwe waarden direct opnieuw inladen uit het JSON-bestand
        $script:Config = Read-Config
    }
    return $result.Saved
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
            Aantal      = $_.Count
            Servers     = (($g | ForEach-Object { $_.Server } | Sort-Object -Unique) -join ', ')
            Bronnen     = (($g | ForEach-Object { $_.Bron } | Sort-Object -Unique) -join ', ')
            EersteKeer  = $times[0]
            LaatsteKeer = $times[-1]
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
              AlternatingRowBackground="#F3F6FA" GridLinesVisibility="Horizontal" HeadersVisibility="Column"/>
  </DockPanel>
</Window>
'@
    $sw = New-Xaml $sx
    $sw.Owner = $window
    $sw.FindName('SumGrid').ItemsSource = @($rows)
    $sw.FindName('CloseBtn').Add_Click({ $sw.Close() }.GetNewClosure())
    $sw.FindName('ExportSumBtn').Add_Click({ Export-Rows $rows 'Liquidware-applicaties' }.GetNewClosure())
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
# Events koppelen
# ---------------------------------------------------------------------------
$FetchButton.Add_Click({ Invoke-Fetch })

$ConfigButton.Add_Click({
    if (Show-ConfigDialog) {
        Update-SelectionPanels
        Update-FilterLists
        $StatusText.Text = 'Configuratie opgeslagen.'
    }
})

$SummaryButton.Add_Click({ Show-Summary })

$ExportButton.Add_Click({
    $visible = Get-VisibleItems
    if ($visible.Count -eq 0) { [System.Windows.MessageBox]::Show('Er is niets om te exporteren.', 'Export') | Out-Null; return }
    Export-Rows ($visible | Select-Object Tijd, Server, Bron, Niveau, EventID, Applicatie, Logboek, Bericht) 'Liquidware-events'
})

$SourceFilterBox.Add_SelectionChanged({ Invoke-Refilter })
$ServerFilterBox.Add_SelectionChanged({ Invoke-Refilter })
$LevelFilterBox.Add_SelectionChanged({ Invoke-Refilter })
$SearchBox.Add_TextChanged({ Invoke-Refilter })
$AppOnlyBox.Add_Click({ Invoke-Refilter })

$EventGrid.Add_SelectionChanged({
    $sel = $EventGrid.SelectedItem
    if ($sel) {
        $DetailBox.Text = "Tijd:       $($sel.Tijd)`r`nServer:     $($sel.Server)`r`nBron:       $($sel.Bron)`r`nLogboek:    $($sel.Logboek)`r`nNiveau:     $($sel.Niveau)`r`nEvent ID:   $($sel.EventID)`r`nApplicatie: $($sel.Applicatie)`r`n`r`n$($sel.Bericht)"
    } else {
        $DetailBox.Text = ''
    }
})

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
Update-SelectionPanels
Set-Results @()
$StatusText.Text = "Gereed. Configuratie: $ConfigPath"
[void]$window.ShowDialog()
