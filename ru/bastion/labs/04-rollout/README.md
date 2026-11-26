# Лаба 4 · Выкатка новой версии и откат

| | |
|---|---|
| **Время** | 30 минут |
| **Что доказывает** | Версию можно менять и возвращать под боевым трафиком, без окна обслуживания |
| **Что понадобится** | Кластер из лабы 0, `rickroll` из лабы 1, Fortio из лабы 3, три окна терминала, браузер |

## Зачем это

Сервис «Пропуск» вы выкатите один раз, а обновлять будете десятки раз. Каждое обновление в
привычной схеме — это согласование окна, ночь субботы, снапшот перед началом и человек,
который сидит и смотрит. Такая цена за изменение приводит к тому, что изменения копят: вместо
десяти маленьких выкатывают одну большую, а большая ломается охотнее.

Сколько это стоит здесь, разберёмся на кошках — то есть на учебном `rickroll`, а не на
«Пропуске». Мы подменим версию приложения **прямо во время нагрузки** — не в тихий час, а
посреди тысяч запросов в минуту, — и посмотрим на счётчик ошибок. Потом откатимся, тоже под
нагрузкой.

## Словарик

| Термин | Что это | Похоже на… но |
|---|---|---|
| **RollingUpdate** | Замена копий по очереди, а не всех разом | **Обновление ВМ по одной руками**, но кластер делает это сам и останавливается, если новая копия не поднялась |
| **Ревизия** | Сохранённый снимок описания приложения | **Снапшот ВМ**, но хранит только описание, никаких данных внутри нет |
| **maxSurge** | Сколько копий сверх заказанного разрешено поднять на время выкатки | прямого аналога нет; считается в процентах от `replicas` и округляется вверх |
| **maxUnavailable** | Сколько копий разрешено погасить, не дождавшись замены | **Сколько ВМ гасим за раз**, но округляется вниз, поэтому при трёх копиях выходит ноль |
| **readinessProbe** | Проверка «готов принимать трафик» | **Health check в пуле балансировщика**, но она же тормозит выкатку, а не только выводит из балансировки |
| **ReplicaSet** | Набор одинаковых копий, отвечающий за одну версию описания | **Пул одинаковых ВМ из шаблона**, но на каждую версию заводится свой набор, а прежний остаётся рядом с нулём копий |
| **EndpointSlice** | Список адресов копий, готовых принимать трафик | **Список членов пула балансировщика**, но его ведёт кластер по меткам, а не администратор руками |
| **JSON Patch** | Точечная правка одного поля по пути внутри объекта | прямого аналога нет; путь указывает **номер** элемента в списке, а не имя |

## Что лежит в папке лабы

Все файлы уже у вас — вы забрали их вместе с репозиторием. Создавать и печатать заново
ничего не нужно: там, где ниже написано `kubectl apply -f name.yaml`, файл берётся отсюда.

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| Файл | Что это | Когда пригодится |
|---|---|---|
| `rickroll-page-v2.yaml` | Вторая версия страницы — то, что выкатываем под нагрузкой | применяете на своём кластере `lab` |
| `check.sh` | Проверка, что выкатка прошла без потери запросов | запускаете в конце лабы |
| — | Генератор нагрузки берём из соседней лабы: `../03-scale/fortio.yaml` | |

## Шаг 1. Готовим площадку

📍 **Где:** на виртуалке (в терминале bastion).

Перед выкаткой нужно сделать две вещи, и обе не косметические.

**Автомасштабирование снимаем**, потому что оно тоже управляет полем `replicas`. Наблюдать за
выкаткой, когда одновременно с ней кто-то меняет количество копий, — гарантированный способ
не понять, что произошло. Один механизм на одно поле.

**Копий делаем три**, чтобы замену было видно поштучно. Копия здесь — это под: минимальная
единица запуска в кластере, контейнер приложения вместе с его окружением, ближайший аналог
одной ВМ. На одной копии выкатка тоже пройдёт без простоя, но вы увидите только «был один
под, стал другой» и не увидите, в каком порядке кластер их меняет.

