#!/usr/bin/env python3
"""Generate Localizable.xcstrings + L10nKeys.swift from mobile/src/lib/i18n.ts of the Expo app.

Usage: python3 scripts/gen_l10n.py path/to/printshare/mobile/src/lib/i18n.ts
The output is committed; run this only when the Expo texts change.
"""
import json, re, sys, pathlib

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
STR = r'"((?:[^"\\]|\\.)*)"'
TABLES = ["jobStates", "printerKinds", "rawStates", "plates", "lineTypes", "heaterNames", "fanNames", "lightNames",
          "speedModes", "powerStates", "kindNames", "printerTypes", "printerTypeHints", "infillNames"]
PREFIX = {"jobStates": "jobState", "printerKinds": "printerKind", "rawStates": "rawState", "plates": "plate",
          "lineTypes": "lineType", "heaterNames": "heater", "fanNames": "fan", "lightNames": "light",
          "speedModes": "speedMode", "powerStates": "powerState", "kindNames": "profileKind",
          "printerTypes": "printerTypeName", "printerTypeHints": "printerTypeHint",
          # upstream's names win over the native-only infillPattern.<name> texts below
          "infillNames": "infillPattern"}


def block(name_re: str) -> str:
    m = re.search(name_re, src)
    start = m.end()
    depth, i = 1, start
    while depth:
        ch = src[i]
        if ch == "{": depth += 1
        elif ch == "}": depth -= 1
        i += 1
    return src[start:i - 1]


def unesc(s: str) -> str:
    return json.loads('"' + s + '"')


def parse(body: str) -> dict:
    out = {}
    for tname in TABLES:
        m = re.search(tname + r":\s*\{", body)
        if not m:
            continue
        depth, i = 1, m.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(body[i], 0)
            i += 1
        inner = body[m.end():i - 1]
        for q, k, v in re.findall(r'(?:"([\w -]+)"|(\b\w+)):\s*' + STR, inner):
            out[f"{PREFIX[tname]}.{q or k}"] = unesc(v)
        body = body[:m.start()] + body[i:]
    body = re.sub(r"log:\s*\[.*?\]\s*(as \[RegExp, string\]\[\])?,", "", body, flags=re.S)
    for k, v in re.findall(r'\b(\w+):\s*' + STR, body):
        out[k] = unesc(v)
    return out


de = parse(block(r"const de = \{"))
en = parse(block(r"const en: Strings = \{"))
# English line types are OrcaSlicer's own names: i18n.ts only lists the ones it renames
for k in de:
    if k.startswith("lineType.") and k not in en:
        en[k] = k.split(".", 1)[1]
assert set(de) == set(en), (set(de) ^ set(en))

