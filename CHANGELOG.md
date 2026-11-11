# Changelog

Jeder Abschnitt `## X.Y.Z` wird beim Tag `vX.Y.Z` automatisch als „Was testen“ in TestFlight eingetragen
(`.github/workflows/testflight.yml`). Text auf Deutsch, höchstens 4000 Zeichen. Fehlt der Abschnitt, stehen dort
die Commit-Titel seit dem letzten Tag.

## 0.9.19

- Steckdose direkt in der App einrichten (eigener Server): Einstellungen → Drucker → „Steckdose“. Home-Assistant-Adresse, Token und Steckdose eintragen (die Liste der Steckdosen lädt die App aus Home Assistant), Verbindung testen, „Bei Bedarf einschalten“ an- oder ausschalten. Bisher ging das nur auf der klassischen Webseite des Servers, die mit Server 0.52.0 wegfällt. Läuft der Server als Home-Assistant-Add-on, reicht die Wahl der Steckdose
- Bitte testen: beim COSMOS die Steckdose einrichten („Steckdosen aus Home Assistant laden“, Steckdose wählen, „Verbindung testen“, Speichern) – danach muss die Druckerseite „Eingerichtet: …“ zeigen und die Steuerung den Ein-/Ausschalter

## 0.9.18

- Mitteilungen (Server ab 0.51.0): Einstellungen → „Mitteilungen“ einschalten. Das Handy meldet sich, wenn ein Druck fertig oder abgebrochen ist, der Drucker pausiert oder einen Fehler meldet, die KI-Fehlererkennung anschlägt oder ein Druck nicht starten konnte – auch bei geschlossener App. Welche Meldungen kommen, lässt sich dort einstellen; „Testmitteilung senden“ prüft den Weg. Die Texte sind verschlüsselt, nur dein Handy kann sie lesen
- Live-Aktivität: Ein gestarteter Druck erscheint mit Fortschritt, Restzeit und Schicht auf dem Sperrbildschirm und in der Dynamic Island und wird vom Server aktualisiert; Drucke, die am Drucker oder in OrcaSlicer gestartet wurden, können ebenfalls eine bekommen
- „Einschalten und drucken“: Liegt nach dem Einschalten in einem Slot ein anderes Material, bricht der Server nicht mehr sofort ab, sondern wartet 10 Minuten. Die Mitteilung „Falsches Material im Slot“ hat die Knöpfe „Prüfen“ und „Nicht drucken“; in der App kannst du nach einer Rückfrage „Trotzdem drucken“. Ohne Antwort wird nicht gedruckt und die Steckdose wieder ausgeschaltet
- Bitte testen: Mitteilungen einschalten und „Testmitteilung senden“ (muss sofort ankommen, auch bei gesperrtem Handy). Dann einen kurzen Druck starten: Live-Aktivität auf dem Sperrbildschirm prüfen und am Ende die Mitteilung „Druck fertig“. Danach wie bei 0.9.17 ein anderes Material in einen Slot legen, Drucker aus, „Einschalten und drucken“ – die Mitteilung muss kommen und „Nicht drucken“ muss den Druck stoppen

## 0.9.17

- Drucken, wenn der Drucker aus ist (Server ab 0.50.0, Home-Assistant-Steckdose mit „bei Bedarf einschalten“ auf der Webseite): auf dem Prüf-Bildschirm heißt der Knopf dann „Einschalten und drucken“. Nach der gewohnten Bestätigung schaltet der Server die Steckdose ein, wartet, bis der Drucker und sein Filamentsystem bereit sind, und startet erst dann (wie bei OrcaSlicer); der Bildschirm zeigt, was gerade passiert
- Slots wählen, auch wenn der Drucker aus ist: Vorbereiten und Prüf-Bildschirm zeigen die zuletzt gesehenen Slots (mit Hinweis, wann sie zuletzt gesehen wurden)
- Vor dem Start prüft der Server die gewählten Slots noch einmal: Ist ein Slot jetzt leer oder liegt dort ein anderes Material als bei der Auswahl, wird nicht gedruckt und die App sagt, welcher Slot nicht passt. Eine andere Farbe vom gleichen Material ist in Ordnung
- Bitte testen: Drucker (COSMOS + CANVAS) über die Steckdose ausschalten, ein Modell vorbereiten (Slots müssen erscheinen), „Einschalten und drucken“ – der Drucker muss angehen und nach 1–3 Minuten drucken. Danach einmal eine Spule tauschen (anderes Material), Drucker aus, gleiche Auswahl: der Druck darf nicht starten und die Meldung muss den Slot nennen