```bash
# KUBECONFIG — the file with the cluster's address and the credentials to log into it. While the
# variable is set, every kubectl command goes to the `lab` cluster, not the one it was issued from.
export KUBECONFIG=~/lab.kubeconfig

# hpa — the autoscaler set up in the scaling lab. We delete it
# so the number of copies changes only on our command.
#   --ignore-not-found  don't treat it as an error if it's no longer in the cluster
kubectl delete hpa rickroll --ignore-not-found

# scale = "keep this many copies". The number goes into the application's description,
# and the cluster then brings up the missing ones itself.
kubectl scale deployment rickroll --replicas=3

# rollout status = "wait until the requested becomes actual". The command keeps the window
# busy until all three copies are ready, and only then returns the prompt.
kubectl rollout status deployment/rickroll
```

Проверьте, что генератор нагрузки Fortio на месте:

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

Если его нет — поднимите из соседней папки: `kubectl apply -f ../03-scale/fortio.yaml`.

## Шаг 2. Кладём в кластер вторую версию

📍 **Где:** на виртуалке (в терминале bastion).

В папке лежит `rickroll-page-v2.yaml` — описание объекта типа ConfigMap. ConfigMap держит
текстовый файл в кластере отдельно от приложения, а кластер потом подкладывает этот файл
внутрь контейнера. Здесь в нём лежит страница, которую отдаёт nginx.

<details>
<summary><b>Разбираем rickroll-page-v2.yaml</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">VERSION 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">served by pod<b>__POD__</b></div>
```

Внутри одна страница: другой заголовок, другая цветовая гамма, заметная плашка «VERSION 2».
Различия сделаны бросающимися в глаза намеренно — вы будете смотреть в браузер, а не в diff.

Обратите внимание на две вещи.

**`__POD__` остался на месте.** Подмена имени копии делается настройками nginx из ConfigMap
`rickroll-conf`, а он общий для обеих версий. Мы меняем страницу, а не поведение сервера.

**Имя объекта — `rickroll-page-v2`, а не `rickroll-page`.** Это и есть ключевое решение всей
лабы, и стоит проговорить, почему так.

Напрашивается ведь другое: взять существующий `rickroll-page-v1` и переписать в нём
содержимое. Одна команда, никаких новых объектов. Так делать не надо, и вот почему.

Во-первых, вы потеряете старое. Отката не будет: прежней страницы больше нет нигде, кроме
как в вашем файле, — а если правку сделали через `kubectl edit`, то и в файле её нет.

Во-вторых, обновление получится неуправляемым. Описание приложения при правке ConfigMap не
меняется, значит Deployment — объект, который хранит это описание (какой образ, сколько
копий, откуда брать файлы) и следит за его исполнением, — ничего не заметит и никакой
выкатки не начнёт. Файлы внутри
работающих подов при этом кластер всё-таки подменит — сам, в свой момент, в течение примерно
минуты и в произвольном порядке между копиями. Получится изменение, которого нет в истории,
которое нельзя откатить командой и которое доехало до копий вразнобой.

Поэтому правило: **версии — это разные объекты, а переключение версии — это изменение
описания приложения.** Именно так его увидит Deployment, так оно попадёт в историю ревизий,
и так его можно будет отменить.

</details>

Применяем. В кластере появится второй ConfigMap; работающее приложение он не тронет, потому
что на него пока никто не ссылается:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**Что вы должны увидеть:** `configmap/rickroll-page-v2 created`.

Теперь откройте приложение и убедитесь, что **ничего не изменилось**:

```bash
# port-forward = a temporary tunnel from the bastion into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the bastion, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — та же первая версия. Мы положили новую страницу в кластер, но
приложение о ней не знает: его том по-прежнему смотрит на `rickroll-page-v1`. Закройте
туннель (`Ctrl+C`), это ещё не выкатка.

## Шаг 3. Разбираемся, как кластер будет менять копии

📍 **Где:** на виртуалке (в терминале bastion).

