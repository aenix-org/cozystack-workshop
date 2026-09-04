## 22. Phase 3. Wir werfen den Zoo weg

**Schritte 5, 7, 8, 9.** Der wertvollste Teil. In der herübergezogenen Maschine leben noch immer
ihre eigenen Postgres und Kafka — genau die, die jemand einmal installiert hat und seither
niemand mehr angefasst hat.

Wir nehmen sie **nicht** mit. Stattdessen nehmen wir fertige aus dem Cozystack-Katalog und
konfigurieren die Anwendung um. Der Unterschied ist einfach: Hinter einem Managed Service stehen
Replikation, automatische Backups und Monitoring; hinter einem selbstgebauten die Hoffnung, dass
die Person, die ihn eingerichtet hat, noch im Unternehmen arbeitet.

Die Reihenfolge ist so: Zuerst starten wir die Services (Schritt 5), dann richten wir die
Anwendung darauf aus (Schritt 7), dann legen wir in der Datenbank eine Tabelle an (Schritt 8)
und prüfen die gesamte Kette (Schritt 9).
