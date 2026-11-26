# 랩 4 · 새 버전 롤아웃과 롤백

| | |
|---|---|
| **소요 시간** | 30분 |
| **무엇을 증명하는가** | 유지보수 창(window) 없이, 실시간 트래픽 아래에서 버전을 바꾸고 되돌릴 수 있다 |
| **필요한 것** | 랩 0의 클러스터, 랩 1의 `rickroll`, 랩 3의 Fortio, 터미널 창 세 개, 브라우저 |

## 왜 중요한가

"Pass" 서비스는 한 번만 롤아웃하지만, 업데이트는 수십 번 하게 됩니다. 흔한 방식에서는 업데이트할 때마다 유지보수 창을 잡고, 토요일 밤을 잡고, 시작 전에 스냅샷을 뜨고, 지켜보는 사람 하나가 앉아 있어야 합니다. 변경 비용이 이렇게 크면 변경이 쌓입니다. 작은 롤아웃 열 번 대신 큰 롤아웃 한 번을 하게 되고, 큰 롤아웃일수록 더 쉽게 깨집니다.

그 비용이 얼마인지는 여기 실험용 쥐에게서 알아봅니다. 즉 "Pass"가 아니라 연습용 `rickroll`에서요. 애플리케이션의 버전을 **부하가 걸린 한복판에서** 바꿉니다. 한가한 시간이 아니라 분당 수천 건의 요청이 쏟아지는 와중에 말이죠. 그리고 오류 카운터를 지켜봅니다. 그런 다음, 역시 부하 아래에서 롤백합니다.

## 간단한 용어집

| 용어 | 무엇인가 | 비슷하지만… 다른 점 |
|---|---|---|
| **RollingUpdate** | 사본을 한꺼번에가 아니라 하나씩 교체하는 것 | **VM을 손으로 하나씩 업데이트**하는 것과 비슷하지만, 클러스터가 스스로 하고 새 사본이 뜨지 못하면 멈춘다 |
| **Revision** | 애플리케이션 명세를 저장해 둔 스냅샷 | **VM 스냅샷**과 비슷하지만, 명세만 보관하고 그 안에 데이터는 없다 |
| **maxSurge** | 롤아웃 동안 요청한 수를 넘어 추가로 띄울 수 있는 사본 수 | 직접적인 대응물은 없다. `replicas`에 대한 백분율로 계산하고 올림한다 |
| **maxUnavailable** | 교체를 기다리지 않고 내려도 되는 사본 수 | **한 번에 몇 대의 VM을 끄는가**와 비슷하지만, 내림하므로 사본이 셋이면 0이 된다 |
| **readinessProbe** | "트래픽을 받을 준비가 됐다"는 확인 | **로드 밸런서 풀의 health check**와 비슷하지만, 멤버를 밸런싱에서 빼기만 하는 게 아니라 롤아웃 자체를 붙잡아 둔다 |
| **ReplicaSet** | 명세의 한 버전을 담당하는, 동일한 사본들의 집합 | **템플릿에서 찍어낸 동일한 VM 풀**과 비슷하지만, 버전마다 자기 집합이 생기고 이전 집합은 사본 0으로 옆에 남는다 |
| **EndpointSlice** | 트래픽을 받을 준비가 된 사본들의 주소 목록 | **로드 밸런서 풀 멤버 목록**과 비슷하지만, 관리자가 손으로가 아니라 클러스터가 레이블로 관리한다 |
| **JSON Patch** | 객체 안의 경로로 필드 하나를 콕 집어 수정하는 것 | 직접적인 대응물은 없다. 경로가 목록 요소의 이름이 아니라 **인덱스**를 가리킨다 |

## 랩 폴더에 무엇이 들어 있나