Прежде чем переключать версию, посмотрим на правила, по которым пойдёт замена копий. Они
лежат в самом описании приложения:

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Этого блока нет в `rickroll.yaml` — кластер подставил значения по умолчанию.

<details>
<summary><b>Что означают эти проценты при наших трёх копиях</b></summary>

Оба числа считаются от `replicas`, то есть от трёх. И округляются они в разные стороны.

**`maxSurge: 25%`** — сколько копий разрешено поднять **сверх** заказанного, пока идёт замена.
25% от трёх — это 0,75, округление **вверх** даёт 1. Значит на время выкатки в кластере
временно может быть четыре копии.

**`maxUnavailable: 25%`** — сколько копий разрешено держать **недоступными** одновременно.
25% от трёх — те же 0,75, но округление **вниз** даёт **0**.

Ноль — это жёсткое ограничение. Кластер не имеет права погасить ни одну работающую копию,
пока не появилась готовая замена. Не «постарается», а не имеет права: это ограничение, а не
намерение.

Отсюда порядок действий на каждом шаге замены:

1. поднять одну новую копию (разрешено `maxSurge`);
2. дождаться, пока её `readinessProbe` ответит успехом;
3. добавить её в EndpointSlice, то есть пустить на неё трафик;
4. **только теперь** вывести из балансировки и погасить одну старую;
5. повторить, пока старых не останется.

Всё держится на третьем и четвёртом пунктах, а они держатся на `readinessProbe`. Уберите
проверку готовности из манифеста — и кластер начнёт считать копию пригодной в момент запуска
процесса. Трафик пойдёт на nginx, который ещё не прочитал конфиг, и вы получите порцию
пятисотых. Проверка готовности здесь не мониторинг, а **тормоз выкатки**, и это её главная
работа.

Полезное следствие: если новая версия сломана настолько, что не проходит проверку готовности,
выкатка **остановится**. Старые копии продолжат работать. Мы это увидим ближе к концу
лабы, только сломаем по-другому.

</details>

## Шаг 4. Включаем нагрузку

Выкатывать в тишине неинтересно — так поступали и в vSphere. Пустим трафик и будем менять
версию под ним.

📍 **Окно 1** — туннель до Fortio:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the bastion → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **В браузере** — <http://localhost:8081/fortio/>. Заполняем:

| Поле | Значение | Почему так |
|---|---|---|
| URL | `http://rickroll/` | имя Service — постоянного адреса, за которым стоят все копии; трафик пойдёт через балансировку, а не в конкретный под |
| QPS | `300` | ровный фон; выжимать максимум сейчас не нужно |
| Duration | `180s` | три минуты — окно, внутри которого мы успеем и выкатить, и откатить |
| Connections | `20` | |

Нажимаем **Start** и **не трогаем браузер до конца лабы**.

Ту же нагрузку можно дать командой, если с формой не сложилось:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your bastion,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **Окно 2** — смотрим за копиями:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## Шаг 5. Переключаем версию

📍 **Окно 3** — свободное окно. Первое держит туннель к Fortio, второе занято слежением
за подами, поэтому патч выполняем в третьем. Доступ в нём нужно задать заново:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

Сейчас мы изменим ровно одно поле в описании приложения: том с именем `page` — папка, которая
подкладывается внутрь контейнера, — должен брать содержимое из ConfigMap `rickroll-page-v2`.
Команды «обнови приложение» нет и не будет: есть только новая запись о том, как должно быть.
Расхождение с фактическим состоянием кластер заметит сам и начнёт замену копий.

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**Что вы должны увидеть:**

```
deployment.apps/rickroll patched
```

⚠️ **Этот патч хрупкий, и об этом надо сказать прямо.** Путь
`/spec/template/spec/volumes/0/...` адресует том **по номеру в списке**. В `rickroll.yaml`
первым идёт том `page`, вторым `conf` — там даже стоит комментарий об этом. Но если кто-то
поменяет их местами (а YAML это никак не запрещает), та же самая команда без единой ошибки
перепишет имя конфига nginx, и приложение сломается непонятным образом.

<details>
<summary><b>Почему мы всё-таки делаем так и как правильно</b></summary>

