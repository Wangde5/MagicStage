# MagicStage 更新发布指南

> 本文档写给**完全不懂技术的小白**。看完能自己独立完成 App 更新发布。

---

## 一、你的工具箱（已经就绪，不需要动）

在项目目录 `/Users/wangde5/Desktop/MagicStage` 下，有以下关键文件：

| 文件 | 作用 | 一句话解释 |
|------|------|-----------|
| `sparkle_private_key` | 数字签名私钥 | 你的"个人印章"，发版时盖在更新包上，证明是你本人发布的 |
| `generate_appcast` | 更新元数据生成器 | 扫描 `docs/` 下的 zip 文件，自动生成 `appcast.xml` |
| `sign_update` | 签名工具（备用） | 给单个文件签名，一般用不到 |
| `build.sh` | 一键构建脚本 | 编译 + 打包 + 部署中文字体，一条命令搞定 |
| `docs/` | 更新包存放目录 | 这个文件夹通过 jsDelivr CDN 加速，用户从这下载更新 |

---

## 二、核心原理（用大白话讲）

### 整个更新流程就像快递：

```
你（开发者）                          GitHub（仓库）                    用户（装了你的 App）
───────────                          ────────────                     ────────────────

1. 编译 App（.app 文件）
2. 压缩成 zip
3. 用私钥签名（盖印章）
4. 生成 appcast.xml（更新清单）
5. 推送到 GitHub ──────────►  jsDelivr CDN 自动加速  ◄────────── App 启动时自动读取 appcast.xml
                                                              │
                                                              ├─ 发现新版本？→ 弹窗通知用户
                                                              ├─ 用户点"安装更新"
                                                              └─ 自动下载 zip → 解压 → 替换旧 App
```

### 为什么用 jsDelivr？

jsDelivr 是一个**免费的公共 CDN**，能直接加速 GitHub 仓库里的文件。
- **国内无需 VPN 即可访问**（有国内节点）
- **无需额外配置**：文件放在 GitHub 仓库里就能用，不需要部署、不需要同步
- **自动跟随更新**：你 push 到 GitHub 后，jsDelivr 会自动拉取最新文件（有几分钟缓存延迟）

### 什么是 appcast.xml？

它就是一个"版本清单"，告诉 App 有没有新版本可用。就像你打开"设置 → 软件更新"，手机会去苹果服务器查"有没有新 iOS 版本？"——appcast.xml 就是那个查询结果。

### 什么是数字签名？

你用私钥给 zip 文件"盖章"，Sparkle 用公钥（写死在 Info.plist 里）验证章是不是真的。如果有人篡改了你的 zip 文件，章就对不上，Sparkle 拒绝安装。

**类比**：你用私章在文件上盖印，别人用你留的印模（公钥）核对。印模可以公开，私章不能丢。

---

## 三、你的网址

| 用途 | 地址 |
|------|------|
| GitHub 仓库 | https://github.com/Wangde5/MagicStage |
| 更新元数据（appcast.xml） | https://cdn.jsdelivr.net/gh/Wangde5/MagicStage@main/docs/appcast.xml |
| 下载 v1.4 | https://cdn.jsdelivr.net/gh/Wangde5/MagicStage@main/docs/MagicStage-1.4.zip |
| GitHub Pages 设置（备用） | https://github.com/Wangde5/MagicStage/settings/pages |

> jsDelivr URL 格式说明：`https://cdn.jsdelivr.net/gh/GitHub用户名/仓库名@分支名/文件路径`
> 你的仓库是 `Wangde5/MagicStage`，分支是 `main`，更新文件在 `docs/` 目录下。

---

## 四、发新版完整步骤（每次发版照做）

### 第 1 步：改版本号

用 Xcode 打开项目，找到 `MagicStage/Resources/Info.plist`，改两行：

```xml
<key>CFBundleShortVersionString</key>
<string>1.5</string>          <!-- 1.4 → 1.5（人类看的） -->

<key>CFBundleVersion</key>
<string>6</string>            <!-- 5 → 6（Sparkle 比较用的，必须比上次大） -->
```

> **规则**：`CFBundleVersion` 每次发版 +1。`CFBundleShortVersionString` 用 `1.0`、`1.1`、`2.0` 这种。

### 第 2 步：一键构建

打开终端，复制粘贴：

```bash
cd ~/Desktop/MagicStage
bash build.sh Release
```