파일은 이미 다 갖고 있습니다. 리포지토리와 함께 받았으니까요. 새로 만들거나 다시 타이핑할 것은 없습니다. 아래에서 `kubectl apply -f name.yaml`이 보이면, 그 파일은 여기서 가져오는 것입니다.

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| 파일 | 무엇인가 | 언제 쓰나 |
|---|---|---|
| `rickroll-page-v2.yaml` | 페이지의 두 번째 버전 — 부하 아래에서 롤아웃할 대상 | 자신의 `lab` 클러스터에 적용한다 |
| `check.sh` | 롤아웃이 요청 손실 없이 지나갔는지 확인하는 검사 | 랩 끝에서 실행한다 |
| — | 부하 생성기는 옆 랩에서 가져온다: `../03-scale/fortio.yaml` | |

## 1단계. 준비 작업

📍 **위치:** 노트북에서.

롤아웃 전에 두 가지를 해야 하고, 둘 다 겉치레가 아닙니다.

**오토스케일링을 끕니다.** 이것도 `replicas` 필드를 제어하기 때문입니다. 누군가 동시에 사본 수를 바꾸는 와중에 롤아웃을 지켜보는 것은 무슨 일이 일어났는지 이해하지 못하는 확실한 방법입니다. 필드 하나에 메커니즘 하나만.

**사본을 세 개로 만듭니다.** 교체가 하나씩 눈에 보이도록 말이죠. 여기서 사본이란 Pod입니다. 클러스터에서의 최소 실행 단위이자, 애플리케이션 컨테이너와 그 환경을 합친 것으로, VM 한 대에 가장 가까운 대응물입니다. 사본이 하나여도 롤아웃은 다운타임 없이 지나가지만, "Pod 하나가 있었는데 이제 다른 Pod가 됐다"만 보일 뿐 클러스터가 어떤 순서로 교체하는지는 보이지 않습니다.

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

Fortio 부하 생성기가 제자리에 있는지 확인하세요:

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

없다면 옆 폴더에서 띄우세요: `kubectl apply -f ../03-scale/fortio.yaml`.

## 2단계. 두 번째 버전을 클러스터에 넣기

📍 **위치:** 노트북에서.

폴더에 `rickroll-page-v2.yaml`이 있습니다. ConfigMap 타입 객체의 명세입니다. ConfigMap은 텍스트 파일을 애플리케이션과 별도로 클러스터에 보관하고, 클러스터가 그 파일을 컨테이너 안에 넣어 줍니다. 여기서는 nginx가 제공하는 페이지가 담겨 있습니다.

<details>
<summary><b>자세히 보기: rickroll-page-v2.yaml 안에 무엇이 있나</b></summary>

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

안에는 페이지 하나가 들어 있습니다. 다른 제목, 다른 색 배합, 눈에 띄는 "VERSION 2" 배지. 차이는 일부러 눈에 잘 띄게 만들었습니다. diff가 아니라 브라우저를 볼 테니까요.

두 가지를 눈여겨보세요.

**`__POD__`는 그대로 남아 있습니다.** 사본 이름을 치환하는 일은 두 버전이 공유하는 `rickroll-conf` ConfigMap의 nginx 설정이 합니다. 우리는 페이지를 바꾸는 것이지 서버의 동작을 바꾸는 게 아닙니다.

**객체 이름은 `rickroll-page`가 아니라 `rickroll-page-v2`입니다.** 이것이 이 랩 전체의 핵심 결정이며, 왜 그런지 짚어 볼 만합니다.

뻔한 수는 다른 것입니다. 기존 `rickroll-page-v1`을 가져와 그 내용을 다시 쓰는 것이죠. 명령 하나, 새 객체 없음. 그렇게 하지 마세요. 이유는 이렇습니다.

첫째, 옛것을 잃게 됩니다. 롤백이 없습니다. 이전 페이지는 여러분의 파일 말고는 어디에도 더 이상 존재하지 않고, `kubectl edit`으로 수정했다면 파일에도 없습니다.