JSON Patch взят потому, что он показывает механику в чистом виде: одна команда, одно поле,
видимое следствие. Для лабы это ценно.

**Безопаснее** — то же самое обычным патчем-слиянием. Списки в Kubernetes умеют сливаться по
ключу, и у `volumes` этот ключ — `name`:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

Здесь адресация идёт по имени тома, порядок в списке не имеет значения, и перепутать нечего.

**Правильно** — не патчить вообще. Патч, как и `kubectl edit`, меняет объект в кластере, но
не меняет ваш файл. Через неделю кто-то применит `rickroll.yaml` из репозитория, и приложение
молча уедет обратно на первую версию. Никто не поймёт, почему.

В нормальной работе версию меняют так: правят строку в файле, отправляют изменение на ревью,
после слияния его применяет автоматика. Тогда состояние кластера и содержимое репозитория
совпадают всегда. Ровно этим мы займёмся в лабе 5.

</details>

Смотрим, как идёт замена:

```bash
# rollout status prints the progress of the replacement line by line and finishes when all copies are updated.
# If the rollout doesn't converge, the command returns a non-zero exit code — convenient for
# stopping it in scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **В окне 2** тем временем видно, как копии сменяются по одной: сначала появляется новая и
доходит до `1/1 Running`, и только после этого одна из старых уходит в `Terminating`.

Обратите внимание на хвост имён: у новых копий изменилась и средняя часть — это другой
ReplicaSet. Deployment не переделывал старый, он создал рядом второй и переливает копии из
одного в другой. Старый никуда не делся, в нём ноль копий, и он ждёт своего часа:

```bash
# rs — shorthand for ReplicaSet, a set of copies of one version of the description.
# DESIRED — how many copies are requested in this set, READY — how many of them are ready to answer.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## Шаг 6. Считаем ошибки

📍 **Где:** на виртуалке, в окне 3 — оно освободилось после предыдущей команды.

Открываем туннель до приложения:

```bash
# The same tunnel as at the start of the lab: port 8080 on the bastion → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **В браузере** <http://localhost:8080> — зелёная страница с плашкой «VERSION 2». Обновите
несколько раз: имя копии внизу меняется, потому что Service раскладывает запросы по трём
копиям.

Закройте туннель (`Ctrl+C`).

📍 **Теперь главное — вкладка Fortio.** Дождитесь конца прогона и найдите строки с кодами
ответа:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**Ошибок ноль.** Приложение сменило версию целиком, под непрерывным трафиком, и ни один из
пятидесяти четырёх тысяч запросов не пострадал.

Заплатили за это одним блоком в манифесте — той самой `readinessProbe` из лабы 1. Без неё
кластер выводил бы старую копию из балансировки, не убедившись, что новая готова отвечать, и
эта строка выглядела бы иначе.

⚠️ **Несколько десятков ошибок на десятки тысяч запросов вместо нуля** — это не поломка
стенда. Удаление копии из балансировки и остановка процесса в ней происходят параллельно, и
на быстром трафике в этот зазор успевает попасть горсть соединений.
Лечится это паузой перед остановкой (`preStop`) и корректным завершением соединений в самом
приложении. Мы этого в лабе не делаем намеренно: полезнее знать, что зазор существует, чем
считать, будто он закрывается сам.

## Шаг 7. Откатываемся

Запустите нагрузку в Fortio ещё раз (те же параметры) и, пока она идёт, посмотрите историю
изменений:

```bash
# history = the list of saved revisions of the description. Each line is a state you can
# return to with a single command. CHANGE-CAUSE — an optional note on why it was changed.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

Две ревизии. Каждая — сохранённый снимок описания приложения на момент изменения. Первая с
`rickroll-page-v1`, вторая с `v2`. Хранятся они ровно потому, что старые ReplicaSet не
удаляются: по умолчанию кластер держит десять последних.

Откат:

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **В окне 2** — та же процедура в обратную сторону: три новых копии поднимаются по одной,
три текущих уходят. `kubectl get rs -l app=rickroll` покажет, что копии вернулись в первый
ReplicaSet — тот, что висел с нулём.

