## 12. Fase 1. Sacamos la imagen de vSphere

**Pasos 1–3.** El disco de la máquina virtual está en un formato que VMware entiende, y por sí solo no
va a ir a ningún lado. Necesitamos convertirlo a un formato para KVM y ponerlo en un lugar del que el clúster
pueda tomarlo.

Tres pasos: preparamos el almacenamiento, levantamos una máquina temporal con las herramientas, convertimos.
