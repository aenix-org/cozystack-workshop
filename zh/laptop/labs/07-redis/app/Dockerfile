# 实验 7 · 服务「通行证」镜像的构建配方，版本 v2。
#
# Dockerfile 是一份步骤清单，按它把源码变成镜像：文件系统的不可变
# 快照，连同启动命令一起。你最熟悉的类比就是——
# 虚拟机模板，只不过它不是用鼠标构建的，而是用这段文本，存放
# 在镜像仓库里，并用标签做版本管理。
#
# 它在笔记本上构建，而不是在集群里（见 README 中关于构建的步骤）：
#   docker build --platform linux/amd64 -t <你的-harbor>/passes/passes-api:v2 app/
#   docker push  <你的-harbor>/passes/passes-api:v2
#
# --platform linux/amd64 在使用 Apple Silicon 的 Mac 上是必需的：没有它镜像会被构建
# 成 ARM 版，推送时不会有半点抱怨，却会在集群里以「exec format error」崩溃。
#
# 两阶段构建。
#
# 第一阶段是构建阶段：这里需要整个 Go 编译器，大约 350 MB。
# 第二阶段是要送进集群的东西：只有编译好的二进制文件会进到那里。
# 这样最终镜像大约 10 MB 而不是 350，而且里面既没有
# 编译器，也没有源码，也没有包管理器——也就是说，即便有人
# 真的进到了容器里，也没有什么可供他利用的东西。

# FROM——我们从哪个现成镜像开始。这里取带 Go 编译器的官方镜像，
# 基于 Alpine。AS build 给这个阶段起个名字，以便第二阶段能从中取出
# 结果。版本被固定（1.23），而不是 latest：否则明天对同一份
# 源码的构建可能会产出不同的二进制文件。
FROM golang:1.23-alpine AS build
# WORKDIR——镜像内部的工作目录。接下来所有命令都在其中执行。
WORKDIR /src
# COPY 把文件从笔记本放进镜像里。分成两行而不是一行：go.mod 变
# 得少，main.go 变得勤，而 docker 会分别缓存每一步。只动了 main.go——
# go.mod 那一步就会从缓存里取。
COPY go.mod ./
COPY main.go ./
# RUN——在构建过程中直接执行命令；其结果会留在镜像里。
# CGO_ENABLED=0——静态编译，不绑定系统库。
# 没有它，二进制文件会需要 glibc，而最终镜像里不会有它。
# -trimpath 从二进制文件里去掉你笔记本上的路径，-ldflags="-s -w" 丢弃
# 调试信息——镜像更小，而且日志里不会泄露你的文件夹名字。
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# 第二个 FROM 让镜像从头开始，一张白纸。构建阶段里的一切，
# 在这里都被丢弃，只有我们用下一条
# COPY --from=build 命令明确复制的东西，才会进到最终镜像里。
FROM alpine:3.21
# 应用不以 root 运行。在正确配置的集群里，以 root 运行的 pod
# 根本不会被放行，这不是吹毛求疵，而是标准的安全要求。
RUN adduser -D -u 10001 app
# 从构建阶段迁移过来的唯一东西，就是一个文件：编译好的二进制。
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER——以谁的身份运行进程。给的是编号，而不是名字：kubernetes 检查的
# 正是清单里的编号（runAsNonRoot 看的是 uid），两者必须对得上。
USER 10001
# EXPOSE——一个标注「内部监听这个端口」。它不开放也不转发任何东西，
# 这是给将来编写清单的人看的文档。
EXPOSE 8080
# ENTRYPOINT——容器启动时运行什么。这里只有一个进程，而且它是
# 主进程：它结束，容器就结束，集群会拉起一个新副本。
ENTRYPOINT ["/usr/local/bin/passes-api"]
