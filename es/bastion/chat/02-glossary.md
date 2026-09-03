## 2. Un pequeño glosario: cómo se llama en tu terreno y cómo se llama aquí

**Un mensaje al que siempre puedes volver**

La mitad de la confusión en los talleres no es por la tecnología, sino por las palabras. Abajo está la
traducción. Allí donde la analogía induce a error, digo con honestidad dónde exactamente: una analogía
equivocada es peor que ninguna.

| En vSphere | En Cozystack / Kubernetes | Dónde la analogía induce a error |
|---|---|---|
| Máquina virtual | **VM Instance** | Aquí no hay nada engañoso: es exactamente eso |
| Disco de VM | **VM Disk** | Un objeto aparte. No hay VM sin disco, así que el disco siempre se crea primero |
| Plantilla de VM | Una imagen del catálogo | — |
| Contenedor de aplicación | **Pod** | Un Pod es desechable. No lo reparas: lo eliminas y se crea uno nuevo |
| vApp | **Deployment** | — |
| Pool de recursos | **Tenant** con una cuota | Un tenant es además un límite de acceso: alguien de fuera no puede asomarse dentro |
| vCenter | API server | El panel es solo su cara, no la cosa en sí |
| HA | Un **Deployment** mantiene N copias | No «revive uno que se cayó», sino «siempre mantiene tantas como pediste» |
| Pool del balanceador de carga | **Service** | — |
| Datastore | **Storage Class** | `replicated` — replicado en tres nodos, `local` — sin replicación |
| Una VM aparte con Postgres | **Postgres del catálogo** | Viene con replicación y copias de seguridad, se actualiza solo |
| Un ticket al departamento de TI | *sin analogía* | Lo haces tú mismo, en un minuto |

⚠️ **No confundas las dos «VM».** En este recorrido la palabra «VM» se refiere al **bastion**:
la máquina compartida a la que entraste por SSH y desde la que manejas el clúster. Y la máquina
que vas a levantar dentro del clúster (primero la máquina conversora, luego la app-VM) es una **VM Instance**, y la
llamamos «tu máquina» o «app-VM». El bastion es desde donde emites los comandos; la app-VM es
lo que creas dentro del clúster. Los comandos `kubectl`/`virtctl` los escribes en el bastion, mientras que
`netfix`, el esquema de la base de datos y `psql` ocurren dentro de la app-VM (mediante `virtctl console`).

**Una cosa a la que tendrás que acostumbrarte.** En vSphere **creas** un objeto: haces clic,
aparece y a partir de ahí vive por su cuenta. Aquí **describes el estado deseado**, y el
clúster lo compara constantemente con el estado real y elimina la diferencia. Así que si borras
algo, puede volver: no por un fallo, sino porque nunca revocaste el deseo.
