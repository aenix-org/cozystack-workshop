## 22. Fase 3. Nos deshacemos del zoológico

**Pasos 5, 7, 8, 9.** La parte más valiosa. Dentro de la máquina que migramos siguen vivos su
propio Postgres y Kafka — esos mismos que alguien instaló una vez y que desde entonces nadie ha
tocado.

**No** nos los llevamos. En su lugar tomamos los que ya vienen listos del catálogo de Cozystack
y reconfiguramos la aplicación. La diferencia es simple: detrás de un servicio gestionado hay
replicación, copias de seguridad automáticas y monitorización; detrás de uno casero, la esperanza de que la
persona que lo montó todavía trabaje en la empresa.

El orden es este: primero levantamos los servicios (paso 5), luego apuntamos la aplicación hacia
ellos (paso 7), después creamos una tabla en la base de datos (paso 8) y verificamos toda la
cadena (paso 9).