这条命令做了三件事：
1. 编译 App（Release 模式，优化过的）
2. 把中文翻译复制到 Sparkle 框架里
3. 自动打开 App

### 第 3 步：打包 zip + 生成 appcast.xml

终端里继续粘贴（**把 VERSION 改成你的版本号**）：

```bash
cd ~/Desktop/MagicStage
VERSION="1.5"

# 打包（注意：必须先 cd 到 .app 所在目录再 zip）
APP_DIR="build/MagicStage.xcarchive/Products/Applications"
cd "$APP_DIR"
zip -r ~/Desktop/MagicStage/docs/MagicStage-${VERSION}.zip MagicStage.app

# 生成 appcast.xml（用私钥签名 + jsDelivr 下载链接）
cd ~/Desktop/MagicStage
./generate_appcast --ed-key-file sparkle_private_key --download-url-prefix "https://cdn.jsdelivr.net/gh/Wangde5/MagicStage@main/docs/" docs/
```

看到 `Wrote 1 new update` 就说明成功了。

### 第 4 步：推送到 GitHub

```bash
cd ~/Desktop/MagicStage
git add docs/ MagicStage/Resources/Info.plist
git commit -m "v${VERSION}"
git push
```

**完成。** 等 5-10 分钟，jsDelivr CDN 缓存刷新后，用户打开 App 点「检查更新」就会收到通知。

> jsDelivr 对 `@main` 分支的缓存大约 12 小时，但通常几分钟内就会更新。如果急着测试，可以在浏览器访问 URL 时加 `?v=时间戳` 强制刷新。

---

## 五、上传后会发生什么

### 你（开发者）的视角

```
docs/ 文件夹里有：
  MagicStage-1.4.zip     ← 旧版本
  MagicStage-1.5.zip     ← 新版本
  appcast.xml            ← 自动更新，包含两个版本的条目
```

### 用户（v1.4）的视角

打开 MagicStage → 系统设置 → 检查更新：

```
appcast.xml 里最新 version = 6
用户本地 App 的 version = 5
6 > 5 → "MagicStage 发现新版本！现已推出 MagicStage 1.5，你当前版本为 1.4"
       → 点"安装更新" → 自动下载 zip → 替换旧 App → 新版本上线
```

### 用户（v1.5）的视角

```
appcast.xml 里最新 version = 6
用户本地 App 的 version = 6
6 = 6 → "已是最新版本！MagicStage 1.5 为当前可用最新版本"
```

---

## 六、常见问题

### Q1：jsDelivr 缓存没刷新怎么办？

jsDelivr 对 `@main` 分支文件有缓存（约 12 小时）。如果刚 push 完发现还是旧内容：
1. 等几分钟，再试一次
2. 或在 URL 后加 `?v=1`、`?v=2` 强制刷新（仅用于测试，不影响 App 实际使用）
3. 或访问 https://www.jsdelivr.com/github 刷新缓存

### Q2：私钥丢了怎么办？

重新生成一对密钥，更新 Info.plist 里的 `SUPublicEDKey`，然后重新发版。**旧用户无法更新到新版本**（因为公钥不匹配），他们需要手动下载。

### Q3：怎么确认 jsDelivr 能访问到文件？

浏览器打开 https://cdn.jsdelivr.net/gh/Wangde5/MagicStage@main/docs/appcast.xml，看到 XML 代码就说明成功了。

### Q4：推送到 GitHub 失败了怎么办？

```bash
# 先拉取远程更新
git pull --rebase
# 再推送
git push
```

### Q5：老版本用户能自动收到更新吗？

**注意**：这次从 Vercel 迁移到 jsDelivr，老版本（1.4 及更早）的 `SUFeedURL` 指向的是 Vercel 地址，已经失效。**老用户需要手动下载一次 1.5 版本**，1.5 及以后的版本会指向 jsDelivr，后续就能自动更新了。

这是一次性的迁移成本，之后就稳定了。

### Q6：jsDelivr 会不会哪天也挂了？

jsDelivr 由 Cloudflare、Fastly、Bunny 等多家 CDN 厂商共同支持，是非常成熟的基础设施，稳定性远高于 Vercel。而且即使 jsDelivr 挂了，你的文件还在 GitHub 仓库里，随时可以切换到其他 CDN。

---

## 七、速查表

```
改版本号 → bash build.sh → 打包 zip → ./generate_appcast → git push
```

每次发版就这 5 步，记住即可。jsDelivr 会自动加速 GitHub 仓库里的文件，无需额外操作。
