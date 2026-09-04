# Anforderungen an die Umgebung

Für alle, die die Umgebung für den Workshop einrichten oder die Labs selbstständig
durcharbeiten. Teilnehmende benötigen diese Datei nicht.

## Tenant-Quota

**Mindestens 40 CPUs und 48 GB Arbeitsspeicher pro Tenant.**

Der Grund liegt darin, wie die Request-Quota berechnet wird: Sie beträgt ein Zehntel des Limits.
Ein Tenant mit `cpu: 16` erhält 1600m an Requests — während ein einzelner Lab-Cluster aus Lab 0
etwa 1435m beansprucht. Das lässt nichts für die Managed Services in den Labs 6–12 übrig, und
Lab 0 fordert Sie ausdrücklich auf, den Cluster nicht zu löschen.

Das Symptom, wenn es knapp wird: `exceeded quota: tenant-quota` in den Events und ein Cluster,
der für immer im Status `Unknown` feststeckt. Aus diesem Zustand kommt er nicht von selbst heraus.

## Tenants erstellen

**Einen nach dem anderen, nicht im Stapel.**

Mehrere gleichzeitige Erstellungen mit aktiviertem Storage und Monitoring verstopfen die
Warteschlange des helm-controller: Releases geraten in einen Install–Fail–Delete-Zyklus mit
zehnminütigen Timeouts. Sie diagnostizieren das an `observedGeneration: -1` auf der hängenden
HelmRelease.

Dasselbe gilt für das Löschen: Ein Tenant mit einem Cluster darin braucht Minuten zum Abbau,
weil der Cleanup-Job darauf wartet, dass die virtuellen Maschinen der Worker freigegeben werden.

## Was im Tenant aktiviert sein muss

| Was | Warum | Labs |
|---|---|---|
| etcd | Ohne es kommt der Cluster aus Lab 0 nicht hoch | alle |
| Storage (SeaweedFS) | Buckets und Harbor | 6, 11 |
| Monitoring | Metriken und Dashboards | 3, 14 |

`metrics-server` wird automatisch installiert, wenn der Tenant etcd hat — Sie müssen ihn nicht
separat aktivieren. Er liegt im `cozy-monitoring` namespace, ist aber nicht Teil des
Monitoring-Add-ons.

## Plattformversion

Die Labs wurden mit **Cozystack v1.6.1** geschrieben und verifiziert. In früheren Versionen haben
einige Catalog-Einträge einen anderen Namen oder einen anderen Satz von Feldern.
