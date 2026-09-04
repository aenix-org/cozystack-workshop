## 10. Die Materialien liegen bereits auf dem Bastion

**Nichts zu klonen**

📍 **Wo:** auf dem Bastion, auf dem Sie sich gerade per SSH angemeldet haben.

Der Materialordner liegt bereits in Ihrem Home-Verzeichnis, und **Ihre Tenant-Nummer ist darin bereits eingetragen**. Die Platzhalter `tenant-workshopXX` wurden bei der Vorbereitung des Bastion durch Ihren `tenant-workshopNN` ersetzt — Sie müssen nichts suchen und ersetzen, wenden Sie die Dateien einfach so an, wie sie sind.

Wechseln Sie in den Ordner und sehen Sie sich an, was darin liegt:

```bash
cd ~/workshop
ls manifests scripts
```

Sie sollten vier Manifeste und vier Skripte sehen — genau die aus der Dateiübersicht. Vergewissern Sie sich, dass die eingetragene Nummer Ihre ist:

```bash
grep -m1 namespace manifests/01-bucket.yaml
```

In der Zeile `namespace:` steht Ihr `tenant-workshopNN`, nicht `tenant-workshopXX`.

**Wenn Sie sich verlaufen**, führt der Weg zurück immer gleich:
```bash
cd ~/workshop
```

**Womit Sie Dateien zum Bearbeiten öffnen.** Das brauchen Sie genau einmal — um die presigned URL in der dritten Phase in `manifests/03-app-vm.yaml` einzufügen. `nano` genügt:
`nano manifests/03-app-vm.yaml` (speichern: `Ctrl+O`, `Enter`, beenden: `Ctrl+X`).

Der einzige Platzhalter, der absichtlich stehen geblieben ist, befindet sich in `manifests/03-app-vm.yaml`, in der Zeile
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Diese URL erhalten Sie, sobald Sie das Image konvertiert haben. Für den Moment sollten Sie nur wissen, dass sie dort auf Sie wartet.
