## 16. Schritt 2: die Konverter-Maschine

**Wir starten die VM, in der wir die Konvertierung durchführen**

📍 **Wo:** auf dem Bastion.

**Was „Konvertierung“ ist und warum es keinen Weg daran vorbei gibt.** Der Datenträger einer virtuellen Maschine ist eine Datei. VMware speichert sie in seinem eigenen Format, `VMDK`. KVM, auf dem die VMs in Cozystack laufen, versteht dieses Format nicht — es braucht `QCOW2`. Der Inhalt ist derselbe, Ihr CentOS mit allem Drum und Dran, aber die Verpackung ist eine andere. Konvertierung ist das Umpacken der Datei von einem Format in das andere; die Daten selbst ändern sich dabei nicht.

Darüber hinaus muss man anpassen, was darin steckt. Ein System, das in vSphere aufgewachsen ist, erwartet die virtuelle Hardware von VMware vorzufinden: seine eigenen Netzwerkkarten, seine eigenen Festplatten-Controller, die Treiber `vmxnet3` und `pvscsi`. Am neuen Ort ist die Hardware anders — `virtio`. Wenn Sie nicht vorab die passenden Treiber in das Boot-Image einschleusen, startet die Maschine und findet weder Datenträger noch Netzwerk. Auch darum kümmert sich die Konvertierung.

**Warum eine eigene Maschine und nicht die VM selbst.** Das Werkzeug heißt `virt-v2v`, es schleppt einen Berg an Abhängigkeiten mit sich und frisst Dutzende Gigabyte. Es auf dem gemeinsamen Bastion zu installieren, von dem aus alle arbeiten, ist eine schlechte Idee: er ist klein und es gibt nur einen für Sie alle. Einfacher ist es, im Cluster eine Wegwerf-Maschine direkt neben dem Storage hochzufahren, die Arbeit darin zu erledigen und sie wieder herunterzufahren.

Als Bonus ist das genau der Ansatz, mit dem die Konvertierung in echten Migrationsprojekten durchgeführt wird: der Konverter lebt neben den Daten und nicht auf jemandes Arbeitsplatzrechner über ein VPN.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

Wir warten auf den Zustand `Running` (drücken Sie Ctrl+C, um die Beobachtung zu beenden). Wir gehen **über die Konsole** hinein:

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

**Zugang zur Konverter-Maschine:**
```
login:    ubuntu
password: ubuntu
```

Um die Konsole zu verlassen — `Ctrl+]`. Wenn der Bildschirm leer ist, drücken Sie Enter.

⚠️ **Gehen Sie nicht über `virtctl ssh` hinein.** Bei früheren Workshops hat es bei niemandem funktioniert: es antwortet mit `exit status 255` und bricht die Verbindung ab. Die Konsole läuft über die Cluster-API und funktioniert immer. Dasselbe ist mit der Maus verfügbar — die Schaltfläche **VNC** auf der Seite der Maschine im Dashboard.

**Was genau dieser Befehl erzeugt hat.** Die Datei beschreibt zwei Objekte, deshalb tauchen im Dashboard zwei Einträge auf und nicht einer:

• **VM Disk** mit dem Namen `convert-tools` — ein 25Gi-Datenträger, geklont aus dem Katalog-Image `ubuntu-20.04`
• **VM Instance** mit dem Namen `convert` — die Maschine selbst, die diesen Datenträger einbindet

Eine VM existiert nie ohne Datenträger — deshalb wird der Datenträger immer zuerst und als eigenes Objekt erzeugt. Merken Sie sich das; in Schritt 4 sehen Sie genau dasselbe Paar.

⚠️ Und gleich ein Wort zu den Namen, sonst kommen Sie durcheinander. Das Objekt im Dashboard heißt `convert`, aber die Maschine, die es hochfährt, ist innerhalb des Clusters als **`vm-instance-convert`** bekannt — mit dem Präfix. Im Dashboard suchen Sie also nach `convert`, während Sie in `virtctl`-Befehlen `vm-instance-convert` schreiben.

🖱 **Über das Dashboard:** Sie erzeugen dieselben zwei Objekte von Hand, eines nach dem anderen.
**1)** **VM Disk → Deploy new**: Name `convert-tools`, source = **image**, Image `ubuntu-20.04`, Größe `25Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: Name `convert`, instance type `u1.large`, profile `ubuntu`, und in der Liste der Datenträger wählen Sie `convert-tools` — den, den Sie einen Schritt zuvor erstellt haben. Sie können dort gleich mit der Schaltfläche **VNC** hineingehen, dann braucht es weder ssh noch virtctl, alles läuft im Browser.

⚠️ Machen Sie den Datenträger nicht kleiner als 25Gi: ist er kleiner als das Image, geht der Klon nicht durch, und dann hängt der Datenträger im Zustand Terminating fest und steht im Weg.

⚠️ Das Manifest gibt bewusst das Image **ubuntu-20.04** an; ändern Sie es nicht. Auf 24.04 bootet die Maschine nicht, und auf 22.04 stolpert die Konvertierung über die alte Paketdatenbank in CentOS 7. Wir haben das geprüft, damit Sie es nicht prüfen müssen.
