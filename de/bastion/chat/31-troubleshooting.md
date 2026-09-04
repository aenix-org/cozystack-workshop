## 31. Wenn etwas nicht funktioniert

**Eine kurze Liste der Dinge, über die man stolpert**

• **Die Anwendung ist von außen nicht erreichbar.** Auf einem migrierten CentOS ist meist die
  eingebaute Firewall schuld — sie blockiert Port 8080:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl` antwortet mit „forbidden“.** Prüfen Sie, dass Sie Ihren eigenen namespace ansprechen:
  `-n tenant-workshopXX`. Und denken Sie daran, dass `vminstance` verfügbar ist, nicht `vm` oder `vmi`.

• **Die Bestellung wird nicht angelegt, obwohl health dabei `200` zurückgibt.** Die Tabelle wurde nicht
  angelegt — gehen Sie zurück zur Nachricht über das Datenbankschema.

• **Die neue Maschine (app-VM) hängt in `Pending`.** Die Konvertierungsmaschine wurde nicht
  heruntergefahren — sie belegt 8Gi der Quota, und für die neue bleibt nicht genug übrig. Löschen Sie sie und ihre Disk:
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **`mc` meldet `Insufficient permissions` beim Hochladen des Images.** In `convert.sh` steht im Feld
  `BUCKET` `my-images` statt des echten `bucketName` (das lange `bucket-...-...`).
  Nehmen Sie den `bucketName` aus dem Secret des Buckets im Dashboard und tragen Sie ihn ein.

• **Die Disk hängt im Zustand Terminating.** Höchstwahrscheinlich ist die Disk kleiner als das Image.
  Für ubuntu-20.04 brauchen Sie mindestens 25Gi.

• **Nichts hilft.** Schreiben Sie hier, wir klären das gemeinsam. Das ist ein normaler Teil der Arbeit
  und kein Grund, sich unwohl zu fühlen — bei einer echten Migration ist es genauso, nur um drei Uhr nachts.
