## 30. Schritt 9: die gesamte Kette prüfen

**Der Moment der Wahrheit**

⚠️ **Zuerst — innerhalb der virtuellen Maschine — firewalld herunterfahren.** Das migrierte CentOS
hat Regeln aus seinem früheren Leben übernommen und gibt nach außen nur SSH frei. Der
Anwendungsport ist geschlossen, und von außen sieht das aus wie „die Anwendung läuft nicht“.

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Prüfen Sie gleich dort, von innerhalb der Maschine, dass die Anwendung lebt:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — die Anwendung antwortet. `503` — kehren Sie zum Netzwerk-Schritt zurück. Hier ist
`localhost` die Maschine, in der Sie sitzen: die Anwendung prüft sich selbst.

📍 **Als Nächstes — eine Prüfung von außen, über den Domainnamen.** Port-Weiterleitung wird auf
diesem Weg nicht benötigt: die Lehrkraft hat im Voraus einen `Ingress` in Ihrem Tenant angelegt,
und sobald die Anwendung innerhalb der Maschine auf `8080` lauscht, wird der Shop unter
`https://app.workshopXX.workshop.aenix.io` veröffentlicht (`XX` ist Ihre Nummer). Öffnen Sie ihn
im Browser auf Ihrem Laptop — oder prüfen Sie mit `curl` direkt auf dem Bastion:

```bash
# Gesundheit
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

# eine Bestellung anlegen
curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# prüfen, dass sie gespeichert wurde
curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

⚠️ Solange die app-VM noch nicht hochgefahren oder noch am Booten ist, antwortet die Domain mit
`503` — das ist normal: der `Ingress` wartet auf das Backend. Sobald Sie `200` sehen, lauscht die
Maschine im Inneren auf `8080`.

Wenn die Bestellung angelegt wurde — haben Sie den gesamten Weg zurückgelegt. Die Anwendung ist
von VMware herübergekommen, läuft im Cluster, schreibt in eine verwaltete Datenbank und sendet
Ereignisse an eine verwaltete Queue.

Vor einer halben Stunde lebte dieses System noch auf ESXi.
