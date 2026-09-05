// 랩 6 · 나만의 프라이빗 이미지 레지스트리. 「출입증」 서비스, 학습용 버전.
//
// 이 프로그램이 하는 일. 웹 서버를 띄우고 두 개의 주소에 응답한다.
// /healthz 주소는 짧은 「ok」를 돌려준다: 이를 통해 클러스터는 복제본이 살아 있고
// 트래픽을 받을 준비가 되었음을 파악한다. / 주소는 JSON 형식의 작은 응답(「필드: 값」
// 형태의 텍스트)을 돌려주는데, 여기에는 어느 복제본이 어느 노드에서 요청을 처리했는지가
// 나열된다. 그 이상은 없다: 데이터베이스도, 디스크도, 상태도 없다. 그렇게 설계된 것이다 — 이 랩에서
// 흥미로운 것은 코드가 아니라, 그 코드가 클러스터로 들어가는 경로다:
// 소스 -> 이미지 -> 나만의 레지스트리 -> 클러스터.
//
// 이 Go 파일을 읽을 줄 알 필요는 없고, 여기서 무슨 일이 일어나는지만 이해하면 된다;
// 아래 주석들은 여러분이 Go를 처음 본다는 전제로 작성되었다.
//
// 외부 의존성은 없다: 컴파일러와 함께 오는 표준 라이브러리만 사용한다.
// 그래서 빌드는 라이브러리를 받으러 인터넷에 나가지 않으며, 외부 접속이 막힌 곳에서도
// 이미지를 빌드할 수 있다 — 바로 여기서 이 랩 전체가 시작된다.
//
// 직접 빌드하지 않고, 옆에 있는 Dockerfile을 통해 다음 명령으로 빌드한다
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main — Go에서 (라이브러리와 달리) 실행할 수 있는 프로그램을 이렇게 표시한다.
// 실행 시 진입점은 파일 맨 아래의 main 함수다.
package main

// 표준 라이브러리에서 무엇을 가져오는가:
//   encoding/json — 응답을 JSON 형식으로 조립한다
//   log           — 메시지를 쓴다; 컨테이너 안에서는 표준 출력으로 나가고,
//                   거기서 kubectl logs가 가져간다. 안에는 로그 파일이 없고,
//                   만들 필요도 없다 — 이것이 컨테이너에서는 정상이다
//   net/http      — 웹 서버 자체
//   os            — 환경 변수를 읽는다
//   time          — 응답의 타임스탬프와 서버 타임아웃
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// 응답의 형태: 애플리케이션이 자신에 대해 보고하는 필드들의 모음. 거의 전부 —
// 애플리케이션이 클러스터로부터 알게 되는 것들이다: 우리가 계산하거나 추측하지 않고, 클러스터가
// 직접 환경 변수에 넣어 준다(passes.yaml의 env 블록과 downward API 참고).
//
// 오른쪽 역따옴표 안의 텍스트는 완성된 JSON에서의 필드 이름이다. 그것이 없으면 필드는
// 응답에 namespace가 아니라 Namespace로 나갈 것이다; check.sh의 검사는 소문자 「pod」를 찾는다.
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// 환경 변수를 읽고, 없거나 비어 있으면 — 대체 값을 돌려준다. 프로그램을
// 클러스터 밖에서도 설정 하나 없이 실행할 수 있게 하기 위해 필요하다: 죽지 않고,
// 응답에 정직하게 「알 수 없음」라고 쓴다.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// 진입점: 이 함수에서 프로그램의 동작이 시작된다.
func main() {
	// 어느 포트에서 수신할지. 포트는 이미지를 다시 빌드하지 않고 PORT 변수로 재정의할 수
	// 있지만, 기본값은 8080이다 — passes.yaml(containerPort)과
	// Dockerfile(EXPOSE)에 있는 것과 같은 숫자다. 어긋나면 — Service가 닫힌 문을 두드리게 된다.
	port := env("PORT", "8080")

	// 라우팅 테이블: 어느 주소를 어느 핸들러가 처리하는가.
	mux := http.NewServeMux()

	// 준비 상태 확인. 클러스터가 여기를 두드리고, 응답을 받기 전까지는
	// 복제본으로 트래픽을 보내지 않는다. 항상 그리고 빠르게, 아무것도 확인하지 않고 응답한다:
	// 애플리케이션은 확인할 것이 없다, 데이터베이스도 디스크도 없기 때문이다.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 주요 응답. 바로 그 필드들을 조립해 하나의 JSON으로 돌려준다. 값들은 매 요청마다
	// 읽히므로, 서비스의 두 번째 복제본은 자기 파드 이름으로 응답한다 —
	// 랩에서 이 이름으로 복제본이 실제로 둘임을 볼 수 있다.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "알 수 없음"),
			Node:      env("NODE_NAME", "알 수 없음"),
			Namespace: env("POD_NAMESPACE", "알 수 없음"),
			Registry:  env("IMAGE_REGISTRY", "미지정"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false), 그렇지 않으면 키릴 문자와 < 같은 기호가 \uXXXX로 나가서
		// 응답이 터미널에서 읽을 수 없게 된다.
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("응답을 보내지 못했습니다: %v", err)
		}
	})

	// 서버 설정. ReadHeaderTimeout — 연결을 끊기 전에 요청 헤더를 얼마나 기다릴지.
	// 5초는 속도를 위한 것이 아니다: 이 타임아웃이 없으면
	// 열린 채 버려진 연결이 컨테이너의 메모리를 다 먹어치울 때까지 쌓이고,
	// 메모리는 매니페스트의 리밋으로 제한되어 있다.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// kubectl logs에서 여러분이 처음 보게 될 것. 이 줄은 「애플리케이션이 시작되지 않았다」와
	// 「시작은 됐지만 응답하지 않는다」를 구분하기 위해 필요하다 — 이 둘은 서로 다른 진단이다.
	log.Printf("passes-api %s가 %s 포트에서 수신 중, 파드 %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "알 수 없음"))
	// 서버를 실행하고 멈춰질 때까지 동작한다. 포트가 점유되었거나 서버가
	// 죽으면 — 원인을 쓰고 오류와 함께 종료한다. 클러스터는 종료된 프로세스를 보고
	// 복제본을 다시 띄운다; 프로그램 안에서 재시작을 고칠 필요는 없다.
	log.Fatal(srv.ListenAndServe())
}
