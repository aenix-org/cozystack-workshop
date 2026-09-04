## 28. 스텝 8: 애플리케이션이 여전히 실패하는 이유

**데이터베이스가 비어 있습니다 — 애플리케이션에는 자신의 스키마가 필요합니다**

📍 **위치:** 여러분 자신의 머신 안 — 세 번째 페이즈에서 올린 그 머신(app-VM)입니다. bastion이 아닙니다. 이 머신은 이미 클러스터 네트워크에 있고 데이터베이스를 이름으로 볼 수 있습니다.

### 먼저 — 역시 통과하지 못할 두 번째 확인

주소는 고쳤고, 애플리케이션은 재시작되었으며, health 엔드포인트는 `200`을 응답합니다. 모든 게 준비된 것처럼 보입니다. 주문을 하나 만들어 봅시다:

```bash
curl -s -X POST localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"item":"test order"}' -w '\nHTTP %{http_code}\n'
```

**돌아오는 것은 `500`입니다.** 방금 전까지 health가 `200`이었는데도 말입니다.

<details>
<summary><b>답과, 이 오류보다 더 넓은 교훈</b></summary>

이 애플리케이션의 health check는 데이터베이스로의 **연결이 되었다는 사실**만 보기 때문입니다: 연결이 열렸고, 서버가 응답했으니 — 그러면 "살아 있다"는 것입니다. 필요한 테이블이 안에 있는지는 확인하지 않습니다.

그런데 테이블이 없습니다. 카탈로그에서 Postgres를 주문했을 때 여러분에게 주어진 것은 **빈 서버**입니다: `orders` 데이터베이스와 `orders` 사용자가 만들어져 있고, 그게 전부입니다. 예전 머신에는 테이블이 있었습니다 — 오래전 첫 실행 때 애플리케이션이 한 번 만들었고, 여러 해가 지나는 동안 모두가 그것을 잊어버렸습니다.

덤으로, 여러분은 방금 초록색 health check가 얼마만큼의 값어치인지도 보았습니다. 그것은 "데이터베이스까지 연결이 닿았다"고 말할 뿐, "나는 동작하고 있다"고 말하지 않습니다. 실제 프로젝트에서는 이런 확인 위에 모니터링을 쌓기 쉬운데, 그러면 사용자가 주문을 단 하나도 넣지 못하는 동안에도 모든 것을 신나게 초록색으로 보여 줄 것입니다.

</details>

**우리가 할 일.** 우리는 애플리케이션을 옮기는 것이지 그 데이터를 옮기는 것이 아니므로, 테이블은 새로 만들어야 합니다. 이것은 SQL 명령 목록이 담긴 파일 하나로 한 번만 하면 됩니다. 이런 파일을 **스키마**라고 부릅니다 — 저장소가 어떻게 구성되어 있는지를 기술합니다: 어떤 테이블이 있고, 그 안에 어떤 필드가 있으며, 그 타입은 무엇인지.

<details>
<summary><b>더 자세히: orders-schema.sql 안에 무엇이 있는가</b></summary>

파일은 저장소의 `scripts/orders-schema.sql`입니다. 안에는 딱 두 개의 명령이 들어 있습니다.

**첫 번째는 orders 테이블을 만듭니다:**

```sql
CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
```

필드 하나하나:

- `id BIGSERIAL PRIMARY KEY` — 주문 번호. `BIGSERIAL`은 "데이터베이스가 다음 번호를 순서대로 알아서 발급한다"는 뜻이고, `PRIMARY KEY`는 "고유하며 이것으로 행을 찾는다"는 뜻입니다.
- `item` — 무엇을 주문했는지. `NOT NULL` — 품목 없는 주문은 의미가 없으므로, 데이터베이스는 그런 행을 받지 않습니다.
- `status` — 주문의 상태, 기본값은 `NEW`. 메시지가 Kafka를 통과하면 `PROCESSED`로 바뀝니다.
- `created_by` / `processed_by` — 누가 만들었고 누가 처리했는지. 애플리케이션이 바로 이곳에 `kafka`를 쓰며, 스텝 9에서 큐가 실제로 동작한다는 것을 보여 주는 것이 바로 이 필드입니다.
- `created_at` / `processed_at` — 언제. `TIMESTAMPTZ` — 시간대가 포함된 타임스탬프.
- `IF NOT EXISTS` — "테이블이 이미 있으면 아무것도 하지 말고 불평하지도 말라". 덕분에 이 파일은 아무것도 깨뜨리지 않고 다시 적용할 수 있습니다.

**두 번째는 이력 한 행을 추가합니다:**

```sql
INSERT INTO orders (...) SELECT '12x rack rails', 'PROCESSED', ...
WHERE NOT EXISTS (SELECT 1 FROM orders);
```

이것은 겉치레입니다: 스텝 9에서 주문 목록이 비어 있지 않도록 하는 것이죠. `WHERE NOT EXISTS`는 "테이블이 비어 있을 때만 삽입하라"는 뜻이며 — 다시 실행해도 중복을 만들지 않습니다.

**파일에 일부러 빠져 있는 것:** `CREATE DATABASE`도, `CREATE USER`도 없습니다. 데이터베이스와 역할 둘 다 스텝 5에서 Postgres를 주문했을 때 Cozystack 카탈로그가 이미 만들었습니다. 이것이 바로 매니지드 서비스의 핵심입니다: 반복적인 잡무는 자신이 떠맡고, 여러분에게 남는 것은 여러분 자신의 스키마뿐입니다.

</details>

> ⚠️ **파일 주석의 불일치.** `orders-schema.sql`의 헤더에는 먼저 슈퍼유저로 `GRANT CREATE,USAGE ON SCHEMA public`을 해야 한다고 적혀 있습니다. **이것은 낡은 내용이니, 하지 마세요** — `orders` 역할은 데이터베이스와 스키마를 소유한 `orders_admin`에 속하므로, 이미 권한을 가지고 있습니다. 확인되었습니다. 파일의 주석은 우리가 고칠 것입니다.
