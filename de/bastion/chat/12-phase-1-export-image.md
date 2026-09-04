## 12. Phase 1. Das Image aus vSphere exportieren

**Schritte 1–3.** Der Datenträger der virtuellen Maschine liegt in einem Format vor, das VMware versteht, und
er bewegt sich von allein nirgendwohin. Wir müssen ihn in ein Format für KVM umwandeln und dort ablegen, von wo
der Cluster ihn abholen kann.

Drei Schritte: Storage einrichten, eine temporäre Maschine mit den Werkzeugen hochfahren, konvertieren.
