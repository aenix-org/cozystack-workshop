## 30. Крок 9: перевіряємо весь ланцюг

**Момент істини**

⚠️ **Спершу — усередині віртуальної машини — вимкніть firewalld.** Мігрований CentOS
приніс правила з минулого життя і назовні віддає лише SSH. Порт застосунку закритий, і
проброс із ноутбука впреться в `no route to host` — а виглядатиме це як «застосунок не працює».

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Перевірте прямо там же, зсередини машини, що застосунок живий:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — можна пробрасувати. `503` — поверніться до кроку з мережею.

📍 **Далі — на ноутбуці.** Пробрасуємо порт застосунку до себе:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
Вікно з цією командою не закривайте: тунель живе, поки вона працює.

⚠️ **Тут `vmi/` обов'язковий, а в `virtctl console` — навпаки, заважає.** Це не
одрук і не наша примха: у двох команд різний синтаксис цілі. `port-forward` вимагає
`тип/ім'я` і без префікса відповідає `target must contain type and name separated by '/'`.
`console` очікує просто ім'я і з префіксом відповідає `forbidden`, бо приймає
слово `vmi` за ім'я машини.

Якщо virtctl нарікає на різницю версій клієнта й кластера — це попередження,
а не помилка, працювати не заважає.

Якщо проброс усе одно не піднімається, той самий тунель робиться через Pod машини:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <pod-name-from-output> 8080:8080
```

В іншому вікні термінала:
```bash
# здоров'я
curl -s http://localhost:8080/actuator/health

# створюємо замовлення
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# дивимося, що воно записалося
curl -s http://localhost:8080/api/orders
```

Якщо замовлення створилося — ви пройшли шлях цілком. Застосунок приїхав із VMware, працює
в кластері, пише в керовану базу і надсилає події в керовану чергу.

Пів години тому ця система жила на ESXi.