📍 **В браузере** приложение снова первой версии.

📍 **В Fortio** — снова `Code 200 ... (100.0 %)`.

**Сравните с откатом в vSphere.** Там откат — это восстановление из снапшота: машина
выключается, файлы возвращаются, машина загружается. Минуты недоступности плюс потеря всего,
что произошло после снятия снапшота. Здесь откат — это возврат описания к предыдущей ревизии,
и он ничем не отличается от обычной выкатки: те же копии по одной, тот же нулевой простой.

⚠️ **`CHANGE-CAUSE` пуст, и это неудобно.** История хранит, *что* поменялось, но не хранит,
*почему*. Через месяц ревизия 2 не скажет вам ничего. Заполнить причину можно аннотацией
`kubernetes.io/change-cause`, но настоящий ответ на этот вопрос — не аннотация, а Git, где у
каждого изменения есть автор, дата и текст коммита.

## Шаг 8. Проверка, которая не пройдёт

Механизм понятен. Теперь посмотрим, что бывает, когда выкатка уходит с ошибкой — а это
случается чаще, чем хотелось бы.

Представьте обычное утро: коллега готовит третью версию страницы, торопится и в имени
делает опечатку. Манифест при этом валиден — кластер не обязан знать, что такого объекта
нет. Воспроизведём ровно это:

```bash
# The same patch as when switching to the second version, but with a mistake in the ConfigMap name:
# there is no object `rickroll-page-v3` in the cluster. The reference's existence isn't checked on acceptance,
# so the command will finish successfully.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — don't wait forever: not having gotten ready copies, the command gives up after a
# minute and a half and returns an error. The rollout itself won't go anywhere and will stay hanging.
kubectl rollout status deployment/rickroll --timeout=90s
```

**Что вы увидите:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

Смотрим на состав копий: три прежние работают, новая застряла на запуске.

```bash
# The READY column counts the ready containers inside the Pod: 1/1 — ready, 0/1 — not.
# STATUS says exactly where the startup stalled.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **Остановитесь и подумайте, прежде чем читать дальше.**
>
> Вопросов здесь два, и второй важнее первого. Первый: почему новая копия не запускается?
> Второй: что сейчас происходит с сервисом — он лежит?

<details>
<summary><b>Ответ и урок шире, чем эта ошибка</b></summary>

**Почему копия не поднялась.** ConfigMap с именем `rickroll-page-v3` мы не создавали — его в
кластере нет. Спросите у кластера напрямую:

```bash
# events — the cluster's log of occurrences, the nearest analogue of the Tasks & Events tab in vCenter.
#   --field-selector reason=FailedMount  keep only the records about a failed volume mount
#   --sort-by=.lastTimestamp             sort by time, the freshest end up at the bottom
#   | tail -3                            show the last three lines, discard the rest
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

Заметьте: команда `kubectl patch` отработала успешно и напечатала `patched`. Кластер принял
описание, в котором ссылка ведёт в никуда, и не сказал ни слова. Проверки на существование
ConfigMap при приёме манифеста нет — она была бы возможна только в момент запуска пода, что и
произошло.

**А теперь второй вопрос, ради которого шаг и сделан.** Откройте приложение прямо посреди
застрявшей выкатки:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

Оно работает. Первая версия, три копии, ошибок нет. Если у вас в этот момент шла нагрузка в
Fortio — в отчёте по-прежнему сто процентов двухсотых.

**Полностью сломанная выкатка не уронила сервис.** Это прямое следствие `maxUnavailable: 0`,
которое мы считали в начале лабы: кластер не имел права погасить ни одной работающей копии,
пока не получил готовую замену. Замены он не получил — значит и гасить не стал. Выкатка
остановилась ровно там, где начала ломаться, и осталась в этом состоянии.

**Урок шире, чем эта ошибка.**

> Неудачная выкатка в Kubernetes по умолчанию **застревает**, а не обрушивается.

