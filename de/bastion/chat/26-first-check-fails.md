## 26. Erste Prüfung: versuchen zu starten und den Fehler einfangen

**Überspringen Sie diesen Schritt nicht. Er ist der nützlichste von allen.**

📍 **Wo:** in Ihrer VM — derjenigen, die Sie in der dritten Phase hochgefahren haben (app-VM). Nicht auf dem Bastion.

Die VM ist umgezogen, gebootet, und das Netzwerk funktioniert. Nach aller Logik sollte sie einfach laufen — die Anwendung sitzt auf dieser VM genau dort, wo sie immer saß, wir haben sie nie angefasst. Prüfen wir das:

```bash
systemctl status orders-api
curl -s -o /dev/null -w 'HTTP %{http_code}\n' localhost:8080/actuator/health
```

**Es funktioniert nicht.** Der Dienst ist entweder gar nicht hochgekommen oder antwortet mit `503`. Sehen wir uns an, worüber er sich beschwert:

```bash
journalctl -u orders-api --no-pager | tail -20
```

Im Log wird etwas in der Art von `Connection to 192.168.10.30:5432 refused` stehen oder ein Timeout gegen dieselbe Adresse.

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Die Anwendung haben wir nicht angefasst, die VM ist gebootet, das Netzwerk funktioniert. Warum kommt sie nicht hoch?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Weil in der Konfiguration die Adressen `192.168.10.30` und `192.168.10.40` fest verdrahtet sind — die Datenbank und die Queue, die auf **zwei anderen VMs in vSphere** lebten. Wir haben sie nicht mitgenommen und hatten das nie vor. Unter diesen Adressen ist hier nichts.

Die Anwendung ist in Ordnung, die VM ist in Ordnung, das Netzwerk ist in Ordnung. Das Einzige, was kaputt ist, ist die Annahme, die Welt um sie herum sei dieselbe geblieben.

**Das ist genau das, was eine echte Migration ausmacht.** Eine Platte zu verschieben ist der einfachste Teil davon, und es ist der Teil, der üblicherweise alle Aufmerksamkeit bekommt. Was kaputtgeht, ist immer das, was außen liegt: Adressen, DNS-Namen, Zugangsdaten, Zertifikate, benachbarte Systeme. Deshalb kalkuliert man in einem echten Projekt einen Tag für den Umzug der VM und Wochen für das „Zum-Laufen-Bringen“.

Sie haben das gerade selbst in zwei Minuten gesehen, und zwar am eigenen Leib, nicht in der Präsentation eines anderen.

</details>

**Was wir als Nächstes tun.** Wir werden nicht die Anwendung reparieren, sondern ihr Bild von der Welt: an die Stelle der fest verdrahteten IPs setzen wir die Namen der Managed Services, die wir in Schritt 5 hochgefahren haben.
