## 25. Schritt 6: das Netzwerk innerhalb der Maschine reparieren

**Zuerst das Netzwerk, alles andere danach**

📍 **Wo:** innerhalb Ihrer virtuellen Maschine, in der Konsole (nicht auf dem Laptop).

📄 Das ist der Inhalt von `scripts/netfix-dhcp.sh` aus dem Repository. **Sie müssen ihn nicht in die Maschine herunterladen, und Sie können es auch nicht** — die Maschine hat noch kein Netzwerk, und genau dieses fehlende Netzwerk ist unser Defekt. Tippen Sie die Befehle von Hand ab; es sind zwei. Die Datei liegt im Repository, damit Sie sie später erneut nachlesen können.

Die Anwendung ist gerade nicht erreichbar, und das ist kein Fehler der Testumgebung. Im Image lebt die Vergangenheit weiter: eine statische Adresse aus dem VMware-Netzwerk und ein Gateway, das es hier nicht gibt. Die Maschine klammert sich daran und sieht weder den Cluster-DNS noch ihre Nachbarn.

Betreten Sie die Maschine über die Konsole — vom Laptop aus:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```
🖱 **Oder mit der Maus:** öffnen Sie im Dashboard Ihre Maschine und klicken Sie auf **VNC** — das ist dieselbe Konsole, nur im Browser. Beide Wege laufen über die Cluster-API und funktionieren selbst jetzt, wenn das Netzwerk innerhalb der Maschine defekt ist.

Weiter — innerhalb der Maschine (das ist CentOS, das Netzwerk wird hier konfiguriert, nicht in netplan):
```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
```
Überzeugen Sie sich mit eigenen Augen, was dabei herauskam:
```bash
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```
Die Zeile `BOOTPROTO=dhcp` sollte erhalten bleiben, und es sollte keine Zeilen mit einer Adresse oder einem Gateway geben. Wenn Sie die Datei von Hand mit `nano` bearbeiten, ist das Ergebnis dasselbe, nur langsamer.

Jetzt muss die Maschine neu gestartet werden:
```bash
reboot
```
🖱 **Oder mit der Maus:** im Dashboard auf der Seite der Maschine die Schaltfläche **Restart**.

Prüfen Sie nach dem Neustart, dass die Adresse zu einer Cluster-Adresse geworden ist:
```bash
ip -4 addr show eth0
```
Es sollte etwas in der Art von `10.244.x.x` sein. Das bedeutet, dass die Maschine im Cluster-Netzwerk ist und dessen DNS sieht.

⚠️ Die Reihenfolge ist wichtig: solange die Adresse noch die alte ist, werden Service-Namen nicht aufgelöst, und es hat keinen Sinn, die Konfiguration der Anwendung zu bearbeiten.
