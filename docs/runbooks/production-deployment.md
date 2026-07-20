# 生产部署运行手册

本手册部署 H5、API、PostgreSQL、Redis 和私有 MinIO 到单台 Ubuntu 主机。Caddy 对 `shot.socialdog.cn` 和 `shotapi.socialdog.cn` 自动申请和续签 HTTPS 证书。

## 前置条件

- 两个域名的可用解析均指向服务器公网 IP。
- 云安全组及主机防火墙应开放 TCP `80`、`443`；不向公网开放 PostgreSQL、Redis、MinIO 或 API 容器端口。
- 服务器已安装 Docker Engine 和 Docker Compose 插件。
- Ark 凭据只保存在服务器 `infra/deployment/.env.production` 中，不能提交到 Git。

## 配置

在仓库根目录执行：

```bash
cp infra/deployment/.env.production.example infra/deployment/.env.production
chmod 600 infra/deployment/.env.production
```

将所有 `replace-with-*` 值替换为高熵随机值，并填入 `ARK_API_KEY`、`ACME_EMAIL`。生产环境保持 `MOCK_AI_ENABLED=false`；未配置 Ark 时，自定义媒体与场景适配会诚实返回不可用，不会伪装为实时结果。

## 发布与验证

```bash
docker compose -f infra/deployment/docker-compose.production.yml --env-file infra/deployment/.env.production up -d --build
curl --fail https://shotapi.socialdog.cn/health
curl --fail https://shot.socialdog.cn/
```

查看运行状态与日志：

```bash
docker compose -f infra/deployment/docker-compose.production.yml --env-file infra/deployment/.env.production ps
docker compose -f infra/deployment/docker-compose.production.yml --env-file infra/deployment/.env.production logs -f caddy api
```

首次部署还应在真实 iPhone 上完成二维码接力、媒体上传、两轮拍摄和断网恢复检查。HTTPS 可用不等同于真机验收完成。
