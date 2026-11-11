#requires -version 5.1
<#
SPDX-License-Identifier: GPL-3.0-only
Copyright (C) 2026 Andreas Mayer

Dieses Programm darf unter den Bedingungen der GNU General Public License,
Version 3, weitergegeben und verändert werden. Es wird ohne Gewährleistung
bereitgestellt, soweit gesetzlich zulässig. Der vollständige Lizenztext
befindet sich in der mitgelieferten Datei LICENSE.

Überarbeitet am 11.11.2026: HTTPS-Pflicht, Löschfreigabe je Lauf,
Schutzliste und zugehörige Bedienhinweise ergänzt.

Nextcloud Benutzerverwaltung - reine PowerShell-Version
========================================================

Funktionen:
- Benutzer aus einer CSV-Datei anlegen
- bei leerem Passwort wahlweise:
    * kryptographisch sicheres Passwort erzeugen
    * Nextcloud-Willkommensmail zum Setzen des Passworts verwenden
- Gruppen bei Bedarf anlegen und Benutzer zuordnen
- Subadmin-Gruppen zuweisen
- pro neu angelegtem Benutzer eine TXT-Datei mit Zugangsdaten erzeugen
- konfigurierbarer Text in jeder Zugangsdaten-Datei
- keine Python-Installation, keine EXE, keine PDF-/QR-Code-Bibliotheken
- Admin-Passwort wird niemals gespeichert
- Bestandsabgleich mit Vorschau und zusätzlicher Löschfreigabe je Lauf
- zusätzliche Schutzliste für Konten, die nicht gelöscht werden dürfen
- ausschließlich HTTPS, keine automatischen Weiterleitungen

CSV-Format:
username;displayname;password;email;groups;subadmin;quota

Technische Grundlage:
Nextcloud Provisioning API:
- POST /ocs/v1.php/cloud/users
- POST /ocs/v1.php/cloud/groups
- POST /ocs/v1.php/cloud/users/{userid}/groups
- POST /ocs/v1.php/cloud/users/{userid}/subadmins

Das CSV-Trennzeichen ist fest ";".
Mehrere Gruppen werden mit "," getrennt.
TLS-Zertifikate werden normal geprüft.
#>

Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Für ältere Windows-PowerShell/.NET-Framework-Installationen TLS 1.2 sicherstellen.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SettingsFile = Join-Path $script:AppDir "nc-userkontenverwaltung.settings.json"
$script:OutputDir = Join-Path $script:AppDir "output"
$script:LogDir = Join-Path $script:AppDir "logs"
$script:LogFile = Join-Path $script:LogDir "Nextcloud-Benutzerverwaltung.log"

$script:CsvDelimiter = ";"
$script:GroupDelimiter = ","

$script:DefaultOutputText = @"
Willkommen bei unserer Nextcloud.

Bitte bewahren Sie Ihre Zugangsdaten sicher auf.
"@

$script:OutputText = $script:DefaultOutputText
$script:Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

# --------------------------------------------------------------------
# Allgemeine Helfer
# --------------------------------------------------------------------