## 0.9.16

- Einstellungen → Erweitert → „Aus einem CAD-Programm öffnen“ (Server ab 0.48.0): zeigt Adresse und Schlüssel, mit denen ein CAD-Programm wie SolidCraft ein Teil direkt an PocketPrint3D schickt (eigener Server: Zugangs-Token, Cloud: eigener Schlüssel, nur einmal sichtbar)
- Startseite: auf eigenen Servern (ab 0.49.0) erscheint „Neu im Eingangsordner“ mit Dateien, die ein CAD-Programm dort abgelegt hat; antippen öffnet die Druckvorbereitung, das Kreuz entfernt den Eintrag
- Startseite: Steht im Link-Feld kein Link, sondern ein Suchbegriff (z. B. „Benchy“), führen Enter oder „Weiter“ jetzt direkt zur Modellsuche mit diesem Begriff, statt die Meldung „Bitte einen Link einfügen“ zu zeigen. Links verhalten sich wie bisher. Die Tastatur des Feldes hat dafür jetzt eine Leertaste
- Bitte testen: mit einem Server ab 0.49.0 und eingehängtem Eingangsordner eine STL dort ablegen – nach wenigen Sekunden muss die Karte erscheinen und die Druckvorbereitung den Dateinamen zeigen; außerdem auf der Startseite „Benchy“ eintippen und Enter drücken (Suche-Tab mit Ergebnissen), dann einen Printables-Link einfügen und „Weiter“ (Vorbereiten wie bisher)

## 0.9.15

- Slots wieder da mit COSMOS 26.10.0: dessen neueres AFC meldet das Werkzeug einer Spur als Liste (`map: ["T3"]`) statt als `"T3"`. Dadurch hatte keine Spur mehr ein Werkzeug, beim Vorbereiten fehlten die Slots und der Druck ließ sich nicht starten. Beide Formen werden jetzt gelesen (direkte WLAN-Verbindung in der Cloud; mit eigenem Server braucht es Server 0.49.1)
- Bitte testen: COSMOS mit CANVAS, Druck vorbereiten – die Slots 1–4 müssen mit Material und Farbe erscheinen, der Druck muss sich starten lassen

## 0.9.12

- Steuerung → „Spule und NFC-Leser“ für Drucker mit nur einem Fach (z. B. Centauri Carbon ohne CANVAS, Prusa; sie haben kein Filament-Menü): Hier steht, welche Spule im Drucker ist (antippen zum Ändern), ein vom NFC-Leser gesehener unbekannter Chip lässt sich einer Spule zuordnen, und der Schlüssel für den NFC-Leser (ESP32 + PN5180, Server ab 0.38.0) wird erzeugt. Der Druck-Bildschirm schlägt diese Spule bei einfarbigen Drucken vor und bucht sie
- Bitte testen: bei einem Drucker ohne Filament-Menü Steuerung öffnen, Spule wählen, dann einen Druck vorbereiten – die Spule muss im Abschnitt „Spulen“ vorgewählt sein

## 0.9.11

- Zeitraffer: Drucke, die direkt am Drucker gestartet wurden (Einstellung „Zeitraffer immer erstellen“), zeigten beim Ansehen nur ein durchgestrichenes Play-Symbol. Ursache war der Server, behoben in Server 0.45.1. Kann ein Video nicht geladen werden, sagt die App das jetzt in Worten
- Bitte testen: nach dem Server-Update einen solchen Zeitraffer öffnen; er muss abspielen und sich speichern lassen

## 0.9.10

- Drucker-Tab: die Drucker erscheinen sofort, auch wenn einer ausgeschaltet ist. Bisher blieb die Seite leer, bis der ausgeschaltete Drucker nicht mehr antwortete; jetzt steht dort solange „Status wird abgefragt …“ und danach „Einschalten“. Mehrere Drucker werden gleichzeitig abgefragt
- Bitte testen: Drucker ausschalten, App neu öffnen und den Drucker-Tab aufrufen

## 0.9.9

- Einstellungen → Erweitert → Orca-Cloud-Konto (Server ab 0.45.0): Du wählst, wie oft der Server deine OrcaSlicer-Profile abholt (nur von Hand, stündlich, alle 6 Stunden oder täglich). Zusätzlich holt er beim Vorbereiten eines Drucks zuerst neue Profile, wenn der letzte Abgleich über 10 Minuten her ist (abschaltbar). Bei älteren Servern erscheint der Abschnitt nicht
- Bitte testen: mit gekoppeltem Orca-Cloud-Konto den Abgleich auf „Täglich“ und wieder zurück stellen, den Schalter „Beim Vorbereiten eines Drucks“ aus- und einschalten; die Auswahl muss nach dem erneuten Öffnen der Seite erhalten bleiben

