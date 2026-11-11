---
lang: de-DE
---

# Nextcloud-Benutzerkontenverwaltung

Windows-Anwendung mit grafischer Oberfläche in PowerShell zum Bearbeiten von Benutzer-CSV-Dateien und zum Verwalten von Nextcloud-Konten über die OCS Provisioning API.

**Status: experimentell.** Der Quelltext wurde statisch und in isolierten Funktionsprüfungen mit simulierten Serveraufrufen geprüft; ein vollständiger Test mit Oberfläche und Nextcloud-Instanz steht aus. Bekannte Sicherheitsgrenzen stehen im [Prüfbericht](PRUEFBERICHT.md).

## Achtung: Der Bestandsabgleich kann Konten löschen

Die CSV ist der **vollständige Sollbestand**. Auf dem Server vorhandene Konten, die in der CSV fehlen, werden als Löschkandidaten angezeigt. Gelöscht wird nur, wenn in der Vorschau das Kästchen **„Auch … Konten löschen (nur dieser Lauf)“** ausdrücklich aktiviert und anschließend der Abgleich bestätigt wird. Das Kästchen beginnt bei jeder Vorschau leer; die Freigabe wird nicht gespeichert. Ohne Häkchen führt der Abgleich ausschließlich Anlegen und Aktualisieren aus.

Das für den Lauf verwendete Administratorkonto ist immer vor Löschung geschützt. Im Hauptfenster lassen sich unter **„Vor Löschung geschützt“** weitere Kontonamen durch Kommas getrennt hinterlegen, beispielsweise `adminzwei,dienstkonto`. Diese Schutzliste wird mit den Einstellungen gespeichert. Andere Admin- und Dienstkonten werden nicht automatisch erkannt und müssen eingetragen werden. Der Schutz betrifft ausschließlich das Löschen; Daten und Gruppenzuordnungen dieser Konten können weiterhin aktualisiert werden.

Bei einer kleinen Beispiel- oder Teilmengen-CSV niemals Löschungen gegen einen produktiven Gesamtbestand freigeben. Der CSV-Export ist kein vollständiges Backup. Vor Änderungen eine wiederherstellbare Sicherung der Nextcloud-Daten und Datenbank anlegen und den Ablauf in einer getrennten Testinstanz erproben. Es gibt keinen automatischen Rollback.

## Funktionen

- CSV lokal prüfen und im Windows-Editor öffnen.
- Gruppenzuordnungen lokal bearbeiten; dafür werden Gruppennamen aus Nextcloud gelesen.
- Nextcloud-Bestand als CSV exportieren; Passwortspalten bleiben dabei leer.
- Konten anlegen, Anzeigenamen, E-Mail-Adressen und Quoten aktualisieren.
- Gruppen und Subadmin-Zuordnungen hinzufügen und entfernen.
- Für neue Konten Passwörter erzeugen oder die serverseitige E-Mail-Einrichtung verwenden.
- Für neue Konten Zugangsdaten als TXT ausgeben und Aktionen protokollieren.

Passwörter und Sprache bestehender Konten werden durch den Bestandsabgleich nicht aktualisiert. Leere Quoten lassen die bestehende Quote unverändert; leere E-Mail- und Gruppenfelder können bestehende Werte beziehungsweise Zuordnungen entfernen.

## Voraussetzungen und Start

- Windows mit Windows PowerShell 5.1 und .NET Framework/Windows Forms. PowerShell 7 wurde nicht als Laufzeit verifiziert; Linux und macOS werden nicht unterstützt.
- Eine erreichbare Nextcloud-Instanz mit verfügbarer Provisioning API und einem ausreichend berechtigten Konto.
- Eine gültige HTTPS-Adresse und ein vertrauenswürdiges Serverzertifikat.
- Schreibrechte im Skriptordner für Einstellungen, Protokolle und Ausgaben. Lokale Windows-Administratorrechte werden vom Skript nicht vorausgesetzt.

Im entpackten Projektordner starten:

```powershell
powershell.exe -NoProfile -STA -File .\nc-userkontenverwaltung.ps1
```

Bei einer Ausführungssperre gelten die lokalen beziehungsweise organisatorischen Vorgaben für PowerShell-Skripte. Eine generelle Abschaltung der Ausführungsrichtlinie ist nicht erforderlich.

## CSV-Format

UTF-8, für Windows PowerShell 5.1 vorzugsweise mit BOM. Das Trennzeichen ist ein Semikolon; mehrere Gruppen werden mit Kommas getrennt. Die sieben Spalten müssen in dieser Reihenfolge stehen:

```csv
username;displayname;password;email;groups;subadmin;quota
demo01;Beispielkonto;;demo01@example.invalid;demogruppe;;1GB
```

Eine ausschließlich erfundene Vorlage liegt in [users.example.csv](users.example.csv). Kopiere sie bei Bedarf nach `users.csv`. Beide Dateien sind nur für eine getrennte Testinstanz geeignet.

