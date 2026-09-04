## 27. Schritt 7: die Anwendung auf die verwalteten Dienste umstellen

**Fest verdrahtete Adressen durch Namen ersetzen**

📍 **Wo:** innerhalb Ihrer Maschine (app-VM), nach dem Neustart. Nicht auf dem Bastion.

📄 Dies ist der Inhalt von `scripts/connect-managed.sh`. Tippen Sie ihn ebenfalls von Hand ab — aus demselben Grund und weil es nur drei Befehle sind.

Öffnen Sie innerhalb der Maschine die Konfiguration der Anwendung:
```bash
cat /etc/orders/application.properties
```
Sie sehen dieselben `192.168.10.30` und `192.168.10.40`. Das ist der Schmerz jedes Legacy-Systems: Niemand erinnert sich mehr, warum es genau diese Adressen sind.

Ersetzen Sie sie durch die Dienstnamen (setzen Sie Ihre eigene Nummer statt `XX` ein):
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
(zwei Befehle statt eines mit Zeilenumbruch: Ein Zeilenumbruch geht beim Kopieren aus dem Chat oft verloren, und der Befehl wird nur zur Hälfte ausgeführt)

Prüfen Sie es:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` — die Anwendung sieht sowohl die Datenbank als auch die Warteschlange. Bei `503` gehen Sie zurück zum Schritt mit dem Netzwerk; höchstwahrscheinlich hat sich die Adresse nicht geändert.
