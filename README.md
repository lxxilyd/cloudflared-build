# cloudflared-build

cloudflared 官方只发 linux、darwin、windows 的包，BSD 上跑不起来。这个仓库补的就是这一块：
每次上游发版，把源码拉下来、打几个补丁、交叉编译出 FreeBSD / OpenBSD / NetBSD 的二进制。

仓库里不放源码，只放「怎么构建」——一个 `build.sh`、一个补丁目录、一条流水线。

## 为什么这么干

把上游源码存进一个分支里当然也能用，但维护起来很累：上游动一下就要同步、要解冲突，
时间一长自己也说不清仓库里那份和上游到底差在哪。

我们真正想要的其实就一句话：**某个 tag 的源码，加上几个改动**。
那不如构建时再拼——源码永远当场下载，补丁永远当场打，仓库里不留下任何会过期的副本。

## 补丁怎么打，怎么确认只打在该改的地方

`build.sh` 会把同一个 tarball 下载两遍：

- 一份 `pristine/` 一个字都不动，留着当参照；
- 一份 `patched/` 用来打补丁。

打完补丁，把两份树逐文件比一遍（新增、修改、删除都算），得到的文件清单必须和
`custom/bsd/manifest.txt` **完全一致**。多一个、少一个，脚本就停下，编译根本不会开始。

这一步不是形式主义。补丁脚本改错了路径、上游把某个文件挪走了、顺手多写了一个文件——
这些情况都会在比对里露出来，而不是等到某个版本发布以后才有人发现"这个二进制到底改了啥"。

补丁目前只碰 6 个文件：

| 文件 | 做了什么 |
| --- | --- |
| `Makefile` | 加 2 行，让 `make` 认识 netbsd（上游只留了 freebsd / openbsd） |
| `diagnostic/system_collector_unix.go` | 新文件，BSD 的系统信息采集（`cloudflared tunnel diag` 要用） |
| `cmd/cloudflared/service_token_bsd.go` | 新文件，补上上游只给 linux/darwin/windows 写的 `createTokenFile` |
| `diagnostic/network/collector_unix.go` | 只改 `//go:build` 一行 |
| `diagnostic/network/collector_unix_test.go` | 同上 |
| `ingress/icmp_posix.go` | 同上 |

除此之外一行都不动。

## 自己跑一下

```bash
./build.sh                      # 上游最新 tag，编本机平台
./build.sh 2026.10.3            # 指定版本
GOOS=freebsd GOARCH=arm64 ./build.sh 2026.10.3
```

产物在 `output/cloudflared-<os>-<arch>.tar.gz`，windows 里面是 `.exe`。

调试的时候加 `WORK_DIR=/tmp/work` 可以保留中间目录，加 `--snapshot /tmp/tree` 只导出打完补丁的树、不编译。

一个细节：tarball 里没有 `.git`，Makefile 靠 `git describe` 取版本号会拿到空值，
所以这里显式传了 `make VERSION=<tag> cloudflared`。

## 发布

`.github/workflows/release.yml` 每天 06:00 UTC 检查一次上游，有新版本才构建，也可以手动触发。

11 个目标全部在 ubuntu 上交叉编译（`CGO_ENABLED=0`），不启任何 VM，所以没有
"VM 里缺个目录"、"镜像版本下架了"这类问题。两分多钟能跑完。

11 个目标全部成功后，才由一个单独的 `publish` job 一次性创建 release、上传所有文件。
少一条腿就什么都不发——宁可没有，也不要发一个只有一半产物的版本。

## 想看代码

每次构建还会把**打完补丁的那棵树**推到 `release/<tag>` 分支（orphan 分支），
方便直接在网页上翻代码、搜函数：

```bash
git fetch origin 'refs/heads/release/*:refs/remotes/origin/release/*'
git diff <上游tag>..origin/release/2026.10.3 --stat    # 应该只有上面那 6 个文件
```

它和产物来自同一次打补丁的结果，所以看到的代码就是编译的代码。

分支里少了 `.github/`：上游 tarball 自带 `.github/workflows/`，把这类文件推到仓库需要
token 具备 `workflows` 权限。一份只读镜像不值得为上游的 CI 配置开这个权限，所以推之前删掉了。

只想本地看一眼、不建分支的话：

```bash
./build.sh --snapshot /tmp/tree 2026.10.3
diff -r <上游解压目录> /tmp/tree
```

## 上游变了怎么办

- **挪了 / 删了补丁依赖的文件**：`apply.sh` 会直接报错，不会产出一个编译不过的版本。
- **确实需要多改一个文件**：`apply.sh` 和 `manifest.txt` 一起改，后者是那份清单。
- **抬高了 Go 版本要求**：改 `release.yml` 里的 `GO_VERSION`。版本不够时 `build.sh` 会先提醒一句，
  真正不满足的话 go 自己会报错，看日志能直接看到要什么版本。
