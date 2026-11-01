# UIBridge — iOS 版 uiautomator2

给越狱 iPhone 用的 UI 自动化桥。**AI 不需要截图**，直接读一棵结构化元素树，然后按元素索引或坐标操作。

```
AI / 脚本 ──TCP 9700 (NDJSON)──► uibridge daemon
                                   ├── IOHIDEventSystem  → 合成触摸 / 滑动 / 键盘（全系统）
                                   ├── libAccessibility  → AXUIElement 树（iOS ≤ 16）
                                   └── unix socket       → 每个 App 内的 UIBridgeAgent（iOS 17+）
```

对应关系：Android 的 `uiautomator2` 靠 `AccessibilityService` 拿节点树 + `input` 注入事件。
iOS 这里：

| 能力 | Android | 本项目 |
|---|---|---|
| 节点树 | AccessibilityNodeInfo | `AXUIElement`（iOS ≤16）/ App 内 UIKit 视图树（iOS 17+） |
| 点击坐标 | `input tap` | `IOHIDEventCreateDigitizerFingerEvent` |
| 语义点击 | `performAction(CLICK)` | `AXUIElementPerformAction(AXPress)` / `UIControl sendActionsForControlEvents:` |
| 输入文本 | `input text` | `AXValue` / `UITextField.setText:` / HID 键盘 |

---

## 一键安装（给 AI / 自动部署用）

前置：iPhone 已用 **Dopamine** 越狱（rootless `/var/jb`），SSH 可连。
默认 rootless SSH 端口是 `22`（或 `2222`，看你的环境）。

```bash
DEVICE=172.20.2.142          # 改成你的手机 IP
SSH_PORT=22

# 1. 编译（需要 Theos: https://theos.dev）
export THEOS=~/theos
make package FINALPACKAGE=1

# 2. 上传并安装
scp -P $SSH_PORT packages/com.yg.uibridge_0.2.0_iphoneos-arm64.deb root@$DEVICE:/tmp/
ssh -p $SSH_PORT root@$DEVICE \
  '/var/jb/usr/bin/dpkg -i /tmp/com.yg.uibridge_0.2.0_iphoneos-arm64.deb'

# 3. 生效（tweak 需要重启 SpringBoard 才会注入 App）
#    必须用 mobile 身份执行：root 杀掉 SpringBoard 时它不会带着 tweak 注入环境重生
#    mobile 默认密码 alpine（首次登录后请改）
ssh mobile@$DEVICE 'killall -9 SpringBoard'

# 4. 验证
python3 -c "
import sys; sys.path.insert(0,'client'); import uibridge
print(uibridge.Device('$DEVICE').info())
"
```

> **mobile 用户 SSH 登录失败时**（`Permission denied (publickey,password)`）：iOS 的 `sshd`
> 默认 `AuthorizedKeysFile .ssh/authorized_keys`，但 `/var/mobile` 权限是 `drwx--x--x`，
> 公钥登录常被拒。用密码登录即可；若要免密，以 root 执行：
>
> ```bash
> ssh root@$DEVICE 'printf "StrictModes no\n" >> /var/jb/etc/ssh/sshd_config; killall -HUP sshd'
> ```

`postinst` 会自动执行 `launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist`。
手工重启 daemon：

```bash
launchctl bootout   system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist
launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist
tail -f /var/jb/var/log/uibridge.log
```

> **每次重启手机后都要先跑一遍 Dopamine 的 Jailbreak**，daemon 才会被 launchd 拉起来。

### 依赖

- Theos（编译）
- 设备端：Dopamine 越狱 + ellekit 1.2+（Dopamine 自带）
- 编译需要 Xcode / Command Line Tools 的 iPhoneOS SDK；`ldid` 要在 PATH 里（`brew install ldid`）

---

## 用法

### Python（uiautomator2 风格）

