# 实验 7 · 「通行证」服务镜像的构建配方，版本 v2。
#
# Dockerfile 是一系列步骤，把源代码变成镜像：一个不可变的文件系统
# 快照，连同启动命令一起打包。最贴近你们熟悉的类比就是
# 虚拟机模板，但它不是用鼠标搭出来的，而是用这段文本，它存放
# 在镜像仓库里，并用标签来做版本管理。
#
# 它是在虚拟机上构建的，而不是在集群里（见 README 里的构建步骤）：
#   docker build --platform linux/amd64 -t <你的-harbor>/passes/passes-api:v2 app/
#   docker push  <你的-harbor>/passes/passes-api:v2
#
# 在使用 Apple Silicon 的 Mac 上，--platform linux/amd64 是必需的：没有它，镜像会
# 构建成 ARM 版，推送时不会有一句抱怨，却会在集群里以「exec format error」崩溃。
#
# 两阶段构建。
#
# 第一阶段是构建阶段：这里需要整个 Go 编译器，大约 350 MB。
# 第二阶段是要交付到集群的东西：只有构建好的二进制文件才会进去。
# 这样最终镜像大约只有 10 MB 而不是 350，而且里面既没有
# 编译器，也没有源代码，更没有包管理器——也就是说，即便有人真的
# 进到容器里，也没有任何东西可用。

# FROM——我们从哪个现成的镜像开始。这里我们采用基于 Alpine、带 Go
# 编译器的官方镜像。AS build 给这一阶段取了个名字，好让第二阶段能从中取回
# 结果。版本是被固定的（1.23），而不是 latest：否则明天用同一份
# 源代码构建，可能会得到不同的二进制文件。
FROM golang:1.23-alpine AS build
# WORKDIR——镜像内部的工作目录。后续所有命令都在其中执行。
WORKDIR /src
# COPY 把虚拟机上的文件放进镜像内部。分两行而不是一行：go.mod 变动
# 很少，main.go 很频繁，而 docker 会分别缓存每一步。只动了 main.go——
# go.mod 那一步就会从缓存中取用。
COPY go.mod ./
COPY main.go ./
# RUN——在构建过程中直接执行命令；其结果会留在镜像里。
# CGO_ENABLED=0——静态编译，不依赖系统库。
# 没有这一项，二进制文件会需要 glibc，而最终镜像里不会有它。
# -trimpath 把你虚拟机上的路径从二进制文件中剥除，-ldflags="-s -w" 丢弃
# 调试信息——镜像更小，你的文件夹名也不会泄漏到日志里。
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# 第二个 FROM 从一张白纸重新开始镜像。构建阶段里的一切
# 在此处都被丢弃，只有我们用下一条 COPY --from=build 命令显式
# 复制的东西，才会进入最终镜像。
FROM alpine:3.21
# 应用不以 root 身份运行。在正确配置的集群里，以 root 运行的 Pod
# 根本不会被放行，这不是吹毛求疵，而是标准的安全要求。
RUN adduser -D -u 10001 app
# 唯一从构建阶段迁移过来的，是一个文件：构建好的二进制文件。
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER——以谁的身份运行进程。这里给的是编号，而不是名字：kubernetes 在
# 清单里检查的正是这个编号（runAsNonRoot 看的是 uid），两者必须一致。
USER 10001
# EXPOSE——一个「内部监听此端口」的标注。它不打开也不转发任何东西，
# 它是给将来编写清单的人看的文档。
EXPOSE 8080
# ENTRYPOINT——容器启动时运行什么。这里只有一个进程，而且它是
# 主进程：它结束容器就结束，集群会拉起一个新副本。
ENTRYPOINT ["/usr/local/bin/passes-api"]
