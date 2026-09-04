## 15. Genauer betrachtet: was in 02-conversion-vm.yaml steckt

Die Datei enthält **zwei** Objekte, getrennt durch eine `---`-Zeile. So packt YAML mehrere
Dokumente in eine Datei. Eine virtuelle Maschine kann nicht ohne Disk existieren, deshalb wird
die Disk separat beschrieben und immer zuerst erstellt.

```yaml
kind: VMDisk
metadata:
  name: convert-tools
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 25Gi
  storageClass: replicated
```

`kind: VMDisk` — die Disk für sich, ein eigenes Objekt. Daran muss man sich gewöhnen: In
vSphere ist eine Disk eine Eigenschaft der Maschine, hier ist sie eine eigenständige Entität,
die Sie im Voraus erstellen, an eine Maschine anhängen, wieder abhängen und an eine andere
anhängen können.

`source.image.name: ubuntu-20.04` — woher der Inhalt bezogen wird. Das ist derselbe
Image-Katalog aus der Übersicht oben: Cozystack hat das offizielle Ubuntu-20.04-Cloud-Image
bereits von `cloud-images.ubuntu.com` heruntergeladen und hält es lokal vor. Hier bitten wir
darum, eine Kopie anzulegen. Niemand greift dafür auf das Internet zu; die Kopie entsteht
innerhalb des Clusters.

⚠️ **Die Ubuntu-Version ist bewusst festgelegt — ändern Sie sie nicht.** Auf 24.04 bootet die
Maschine nicht; auf 22.04 stolpert das Umpacken über die alte RPM-Paketdatenbank in CentOS 7 —
`virt-v2v` kann sie nicht parsen. Getestet, damit Sie es nicht müssen.

`storage: 25Gi` — die Größe der Disk. Das Ubuntu-Image aus dem Katalog belegt 20Gi, und **die
Disk muss größer sein als das Image**, sonst bricht die Kopie auf halbem Weg ab und die Disk
bleibt danach in einem `Terminating`-Zustand hängen und steht im Weg. Der Puffer wird außerdem
gebraucht, weil die heruntergeladene `app-1.ova` und das Ergebnis des Umpackens gleichzeitig
darin liegen.

`storageClass: replicated` — wie sie gespeichert wird. `replicated` bedeutet mehrere Kopien auf
verschiedenen Nodes: Fällt ein Node aus — die Daten sind weiterhin da. Das Gegenstück ist eine
Storage Policy in vSphere. Es gibt auch `local` — schneller, liegt aber auf einem einzelnen Node.

```yaml
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  runStrategy: Always
  disks:
    - name: convert-tools
```

`instanceType: u1.large` — die Größe der Maschine, ein fertiges Bündel aus „so viele CPUs, so
viel Speicher“: hier zwei CPUs und acht Gigabyte. Das Umpacken hält das Image stückweise im
Speicher und fordert ihn ernsthaft ein.

`instanceProfile: ubuntu` — ein Satz von Einstellungen der virtuellen Hardware, zugeschnitten auf
dieses Gastsystem: welche Disk-Controller, welche Netzwerkkarte, wie die Uhr durchgereicht wird.
Das nächste Gegenstück ist „Guest OS Type“ im Assistenten zur VM-Erstellung, der ebenso
stillschweigend ein Dutzend Einstellungen an das gewählte System anpasst.

`runStrategy: Always` — die Maschine laufen lassen und, falls sie abstürzt, wieder hochfahren.
Das ist kein „Autostart, wenn der Host bootet“, sondern eine dauerhafte Regel: Die Plattform
sorgt dafür, dass die Maschine läuft.

`disks` — welche Disks angehängt werden. Ein Verweis per Name auf das oben beschriebene
`VMDisk`-Objekt.

```yaml
  cloudInit: |
    #cloud-config
    password: ubuntu
    packages: [ libguestfs-tools, virt-v2v, qemu-utils ]
    runcmd:
      - [ bash, -c, "wget ... mc && chmod +x /usr/local/bin/mc" ]
```

`cloudInit` — Anweisungen, die die Maschine beim ersten Start selbst ausführt. Das ist der
Standardmechanismus jedes Cloud-Images: Beim Start sucht das System nach solchem Text und führt
ihn aus. In vSphere ist das nächste Gegenstück eine Customization Specification, nur ist sie hier
als Text ausgedrückt und liegt in derselben Datei wie die Maschine selbst.

Hier bitten wir darum, ein Passwort zu setzen, `virt-v2v` mit seinen Abhängigkeiten zu
installieren und `mc` herunterzuladen — einen Konsolen-Client für die Arbeit mit S3-Storage,
genau den, mit dem wir das Ergebnis in den Bucket hochladen werden.

⚠️ **Das Passwort im Klartext** — nur für die Testumgebung der Schulung: Die Maschine lebt eine
halbe Stunde und ist nur von innerhalb des Clusters erreichbar. Auf einer echten Maschine setzen
Sie ssh-Schlüssel an die Stelle von `password`.