Это переворачивает привычную логику обновления. В схеме «остановили, обновили, запустили»
любая ошибка посередине означает простой, и поэтому обновление делают ночью, с людьми на
телефоне. В схеме «подними новое, убедись, переключи» ошибка означает, что переключение
не состоялось, — а старое как работало, так и работает.

Отсюда практическое следствие для дежурного: **застрявшая выкатка — не инцидент.**
Она не будит вас ночью. Её можно разобрать утром — или откатить одной командой и разбираться
потом.

Именно это мы сейчас и сделаем.

</details>

Выбираемся:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

Зависшая копия исчезает, описание возвращается к рабочему.

## Проверка

📍 **Где:** на виртуалке, в том же окне терминала, где вы работали с `kubectl`.

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **На Windows скрипт запускается из WSL**, а не из PowerShell — как его поставить,
написано в начале лабы 0. Без WSL лабу можно пройти, но отчёта-артефакта не будет.

Скрипт смотрит на существо дела, а не на набранные команды: в истории приложения есть
несколько ревизий (значит версию действительно меняли и возвращали), в кластере лежит
ConfigMap второй версии, приложение отвечает по HTTP, и отданная им страница соответствует
тому ConfigMap, на который указывает описание. Отдельно проверяется `readinessProbe` — без
неё нулевой простой не воспроизвести.

## Уборка

Приложение `rickroll` понадобится дальше — не удаляем. Верните ему одну копию:

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

Генератор нагрузки больше не нужен:

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

ConfigMap `rickroll-page-v2` можно оставить: он занимает пару килобайт и не потребляет ни
процессора, ни памяти. Описания в Kubernetes хранятся в базе control plane и ничего не стоят,
пока на них никто не ссылается, — в отличие от снапшота виртуальной машины, который занимает
место на хранилище и тем сильнее замедляет машину, чем дольше живёт.

## Что мы теперь умеем

- Менять версию приложения под боевым трафиком и проверять по счётчику, что ошибок не было
- Объяснять, откуда берётся нулевой простой: `maxUnavailable`, `readinessProbe` и порядок
  «сначала готово, потом переключаем»
- Читать историю ревизий и откатываться одной командой
- Понимать, почему версии делают разными объектами, а не правкой существующего
- Знать, что сломанная выкатка застревает, а не роняет сервис, и почему это не инцидент

## А в vSphere это было бы

Окно обслуживания, согласованное заранее. Снапшот перед началом — минуты и место на
хранилище. Обновление на месте. Если не взлетело — восстановление из снапшота, ещё минуты
недоступности. Всё это ночью, потому что днём нельзя.

Здесь — одна команда днём, под трафиком, и вторая команда, если не понравилось.

**Где vSphere удобнее, честно.** Три вещи.

Во-первых и главное: **снапшот забирает состояние целиком, а `rollout undo` — только
описание.** Если ваше приложение за время работы новой версии успело что-то записать в базу
или изменить схему, откат вернёт код и не вернёт данные. Вы получите старую версию поверх
новых данных — иногда это хуже, чем оставить как было. Снапшот виртуалки от этого спасает,
`rollout undo` — нет. Ровно поэтому миграции схемы БД пишут совместимыми в обе стороны, и это
дисциплина, которой Kubernetes от вас потребует, а vSphere не требовал.

Во-вторых, откат в vSphere возвращает вообще всё: пакеты, которые доставили руками, правку в
конфиге, сделанную по телефону. Здесь откатывается только то, что было описано в манифесте.
Всё, что кто-то сделал в обход, не откатится, потому что кластер о нём не знает.

В-третьих, снапшот не требует, чтобы приложение умело работать в двух версиях одновременно. А
`RollingUpdate` требует: во время выкатки старые и новые копии обслуживают запросы вместе, за
одним адресом. Если они несовместимы между собой — по формату сессии, по схеме данных, по
протоколу — нулевого простоя не будет, будет каша. Для приложений, которые к этому не готовы,
существует стратегия `Recreate`: погасить все, потом поднять все. Она даёт простой, зато
предсказуема, и иногда честнее выбрать её.
