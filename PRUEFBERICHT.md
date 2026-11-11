---
lang: de-DE
---

# Prüfung und Überarbeitung der Veröffentlichungstauglichkeit

Stand: 11. November 2026. Geprüft wurde die hochgeladene `nc-userkontenverwaltung.ps1`; anschließend wurden die besprochenen Schutzmaßnahmen in der Paketkopie umgesetzt. Der ursprüngliche Upload bleibt unverändert.

## Ergebnis der Inhaltsprüfung

Im ursprünglichen Skript wurden keine fest eingetragenen echten Passwörter, API-Tokens, privaten Schlüssel, persönlichen E-Mail-Adressen, konkreten Instanzadressen oder organisationsbezogenen lokalen Pfade gefunden. Instanzadresse und Admin-Kontoname sind standardmäßig leer. Variablennamen wie `AdminPassword` und ein erst zur Laufzeit erzeugter Basic-Auth-Header sind keine hinterlegten Zugangsdaten.

Dies ist keine Garantie vollständiger Geheimnisfreiheit. Die lokale Vorbereitung als experimentelles Projekt ist abgeschlossen; zum Abschluss der lokalen Vorbereitung war noch kein Upload vorgenommen worden. Die Lizenz wurde inzwischen ausdrücklich als GPL-3.0-only festgelegt; der genannte Rechteinhaber ist Andreas Mayer. Etwaige Rechte Dritter sind vor Veröffentlichung zu klären.

## Umgesetzte Änderungen

| Änderung | Verhalten der überarbeiteten Fassung |
| --- | --- |
| HTTPS | HTTP, fremde Protokolle und URLs mit eingebetteten Zugangsdaten werden abgewiesen. Die Prüfung erfolgt auch unmittelbar an der zentralen Request-Funktion. Ohne Schema wird HTTPS ergänzt. |
| Weiterleitungen | Automatische Weiterleitungen sind deaktiviert, damit authentifizierte Anfragen nicht unbemerkt zu anderen Zielen gelangen. Die endgültige HTTPS-Adresse muss direkt eingetragen werden. |
| Löschfreigabe | Jede Vorschau beginnt mit einem leeren Kästchen „Auch … Konten löschen (nur dieser Lauf)“. Erst Häkchen plus Bestätigung geben die Löschphase dieses Laufs frei. Ohne Häkchen bleiben Anlegen und Aktualisieren möglich. Die Ausführungsfunktion benötigt ebenfalls ein ausdrückliches `AllowDeletion`; der Standard ist aus. |
| Schutzliste | Das verwendete Admin-Konto und zusätzlich eingetragene Kontonamen werden aus dem Löschplan ausgeschlossen. Kontonamen werden ohne Beachtung der Groß-/Kleinschreibung verglichen. Weitere Admin- und Dienstkonten müssen ausdrücklich eingetragen werden. Der Schutz verhindert keine Feld- oder Gruppenaktualisierungen. |
| Einstellungen | Die Schutzliste wird gespeichert, die Löschfreigabe nicht. Vorhandene Einstellungsdateien ohne Schutzliste bleiben lesbar. Einstellungsdateien bleiben vom Git-Tracking ausgeschlossen. |
| Fehler und Bedienung | Vorherige Fehler beim Anlegen oder Aktualisieren verhindern weiterhin die Löschphase, auch bei erteilter Freigabe. Eine fehlende Freigabe wird als bewusste Auslassung angezeigt. Während Export und Abgleich ist der Hauptinhalt der Oberfläche gesperrt, um parallele Bedienaktionen zu verhindern. Ungültige URLs werden als Fehlermeldung behandelt. |

Wesentliche Funktionen: `Normalize-NextcloudUrl`, `Assert-HttpsRequestUrl`, `Invoke-OcsRequest`, `New-ReconciliationPlan`, `Show-ReconciliationPreview`, `Apply-ReconciliationPlan`, `Start-Reconciliation`.

## Weiter bestehende Grenzen

- **Klartextdateien:** `Write-AccessFile` schreibt Passwörter neuer Konten weiterhin absichtlich als TXT. Besondere Dateiberechtigungen, Verschlüsselung und automatische Löschung fehlen. Einen zugriffsbeschränkten Speicherort und eine sichere Übergabe verwenden; die E-Mail-Einrichtung gesondert testen.
- **Löschumfang:** Die CSV bleibt der vollständige Sollbestand. Außerhalb der CSV liegende Konten werden bei erteilter Freigabe gelöscht, sofern sie nicht geschützt sind. Es gibt keine automatische Erkennung aller Admin-/Dienstkonten, keine Begrenzung auf verwaltete Gruppen und keinen Rollback. Backups und Testinstanz bleiben erforderlich. Fehler innerhalb der Löschphase stoppen nicht automatisch alle weiteren Löschversuche.
- **Sensible Betriebsdaten:** Einstellungen enthalten unter anderem Instanzadresse, Admin-Kontonamen, Schutzliste, CSV-Pfad und freien Ausgabetext. CSV-Dateien und Kopien können Namen, E-Mail-Adressen, Gruppen und Passwörter enthalten. Beim Bestandsexport bleiben nur die Passwortfelder leer.
- **Logs:** Reguläre Logtexte enthalten Kontonamen, Gruppen und Pfade. Server- und Ausnahmeinformationen werden ungefiltert übernommen. Keine direkte Ausgabe des Admin-Passworts in regulären Logaufrufen gefunden; sensible Angaben in fremden Fehlertexten sind nicht ausgeschlossen. Protokolle vor Weitergabe prüfen und anonymisieren.
- **Arbeitsspeicher:** Admin-Passwort, Dialog-Tag und Basic-Auth-Zwischenwerte liegen während der Verarbeitung als Strings im Speicher. Variablen werden teilweise geleert; eine sichere Speicherlöschung ist damit nicht gewährleistet. Weitere Begrenzung der Lebensdauer und Entsorgung der Dialoge bleiben mögliche Verbesserungen.

