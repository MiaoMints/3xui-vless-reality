# 3x-ui VLESS REALITY

在已安装 3x-ui 的 VPS 上一键创建 **VLESS + TCP + REALITY** 入站，并打印可导入链接。

节点名自己指定，端口、UUID、密钥、ShortId 每次随机。

## 用法

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MiaoMints/3xui-vless-reality/main/create-vless-reality.sh) "日本 Akilecloud 1000Mbps"
```

只预览、不写入面板：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MiaoMints/3xui-vless-reality/main/create-vless-reality.sh) "日本 Akilecloud 1000Mbps" --dry-run
```

指定用户邮箱：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MiaoMints/3xui-vless-reality/main/create-vless-reality.sh) "日本 Akilecloud 1000Mbps" --email test
```

最后一行 `vless://...` 拿去客户端导入即可。

## 说明

- 需要已安装 3x-ui，并在 VPS 上以 root 运行
- 协议固定为 VLESS + TCP + REALITY，`encryption=none`，默认不开 Vision（兼容性更好）
- 自动读取 `/etc/x-ui/install-result.env` 或 `x-ui setting -getApiToken`
