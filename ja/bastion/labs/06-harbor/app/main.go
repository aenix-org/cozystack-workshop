// ラボ6 · 自分専用のプライベートイメージレジストリ。「パス（Pass）」サービス、学習用バージョン。
//
// このプログラムが行うこと。Webサーバーを起動し、2つのパスに応答する。
// /healthz パスは短い「ok」を返す。これにより、クラスターはレプリカが生きていて
// トラフィックを受け取る準備ができていることを知る。/ パスはJSON形式の小さな応答（「フィールド: 値」
// という形式のテキスト）を返し、どのレプリカがどのノード上でリクエストを処理したかを列挙する。
// それ以外は何もない。データベースもディスクも状態もない。これは意図的なものだ。このラボで
// 重要なのはコードそのものではなく、それがクラスターに届くまでの経路である。
// ソース -> イメージ -> 自分のレジストリ -> クラスター。
//
// このGoファイルを読める必要はない。ここで何が起きているかを理解できれば十分だ。
// 以下のコメントは、あなたがGoを初めて目にすることを前提に書かれている。
//
// 外部依存はない。使うのはコンパイラと一緒に同梱される標準ライブラリだけだ。
// そのためビルドはライブラリを取りにインターネットへ行かないので、外向きの
// アクセスが閉じられている場所でもイメージをビルドできる。まさにそこから
// ラボ全体が始まる。
//
// 直接ではなく、隣にあるDockerfileを通して、次のコマンドでビルドされる。
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main — これはGoにおいて、（ライブラリとは対照的に）実行できるプログラムを
// 示す方法だ。実行時のエントリーポイントは、ファイル最下部にあるmain関数である。
package main

// 標準ライブラリから取り込むもの:
//   encoding/json — 応答をJSON形式で組み立てる
//   log           — メッセージを書き出す。コンテナ内ではそれらは標準出力へ送られ、
//                   そこから kubectl logs が拾い上げる。内部にログファイルはなく、
//                   作る必要もない。これはコンテナでは普通のことだ
//   net/http      — Webサーバー本体
//   os            — 環境変数を読む
//   time          — 応答内のタイムスタンプとサーバーのタイムアウト
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// 応答の形: アプリケーションが自分自身について報告するフィールドの集合。そのほとんどは
// アプリケーションがクラスターから知る値だ。私たちはそれらを計算も推測もしない。クラスター
// 自身がそれらを環境変数に入れる（passes.yaml の env ブロックと downward API を参照）。
//
// 右側のバッククォート内のテキストは、完成したJSONでのフィールド名だ。これがないとフィールドは
// namespace ではなく Namespace として応答に入ってしまう。check.sh のチェックは小文字の「pod」を探す。
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// 環境変数を読み、それが存在しないか空の場合は予備の値を返す。これは、プログラムを
// クラスターの外でも、設定を一つもせずに実行できるようにするために必要だ。プログラムは
// 落ちず、正直に応答に「不明」と書く。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// エントリーポイント: プログラムの動作はこの関数から始まる。
func main() {
	// どのポートで待ち受けるか。ポートは PORT 変数で上書きでき、イメージを再ビルドする
	// 必要はない。ただしデフォルトは 8080 で、passes.yaml（containerPort）や
	// Dockerfile（EXPOSE）と同じ数字だ。食い違えば、Service は閉じたドアを叩くことになる。
	port := env("PORT", "8080")

	// ルーティングテーブル: どのパスをどのハンドラーが処理するか。
	mux := http.NewServeMux()

	// レディネスチェック。クラスターはここを叩き、応答を得るまではレプリカに
	// トラフィックを送らない。常に素早く応答し、何も確認しない。
	// アプリケーションには確認するものがない。データベースもディスクもないからだ。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// メインの応答。まさにそれらのフィールドを組み立て、一つのJSONとして返す。値は
	// リクエストごとに読まれるので、サービスの2つ目のレプリカは自分のポッド名で応答する。
	// その名前によって、ラボではレプリカが本当に2つあることが見える。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "不明"),
			Node:      env("NODE_NAME", "不明"),
			Namespace: env("POD_NAMESPACE", "不明"),
			Registry:  env("IMAGE_REGISTRY", "未設定"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false)。そうしないとキリル文字や < のような記号が \uXXXX に
		// なってしまい、応答がターミナルで読めなくなる。
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("応答を返せませんでした: %v", err)
		}
	})

	// サーバーの設定。ReadHeaderTimeout — 接続を切る前に、リクエストヘッダーをどれだけ
	// 待つか。この5秒は速度のためではない。このタイムアウトがないと、開かれたまま
	// 放置された接続が積み上がり、やがてコンテナのメモリを食い尽くす。
	// そしてメモリはマニフェストのリミットで上限が定められている。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// kubectl logs で最初に目にするもの。この行は「アプリケーションが起動しなかった」と
	// 「起動したが応答しない」を区別するために必要だ。これらは別々の診断である。
	log.Printf("passes-api %s がポート %s で待ち受けています、ポッド %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "不明"))
	// サーバーを起動し、止められるまで動作する。ポートが使用中か、サーバーが落ちた
	// 場合は、原因を書き出してエラーで終了する。クラスターは終了したプロセスを見て、
	// レプリカを新たに立ち上げる。再起動をプログラム内部で直す必要はない。
	log.Fatal(srv.ListenAndServe())
}
