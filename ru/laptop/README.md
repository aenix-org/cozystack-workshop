# Воркшоп: переезд виртуалки из VMware в Cozystack (со своего ноутбука)

Сервис заказов много лет жил в VMware на трёх виртуальных машинах: на одной само приложение, на другой база PostgreSQL, на третьей очередь Kafka. Сегодня вы перевезёте виртуалку с приложением в Cozystack, а две остальные замените управляемыми сервисами из каталога Cozystack. Все манифесты вы напишете сами, всю инфраструктуру будете держать в Git, диск сконвертируете своими руками и сами же почините то, что сломается внутри гостевой системы.

> Если ведущий выдал вам логин на общей виртуалке — бастионе, где инструменты уже установлены, вам нужна другая версия: [`../bastion/`](../bastion/). Маршрут там тот же, отличается только часть 0.

Закладывайте около трёх часов. В каждом задании сказано, что нужно описать и какую страницу документации прочитать; решение спрятано под спойлер. Сначала попробуйте сами, потом заглядывайте.

## Маршрут

| Часть | Что делаете | Время |
|---|---|---|
| 0 | Ставите инструменты, входите, осматриваетесь, читаете описание виртуалки из VMware | 25 мин |
| 1 | Заказываете объектное хранилище под образ диска: сначала в дашборде, потом в Git | 15 мин |
| 2 | Описываете временную виртуалку для конвертации, вручную конвертируете диск, удаляете виртуалку через Git | 40 мин |
| 3 | Описываете виртуалку приложения по размерам из описания VMware и импортируете диск | 20 мин |
| 4 | Заказываете в каталоге PostgreSQL с репликой и Kafka | 15 мин |
| 5 | Возвращаете приложение к жизни и публикуете его по HTTPS | 40 мин |
| 6 | День второй: меняете размер виртуалки, переносите её на лету, теряете основной экземпляр базы | 25 мин |

## Что выдаёт ведущий

- дашборд Cozystack: https://dashboard.workshop.aenix.io
- ваш логин `vmwXX` и пароль; эта пара подходит и к дашборду, и к GitLab
- ваш Git-репозиторий: `https://gitlab.workshop.aenix.io/vmwXX/vmware-migration`

Везде ниже заменяйте `vmwXX` своим логином. Namespace вашего тенанта называется `tenant-vmwXX`.

## Часть 0. Подготовка и осмотр (25 мин)

### 0.1 Четыре инструмента

📍 На ноутбуке. Если получится, поставьте их до воркшопа.

| Инструмент | Зачем он нужен | Где взять |
|---|---|---|
| `kubectl` | разговаривает с платформой: применяет объекты и показывает их | https://kubernetes.io/docs/tasks/tools/ |
| `kubelogin` | нужен, чтобы `kubectl` пускал вас через браузер | https://github.com/int128/kubelogin#setup |
| `virtctl` | консоль виртуалки | https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/ |
| `git` | ваша инфраструктура живёт в Git-репозитории | https://git-scm.com/downloads |

```bash
kubectl version --client
kubectl oidc-login --help | head -1
virtctl version --client
git --version
```

**Вы должны увидеть:** каждая команда печатает версию или строку справки, и ни одна не отвечает `command not found`.

### 0.2 Вход на платформу

📍 Сначала в дашборде, потом на ноутбуке.

