# 第三方高画质解析（解锁）协议参考

> 基线：2026-11-08，脚本 v0.0.7，服务器 `http://mxd.indevs.in`，commit `032fd09da`。
> 本文档冻结「已验证可工作」的协议形状，供下次脚本/服务器更新时对齐排查。

## 链路概览

功能移植自「网盘下载助手」油猴脚本（`http://mxd.indevs.in/hd2a/assets/min.baidu.user.js`）。
把 wbi 签名的 B 站播放请求地址 + 账号信息（ui，含完整 Cookie）提交给解析服务器，
由服务器携 Cookie 代为请求并返回可替换的 playurl/playview 响应，解锁会员画质（qn > 80）。

- **脚本分发地址**（自动提取服务器用）：`HttpString.qualityResolverScriptUrl`；
  旧地址存量的自动映射见 `HttpString.qualityResolverLegacyScriptUrls`。
- 从脚本提取服务器地址：正则匹配 `box={home:"http://host:port"`，兜底 `// @homepage`。

## 服务器接口

| 接口 | 用途 | 请求体 |
|---|---|---|
| `POST /api/bzusta` | 注册/校验账号 | `{ui}` |
| `POST /api/bzview2` | UGC 画质解锁（playurl 中继） | `{ui, url}` |
| `POST /api/bzview3` | PGC（番剧/电影）playview 中继 | `{iic, url, ui}` |

- 响应信封 `{code, message, ...}`：`0` 成功；`9` 当日次数上限（投币重置）；
  `1` 连接失败；`2` 通常为转发 B 站失败（message 如 `timeout`/`fail`）。
- ui 共 9 字段（v0.0.7）：`ua, mid, vip, level, money, cookie, csrf, name, face`。
- bzview3 的 `iic`：脚本以原 playview 响应是否含 `AreaLimitPanel`（地区限制）置位，
  true 时服务器走区域代理。app 侧对应「整片锁定 base:null」的整集解析路径。
- 服务器会把 CDN 域名 `mirrorcos` 混淆为 `mirrorcosov`（旧版行为，保留还原逻辑作兜底）。

## bzview3 转发 URL（关键对齐基准）

**必须与 web 播放器实抓请求逐参数一致**，否则服务器报 `fail`。已验证形状（GET、
全部参数在 query、wbi 签名、**无请求体、转发时不带 body 字段**）：

```
https://api.bilibili.com/ogv/player/playview?
  x-bili-locale-json={"c_locale":{"language":"zh-Hans"},"always_translate":false}
  &biz_type=ogv&scene=normal&from_client=BROWSER
  &ep_id=<epid>&season_id=<sid>&cid=<cid>&qn=<qn>
  &fnver=0&fnval=4048&drm_tech_type=2
  &version_name=4.10.10          ← 播放器版本，随播放器更新会变
  &app_id=100&web_location=666.25 ← 字符串
  &x-bili-device-req-json={"platform":"web","device":"pc","spmid":"666.25","mobi_app":"web_cn"}
  &w_rid=<wbi>&wts=<ts>
```

**不要**附带 app 播放参数：`fourk/voice_balance/gaia_source/isGaiaAvoided/dm_*/avid/bvid`
（这些是 videoUrl 自播形状，混入即 fail——2026-11-08 实测踩坑）。

实现：`VideoHttp.buildSignedPlayViewUrl`（video.dart）。

## bzview2 转发 URL

经典 playurl GET 签名地址（`VideoHttp.buildSignedPlayUrl`），提交前剥离 `dm_*` 字段。
UGC 场景脚本仅在非 VIP 且 qn>80 时触发；app 侧用作 PGC 的兜底通道。

## 排查手册（下次失效时）

1. **Toast 已透传完整原因**（`bzview3: msg(code=N)；bzview2: ...`），先看 message。
2. **服务器可达性**：`mxd.indevs.in` 是明文 HTTP，大陆网络间歇性 TCP 超时属正常，
   与服务器故障区分开。无 cookie 哑 ui 探测 bzusta 应秒回，带假 cookie 常挂 ~21s。
3. **决定性对照实验**：浏览器装油猴脚本测同一内容——脚本也失败=服务器端问题，
   等服务端修复；脚本能解锁=app 请求形状漂移，按下一条重新对齐。
4. **重新对齐**：浏览器 F12 → Network 过滤 `playview`（注意 `bzview3` 走
   GM_xmlhttpRequest 从扩展后台发出，页面 Network 看不到）→ 复制播放器实抓的
   完整 query → 与 `buildSignedPlayViewUrl` 逐参数 diff。重点盯 `version_name`、
   `drm_tech_type`、新增/改名参数。
5. 脚本更新（v0.0.8+）时重新逆向：`box={home...}` 提取、ui 字段数、
   bzview3 钩子的转发条件与 payload 字段。
