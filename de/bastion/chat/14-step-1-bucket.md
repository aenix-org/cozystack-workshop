## 14. Schritt 1: Ihr eigener Speicher

**Einen Bucket für das Image anlegen**

📍 **Wo:** auf dem Bastion, im Verzeichnis `~/workshop`.

Das Disk-Image ist mehrere Gigabyte groß. Es muss irgendwo liegen, damit der Cluster die Datei später über einen Link abholen kann. Genau dafür gibt es Object Storage — dasselbe Prinzip wie bei S3.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io -n tenant-workshopXX
```

Warten Sie, bis der Bucket einen betriebsbereiten Zustand erreicht.

Das Manifest legt einen Bucket namens **`my-images`** mit einem einzigen Benutzer an — `app`. Im Dashboard erscheint er im Bereich **Bucket**.

🖱 **Über das Dashboard:** **Bucket → Deploy new**, Name `my-images`. Achten Sie nur darauf, **den Benutzer `app` sofort in den Abschnitt `users` aufzunehmen**, noch vor dem Anlegen. Wenn Sie einen leeren Bucket anlegen und den Benutzer erst später über Edit ergänzen, bleibt der Bucket in einem halbfertigen Zustand und der Image-Upload schlägt fehl. Im Manifest ist das bereits berücksichtigt.

**Holen Sie sich jetzt die Schlüssel des Buckets — Sie brauchen sie in zwei Schritten.**

Der Bucket ist verschlossen, und um etwas hineinzulegen, brauchen Sie seine eigenen Zugriffsschlüssel. Sie liegen im Dashboard: **Bucket → `my-images` → Tab Secrets → das Secret `bucket-my-images-app-credentials`**. Klappen Sie es auf, und Sie sehen vier Werte, jeder mit einer Schaltfläche *Reveal* und *Copy*.

**Was Sie jetzt damit tun: Kopieren Sie drei davon in einen Notizblock** — irgendwohin, Notizen, ein Nachrichtenentwurf an sich selbst:

• `bucketName`
• `accessKey`
• `secretKey`

⚠️ **`bucketName` ist NICHT `my-images`.** `my-images` ist der Name, den Sie der Bestellung gegeben haben; den echten Namen des Buckets in S3 hat die Plattform selbst generiert — lang, in der Form `bucket-a9209f83-4ac1-463e-8477-d8365bef787b`. Genau der kommt ins Skript, aus dem Feld `bucketName`. Tragen Sie `my-images` ein, landet der Upload in einem nicht existierenden Bucket und schlägt mit `Insufficient permissions` fehl. Bei früheren Workshops sind Leute darüber gestolpert.

Den vierten, `endpoint`, müssen Sie nicht notieren — er ist für alle gleich und im Skript bereits eingetragen.

**Wohin sie kommen.** In Schritt 3 öffnen Sie auf der Konvertermaschine die Datei `convert.sh`, und darin einen Block „FÜGEN SIE IHRE WERTE EIN“ aus drei Zeilen:

```
BUCKET="ВСТАВЬТЕ_bucketName"
ACCESS_KEY="ВСТАВЬТЕ_accessKey"
SECRET_KEY="ВСТАВЬТЕ_secretKey"
```

Genau diese drei Werte fügen Sie dort ein, jeden in seine eigenen Anführungszeichen. An anderer Stelle werden sie nicht gebraucht: Das Skript lädt das fertige Image selbst in Ihren Bucket hoch und erstellt selbst einen Link darauf.

⚠️ Der Secret Key ist das Passwort für Ihren Speicher. Posten Sie ihn nicht im gemeinsamen Chat, auch nicht, wenn Sie um Hilfe bitten. Wenn etwas nicht aufgeht, schreiben Sie mir privat.

⚠️ Wenn Sie `endpoint` auf Ihren eigenen ändern möchten: Im Dashboard wird er ohne Schema angezeigt (`s3.workshop.aenix.io`), im Skript wird er aber **mit** `https://` am Anfang eingetragen. Lassen Sie es weg, schlägt der Upload stillschweigend fehl.
