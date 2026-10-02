# Changelog

Jeder Abschnitt `## X.Y.Z` wird beim Tag `vX.Y.Z` automatisch als „Was testen“ in TestFlight eingetragen
(`.github/workflows/testflight.yml`). Text auf Deutsch, höchstens 4000 Zeichen. Fehlt der Abschnitt, stehen dort
die Commit-Titel seit dem letzten Tag.

## 0.8.0

Aufgeholt mit Server 0.23.0. Enthält die Teilen-Korrektur aus 0.7.91.

- Druckereinstellungen → „Aus der Orca Cloud“: Link einer geteilten Profilsammlung (cloud.orcaslicer.com/b/…) einfügen, die Profile landen auf dem Server, ein passendes Druckerprofil wird gleich verwendet
- Neue Spule → „Aus Datenbank wählen“: Marke und Filament aus SpoolmanDB, Name, Material, Farbe, Gewicht und Leerspulengewicht werden ausgefüllt
- Entdecken: Karte „MakerWorld“, und ein MakerWorld-Link im Suchfeld öffnet die Modellseite
- Einstellungen → Manyfold (eigener Server): eigene Modellbibliothek als Quelle in „Entdecken“
- Einstellungen → KI-Fehlererkennung (eigener Server, Obico-ML-Dienst nötig): Druckertab zeigt „wird überwacht“, bei Verdacht ein rotes Feld mit Kamerabild, „Fehlalarm“ oder „Pausieren“
- Teilen → PocketPrint3D öffnet die App wieder von selbst
- Bitte testen: Orca-Cloud-Link, Spule aus Datenbank, Manyfold-Suche mit Vorschaubildern

## 0.7.91

- Teilen → PocketPrint3D: die App öffnet sich danach wieder von selbst. Die Erweiterung wollte die App öffnen, bevor das Teilen-Fenster ganz zu sehen war; das hat iOS still ignoriert
- Klappt es trotzdem nicht, steht im Teilen-Fenster „Gespeichert. Öffne PocketPrint3D, um weiterzumachen.“ und das Modell erscheint beim nächsten Öffnen der App
- Bitte testen: Link aus Safari / Printables-App, und eine STL- oder 3MF-Datei aus „Dateien“ teilen

## 0.7.90

Printables.com in der App (enthält alles aus 0.7.0).

- „Entdecken“ → oben rechts „Printables.com“: die Printables-Webseite in der App. Dort mit dem Prusa-Konto anmelden, dann gibt es Likes und Sammlungen
- Bitte testen: bleibt die Anmeldung nach dem Beenden der App erhalten? Klappt die Anmeldung mit E-Mail, mit Apple, mit Google (Google sperrt Anmeldungen in eingebetteten Webseiten vermutlich)?
- Auf einer Modellseite „Mit PocketPrint3D drucken“: öffnet das Modell wie aus der Suche, der Server lädt es wie bisher ohne Anmeldung
- Download-Knöpfe der Webseite laden nichts aufs Handy, sondern öffnen ebenfalls das Modell in PocketPrint3D
- Menü oben rechts: „Bei Printables abmelden“ löscht Anmeldung und Website-Daten von Printables in der App

## 0.7.0

Aufgeholt mit Server 0.17.1: Spoolman, Spulen in der Cloud, MakerWorld. Enthält die Korrekturen aus 0.6.1.

- Einstellungen → Spoolman: eigene Spoolman-Adresse eintragen und testen, oder (Cloud-Konto) „Spulen in der Cloud“ nutzen. Cloud-Spulen anlegen, bearbeiten, kopieren, archivieren, löschen
- Nach dem Slicen: Abschnitt „Spulen“ mit einer Spule pro Farbe, Warnung bei zu wenig Filament oder anderem Material
- Nach dem Druck bucht die App das Filament ab (Druckertab). Bei abgebrochenem Druck fragt sie: alles, nur den gedruckten Teil oder nichts. Klipper mit eigener Spoolman-Anbindung bucht selbst
- MakerWorld-Links (auch über „Teilen“) öffnen die Modellseite mit Druckprofilen und einem Knopf zu MakerWorld; die 3MF dann über „Teilen“ an die App schicken
- Bitte testen: Spoolman zu Hause, Cloud-Spulen, Abbuchen nach einem Druck, MakerWorld-Link

## 0.6.1

- Cloud: Ist im Konto noch kein Drucker angelegt, bleibt „Druck vorbereiten“ nicht mehr leer. Die App sagt das und
  bietet „Drucker hinzufügen“ an; danach geht es direkt weiter.
- Cloud: Geänderte Druckereinstellungen (z. B. der COSMOS-Haken) erscheinen nach dem Speichern auch beim nächsten
  Öffnen. Die App zeigte teils eine zwischengespeicherte alte Druckerliste; Anfragen an Server und Drucker gehen
  jetzt immer frisch übers Netz.

## 0.6.0

Aufgeholt mit Server 0.15.3: PocketPrint3D Cloud, auch für Prusa (PrusaLink) und OctoPrint. Enthält das Füllmuster aus 0.5.0.

- Verbinden: neue Wahl „PocketPrint3D Cloud / Eigener Server“. Cloud = Anmeldung mit E-Mail-Adresse und 6-stelligem Code, kein eigener Server nötig
- Einstellungen in der Cloud: Konto mit „x von 30 Slices heute“, Abmelden, Konto löschen (zweimal bestätigen) und die Drucker des Kontos
- Drucker hinzufügen: Name, Typ (Elegoo Centauri Carbon, Klipper/COSMOS, Prusa mit PrusaLink oder OctoPrint), bei Prusa/OctoPrint das Druckermodell, und die Adresse im WLAN mit „Verbindung testen“. Prusa braucht das PrusaLink-Passwort vom Druckerdisplay, OctoPrint einen API-Key. Adresse, Passwort und Key bleiben nur auf dem Handy
- Drucken in der Cloud: die App holt den G-Code aus der Cloud und schickt ihn selbst über das WLAN an den Drucker (Fortschritt wird angezeigt); Status, Pause, Fortsetzen und Abbrechen laufen ebenfalls direkt über das WLAN
- Bitte testen: Centauri (Original-Firmware), COSMOS, Prusa und OctoPrint über WLAN, jeweils „Nur hochladen“ und Drucken
- Mit eigenem Server ändert sich nichts

## 0.5.0

Braucht Server 0.15.2 (ältere Server: die Auswahl erscheint nicht).

- Beim Vorbereiten unter „Mehr“: neues Feld „Füllmuster“ (Geradlinig, Gitter, Dreiecke, Kubisch, Bienenwabe, Gyroid, Konzentrisch, Blitz …) mit kleinem Bild und kurzem Hinweis, wofür es gut ist
- Darunter ein 3 × 3 cm großes Bild in ungefähr echter Größe: so sieht eine Schicht mit dem gewählten Muster und der gewählten Füllung von oben aus. Ändert sich mit Muster und Prozent sofort. Bitte mit einem Lineal nachmessen, ob es wirklich 3 cm sind (vor allem auf iPad und mit „Bildschirmzoom“)
- In der Prüfung steht ein geändertes Füllmuster bei den geänderten Werten

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