둘째, 업데이트가 통제 불능이 됩니다. ConfigMap을 수정해도 애플리케이션 명세는 바뀌지 않으므로, 그 명세(어떤 이미지, 사본 몇 개, 파일을 어디서 가져올지)를 저장하고 그것이 지켜지도록 보장하는 객체인 Deployment는 아무것도 눈치채지 못하고 어떤 롤아웃도 시작하지 않습니다. 그런데도 클러스터는 실행 중인 Pod 안의 파일을 결국 바꿉니다. 스스로, 자기 타이밍에, 약 1분에 걸쳐, 사본들 사이에서 제멋대로의 순서로요. 그러면 이력에 없고, 명령으로 롤백할 수 없으며, 사본마다 제각각 도달한 변경을 얻게 됩니다.

그래서 규칙이 나옵니다. **버전은 서로 다른 객체이고, 버전을 바꾸는 것은 애플리케이션 명세를 바꾸는 것이다.** 바로 그렇게 해야 Deployment가 그것을 보고, 리비전 이력에 남고, 되돌릴 수 있습니다.

</details>

적용하세요. 클러스터에 두 번째 ConfigMap이 생기지만, 아직 아무것도 그것을 참조하지 않으므로 실행 중인 애플리케이션은 건드리지 않습니다:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**보게 될 것:** `configmap/rickroll-page-v2 created`.

이제 애플리케이션을 열어 **아무것도 바뀌지 않았음**을 확인하세요:

```bash
# port-forward = a temporary tunnel from the laptop into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the laptop, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — 똑같은 첫 번째 버전입니다. 새 페이지를 클러스터에 넣었지만 애플리케이션은 그것을 모릅니다. 볼륨이 여전히 `rickroll-page-v1`을 가리키고 있으니까요. 터널을 닫으세요(`Ctrl+C`). 아직 롤아웃이 아닙니다.

## 3단계. 클러스터가 사본을 어떻게 교체할지 이해하기

📍 **위치:** 노트북에서.

버전을 바꾸기 전에, 교체가 따를 규칙을 살펴봅시다. 이 규칙은 애플리케이션 명세 자체에 들어 있습니다:

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

이 블록은 `rickroll.yaml`에 없습니다. 클러스터가 기본값을 채워 넣은 것입니다.

<details>
<summary><b>우리의 사본 세 개에서 이 백분율이 뜻하는 것</b></summary>

두 숫자 모두 `replicas`, 즉 3을 기준으로 계산합니다. 그리고 반올림 방향이 반대입니다.

**`maxSurge: 25%`** — 교체가 진행되는 동안 요청한 수를 **넘어서** 몇 개의 사본을 띄워도 되는가. 3의 25%는 0.75이고, **올림**하면 1이 됩니다. 그래서 롤아웃 동안 클러스터에는 일시적으로 사본이 네 개까지 있을 수 있습니다.

**`maxUnavailable: 25%`** — 동시에 몇 개의 사본을 **사용 불가** 상태로 둬도 되는가. 3의 25%도 같은 0.75이지만, **내림**하면 **0**이 됩니다.

0은 절대적인 제약입니다. 준비된 교체본이 나타나기 전까지 클러스터는 작동 중인 사본을 단 하나도 내릴 수 없습니다. "노력한다"가 아니라 할 수 없습니다. 이것은 의도가 아니라 제약입니다.

그래서 각 교체 단계의 동작 순서는 이렇습니다:

1. 새 사본 하나를 띄운다(`maxSurge`가 허용);
2. 그 사본의 `readinessProbe`가 성공으로 응답할 때까지 기다린다;
3. 그것을 EndpointSlice에 추가한다, 즉 트래픽을 보낸다;
4. **그제서야** 옛 사본 하나를 밸런싱에서 빼고 내린다;
5. 옛 사본이 남지 않을 때까지 반복한다.

모든 것이 세 번째와 네 번째 항목에 달려 있고, 그 둘은 `readinessProbe`에 달려 있습니다. 매니페스트에서 준비 상태 검사를 없애면, 클러스터는 프로세스가 시작되는 순간부터 사본을 쓸 만한 것으로 취급하기 시작합니다. 아직 설정을 읽지 못한 nginx로 트래픽이 가고, 여러분은 500 오류 한 무더기를 받게 됩니다. 여기서 준비 상태 검사는 모니터링이 아니라 **롤아웃의 브레이크**이며, 그것이 그 검사의 주된 임무입니다.

쓸모 있는 따름 결론: 새 버전이 준비 상태 검사를 통과하지 못할 만큼 심하게 망가졌다면, 롤아웃은 **멈춥니다**. 옛 사본들은 계속 작동합니다. 이 랩 끝머리에서 이것을 보게 되는데, 다만 우리는 다른 방식으로 망가뜨릴 겁니다.

</details>

## 4단계. 부하 켜기

조용한 가운데 롤아웃하는 건 재미가 없습니다. vSphere에서도 그렇게 했죠. 트래픽을 흘려보내고 그 아래에서 버전을 바꿉시다.

📍 **창 1** — Fortio로 가는 터널:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the laptop → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **브라우저에서** — <http://localhost:8081/fortio/>. 다음을 채웁니다:

| 필드 | 값 | 왜 그런가 |
|---|---|---|
| URL | `http://rickroll/` | Service의 이름 — 모든 사본이 그 뒤에 서 있는 안정적인 주소; 트래픽이 특정 Pod가 아니라 밸런싱을 거쳐 간다 |
| QPS | `300` | 잔잔한 배경; 지금 최대치를 짜낼 필요는 없다 |
| Duration | `180s` | 3분 — 그 안에 롤아웃도 롤백도 해낼 수 있는 창 |
| Connections | `20` | |

