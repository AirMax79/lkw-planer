# LKW-Planer – iPhone-App

Die App zeigt den LKW-Planer (https://airmax79.github.io/lkw-planer/) und ergänzt:
- GPS im Hintergrund – die Lenkzeit zählt auch bei gesperrtem Display weiter
- Mitteilungen: noch 30 / 15 min Lenkzeit, 4,5 h erreicht, Pause 15 / 30 / 45 min erfüllt,
  Blitzer (AT), Umfahrung, Parkplätze, 1 h vor Ende der Einsatzzeit
- Display bleibt an, solange die Live-Navigation läuft

Updates des Planers auf GitHub kommen automatisch in der App an.

## Installieren (Mac mit Xcode)
1. `LKWPlaner.xcodeproj` öffnen.
2. Links das blaue Projekt „LKWPlaner“ → Target „LKWPlaner“ → Reiter „Signing & Capabilities“ →
   bei „Team“ dein Apple-Konto wählen. Falls die Bundle-ID belegt ist: `com.airmax79.lkwplaner` leicht ändern.
3. iPhone per Kabel anschließen, oben als Ziel auswählen, ▶ drücken.
4. Am iPhone beim ersten Mal: Einstellungen › Datenschutz & Sicherheit › Entwicklermodus einschalten.
