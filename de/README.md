# Von VMware zu Cozystack migrieren: Workshop und Labs

Material für alle, die VMware administrieren und verstehen möchten, was Cozystack ist —
nicht anhand von Folien, sondern praktisch. Kubernetes-Kenntnisse sind nicht erforderlich:
Alles wird unterwegs erklärt, ausgehend von dem, was Sie bereits aus vSphere kennen.

## Zwei Wege, ihn zu absolvieren — wählen Sie Ihren

Denselben Workshop gibt es in zwei Varianten. Sie unterscheiden sich nur darin, **von wo aus
Sie mit dem Cluster arbeiten**. Die Lehrkraft teilt Ihnen mit, welche für Sie vorgesehen ist.

| | [`laptop/`](laptop/) — vom eigenen Laptop | [`bastion/`](bastion/) — über den Bastion |
|---|---|---|
| **Werkzeuge** | Sie installieren sie selbst: `kubectl`, `virtctl`, `kubelogin` | bereits auf dem Bastion installiert |
| **Cluster-Zugang** | kubeconfig aus dem Dashboard, Anmeldung über den Browser | Sie melden sich per SSH an, Zugang ist bereits eingerichtet |
| **Tenant-Nummer in den Dateien** | tragen Sie selbst ein | im Voraus eingetragen |
| **App prüfen** | `virtctl port-forward` + `localhost:8080` | über den Domainnamen `app.<Nummer>.workshop.aenix.io` |
| **Für wen** | alle ohne gemeinsamen Bastion | eine vorbereitete Testumgebung mit Bastion |

In jedem Ordner liegt ein in sich geschlossener Satz: ein eigenes `README.md` (die Route), `chat/`
(die Chat-Nachrichten für jeden Schritt), `manifests/`, `scripts/`. Öffnen Sie das README für Ihren Weg
und folgen Sie ihm.

## Labs

Beide Ordner enthalten `labs/` — sechzehn eigenständige Labs, die Sie in Ihrem eigenen Tempo durcharbeiten,
zu Hause oder in den Pausen. Zu jedem gehört ein eigenes Prüfskript (`check/`). Der gesamte Satz umfasst
etwa neun Stunden und ist nicht für eine einzige Sitzung gedacht: Nehmen Sie sich eines pro Abend vor.

| Lab | Worum es geht | Zeit |
|---|---|---|
| 0 · Ihr eigener Cluster | in zehn Minuten zu einem eigenen Kubernetes | 15 Min. |
| 1 · Erste Anwendung | eine Anwendung mit einer Datei und einem Befehl bereitstellen | 25 Min. |
| 2 · Selbstheilung | eine Replica löschen und sehen, was passiert | 25 Min. |
| 3 · Skalierung | Last erzeugen und zusehen, wie die Replicas wachsen | 30 Min. |
| 4 · Rollout und Rollback | die Version unter Last ändern, ohne Ausfallzeit | 30 Min. |
| 5 · Infrastruktur in Git | alles in einem Repository beschreiben und mit einem Push ausliefern | 40 Min. |
| 6 · Eigene Registry | Harbor, einen Go-Service bauen, aus der eigenen Registry bereitstellen | 45 Min. |
| 7 · Cache | Redis vor einem langsamen Backend, der Gewinn in Zahlen | 50 Min. |
| 8 · Secrets | ein Passwort aus dem Manifest nach OpenBao auslagern | 50 Min. |
| 9 · Analytics | eine Million Zeilen und ein Bericht in Millisekunden | 45 Min. |
| 10 · Dokumente | MongoDB, wo Datensätze unterschiedliche Formen haben | 45 Min. |
| 11 · Mobile-Build | ein APK im Cluster bauen und in einen Bucket ablegen | 40 Min. |
| 12 · Eine VM daneben | Legacy muss nicht containerisiert werden, um umzuziehen | 30 Min. |
| 13 · Eigenes im Katalog | eine Anwendung als Cozystack-App verpacken | 40 Min. |
| 14 · Observability | die Spuren der eigenen Last in den Graphen finden | 30 Min. |
| 15 · Was am Montag zu tun ist | mit welchem System beginnen und was dem Management versprechen | 20 Min. |

Links zu den Labs finden Sie im README für Ihren Weg: [`laptop/labs/`](laptop/labs/) oder
[`bastion/labs/`](bastion/labs/).

## Organisatorisches

* [`CONVENTIONS.md`](CONVENTIONS.md) — wie die Materialien geschrieben sind (für Autoren).
* [`REQUIREMENTS.md`](REQUIREMENTS.md) — was Sie brauchen, um die Testumgebung aufzubauen (für alle,
  die den Workshop vorbereiten: Quotas, die Reihenfolge, in der Tenants angelegt werden, die Plattformversion).