**Start**를 누르고 **랩이 끝날 때까지 브라우저를 건드리지 마세요**.

폼이 잘 안 됐다면 같은 부하를 명령으로 줄 수도 있습니다:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your laptop,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **창 2** — 사본 지켜보기:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## 5단계. 버전 전환

📍 **창 3** — 비어 있는 창. 첫 번째는 Fortio로 가는 터널을 붙들고 있고, 두 번째는 Pod를 지켜보느라 붙잡혀 있으므로, 패치는 세 번째에서 실행합니다. 거기서 접근을 다시 설정해야 합니다:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

이제 애플리케이션 명세에서 정확히 필드 하나를 바꿉니다. `page`라는 이름의 볼륨 — 컨테이너 안에 넣어지는 폴더 — 이 그 내용을 ConfigMap `rickroll-page-v2`에서 가져오게 만드는 것입니다. "애플리케이션을 업데이트하라"는 명령은 없고 앞으로도 없을 겁니다. 있는 것은 어떻게 되어야 하는지에 대한 새 기록뿐입니다. 클러스터가 실제 상태와의 불일치를 스스로 알아채고 사본 교체를 시작합니다.

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**보게 될 것:**

```
deployment.apps/rickroll patched
```

⚠️ **이 패치는 부서지기 쉽고, 이것은 대놓고 말해 두어야 합니다.** 경로 `/spec/template/spec/volumes/0/...`는 볼륨을 **목록 안의 인덱스로** 지정합니다. `rickroll.yaml`에서는 `page` 볼륨이 첫 번째, `conf`가 두 번째로 오며 — 거기에는 그에 대한 주석까지 있습니다. 하지만 누군가 그 둘의 순서를 바꾸면(그리고 YAML은 그것을 전혀 금하지 않습니다), 똑같은 이 명령이 오류 하나 없이 nginx 설정의 이름을 덮어쓰고, 애플리케이션은 영문 모를 방식으로 깨집니다.

<details>
<summary><b>그런데도 왜 우리가 이렇게 하는지, 그리고 제대로 하는 법</b></summary>

