## 21. Schritt 4: Ihre virtuelle Maschine

**Eine Maschine aus dem eigenen Image hochfahren**

📍 **Wo:** auf Ihrem Laptop.

⚠️ **Fahren Sie zuerst die Konverter-Maschine herunter** — sie hat ihre Aufgabe erledigt und belegt 8Gi Ihrer Quota.
Wenn Sie sie nicht loswerden, bleibt die neue Maschine in `Pending` hängen, und es sieht so aus,
als wäre die Testumgebung kaputt. In früheren Workshops sind hier fast alle steckengeblieben:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Das Image bleibt dabei im Bucket — daraus fahren wir die Maschine hoch.

Öffnen Sie nun `manifests/03-app-vm.yaml`, fügen Sie den presigned Link in das Feld `url` ein
und wenden Sie die Datei an:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

Zuerst lädt der Cluster das Image über den Link herunter und verteilt es auf die Replikate — das dauert ein, zwei Minuten.
Danach startet die Maschine.

Steigen wir hinein:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**Zugang zu Ihrer Maschine:**
```
login:    root
password: cozydemo
```

Um die Konsole zu verlassen — `Ctrl+]`.

**Hier haben Sie dasselbe Paar von Objekten wie bei der Konverter-Maschine**, nur wird der Disk nicht
aus dem Katalog genommen — er wird über Ihren Link heruntergeladen:

• **VM Disk** `app-1` — 10Gi, source = http, genau jene presigned URL
• **VM Instance** `app-1` — Profil `centos.7`, instance type `u1.medium`

Die Namen stimmen überein, und das ist in Ordnung: Disk und Maschine sind unterschiedliche Objekttypen. In
`virtctl`-Befehlen wird die Maschine wie beim letzten Mal mit ihrem Präfix angesprochen: **`vm-instance-app-1`**.

🖱 **Über das Dashboard:** **1)** **VM Disk → Deploy new**: Name `app-1`, source = **http**,
im URL-Feld — der presigned Link, Größe `10Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: Name `app-1`, instance type `u1.medium`,
Profil `centos.7`, Disk — `app-1`. Die Konsole — die Schaltfläche **VNC** auf der Seite der Maschine.

Achten Sie darauf, was Sie gerade getan haben: Sie haben eine virtuelle Maschine als Text beschrieben
und sie mit einem einzigen Befehl angewendet. Sie können diese Datei in ein Repository legen und
hundert genau solche Maschinen hochfahren, ohne einen einzigen Klick zu machen.
