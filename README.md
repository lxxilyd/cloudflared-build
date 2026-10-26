# cloudflared-build

给 cloudflared 编 BSD（FreeBSD / OpenBSD / NetBSD）二进制。
仓库不存源码：每次构建下载上游 tarball、打补丁、编译。

## 用法

```bash
./build.sh                                   # 上游最新 tag，本机平台
./build.sh 2026.10.3                         # 指定版本
GOOS=freebsd GOARCH=arm64 ./build.sh 2026.10.3
./build.sh --snapshot /tmp/tree 2026.10.3    # 只导出打完补丁的树，不编译
```

产物：`output/cloudflared-<os>-<arch>.tar.gz`（windows 内含 `.exe`）。

## 校验

`build.sh` 下两份 tarball：`pristine/` 保持原样，`patched/` 用来打补丁。打完逐文件比对，
改动清单必须和 `custom/bsd/manifest.txt` 完全一致，多一个少一个都退出。

当前只改 6 个文件：

```
Makefile
cmd/cloudflared/service_token_bsd.go
diagnostic/network/collector_unix.go
diagnostic/network/collector_unix_test.go
diagnostic/system_collector_unix.go
ingress/icmp_posix.go
```

## 发布

`release.yml` 每天 06:00 UTC 检查上游，有新版本才构建；也可以手动触发，`tag` 指定版本、
`force` 强制重建（版本已发布时用）。

11 个目标全部在 ubuntu 交叉编译（`CGO_ENABLED=0`），全部成功后才由 `publish` 创建 release
并上传所有产物。任一目标失败则不发布。

CI 在 GitHub 跑，仓库本体在 Gitea，而 Gitea 的 push mirror 会删掉源端没有的 ref（tag 被删
release 就退回 draft）。所以 `release/<tag>` 分支和 tag 都会回推一份到 Gitea，需要 secret
`GITEA_TOKEN`（Gitea 令牌，`repository` 读写）；没配就跳过，只打一条 warning。

## 分支

发布时会把打完补丁的树推到 `release/<tag>`：单条提交，提交信息带上游 commit sha，
不含上游的 `.github/`（推 workflow 文件需要额外权限）。

## 改补丁

`custom/bsd/apply.sh` 和 `custom/bsd/manifest.txt` 一起改。上游改名或删掉补丁依赖的文件时，
`apply.sh` 会直接报错。上游抬高 Go 版本要求时，改 `release.yml` 里的 `GO_VERSION`。