# Texts only the native app has (share sheet, camera permission …). Keys that i18n.ts has by now are taken from there.
EXTRA = {
    "preview": ("Vorschau", "Preview"),
    "previewEmpty": ("Keine Vorschau verfügbar.", "No preview available."),
    "viewModel": ("Modell", "Model"),
    "viewBed": ("Platte", "Bed"),
    "layerOf": ("Schicht {n} von {total}", "Layer {n} of {total}"),
    "zHeight": ("Höhe {z} mm", "Height {z} mm"),
    "levelBed": ("Bett vor dem Druck nivellieren", "Level the bed before printing"),
    "lineTypes": ("Linientypen", "Line types"),
    "prevLayer": ("Vorherige Schicht", "Previous layer"),
    "nextLayer": ("Nächste Schicht", "Next layer"),
    "close": ("Schließen", "Close"),
    "openSettings": ("Einstellungen öffnen", "Open settings"),
    "cameraDenied": ("Der Kamerazugriff ist ausgeschaltet. Du kannst ihn in den Einstellungen erlauben.",
                     "Camera access is turned off. You can allow it in Settings."),
    "shareOpen": ("In PocketPrint3D öffnen", "Open in PocketPrint3D"),
    "serverVersionLabel": ("Server-Version", "Server version"),
    "shareGcode": ("G-Code teilen", "Share G-code"),
    "model3dUnsupported": ("Für {ext}-Dateien gibt es keine 3D-Ansicht. Drucken kannst du sie trotzdem.",
                           "There is no 3D view for {ext} files. You can still print them."),
    "model3dUnreadable": ("Diese Datei lässt sich nicht als 3D-Modell lesen. Drucken kannst du sie trotzdem.",
                          "This file can't be read as a 3D model. You can still print it."),
    "model3dHint": ("Mit einem Finger drehen, mit zwei Fingern zoomen.", "Drag to rotate, pinch to zoom."),
    "view3d": ("3D", "3D"),
    "preview3dHint": ("Mit einem Finger drehen, mit zwei Fingern zoomen, doppelt tippen setzt die Ansicht zurück. Der Regler blendet die Schichten darüber aus.",
                      "Drag to rotate, pinch to zoom, double-tap to reset the view. The slider hides the layers above."),
    # AFC/CANVAS: the user picks the printer's slot (as printed on the unit) instead of the upstream "lane" wording
    "slot": ("Slot", "Slot"),
    "slots": ("Slots", "Slots"),
    "slotN": ("Slot {n}", "Slot {n}"),
    "jobSlotsHint": ("Welcher Slot des Druckers jede Farbe druckt. Material und Farbe kommen vom Drucker. Ändern geht ohne neu zu slicen.",
                  "Which slot of the printer prints each colour. Material and colour come from the printer. Changing it needs no re-slicing."),
    "slotsPrepareHint": ("Material und Farbe kommen vom Drucker, das Material zum Slicen folgt dem Slot. Gedrückt halten, um das Material selbst zu wählen.",
                         "Material and colour come from the printer; the slicing material follows the slot. Long-press to choose the material yourself."),
    "slotEmptyWarn": ("{what}: {slot} ist leer – Filament laden oder einen anderen Slot wählen.",
                      "{what}: {slot} is empty – load filament or choose another slot."),
    "slotMaterialWarn": ("{what}: Profil ist {want}, in {slot} ist {have}.",
                         "{what}: the profile is {want}, {slot} holds {have}."),
    "chooseMaterial": ("Material wählen", "Choose material"),
    "errServerOld": ("Dein PocketPrint3D-Server kennt diese Funktion noch nicht. Aktualisiere ihn auf die neueste Version.",
                     "Your PocketPrint3D server does not have this feature yet. Update it to the latest version."),
    # infill pattern per print (server 0.15.2) with a true-to-scale preview
    "infillPattern": ("Füllmuster", "Infill pattern"),
    "infillHollow": ("Hohl – keine Füllung", "Hollow – no infill"),
    "infillNoPreview": ("Für dieses Muster gibt es keine Vorschau.", "No preview for this pattern."),
    "infillPreviewHint": ("Ungefähr in Originalgröße: 3 × 3 cm, eine Schicht von oben.",
                          "About real size: 3 × 3 cm, one layer seen from above."),
    "infillPreviewBelow": ("Blass: die Schicht darunter.", "Faded: the layer below."),
    # printables.com in a web view with the user's own login (test build)
    "printablesWebOpen": ("Printables.com", "Printables.com"),
    "printablesWebHint": ("Melde dich hier bei Printables an, dann siehst du deine Likes und Sammlungen. Die Anmeldung bleibt in der App gespeichert, PocketPrint3D sieht dein Passwort nicht. Auf einer Modellseite tippst du auf „Mit PocketPrint3D drucken“.",
                          "Sign in to Printables here to see your likes and collections. The login stays in the app; PocketPrint3D never sees your password. On a model page, tap “Print with PocketPrint3D”."),
    "printablesPrintThis": ("Mit PocketPrint3D drucken", "Print with PocketPrint3D"),
    "printablesDownloadHint": ("Downloads laufen über PocketPrint3D: öffne die Modellseite und tippe auf „Mit PocketPrint3D drucken“.",
                               "Downloads go through PocketPrint3D: open the model page and tap “Print with PocketPrint3D”."),
    "printablesLogout": ("Bei Printables abmelden", "Sign out of Printables"),
    "printablesLogoutConfirm": ("Anmeldung und Website-Daten von Printables in der App löschen?",
                                "Remove the Printables login and site data from the app?"),
    "webBack": ("Zurück", "Back"),
    "webForward": ("Vorwärts", "Forward"),
    "webReload": ("Neu laden", "Reload"),
    # prints started elsewhere (server 0.39.0) and "always make a time-lapse"
    "jobExternal": ("Direkt am Drucker gestartet", "Started on the printer"),
    "jobExternalSub": ("Dieser Druck kam nicht über PocketPrint3D, zum Beispiel direkt aus OrcaSlicer. Die App verfolgt ihn trotzdem bis zum Ende.",
                       "This print didn't come through PocketPrint3D, for example straight from OrcaSlicer. The app still follows it to the end."),
    "jobProgress": ("Fortschritt", "Progress"),
    "timelapseAlways": ("Zeitraffer immer erstellen", "Always make a time-lapse"),
    "timelapseAlwaysSub": ("Bei jedem Druck mit Kamera, auch bei Drucken, die direkt am Drucker gestartet wurden (zum Beispiel aus OrcaSlicer). Vor dem Drucken lässt er sich für einen Druck abschalten.",
                           "For every print with a camera, also prints started on the printer itself (for example from OrcaSlicer). You can still switch it off for one print before printing."),
    "timelapseAlwaysSubCloud": ("Der Schalter „Zeitraffer aufnehmen“ ist vor jedem Druck schon an (Drucker hinter einer Brücke mit Kamera).",
                                "The “Record a time-lapse” switch is already on before every print (printers behind a bridge with a camera)."),
    "timelapseAlwaysOld": ("Dein Server ist älter als 0.39.0: Die Einstellung gilt nur für Drucke aus dieser App.",
                           "Your server is older than 0.39.0: the setting only applies to prints from this app."),
}
# OrcaSlicer infill pattern names (sparse_infill_pattern) and a short note on what each is good for
INFILL = {
    "rectilinear": ("Geradlinig", "Rectilinear", "Schnell, wenig Material", "Fast, little material"),
    "grid": ("Gitter", "Grid", "Schnell und stabil", "Fast and strong"),
    "triangles": ("Dreiecke", "Triangles", "Stabil in der Fläche", "Strong in the plane"),
    "tri-hexagon": ("Tri-Hexagon", "Tri-hexagon", "Stabil, weniger Kreuzungen", "Strong, fewer crossings"),
    "cubic": ("Kubisch", "Cubic", "Stabil in alle Richtungen", "Strong in every direction"),
    "adaptivecubic": ("Adaptiv kubisch", "Adaptive cubic", "Wie kubisch, innen dünner – spart Material",
                      "Like cubic, sparser inside – saves material"),
    "honeycomb": ("Bienenwabe", "Honeycomb", "Sehr stabil, druckt langsamer", "Very strong, prints slower"),
    "3dhoneycomb": ("3D-Bienenwabe", "3D honeycomb", "Stabil, leicht federnd", "Strong, slightly springy"),
    "gyroid": ("Gyroid", "Gyroid", "Gleichmäßig stabil, gut für flexibles Filament",
               "Even strength, good for flexible filament"),
    "crosshatch": ("Kreuzschraffur", "Cross hatch", "Wechselt die Richtung in Schichtblöcken",
                   "Changes direction in blocks of layers"),
    "concentric": ("Konzentrisch", "Concentric", "Folgt der Außenform, gut für flexible Teile",
                   "Follows the outline, good for flexible parts"),
    "lightning": ("Blitz", "Lightning", "Stützt nur die Oberseite – am schnellsten, nicht stabil",
                  "Only holds up the top – fastest, not strong"),
}
for k, (dn, en_, dh, eh) in INFILL.items():
    EXTRA[f"infillPattern.{k}"] = (dn, en_)
    EXTRA[f"infillHint.{k}"] = (dh, eh)
for k, (d_, e_) in EXTRA.items():
    if k not in de:
        de[k], en[k] = d_, e_

strings = {}
for k in sorted(de):
    strings[k] = {"localizations": {
        "de": {"stringUnit": {"state": "translated", "value": de[k]}},
        "en": {"stringUnit": {"state": "translated", "value": en[k]}}}}
root = pathlib.Path(__file__).resolve().parent.parent
(root / "PrintShare/Resources/Localizable.xcstrings").write_text(
    json.dumps({"sourceLanguage": "de", "strings": strings, "version": "1.0"}, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8")


def case(k: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", k)


lines = ["// Generated by scripts/gen_l10n.py from the Expo app's i18n.ts - do not edit.", "",
         "enum L10nKey: String, CaseIterable, Sendable {"]
for k in sorted(de):
    lines.append(f'    case {case(k)} = "{k}"')
lines.append("}")
(root / "PrintShare/Util/L10nKeys.swift").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(len(de), "keys")
