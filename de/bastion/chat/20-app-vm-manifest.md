## 20. Genauer betrachtet: Was steckt in 03-app-vm.yaml

Wieder zwei Objekte — eine Disk und eine Maschine.

```yaml
kind: VMDisk
spec:
  source:
    http:
      url: "ВСТАВЬТЕ_PRESIGNED_URL"
  storage: 10Gi
```

`source.http` statt `source.image` — das ist der ganze Unterschied zur vorherigen Phase. Hier fügen Sie den Link aus der Ausgabe von `convert.sh` ein, den nach dem Wort `Share:`. Fügen Sie ihn vollständig ein, samt dem langen „Anhang“ nach dem Fragezeichen: dieser Anhang ist die Signatur, und ohne ihn wird der Plattform der Zugriff verweigert.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
  instanceProfile: centos.7
  disks:
    - name: app-1
```

`instanceProfile: centos.7` — ein Profil für virtuelle Hardware für ein altes System. Es ist wichtiger, als es aussieht: CentOS 7 läuft mit einem Kernel von 2016, und einige moderne Einstellungen für virtuelle Hardware gehen darüber hinaus. Das Profil wählt jene aus, mit denen ein solcher Kernel umzugehen weiß.

Das ist übrigens die allgemeine Antwort auf die Frage „läuft darauf überhaupt ein altes System?“. Es läuft — solange Sie der Plattform sagen, dass das System alt ist.