```python
import uibridge

d = uibridge.Device("192.168.1.23")          # token="..." 如果 daemon 设了

d.info()                                      # 机型 / iOS / 屏幕 / 前台 App / 诊断
print(d.tree())                               # 缩进渲染的元素树，可直接塞进 LLM prompt

d.dump()                                      # 原始节点列表（JSON 友好）
d(text="设置").click()                        # 选择器
d(role="Button", label="搜索").click()
d(id="search-field").set_text("wifi")

d.click(200, 400)                             # 坐标点击
d.long_click(200, 400, 0.8)
d.swipe(200, 700, 200, 200, 0.3)
d.scroll(-400)                                # 向上滚
d.send_keys("hello")                          # 输入到已聚焦的输入框
d.home()
d.app_switcher()
d.open_app("com.apple.Preferences")
```

### 给 LLM 的典型循环

```python
state = d.tree()
action = llm(state, goal)         # 模型返回 {"tap_index": 12} / {"swipe": [...]}
if "tap_index" in action:
    d.click_element(action["tap_index"])
```

### CLI

```bash
python3 client/uibridge.py --host 192.168.1.23 dump
python3 client/uibridge.py --host 192.168.1.23 find "设置"
python3 client/uibridge.py --host 192.168.1.23 tap 200 400
```

---

## 协议（新行分隔 JSON over TCP 9700）

请求一行，响应一行：

```json
{"id":1,"cmd":"dump","depth":16}
{"id":1,"ok":true,"result":{...}}
{"id":1,"ok":false,"error":"stale index, call dump first"}
```

| cmd | 参数 | 说明 |
|---|---|---|
| `ping` | — | 存活 + AX/HID/agent 状态 |
| `info` | — | 机型、iOS、屏幕、前台 App、完整诊断 |
| `diag` | — | 只返回诊断 |
| `agents` | — | 已连接 App 内的 agent 列表 |
| `symbols` | `needle` | 扫描已加载镜像的导出符号（排查 API 改名用） |
| `screen` | — | 屏幕尺寸（point）与方向 |
| `frontmost` | — | 前台 App 的 `bundleId` / `pid` / `hasAgent` |
| `dump` | `depth`(20) `bundleId` | 元素树 |
| `find` | `text` `role` `limit` | 检索元素 |
| `hit` | `x` `y` | 坐标 → 元素索引 |
| `tap` | `x` `y` | 点击坐标 |
| `tapElement` | `index` `forceTap` | 语义点击，失败回退坐标点击 |
| `longPress` | `x` `y` `duration` | 长按 |
| `swipe` / `drag` | `x1 y1 x2 y2 duration` | 滑动 / 拖拽 |
| `scroll` | `dy` `x` `y` | 滚动（dy<0 向上） |
| `type` | `text` `index` `forceHID` | 输入：先试语义写入，再退 HID 键盘 |
| `setValue` | `index` `value` | 直接写值 |
| `press` | `index` `action` | 执行 AX action |
| `pressKey` | `usage` | 原始 HID usage（0x28=Return） |
| `home` / `appSwitcher` | — | 手势回桌面 / 多任务 |
| `lock` | — | 电源键（实验性） |
| `openApp` | `bundleId` | 启动 App |
| `launchUrl` | `url` | 打开 URL / deep link |
| `wait` | `text` `role` `timeout` | 轮询等元素出现 |

`dump` 结果：

```json
{
  "nodes": [
    {"i":0,"role":"View","cls":"UIWindow","frame":{"x":0,"y":0,"w":414,"h":896},"children":[1]},
    {"i":1,"role":"Button","cls":"UIButton","label":"无线局域网","id":"wifi-cell",
     "frame":{"x":0,"y":100,"w":414,"h":44},"enabled":true,"actions":["AXPress"]}
  ],
  "root": 0, "nodeCount": 2, "bundleId": "com.apple.Preferences",
  "screen": {"width":414,"height":896}, "source": "agent"
}
```

- `i` 只在**本次 dump** 内有效，下次 `dump` 后旧索引返回 `stale index`。
- 节点是 DFS 前序扁平数组，父子关系在 `children` 里。
- `source` 告诉你树是从哪来的：`agent`（App 内 UIKit 树）或 `ax`（系统无障碍树）。

---

## 架构要点 / 为什么这么设计

### iOS 17 上 AX 不可用

`AXUIElement` 跨进程访问需要连上 `axserver`。实测（iPhone 11 / iOS 17.1.1 / Dopamine）：

