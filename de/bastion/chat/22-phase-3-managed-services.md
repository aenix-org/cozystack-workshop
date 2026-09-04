## 22. Phase 3. Der Zoo fliegt raus

**Schritte 5, 7, 8, 9.** Der wertvollste Teil. Innerhalb der Maschine, die wir übernommen
haben, leben immer noch ihr eigenes Postgres und Kafka — genau die, die irgendwann jemand
installiert hat und die seither niemand mehr angefasst hat.

Wir nehmen sie **nicht** mit. Stattdessen holen wir uns fertige aus dem Cozystack-Katalog
und konfigurieren die Anwendung um. Der Unterschied ist einfach: Hinter einem Managed
Service stehen Replikation, automatische Backups und Monitoring; hinter einem
selbstgebauten die Hoffnung, dass die Person, die ihn aufgesetzt hat, noch im Unternehmen
arbeitet.

Die Reihenfolge ist so: Zuerst starten wir die Dienste (Schritt 5), dann richten wir die
Anwendung auf sie aus (Schritt 7), dann legen wir in der Datenbank eine Tabelle an
(Schritt 8) und prüfen die gesamte Kette (Schritt 9).
