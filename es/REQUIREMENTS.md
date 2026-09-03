# Requisitos del entorno

Para quien prepara el entorno del taller o para trabajar los laboratorios por cuenta
propia. Los participantes no necesitan este archivo.

## Cuota del tenant

**Al menos 40 CPU y 48 GB de memoria por tenant.**

La razón está en cómo se calcula la cuota de requests: equivale a una décima parte del
límite. Un tenant con `cpu: 16` obtiene 1600m de requests, mientras que un solo clúster de
laboratorio del laboratorio 0 consume alrededor de 1435m. Eso no deja nada para los
servicios gestionados de los laboratorios 6–12, y el laboratorio 0 pide explícitamente que
no elimines el clúster.

El síntoma cuando te quedas corto: `exceeded quota: tenant-quota` en los eventos y un
clúster atascado para siempre en estado `Unknown`. No saldrá de ese estado por sí solo.

## Creación de tenants

**De a uno, no en lote.**

Varias creaciones simultáneas con almacenamiento y monitoreo habilitados saturan la cola
del helm-controller: los releases entran en un ciclo de «instalación — fallo — borrado» con
tiempos de espera de diez minutos. Se diagnostica por `observedGeneration: -1` en el HelmRelease
atascado.

Lo mismo aplica a la eliminación: un tenant con un clúster dentro tarda minutos en
desmontarse, porque el job de limpieza espera a que se liberen las máquinas virtuales de los
workers.

## Qué debe estar habilitado en el tenant

| Qué | Por qué | Laboratorios |
|---|---|---|
| etcd | Sin él no arranca el clúster del laboratorio 0 | todos |
| Almacenamiento (SeaweedFS) | Buckets y Harbor | 6, 11 |
| Monitoreo | Métricas y paneles | 3, 14 |

`metrics-server` se instala automáticamente si el tenant tiene etcd; no hace falta
habilitarlo por separado. Vive en el namespace `cozy-monitoring`, pero no forma parte del
complemento de monitoreo.

## Versión de la plataforma

Los laboratorios se escribieron y verificaron sobre **Cozystack v1.6.1**. En versiones
anteriores, algunas entradas del catálogo tienen otro nombre o un conjunto de campos
distinto.