## 0.9.7

- Drucker per Home Assistant ausschalten: Power-Symbol oben rechts auf der Druckerkarte im Drucker-Tab und oben rechts in der Steuerung. Es erscheint nur, wenn für den Drucker eine Home-Assistant-Steckdose eingerichtet ist und gerade kein Druck läuft, und fragt vor dem Ausschalten nach. Der bisherige Eintrag „Ausschalten“ unten in der Steuerung ist dafür weggefallen
- Bitte testen: Drucker im Leerlauf über das Power-Symbol ausschalten; während eines Drucks darf das Symbol nicht zu sehen sein

## 0.9.6

- Einstellungen → Drucker → Profile: Löschen jetzt wie in iOS üblich durch Wischen nach links (statt langem Drücken). Oben „Bearbeiten“ wählt mehrere Profile aus und löscht sie zusammen; Profile, die noch benutzt werden, bleiben mit einem Hinweis stehen
- Bitte testen: ein Profil wegwischen; mit „Bearbeiten“ zwei Profile auswählen und löschen

## 0.9.5

Filament-Menü, Spulen per NFC und Spulen-Quelle wie in der Android-App (Server 0.37.0 bis 0.39.0). Mit älteren Servern fehlen die neuen Bereiche einfach.

- Steuerung → „Filament“ (Bambu): pro AMS-Fach und externer Spule laden, entladen sowie Material und Farbe einstellen. Laden und Entladen fragen vorher und gehen nicht während eines Drucks
- Spule pro Fach: im Filament-Menü eine Spule zuordnen (aus der Liste oder per NFC). Der Druckbildschirm wählt und bucht sie dann von selbst
- NFC: jeder Chip (Aufkleber, Bambu-Chip, OpenPrintTag) lässt sich einmal mit einer Spule verknüpfen und wird danach erkannt. Spulenformular: „Von NFC-Tag lesen“ (OpenPrintTag) und „NFC-Chip verknüpfen“; Druckbildschirm: „Spule per NFC wählen“
- NFC-Leser am Drucker: Schlüssel im Filament-Menü erzeugen
- Einstellungen → Spoolman: die Wahl Cloud oder eigener Spoolman geht jetzt auch an den Server; Cloud-Konten können alle Spoolman-Spulen in die Cloud kopieren
- Bitte testen: Fach am P1S auf ein anderes Material stellen; einen NFC-Aufkleber verknüpfen und danach im Filament-Menü scannen. Ein Bambu-Chip (MIFARE Classic) wird vom iPhone eventuell nicht erkannt

## 0.9.4

Aufgeholt mit Server 0.44.0 (Bewegen, Laden/Entladen, Orca-Cloud-Konto). Mit älteren Servern fehlen die neuen Bereiche einfach.

- Steuerung → „Bewegen“: Achsen homen, mit dem Steuerkreuz X/Y/Z verfahren (Schrittweite wählbar), extrudieren und zurückziehen, Motoren aus, Makros des Druckers. Während eines Drucks gesperrt
- Filament laden und entladen: Material wählen, die Düse heizt vorher auf dessen Temperatur. Bei Bambu mit Fachwahl. Der Centauri führt beides als kurzen Auftrag aus
- Einstellungen → Erweitert → „Orca-Cloud-Konto“: eigene OrcaSlicer-Profile automatisch übernehmen (App-ID eintragen, mit einem Code koppeln; der Server holt die Profile alle 6 Stunden). Braucht Server 0.42.0
- Bitte testen: Centauri homen und um 10 mm verfahren (Kamera beobachten), danach erst Laden/Entladen; Orca-Kopplung mit einer echten App-ID

## 0.9.3

Braucht Server 0.40.0 (mit älteren Servern läuft alles wie bisher).

- Alle Drucke erscheinen unter „Aufträge“, auch solche, die direkt am Drucker gestartet wurden (zum Beispiel aus OrcaSlicer an den Drucker gesendet). Sie zeigen den Fortschritt und werden bis „Gedruckt“ oder „Abgebrochen“ verfolgt
- Einstellungen → Zeitraffer → „Zeitraffer immer erstellen“: der Schalter vor dem Drucken ist dann schon an. Beim eigenen Server nimmt der Server außerdem jeden Druck mit Kamera auf, auch die direkt gestarteten
- Bitte testen: aus OrcaSlicer direkt an den Drucker senden und nach etwa 30 Sekunden in „Aufträge“ schauen; „Zeitraffer immer erstellen“ einschalten und einen Druck aus OrcaSlicer starten, am Ende sollte „Zeitraffer ansehen“ erscheinen

