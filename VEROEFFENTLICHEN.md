---
lang: de-DE
---

# GitHub-Veröffentlichung vorbereiten

Stand: 11. November 2026. Diese Anleitung beschreibt die lokalen Git-Schritte und den getrennten Upload. Als Ziel wurde `andreasmayerbw/nc-userkontenverwaltung` angegeben. Die folgende lokale Vorbereitung überträgt keine Dateien zu GitHub.

## 1. Entscheidungen und Vorbereitung

Vorgeschlagener Repository-Name: `nc-userkontenverwaltung`.

Beschreibung: „Grafische Nextcloud-Benutzerverwaltung mit Windows PowerShell, CSV-Import, Export und Bestandsabgleich.“

Das Paket enthält eine überarbeitete Fassung: HTTPS wird erzwungen, Löschungen brauchen eine gesonderte Freigabe pro Lauf, und weitere Konten lassen sich gezielt vor Löschung schützen. Die geänderten Funktionen wurden mit simulierten Serverantworten geprüft; ein vollständiger Test mit Nextcloud und Bedienung der Oberfläche steht aus. Für eine Veröffentlichung als experimentellen Quelltext die bekannten Grenzen deutlich beibehalten; Details im Prüfbericht.

Lizenz und Rechteinhaber sind festgelegt: **GPL-3.0-only**, Copyright © 2026 Andreas Mayer. `LICENSE` enthält den unveränderten englischen Standardtext. Repository-Eigentümer und Sichtbarkeit noch bestimmen. Ein privates Repository beschränkt die Sichtbarkeit, ersetzt aber nicht das Entfernen sensibler Inhalte.

Das ZIP zunächst in einen **neuen, eigenen Projektordner** entpacken. Nicht im übergeordneten Dokumente-Ordner und nicht in einem bestehenden Arbeitsrepository beginnen. Keine echten CSV-, Einstellungs-, Log- oder Zugangsdaten-Dateien hinein kopieren.

## 2. Nur lokal vorbereiten

PowerShell im entpackten Projektordner öffnen. `git --version` prüft, ob Git installiert ist. Die folgenden Befehle sind für einen neuen Projektordner ohne vorhandenes Git-Repository gedacht:

```powershell
git init -b main
git status --short --untracked-files=all
git check-ignore --no-index users.csv nc-userkontenverwaltung.settings.json output/demo01.txt logs/Nextcloud-Benutzerverwaltung.log
```

Beim letzten Befehl sollten alle vier Pfade erscheinen. Nur die künstliche Beispiel-CSV darf aufgenommen werden. Git muss außerdem keine echte CSV an anderer Stelle kennen.

Für einen Commit verwendet Git einen Namen und eine E-Mail-Adresse; diese können später öffentlich sichtbar sein. Bei Bedarf die in den GitHub-Kontoeinstellungen angezeigte persönliche No-Reply-Adresse verwenden. Die folgenden Werte vor Ausführung ersetzen:

```powershell
git config --local user.name 'DEIN ANZEIGENAME'
git config --local user.email 'DEINE GITHUB-NO-REPLY-ADRESSE'
```

Dateien gezielt vormerken, dann den vollständigen Inhalt kontrollieren:

```powershell
git add -- .gitignore .gitattributes nc-userkontenverwaltung.ps1 _START_nc-userkontenverwaltung-starten.vbs README.md users.example.csv PRUEFBERICHT.md LIZENZOPTIONEN.md VEROEFFENTLICHEN.md LICENSE
git diff --cached --name-only
git diff --cached --check
git diff --cached
```

Es dürfen ausschließlich die zehn genannten Projektdateien erscheinen. Jede Datei inhaltlich prüfen, insbesondere Kommentare und Beispiele. Anschließend lokal speichern:

```powershell
git commit -m 'Erste dokumentierte Fassung der Nextcloud-Benutzerverwaltung'
git status --short
git log -1 --format=fuller
```

`git status --short` sollte leer sein. `git log` zeigt unter anderem die Commit-Identität; sie vor der Veröffentlichung kontrollieren. Falls Git einen Fehler meldet, vor dem nächsten Schritt beheben. Bis hier wurde nichts hochgeladen.

## 3. Erst nach ausdrücklicher Zustimmung veröffentlichen

Dieser Abschnitt ist eine Anleitung und keine Freigabe zur Ausführung durch den Assistenten. Vor einer Ausführung durch den Assistenten sind eine ausdrückliche Zustimmung, der Eigentümer, der Repository-Name und die gewünschte Sichtbarkeit erforderlich.

Nach dieser Entscheidung auf GitHub ein **leeres** Repository anlegen: README, `.gitignore` und Lizenz dort nicht automatisch erzeugen lassen, weil diese lokal vorbereitet werden. Die Anzeige „Public“ macht den hochgeladenen Inhalt öffentlich sichtbar. Falls bereits ein Repository mit Inhalt existiert, diese Neuanlage-Anleitung nicht unverändert verwenden und keinen Force-Push ausführen.

Die folgende URL verweist auf das vom Nutzer genannte Zielrepository. Keine Tokens oder Passwörter in die URL schreiben. Für die Anmeldung Git Credential Manager oder eine vorhandene SSH-Einrichtung nutzen.

```powershell
git remote add origin https://github.com/andreasmayerbw/nc-userkontenverwaltung.git
git remote -v
git push -u origin main
```

**Der letzte Befehl überträgt die Dateien zu GitHub.** Er darf erst nach der Freigabe ausgeführt werden. Danach auf GitHub die Dateiliste, README, Sichtbarkeit und Lizenz kontrollieren. Die Beispiel-CSV bleibt ein reines Testszenario.

## Falls versehentlich sensible Daten aufgenommen wurden

`.gitignore` entfernt keine bereits verfolgten Dateien und bereinigt keine Historie. Vor dem ersten Commit können versehentlich vorgemerkte Dateien gezielt wieder aus der Vormerkliste genommen werden. Bereits gespeicherte oder hochgeladene Geheimnisse erfordern eine gesonderte Prüfung der gesamten Historie; ein späterer Lösch-Commit genügt nicht. Betroffene Zugangsdaten bei Offenlegung sperren beziehungsweise erneuern und die GitHub-Anleitung zur Bereinigung verwenden. Keine echten Protokolle ungeprüft in Issues anhängen.

Quellen:

- [GitHub: lokalen Code hinzufügen](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)
- [GitHub: Dateien ignorieren](https://docs.github.com/en/get-started/git-basics/ignoring-files)
- [GitHub: sensible Daten entfernen](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
