# Liquidware Event Viewer

PowerShell-tool met grafische interface (WPF) om eventlogs van een of meer servers in één overzicht te bekijken. Hij is bedoeld om te zien welke applicaties door Liquidware (whitelisting/blacklisting) worden tegengehouden.

## Functies

- Events ophalen van meerdere servers tegelijk, per bron (event source/provider)
- Standaardbronnen:
  - `liquidware application restriction`
  - `Liquidware data service`
  - `Liquidware Events and Metrics Service`
- Filteren op bron, server, niveau en vrije tekst; optie "Alleen events met applicatie"
- Automatische herkenning van de applicatie (pad of bestandsnaam zoals `.exe`, `.bat`, `.ps1`) in de berichttekst
- **Overzicht per applicatie**: aantal blokkades, servers, bronnen, eerste en laatste keer
- Export naar CSV (met puntkomma's, geschikt voor Nederlandse Excel)
- **Donkere modus** via een schakelaar in het hoofdvenster (wordt onthouden)
- Configuratiescherm voor servers, bronnen, standaardperiode en maximum aantal events; wordt opgeslagen in `LiquidwareEventViewer.json` en direct geladen

## Bestanden

| Bestand | Omschrijving |
|---|---|
| `LiquidwareEventViewer.ps1` | Het script |
| `LiquidwareEventViewer.json` | Configuratie (servers, bronnen, standaardwaarden) |
| `Start-LiquidwareEventViewer.cmd` | Start het script zonder consolevenster |

## Gebruik

1. Zet de bestanden samen in één map.
2. Start `Start-LiquidwareEventViewer.cmd`, of:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\LiquidwareEventViewer.ps1
   ```
3. Voeg via **Configuratie...** je servers toe en klik op **Opslaan**.
4. Kies servers, bronnen en periode, en klik op **Events ophalen**.

## Configuratie

```json
{
    "Servers":   [ "server01", "server02" ],
    "Sources":   [ "liquidware application restriction", "Liquidware data service", "Liquidware Events and Metrics Service" ],
    "HoursBack": 24,
    "MaxEvents": 500,
    "DarkMode":  false
}
```

Bestaat het JSON-bestand niet, dan maakt het script het aan met de standaardbronnen en zonder servers.

## Vereisten

- Windows PowerShell 5.1
- Rechten om eventlogs op afstand te lezen (lid van *Event Log Readers* of lokale admin op de server)
- Firewallregel **Remote Event Log Management** ingeschakeld op de servers
- De bronnaam moet overeenkomen met de naam in Event Viewer (hoofdletters maken niet uit)