Войдите в дашборд как `vmwXX`. Откройте свой тенант, затем **Info → Secrets** и скопируйте секрет `kubeconfig-tenant-vmwXX`. Сохраните его в файл `~/.kube/workshop`. На Windows сохраняйте его как `%USERPROFILE%\.kube\workshop` в кодировке UTF-8: Блокнот по умолчанию пишет в UTF-16, и тогда `kubectl` жалуется на сертификат, хотя сертификат тут ни при чём.

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config set-context --current --namespace tenant-vmwXX
kubectl get resourcequota
```

При первом обращении откроется окно браузера: войдите как `vmwXX` ещё раз.

**Вы должны увидеть:** свою квоту — пределы `hard` и то, что уже занято (`used`).

Вторая команда назначает namespace вашего тенанта используемым по умолчанию, так что дальше `-n tenant-vmwXX` можно не писать.

<details><summary>Что такое тенант, если мерить vSphere</summary>

Тенант — это примерно пул ресурсов со своими правами и своим бюджетом, к которому прилагается собственный каталог сервисов. Всё, что вы сегодня создадите, живёт в одном namespace, `tenant-vmwXX`, и расходует одну квоту. В отличие от пула ресурсов, в тенанте базы данных, очереди, объектное хранилище и целые кластеры Kubernetes заказываются так же легко, как виртуалки.

</details>

Посмотрите, что можно заказать:

```bash
kubectl get applicationdefinitions -o custom-columns=KIND:.spec.application.kind
```

**Вы должны увидеть:** несколько десятков типов, среди них `VMInstance`, `VMDisk`, `Bucket`, `Postgres` и `Kafka`. Тот же список показывает страница **Catalog** в дашборде. Заказывается всё это одинаково: вы описываете, что вам нужно, в коротком YAML-файле, а платформа это строит.

### 0.3 Ваша инфраструктура — это Git-репозиторий

📍 На ноутбуке.

```bash
git clone https://gitlab.workshop.aenix.io/vmwXX/vmware-migration.git ~/vmware-migration
cd ~/vmware-migration
cat platform/README.md
```

Git один раз спросит логин и пароль.

**Вы должны увидеть:** папку `platform/`, в которой лежит один README.

Платформа следит за этим репозиторием. Раз в минуту Flux, встроенный в Cozystack механизм GitOps, берёт ветку `main` и применяет к вашему тенанту все YAML-файлы из `platform/`. Удалите файл — Flux удалит объект. Посмотрите на эту связку:

```bash
kubectl get gitrepository,kustomization
git log -1 --format=%h
```

**Вы должны увидеть:** `infra` (откуда Flux читает) и `platform` (что он применяет), оба в состоянии `READY True`, а в их статусе — тот же хеш коммита, что показывает `git log`.

Отныне каждый манифест ложится в `~/vmware-migration/platform/`, а за ним следуют `git add`, `git commit`, `git push`. После каждого пуша дайте платформе около минуты; последний коммит, который применил Flux, показывает `kubectl get kustomization platform`.

<details><summary>Почему Git, а не kubectl apply</summary>

В vSphere правда о виртуалке — то, что vCenter показывает в эту минуту: кто-то ночью поменял ей размер, кто-то добавил диск, и никто уже не помнит зачем. При GitOps правда — это репозиторий. У каждого изменения есть автор, время и описание; его можно посмотреть до того, как оно попадёт на платформу, и откатить через `git revert`. Если кто-то поправит платформу руками, Flux в течение минуты вернёт всё как было. Сегодня вы увидите и то и другое.

</details>

### 0.4 Изучите виртуалку из VMware, прежде чем её перевозить

📍 На ноутбуке.

Виртуалку выгрузили из vSphere в формате OVA — это tar-архив, в котором лежат описание `.ovf` и диск `.vmdk`. Прежде чем что-то перевозить, выясните, что перед вами. Описание лежит в начале архива, так что хватит первых 64 КБ:

```bash
curl -sL -r 0-65535 https://github.com/aenix-org/cozystack-workshop/releases/download/vmware-demo-ova/app-1.ova | tar xO app-1.ovf 2>/dev/null > app-1.ovf
grep -E 'osType|ElementName>|capacity=|ethernet' app-1.ovf
```

Запишите гостевую ОС, число vCPU, объём памяти и размер диска. Всё это понадобится в части 3.

<details><summary>Что вы должны были найти</summary>

- `vmw:osType="centos7_64Guest"`: CentOS 7, 64-битная.
- `2 virtual CPU(s)` и `2048 MB of memory`.
- `ovf:capacity="8591507456"`: диск на 8 GiB.
- `E1000 ethernet adapter on "VM Network"`: эмулированная сетевая карта Intel в группе портов `VM Network`. Запомните это до части 5.

</details>

## Часть 1. Объектное хранилище под образ диска (15 мин)

Сконвертированный диск нужно положить туда, откуда платформа сможет скачать его по HTTP. Такое место — бакет, S3-совместимое объектное хранилище из каталога.

### 1.1 Закажите бакет в дашборде

📍 В дашборде.

Откройте **Catalog → Bucket**, назовите бакет `images` и добавьте одного пользователя с именем `convert`. Создайте бакет, а потом посмотрите на него из терминала:

```bash
kubectl get buckets.apps.cozystack.io images
kubectl get secret bucket-images-convert-credentials -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
```

**Вы должны увидеть:** `images` с `READY True` и `Secret` с четырьмя ключами: `accessKey`, `bucketName`, `endpoint`, `secretKey`.

«Пользователь» бакета — не человек, а пара ключей S3, которая открывает только этот бакет. Cozystack сам генерирует ключи и кладёт их в этот `Secret`.

⚠️ Всегда пишите тип полностью: `buckets.apps.cozystack.io`. Короткое слово `bucket` в кластере занято трижды (тип из каталога, тип Flux и тип из стандарта объектных хранилищ), и `kubectl` может выбрать тот, на который у вас нет прав, и ответить `forbidden`. С правами всё в порядке; пишите полное имя.

### 1.2 Перенесите бакет в Git

📍 На ноутбуке.

```bash
kubectl get buckets.apps.cozystack.io images -o yaml
```

Напишите `platform/bucket.yaml` с тем же описанием. Возьмите из вывода только `apiVersion`, `kind`, `metadata.name` и `spec`. Отбросьте `status`, `namespace` и всё, что сгенерировала платформа (`uid`, `resourceVersion`, `creationTimestamp`, `managedFields`, аннотации и метки): в ваш namespace объект положит сам Flux.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: images
spec:
  users:
    convert: {}
```

</details>

```bash
cd ~/vmware-migration
git add platform/bucket.yaml
git commit -m "Keep the image bucket in Git"
git push
```

