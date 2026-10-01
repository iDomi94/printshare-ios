# Changelog

Jeder Abschnitt `## X.Y.Z` wird beim Tag `vX.Y.Z` automatisch als „Was testen“ in TestFlight eingetragen
(`.github/workflows/testflight.yml`). Text auf Deutsch, höchstens 4000 Zeichen. Fehlt der Abschnitt, stehen dort
die Commit-Titel seit dem letzten Tag.

## 0.6.0

Aufgeholt mit Server 0.15.1: PocketPrint3D Cloud.

- Verbinden: neue Wahl „PocketPrint3D Cloud / Eigener Server“. Cloud = Anmeldung mit E-Mail-Adresse und 6-stelligem Code, kein eigener Server nötig
- Einstellungen in der Cloud: Konto mit „x von 30 Slices heute“, Abmelden, Konto löschen (zweimal bestätigen) und die Drucker des Kontos
- Drucker hinzufügen: Name, Typ (Centauri Carbon oder Klipper/COSMOS), COSMOS-Schalter und die Adresse im WLAN mit „Verbindung testen“. Die Adresse bleibt nur auf dem Handy
- Drucken in der Cloud: die App holt den G-Code aus der Cloud und schickt ihn selbst über das WLAN an den Drucker (Fortschritt wird angezeigt); Status, Pause, Fortsetzen und Abbrechen laufen ebenfalls direkt über das WLAN
- Bitte testen: Centauri (Original-Firmware) und COSMOS über WLAN, jeweils „Nur hochladen“ und Drucken
- Mit eigenem Server ändert sich nichts

## 0.4.0

- Vorschau: neuer Umschalter oben „Modell / Ganze Platte / 3D“. „3D“ zeigt die geslicte Platte räumlich (jede Linie mit Breite und Schichthöhe), mit einem Finger drehen, mit zwei Fingern zoomen, doppelt tippen setzt die Ansicht zurück
- Der Schicht-Regler blendet in 3D die Schichten darüber aus; Farben nach Linientyp oder Filament und die Legende (antippen zum Ausblenden) wirken auch in 3D
- Die 2D-Ansichten bleiben wie bisher

## 0.3.0

Aufgeholt mit Server 0.14.0.

- Neuer Abschnitt „Auf der Platte“ beim Vorbereiten: Anzahl der Kopien (der Slicer ordnet sie an, so viele wie passen), Lage (wie im Modell, automatisch hinlegen, nach vorne/hinten/links/rechts kippen, auf den Kopf) und Größe in Prozent
- In der Prüfung steht die Anordnung bei den Details; passen weniger Kopien als gewünscht, erscheint ein gelber Hinweis
- „Einstellungen ändern“ übernimmt die Anordnung
- Live-Kamerabild funktioniert jetzt (vorher „Kamerabild nicht verfügbar“, z. B. bei COSMOS/Moonraker); Vorschau und Standbild waren nicht betroffen

## 0.2.0

Aufgeholt mit Server 0.13.1.

- Neuer Name: PocketPrint3D
- Drucker über eine Home-Assistant-Steckdose einschalten (Druckerliste) und ausschalten (Steuerung, mit Bestätigung, nicht während eines Drucks)
- Eigene Qualitäts- und Materialprofile: in den Auswahllisten unter „Eigene Profile“, in den Druckereinstellungen aufgelistet (lange drücken zum Löschen)
- Slots in der Druckerliste als „Slot N“ in physischer Reihenfolge; Vorauswahl nimmt jeden Slot nur einmal und bei einer Farbe den Slot im Druckkopf

## 0.1.0

Erste native iOS-Version (Swift/SwiftUI), ersetzt den Expo-Build.

- Links teilen oder einfügen (Printables, Thingiverse, direkte Datei), Modelle suchen und Details ansehen
- Modelldateien vor dem Slicen in 3D ansehen (STL, 3MF mit Farben, OBJ)
- Mehrfarbige 3MF-Projekte: Slot (CANVAS/AFC) pro Farbe schon beim Vorbereiten wählen, Material folgt dem Slot
- Ergebnis prüfen (Zeit, Gramm pro Farbe, Schichten), 2D-Vorschau, G-Code teilen, Druckstart nur mit Bestätigung
- Drucker: Kamera (live und Standbild), Steuerung (Temperaturen mit Verlauf, Lüfter, Licht, Geschwindigkeit)
- Eigenes OrcaSlicer-Druckerprofil hochladen und zuweisen
- Kopplung per QR-Code, Heim- und Unterwegs-Adresse, Teilen-Erweiterung
