## 30. Schritt 9: die gesamte Kette prüfen

**Der Moment der Wahrheit**

⚠️ **Zuerst — innerhalb der virtuellen Maschine — firewalld herunterfahren.** Das migrierte CentOS
hat Regeln aus seinem früheren Leben übernommen und gibt nach außen nur SSH frei. Der
Anwendungsport ist geschlossen, und eine Port-Weiterleitung von Ihrem Laptop läuft in
`no route to host` — und das sieht aus wie „die Anwendung läuft nicht“.

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Prüfen Sie gleich dort, von innerhalb der Maschine, dass die Anwendung lebt:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — Sie können die Port-Weiterleitung machen. `503` — kehren Sie zum Netzwerk-Schritt zurück.

📍 **Als Nächstes — auf Ihrem Laptop.** Leiten Sie den Anwendungsport zu sich weiter:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
Schließen Sie das Fenster mit diesem Befehl nicht: der Tunnel lebt, solange er läuft.

⚠️ **Hier ist `vmi/` erforderlich, während es in `virtctl console` genau umgekehrt ist — dort
stört es.** Das ist kein Tippfehler und keine Marotte von uns: die beiden Befehle haben eine
unterschiedliche Ziel-Syntax. `port-forward` verlangt `Typ/Name` und antwortet ohne das Präfix mit
`target must contain type and name separated by '/'`. `console` erwartet nur den Namen und
antwortet mit dem Präfix mit `forbidden`, weil es das Wort `vmi` für den Namen der Maschine hält.

Wenn virtctl sich über einen Versionsunterschied zwischen Client und Cluster beschwert — das ist
eine Warnung, kein Fehler, und es stört nicht.

Wenn die Port-Weiterleitung trotzdem nicht hochkommt, lässt sich derselbe Tunnel über den Pod der Maschine herstellen:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <pod-name-from-output> 8080:8080
```

In einem anderen Terminalfenster:
```bash
# Gesundheit
curl -s http://localhost:8080/actuator/health

# eine Bestellung anlegen
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# prüfen, dass sie gespeichert wurde
curl -s http://localhost:8080/api/orders
```

Wenn die Bestellung angelegt wurde — haben Sie den gesamten Weg zurückgelegt. Die Anwendung ist
von VMware herübergekommen, läuft im Cluster, schreibt in eine verwaltete Datenbank und sendet
Ereignisse an eine verwaltete Queue.

Vor einer halben Stunde lebte dieses System noch auf ESXi.