JSON Patch를 택한 것은 그것이 메커니즘을 순수한 형태로 보여주기 때문입니다. 명령 하나, 필드 하나, 눈에 보이는 결과. 랩에서는 그게 값집니다.

**더 안전한 방법** — 같은 일을 평범한 merge patch로 하는 것입니다. Kubernetes의 목록은 키로 병합될 수 있고, `volumes`의 그 키는 `name`입니다:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

여기서는 볼륨의 이름으로 지정하므로, 목록 안 순서는 상관없고 헷갈릴 것도 없습니다.

**제대로 된 방법** — 아예 패치하지 않는 것입니다. 패치는 `kubectl edit`과 마찬가지로 클러스터의 객체는 바꾸지만 여러분의 파일은 바꾸지 않습니다. 일주일 뒤에 누군가 리포지토리에서 `rickroll.yaml`을 적용하면, 애플리케이션은 조용히 첫 번째 버전으로 되돌아갑니다. 아무도 왜 그런지 이해하지 못하겠죠.

정상적인 작업에서 버전은 이렇게 바꿉니다: 파일의 한 줄을 수정하고, 그 변경을 리뷰에 보내고, 병합된 뒤에 자동화가 적용합니다. 그러면 클러스터의 상태와 리포지토리의 내용이 항상 일치합니다. 바로 이것을 랩 5에서 하게 됩니다.

</details>

교체가 진행되는 것을 지켜보세요:

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

📍 **창 2에서는** 그동안 사본이 하나씩 교체되는 것을 볼 수 있습니다. 먼저 새 사본이 나타나 `1/1 Running`에 도달하고, 그제서야 옛 사본 중 하나가 `Terminating`으로 들어갑니다.

이름의 꼬리를 눈여겨보세요. 새 사본은 가운데 부분도 바뀌었습니다 — 다른 ReplicaSet이라는 뜻입니다. Deployment는 옛것을 손보지 않았고, 옆에 두 번째 것을 만들어 사본을 한쪽에서 다른 쪽으로 부어 넣습니다. 옛것은 어디로도 사라지지 않았습니다. 사본이 0인 채로 무대 뒤에서 대기하고 있습니다:

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

## 6단계. 오류 세기

📍 **위치:** 노트북에서, 창 3 — 앞의 명령이 끝나 비었습니다.

애플리케이션으로 가는 터널을 여세요:

