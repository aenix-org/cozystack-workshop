## 20. Un vistazo más de cerca: qué hay dentro de 03-app-vm.yaml

De nuevo dos objetos: un disco y una máquina.

```yaml
kind: VMDisk
spec:
  source:
    http:
      url: "ВСТАВЬТЕ_PRESIGNED_URL"
  storage: 10Gi
```

`source.http` en lugar de `source.image`: esa es toda la diferencia con la fase anterior. Aquí pegas el enlace de la salida de `convert.sh`, el que viene después de la palabra `Share:`. Pégalo completo, incluida la larga "cola" que va después del signo de interrogación: esa cola es la firma, y sin ella la plataforma recibirá una denegación de acceso.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
  instanceProfile: centos.7
  disks:
    - name: app-1
```

`instanceProfile: centos.7`: un perfil de hardware virtual para un sistema antiguo. Importa más de lo que parece: CentOS 7 corre un kernel de 2016, y hay algunos ajustes modernos de hardware virtual que quedan fuera de su alcance. El perfil elige los que ese kernel sabe manejar.

Esta, por cierto, es la respuesta general a la pregunta "¿siquiera va a correr un sistema antiguo?". Sí correrá, siempre que le digas a la plataforma que el sistema es antiguo.