```
bootstrap_look_up("com.apple.iphone.axserver")   -> kr=1102 (BOOTSTRAP_UNKNOWN_SERVICE)
bootstrap_look_up("com.apple.springboard.services") -> kr=0   (found)
AXUIElementCopyAttributeValue(AXFocusedApplication) -> -25216
```

`axserver` 在 **user bootstrap 域**，root launchd daemon 在 **system 域**，lookup 必然失败 —— 这不是 entitlement 问题
（`SecTaskCopyValueForEntitlement` 里 `com.apple.private.accessibility` / `platform-application` 都是 1）。
另外 iOS 17 的 `libAccessibility.dylib` 已不再导出 `AXUIElementCreateApplication`。

所以：**iOS ≤16** 走 AX；**iOS 17+** 靠在每个 App 里注入 `UIBridgeAgent`（tweak），
它在本进程内遍历 `UIWindow` 视图树 —— 不需要任何无障碍权限。

### HID 注入

`IOHIDEventSystemClient` 的合成事件需要 `com.apple.private.hid.client.event-dispatch`。
digitizer 的字段号来自 xnu 的 `IOHIDEventTypes.h`（公开 SDK 里没有），代码里按
`IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) = 11<<16` 推算，并在启动时做 **set/get 回环自检**
（字段号不存在时 `IOHIDEventSetIntegerValue` 是静默 no-op，读回为 0，据此会在候选值间切换）。
`d.diagnostics()` 里的 `displayIntegratedField` 是最终选中的值。

### 前台 App 判断

`SBSCopyFrontmostApplicationDisplayIdentifier`（SpringBoardServices）—— 它在 system 域可达，已验证。

---

## 排错

### `info` 里 `axDiagnostics.probeFocusedApplication != 0`

| 码 | 含义 | 处理 |
|---|---|---|
| `0` | 正常 | — |
| `-25204` | `kAXErrorCannotComplete` | entitlement 没生效 |
| `-25211` | `kAXErrorAPIDisabled` | AX 客户端被禁 |
| `-25216` | iOS 17 的 axserver 不可达 | 正常现象，走 agent 路线 |

### `agents` 为空 / `dump` 报 `no agent for ...`

App 内没有注入 `UIBridgeAgent`：

1. `ls /var/jb/Library/MobileSubstrate/DynamicLibraries/UIBridgeAgent.dylib` 确认文件在
2. 确认 filter plist 在且格式为 OpenStep：
   `cat /var/jb/usr/lib/TweakInject/UIBridgeAgent.plist`
3. `killall -9 SpringBoard` 后重新打开目标 App
4. 检查 Dopamine 设置里的 tweak 注入是否开启
5. 目标 App 的 bundleId 必须在 `UIBridgeAgent.plist` 的 `Bundles` 里

### 点击位置偏 / 没反应

`IOHIDEvent` 的 `IsDisplayIntegrated` 字段号不对时坐标会被当作归一化值。
看 `d.diagnostics()["hid"]["displayIntegratedField"]`，或从设备上的 `IOHIDEventTypes.h`
取真值替换 `HIDInjector.m` 顶部的常量。

### 手势被识别成点击

`duration` 太短。滚动建议 `0.25~0.4`，`drag` 用 `1.0` 以上。

---

## 安全

daemon 默认监听 `0.0.0.0:9700`，**同局域网任何人都能操控这台手机**。
共享网络里务必设 token：

```bash
# launchd plist 的 EnvironmentVariables 加 UIBRIDGE_TOKEN，或直接传参
/var/jb/usr/libexec/uibridge 9700 my-secret
```

客户端：`uibridge.Device(host, token="my-secret")`。

---

## 已知限制

- 自绘 UI（Flutter / React Native / 游戏引擎）在 UIKit 视图树里可能只有一层容器，
  只能靠坐标 + `hit`。AX 路线上 WKWebView 里的 H5 元素能不能看到取决于页面。
- 没有截图能力（刻意不做）。需要像素校验时用 `idevicescreenshot`。
- `home` / `appSwitcher` 是手势，全屏视频和部分游戏里可能被 App 吞掉。
- 多指手势（捏合缩放）未实现，当前是单指。
- `lock` 走消费类 HID 电源键，未在所有版本验证。

## 自测

```bash
python3 client/selftest.py     # 假 daemon + 真客户端，覆盖协议/选择器/参数传递
```