```bash
# The same tunnel as at the start of the lab: port 8080 on the laptop → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **브라우저에서** <http://localhost:8080> — "VERSION 2" 배지가 붙은 초록색 페이지. 몇 번 새로고침해 보세요: 아래쪽 사본 이름이 바뀝니다. Service가 요청을 세 사본에 분배하기 때문입니다.

터널을 닫으세요(`Ctrl+C`).

📍 **이제 핵심 — Fortio 탭.** 실행이 끝나기를 기다렸다가 응답 코드가 적힌 줄을 찾으세요:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**오류 0.** 애플리케이션은 끊임없는 트래픽 아래에서 버전을 통째로 바꿨고, 5만 4천 건의 요청 중 단 하나도 다치지 않았습니다.

그 대가로 우리가 치른 것은 매니페스트의 블록 하나 — 바로 랩 1의 그 `readinessProbe`입니다. 그것이 없었다면 클러스터는 새 사본이 응답할 준비가 됐는지 확인하지 않은 채 옛 사본을 밸런싱에서 빼냈을 것이고, 이 줄은 다르게 보였을 겁니다.

⚠️ **수만 건의 요청 중 0이 아니라 오류 수십 개**가 나온다고 해서 테스트베드가 망가진 것은 아닙니다. 사본을 밸런싱에서 제거하는 것과 그 안의 프로세스를 멈추는 것은 병렬로 일어나고, 빠른 트래픽 아래에서는 한 줌의 연결이 그 틈으로 미끄러져 들어갑니다. 이것은 종료 전의 일시 정지(`preStop`)와 애플리케이션 자체의 우아한 연결 종료로 해결됩니다. 우리는 랩에서 일부러 이렇게 하지 않습니다. 틈이 저절로 닫힌다고 가정하기보다 그 틈이 존재한다는 것을 아는 편이 더 쓸모 있으니까요.

## 7단계. 롤백

Fortio에서 부하를 다시 시작하고(같은 파라미터), 그것이 도는 동안 변경 이력을 살펴보세요:

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

리비전 두 개. 각각은 변경 시점의 애플리케이션 명세를 저장해 둔 스냅샷입니다. 첫 번째는 `rickroll-page-v1`으로, 두 번째는 `v2`로. 이것들이 보관되는 것은 바로 옛 ReplicaSet들이 삭제되지 않기 때문입니다. 기본적으로 클러스터는 가장 최근 열 개를 유지합니다.

롤백:

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **창 2에서는** 같은 절차가 반대 방향으로 진행됩니다: 새 사본 세 개가 하나씩 올라오고, 현재 사본 세 개가 떠납니다. `kubectl get rs -l app=rickroll`을 실행하면 사본이 첫 번째 ReplicaSet — 0인 채로 걸려 있던 그것 — 으로 돌아갔음을 보여줍니다.

📍 **브라우저에서** 애플리케이션은 다시 첫 번째 버전입니다.

📍 **Fortio에서는** 다시 `Code 200 ... (100.0 %)`.

**이것을 vSphere에서의 롤백과 비교해 보세요.** 거기서 롤백은 스냅샷에서 복원하는 것을 뜻합니다: 머신이 꺼지고, 파일이 되돌려지고, 머신이 부팅됩니다. 수 분의 사용 불가에 더해, 스냅샷을 뜬 뒤에 일어난 모든 것의 손실. 여기서 롤백은 명세를 이전 리비전으로 되돌리는 것이며, 평범한 롤아웃과 전혀 다르지 않습니다: 똑같은 사본이 하나씩, 똑같은 제로 다운타임.

⚠️ **`CHANGE-CAUSE`가 비어 있고, 이것은 불편합니다.** 이력은 *무엇이* 바뀌었는지는 보관하지만 *왜*는 보관하지 않습니다. 한 달 뒤 리비전 2는 여러분에게 아무것도 말해 주지 않을 겁니다. 원인은 `kubernetes.io/change-cause` 애너테이션으로 채울 수 있지만, 이 질문에 대한 진짜 답은 애너테이션이 아니라 Git입니다. 거기에는 모든 변경마다 작성자와 날짜와 커밋 메시지가 있으니까요.

## 8단계. 통과하지 못할 검사

메커니즘은 분명합니다. 이제 롤아웃이 오류로 어긋날 때 무슨 일이 벌어지는지 봅시다 — 이런 일은 바라는 것보다 자주 일어납니다.

평범한 아침을 그려 보세요: 동료가 페이지의 세 번째 버전을 준비하다가 서두르는 바람에 이름에 오타를 냅니다. 그런데 매니페스트는 유효합니다 — 그런 객체가 없다는 것을 클러스터가 알아야 할 의무는 없으니까요. 정확히 이것을 재현해 봅시다:

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

**보게 될 것:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

사본 구성을 보세요: 이전 사본 셋은 작동 중이고, 새 사본은 시작 단계에서 멈춰 있습니다.

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

> **더 읽기 전에 멈추고 생각해 보십시오.**
>
> 여기에는 질문이 둘 있고, 두 번째가 첫 번째보다 더 중요합니다. 첫째: 왜 새 사본이 시작되지 않는가? 둘째: 지금 서비스에는 무슨 일이 일어나고 있는가 — 죽었는가?

<details>
<summary><b>답과, 이 오류보다 더 넓은 교훈</b></summary>

**왜 사본이 뜨지 않았나.** 우리는 `rickroll-page-v3`이라는 이름의 ConfigMap을 만든 적이 없습니다 — 클러스터에 없습니다. 클러스터에 직접 물어보세요:

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

눈여겨보세요: `kubectl patch` 명령은 성공적으로 끝났고 `patched`를 출력했습니다. 클러스터는 참조가 아무 데도 이어지지 않는 명세를 받아들이고 한마디도 하지 않았습니다. 매니페스트를 수락할 때 ConfigMap의 존재 여부를 검사하는 절차는 없습니다 — 그것은 Pod가 시작되는 순간에만 가능할 텐데, 바로 그 일이 일어난 것입니다.

**이제 두 번째 질문, 이 단계가 만들어진 이유입니다.** 걸려 있는 롤아웃 한복판에서 애플리케이션을 열어 보세요:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

작동합니다. 첫 번째 버전, 사본 셋, 오류 없음. 그때 Fortio에서 부하가 돌고 있었다면 — 보고서는 여전히 100퍼센트 200을 보여줍니다.

**완전히 망가진 롤아웃이 서비스를 죽이지 않았습니다.** 이것은 랩 시작 때 계산했던 `maxUnavailable: 0`의 직접적인 결과입니다: 클러스터는 준비된 교체본을 얻기 전까지 작동 중인 사본을 단 하나도 내릴 수 없었습니다. 교체본을 얻지 못했으니 — 아무것도 내리지 않은 것입니다. 롤아웃은 깨지기 시작한 바로 그 지점에서 멈췄고, 그 상태로 남았습니다.

**교훈은 이 오류보다 넓습니다.**

> Kubernetes에서 실패한 롤아웃은 기본적으로 **걸려 멈추는** 것이지, 무너지는 것이 아닙니다.

이것은 익숙한 업데이트 논리를 뒤집습니다. "멈추고, 업데이트하고, 시작한다" 방식에서는 중간의 어떤 오류든 다운타임을 뜻하고, 그래서 업데이트를 밤에, 사람이 전화기를 붙들고 하는 겁니다. "새것을 띄우고, 확인하고, 전환한다" 방식에서는 오류가 전환이 일어나지 않았다는 것을 뜻하고 — 옛것은 작동하던 그대로 작동합니다.

그래서 당직자를 위한 실용적 결론이 나옵니다: **걸려 멈춘 롤아웃은 인시던트가 아닙니다.** 그것은 여러분을 밤에 깨우지 않습니다. 아침에 처리해도 되고 — 혹은 명령 하나로 롤백해 두고 나중에 처리해도 됩니다.

바로 이것을 지금 할 겁니다.

</details>

빠져나오기:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

걸려 있던 사본이 사라지고, 명세는 작동하던 것으로 돌아갑니다.

## 검증

📍 **위치:** 노트북에서, `kubectl`로 작업하던 바로 그 터미널 창에서.

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **Windows에서는 스크립트를 PowerShell이 아니라 WSL에서 실행합니다** — 설치 방법은 랩 0 앞부분에 적혀 있습니다. WSL 없이도 랩은 완료할 수 있지만, 산출물 보고서는 없습니다.

스크립트는 여러분이 타이핑한 명령이 아니라 사안의 본질을 봅니다: 애플리케이션 이력에 리비전이 여러 개 있고(즉 버전이 실제로 바뀌었다가 되돌아왔음), 두 번째 버전의 ConfigMap이 클러스터에 있으며, 애플리케이션이 HTTP로 응답하고, 그것이 제공하는 페이지가 명세가 가리키는 ConfigMap과 일치하는지. 별도로 `readinessProbe`도 검사합니다 — 그것이 없으면 제로 다운타임을 재현할 수 없으니까요.

## 정리

`rickroll` 애플리케이션은 나중에 필요하니 — 삭제하지 않습니다. 사본을 하나로 되돌리세요:

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

부하 생성기는 더 이상 필요 없습니다:

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

`rickroll-page-v2` ConfigMap은 그대로 둬도 됩니다: 몇 킬로바이트를 차지할 뿐 CPU도 메모리도 소비하지 않습니다. Kubernetes에서 명세는 control plane의 데이터베이스에 저장되고, 아무것도 그것을 참조하지 않는 동안에는 아무 비용도 들지 않습니다 — 스토리지의 공간을 차지하고 오래 살수록 머신을 더 느리게 만드는 가상 머신 스냅샷과는 다릅니다.

## 이제 우리가 할 수 있는 것

- 실시간 트래픽 아래에서 애플리케이션의 버전을 바꾸고, 오류가 없었음을 카운터로 확인하기
- 제로 다운타임이 어디서 오는지 설명하기: `maxUnavailable`, `readinessProbe`, 그리고 "먼저 준비, 그다음 전환" 순서
- 리비전 이력을 읽고 명령 하나로 롤백하기
- 왜 버전을 기존 것을 수정하는 대신 별도의 객체로 만드는지 이해하기
- 망가진 롤아웃이 서비스를 죽이는 게 아니라 걸려 멈춘다는 것, 그리고 왜 그것이 인시던트가 아닌지 알기

## 그리고 vSphere에서라면

미리 합의한 유지보수 창. 시작 전 스냅샷 — 수 분과 스토리지 공간. 제자리 업데이트. 잘 안 됐다면 — 스냅샷에서 복원, 다시 수 분의 사용 불가. 이 모든 것을 밤에 하는데, 낮에는 할 수 없기 때문입니다.

여기서는 — 낮에, 트래픽 아래에서 명령 하나, 그리고 결과가 마음에 들지 않으면 명령 하나 더.

**vSphere가 더 편한 지점, 솔직하게.** 세 가지입니다.

첫째이자 무엇보다: **스냅샷은 상태를 통째로 가져가지만, `rollout undo`는 명세만 가져갑니다.** 새 버전이 작동하던 동안 애플리케이션이 데이터베이스에 무언가를 쓰거나 스키마를 바꿨다면, 롤백은 코드는 되돌리지만 데이터는 되돌리지 않습니다. 새 데이터 위에 옛 버전을 얹은 꼴이 되고 — 때로는 그것이 그냥 놔두는 것보다 더 나쁩니다. VM 스냅샷은 이로부터 여러분을 구하지만, `rollout undo`는 그러지 못합니다. 데이터베이스 스키마 마이그레이션을 양방향으로 호환되게 작성하는 것은 바로 이 때문이며, 그것은 vSphere는 요구하지 않았지만 Kubernetes는 여러분에게 요구할 규율입니다.

둘째, vSphere에서의 롤백은 정말 모든 것을 되돌립니다: 손으로 설치한 패키지, 전화로 지시받아 설정에 넣은 수정. 여기서는 매니페스트에 기술된 것만 롤백됩니다. 누군가 옆길로 한 일은 클러스터가 그것을 모르기 때문에 롤백되지 않습니다.

셋째, 스냅샷은 애플리케이션이 두 버전으로 동시에 작동할 수 있기를 요구하지 않습니다. 하지만 `RollingUpdate`는 요구합니다: 롤아웃 동안 옛 사본과 새 사본이 하나의 주소 뒤에서 함께 요청을 처리합니다. 그것들이 서로 호환되지 않으면 — 세션 형식에서, 데이터 스키마에서, 프로토콜에서 — 제로 다운타임은 없고 엉망만 남습니다. 이에 준비되지 않은 애플리케이션을 위해서는 `Recreate` 전략이 있습니다: 전부 내리고, 그다음 전부 띄우는 것. 다운타임이 생기지만 예측 가능하고, 때로는 그것을 고르는 편이 더 정직합니다.
