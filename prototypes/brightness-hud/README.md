# BrightnessHUDProbe

Ein Spike, kein Feature. Beantwortet zwei Fragen auf dieser Maschine:

1. Kann ein `CGEventTap` die F1/F2-Events **schlucken**, so dass der native
   macOS-Slider gar nicht erst erscheint?
2. Sieht ein selbstgebautes HUD-Panel nativ genug aus?

Setzt die Helligkeit des internen Displays echt (`DisplayServicesSetBrightness`),
in 16 Stufen wie das System, Shift+Option für Viertelschritte. Der Ausgangswert
wird bei jedem Tastendruck frisch gelesen statt mitgezählt — sonst driftet er,
sobald Auto-Brightness oder das Kontrollzentrum dazwischenfunken.

`--dry-run` schaltet das Schreiben ab und loggt nur.

Externe Displays werden nicht bedient — die brauchen DDC/CI über I2C.

Volume- und Media-Tasten werden bewusst nur geloggt und durchgereicht.

## Bauen und starten

```bash
cd prototypes/brightness-hud && ./build.sh
```

```bash
open prototypes/brightness-hud/build/BrightnessHUDProbe.app
```

Dann F1/F2 drücken und mitlesen:

```bash
tail -f ~/Library/Logs/BrightnessHUDProbe.log
```

Beenden:

```bash
killall BrightnessHUDProbe
```

## Der eigentliche Test

```bash
open -a prototypes/brightness-hud/build/BrightnessHUDProbe.app --args --observe
```

`--observe` reicht die Events durch — der native Slider erscheint weiter, das
eigene HUD daneben. Damit trennt man die zwei Fragen: kommen die Events an
(`--observe`), und lassen sie sich unterdrücken (Default).

`--tap hid|session|annotated` verschiebt den Tap in der Pipeline. `hid`
(Default) sitzt am weitesten vorne und hat die besten Chancen, dem System
zuvorzukommen; wenn dort etwas nicht durchkommt, ist `session` der Vergleich.

## Was zu erwarten ist

- `accessibility: granted` muss im Log stehen. Beim Start aus dem Terminal
  heraus erbt der Prozess ggf. den Grant des Terminals — das täuscht. Für ein
  ehrliches Ergebnis mit `open` starten.
- **Nach jedem `./build.sh` kann der Accessibility-Grant weg sein.** Die
  Ad-hoc-Signatur erzeugt jedes Mal einen neuen cdhash, und TCC sieht darin eine
  andere App. Alter Eintrag in Systemeinstellungen → Datenschutz → Bedienungs­hilfen
  entfernen und neu hinzufügen.
- `tap: disabled (timeout) — re-enabling` im Log ist der Grund, warum solche
  Features "irgendwann einfach aufhören". Der Probe fängt es ab; eine echte
  Implementierung muss das auch tun.
- Bei aktivem Secure Input (fokussiertes Passwortfeld) kann der Tap nichts
  sehen. Das ist eine Systemgrenze, kein Bug hier.

## Was der Spike *nicht* klärt

- DDC/CI für externe Displays.
- Verhalten mit mehreren Displays (welches Panel soll die Taste treffen?).
- Fn-Umschaltung (Systemeinstellung "F1, F2 usw. als Standard-Funktionstasten").
- Was passiert, wenn der Prozess stirbt, während der Tap aktiv ist.