function Show-Info {
    param(
        [string]$Message,
        [string]$Title = "Hinweis"
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-Warn {
    param(
        [string]$Message,
        [string]$Title = "Achtung"
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Show-ErrorBox {
    param(
        [string]$Message,
        [string]$Title = "Fehler"
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Write-Log {
    param(
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $script:LogDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    $line = "{0:yyyy-MM-dd HH:mm:ss} - {1} - {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function New-Label {
    param([string]$Text)

    $c = New-Object System.Windows.Forms.Label
    $c.Text = $Text
    $c.AutoSize = $true
    $c.Anchor = "Left"
    $c.Margin = New-Object System.Windows.Forms.Padding(3,7,8,2)
    return $c
}

function New-TextBox {
    $c = New-Object System.Windows.Forms.TextBox
    $c.Dock = "Fill"
    $c.Margin = New-Object System.Windows.Forms.Padding(3,3,3,3)
    return $c
}

function New-Combo {
    param([string[]]$Items)

    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $c.Margin = New-Object System.Windows.Forms.Padding(3,3,3,3)

    foreach ($item in $Items) {
        [void]$c.Items.Add($item)
    }

    return $c
}

function New-Button {
    param([string]$Text)

    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.Padding = New-Object System.Windows.Forms.Padding(7,2,7,2)
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    return $b
}

function Add-FormRow {
    param(
        [System.Windows.Forms.TableLayoutPanel]$Table,
        [string]$LabelText,
        [System.Windows.Forms.Control]$Control
    )

    $row = $Table.RowCount
    $Table.RowCount++

    $Table.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle(
            [System.Windows.Forms.SizeType]::AutoSize
        ))
    )

    $Table.Controls.Add((New-Label $LabelText), 0, $row)
    $Table.Controls.Add($Control, 1, $row)
}

function Set-ComboText {
    param(
        [System.Windows.Forms.ComboBox]$Combo,
        [string]$Value
    )

    $index = $Combo.Items.IndexOf($Value)

    if ($index -ge 0) {
        $Combo.SelectedIndex = $index
    }
    elseif ($Combo.Items.Count -gt 0) {
        $Combo.SelectedIndex = 0
    }
}

function Open-Path {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Show-Warn "Pfad nicht gefunden:`r`n$Path"
        return
    }

    Start-Process -FilePath $Path
}

function Open-TextFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Show-Warn "Datei nicht gefunden:`r`n$Path"
        return
    }

    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$Path`""
}

function Normalize-NextcloudUrl {
    param([string]$Url)

    $value = $Url.Trim()

    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "https://" + $value
    }

    Assert-HttpsRequestUrl $value
    $uri = [uri]$value
    if ($uri.Query -or $uri.Fragment) {
        throw "Die Nextcloud-Adresse darf keine Abfrageparameter oder Sprungmarke enthalten."
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Assert-HttpsRequestUrl {
    param([string]$Url)

    $uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne "https" -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or $uri.Fragment) {
        throw "Bitte eine gültige HTTPS-Adresse ohne eingebettete Zugangsdaten verwenden."
    }
}

function Get-SafeFileName {
    param([string]$Value)

    $result = $Value

    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $result = $result.Replace([string]$char, "_")
    }

    if ([string]::IsNullOrWhiteSpace($result)) {
        return "benutzer"
    }

    return $result
}

# --------------------------------------------------------------------
# Einstellungen
# --------------------------------------------------------------------

function Get-DefaultSettings {
    return [pscustomobject]@{
        NextcloudUrl   = ""
        AdminName      = ""
        ProtectedUsers = ""
        CsvFile        = "users.csv"
        PasswordMode   = "generate"
        PasswordLength = "12"
        Language       = "de_DE"
        OutputText     = $script:DefaultOutputText
    }
}

function Load-Settings {
    $defaults = Get-DefaultSettings

    if (-not (Test-Path -LiteralPath $script:SettingsFile -PathType Leaf)) {
        return $defaults
    }

    try {
        $loaded = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 |
            ConvertFrom-Json

        # Bewusst kein Admin-Passwort laden oder unterstützen.
        return [pscustomobject]@{
            NextcloudUrl   = if ($null -ne $loaded.NextcloudUrl)   { [string]$loaded.NextcloudUrl }   else { $defaults.NextcloudUrl }
            AdminName      = if ($null -ne $loaded.AdminName)      { [string]$loaded.AdminName }      else { $defaults.AdminName }
            ProtectedUsers = if ($null -ne $loaded.PSObject.Properties["ProtectedUsers"]) { [string]$loaded.ProtectedUsers } else { $defaults.ProtectedUsers }
            CsvFile        = if ($null -ne $loaded.CsvFile)        { [string]$loaded.CsvFile }        else { $defaults.CsvFile }
            PasswordMode   = if ($null -ne $loaded.PasswordMode)   { [string]$loaded.PasswordMode }   else { $defaults.PasswordMode }
            PasswordLength = if ($null -ne $loaded.PasswordLength) { [string]$loaded.PasswordLength } else { $defaults.PasswordLength }
            Language       = if ($null -ne $loaded.Language)       { [string]$loaded.Language }       else { $defaults.Language }
            OutputText     = if ($null -ne $loaded.OutputText)     { [string]$loaded.OutputText }     else { $defaults.OutputText }
        }
    }
    catch {
        Write-Log "WARN" "Einstellungsdatei konnte nicht gelesen werden. Standardwerte werden verwendet."
        return $defaults
    }
}

function Get-SelectedLanguageCode {
    if ($cbLanguage.SelectedIndex -eq 1) {
        return "de"
    }

    return "de_DE"
}

function Request-AdminPassword {
    param(
        [string]$Purpose = "Nextcloud-Zugriff"
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Admin-Passwort erforderlich"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(600,320)
    $dialog.MinimumSize = New-Object System.Drawing.Size(560,300)
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI",10)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.Padding = New-Object System.Windows.Forms.Padding(12)
    $layout.ColumnCount = 1
    $layout.RowCount = 4

    [void]$layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    [void]$layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    [void]$layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    [void]$layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )

    [void]$dialog.Controls.Add($layout)

    $info = New-Object System.Windows.Forms.Label
    $info.AutoSize = $true
    $info.MaximumSize = New-Object System.Drawing.Size(540,0)
    $info.Text = (
        $Purpose + "`r`n`r`n" +
        "Admin-Benutzer: " + $txtAdmin.Text.Trim() + "`r`n" +
        "Das Passwort wird nur für diese Aktion im Arbeitsspeicher verwendet und nicht gespeichert."
    )

    $passwordPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $passwordPanel.Dock = "Fill"
    $passwordPanel.AutoSize = $true
    $passwordPanel.ColumnCount = 2

    [void]$passwordPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100))
    )
    [void]$passwordPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))
    )

    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Dock = "Fill"
    $passwordBox.UseSystemPasswordChar = $true

    $showPassword = New-Object System.Windows.Forms.CheckBox
    $showPassword.Text = "anzeigen"
    $showPassword.AutoSize = $true
    $showPassword.Margin = New-Object System.Windows.Forms.Padding(8,5,0,0)

    [void]$passwordPanel.Controls.Add($passwordBox,0,0)
    [void]$passwordPanel.Controls.Add($showPassword,1,0)

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.MaximumSize = New-Object System.Drawing.Size(540,0)
    $hint.Text = "Das Passwort wird nach dem Schließen dieses Dialogs nicht in der GUI angezeigt."

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = "Fill"
    $buttons.AutoSize = $true
    $buttons.FlowDirection = "RightToLeft"
    $buttons.Margin = New-Object System.Windows.Forms.Padding(0,12,0,0)

    $ok = New-Button "Weiter"
    $cancel = New-Button "Abbrechen"

    $buttons.Controls.AddRange(@($ok,$cancel))

    [void]$layout.Controls.Add($info,0,0)
    [void]$layout.Controls.Add($passwordPanel,0,1)
    [void]$layout.Controls.Add($hint,0,2)
    [void]$layout.Controls.Add($buttons,0,3)

    $showPassword.Add_CheckedChanged({
        $passwordBox.UseSystemPasswordChar = -not $showPassword.Checked
    })

    $ok.Add_Click({
        if ([string]::IsNullOrWhiteSpace($passwordBox.Text)) {
            Show-Warn "Bitte das Admin-Passwort eingeben." "Admin-Passwort"
            [void]$passwordBox.Focus()
            return
        }

        $dialog.Tag = [string]$passwordBox.Text
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $cancel.Add_Click({
        $dialog.Tag = $null
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    $dialog.Add_Shown({
        [void]$passwordBox.Focus()
    })

    $dialogResult = $dialog.ShowDialog($form)

    # Wichtig: Diese Funktion darf genau EINEN Wert liefern:
    # entweder das Passwort als String oder $null.
    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $password = [string]$dialog.Tag
        return $password
    }

    return $null
}


function Save-Settings {
    try {
        $data = [pscustomobject]@{
            NextcloudUrl   = Normalize-NextcloudUrl $txtCloud.Text
            AdminName      = $txtAdmin.Text.Trim()
            ProtectedUsers = $txtProtectedUsers.Text.Trim()
            CsvFile        = $txtCsv.Text.Trim()
            PasswordMode   = if ($cbPasswordMode.SelectedIndex -eq 1) { "email" } else { "generate" }
            PasswordLength = $cbPasswordLength.Text
            Language       = Get-SelectedLanguageCode
            OutputText     = $script:OutputText
        }

        $data |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8

        $statusLabel.Text = "Einstellungen gespeichert."
        return $true
    }
    catch {
        Show-ErrorBox (
            "Die Einstellungen konnten nicht gespeichert werden.`r`n`r`n" +
            $_.Exception.Message
        )
        return $false
    }
}

# --------------------------------------------------------------------
# Sichere Passworterzeugung
# --------------------------------------------------------------------

function Get-CryptoRandomInt {
    param(
        [Parameter(Mandatory=$true)]
        [int]$MaxExclusive
    )

    if ($MaxExclusive -le 0) {
        throw "MaxExclusive muss größer als 0 sein."
    }

    $bytes = New-Object byte[] 4
    $range = [uint64]([uint64][uint32]::MaxValue + 1)
    $limit = $range - ($range % [uint64]$MaxExclusive)

    do {
        $script:Rng.GetBytes($bytes)
        $value = [uint64][System.BitConverter]::ToUInt32($bytes, 0)
    }
    while ($value -ge $limit)

    return [int]($value % [uint64]$MaxExclusive)
}

function Get-SecurePassword {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateRange(8,128)]
        [int]$Length
    )

    # Vermeidet leicht verwechselbare Zeichen wie O/0 und l/1.
    $upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower   = "abcdefghijkmnopqrstuvwxyz"
    $digits  = "23456789"
    $symbols = "!#$%&*+-=?@"
    $all     = $upper + $lower + $digits + $symbols

    $chars = New-Object 'System.Collections.Generic.List[char]'

    # Je mindestens ein Zeichen jeder Kategorie.
    $chars.Add($upper[(Get-CryptoRandomInt $upper.Length)])
    $chars.Add($lower[(Get-CryptoRandomInt $lower.Length)])
    $chars.Add($digits[(Get-CryptoRandomInt $digits.Length)])
    $chars.Add($symbols[(Get-CryptoRandomInt $symbols.Length)])

    while ($chars.Count -lt $Length) {
        $chars.Add($all[(Get-CryptoRandomInt $all.Length)])
    }

    # Kryptographisch zufälliges Fisher-Yates-Shuffle.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-CryptoRandomInt ($i + 1)
        $temp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $temp
    }

    return -join $chars
}

# --------------------------------------------------------------------
# CSV
# --------------------------------------------------------------------

function Get-CurrentCsvPath {
    $value = $txtCsv.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($value)) {
        return $value
    }

    return Join-Path $script:AppDir $value
}

function Select-CsvFile {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "CSV-Datei auswählen"
    $dialog.Filter = "CSV-Dateien (*.csv)|*.csv|Alle Dateien (*.*)|*.*"
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $dialog.Multiselect = $false
    $dialog.RestoreDirectory = $true

    $current = Get-CurrentCsvPath

    if ($current -and (Test-Path -LiteralPath $current -PathType Leaf)) {
        $dialog.InitialDirectory = Split-Path -Parent $current
        $dialog.FileName = Split-Path -Leaf $current
    }
    else {
        $dialog.InitialDirectory = $script:AppDir
    }

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    $selected = $dialog.FileName
    $selectedDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $selected)).TrimEnd('\')
    $appDirFull = [System.IO.Path]::GetFullPath($script:AppDir).TrimEnd('\')

    if ($selectedDir -ieq $appDirFull) {
        $txtCsv.Text = Split-Path -Leaf $selected
    }
    else {
        $txtCsv.Text = $selected
    }

    $statusLabel.Text = "CSV-Datei ausgewählt."
}

function Read-AndValidateCsv {
    param([bool]$ShowSuccess = $false)

    $csvPath = Get-CurrentCsvPath

    if (-not $csvPath -or -not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        throw "CSV-Datei nicht gefunden: $csvPath"
    }

    $firstLine = Get-Content -LiteralPath $csvPath -Encoding UTF8 -TotalCount 1

    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        throw "Die CSV-Datei ist leer."
    }

    $expectedHeaders = @(
        "username",
        "displayname",
        "password",
        "email",
        "groups",
        "subadmin",
        "quota"
    )

    $actualHeaders = @(
        $firstLine.Split([char]$script:CsvDelimiter) |
            ForEach-Object { $_.Trim().Trim('"') }
    )

    if ($actualHeaders.Count -ne $expectedHeaders.Count) {
        throw (
            "Die CSV-Kopfzeile muss genau diese sieben Spalten enthalten:`r`n" +
            ($expectedHeaders -join ";")
        )
    }

    for ($i = 0; $i -lt $expectedHeaders.Count; $i++) {
        if ($actualHeaders[$i].ToLowerInvariant() -ne $expectedHeaders[$i]) {
            throw (
                "Ungültige CSV-Kopfzeile.`r`n`r`nErwartet:`r`n" +
                ($expectedHeaders -join ";")
            )
        }
    }

    $rows = @(
        Import-Csv -LiteralPath $csvPath -Delimiter ([char]$script:CsvDelimiter) -Encoding UTF8
    )

    if ($rows.Count -eq 0) {
        throw "Die CSV enthält keine Benutzerzeilen."
    }

    $emptyUsers = @(
        $rows |
            Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.username)
            }
    )

    if ($emptyUsers.Count -gt 0) {
        throw "Mindestens eine CSV-Zeile enthält keinen Benutzernamen."
    }

    $duplicates = @(
        $rows |
            Group-Object {
                ([string]$_.username).Trim().ToLowerInvariant()
            } |
            Where-Object Count -gt 1
    )

    if ($duplicates.Count -gt 0) {
        $names = @(
            $duplicates |
                ForEach-Object { $_.Group[0].username }
        )

        throw (
            "Doppelte Benutzernamen gefunden:`r`n" +
            ($names -join "`r`n")
        )
    }

    $emailMode = ($cbPasswordMode.SelectedIndex -eq 1)

    foreach ($row in $rows) {
        $username = ([string]$row.username).Trim()
        $email = ([string]$row.email).Trim()
        $csvPassword = [string]$row.password

        if ($emailMode -and [string]::IsNullOrWhiteSpace($csvPassword) -and [string]::IsNullOrWhiteSpace($email)) {
            throw (
                "Beim Benutzer '$username' ist das Passwort leer und es wurde die E-Mail-Variante gewählt, " +
                "aber es ist keine E-Mail-Adresse eingetragen."
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($email)) {
            try {
                [void](New-Object System.Net.Mail.MailAddress($email))
            }
            catch {
                throw "Ungültige E-Mail-Adresse bei '$username': $email"
            }
        }
    }

    if ($ShowSuccess) {
        Show-Info (
            "CSV-Prüfung erfolgreich.`r`n`r`n" +
            "Benutzer: $($rows.Count)`r`n" +
            "Datei: $csvPath"
        ) "CSV-Prüfung"
    }

    return $rows
}

# --------------------------------------------------------------------
# Nextcloud OCS Provisioning API
# --------------------------------------------------------------------

function New-BasicAuthHeaders {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AdminName,

        [Parameter(Mandatory=$true)]
        [string]$AdminPassword
    )

    $raw = $AdminName + ":" + $AdminPassword
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $token = [Convert]::ToBase64String($bytes)

    return @{
        Authorization    = "Basic $token"
        "OCS-APIRequest" = "true"
        Accept           = "application/xml"
    }
}

function Invoke-OcsRequest {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("GET","POST","PUT","DELETE")]
        [string]$Method,

        [Parameter(Mandatory=$true)]
        [string]$Url,

        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,

        [hashtable]$Body
    )

    try {
        Assert-HttpsRequestUrl $Url
        $parameters = @{
            Uri             = $Url
            Method          = $Method
            Headers         = $Headers
            UseBasicParsing = $true
            ErrorAction     = "Stop"
            MaximumRedirection = 0
        }

        if ($null -ne $Body) {
            $parameters["Body"] = $Body
            $parameters["ContentType"] = "application/x-www-form-urlencoded"
        }

        $response = Invoke-WebRequest @parameters
        [xml]$xml = $response.Content

        $codeText = [string]$xml.ocs.meta.statuscode
        $message = [string]$xml.ocs.meta.message
        $status = [string]$xml.ocs.meta.status

        $code = 0
        [void][int]::TryParse($codeText, [ref]$code)

        return [pscustomobject]@{
            TransportSuccess = $true
            Success          = ($code -eq 100 -and $status -eq "ok")
            StatusCode       = $code
            Message          = $message
            Xml              = $xml
        }
    }
    catch {
        return [pscustomobject]@{
            TransportSuccess = $false
            Success          = $false
            StatusCode       = 0
            Message          = $_.Exception.Message
            Xml              = $null
        }
    }
}

function Get-ApiBaseUrl {
    param([string]$NextcloudUrl)

    return (Normalize-NextcloudUrl $NextcloudUrl) + "/ocs/v1.php/cloud"
}

function Test-NextcloudConnection {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers
    )

    $result = Invoke-OcsRequest `
        -Method GET `
        -Url ($BaseUrl + "/users?limit=1") `
        -Headers $Headers

    if (-not $result.TransportSuccess) {
        throw (
            "Nextcloud konnte nicht erreicht werden oder die Anmeldung ist fehlgeschlagen.`r`n`r`n" +
            $result.Message
        )
    }

    if (-not $result.Success) {
        throw (
            "Nextcloud hat die Anfrage abgelehnt.`r`n" +
            "OCS-Status: $($result.StatusCode)`r`n" +
            $result.Message
        )
    }
}

function Ensure-NextcloudGroup {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$GroupName
    )

    if ([string]::IsNullOrWhiteSpace($GroupName)) {
        return
    }

    $result = Invoke-OcsRequest `
        -Method POST `
        -Url ($BaseUrl + "/groups") `
        -Headers $Headers `
        -Body @{ groupid = $GroupName }

    # 100 = neu angelegt, 102 = existiert bereits.
    # Bei Erfolg bewusst keinen Wert in die Pipeline schreiben.
    if ($result.Success -or $result.StatusCode -eq 102) {
        return
    }

    throw (
        "Gruppe '$GroupName' konnte nicht angelegt/geprüft werden. " +
        "OCS-Status $($result.StatusCode): $($result.Message)"
    )
}

function Add-UserToNextcloudGroup {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username,
        [string]$GroupName
    )

    [void](Ensure-NextcloudGroup -BaseUrl $BaseUrl -Headers $Headers -GroupName $GroupName)

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method POST `
        -Url ($BaseUrl + "/users/" + $encodedUser + "/groups") `
        -Headers $Headers `
        -Body @{ groupid = $GroupName }

    if (-not $result.Success) {
        throw (
            "Benutzer '$Username' konnte nicht der Gruppe '$GroupName' zugeordnet werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }
}

function Add-UserAsSubadmin {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username,
        [string]$GroupName
    )

    [void](Ensure-NextcloudGroup -BaseUrl $BaseUrl -Headers $Headers -GroupName $GroupName)

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method POST `
        -Url ($BaseUrl + "/users/" + $encodedUser + "/subadmins") `
        -Headers $Headers `
        -Body @{ groupid = $GroupName }

    if (-not $result.Success) {
        throw (
            "Benutzer '$Username' konnte nicht zum Subadmin der Gruppe '$GroupName' gemacht werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }
}

function New-NextcloudUser {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username,
        [string]$DisplayName,
        [string]$Password,
        [string]$Email,
        [string]$Quota,
        [string]$Language
    )

    $body = @{
        userid      = $Username
        password    = $Password
        displayName = $DisplayName
        language    = $Language
    }

    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        $body["email"] = $Email
    }

    if (-not [string]::IsNullOrWhiteSpace($Quota)) {
        $body["quota"] = $Quota
    }

    return Invoke-OcsRequest `
        -Method POST `
        -Url ($BaseUrl + "/users") `
        -Headers $Headers `
        -Body $body
}


# --------------------------------------------------------------------
# Soll-Ist-Abgleich
# --------------------------------------------------------------------