| Spalte | Bedeutung |
| --- | --- |
| `username` | Pflichtfeld, eindeutiger Kontoname |
| `displayname` | Anzeigename; leer bedeutet Kontoname |
| `password` | Nur für neue Konten; leer bedeutet gewählter Passwortmodus |
| `email` | Im E-Mail-Modus bei leerem Passwort erforderlich |
| `groups` | Vollständige gewünschte Gruppenliste |
| `subadmin` | Vollständige gewünschte Liste verwalteter Gruppen |
| `quota` | Beispielsweise `1GB`; leer verändert bestehende Quoten nicht |

Die E-Mail-Einrichtung hängt von der Nextcloud-Version und der Mailkonfiguration ab und muss separat getestet werden. Die Oberfläche bietet `de_DE` und `de` als Nextcloud-Sprachcodes für neue Konten an.

## Umgang mit sensiblen Dateien

**HTTPS ist erforderlich.** HTTP und Adressen mit eingebetteten Zugangsdaten werden vor einem Transport abgewiesen. Ohne Schema wird HTTPS ergänzt. Automatische HTTP-Weiterleitungen sind abgeschaltet; die tatsächliche HTTPS-Zieladresse der Nextcloud-Installation einschließlich eines möglichen Unterordners eintragen. Basic-Auth-Zugangsdaten werden nur kodiert; ihre Übertragung wird durch TLS geschützt.

Das Admin-Passwort wird zur Aktion abgefragt und laut geprüftem Code nicht absichtlich auf Datenträger geschrieben. Es liegt während der Verarbeitung als Klartextzeichenfolge im Speicher vor; das Leeren von Variablen garantiert keine sichere Speicherlöschung.

| Lokale Datei | Schutzbedarf |
| --- | --- |
| `nc-userkontenverwaltung.settings.json` | Enthält Instanzadresse, Admin-Kontonamen, Schutzliste, CSV-Pfad und individuellen Ausgabetext |
| CSV-Dateien und Gruppenbearbeitungs-Kopien | Personenbezogene Angaben und gegebenenfalls Klartextpasswörter |
| `output/` | Zugangsdaten-TXT mit Kontonamen und gegebenenfalls Klartextpasswörtern |
| `logs/` | Kontonamen, Gruppen, lokale Pfade und Fehlerdetails |

Die TXT-Ausgabe ist nicht verschlüsselt und setzt keine besonderen Dateiberechtigungen. Einen zugriffsbeschränkten lokalen Ordner verwenden und Zugangsdaten nach sicherer Übergabe nach dem eigenen Löschkonzept entfernen. Protokolle vor Weitergabe manuell anonymisieren; ungefilterte Serverfehlermeldungen können sensible Angaben enthalten.

Die mitgelieferte `.gitignore` schließt diese Betriebsdaten sowie alle CSV-Dateien außer der Beispielvorlage aus. Sie ersetzt keine Inhaltskontrolle und schützt weder bereits verfolgte Dateien noch Dateien, die über die GitHub-Weboberfläche hochgeladen werden.

## Veröffentlichung und Lizenz

Die Anleitung [VEROEFFENTLICHEN.md](VEROEFFENTLICHEN.md) enthält die lokalen Git-Schritte und einen getrennten Veröffentlichungsschritt. Die Dateien werden nur nach ausdrücklicher Freigabe in das gewünschte GitHub-Repository übertragen.

Copyright © 2026 Andreas Mayer. Das Projekt steht unter der **GNU General Public License, Version 3** (`GPL-3.0-only`). Der vollständige, unveränderte englische Lizenztext steht in [LICENSE](LICENSE); die Verwendung dieses englischen Standardtextes wurde ausdrücklich bestätigt.

Du darfst das Programm verwenden, verändern und weitergeben, auch kommerziell. Bei Weitergabe bearbeiteter Fassungen gelten insbesondere die GPL-Pflichten zur Bereitstellung des entsprechenden Quellcodes und zur Erhaltung der Lizenz- und Urheberrechtshinweise. Rein private Änderungen müssen nicht veröffentlicht werden. Das Programm wird ohne Gewährleistung bereitgestellt, soweit gesetzlich zulässig. Maßgeblich ist der vollständige Lizenztext.

Die dokumentierte Entscheidung und ergänzende Hinweise stehen in [LIZENZOPTIONEN.md](LIZENZOPTIONEN.md). Etwaige Rechte Dritter oder Vorgaben eines Arbeitgebers müssen vor Veröffentlichung geklärt sein.

## Quellen

- [Nextcloud: Provisioning API](https://docs.nextcloud.com/server/stable/admin_manual/configuration_user/user_provisioning_api.html)
- [Nextcloud: Benutzer-Endpunkte](https://docs.nextcloud.com/server/stable/admin_manual/configuration_user/instruction_set_for_users.html)
- [GitHub: Dateien ignorieren](https://docs.github.com/en/get-started/git-basics/ignoring-files)