На платформе ничего не изменится: описание то же самое. Изменилось другое — кто им владеет. Отныне бакетом управляет репозиторий.

### 1.3 Что под капотом

```bash
kubectl get helmreleases | grep images
```

**Вы должны увидеть:** `bucket-images` и `bucket-images-system`, оба `True`. Каждый объект из каталога превращается в Helm-релиз, а уже релиз создаёт настоящие ресурсы. Писать Helm-чарты самим вам не придётся: запись в каталоге и есть чарт, а ваш YAML — его значения.

## Часть 2. Временная виртуалка для конвертации диска (40 мин)

VMware хранит диски в формате VMDK, а Cozystack запускает виртуалки на KVM. Перепаковывает диск и заодно готовит гостевую систему к жизни на KVM (драйверы, загрузчик) утилита `virt-v2v`. Ставить её на ноутбук вы не будете: вы закажете временную виртуалку с Linux и нужными инструментами, воспользуетесь ею один раз и выбросите.

### 2.1 Опишите виртуалку для конвертации

Виртуалка в Cozystack — это два объекта: `VMDisk` (диск и источник его данных) и `VMInstance` (процессор, память, подключённые диски, параметры загрузки). Разделены они намеренно: удалите машину — диск уцелеет; подключите диск к другой машине — с него загрузится она.