function Split-GroupList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value.Split([char]$script:GroupDelimiter) |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Get-AllNextcloudUsers {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers
    )

    # Normales PowerShell-Array statt Generic List.
    # Das ist unter Windows PowerShell 5.1 robuster.
    $all = @()
    $limit = 500
    $offset = 0

    while ($true) {
        $result = Invoke-OcsRequest `
            -Method GET `
            -Url ($BaseUrl + "/users?limit=$limit&offset=$offset") `
            -Headers $Headers

        if (-not $result.TransportSuccess -or -not $result.Success) {
            throw (
                "Die Benutzerliste konnte nicht aus Nextcloud geladen werden. " +
                "OCS-Status $($result.StatusCode): $($result.Message)"
            )
        }

        $page = @()

        $userNodes = $result.Xml.SelectNodes("/ocs/data/users/element")

        if ($null -ne $userNodes) {
            $page = @(
                $userNodes |
                    ForEach-Object { ([string]$_.InnerText).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }

        foreach ($username in $page) {
            $all += [string]$username
        }

        if ($page.Count -lt $limit) {
            break
        }

        $offset += $limit
    }

    return $all
}

function Get-AllNextcloudGroups {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers
    )

    $all = @()
    $limit = 500
    $offset = 0

    while ($true) {
        $result = Invoke-OcsRequest `
            -Method GET `
            -Url ($BaseUrl + "/groups?limit=$limit&offset=$offset") `
            -Headers $Headers

        if (-not $result.TransportSuccess -or -not $result.Success) {
            throw (
                "Die Gruppenliste konnte nicht aus Nextcloud geladen werden. " +
                "OCS-Status $($result.StatusCode): $($result.Message)"
            )
        }

        $page = @()
        $groupNodes = $result.Xml.SelectNodes("/ocs/data/groups/element")

        if ($null -ne $groupNodes) {
            $page = @(
                $groupNodes |
                    ForEach-Object { ([string]$_.InnerText).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }

        foreach ($group in $page) {
            $all += [string]$group
        }

        if ($page.Count -lt $limit) {
            break
        }

        $offset += $limit
    }

    return @(
        $all |
            Sort-Object -Unique
    )
}

function Convert-QuotaToComparable {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $v = $Value.Trim()
    $compact = ($v -replace '\s','').ToUpperInvariant()

    # Reine Byte-Zahl, wie sie Nextcloud häufig in der API zurückliefert.
    if ($compact -match '^\d+$') {
        return "BYTES:" + ([int64]$compact).ToString()
    }

    if ($compact -match '^([0-9]+(?:[\.,][0-9]+)?)(B|KB|MB|GB|TB)$') {
        $numberText = $matches[1].Replace(',', '.')
        $number = [double]::Parse(
            $numberText,
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        $factor = switch ($matches[2]) {
            "B"  { [double]1 }
            "KB" { [double]1024 }
            "MB" { [double](1024 * 1024) }
            "GB" { [double](1024 * 1024 * 1024) }
            "TB" { [double](1024 * 1024 * 1024 * 1024) }
        }

        $bytes = [int64][Math]::Round($number * $factor)
        return "BYTES:" + $bytes.ToString()
    }

    return "TEXT:" + $compact
}

function Get-QuotaFromUserData {
    param([System.Xml.XmlElement]$DataNode)

    if ($null -eq $DataNode) {
        return ""
    }

    $quotaNode = $DataNode.SelectSingleNode("quota")

    if ($null -eq $quotaNode) {
        return ""
    }

    # Neuere Nextcloud-Versionen liefern quota teils strukturiert.
    $configuredNode = $quotaNode.SelectSingleNode("quota")

    if ($null -ne $configuredNode -and -not [string]::IsNullOrWhiteSpace($configuredNode.InnerText)) {
        return $configuredNode.InnerText.Trim()
    }

    return $quotaNode.InnerText.Trim()
}

function Get-NextcloudUserState {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username
    )

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method GET `
        -Url ($BaseUrl + "/users/" + $encodedUser) `
        -Headers $Headers

    if (-not $result.TransportSuccess -or -not $result.Success) {
        throw (
            "Benutzerdaten für '$Username' konnten nicht geladen werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }

    $data = $result.Xml.ocs.data

    $groups = @()

    $groupNodes = $result.Xml.SelectNodes("/ocs/data/groups/element")

    if ($null -ne $groupNodes) {
        $groups = @(
            $groupNodes |
                ForEach-Object { ([string]$_.InnerText).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }

    $subResult = Invoke-OcsRequest `
        -Method GET `
        -Url ($BaseUrl + "/users/" + $encodedUser + "/subadmins") `
        -Headers $Headers

    if (-not $subResult.TransportSuccess -or -not $subResult.Success) {
        throw (
            "Subadmin-Gruppen für '$Username' konnten nicht geladen werden. " +
            "OCS-Status $($subResult.StatusCode): $($subResult.Message)"
        )
    }

    $subadmins = @()

    $subadminNodes = $subResult.Xml.SelectNodes("/ocs/data/element")

    if ($null -ne $subadminNodes) {
        $subadmins = @(
            $subadminNodes |
                ForEach-Object { ([string]$_.InnerText).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
    }

    return [pscustomobject]@{
        Username    = $Username
        DisplayName = ([string]$data.displayname).Trim()
        Email       = ([string]$data.email).Trim()
        Quota       = Get-QuotaFromUserData $data
        Groups      = $groups
        Subadmins   = $subadmins
    }
}

function Set-NextcloudUserField {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username,
        [string]$Key,
        [string]$Value
    )

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method PUT `
        -Url ($BaseUrl + "/users/" + $encodedUser) `
        -Headers $Headers `
        -Body @{
            key   = $Key
            value = $Value
        }

    if (-not $result.TransportSuccess -or -not $result.Success) {
        throw (
            "Feld '$Key' von '$Username' konnte nicht geändert werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }
}

function Remove-UserFromNextcloudGroup {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username,
        [string]$GroupName
    )

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method DELETE `
        -Url ($BaseUrl + "/users/" + $encodedUser + "/groups") `
        -Headers $Headers `
        -Body @{ groupid = $GroupName }

    if (-not $result.TransportSuccess -or -not $result.Success) {
        throw (
            "Benutzer '$Username' konnte nicht aus der Gruppe '$GroupName' entfernt werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }
}

function Remove-UserAsSubadmin {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username,
        [string]$GroupName
    )

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method DELETE `
        -Url ($BaseUrl + "/users/" + $encodedUser + "/subadmins") `
        -Headers $Headers `
        -Body @{ groupid = $GroupName }

    if (-not $result.TransportSuccess -or -not $result.Success) {
        throw (
            "Subadmin-Recht von '$Username' für '$GroupName' konnte nicht entfernt werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }
}

function Remove-NextcloudUser {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$Username
    )

    $encodedUser = [System.Uri]::EscapeDataString($Username)

    $result = Invoke-OcsRequest `
        -Method DELETE `
        -Url ($BaseUrl + "/users/" + $encodedUser) `
        -Headers $Headers

    if (-not $result.TransportSuccess -or -not $result.Success) {
        throw (
            "Benutzer '$Username' konnte nicht gelöscht werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }
}

function New-ReconciliationPlan {
    param(
        [object[]]$CsvRows,
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$ProtectedAdmin,
        [string[]]$ProtectedAccounts = @()
    )

    $csvByUser = @{}

    foreach ($row in $CsvRows) {
        $username = ([string]$row.username).Trim()
        $csvByUser[$username] = $row
    }

    $nextcloudUsers = @(Get-AllNextcloudUsers -BaseUrl $BaseUrl -Headers $Headers)

    # Normale PowerShell-Arrays vermeiden unter Windows PowerShell 5.1
    # Probleme bei der Umwandlung generischer .NET-Listen.
    $newUsers = @()
    $deleteUsers = @()
    $updates = @()
    $protected = @()

    foreach ($username in $csvByUser.Keys | Sort-Object) {
        if ($nextcloudUsers -notcontains $username) {
            $newUsers += $csvByUser[$username]
        }
    }

    foreach ($username in $nextcloudUsers | Sort-Object) {
        if (-not $csvByUser.ContainsKey($username)) {
            if ($username -ieq $ProtectedAdmin -or $ProtectedAccounts -contains $username) {
                $protected += [string]$username
            }
            else {
                $deleteUsers += [string]$username
            }
        }
    }

    $commonUsers = @(
        $nextcloudUsers |
            Where-Object { $csvByUser.ContainsKey($_) } |
            Sort-Object
    )

    $totalCommon = [Math]::Max(1, $commonUsers.Count)
    $checked = 0

    foreach ($username in $commonUsers) {
        $checked++
        $statusLabel.Text = "Vergleiche Benutzer $checked von $($commonUsers.Count): $username"
        $progress.Maximum = $totalCommon
        $progress.Value = [Math]::Min($checked, $totalCommon)
        [System.Windows.Forms.Application]::DoEvents()

        $row = $csvByUser[$username]
        $state = Get-NextcloudUserState `
            -BaseUrl $BaseUrl `
            -Headers $Headers `
            -Username $username

        $desiredDisplayName = ([string]$row.displayname).Trim()

        if ([string]::IsNullOrWhiteSpace($desiredDisplayName)) {
            $desiredDisplayName = $username
        }

        $desiredEmail = ([string]$row.email).Trim()
        $desiredQuota = ([string]$row.quota).Trim()
        $desiredGroups = @(Split-GroupList ([string]$row.groups))
        $desiredSubadmins = @(Split-GroupList ([string]$row.subadmin))

        $fieldChanges = @()

        if ($state.DisplayName -cne $desiredDisplayName) {
            $fieldChanges += [pscustomobject]@{
                Key = "displayname"
                Label = "Anzeigename"
                Old = $state.DisplayName
                New = $desiredDisplayName
            }
        }

        if ($state.Email -ine $desiredEmail) {
            $fieldChanges += [pscustomobject]@{
                Key = "email"
                Label = "E-Mail"
                Old = $state.Email
                New = $desiredEmail
            }
        }

        # Leere Quota in der CSV bedeutet: Quota nicht verändern.
        if (-not [string]::IsNullOrWhiteSpace($desiredQuota)) {
            $currentQuotaComparable = Convert-QuotaToComparable $state.Quota
            $desiredQuotaComparable = Convert-QuotaToComparable $desiredQuota

            if ($currentQuotaComparable -ne $desiredQuotaComparable) {
                $fieldChanges += [pscustomobject]@{
                    Key = "quota"
                    Label = "Quota"
                    Old = $state.Quota
                    New = $desiredQuota
                }
            }
        }

        $addGroups = @(
            $desiredGroups |
                Where-Object { $state.Groups -notcontains $_ }
        )

        $removeGroups = @(
            $state.Groups |
                Where-Object { $desiredGroups -notcontains $_ }
        )

        # Das für den Lauf verwendete Administratorkonto darf sich nicht selbst
        # aus der admin-Gruppe entfernen.
        if ($username -ieq $ProtectedAdmin) {
            $removeGroups = @(
                $removeGroups |
                    Where-Object { $_ -ine "admin" }
            )
        }

        $addSubadmins = @(
            $desiredSubadmins |
                Where-Object { $state.Subadmins -notcontains $_ }
        )

        $removeSubadmins = @(
            $state.Subadmins |
                Where-Object { $desiredSubadmins -notcontains $_ }
        )

        if (
            $fieldChanges.Count -gt 0 -or
            $addGroups.Count -gt 0 -or
            $removeGroups.Count -gt 0 -or
            $addSubadmins.Count -gt 0 -or
            $removeSubadmins.Count -gt 0
        ) {
            $updates += [pscustomobject]@{
                Username        = $username
                Row             = $row
                FieldChanges    = @($fieldChanges)
                AddGroups       = @($addGroups)
                RemoveGroups    = @($removeGroups)
                AddSubadmins    = @($addSubadmins)
                RemoveSubadmins = @($removeSubadmins)
            }
        }
    }

    $unchanged = $commonUsers.Count - $updates.Count

    return [pscustomobject]@{
        CsvCount       = $CsvRows.Count
        NextcloudCount = $nextcloudUsers.Count
        NewUsers       = $newUsers
        Updates        = $updates
        DeleteUsers    = $deleteUsers
        ProtectedUsers = $protected
        DeletionApproved = $false
        UnchangedCount = $unchanged
    }
}

function Get-ReconciliationPreviewText {
    param([object]$Plan)

    $lines = New-Object 'System.Collections.Generic.List[string]'

    $lines.Add("CSV (Sollbestand):       $($Plan.CsvCount) Benutzer")
    $lines.Add("Nextcloud (Istbestand):  $($Plan.NextcloudCount) Benutzer")
    $lines.Add("")
    $lines.Add("Neu anzulegen:            $($Plan.NewUsers.Count)")
    $lines.Add("Zu aktualisieren:         $($Plan.Updates.Count)")
    $lines.Add("Zu löschen:               $($Plan.DeleteUsers.Count)")
    $lines.Add("Unverändert:              $($Plan.UnchangedCount)")
    $lines.Add("Geschützt:                $($Plan.ProtectedUsers.Count)")
    $lines.Add("")

    if ($Plan.NewUsers.Count -gt 0) {
        $lines.Add("=== NEU ANLEGEN ===")
        foreach ($row in $Plan.NewUsers) {
            $lines.Add("+ " + ([string]$row.username).Trim())
        }
        $lines.Add("")
    }

    if ($Plan.Updates.Count -gt 0) {
        $lines.Add("=== AKTUALISIEREN ===")

        foreach ($update in $Plan.Updates) {
            $lines.Add("~ " + $update.Username)

            foreach ($field in $update.FieldChanges) {
                $old = if ([string]::IsNullOrWhiteSpace([string]$field.Old)) { "<leer>" } else { [string]$field.Old }
                $new = if ([string]::IsNullOrWhiteSpace([string]$field.New)) { "<leer>" } else { [string]$field.New }
                $lines.Add("    $($field.Label): $old  ->  $new")
            }

            foreach ($group in $update.AddGroups) {
                $lines.Add("    + Gruppe: $group")
            }

            foreach ($group in $update.RemoveGroups) {
                $lines.Add("    - Gruppe: $group")
            }

            foreach ($group in $update.AddSubadmins) {
                $lines.Add("    + Subadmin: $group")
            }

            foreach ($group in $update.RemoveSubadmins) {
                $lines.Add("    - Subadmin: $group")
            }
        }

        $lines.Add("")
    }

    if ($Plan.DeleteUsers.Count -gt 0) {
        $lines.Add("=== LÖSCHEN ===")
        foreach ($username in $Plan.DeleteUsers) {
            $lines.Add("- " + $username)
        }
        $lines.Add("")
    }

    if ($Plan.ProtectedUsers.Count -gt 0) {
        $lines.Add("=== VOR LÖSCHUNG GESCHÜTZT ===")
        foreach ($username in $Plan.ProtectedUsers) {
            $lines.Add("! " + $username + " (Admin-Konto oder Schutzliste)")
        }
    }

    return ($lines -join "`r`n")
}

function Show-ReconciliationPreview {
    param([object]$Plan)

    # Jede Vorschau beginnt ohne Freigabe; die Entscheidung wird nie gespeichert.
    $Plan.DeletionApproved = $false
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Vorschau des Bestandsabgleichs"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(760,650)
    $dialog.MinimumSize = New-Object System.Drawing.Size(650,500)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI",10)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.Padding = New-Object System.Windows.Forms.Padding(10)
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $dialog.Controls.Add($layout)

    $warning = New-Object System.Windows.Forms.Label
    $warning.AutoSize = $true
    $warning.MaximumSize = New-Object System.Drawing.Size(710,0)

    if ($Plan.DeleteUsers.Count -gt 0) {
        $warning.Text = (
            "ACHTUNG: Die CSV ist der Sollbestand. " +
            "$($Plan.DeleteUsers.Count) Benutzer sind nicht in der CSV enthalten. " +
            "Sie werden nur mit der zusätzlichen Löschfreigabe für diesen Lauf gelöscht."
        )
        $warning.ForeColor = [System.Drawing.Color]::DarkRed
        $warning.Font = New-Object System.Drawing.Font(
            "Segoe UI",
            10,
            [System.Drawing.FontStyle]::Bold
        )
    }
    else {
        $warning.Text = "Die CSV wird als vollständiger Sollbestand verwendet."
    }

    $details = New-Object System.Windows.Forms.TextBox
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = "Both"
    $details.WordWrap = $false
    $details.Dock = "Fill"
    $details.Font = New-Object System.Drawing.Font("Consolas",9.5)
    $details.Text = Get-ReconciliationPreviewText $Plan

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = "Fill"
    $buttons.AutoSize = $true
    $buttons.FlowDirection = "RightToLeft"

    $apply = New-Button "Abgleich durchführen"
    $cancel = New-Button "Abbrechen"

    $allowDeletion = New-Object System.Windows.Forms.CheckBox
    $allowDeletion.AutoSize = $true
    $allowDeletion.Checked = $false
    $allowDeletion.Enabled = ($Plan.DeleteUsers.Count -gt 0)
    $allowDeletion.Text = "Auch $($Plan.DeleteUsers.Count) Konten löschen (nur dieser Lauf)"
    $buttons.WrapContents = $true
    $buttons.Controls.AddRange(@($apply,$cancel,$allowDeletion))

    $layout.Controls.Add($warning,0,0)
    $layout.Controls.Add($details,0,1)
    $layout.Controls.Add($buttons,0,2)

    $apply.Add_Click({
        $Plan.DeletionApproved = ($allowDeletion.Enabled -and $allowDeletion.Checked)
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $cancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    return ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK)
}

function Add-NewUserFromCsvRow {
    param(
        [object]$Row,
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$NextcloudUrl
    )

    $username = ([string]$Row.username).Trim()
    $displayName = ([string]$Row.displayname).Trim()
    $email = ([string]$Row.email).Trim()
    $quota = ([string]$Row.quota).Trim()

    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = $username
    }

    $effectivePassword = [string]$Row.password
    $hasPasswordForOutput = -not [string]::IsNullOrWhiteSpace($effectivePassword)

    if ([string]::IsNullOrWhiteSpace($effectivePassword)) {
        if ($cbPasswordMode.SelectedIndex -eq 0) {
            $effectivePassword = Get-SecurePassword ([int]$cbPasswordLength.Text)
            $hasPasswordForOutput = $true
        }
        else {
            $effectivePassword = ""
            $hasPasswordForOutput = $false
        }
    }

    $result = New-NextcloudUser `
        -BaseUrl $BaseUrl `
        -Headers $Headers `
        -Username $username `
        -DisplayName $displayName `
        -Password $effectivePassword `
        -Email $email `
        -Quota $quota `
        -Language (Get-SelectedLanguageCode)

    if (-not $result.TransportSuccess -or -not $result.Success) {
        throw (
            "Benutzer '$username' konnte nicht angelegt werden. " +
            "OCS-Status $($result.StatusCode): $($result.Message)"
        )
    }

    # Zugangsdaten direkt nach erfolgreicher Kontoanlage schreiben.
    $accessFile = Write-AccessFile `
        -NextcloudUrl $NextcloudUrl `
        -Username $username `
        -Password $effectivePassword `
        -PasswordGeneratedOrProvided $hasPasswordForOutput

    Write-Log "INFO" "Zugangsdaten-Datei für '$username': $accessFile"

    foreach ($group in @(Split-GroupList ([string]$Row.groups))) {
        [void](Add-UserToNextcloudGroup `
            -BaseUrl $BaseUrl `
            -Headers $Headers `
            -Username $username `
            -GroupName $group)
    }

    foreach ($group in @(Split-GroupList ([string]$Row.subadmin))) {
        [void](Add-UserAsSubadmin `
            -BaseUrl $BaseUrl `
            -Headers $Headers `
            -Username $username `
            -GroupName $group)
    }

    $effectivePassword = $null
}

function Apply-ReconciliationPlan {
    param(
        [object]$Plan,
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$NextcloudUrl,
        [switch]$AllowDeletion
    )

    $created = 0
    $updated = 0
    $deleted = 0
    $errors = 0
    $deletionSkipped = $false
    $deletionSkipReason = ""

    $totalSteps = $Plan.NewUsers.Count + $Plan.Updates.Count + $Plan.DeleteUsers.Count
    $progress.Minimum = 0
    $progress.Maximum = [Math]::Max(1, $totalSteps)
    $progress.Value = 0
    $step = 0

    Write-Log "INFO" (
        "Bestandsabgleich gestartet: " +
        "$($Plan.NewUsers.Count) neu, " +
        "$($Plan.Updates.Count) aktualisieren, " +
        "$($Plan.DeleteUsers.Count) löschen."
    )

    # 1. Neue Benutzer anlegen
    foreach ($row in $Plan.NewUsers) {
        $username = ([string]$row.username).Trim()
        $statusLabel.Text = "Lege neuen Benutzer an: $username"
        [System.Windows.Forms.Application]::DoEvents()

        try {
            [void](Add-NewUserFromCsvRow `
                -Row $row `
                -BaseUrl $BaseUrl `
                -Headers $Headers `
                -NextcloudUrl $NextcloudUrl)

            $created++
            Write-Log "INFO" "Benutzer '$username' wurde neu angelegt."
        }
        catch {
            $errors++
            Write-Log "ERROR" $_.Exception.Message
        }

        $step++
        $progress.Value = [Math]::Min($step, $progress.Maximum)
    }

    # 2. Bestehende Benutzer synchronisieren
    foreach ($update in $Plan.Updates) {
        $username = $update.Username
        $userHadError = $false

        $statusLabel.Text = "Synchronisiere Benutzer: $username"
        [System.Windows.Forms.Application]::DoEvents()

        foreach ($field in $update.FieldChanges) {
            try {
                [void](Set-NextcloudUserField `
                    -BaseUrl $BaseUrl `
                    -Headers $Headers `
                    -Username $username `
                    -Key $field.Key `
                    -Value ([string]$field.New))

                Write-Log "INFO" "Benutzer '$username': $($field.Label) aktualisiert."
            }
            catch {
                $userHadError = $true
                $errors++
                Write-Log "ERROR" $_.Exception.Message
            }
        }

        foreach ($group in $update.AddGroups) {
            try {
                [void](Add-UserToNextcloudGroup `
                    -BaseUrl $BaseUrl `
                    -Headers $Headers `
                    -Username $username `
                    -GroupName $group)

                Write-Log "INFO" "Benutzer '$username': Gruppe '$group' hinzugefügt."
            }
            catch {
                $userHadError = $true
                $errors++
                Write-Log "ERROR" $_.Exception.Message
            }
        }

        foreach ($group in $update.RemoveGroups) {
            try {
                [void](Remove-UserFromNextcloudGroup `
                    -BaseUrl $BaseUrl `
                    -Headers $Headers `
                    -Username $username `
                    -GroupName $group)

                Write-Log "INFO" "Benutzer '$username': Gruppe '$group' entfernt."
            }
            catch {
                $userHadError = $true
                $errors++
                Write-Log "ERROR" $_.Exception.Message
            }
        }

        foreach ($group in $update.AddSubadmins) {
            try {
                [void](Add-UserAsSubadmin `
                    -BaseUrl $BaseUrl `
                    -Headers $Headers `
                    -Username $username `
                    -GroupName $group)

                Write-Log "INFO" "Benutzer '$username': Subadmin '$group' hinzugefügt."
            }
            catch {
                $userHadError = $true
                $errors++
                Write-Log "ERROR" $_.Exception.Message
            }
        }

        foreach ($group in $update.RemoveSubadmins) {
            try {
                [void](Remove-UserAsSubadmin `
                    -BaseUrl $BaseUrl `
                    -Headers $Headers `
                    -Username $username `
                    -GroupName $group)

                Write-Log "INFO" "Benutzer '$username': Subadmin '$group' entfernt."
            }
            catch {
                $userHadError = $true
                $errors++
                Write-Log "ERROR" $_.Exception.Message
            }
        }

        if (-not $userHadError) {
            $updated++
        }

        $step++
        $progress.Value = [Math]::Min($step, $progress.Maximum)
    }

    # Sicherheitsregel:
    # Wenn beim Anlegen oder Synchronisieren etwas fehlgeschlagen ist,
    # werden in diesem Lauf KEINE Benutzer gelöscht.
    if ($errors -gt 0 -and $Plan.DeleteUsers.Count -gt 0) {
        $deletionSkipped = $true
        $deletionSkipReason = "Errors"

        Write-Log "WARN" (
            "Löschphase wurde übersprungen, weil beim Anlegen/Synchronisieren Fehler aufgetreten sind. " +
            "$($Plan.DeleteUsers.Count) geplante Löschungen wurden nicht ausgeführt."
        )
    }
    elseif (-not $AllowDeletion -and $Plan.DeleteUsers.Count -gt 0) {
        $deletionSkipped = $true
        $deletionSkipReason = "NotApproved"
        Write-Log "INFO" "Löschphase übersprungen: Für diesen Lauf wurden keine Löschungen freigegeben."
    }
    else {
        # 3. Benutzer löschen, die nicht mehr in der CSV stehen.
        foreach ($username in $Plan.DeleteUsers) {
            $statusLabel.Text = "Lösche Benutzer: $username"
            [System.Windows.Forms.Application]::DoEvents()

            try {
                [void](Remove-NextcloudUser `
                    -BaseUrl $BaseUrl `
                    -Headers $Headers `
                    -Username $username)

                $deleted++
                Write-Log "INFO" "Benutzer '$username' wurde gelöscht."
            }
            catch {
                $errors++
                Write-Log "ERROR" $_.Exception.Message
            }

            $step++
            $progress.Value = [Math]::Min($step, $progress.Maximum)
        }
    }

    return [pscustomobject]@{
        Created         = $created
        Updated         = $updated
        Deleted         = $deleted
        Errors          = $errors
        DeletionSkipped = $deletionSkipped
        DeletionSkipReason = $deletionSkipReason
    }
}



# --------------------------------------------------------------------
# Lokaler Gruppen-Editor für CSV
# --------------------------------------------------------------------

function Edit-CsvGroupMemberships {
    $csvPath = Get-CurrentCsvPath

    if (-not $csvPath -or -not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        Show-Warn "Bitte zuerst eine vorhandene CSV-Datei auswählen."
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtCloud.Text)) {
        Show-Warn "Bitte die Nextcloud-Adresse eintragen."
        $txtCloud.Focus()
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtAdmin.Text)) {
        Show-Warn "Bitte den Admin-Benutzernamen eintragen."
        $txtAdmin.Focus()
        return
    }

    $rows = $null

    try {
        $rows = @(Read-AndValidateCsv $false)
    }
    catch {
        Show-ErrorBox $_.Exception.Message "CSV-Prüfung"
        return
    }

    [string]$adminPassword = Request-AdminPassword (
        "Die vorhandenen Gruppennamen werden aus Nextcloud gelesen. " +
        "Die anschließenden Änderungen erfolgen ausschließlich lokal in der CSV."
    )

    if ([string]::IsNullOrWhiteSpace($adminPassword)) {
        $statusLabel.Text = "Gruppen bearbeiten abgebrochen."
        return
    }

    try {
        $nextcloudUrl = Normalize-NextcloudUrl $txtCloud.Text
        $baseUrl = Get-ApiBaseUrl $nextcloudUrl
    }
    catch {
        $adminPassword = $null
        Show-ErrorBox $_.Exception.Message "Nextcloud-Adresse"
        return
    }
    $adminName = $txtAdmin.Text.Trim()
    $headers = $null
    $groups = @()

    $btnGroups.Enabled = $false
    $btnCreate.Enabled = $false
    $btnExport.Enabled = $false

    try {
        $headers = New-BasicAuthHeaders `
            -AdminName $adminName `
            -AdminPassword $adminPassword

        $statusLabel.Text = "Gruppen werden aus Nextcloud geladen..."
        [System.Windows.Forms.Application]::DoEvents()

        Test-NextcloudConnection -BaseUrl $baseUrl -Headers $headers

        $groups = @(
            Get-AllNextcloudGroups `
                -BaseUrl $baseUrl `
                -Headers $headers |
                Where-Object { $_ -ine "admin" }
        )

        # Auch Gruppen berücksichtigen, die bereits in der CSV stehen,
        # aber noch nicht in Nextcloud existieren.
        $csvGroups = @()

        foreach ($row in $rows) {
            foreach ($group in @(Split-GroupList ([string]$row.groups))) {
                if (
                    -not [string]::IsNullOrWhiteSpace($group) -and
                    $group -ine "admin"
                ) {
                    $csvGroups += [string]$group
                }
            }
        }

        $groups = @(
            @($groups) + @($csvGroups) |
                Sort-Object -Unique
        )
    }
    catch {
        Show-ErrorBox (
            "Die Gruppen konnten nicht aus Nextcloud geladen werden.`r`n`r`n" +
            $_.Exception.Message
        ) "Gruppen bearbeiten"

        $statusLabel.Text = "Gruppen konnten nicht geladen werden."
        return
    }
    finally {
        $adminPassword = $null

        if ($null -ne $headers) {
            $headers.Clear()
            $headers = $null
        }

        $btnGroups.Enabled = $true
        $btnCreate.Enabled = $true
        $btnExport.Enabled = $true
    }

    # Kopie der CSV-Daten anlegen, damit Abbrechen die Ursprungsdatei garantiert nicht verändert.
    $editorRows = @()

    foreach ($row in $rows) {
        $editorRows += [pscustomobject][ordered]@{
            username    = ([string]$row.username).Trim()
            displayname = [string]$row.displayname
            password    = [string]$row.password
            email       = [string]$row.email
            groups      = [string]$row.groups
            subadmin    = [string]$row.subadmin
            quota       = [string]$row.quota
        }
    }

    $editorRows = @(
        $editorRows |
            Sort-Object `
                @{ Expression = {
                    if ([string]::IsNullOrWhiteSpace([string]$_.displayname)) {
                        [string]$_.username
                    }
                    else {
                        [string]$_.displayname
                    }
                }},
                @{ Expression = { [string]$_.username }}
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Gruppenzuordnungen in CSV bearbeiten"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(760,720)
    $dialog.MinimumSize = New-Object System.Drawing.Size(650,560)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI",10)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.Padding = New-Object System.Windows.Forms.Padding(10)
    $layout.ColumnCount = 1
    $layout.RowCount = 6

    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )

    $dialog.Controls.Add($layout)

    $info = New-Object System.Windows.Forms.Label
    $info.AutoSize = $true
    $info.MaximumSize = New-Object System.Drawing.Size(700,0)
    $info.Text = (
        "Die Änderungen erfolgen nur in der CSV-Datei. Nextcloud wird hier nicht verändert. " +
        "Wählen Sie eine Gruppe und markieren Sie alle Benutzer, die Mitglied dieser Gruppe sein sollen. " +
        "Über 'Neue Gruppe...' können Sie zusätzliche Gruppen lokal anlegen. " +
        "Beim späteren Bestandsabgleich werden fehlende Gruppen automatisch in Nextcloud erzeugt. " +
        "Die Systemgruppe 'admin' wird aus Sicherheitsgründen nicht zur Bearbeitung angeboten."
    )

    $groupPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $groupPanel.Dock = "Fill"
    $groupPanel.AutoSize = $true
    $groupPanel.ColumnCount = 3
    $groupPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $groupPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100))
    )
    $groupPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))
    )

    $groupLabel = New-Label "Gruppe"
    $groupLabel.Margin = New-Object System.Windows.Forms.Padding(0,7,10,2)

    $groupCombo = New-Object System.Windows.Forms.ComboBox
    $groupCombo.Dock = "Fill"
    $groupCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

    foreach ($group in $groups) {
        [void]$groupCombo.Items.Add($group)
    }

    $btnNewGroup = New-Button "Neue Gruppe..."
    $btnNewGroup.AutoSize = $true

    $toolTip.SetToolTip(
        $btnNewGroup,
        "Legt eine neue Gruppe zunächst nur lokal in der CSV an. Beim Bestandsabgleich wird sie automatisch in Nextcloud erzeugt, sobald ihr mindestens ein Benutzer zugeordnet ist."
    )

    $groupPanel.Controls.Add($groupLabel,0,0)
    $groupPanel.Controls.Add($groupCombo,1,0)
    $groupPanel.Controls.Add($btnNewGroup,2,0)

    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.AutoSize = $true
    $countLabel.ForeColor = [System.Drawing.Color]::DimGray
    $countLabel.Margin = New-Object System.Windows.Forms.Padding(0,4,0,5)

    $userList = New-Object System.Windows.Forms.CheckedListBox
    $userList.Dock = "Fill"
    $userList.CheckOnClick = $true
    $userList.HorizontalScrollbar = $true
    $userList.IntegralHeight = $false

    foreach ($row in $editorRows) {
        $display = ([string]$row.displayname).Trim()

        if ([string]::IsNullOrWhiteSpace($display)) {
            $display = [string]$row.username
        }

        [void]$userList.Items.Add(
            [pscustomobject]@{
                Username = [string]$row.username
                Label = $display + "  [" + ([string]$row.username) + "]"
            }
        )
    }

    $userList.DisplayMember = "Label"

    $selectionButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $selectionButtons.Dock = "Fill"
    $selectionButtons.AutoSize = $true
    $selectionButtons.WrapContents = $false

    $btnAll = New-Button "Alle markieren"
    $btnNone = New-Button "Keine markieren"

    $selectionButtons.Controls.AddRange(@(
        $btnAll,
        $btnNone
    ))

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = "Fill"
    $buttons.AutoSize = $true
    $buttons.FlowDirection = "RightToLeft"

    $btnSaveCsv = New-Button "CSV speichern unter..."
    $btnCancel = New-Button "Abbrechen"

    $buttons.Controls.AddRange(@(
        $btnSaveCsv,
        $btnCancel
    ))

    $layout.Controls.Add($info,0,0)
    $layout.Controls.Add($groupPanel,0,1)
    $layout.Controls.Add($countLabel,0,2)
    $layout.Controls.Add($userList,0,3)
    $layout.Controls.Add($selectionButtons,0,4)
    $layout.Controls.Add($buttons,0,5)

    # Gemeinsamer, veränderbarer Zustand für die Event-Handler.
    # Ein PSCustomObject wird verwendet, damit Änderungen auch über
    # PowerShell-Scope-Grenzen hinweg erhalten bleiben.
    $editorState = [pscustomobject]@{
        CurrentGroup = $null
        LoadingChecks = $false
    }

    $findRow = {
        param([string]$Username)

        return @(
            $editorRows |
                Where-Object {
                    ([string]$_.username) -ieq $Username
                }
        ) | Select-Object -First 1
    }

    $setMembership = {
        param(
            [string]$Username,
            [string]$GroupName,
            [bool]$IsMember
        )

        if ([string]::IsNullOrWhiteSpace($GroupName)) {
            return
        }

        $row = & $findRow $Username

        if ($null -eq $row) {
            return
        }

        $rowGroups = @(Split-GroupList ([string]$row.groups))

        if ($IsMember) {
            if ($rowGroups -notcontains $GroupName) {
                $rowGroups += $GroupName
            }
        }
        else {
            $rowGroups = @(
                $rowGroups |
                    Where-Object { $_ -ine $GroupName }
            )
        }

        $row.groups = (
            @(
                $rowGroups |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    } |
                    Sort-Object -Unique
            ) -join $script:GroupDelimiter
        )
    }

    $refreshCount = {
        $checked = 0

        for ($i = 0; $i -lt $userList.Items.Count; $i++) {
            if ($userList.GetItemChecked($i)) {
                $checked++
            }
        }

        $countLabel.Text = (
            "Mitglieder in '" +
            [string]$groupCombo.SelectedItem +
            "': " +
            $checked +
            " von " +
            $userList.Items.Count
        )
    }

    $loadSelectedGroup = {
        $selected = [string]$groupCombo.SelectedItem

        if ([string]::IsNullOrWhiteSpace($selected)) {
            return
        }

        $editorState.LoadingChecks = $true

        try {
            for ($i = 0; $i -lt $userList.Items.Count; $i++) {
                $item = $userList.Items[$i]
                $row = & $findRow ([string]$item.Username)

                $isMember = $false

                if ($null -ne $row) {
                    $rowGroups = @(Split-GroupList ([string]$row.groups))
                    $isMember = ($rowGroups -contains $selected)
                }

                $userList.SetItemChecked($i, $isMember)
            }
        }
        finally {
            $editorState.LoadingChecks = $false
        }

        $editorState.CurrentGroup = $selected
        & $refreshCount
    }

    $btnNewGroup.Add_Click({
        $newGroupDialog = New-Object System.Windows.Forms.Form
        $newGroupDialog.Text = "Neue Gruppe"
        $newGroupDialog.StartPosition = "CenterParent"
        $newGroupDialog.Size = New-Object System.Drawing.Size(500,220)
        $newGroupDialog.MinimumSize = New-Object System.Drawing.Size(460,210)
        $newGroupDialog.MaximizeBox = $false
        $newGroupDialog.MinimizeBox = $false
        $newGroupDialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $newGroupDialog.Font = New-Object System.Drawing.Font("Segoe UI",10)

        $newGroupLayout = New-Object System.Windows.Forms.TableLayoutPanel
        $newGroupLayout.Dock = "Fill"
        $newGroupLayout.Padding = New-Object System.Windows.Forms.Padding(12)
        $newGroupLayout.ColumnCount = 1
        $newGroupLayout.RowCount = 4

        [void]$newGroupLayout.RowStyles.Add(
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
        )
        [void]$newGroupLayout.RowStyles.Add(
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
        )
        [void]$newGroupLayout.RowStyles.Add(
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
        )
        [void]$newGroupLayout.RowStyles.Add(
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
        )

        [void]$newGroupDialog.Controls.Add($newGroupLayout)

        $newGroupInfo = New-Object System.Windows.Forms.Label
        $newGroupInfo.AutoSize = $true
        $newGroupInfo.MaximumSize = New-Object System.Drawing.Size(450,0)
        $newGroupInfo.Text = (
            "Die Gruppe wird zunächst nur für diese CSV angelegt. " +
            "Beim Bestandsabgleich wird sie automatisch in Nextcloud erzeugt, " +
            "sobald mindestens ein Benutzer dieser Gruppe zugeordnet ist."
        )

        $newGroupBox = New-Object System.Windows.Forms.TextBox
        $newGroupBox.Dock = "Fill"

        $newGroupHint = New-Object System.Windows.Forms.Label
        $newGroupHint.AutoSize = $true
        $newGroupHint.ForeColor = [System.Drawing.Color]::DimGray
        $newGroupHint.Text = "Das Komma kann nicht verwendet werden, da es in der CSV Gruppen trennt."

        $newGroupButtons = New-Object System.Windows.Forms.FlowLayoutPanel
        $newGroupButtons.Dock = "Fill"
        $newGroupButtons.AutoSize = $true
        $newGroupButtons.FlowDirection = "RightToLeft"

        $btnNewGroupOk = New-Button "Übernehmen"
        $btnNewGroupCancel = New-Button "Abbrechen"

        $newGroupButtons.Controls.AddRange(@(
            $btnNewGroupOk,
            $btnNewGroupCancel
        ))

        [void]$newGroupLayout.Controls.Add($newGroupInfo,0,0)
        [void]$newGroupLayout.Controls.Add($newGroupBox,0,1)
        [void]$newGroupLayout.Controls.Add($newGroupHint,0,2)
        [void]$newGroupLayout.Controls.Add($newGroupButtons,0,3)

        $btnNewGroupOk.Add_Click({
            $newGroupName = ([string]$newGroupBox.Text).Trim()

            if ([string]::IsNullOrWhiteSpace($newGroupName)) {
                Show-Warn "Bitte einen Gruppennamen eingeben." "Neue Gruppe"
                [void]$newGroupBox.Focus()
                return
            }

            if ($newGroupName.Contains($script:GroupDelimiter)) {
                Show-Warn (
                    "Der Gruppenname darf kein '" +
                    $script:GroupDelimiter +
                    "' enthalten, da dieses Zeichen in der CSV die Gruppen trennt."
                ) "Neue Gruppe"
                [void]$newGroupBox.Focus()
                return
            }

            if ($newGroupName -ieq "admin") {
                Show-Warn (
                    "Die Systemgruppe 'admin' kann in diesem Editor nicht angelegt oder bearbeitet werden."
                ) "Neue Gruppe"
                return
            }

            $existingIndex = -1

            for ($i = 0; $i -lt $groupCombo.Items.Count; $i++) {
                if ([string]$groupCombo.Items[$i] -ieq $newGroupName) {
                    $existingIndex = $i
                    break
                }
            }

            if ($existingIndex -ge 0) {
                $groupCombo.SelectedIndex = $existingIndex
                $newGroupDialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $newGroupDialog.Close()
                return
            }

            [void]$groupCombo.Items.Add($newGroupName)

            # Neu erzeugte Gruppen werden für diese Editor-Sitzung ebenfalls
            # in der lokalen Gruppenliste geführt.
            $groups = @(
                @($groups) + @($newGroupName) |
                    Sort-Object -Unique
            )

            $groupCombo.SelectedItem = $newGroupName
            $newGroupDialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $newGroupDialog.Close()
        })

        $btnNewGroupCancel.Add_Click({
            $newGroupDialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $newGroupDialog.Close()
        })

        $newGroupDialog.AcceptButton = $btnNewGroupOk
        $newGroupDialog.CancelButton = $btnNewGroupCancel

        $newGroupDialog.Add_Shown({
            [void]$newGroupBox.Focus()
        })

        [void]$newGroupDialog.ShowDialog($dialog)
    })

    $groupCombo.Add_SelectedIndexChanged({
        & $loadSelectedGroup
    })

    # Jede einzelne Änderung wird sofort in $editorRows geschrieben.
    # Dadurch hängt das Speichern der CSV nicht mehr von einem späteren
    # Gruppenwechsel oder einem separaten "Übernehmen"-Schritt ab.
    $userList.Add_ItemCheck({
        if ($editorState.LoadingChecks) {
            return
        }

        $groupName = [string]$editorState.CurrentGroup

        if ([string]::IsNullOrWhiteSpace($groupName)) {
            return
        }

        $item = $userList.Items[$_.Index]
        $willBeChecked = (
            $_.NewValue -eq [System.Windows.Forms.CheckState]::Checked
        )

        & $setMembership `
            ([string]$item.Username) `
            $groupName `
            $willBeChecked

        $dialog.BeginInvoke(
            [Action]{
                & $refreshCount
            }
        ) | Out-Null
    })

    $btnAll.Add_Click({
        $groupName = [string]$editorState.CurrentGroup

        if ([string]::IsNullOrWhiteSpace($groupName)) {
            return
        }

        $editorState.LoadingChecks = $true

        try {
            for ($i = 0; $i -lt $userList.Items.Count; $i++) {
                $item = $userList.Items[$i]

                $userList.SetItemChecked($i, $true)

                & $setMembership `
                    ([string]$item.Username) `
                    $groupName `
                    $true
            }
        }
        finally {
            $editorState.LoadingChecks = $false
        }

        & $refreshCount
    })

    $btnNone.Add_Click({
        $groupName = [string]$editorState.CurrentGroup

        if ([string]::IsNullOrWhiteSpace($groupName)) {
            return
        }

        $editorState.LoadingChecks = $true

        try {
            for ($i = 0; $i -lt $userList.Items.Count; $i++) {
                $item = $userList.Items[$i]

                $userList.SetItemChecked($i, $false)

                & $setMembership `
                    ([string]$item.Username) `
                    $groupName `
                    $false
            }
        }
        finally {
            $editorState.LoadingChecks = $false
        }

        & $refreshCount
    })

    $btnSaveCsv.Add_Click({
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Title = "CSV mit neuen Gruppenzuordnungen speichern"
        $saveDialog.Filter = "CSV-Dateien (*.csv)|*.csv|Alle Dateien (*.*)|*.*"
        $saveDialog.FilterIndex = 1
        $saveDialog.AddExtension = $true
        $saveDialog.DefaultExt = "csv"
        $saveDialog.OverwritePrompt = $true

        try {
            $saveDialog.InitialDirectory = Split-Path -Parent $csvPath
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($csvPath)
            $saveDialog.FileName = $baseName + "-gruppen.csv"
        }
        catch {
            $saveDialog.InitialDirectory = $script:AppDir
            $saveDialog.FileName = "users-gruppen.csv"
        }

        if ($saveDialog.ShowDialog($dialog) -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        try {
            $rowsForExport = @(
                $editorRows |
                    Sort-Object username |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            username    = [string]$_.username
                            displayname = [string]$_.displayname
                            password    = [string]$_.password
                            email       = [string]$_.email
                            groups      = [string]$_.groups
                            subadmin    = [string]$_.subadmin
                            quota       = [string]$_.quota
                        }
                    }
            )

            $csvText = $rowsForExport |
                ConvertTo-Csv `
                    -Delimiter ([char]$script:CsvDelimiter) `
                    -NoTypeInformation

            Set-Content `
                -LiteralPath $saveDialog.FileName `
                -Value $csvText `
                -Encoding UTF8

            # Die neu gespeicherte Datei direkt als aktuelle Soll-CSV übernehmen.
            $savedDir = [System.IO.Path]::GetFullPath(
                (Split-Path -Parent $saveDialog.FileName)
            ).TrimEnd('\')

            $appDirFull = [System.IO.Path]::GetFullPath(
                $script:AppDir
            ).TrimEnd('\')

            if ($savedDir -ieq $appDirFull) {
                $txtCsv.Text = Split-Path -Leaf $saveDialog.FileName
            }
            else {
                $txtCsv.Text = $saveDialog.FileName
            }

            [void](Save-Settings)

            Write-Log "INFO" (
                "CSV-Gruppenzuordnungen lokal bearbeitet und gespeichert: " +
                $saveDialog.FileName
            )

            $statusLabel.Text = "CSV mit neuen Gruppenzuordnungen gespeichert."

            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
        catch {
            Show-ErrorBox (
                "Die CSV-Datei konnte nicht gespeichert werden.`r`n`r`n" +
                $_.Exception.Message
            ) "Gruppen bearbeiten"
        }
    })

    $btnCancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    if ($groupCombo.Items.Count -gt 0) {
        $groupCombo.SelectedIndex = 0
    }

    [void]$dialog.ShowDialog($form)
}

# --------------------------------------------------------------------
# Nextcloud-Bestand als CSV exportieren
# --------------------------------------------------------------------

function Convert-QuotaForCsv {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $v = $Value.Trim()

    # Wenn Nextcloud bereits einen lesbaren Wert liefert, unverändert verwenden.
    if ($v -notmatch '^\d+$') {
        return $v
    }

    try {
        $bytes = [int64]$v

        $units = @(
            [pscustomobject]@{ Name = "TB"; Factor = [int64](1024L * 1024L * 1024L * 1024L) },
            [pscustomobject]@{ Name = "GB"; Factor = [int64](1024L * 1024L * 1024L) },
            [pscustomobject]@{ Name = "MB"; Factor = [int64](1024L * 1024L) },
            [pscustomobject]@{ Name = "KB"; Factor = [int64]1024L }
        )

        foreach ($unit in $units) {
            if ($bytes -ge $unit.Factor -and ($bytes % $unit.Factor) -eq 0) {
                return (($bytes / $unit.Factor).ToString() + $unit.Name)
            }
        }

        return $bytes.ToString()
    }
    catch {
        return $v
    }
}

function Export-NextcloudUsersToCsv {
    if ([string]::IsNullOrWhiteSpace($txtCloud.Text)) {
        Show-Warn "Bitte die Nextcloud-Adresse eintragen."
        $txtCloud.Focus()
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtAdmin.Text)) {
        Show-Warn "Bitte den Admin-Benutzernamen eintragen."
        $txtAdmin.Focus()
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Nextcloud-Bestand als CSV speichern"
    $dialog.Filter = "CSV-Dateien (*.csv)|*.csv|Alle Dateien (*.*)|*.*"
    $dialog.FilterIndex = 1
    $dialog.AddExtension = $true
    $dialog.DefaultExt = "csv"
    $dialog.OverwritePrompt = $true
    $dialog.InitialDirectory = $script:AppDir
    $dialog.FileName = "nextcloud-bestand_" + (Get-Date -Format "yyyy-MM-dd_HHmm") + ".csv"

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    [string]$adminPassword = Request-AdminPassword "Der aktuelle Benutzerbestand wird aus Nextcloud gelesen und als CSV gespeichert."

    if ([string]::IsNullOrWhiteSpace($adminPassword)) {
        $statusLabel.Text = "CSV-Export abgebrochen."
        return
    }

    try {
        $nextcloudUrl = Normalize-NextcloudUrl $txtCloud.Text
        $baseUrl = Get-ApiBaseUrl $nextcloudUrl
    }
    catch {
        $adminPassword = $null
        Show-ErrorBox $_.Exception.Message "Nextcloud-Adresse"
        return
    }
    $adminName = $txtAdmin.Text.Trim()
    $headers = $null

    $btnExport.Enabled = $false
    $btnCreate.Enabled = $false
    $btnSave.Enabled = $false
    $root.Enabled = $false
    $progress.Minimum = 0
    $progress.Maximum = 1
    $progress.Value = 0

    try {
        $headers = New-BasicAuthHeaders `
            -AdminName $adminName `
            -AdminPassword $adminPassword

        $statusLabel.Text = "Verbindung zu Nextcloud wird geprüft..."
        [System.Windows.Forms.Application]::DoEvents()

        Test-NextcloudConnection -BaseUrl $baseUrl -Headers $headers

        $statusLabel.Text = "Benutzerliste wird aus Nextcloud geladen..."
        [System.Windows.Forms.Application]::DoEvents()

        $usernames = @(Get-AllNextcloudUsers -BaseUrl $baseUrl -Headers $headers)

        $progress.Minimum = 0
        $progress.Maximum = [Math]::Max(1, $usernames.Count)
        $progress.Value = 0

        $exportRows = @()
        $index = 0

        foreach ($username in ($usernames | Sort-Object)) {
            $index++
            $statusLabel.Text = "Exportiere Benutzer $index von $($usernames.Count): $username"
            $progress.Value = [Math]::Min($index, $progress.Maximum)
            [System.Windows.Forms.Application]::DoEvents()

            $state = Get-NextcloudUserState `
                -BaseUrl $baseUrl `
                -Headers $headers `
                -Username $username

            $exportRows += [pscustomobject][ordered]@{
                username    = $state.Username
                displayname = $state.DisplayName
                password    = ""
                email       = $state.Email
                groups      = (($state.Groups | Sort-Object) -join $script:GroupDelimiter)
                subadmin    = (($state.Subadmins | Sort-Object) -join $script:GroupDelimiter)
                quota       = Convert-QuotaForCsv $state.Quota
            }
        }

        # Windows PowerShell 5.1 schreibt mit -Encoding UTF8 eine UTF-8-Datei mit BOM.
        # Das ist für Umlaute wie "lehrkräfte" und die Bearbeitung mit Excel/Editor robust.
        $csvText = $exportRows |
            ConvertTo-Csv `
                -Delimiter ([char]$script:CsvDelimiter) `
                -NoTypeInformation

        Set-Content `
            -LiteralPath $dialog.FileName `
            -Value $csvText `
            -Encoding UTF8

        Write-Log "INFO" (
            "Nextcloud-Bestand exportiert: " +
            $exportRows.Count +
            " Benutzer nach " +
            $dialog.FileName
        )

        $statusLabel.Text = "Export abgeschlossen: $($exportRows.Count) Benutzer."

        Show-Info (
            "Der aktuelle Nextcloud-Bestand wurde gespeichert.`r`n`r`n" +
            "Benutzer: $($exportRows.Count)`r`n" +
            "Datei: $($dialog.FileName)`r`n`r`n" +
            "Das Passwortfeld bleibt bei allen Benutzern leer."
        ) "CSV-Export"
    }
    catch {
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        $sourceLine = ""

        if ($null -ne $_.InvocationInfo.Line) {
            $sourceLine = $_.InvocationInfo.Line.Trim()
        }

        Write-Log "ERROR" (
            "CSV-Export abgebrochen: " +
            $_.Exception.Message +
            " | Zeile: " +
            $lineNumber
        )

        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            Write-Log "ERROR" ("Stacktrace: " + $_.ScriptStackTrace)
        }

        Show-ErrorBox (
            "Der Nextcloud-Bestand konnte nicht exportiert werden.`r`n`r`n" +
            $_.Exception.Message +
            "`r`n`r`nZeile: " +
            $lineNumber +
            $(if (-not [string]::IsNullOrWhiteSpace($sourceLine)) {
                "`r`n" + $sourceLine
            } else {
                ""
            })
        ) "CSV-Export"

        $statusLabel.Text = "CSV-Export abgebrochen."
    }
    finally {
        $adminPassword = $null

        if ($null -ne $headers) {
            $headers.Clear()
            $headers = $null
        }

        $btnExport.Enabled = $true
        $btnCreate.Enabled = $true
        $btnSave.Enabled = $true
        $root.Enabled = $true
    }
}

# --------------------------------------------------------------------
# Zugangsdaten-TXT
# --------------------------------------------------------------------

function Write-AccessFile {
    param(
        [string]$NextcloudUrl,
        [string]$Username,
        [string]$Password,
        [bool]$PasswordGeneratedOrProvided
    )

    if (-not (Test-Path -LiteralPath $script:OutputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }

    $safeName = Get-SafeFileName $Username
    $path = Join-Path $script:OutputDir ($safeName + ".txt")

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $path = Join-Path $script:OutputDir ($safeName + "_" + $stamp + ".txt")
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrWhiteSpace($script:OutputText)) {
        $parts.Add($script:OutputText.Trim())
        $parts.Add("")
    }

    $parts.Add("Nextcloud: " + (Normalize-NextcloudUrl $NextcloudUrl))
    $parts.Add("Benutzername: " + $Username)

    if ($PasswordGeneratedOrProvided -and -not [string]::IsNullOrWhiteSpace($Password)) {
        $parts.Add("Passwort: " + $Password)
    }
    else {
        $parts.Add("")
        $parts.Add("Das Passwort wird über die E-Mail von Nextcloud festgelegt.")
    }

    Set-Content -LiteralPath $path -Value $parts -Encoding UTF8
    return $path
}

# --------------------------------------------------------------------
# Ausgabetext bearbeiten
# --------------------------------------------------------------------

function Edit-OutputText {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Text für Zugangsdaten"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object System.Drawing.Size(650,430)
    $dialog.MinimumSize = New-Object System.Drawing.Size(520,350)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI",10)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.Padding = New-Object System.Windows.Forms.Padding(10)
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100))
    )
    $layout.RowStyles.Add(
        (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
    )
    $dialog.Controls.Add($layout)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = (
        "Dieser Text steht am Anfang jeder Zugangsdaten-Datei. " +
        "URL, Benutzername und gegebenenfalls Passwort werden automatisch darunter ergänzt."
    )
    $info.AutoSize = $true
    $info.MaximumSize = New-Object System.Drawing.Size(600,0)

    $editor = New-Object System.Windows.Forms.TextBox
    $editor.Multiline = $true
    $editor.AcceptsReturn = $true
    $editor.ScrollBars = "Vertical"
    $editor.Dock = "Fill"
    $editor.Text = $script:OutputText

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = "Fill"
    $buttons.AutoSize = $true
    $buttons.FlowDirection = "RightToLeft"

    $ok = New-Button "Übernehmen"
    $cancel = New-Button "Abbrechen"
    $buttons.Controls.AddRange(@($ok,$cancel))

    $layout.Controls.Add($info,0,0)
    $layout.Controls.Add($editor,0,1)
    $layout.Controls.Add($buttons,0,2)

    $ok.Add_Click({
        $script:OutputText = $editor.Text
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $cancel.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    [void]$dialog.ShowDialog($form)
}

# --------------------------------------------------------------------
# Bestand abgleichen
# --------------------------------------------------------------------

function Start-Reconciliation {
    if ([string]::IsNullOrWhiteSpace($txtCloud.Text)) {
        Show-Warn "Bitte die Nextcloud-Adresse eintragen."
        $txtCloud.Focus()
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtAdmin.Text)) {
        Show-Warn "Bitte den Admin-Benutzernamen eintragen."
        $txtAdmin.Focus()
        return
    }

    $rows = $null

    try {
        $rows = @(Read-AndValidateCsv $false)
    }
    catch {
        Show-ErrorBox $_.Exception.Message "CSV-Prüfung"
        return
    }

    if (-not (Save-Settings)) { return }

    [string]$adminPassword = Request-AdminPassword (
        "Der CSV-Sollbestand wird mit Nextcloud abgeglichen. " +
        "Dabei können Benutzer angelegt, geändert und nach der Vorschau gelöscht werden."
    )

    if ([string]::IsNullOrWhiteSpace($adminPassword)) {
        $statusLabel.Text = "Bestandsabgleich abgebrochen."
        return
    }

    try {
        $nextcloudUrl = Normalize-NextcloudUrl $txtCloud.Text
        $baseUrl = Get-ApiBaseUrl $nextcloudUrl
    }
    catch {
        $adminPassword = $null
        Show-ErrorBox $_.Exception.Message "Nextcloud-Adresse"
        return
    }
    $adminName = $txtAdmin.Text.Trim()
    $headers = $null

    $btnCreate.Enabled = $false
    $btnSave.Enabled = $false
    $root.Enabled = $false
    $progress.Minimum = 0
    $progress.Maximum = 1
    $progress.Value = 0

    try {
        if (-not (Test-Path -LiteralPath $script:OutputDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
        }

        if (-not (Test-Path -LiteralPath $script:LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        $headers = New-BasicAuthHeaders `
            -AdminName $adminName `
            -AdminPassword $adminPassword

        $statusLabel.Text = "Verbindung zu Nextcloud wird geprüft..."
        [System.Windows.Forms.Application]::DoEvents()

        Test-NextcloudConnection -BaseUrl $baseUrl -Headers $headers

        $statusLabel.Text = "Soll- und Istbestand werden verglichen..."
        [System.Windows.Forms.Application]::DoEvents()

        $plan = New-ReconciliationPlan `
            -CsvRows $rows `
            -BaseUrl $baseUrl `
            -Headers $headers `
            -ProtectedAdmin $adminName `
            -ProtectedAccounts @(Split-GroupList $txtProtectedUsers.Text)

        $progress.Value = 0
        $statusLabel.Text = (
            "Vorschau: $($plan.NewUsers.Count) neu, " +
            "$($plan.Updates.Count) ändern, " +
            "$($plan.DeleteUsers.Count) löschen."
        )

        if (-not (Show-ReconciliationPreview $plan)) {
            $statusLabel.Text = "Bestandsabgleich abgebrochen. Es wurde nichts verändert."
            return
        }

        $applyOutput = @(
            Apply-ReconciliationPlan `
                -Plan $plan `
                -BaseUrl $baseUrl `
                -Headers $headers `
                -NextcloudUrl $nextcloudUrl `
                -AllowDeletion:$plan.DeletionApproved
        )

        $result = $applyOutput |
            Where-Object {
                $null -ne $_ -and
                $null -ne $_.PSObject.Properties["DeletionSkipped"]
            } |
            Select-Object -Last 1

        if ($null -eq $result) {
            throw "Der Bestandsabgleich lieferte kein gültiges Ergebnisobjekt."
        }

        if ($result.DeletionSkipped -and $result.DeletionSkipReason -eq "NotApproved") {
            $statusLabel.Text = (
                "Fertig: $($result.Created) neu, $($result.Updated) aktualisiert. " +
                "Löschungen wurden für diesen Lauf nicht freigegeben."
            )
        }
        elseif ($result.DeletionSkipped) {
            $statusLabel.Text = (
                "Teilweise abgeschlossen: $($result.Created) neu, " +
                "$($result.Updated) aktualisiert, keine Löschungen wegen Fehlern."
            )

            Show-Warn (
                "Beim Anlegen oder Synchronisieren sind Fehler aufgetreten.`r`n`r`n" +
                "Aus Sicherheitsgründen wurden deshalb keine Benutzer gelöscht.`r`n" +
                "Bitte prüfen Sie die Logdatei."
            ) "Löschungen nicht ausgeführt"
        }
        else {
            $statusLabel.Text = (
                "Fertig: $($result.Created) neu, " +
                "$($result.Updated) aktualisiert, " +
                "$($result.Deleted) gelöscht, " +
                "$($result.Errors) Fehler."
            )
        }

        Write-Log "INFO" (
            "Bestandsabgleich beendet: " +
            "$($result.Created) neu, " +
            "$($result.Updated) aktualisiert, " +
            "$($result.Deleted) gelöscht, " +
            "$($result.Errors) Fehler."
        )
    }
    catch {
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        $sourceLine = ""

        if ($null -ne $_.InvocationInfo.Line) {
            $sourceLine = $_.InvocationInfo.Line.Trim()
        }

        $detail = (
            "Bestandsabgleich abgebrochen: " +
            $_.Exception.Message +
            " | Zeile: " + $lineNumber +
            $(if (-not [string]::IsNullOrWhiteSpace($sourceLine)) {
                " | Code: " + $sourceLine
            } else {
                ""
            })
        )

        Write-Log "ERROR" $detail

        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            Write-Log "ERROR" ("Stacktrace: " + $_.ScriptStackTrace)
        }

        Show-ErrorBox (
            $_.Exception.Message +
            "`r`n`r`nZeile: " + $lineNumber +
            $(if (-not [string]::IsNullOrWhiteSpace($sourceLine)) {
                "`r`n" + $sourceLine
            } else {
                ""
            })
        ) "Bestandsabgleich"

        $statusLabel.Text = "Bestandsabgleich abgebrochen."
    }
    finally {
        # Admin-Passwort und Basic-Auth-Header nicht aufbewahren.
        $adminPassword = $null

        if ($null -ne $headers) {
            $headers.Clear()
            $headers = $null
        }

        $btnCreate.Enabled = $true
        $btnSave.Enabled = $true
        $root.Enabled = $true
    }
}

# --------------------------------------------------------------------
# Oberfläche
# --------------------------------------------------------------------

$settings = Load-Settings
$script:OutputText = $settings.OutputText

$form = New-Object System.Windows.Forms.Form
$form.Text = "Nextcloud Benutzerverwaltung"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1040,740)
$form.MinimumSize = New-Object System.Drawing.Size(940,690)
$form.Font = New-Object System.Drawing.Font("Segoe UI",10)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 500
$toolTip.ReshowDelay = 150
$toolTip.ShowAlways = $true

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = "Fill"
$root.ColumnCount = 1
$root.RowCount = 6
$root.Padding = New-Object System.Windows.Forms.Padding(10,8,10,8)

$root.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
)
$root.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
)
$root.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
)
$root.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
)
$root.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100))
)
$root.RowStyles.Add(
    (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))
)

$form.Controls.Add($root)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Nextcloud Benutzerverwaltung"
$lblTitle.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    16,
    [System.Drawing.FontStyle]::Bold
)
$lblTitle.AutoSize = $true
$lblTitle.Margin = New-Object System.Windows.Forms.Padding(0,0,0,7)
$root.Controls.Add($lblTitle,0,0)

# --------------------------------------------------------------------
# Bereich 1: lokale CSV-Bearbeitung
# --------------------------------------------------------------------

$localGroup = New-Object System.Windows.Forms.GroupBox
$localGroup.Text = "1. CSV lokal bearbeiten"
$localGroup.Dock = "Fill"
$localGroup.AutoSize = $true
$localGroup.Padding = New-Object System.Windows.Forms.Padding(10,8,10,8)
$localGroup.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    10,
    [System.Drawing.FontStyle]::Bold
)
$root.Controls.Add($localGroup,0,1)

$localLayout = New-Object System.Windows.Forms.TableLayoutPanel
$localLayout.Dock = "Fill"
$localLayout.AutoSize = $true
$localLayout.ColumnCount = 1
$localLayout.RowCount = 3
$localGroup.Controls.Add($localLayout)

$localInfo = New-Object System.Windows.Forms.Label
$localInfo.AutoSize = $true
$localInfo.Font = New-Object System.Drawing.Font("Segoe UI",9.5)
$localInfo.ForeColor = [System.Drawing.Color]::DimGray
$localInfo.Text = "Diese Tätigkeiten bearbeiten nur lokale Dateien. Nextcloud wird dabei nicht verändert."

$txtCsv = New-TextBox
$txtCsv.Text = $settings.CsvFile

$btnCsvBrowse = New-Button "..."
$btnCsvBrowse.Width = 42
$btnCsvBrowse.AutoSize = $false
$btnCsvBrowse.Height = 29

$csvPanel = New-Object System.Windows.Forms.TableLayoutPanel
$csvPanel.Dock = "Fill"
$csvPanel.AutoSize = $true
$csvPanel.ColumnCount = 3
$csvPanel.Margin = New-Object System.Windows.Forms.Padding(0,5,0,4)
$csvPanel.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))
)
$csvPanel.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100))
)
$csvPanel.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))
)

$lblCsv = New-Label "CSV-Datei"
$lblCsv.Font = New-Object System.Drawing.Font("Segoe UI",10)
$csvPanel.Controls.Add($lblCsv,0,0)
$csvPanel.Controls.Add($txtCsv,1,0)
$csvPanel.Controls.Add($btnCsvBrowse,2,0)

$localButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$localButtons.Dock = "Fill"
$localButtons.AutoSize = $true
$localButtons.WrapContents = $false
$localButtons.Margin = New-Object System.Windows.Forms.Padding(0)

$btnCsvEdit = New-Button "CSV bearbeiten"
$btnCsvTest = New-Button "CSV prüfen"
$btnGroups = New-Button "Gruppenzuordnungen bearbeiten"

$localButtons.Controls.AddRange(@(
    $btnCsvEdit,
    $btnCsvTest,
    $btnGroups
))

$localLayout.Controls.Add($localInfo,0,0)
$localLayout.Controls.Add($csvPanel,0,1)
$localLayout.Controls.Add($localButtons,0,2)

# --------------------------------------------------------------------
# Bereich 2: Nextcloud
# --------------------------------------------------------------------

$cloudGroup = New-Object System.Windows.Forms.GroupBox
$cloudGroup.Text = "2. Nextcloud verwalten"
$cloudGroup.Dock = "Fill"
$cloudGroup.AutoSize = $true
$cloudGroup.Padding = New-Object System.Windows.Forms.Padding(10,8,10,8)
$cloudGroup.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    10,
    [System.Drawing.FontStyle]::Bold
)
$root.Controls.Add($cloudGroup,0,2)

$cloudLayout = New-Object System.Windows.Forms.TableLayoutPanel
$cloudLayout.Dock = "Fill"
$cloudLayout.AutoSize = $true
$cloudLayout.ColumnCount = 2
$cloudLayout.RowCount = 7
$cloudLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,220))
)
$cloudLayout.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100))
)
$cloudGroup.Controls.Add($cloudLayout)

$cloudInfo = New-Object System.Windows.Forms.Label
$cloudInfo.AutoSize = $true
$cloudInfo.Font = New-Object System.Drawing.Font("Segoe UI",9.5)
$cloudInfo.ForeColor = [System.Drawing.Color]::DimGray
$cloudInfo.Text = "Bei Aktionen mit Nextcloud wird das Admin-Passwort erst dann abgefragt, wenn es tatsächlich benötigt wird."
$cloudLayout.Controls.Add($cloudInfo,0,0)
$cloudLayout.SetColumnSpan($cloudInfo,2)

$txtCloud = New-TextBox
$txtCloud.Text = $settings.NextcloudUrl

$txtAdmin = New-TextBox
$txtAdmin.Text = $settings.AdminName

$txtProtectedUsers = New-TextBox
$txtProtectedUsers.Text = $settings.ProtectedUsers

$script:PasswordGenerateText = "Passwort automatisch erzeugen"
$script:PasswordEmailText = "E-Mail zum Setzen des Passworts"

$cbPasswordMode = New-Combo @(
    $script:PasswordGenerateText,
    $script:PasswordEmailText
)
$cbPasswordMode.Width = 300

if ($settings.PasswordMode -eq "email") {
    Set-ComboText $cbPasswordMode $script:PasswordEmailText
}
else {
    Set-ComboText $cbPasswordMode $script:PasswordGenerateText
}

$cbPasswordLength = New-Combo @(
    "8","10","12","14","16","20","24","32"
)
$cbPasswordLength.Width = 85
Set-ComboText $cbPasswordLength ([string]$settings.PasswordLength)

$passwordPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$passwordPanel.Dock = "Fill"
$passwordPanel.AutoSize = $true
$passwordPanel.WrapContents = $false
$passwordPanel.Margin = New-Object System.Windows.Forms.Padding(0)

$lblLength = New-Label "Länge"
$lblLength.Font = New-Object System.Drawing.Font("Segoe UI",10)
$lblLength.Margin = New-Object System.Windows.Forms.Padding(18,7,5,2)

$passwordPanel.Controls.AddRange(@(
    $cbPasswordMode,
    $lblLength,
    $cbPasswordLength
))

$script:LanguageFormalText = "de_DE (Förmlich: Sie)"
$script:LanguagePersonalText = "de (Persönlich: Du)"

$cbLanguage = New-Combo @(
    $script:LanguageFormalText,
    $script:LanguagePersonalText
)
$cbLanguage.Width = 235

if ([string]$settings.Language -eq "de") {
    Set-ComboText $cbLanguage $script:LanguagePersonalText
}
else {
    Set-ComboText $cbLanguage $script:LanguageFormalText
}

$languagePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$languagePanel.Dock = "Fill"
$languagePanel.AutoSize = $true
$languagePanel.WrapContents = $false
$languagePanel.Margin = New-Object System.Windows.Forms.Padding(0)

$languagePanel.Controls.Add($cbLanguage)

$cloudLayout.Controls.Add((New-Label "Nextcloud-Adresse"),0,1)
$cloudLayout.Controls.Add($txtCloud,1,1)

$cloudLayout.Controls.Add((New-Label "Admin-Benutzername"),0,2)
$cloudLayout.Controls.Add($txtAdmin,1,2)

$cloudLayout.Controls.Add((New-Label "Wenn CSV-Passwort leer ist"),0,3)
$cloudLayout.Controls.Add($passwordPanel,1,3)

$cloudLayout.Controls.Add((New-Label "Sprache neuer Benutzer"),0,4)
$cloudLayout.Controls.Add($languagePanel,1,4)

$cloudActions = New-Object System.Windows.Forms.FlowLayoutPanel
$cloudActions.Dock = "Fill"
$cloudActions.AutoSize = $true
$cloudActions.WrapContents = $false
$cloudActions.Margin = New-Object System.Windows.Forms.Padding(0,7,0,0)

$btnExport = New-Button "Bestand als CSV exportieren"
$btnCreate = New-Button "Bestand abgleichen"

$cloudActions.Controls.AddRange(@(
    $btnExport,
    $btnCreate
))

$cloudActions.Margin = New-Object System.Windows.Forms.Padding(0,8,0,0)
$cloudLayout.Controls.Add((New-Label "Vor Löschung geschützt"),0,5)
$cloudLayout.Controls.Add($txtProtectedUsers,1,5)
$cloudLayout.Controls.Add((New-Label "Aktionen in Nextcloud"),0,6)
$cloudLayout.Controls.Add($cloudActions,1,6)

$toolTip.SetToolTip(
    $txtProtectedUsers,
    "Kontonamen durch Kommas trennen, zum Beispiel admin,backupkonto. Diese Konten werden nicht gelöscht. Das verwendete Admin-Konto ist zusätzlich immer geschützt. Andere Daten und Gruppen können weiterhin aktualisiert werden."
)

# --------------------------------------------------------------------
# Bereich 3: Ausgabe / Protokoll
# --------------------------------------------------------------------

$utilityGroup = New-Object System.Windows.Forms.GroupBox
$utilityGroup.Text = "3. Ausgabe und Protokoll"
$utilityGroup.Dock = "Fill"
$utilityGroup.AutoSize = $true
$utilityGroup.Padding = New-Object System.Windows.Forms.Padding(10,8,10,8)
$utilityGroup.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    10,
    [System.Drawing.FontStyle]::Bold
)
$root.Controls.Add($utilityGroup,0,3)

$utilityLayout = New-Object System.Windows.Forms.TableLayoutPanel
$utilityLayout.Dock = "Fill"
$utilityLayout.AutoSize = $true
$utilityLayout.ColumnCount = 1
$utilityLayout.RowCount = 2
$utilityGroup.Controls.Add($utilityLayout)

$utilityInfo = New-Object System.Windows.Forms.Label
$utilityInfo.AutoSize = $true
$utilityInfo.Font = New-Object System.Drawing.Font("Segoe UI",9.5)
$utilityInfo.ForeColor = [System.Drawing.Color]::DimGray
$utilityInfo.Text = "Hilfen und Ausgaben der Anwendung. Diese Funktionen ändern keine Benutzer in Nextcloud."

$utilityPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$utilityPanel.Dock = "Fill"
$utilityPanel.AutoSize = $true
$utilityPanel.WrapContents = $false
$utilityPanel.Margin = New-Object System.Windows.Forms.Padding(0,6,0,0)

$btnOutputText = New-Button "Ausgabetext..."
$btnOutput = New-Button "Ausgabeordner"
$btnLog = New-Button "Log anzeigen"

$utilityPanel.Controls.AddRange(@(
    $btnOutputText,
    $btnOutput,
    $btnLog
))

$utilityLayout.Controls.Add($utilityInfo,0,0)
$utilityLayout.Controls.Add($utilityPanel,0,1)

# --------------------------------------------------------------------
# Statusleiste
# --------------------------------------------------------------------

$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock = "Fill"
$bottom.AutoSize = $true
$bottom.ColumnCount = 3
$bottom.Margin = New-Object System.Windows.Forms.Padding(0,5,0,0)

$bottom.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100))
)
$bottom.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute,190))
)
$bottom.ColumnStyles.Add(
    (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))
)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Bereit"
$statusLabel.AutoSize = $true
$statusLabel.Margin = New-Object System.Windows.Forms.Padding(3,8,8,3)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = "Fill"
$progress.Height = 20
$progress.Margin = New-Object System.Windows.Forms.Padding(4,6,8,3)

$btnSave = New-Button "Einstellungen speichern"

$bottom.Controls.Add($statusLabel,0,0)
$bottom.Controls.Add($progress,1,0)
$bottom.Controls.Add($btnSave,2,0)

$root.Controls.Add($bottom,0,5)

# --------------------------------------------------------------------
# Tooltips
# --------------------------------------------------------------------

$toolTip.SetToolTip(
    $btnCsvEdit,
    "Öffnet die ausgewählte CSV-Datei im Windows-Editor. Nextcloud wird nicht verändert."
)

$toolTip.SetToolTip(
    $btnCsvTest,
    "Prüft die CSV lokal auf Kopfzeile, fehlende und doppelte Benutzernamen sowie benötigte E-Mail-Adressen. Nextcloud wird nicht verändert."
)

$toolTip.SetToolTip(
    $btnGroups,
    "Bearbeitet Gruppenzuordnungen in einer neuen CSV. Nur die Gruppennamen werden zuvor aus Nextcloud gelesen; die Änderungen selbst werden nicht direkt nach Nextcloud geschrieben."
)

$toolTip.SetToolTip(
    $btnExport,
    "Liest den aktuellen Benutzerbestand aus Nextcloud und speichert ihn im gleichen CSV-Format wie der Sollbestand."
)

$toolTip.SetToolTip(
    $btnCreate,
    "Vergleicht die CSV als Sollbestand mit Nextcloud. Löschungen außerhalb der CSV brauchen eine zusätzliche Freigabe in der Vorschau für diesen Lauf. Konten der Schutzliste und das verwendete Admin-Konto werden nicht gelöscht."
)

$toolTip.SetToolTip(
    $btnOutputText,
    "Bearbeitet den Text, der am Anfang jeder erzeugten Zugangsdaten-TXT-Datei steht. Es werden dabei keine Benutzer in Nextcloud geändert."
)

$toolTip.SetToolTip(
    $btnOutput,
    "Öffnet den Ordner mit den erzeugten Zugangsdaten-Dateien."
)

$toolTip.SetToolTip(
    $btnLog,
    "Öffnet die Logdatei. Vor Weitergabe auf sensible Angaben und Fehlerdetails prüfen."
)

$toolTip.SetToolTip(
    $btnCsvBrowse,
    "CSV-Datei über einen Windows-Dateidialog auswählen."
)

$toolTip.SetToolTip(
    $txtCloud,
    "Adresse der Nextcloud-Instanz."
)

$toolTip.SetToolTip(
    $txtAdmin,
    "Admin-Benutzername für Nextcloud. Das Passwort wird nicht im Hauptfenster gespeichert oder angezeigt."
)

$toolTip.SetToolTip(
    $cbPasswordMode,
    "Gilt nur für neu anzulegende Benutzer mit leerem Passwortfeld in der CSV."
)

$toolTip.SetToolTip(
    $cbPasswordLength,
    "Länge des automatisch erzeugten Passworts. Wird nur bei automatischer Passworterzeugung verwendet."
)

$toolTip.SetToolTip(
    $cbLanguage,
    "de_DE = förmliche Ansprache mit 'Sie'. de = persönliche Ansprache mit 'Du'."
)

$toolTip.SetToolTip(
    $btnSave,
    "Speichert Instanzadresse, Admin-Kontonamen, Schutzliste und weitere Einstellungen. Das Admin-Passwort und die Löschfreigabe werden nicht gespeichert."
)

# --------------------------------------------------------------------
# Ereignisse
# --------------------------------------------------------------------

$cbPasswordMode.Add_SelectedIndexChanged({
    $cbPasswordLength.Enabled = ($cbPasswordMode.SelectedIndex -eq 0)
})

$btnCsvBrowse.Add_Click({
    Select-CsvFile
})

$btnCsvEdit.Add_Click({
    $path = Get-CurrentCsvPath

    if ($path) {
        Open-TextFile $path
    }
})

$btnCsvTest.Add_Click({
    try {
        [void](Read-AndValidateCsv $true)
        $statusLabel.Text = "CSV-Prüfung erfolgreich."
    }
    catch {
        Show-ErrorBox $_.Exception.Message "CSV-Prüfung"
        $statusLabel.Text = "CSV-Prüfung fehlgeschlagen."
    }
})

$btnGroups.Add_Click({
    Edit-CsvGroupMemberships
})

$btnExport.Add_Click({
    Export-NextcloudUsersToCsv
})

$btnOutputText.Add_Click({
    Edit-OutputText
})

$btnOutput.Add_Click({
    if (-not (Test-Path -LiteralPath $script:OutputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }

    Open-Path $script:OutputDir
})

$btnLog.Add_Click({
    if (-not (Test-Path -LiteralPath $script:LogFile -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $script:LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }

        Set-Content -LiteralPath $script:LogFile -Value "" -Encoding UTF8
    }

    Open-TextFile $script:LogFile
})

$btnSave.Add_Click({
    [void](Save-Settings)
})

$btnCreate.Add_Click({
    Start-Reconciliation
})

$form.Add_Shown({
    $cbPasswordLength.Enabled = ($cbPasswordMode.SelectedIndex -eq 0)
})

$form.Add_FormClosed({
    if ($null -ne $script:Rng) {
        $script:Rng.Dispose()
    }
})

[void]$form.ShowDialog()
