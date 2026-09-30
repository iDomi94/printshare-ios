# Changelog

Jeder Abschnitt `## X.Y.Z` wird beim Tag `vX.Y.Z` automatisch als „Was testen“ in TestFlight eingetragen
(`.github/workflows/testflight.yml`). Text auf Deutsch, höchstens 4000 Zeichen. Fehlt der Abschnitt, stehen dort
die Commit-Titel seit dem letzten Tag.

## 0.1.0

Erste native iOS-Version (Swift/SwiftUI), ersetzt den Expo-Build.

- Links teilen oder einfügen (Printables, Thingiverse, direkte Datei), Modelle suchen und Details ansehen
- Modelldateien vor dem Slicen in 3D ansehen (STL, 3MF mit Farben, OBJ)
- Mehrfarbige 3MF-Projekte: Slot (CANVAS/AFC) pro Farbe schon beim Vorbereiten wählen, Material folgt dem Slot
- Ergebnis prüfen (Zeit, Gramm pro Farbe, Schichten), 2D-Vorschau, G-Code teilen, Druckstart nur mit Bestätigung
- Drucker: Kamera (live und Standbild), Steuerung (Temperaturen mit Verlauf, Lüfter, Licht, Geschwindigkeit)
- Eigenes OrcaSlicer-Druckerprofil hochladen und zuweisen
- Kopplung per QR-Code, Heim- und Unterwegs-Adresse, Teilen-Erweiterung
