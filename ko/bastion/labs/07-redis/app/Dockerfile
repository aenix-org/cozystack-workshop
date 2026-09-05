# 랩 7 · "출입증(Passes)" 서비스 이미지 빌드 레시피, 버전 v2.
#
# Dockerfile은 소스 코드를 이미지로 바꾸는 단계들의 목록입니다: 실행 명령과 함께
# 파일시스템의 불변 스냅샷이죠. 가장 익숙한 비유는 가상 머신 템플릿이지만, 마우스가
# 아니라 바로 이 텍스트로 만들어지며, 레지스트리에 저장되고 태그로 버전이 관리됩니다.
#
# 이것은 클러스터가 아니라 VM에서 빌드됩니다(README의 빌드 단계 참고):
#   docker build --platform linux/amd64 -t <여러분의-harbor>/passes/passes-api:v2 app/
#   docker push  <여러분의-harbor>/passes/passes-api:v2
#
# --platform linux/amd64은 Apple Silicon Mac에서 필수입니다: 이것 없이는 이미지가
# ARM용으로 빌드되어, 아무 불평 없이 push되고, 클러스터에서 "exec format error"로 죽습니다.
#
# 2단계 빌드.
#
# 첫 번째 단계는 빌드 단계입니다: 여기서는 전체 Go 컴파일러가 필요하며, 약 350 MB입니다.
# 두 번째 단계는 클러스터로 배포되는 것입니다: 완성된 바이너리만 여기에 들어갑니다.
# 이렇게 하면 최종 이미지가 350 대신 약 10 MB가 되고, 그 안에는 컴파일러도,
# 소스도, 패키지 매니저도 없습니다 — 즉 컨테이너에 어떻게든 침입한 자가
# 사용할 수 있는 것이 아무것도 없습니다.

# FROM — 어떤 기성 이미지에서 시작할지. 여기서는 Alpine 기반의 Go 컴파일러가 담긴
# 공식 이미지를 가져옵니다. AS build는 이 단계에 이름을 부여하여 두 번째 단계가 그
# 결과를 가져올 수 있게 합니다. 버전은 latest가 아니라 고정되어 있습니다(1.23): 그렇지
# 않으면 같은 소스의 내일 빌드가 다른 바이너리를 만들어낼 수 있습니다.
FROM golang:1.23-alpine AS build
# WORKDIR — 이미지 내부의 작업 폴더. 이후의 모든 명령은 이 안에서 실행됩니다.
WORKDIR /src
# COPY는 VM의 파일을 이미지 안으로 넣습니다. 한 줄이 아니라 두 줄로: go.mod는 드물게,
# main.go는 자주 바뀌며, docker는 각 단계를 개별적으로 캐시합니다. main.go만 건드리면 —
# go.mod 단계는 캐시에서 가져옵니다.
COPY go.mod ./
COPY main.go ./
# RUN — 빌드 도중에 바로 명령을 실행; 그 결과는 이미지에 남습니다.
# CGO_ENABLED=0 — 시스템 라이브러리에 대한 의존 없이 정적으로 빌드.
# 이것 없이는 바이너리가 glibc를 요구하는데, 최종 이미지에는 그것이 없습니다.
# -trimpath는 바이너리에서 VM의 경로를 제거하고, -ldflags="-s -w"는 디버그
# 정보를 버립니다 — 이미지가 더 작아지고, 로그에 폴더 이름이 새어 나가지 않습니다.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# 두 번째 FROM은 백지 상태에서 이미지를 처음부터 다시 시작합니다. build 단계에 있던
# 모든 것은 이 지점에서 버려지고, 다음 COPY --from=build 명령으로 우리가 명시적으로
# 복사하는 것만 최종 이미지에 들어갑니다.
FROM alpine:3.21
# 애플리케이션은 root가 아닌 사용자로 실행됩니다. 올바르게 구성된 클러스터에서는 root로
# 실행되는 파드가 아예 허용되지 않으며, 이것은 트집이 아니라 표준 보안 요구사항입니다.
RUN adduser -D -u 10001 app
# 빌드 단계에서 넘어오는 유일한 것은 파일 하나입니다: 완성된 바이너리.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER — 어떤 사용자로 프로세스를 실행할지. 이름이 아니라 번호가 지정되어 있습니다:
# kubernetes는 매니페스트에서 바로 그 번호를 확인하며(runAsNonRoot는 uid를 봅니다),
# 둘은 일치해야 합니다.
USER 10001
# EXPOSE — "내부에서 이 포트를 수신한다"는 표시. 아무것도 열거나 포워딩하지 않으며,
# 매니페스트를 작성할 사람을 위한 문서입니다.
EXPOSE 8080
# ENTRYPOINT — 컨테이너가 시작될 때 실행되는 것. 여기 프로세스는 하나이고 그것이
# 주된 것입니다: 그것이 끝나면 컨테이너도 끝나고, 클러스터가 새 복제본을 띄웁니다.
ENTRYPOINT ["/usr/local/bin/passes-api"]
