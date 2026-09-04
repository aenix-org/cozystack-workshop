// 랩 6 · 자체 프라이빗 이미지 레지스트리. 「출입증」 서비스, 학습용 버전.
//
// 이 프로그램이 하는 일. 웹 서버를 띄우고 두 개의 경로에 응답합니다.
// /healthz 경로는 짧은 「ok」를 반환합니다. 이를 통해 클러스터는 복제본이 살아 있고
// 트래픽을 받을 준비가 되었음을 파악합니다. / 경로는 JSON 형식의 작은 응답(「필드: 값」
// 형태의 텍스트)을 반환하며, 어떤 복제본이 어떤 노드에서 요청을 처리했는지
// 나열합니다. 그 밖에는 아무것도 없습니다. 데이터베이스도, 디스크도, 상태도 없습니다. 의도된 것입니다 — 이 랩에서
// 흥미로운 것은 코드가 아니라 코드가 클러스터로 들어가는 경로입니다:
// 소스 -> 이미지 -> 자체 레지스트리 -> 클러스터.
//
// 이 Go 파일을 읽을 줄 알 필요는 없으며, 여기서 무슨 일이 일어나는지 이해하면 충분합니다.
// 아래 주석은 여러분이 Go를 처음 본다는 전제로 작성되었습니다.
//
// 외부 의존성은 없습니다. 컴파일러와 함께 제공되는 표준 라이브러리만
// 사용합니다. 그래서 빌드는 라이브러리를 받으러 인터넷에 나가지 않으며,
// 외부로 나가는 통로가 막힌 곳에서도 이미지를 빌드할 수 있습니다 — 바로
// 여기서부터 이 랩 전체가 시작됩니다.
//
// 직접 빌드하지 않고 옆에 있는 Dockerfile을 통해 다음 명령으로 빌드합니다
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main — Go에서 (라이브러리와 달리) 실행할 수 있는 프로그램임을 표시하는 방법입니다.
// 실행 시 진입점은 파일 맨 아래에 있는 main 함수입니다.
package main

// 표준 라이브러리에서 가져오는 것:
//   encoding/json — 응답을 JSON 형식으로 조립
//   log           — 메시지 작성; 컨테이너에서는 표준 출력으로 나가며,
//                   거기서 kubectl logs가 가져갑니다. 내부에 로그 파일은 없으며,
//                   만들 필요도 없습니다 — 컨테이너에서는 정상입니다
//   net/http      — 웹 서버 그 자체
//   os            — 환경 변수를 읽기
//   time          — 응답의 타임스탬프와 서버 타임아웃
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// 응답의 형태: 애플리케이션이 자신에 대해 알리는 필드 집합. 거의 모두가
// 애플리케이션이 클러스터로부터 알아내는 것입니다. 우리가 계산하거나 추측하지 않으며, 클러스터가
// 직접 환경 변수에 넣습니다 (passes.yaml의 env 블록과 downward API 참조).
//
// 오른쪽 백틱 안의 텍스트는 완성된 JSON에서의 필드 이름입니다. 그것이 없으면 필드가
// 응답에 namespace가 아니라 Namespace로 들어갑니다. check.sh의 검사는 소문자 「pod」를 찾습니다.
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// 환경 변수를 읽고, 없거나 비어 있으면 — 예비 값을
// 반환합니다. 프로그램을 클러스터 밖에서도, 설정 하나 없이 실행할 수 있게 하기 위해 필요합니다.
// 프로그램은 죽지 않고 응답에 정직하게 「알 수 없음」이라고 씁니다.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// 진입점: 이 함수에서 프로그램의 작업이 시작됩니다.
func main() {
	// 어느 포트에서 수신할지. 포트는 이미지를 다시 빌드하지 않고 PORT 변수로 재정의할 수
	// 있지만, 기본값은 8080입니다 — passes.yaml(containerPort)과
	// Dockerfile(EXPOSE)에 있는 것과 같은 숫자입니다. 어긋나면 — Service는 닫힌 문을 두드리게 됩니다.
	port := env("PORT", "8080")

	// 라우팅 테이블: 어떤 경로를 어떤 핸들러가 처리하는지.
	mux := http.NewServeMux()

	// 준비 상태 검사. 클러스터는 여기를 두드리며, 응답을 받을 때까지
	// 복제본으로 트래픽을 보내지 않습니다. 아무것도 검사하지 않고 항상 빠르게 응답합니다.
	// 애플리케이션은 검사할 것이 없습니다. 데이터베이스도 디스크도 없습니다.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 주 응답. 바로 그 필드들을 조립하여 하나의 JSON으로 반환합니다. 값은 요청마다
	// 읽히므로, 서비스의 두 번째 복제본은 자신의 파드 이름으로 응답합니다 —
	// 이 이름으로 랩에서 복제본이 실제로 두 개임을 확인할 수 있습니다.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "неизвестно"),
			Node:      env("NODE_NAME", "неизвестно"),
			Namespace: env("POD_NAMESPACE", "неизвестно"),
			Registry:  env("IMAGE_REGISTRY", "не указан"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false), 그렇지 않으면 키릴 문자와 < 같은 기호가 \uXXXX로 바뀌어
		// 응답이 터미널에서 읽을 수 없게 됩니다.
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("не удалось отдать ответ: %v", err)
		}
	})

	// 서버 설정. ReadHeaderTimeout — 연결을 끊기 전에 요청 헤더를
	// 얼마나 기다릴지. 5초는 속도를 위한 것이 아닙니다. 이 타임아웃이 없으면
	// 열린 채 버려진 연결이 컨테이너의 메모리를 다 먹을 때까지 쌓이며,
	// 메모리는 매니페스트의 limit으로 제한되어 있습니다.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// kubectl logs에서 여러분이 처음 보게 될 것. 이 줄은 「애플리케이션이
	// 시작되지 않았다」와 「시작되었지만 응답하지 않는다」를 구분하기 위해 필요합니다 — 서로 다른 진단입니다.
	log.Printf("passes-api %s слушает порт %s, под %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "неизвестно"))
	// 서버를 시작하고 중지될 때까지 동작합니다. 포트가 사용 중이거나 서버가
	// 죽으면 — 이유를 기록하고 오류와 함께 종료합니다. 클러스터는 종료된 프로세스를 보고
	// 복제본을 다시 띄웁니다. 프로그램 내부에서 재시작을 처리할 필요는 없습니다.
	log.Fatal(srv.ListenAndServe())
}
