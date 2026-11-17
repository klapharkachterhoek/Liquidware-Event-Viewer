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
- **Koppeling met de ProfileUnity-configuratie**: kies een JSON-export van je ProfileUnity-configuratie en zie per geblokkeerde applicatie of die op de whitelist (Allow) of blacklist (Deny) staat, en welke regel(s) er van toepassing zijn
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

## ProfileUnity-configuratie

Exporteer de configuratie in de ProfileUnity-console als JSON en voeg het bestand toe via **Configuratie... > ProfileUnity-configuraties > Bladeren...**. Kies daarna in het hoofdvenster bij **ProfileUnity-configuratie** welke export je gebruikt.

De tool leest de sectie `ApplicationRestrictions` en vergelijkt het pad uit het event met elke regel:

| Kolom *Lijst* | Betekenis |
|---|---|
| Whitelist | Er is een actieve Allow-regel die past |
| Blacklist | Er is een actieve Deny-regel die past |
| Whitelist + Blacklist | Er passen zowel Allow- als Deny-regels (kijk naar de filters in *Regel*) |
| Alleen uitgeschakelde regel | Er past alleen een regel die is uitgeschakeld |
| Niet op whitelist | Geen passende regel, terwijl de configuratie Allow-regels bevat (ProfileUnity weigert dan alles wat niet is toegestaan) |
| Niet in configuratie | Geen passende regel en geen whitelist-modus |
| Blacklist (volgens event) | Liquidware meldt *DenyList Match* (event 5003), maar er is geen passende Deny-regel in de gekozen configuratie (of er is geen configuratie gekozen) |
| Niet op whitelist (volgens event) | Liquidware meldt *AllowList Violation* (event 5002) en er is geen configuratie gekozen |
| Whitelist, toch geblokkeerd | Liquidware meldt *AllowList Violation*, terwijl er wel een Allow-regel past (controleer het filter of de datum van de regel) |

Match-types: Contains, Equals, Starts With en Ends With worden gecontroleerd; omgevingsvariabelen zoals `%SystemRoot%` worden uitgevouwen. **Hash** en **Signed** kunnen niet uit een event worden afgeleid en worden niet gecontroleerd. Filters (bijv. AD-groepen) worden getoond in de kolom *Regel*, maar niet geëvalueerd.

## Configuratie

```json
{
    "Servers":   [ "server01", "server02" ],
    "Sources":   [ "liquidware application restriction", "Liquidware data service", "Liquidware Events and Metrics Service" ],
    "HoursBack": 24,
    "MaxEvents": 500,
    "DarkMode":  false,
    "ProfileUnityConfigs": [ "D:\\beheer\\Configuration-CTX-Test.json" ],
    "ActiveProfileUnityConfig": "D:\\beheer\\Configuration-CTX-Test.json"
}
```

Bestaat het JSON-bestand niet, dan maakt het script het aan met de standaardbronnen en zonder servers.

## Vereisten

- Windows PowerShell 5.1
- Rechten om eventlogs op afstand te lezen (lid van *Event Log Readers* of lokale admin op de server)
- Firewallregel **Remote Event Log Management** ingeschakeld op de servers
- De bronnaam moet overeenkomen met de naam in Event Viewer (hoofdletters maken niet uit)
