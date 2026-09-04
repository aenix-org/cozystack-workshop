# Chat-Nachrichten für den Workshop — der Weg über den Bastion

Eine Datei, eine Nachricht. Posten Sie sie im Verlauf der praktischen Arbeit, nicht alle auf einmal.

Dieser Satz ist für Teilnehmende gedacht, die **über den gemeinsamen Bastion (VM)** arbeiten:
Die Werkzeuge und der Cluster-Zugang liegen bereits auf dem Bastion, die Tenant-Nummer ist vorab in die Dateien eingetragen,
und die Anwendung wird über ihren Domainnamen geprüft. Der Satz für die Arbeit vom eigenen Laptop aus liegt
in [`../../laptop/chat/`](../../laptop/chat/).

Die Nummerierung der Nachrichten läuft durchgehend mit dem Laptop-Satz (deshalb hat sie Lücken: Die Beiträge zur
Installation der Werkzeuge werden hier nicht benötigt).

| # | Nachricht | Datei |
|---|---|---|
| 1 | Was wir eigentlich tun | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | Ein kleines Glossar: wie es bei Ihnen heißt und wie es hier heißt | [`02-glossary.md`](02-glossary.md) |
| 3 | Bevor Sie beginnen: was Sie brauchen | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | Am Bastion anmelden | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | Die Materialien liegen bereits auf dem Bastion | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | Dateikarte: was wo liegt und wo es läuft | [`11-file-map.md`](11-file-map.md) |
| 12 | Phase 1. Das Image aus vSphere herausholen | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | Genauer betrachtet: was in 01-bucket.yaml steckt | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | Schritt 1: Ihr eigener Speicher | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | Genauer betrachtet: was in 02-conversion-vm.yaml steckt | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | Schritt 2: die Konverter-Maschine | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | Genauer betrachtet: was convert.sh tut | [`17-convert-script.md`](17-convert-script.md) |
| 18 | Schritt 3: das Image konvertieren | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | Phase 2. Die Maschine am neuen Ort hochfahren | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | Genauer betrachtet: was in 03-app-vm.yaml steckt | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | Schritt 4: Ihre virtuelle Maschine | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | Phase 3. Den Zoo abschaffen | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | Genauer betrachtet: was in 04-managed.yaml steckt | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | Schritt 5: eine Datenbank und eine Warteschlange aus dem Katalog | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | Schritt 6: das Netzwerk in der Maschine reparieren | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | Erste Prüfung: Wir versuchen zu starten und stoßen auf einen Fehler | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | Schritt 7: die Anwendung auf die Managed Services umstellen | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | Schritt 8: warum die Anwendung immer noch abstürzt | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | Schritt 8: den Client installieren und das Schema einspielen | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | Schritt 9: die gesamte Kette prüfen | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | Wenn etwas nicht funktioniert | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | Nach dem Workshop | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
