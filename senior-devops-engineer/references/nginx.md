# Nginx 反向代理模板

```nginx
upstream backend {
    zone backend_zone 64k;
    server 10.0.1.10:8080 weight=5 max_fails=3 fail_timeout=30s;
    server 10.0.1.11:8080 weight=5 max_fails=3 fail_timeout=30s;
    keepalive 32;                          # 与后端复用连接，需下面的 Connection ""
}
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;   # 10m ≈ 16 万个 IP 状态

server {
    listen 443 ssl;
    http2 on;                              # nginx 1.25.1+；listen 上的 http2 参数已弃用（实测打 deprecated 警告）
    server_name app.example.com;

    ssl_certificate     /etc/nginx/ssl/app.crt;   # 含中间证书的完整链
    ssl_certificate_key /etc/nginx/ssl/app.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;         # 列表已全是 AEAD+PFS，让客户端按硬件选；HIGH:!aNULL:!MD5 含 CBC 与非 PFS 的 RSA 套件，别用
    ssl_session_cache   shared:SSL:10m;    # 1m ≈ 4000 会话；省一次完整握手
    ssl_session_timeout 1d;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/nginx/ssl/chain.pem;
    resolver 223.5.5.5 valid=300s;         # stapling 要解析 OCSP responder 域名

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    location /api/ {
        # location 里一旦出现 add_header，server 层的 add_header 全部不再继承，需重复声明
        limit_req zone=api_limit burst=20 nodelay;
        limit_req_status 429;
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";    # 清掉 close，才能复用 upstream keepalive
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout    30s;         # 两次读之间的间隔，不是总时长
        proxy_next_upstream error timeout http_502 http_503;   # 不含 http_500：非幂等请求重试会重复执行
        proxy_next_upstream_tries 2;
    }
}
```