Прочитайте документацию по [дискам виртуалок](https://cozystack.io/docs/v1.7/virtualization/vm-disk/) и [самим виртуалкам](https://cozystack.io/docs/v1.7/virtualization/vm-instance/) и напишите `platform/convert.yaml` с обоими объектами; оба назовите `convert`:

- диск: из готового образа платформы `ubuntu-20.04`, 20Gi, класс хранилища `replicated`;
- виртуалка: профиль `ubuntu`, типоразмер `u1.large` (2 vCPU и 8 GiB: `virt-v2v` любит память), подключён диск `convert`;
- cloud-init, который задаёт пользователю `ubuntu` пароль `ubuntu`, разрешает вход по паролю и ставит `virt-v2v`, `libguestfs-tools`, `qemu-utils` и `awscli`.

Подсказки: образ задаётся в `source.image.name`, размер — в `instanceType`, профиль — в `instanceProfile`, а cloud-init пишется в `cloudInit` строкой, которая начинается с `#cloud-config`. Оба объекта положите в один файл и разделите их строкой `---`.

⚠️ Диск делайте ровно на 20Gi — это размер образа. Меньше нельзя, а больший на этом стенде застревает, пока расширяется клонированный том ([cozystack#5460](https://github.com/cozystack/cozystack/issues/5460)).

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
metadata:
  name: convert
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 20Gi
  storageClass: replicated
---
apiVersion: apps.cozystack.io/v1alpha1
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  disks:
    - name: convert
  cloudInit: |
    #cloud-config
    password: ubuntu
    chpasswd: { expire: false }
    ssh_pwauth: true
    package_update: true
    packages: [virt-v2v, libguestfs-tools, qemu-utils, awscli]
```

</details>

```bash
git add platform/convert.yaml
git commit -m "Temporary VM for disk conversion"
git push
kubectl get vminstances -w
```

**Вы должны увидеть:** в течение минуты появляется виртуалка `convert`, а ещё через минуту-другую она переходит в `READY True`. Остановите наблюдение через `Ctrl-C` и проверьте заодно диск: `kubectl get vmdisks`.

<details><summary>Что значит u1.large</summary>

Типоразмер — это размер с именем, как тип инстанса в EC2: `u1.large` означает 2 vCPU и 8 GiB. На платформе их целая лесенка:

```bash
kubectl get virtualmachineclusterinstancetypes -o custom-columns=NAME:.metadata.name,CPU:.spec.cpu.guest,MEMORY:.spec.memory.guest | grep -E '^NAME|^u1\.'
```

Именованные размеры делают виртуалки сравнимыми, а квоты — предсказуемыми. Когда нужна точная конфигурация, как в части 3, `VMInstance` вместо типоразмера принимает `resources`.

</details>

### 2.2 Сконвертируйте диск

📍 Внутри виртуалки для конвертации.

`Running` означает, что виртуалка включилась, а не что она готова: cloud-init нужно ещё несколько минут, чтобы поставить пакеты.

```bash
virtctl console vm-instance-convert
```

Войдите как `ubuntu` / `ubuntu` (если экран остаётся пустым, нажмите Enter), затем:

```bash
sudo -i
cloud-init status --wait
which virt-v2v aws
```

**Вы должны увидеть:** `status: done`, а затем два пути. Если написано `status: error`, но обе утилиты на месте, продолжайте: это пожаловался необязательный шаг установки пакетов, здесь он ни на что не влияет.

Скачайте OVA. На очном воркшопе образ берётся из объектного хранилища самого стенда: так быстро и не тратится внешний трафик. Если проходите воркшоп самостоятельно, берите публичную копию с GitHub.

```bash
cd /root
curl -fLo app-1.ova https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova
# on your own: https://github.com/aenix-org/cozystack-workshop/releases/download/vmware-demo-ova/app-1.ova
tar tvf app-1.ova
```

**Вы должны увидеть:** скачано около 800 МБ, а в архиве три файла: `app-1.ovf` (описание), `app-1-disk1.vmdk` (диск) и `app-1.mf` (контрольные суммы).

Конвертируйте:

```bash
mkdir -p /root/out
virt-v2v -i ova app-1.ova -o local -os /root/out -of qcow2 -on app-1
```

Команда читается как фраза: на входе (`-i`) файл OVA; результат (`-o`) пишется в локальную папку (`-os`, она должна уже существовать); формат результата (`-of`) — QCOW2; сконвертированная виртуалка называется `app-1`. Без `-of qcow2` получится сырой образ размером во весь диск.

**Вы должны увидеть:** пронумерованные этапы, примерно пять минут: `Opening the source`, `Inspecting the overlay`, `Converting CentOS Linux release 7.8.2003 (Core) to run on KVM`, `Copying disk 1/1`, `Finishing off`. Предупреждение про `grub/device.map` и `vda` безвредно.

```bash
ls -lh /root/out
qemu-img info /root/out/app-1-sda
```

**Вы должны увидеть:** `app-1-sda` (диск, около 1,7 ГБ) и `app-1.xml` (описание для libvirt, оно вам не понадобится), `file format: qcow2`, `virtual size: 8 GiB`.

<details><summary>Что virt-v2v поменял внутри гостевой системы</summary>

Он не просто перепаковал файл. Он открыл файловую систему CentOS, убедился, что в initramfs есть драйверы virtio и гостевая система увидит диск и сетевую карту KVM вместо SCSI-контроллера и E1000 от VMware, удалил VMware Tools и поправил настройки загрузки. Обычный `qemu-img convert` дал бы диск, который на KVM нередко не загружается.

</details>

### 2.3 Загрузите диск и получите ссылку

Ключи от бакета лежат в `Secret` из шага 1.1. Откройте на ноутбуке второй терминал:

```bash
kubectl get secret bucket-images-convert-credentials -o go-template='{{range $k, $v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
```

📍 Снова внутри виртуалки для конвертации; подставьте свои значения:

```bash
export AWS_ACCESS_KEY_ID=<accessKey>
export AWS_SECRET_ACCESS_KEY=<secretKey>
export BUCKET=<bucketName>
export S3=https://s3.workshop.aenix.io

aws --endpoint-url $S3 s3 cp /root/out/app-1-sda s3://$BUCKET/app-1.qcow2
aws --endpoint-url $S3 s3 ls s3://$BUCKET/
aws --endpoint-url $S3 s3 presign s3://$BUCKET/app-1.qcow2 --expires-in 86400
```

`endpoint` в `Secret` — это тот же адрес, только без `https://`.

**Вы должны увидеть:** ход загрузки, затем `app-1.qcow2` в бакете, затем длинный URL. Скопируйте его. Это подписанная ссылка: кто ею владеет, тот 24 часа может скачать этот единственный объект без всяких ключей. Платформа воспользуется ею в части 3.

Выйдите из виртуалки (дважды `exit`) и покиньте консоль через `Ctrl-]`.

### 2.4 Выбросьте виртуалку для конвертации через Git

📍 На ноутбуке.

Виртуалка для конвертации занимает 2 vCPU и 8 GiB вашей квоты. Уберите её так, как принято в GitOps, — удалив её файл:

```bash
cd ~/vmware-migration
git rm platform/convert.yaml
git commit -m "Conversion done, remove the temporary VM"
git push
kubectl get vminstances -w
```

**Вы должны увидеть:** через минуту-другую `convert` пропадает из списка, и `kubectl get vmdisks` его тоже больше не показывает. Flux заметил, что файла нет, и удалил объекты, которые из него создал. За это отвечает настройка `prune: true` в вашей Kustomization `platform` (`kubectl get kustomization platform -o yaml`).

> **Остановитесь и подумайте.** Что было бы, если бы вы удалили виртуалку командой `kubectl delete vminstance convert`, а файл оставили в Git?

<details><summary>Ответ</summary>

Flux пересоздал бы её в течение минуты: в репозитории по-прежнему написано, что она должна существовать. В GitOps меняют репозиторий, а не платформу. По той же причине виртуалка, которую кто-то удалил по ошибке, возвращается сама.

</details>

## Часть 3. Виртуалка приложения (20 мин)

### 3.1 Опишите её

Напишите `platform/app-1.yaml` с `VMDisk` и `VMInstance`; оба назовите `app-1`:

- диск скачивает данные по вашей подписанной ссылке и занимает 10Gi в хранилище `replicated` (диск гостевой системы — 8 GiB, оставьте запас);
- у виртуалки ровно та конфигурация, которую вы записали в шаге 0.4, причём задана она через `resources`, а не типоразмером; виртуалка использует профиль для CentOS 7 и загружается с диска `app-1`.

Подсказки: источник по HTTP задаётся в `source.http.url`; URL возьмите в кавычки, в нём есть `&` и `=`. Имена профилей перечисляет `kubectl get virtualmachineclusterpreferences`.

⚠️ `resources` задаёт размер виртуалки, только если указаны все три поля: `cpu`, `sockets` и `memory`. Если указать лишь часть, платформа откажется создавать виртуалку и объяснит почему в статусе HelmRelease. Это сообщение стоит один раз прочитать нарочно.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
metadata:
  name: app-1
spec:
  source:
    http:
      url: "<your presigned URL>"
  storage: 10Gi
  storageClass: replicated
---
apiVersion: apps.cozystack.io/v1alpha1
kind: VMInstance
metadata:
  name: app-1
spec:
  instanceProfile: centos.7
  resources:
    cpu: 2
    sockets: 1
    memory: 2Gi
  disks:
    - name: app-1
```

</details>

```bash
git add platform/app-1.yaml
git commit -m "Move app-1 from VMware"
git push
kubectl get datavolumes -w
```

**Вы должны увидеть:** `vm-disk-app-1` проходит через `ImportScheduled` и `ImportInProgress` с процентами до `Succeeded`, примерно за две минуты. Затем:

```bash
kubectl get vminstances app-1
kubectl get virtualmachineinstances vm-instance-app-1 -o wide
```

**Вы должны увидеть:** `READY True` и виртуалку в состоянии `Running` на одном из узлов, с адресом из сети кластера (`10.244.x.x`).

<details><summary>Что под капотом: кто скачал диск</summary>

`VMDisk` превратился в DataVolume из CDI (Containerized Data Importer). CDI запустил под-импортёр, который скачал файл QCOW2 по вашей ссылке, превратил его в сырое блочное устройство и записал на реплицируемый том. Тот же механизм импортирует данные из образа, из загрузки (`virtctl image-upload`) или из другого диска (`source.disk`); меняется только источник.

</details>

### 3.2 Загляните внутрь

📍 В консоли виртуалки.

```bash
virtctl console vm-instance-app-1
```

Войдите как `root` / `cozydemo`. Виртуалка загрузилась на KVM, но:

```bash
ip -4 addr show eth0
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```

**Вы должны увидеть:** `192.168.10.21/24` — адрес из старой сети VMware, прописанный в `ifcfg-eth0` статически, вместе со шлюзом, которого здесь нет. Рабочей сети у виртуалки нет. Пока оставьте как есть и выйдите (`Ctrl-]`); это чинится в части 5.

## Часть 4. База и очередь из каталога (15 мин)

Раньше приложение ходило к виртуалке с PostgreSQL по адресу `192.168.10.30` и к виртуалке с Kafka по адресу `192.168.10.40`. Их вы не перевозите, а заказываете вместо них управляемые сервисы.

### 4.1 PostgreSQL с репликой

По [документации PostgreSQL](https://cozystack.io/docs/v1.7/applications/postgres/) напишите `platform/postgres.yaml`: `Postgres` с именем `orders`, у которого есть основной экземпляр и одна горячая реплика, по 5Gi каждый в хранилище `replicated`, пресет `t1.micro`, пользователь `orders` и база `orders`, которой этот пользователь управляет. Пароль не задавайте: Cozystack сгенерирует его сам.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Postgres
metadata:
  name: orders
spec:
  replicas: 2
  size: 5Gi
  storageClass: replicated
  resourcesPreset: t1.micro
  users:
    orders: {}
  databases:
    orders:
      roles:
        admin: [orders]
```

</details>

### 4.2 Kafka

По [документации Kafka](https://cozystack.io/docs/v1.7/applications/kafka/) напишите `platform/kafka.yaml`: `Kafka` с именем `events` и одним брокером, 5Gi в хранилище `replicated`, пресет `c1.small`, и один топик `orders` с одной партицией и одной репликой. Kafka работает в режиме KRaft, без ZooKeeper.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kafka
metadata:
  name: events
spec:
  kafka:
    replicas: 1
    size: 5Gi
    storageClass: replicated
    resourcesPreset: c1.small
  topics:
    - name: orders
      partitions: 1
      replicas: 1
      config: {}
```

</details>

```bash
git add platform/postgres.yaml platform/kafka.yaml
git commit -m "Order the database and the queue from the catalog"
git push
kubectl get postgres,kafka
kubectl get kafka -w
```

**Вы должны увидеть:** оба переходят в `READY True` — PostgreSQL за несколько минут, Kafka примерно за десять. Пока они поднимаются, переходите к части 5.

### 4.3 Что под капотом: что вы получили

```bash
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role
kubectl get services | grep -E 'postgres-orders|kafka-events'
```

**Вы должны увидеть:** два пода, один `primary` и один `replica`, которыми управляет оператор CloudNativePG, и сервисы, через которые будет работать приложение: `postgres-orders-rw` (всегда указывает на текущий основной экземпляр) и `kafka-events-kafka-bootstrap` на порту 9092.

Сгенерированный пароль лежит в `Secret`:

```bash
kubectl get secret postgres-orders-credentials -o jsonpath='{.data.orders}' | base64 -d; echo
```

## Часть 5. Возвращаем приложение к жизни (40 мин)

📍 Большей частью внутри виртуалки приложения. На этот раз без скриптов: для каждой неполадки вы находите симптом, потом причину, потом чините. Подсказки спрятаны; открывайте их, только если застряли.

```bash
virtctl console vm-instance-app-1
```

### 5.1 Сеть

Виртуалка всё ещё уверена, что живёт в сети VMware `192.168.10.0/24`. В Cozystack каждая виртуалка получает адрес из сети кластера по DHCP.

Переведите `eth0` на DHCP, примените изменение без перезагрузки и проверьте, что DNS кластера отвечает.

<details><summary>Подсказка</summary>

В CentOS 7 интерфейс настраивается в `/etc/sysconfig/network-scripts/ifcfg-eth0`. Нужен `BOOTPROTO=dhcp` и не нужны строки `IPADDR`, `NETMASK`, `GATEWAY` и `DNS1`. Применяет настройки `systemctl restart network`.

</details>

<details><summary>Решение</summary>

```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^NETMASK/d; /^GATEWAY/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
cat /etc/sysconfig/network-scripts/ifcfg-eth0
systemctl restart network
ip -4 addr show eth0
cat /etc/resolv.conf
getent hosts postgres-orders-rw kafka-events-kafka-bootstrap
```

</details>

**Вы должны увидеть:** адрес `10.244.x.x`, строку `search tenant-vmwXX.svc.cozy.local ...` в `resolv.conf` и адреса, в которые разрешились оба имени сервисов.

Благодаря строке `search` короткие имена сервисов работают внутри виртуалки точно так же, как в подах.

### 5.2 Каким приложение видит мир

```bash
systemctl status orders-api --no-pager | head -5
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
journalctl -u orders-api --no-pager | tail -5
```

**Вы должны увидеть:** сервис запущен, но нездоров, а в журнале жалобы на `192.168.10.30`.

> **Остановитесь и подумайте.** Виртуалка переехала, загружается, сеть работает. Почему приложение по-прежнему сломано?

<details><summary>Ответ и урок шире этой ошибки</summary>

Его настройки всё ещё указывают на базу и очередь, которые жили на двух других виртуалках в VMware. Их мы не перевозили и не собирались. Приложение в порядке, виртуалка в порядке, сеть в порядке; сломалось только допущение, что мир вокруг остался прежним.

Так и выглядит настоящая миграция. Перенести диск — самое лёгкое. Ломается всё, что вокруг него: адреса, имена, учётные данные, сертификаты, соседние системы.

</details>

Найдите файл настроек, направьте приложение на управляемые сервисы и пропишите сгенерированный пароль из шага 4.3. Перезапустите приложение.

<details><summary>Подсказка</summary>

`systemctl cat orders-api` показывает, как запускается сервис и какой файл он читает. Важны три строки: `spring.datasource.url`, `spring.datasource.password` и `spring.kafka.bootstrap-servers`.

</details>

<details><summary>Решение</summary>

```bash
cat /etc/orders/application.properties
PW='<password from postgres-orders-credentials>'
sed -i "s#192.168.10.30:5432#postgres-orders-rw:5432#; s#192.168.10.40:9092#kafka-events-kafka-bootstrap:9092#; s#^spring.datasource.password=.*#spring.datasource.password=$PW#" /etc/orders/application.properties
grep -E 'url|password|servers' /etc/orders/application.properties
systemctl restart orders-api
sleep 15
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

</details>

**Вы должны увидеть:** `200`.

### 5.3 Первый заказ

```bash
curl -s -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -d '{"item":"test"}' -w '\nHTTP %{http_code}\n'
```

**Вы должны увидеть:** `HTTP 500`, хотя проверка здоровья только что отвечала `200`.

<details><summary>Почему проверка здоровья зелёная, а заказ всё равно не проходит</summary>

Проверка здоровья убеждается лишь в том, что соединение с базой открывается. Есть ли в базе таблицы, которые нужны приложению, она не проверяет. А их нет: вы заказали пустую базу. На старой виртуалке таблицы много лет назад создали руками, и все об этом забыли. `journalctl -u orders-api | grep relation` показывает `relation "orders" does not exist`.

</details>

Создайте схему. Она лежит в этом репозитории, в [`scripts/orders-schema.sql`](scripts/orders-schema.sql): одна таблица и одна строка истории. Ставить клиент PostgreSQL на CentOS 7, чьи репозитории давно закрыты, нет смысла: база — управляемый сервис, так что говорите с ней со стороны платформы. В подах базы есть `psql`.

📍 На ноутбуке:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-workshop/master/en/laptop/scripts/orders-schema.sql
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role
( echo 'SET ROLE orders;'; cat orders-schema.sql ) | kubectl exec -i postgres-orders-1 -c postgres -- psql -d orders -v ON_ERROR_STOP=1
kubectl exec postgres-orders-1 -c postgres -- psql -d orders -c '\dt'
```

Берите тот под, который сейчас `primary`. `SET ROLE orders` делает владельцем таблицы пользователя приложения, а не суперпользователя, от имени которого вы попадаете в под базы.

**Вы должны увидеть:** `CREATE TABLE`, `INSERT 0 1`, затем таблицу `orders`, владелец которой — `orders`.

📍 Снова в виртуалке:

```bash
curl -s -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -d '{"item":"first order on Cozystack"}' -w '\nHTTP %{http_code}\n'
```

**Вы должны увидеть:** `HTTP 200` и новый заказ с `"status":"NEW"`.

### 5.4 Дошло ли событие до Kafka?

Каждый новый заказ приложение пишет в топик `orders`. Прочитайте топик со стороны платформы.

📍 На ноутбуке:

```bash
BROKER=$(kubectl get pods -l strimzi.io/name=kafka-events-kafka,strimzi.io/broker-role=true -o name | head -1)
kubectl exec $BROKER -- bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic orders --from-beginning --timeout-ms 8000
```

Метки на поды брокеров ставит оператор Strimzi, который запускает Kafka для каталога; `broker-role=true` выбирает брокер, а не контроллер KRaft.

**Вы должны увидеть:** идентификаторы созданных вами заказов, затем `TimeoutException` и `Processed a total of N messages`. Исключение означает лишь, что восемь секунд не приходило новых сообщений: так `--timeout-ms` останавливает потребителя. Цепочка «виртуалка → PostgreSQL → Kafka» работает.

### 5.5 Опубликуйте приложение по HTTPS

В vSphere вы попросили бы у сетевиков VIP и сертификат. Здесь вы описываете и то и другое в Git: `Service` Kubernetes, который направляет трафик на виртуалку, и `Ingress` на ingress-контроллере платформы с сертификатом Let's Encrypt.

Напишите `platform/publish.yaml`:

- `Service` с именем `orders`, который выбирает под виртуалки по метке `vm.kubevirt.io/name: vm-instance-app-1` и переводит порт 80 на 8080;
- `Ingress` с именем `orders`: `ingressClassName: tenant-root`, хост `orders.vmwXX.workshop.aenix.io`, бэкенд — `Service` `orders` на порту 80, TLS с сертификатом от кластерного издателя `letsencrypt-prod`.

<details><summary>Решение</summary>

```yaml
apiVersion: v1
kind: Service
metadata:
  name: orders
spec:
  selector:
    vm.kubevirt.io/name: vm-instance-app-1
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: orders
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    acme.cert-manager.io/http01-ingress-ingressclassname: tenant-root
spec:
  ingressClassName: tenant-root
  rules:
    - host: orders.vmwXX.workshop.aenix.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  number: 80
  tls:
    - hosts: [orders.vmwXX.workshop.aenix.io]
      secretName: orders-tls
```

</details>

```bash
git add platform/publish.yaml
git commit -m "Publish the order service over HTTPS"
git push
```

Подождите минуту, затем:

```bash
curl -s https://orders.vmwXX.workshop.aenix.io/actuator/health
```

**Вы должны увидеть:** тайм-аут или `502 Bad Gateway`.

> **Остановитесь и подумайте.** Внутри виртуалки приложение отвечает. `Service` и `Ingress` существуют. Что ещё мешает?

<details><summary>Подсказка</summary>

Что-то внутри гостевой системы: оно приехало из VMware и решает, до каких портов можно достучаться снаружи.

</details>

<details><summary>Решение</summary>

firewalld. Старая виртуалка пускала из сети только SSH, а к приложению ходили через балансировщик, которого здесь больше нет. Внутри виртуалки:

```bash
firewall-cmd --list-all
systemctl disable --now firewalld
```

При настоящей миграции вы бы вместо этого открыли порт 8080 (`firewall-cmd --add-port=8080/tcp --permanent && firewall-cmd --reload`). Так или иначе, это решение о гостевой системе, а не о платформе.

</details>

```bash
curl -s https://orders.vmwXX.workshop.aenix.io/actuator/health
curl -s https://orders.vmwXX.workshop.aenix.io/api/orders
```

**Вы должны увидеть:** `{"status":"UP"}` по HTTPS с действительным сертификатом и свои заказы. Откройте тот же адрес в браузере.

## Часть 6. День второй (25 мин)

📍 На ноутбуке.

Виртуалка переехала. Теперь посмотрите, каково её эксплуатировать в Cozystack.

### 6.1 Добавьте виртуалке памяти — через Git

Команда, которая отвечает за приложение, просит 4 GiB. Поменяйте `memory` в `platform/app-1.yaml`, сделайте коммит и пуш. Затем:

```bash
kubectl get virtualmachines vm-instance-app-1 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

**Вы должны увидеть:** `RestartRequired=True`. Процессор и память работающей виртуалки меняются только при перезапуске, поэтому платформа ждёт, когда вы сами выберете момент. Перезапустите её:

```bash
virtctl restart vm-instance-app-1
kubectl get virtualmachineinstances vm-instance-app-1 -o jsonpath='{.spec.domain.memory.guest}{" "}{.status.interfaces[0].ipAddress}{"\n"}'
```

**Вы должны увидеть:** `4Gi` и тот же IP-адрес, что и раньше. Изменение записано в Git под вашим именем, а адрес пережил перезапуск.

### 6.2 Перенесите виртуалку на лету, не прерывая трафик

Запустите цикл, который каждую секунду создаёт заказ. Пусть он работает во втором терминале:

```bash
while true; do curl -s -o /dev/null -w "%{http_code} " -X POST https://orders.vmwXX.workshop.aenix.io/api/orders -H 'Content-Type: application/json' -d '{"item":"load"}'; sleep 1; done
```

В первом терминале перенесите виртуалку на другой узел — так, как это сделал бы vMotion:

```bash
kubectl get virtualmachineinstances vm-instance-app-1 -o wide
virtctl migrate vm-instance-app-1
kubectl get virtualmachineinstancemigrations -w
```

**Вы должны увидеть:** миграция проходит через `Scheduling`, `TargetReady`, `Running` до `Succeeded` гораздо быстрее, чем за минуту; после неё виртуалка стоит на другом узле с тем же IP, а в цикле идёт непрерывная череда `200` (в момент переключения — от силы одна-две запинки).

Память копируется, пока виртуалка работает; диск вообще не переезжает, потому что лежит в реплицируемом хранилище, доступном с любого узла.

Если миграция минутами висит в `Scheduling`, значит, ни на одном другом узле не хватает свободной памяти для второй копии виртуалки: пока память копируется, живой миграции нужно место и для источника, и для приёмника. Это вопрос ёмкости к тем, кто эксплуатирует платформу, — тот же, что вы задали бы в vSphere о запасе ресурсов для DRS.

### 6.3 Потеряйте основной экземпляр базы

Цикл не останавливайте. Найдите основной экземпляр и убейте его, как будто у его сервера пропало питание:

```bash
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role
kubectl delete pod <the primary> --grace-period=5
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role -w
```

**Вы должны увидеть:** за считаные секунды реплика становится `primary`, а удалённый под возвращается как `replica`. В цикле около десяти секунд часть запросов падает, а потом снова идут `200`. Приложение переподключилось само, потому что обращается к `postgres-orders-rw` — имени, которое всегда указывает на текущий основной экземпляр.

Остановите цикл через `Ctrl-C`.

> **Остановитесь и подумайте.** Что делала старая схема в VMware, когда умирал хост с виртуалкой базы?

<details><summary>Ответ</summary>

vSphere HA перезапускала виртуалку базы на другом хосте: минута-другая простоя плюс восстановление PostgreSQL после сбоя, а от сломанного диска никакой защиты. Здесь база — управляемый кластер с горячей репликой; оператор повышает её за секунды, а бывший основной экземпляр возвращается в строй репликой, и никому не нужно ничего трогать.

</details>

## Что у вас теперь есть

Всё, что вы построили, лежит в вашем репозитории: `git log --oneline` рассказывает всю миграцию списком коммитов, а `platform/` описывает результат. Отдайте этот репозиторий коллеге — и его тенант станет таким же.

## Если что-то пошло не так

| Симптом | Вероятная причина | Что делать |
|---|---|---|
| Пуш ничего не изменил на платформе | Flux ещё не подхватил его или YAML некорректен | `kubectl get kustomization platform`; в сообщении названы файл и ошибка |
| `forbidden` на `bucket` | короткое имя совпало с другим типом | пишите `buckets.apps.cozystack.io` |
| Виртуалка застряла в `READY False` | HelmRelease отверг значения | `kubectl get helmrelease vm-instance-<name> -o yaml`, читайте `status.conditions` |
| `cloud-init status` никак не завершается | ещё идёт установка пакетов | подождите; `tail -f /var/log/cloud-init-output.log` |
| `virt-v2v: error: -os /root/out ... does not exist` | папка для результата должна существовать | `mkdir -p /root/out` |
| DataVolume застрял в `ImportInProgress` на 0% или упал | подписанная ссылка истекла или обрезалась при вставке | сгенерируйте новую ссылку, обновите `platform/app-1.yaml` |
| Консоль ничего не показывает | экран пуст | нажмите Enter; выход — `Ctrl-]` |
| Виртуалка в `Paused` с ошибкой ввода-вывода | под виртуалкой заново подключили реплику хранилища (известная проблема образа узлов на этом стенде, [cozystack#3168](https://github.com/cozystack/cozystack/issues/3168)) | `virtctl restart vm-instance-app-1` |
| Проверка здоровья отвечает `200`, заказы — `500` | в новой базе нет таблиц | часть 5.3 |
| HTTPS не отвечает по тайм-ауту или возвращает `502` | firewalld в гостевой системе | часть 5.5 |
