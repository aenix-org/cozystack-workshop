## 13. Genauer betrachtet: Was steckt in 01-bucket.yaml

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: my-images
  namespace: tenant-workshopXX
spec:
  users:
    app: {}
```

`apiVersion: apps.cozystack.io/v1alpha1` — aus welchem Satz von Typen dieses Objekt stammt.
`apps.cozystack.io` ist der Cozystack-Katalog selbst: Alles, was dort aufgeführt ist, können Sie
bestellen. Es ist nicht so, dass „Kubernetes von sich aus Buckets beherrscht“ — die Plattform hat sie hinzugefügt.

`kind: Bucket` — was Sie genau bestellen. Die Datei beschreibt nicht, *wie* der Speicher aufgebaut
wird: Sie sagt „Ich möchte einen Bucket“, und alles Übrige erledigt die Plattform selbst. So funktioniert
der gesamte Katalog — Sie schreiben auf, was Sie brauchen, und nicht eine Abfolge von Schritten.

`metadata.name: my-images` — der Name der Bestellung. Damit finden Sie die Bestellung im Dashboard
und in Befehlen wieder. Dieser Name ist intern; die Plattform erzeugt ihren eigenen echten Bucket-Namen
in S3, lang und eindeutig — diesen sehen Sie später im Parameter `bucketName`.

`namespace: tenant-workshopXX` — Ihr Abschnitt der Plattform. In der Datei auf dem Bastion **steht Ihre
Nummer hier bereits** — sie wurde beim Vorbereiten der Testumgebung eingetragen, es ist also nichts zu
ändern (`XX` ist nur als Beispiel gezeigt). Ein namespace ist eine Trennwand innerhalb des Clusters:
Objekte mit gleichem Namen in verschiedenen namespaces stören sich nicht gegenseitig und sehen einander
nicht. Die nächste Analogie ist ein eigener Resource Pool mit eigenen Zugriffsrechten, nur strenger.

`users: app: {}` — legt einen S3-Benutzer mit dem Namen `app` an. Die leeren geschweiften Klammern
bedeuten „Standardeinstellungen“: Die Plattform denkt sich selbst einen Zugriffsschlüssel und einen
geheimen Schlüssel für ihn aus und legt sie in ein separates Secret-Objekt, das Sie im Dashboard öffnen.
Sie denken sich keinerlei Passwörter aus und tragen sie nirgends ein.

Beachten Sie, was in der Datei **nicht** steht: Größe, Adresse, Ports, Zertifikat, die Nodes, auf denen
das alles untergebracht wird. All das bestimmt die Plattform selbst. Genau das ist der Unterschied
zwischen „aus dem Katalog bestellen“ und „von Hand einrichten“.