## Durchgeführte Kontrollen

Die Tests laden ausschließlich zuvor gelesene Funktionsdefinitionen aus dem Skript. Die Initialisierung der vollständigen Anwendung wurde nicht ausgeführt. Serverzugriffe und Änderungen wurden durch lokale Testfunktionen ersetzt; es wurde kein echtes Konto angelegt, geändert oder gelöscht.

Unter Windows PowerShell 5.1.26100.9711 bestanden 25 Prüfungen:

- HTTPS als Standard mit Nextcloud-Unterordner; HTTP, fremdes Protokoll, eingebettete Zugangsdaten und Abfrageparameter in der Basisadresse abgewiesen.
- HTTP auch direkt an der Request-Grenze ohne Transport gesperrt; HTTPS-Abfrageparameter für API-Anfragen zugelassen; Weiterleitungsgrenze null an den simulierten Transport übergeben.
- Schutzliste und verwendetes Admin-Konto ohne Beachtung der Groß-/Kleinschreibung vom Löschplan ausgeschlossen; neuer Plan ohne Löschfreigabe.
- Ohne Freigabe kein Löschaufruf; mit Freigabe genau der vorgesehene Löschaufruf und korrekte Zählung.
- Bei vorherigem Anlagefehler trotz Freigabe kein Löschaufruf und korrekter Fehlergrund.
- Leerer Löschplan ohne unnötige Auslassungswarnung; alte Einstellungen ohne Schutzliste erfolgreich eingelesen.

- Ohne Löschfreigabe bleiben Anlegen und Aktualisieren aktiv; auch ein Aktualisierungsfehler verhindert freigegebene Löschungen.
- Schutzliste erfolgreich gespeichert, keine Löschfreigabe in der Einstellungsdatei; Leerzeichen und doppelte Listeneinträge normalisiert.

Zusätzlich: Syntaxprüfung der geänderten Fassung unter Windows PowerShell 5.1 und PowerShell 7 ohne Fehler, Kontrolle der Beispiel-CSV und des ZIP-Inhalts. Die Git-Ausschlüsse wurden bereits bei der Erstprüfung in einem separaten lokalen Prüfverzeichnis geprüft: echte CSV-Pfade, Einstellungen, Zugangsdaten-TXT, Logs, Umgebungsdateien und Schlüssel werden ignoriert; Skript, README und Beispiel-CSV nicht. Die Ausschlussregeln wurden seither nicht geändert.

**Noch offen:** Bedienung der vollständigen Windows-Oberfläche einschließlich Häkchen und Dialogabbruch, tatsächliches Redirect-Verhalten gegen einen Testserver, Nextcloud-Version und Rechte, Mailversand und komplette Integrationsabläufe. Diese Fassung wird deshalb weiterhin als experimentell eingeordnet. Die lokale Ausführungsrichtlinie wurde nicht geändert; die Funktionsprüfungen liefen als direkte PowerShell-Befehle.

Die spätere Lizenzergänzung verändert ausschließlich Kommentare im Skript sowie die Dokumentation; der ausführbare Skriptinhalt stimmt mit der zuvor geprüften Fassung überein. Die Syntax wird erneut geprüft.

## Dateistände

SHA-256 des ursprünglichen Uploads:

```text
0C112CB478078D8D98B9FA1CCD5E0EBF0D6C5516BEC2D025B5B50CAD0BFC0A2C
```

SHA-256 der überarbeiteten Skriptdatei:

```text
CC494952F79948126DC90921E305B851EB1D5638735502903D851AE7071D4BB7
```

Die Inhaltsprüfung umfasste die vollständige ursprüngliche Datei sowie die hinzugefügten Änderungen. Ein ergänzender Musterscan suchte typische Tokens, Schlüssel, Adressen und Passwortzuweisungen; ein umfassender Geheimnisscanner wurde nicht eingesetzt. Historien, echte CSV-/Einstellungsdateien, Logs und serverseitige Inhalte waren nicht Gegenstand der Prüfung.

## Veröffentlichung

README, `.gitignore`, `.gitattributes`, künstliche Beispiel-CSV, Lizenzoptionen und Git-Anleitung sind enthalten. Die Datei `LICENSE` enthält den auf ausdrücklichen Wunsch übernommenen unveränderten englischen GPL-3.0-Standardtext. Der Skriptkopf und die README nennen GPL-3.0-only und Copyright © 2026 Andreas Mayer. Zum Abschluss der lokalen Vorbereitung war durch den Assistenten kein GitHub-Repository angelegt und kein Upload oder Push vorgenommen worden. Die spätere Übertragung in das vom Nutzer angelegte Repository erfolgt nach seiner ausdrücklichen Freigabe. Die Git-Anleitung trennt lokale Vorbereitung und die erst nach ausdrücklicher Zustimmung zulässige Veröffentlichung.

Quellen: [GitHub-Veröffentlichung](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github), [Git-Ausschlüsse](https://docs.github.com/en/get-started/git-basics/ignoring-files), [Nextcloud Provisioning API](https://docs.nextcloud.com/server/stable/admin_manual/configuration_user/user_provisioning_api.html).
