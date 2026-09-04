## 2. Kleines Glossar: wie es bei Ihnen heißt und wie es hier heißt

**Eine Nachricht, zu der Sie zurückkehren können**

Die Hälfte der Verwirrung in Workshops betrifft nicht die Technik, sondern die Wörter. Unten steht die
Übersetzung. Wo die Analogie in die Irre führt, sage ich ehrlich, wo genau: eine falsche Analogie ist schlimmer
als gar keine.

| In vSphere | In Cozystack / Kubernetes | Wo die Analogie in die Irre führt |
|---|---|---|
| Virtuelle Maschine | **VM Instance** | Hier führt nichts in die Irre — genau das ist es |
| Disk der VM | **VM Disk** | Ein eigenes Objekt. Ohne Disk gibt es keine VM, deshalb wird die Disk immer zuerst erstellt |
| VM-Vorlage | Ein Image im Katalog | — |
| Anwendungscontainer | **Pod** | Ein Pod ist Wegwerfware. Man repariert ihn nicht — man löscht ihn, und ein neuer wird erstellt |
| vApp | **Deployment** | — |
| Ressourcen-Pool | **Tenant** mit einer Quota | Ein Tenant ist zugleich eine Zugriffsgrenze: ein Außenstehender kann nicht hineinsehen |
| vCenter | API-Server | Das Dashboard ist nur ein Gesicht dafür, nicht die Sache selbst |
| HA | Ein **Deployment** hält N Kopien | Nicht „bringt eine abgestürzte wieder hoch“, sondern „hält immer so viele, wie Sie angegeben haben“ |
| Load-Balancer-Pool | **Service** | — |
| Datastore | **Storage Class** | `replicated` — repliziert über drei Nodes, `local` — ohne Replikation |
| Eine separate VM mit Postgres | **Postgres aus dem Katalog** | Kommt mit Replikation und Backups, aktualisiert sich selbst |
| Ein Ticket an die IT-Abteilung | *keine Analogie* | Sie machen es selbst, in einer Minute |

**Eine Sache, an die Sie sich gewöhnen müssen.** In vSphere **erstellen** Sie ein Objekt: Sie klicken —
es erscheint und lebt von da an von allein. Hier **beschreiben Sie den gewünschten Zustand**, und der Cluster
vergleicht ihn ständig mit dem tatsächlichen Zustand und beseitigt die Differenz. Wenn Sie also etwas löschen,
kann es zurückkommen — nicht wegen einer Panne, sondern weil Sie den gewünschten Zustand nie widerrufen haben.