## 0.9.2

Bambu Lab ohne Brücke, wie in der Android-App (Server 0.36.1). Ohne echten Bambu-Drucker gebaut: bitte vorsichtig testen.

- Cloud-Drucker hinzufügen → Typ „Bambu Lab“: die App spricht selbst im WLAN mit dem Drucker (MQTT und FTPS), eine Brücke ist nicht mehr nötig. Die Suche im WLAN findet Bambu-Drucker jetzt auch, das Modell kommt aus der Seriennummer
- Status, AMS-Fächer als Slots, Pause/Fortsetzen/Abbrechen, Hochladen und Drucken mit der Fächerwahl
- Der Drucker muss im LAN-Modus sein (neuere Firmware: zusätzlich Entwicklermodus). Startet er nicht, sagt die App das nach 45 Sekunden
- Bitte testen: Bambu im WLAN finden und mit Zugangscode hinzufügen, Status und AMS ansehen, „Nur hochladen“ (die Datei liegt dann auf der SD-Karte), erst danach einen kleinen Druck

## 0.9.1

Aufgeholt mit Server 0.36.1. Nur für Drucker hinter einer Brücke (PocketPrint3D Cloud).

- Bambu Lab (LAN-Modus) über eine Brücke hinzufügen: Typ „Bambu Lab“ mit Zugangscode, das Modell kommt aus der Seriennummer. Wichtig: Der Drucker muss im LAN-Modus sein
- Eigene Kamera (RTSP / HTTP) für Drucker hinter einer Brücke, z. B. eine IP-Kamera; die Adresse wird für die Brücke verschlüsselt, „Eigene Kamera entfernen“ löscht sie wieder
- Seitlich montierte Kamera: `#rotate=90` (oder 180, 270) ans Ende der Kamera-Adresse hängen, dann dreht der Server das Bild (braucht Server 0.36.1)
- Druckersuche über die Brücke: das WLAN des Handys geht als Hinweis mit (hilft Brücken im Docker-Netz, die das Heimnetz sonst nicht sehen)
- Bitte testen: Bambu über die Brücke hinzufügen (nur Hinzufügen und Status, kein Druck ohne Absicht starten), eigene Kamera eintragen und im Druckertab ansehen

## 0.9.0

Aufgeholt mit Server 0.34.0.

- Drucker hinzufügen: die App sucht ihn selbst im WLAN (Centauri Carbon, Klipper/COSMOS, Prusa, OctoPrint) – antippen, fertig. „Selbst eingeben“ bleibt. iOS fragt einmal nach dem Zugriff auf das lokale Netzwerk
- Cloud: Einstellungen → Erweitert → „Von überall drucken“ (Brücken). Code der Brücke eingeben oder eine Raspberry-Pi-Brücke im WLAN mit einem Tipp verbinden; ihre Drucker erscheinen von selbst, weitere kommen über die Brücke dazu. Adresse und Passwort werden für die Brücke verschlüsselt
- Drucker hinter einer Brücke: Status, Kamera, Steuerung und Drucken laufen über die Cloud, auch unterwegs
- Aufträge folgen dem Druck: „Fertig“ oder „Abgebrochen“ statt „Gestartet“, dazu „Nochmal drucken“
- Zeitraffer (Drucker mit Kamera): Schalter vor dem Start, danach Video ansehen und teilen
- Cloud-Drucker → „Aus OrcaSlicer senden“: Adresse und Schlüssel für OrcaSlicer am Computer
- Cloud-Spulen: Buchungen liegen im Konto und werden gebucht, wenn der Druck fertig ist, auch ohne offene App
- Vor dem Start fragt die App, ob die Druckplatte leer und das Material geladen ist (statt des Schalters)
- Bitte testen: Drucker im WLAN finden, Brücke verbinden, Zeitraffer

## 0.8.1

- Teilen → PocketPrint3D: zweiter Anlauf, damit sich die App öffnet. Die Erweiterung hat den Link an das eigene Teilen-Fenster geschickt statt an iOS; das hat nichts geöffnet
- Bitte testen: Link aus Safari / Printables-App, und eine STL- oder 3MF-Datei aus „Dateien“ teilen

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
