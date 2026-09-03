## 10. Los materiales ya están en el bastion

**No hay nada que clonar**

📍 **Dónde:** en el bastion en el que acabas de entrar por SSH.

La carpeta con los materiales ya está en tu directorio de inicio, y **tu número de tenant ya viene rellenado**. Los marcadores `tenant-workshopXX` se reemplazaron por tu `tenant-workshopNN` cuando se preparó el bastion — no hay nada que buscar y reemplazar, simplemente aplica los archivos tal como están.

Entra en la carpeta y mira qué hay dentro:

```bash
cd ~/workshop
ls manifests scripts
```

Deberías ver cuatro manifiestos y cuatro scripts — justo los del mapa de archivos. Comprueba que el número rellenado es el tuyo:

```bash
grep -m1 namespace manifests/01-bucket.yaml
```

La línea `namespace:` contendrá tu `tenant-workshopNN`, no `tenant-workshopXX`.

**Si te pierdes**, la forma de volver es siempre la misma:
```bash
cd ~/workshop
```

**Con qué abrir los archivos para editarlos.** Lo necesitarás exactamente una vez — para pegar la URL presignada en `manifests/03-app-vm.yaml` en la tercera fase. `nano` sirve:
`nano manifests/03-app-vm.yaml` (guardar: `Ctrl+O`, `Enter`, salir: `Ctrl+X`).

El único marcador que se dejó a propósito está en `manifests/03-app-vm.yaml`, la línea
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Esa URL la obtendrás cuando conviertas la imagen. Por ahora, solo debes saber que ahí te está esperando.
