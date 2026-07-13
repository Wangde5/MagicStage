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
| `docs/` | 更新包存放目录 | 这个文件夹会被 GitHub 自动托管，用户从这下载更新 |

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
5. 上传到 docs/ 文件夹 ──────────►  GitHub Pages 托管 ◄────────── App 启动时自动读取 appcast.xml
                                                              │
                                                              ├─ 发现新版本？→ 弹窗通知用户
                                                              ├─ 用户点"安装更新"
                                                              └─ 自动下载 zip → 解压 → 替换旧 App
```

### 什么是 appcast.xml？

它就是一个"版本清单"，告诉 App 有没有新版本可用。就像你打开"设置 → 软件更新"，手机会去苹果服务器查"有没有新 iOS 版本？"——appcast.xml 就是那个查询结果。

你当前 `docs/appcast.xml` 的内容（目前只有 v1.0）：

```xml
<rss version="2.0">
    <channel>
        <title>MagicStage</title>
        <item>
            <title>1.0</title>                           <!-- 人类看的版本号 -->
            <sparkle:version>1</sparkle:version>          <!-- 内部版本号，Sparkle 用这个比较大小 -->
            <enclosure url="https://wangde5.github.io/MagicStage/MagicStage-1.0.zip"  <!-- 下载地址 -->
                       sparkle:edSignature="xxxx..." />   <!-- 数字签名，证明是本人发布的 -->
        </item>
    </channel>
</rss>
```

### 什么是数字签名？

你用私钥给 zip 文件"盖章"，Sparkle 用公钥（写死在 Info.plist 里）验证章是不是真的。如果有人篡改了你的 zip 文件，章就对不上，Sparkle 拒绝安装。

**类比**：你用私章在文件上盖印，别人用你留的印模（公钥）核对。印模可以公开，私章不能丢。

---

## 三、你的网址

| 用途 | 地址 |
|------|------|
| GitHub 仓库 | https://github.com/Wangde5/MagicStage |
| 更新元数据（appcast.xml） | https://magic-stage.vercel.app/appcast.xml |
| 下载 v1.4 | https://magic-stage.vercel.app/MagicStage-1.4.zip |
| Vercel 项目控制台 | https://vercel.com/2061630958-9760s-projects/magic-stage |
| GitHub Pages 设置（备用） | https://github.com/Wangde5/MagicStage/settings/pages |

---

## 四、发新版完整步骤（每次发版照做）

### 第 1 步：改版本号

用 Xcode 打开项目，找到 `MagicStage/Resources/Info.plist`，改两行：

```xml
<key>CFBundleShortVersionString</key>
<string>1.1</string>          <!-- 1.0 → 1.1（人类看的） -->

<key>CFBundleVersion</key>
<string>2</string>            <!-- 1 → 2（Sparkle 比较用的，必须比上次大） -->
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
VERSION="1.1"

# 打包（注意：必须先 cd 到 .app 所在目录再 zip）
APP_DIR="build/MagicStage.xcarchive/Products/Applications"
cd "$APP_DIR"
zip -r ~/Desktop/MagicStage/docs/MagicStage-${VERSION}.zip MagicStage.app

# 生成 appcast.xml（用私钥签名 + Vercel 下载链接）
cd ~/Desktop/MagicStage
./generate_appcast --ed-key-file sparkle_private_key --download-url-prefix "https://magic-stage.vercel.app/" docs/
```

看到 `Wrote 1 new update` 就说明成功了。

### 第 4 步：推送到 GitHub

```bash
cd ~/Desktop/MagicStage
git add docs/ MagicStage/Resources/Info.plist
git commit -m "v${VERSION}"
git push
```

**完成。** 等 1-2 分钟，GitHub Pages 自动部署。用户打开 App 点「检查更新」就会收到通知。

---

## 五、上传后会发生什么

### 你（开发者）的视角

```
docs/ 文件夹里有：
  MagicStage-1.0.zip     ← 旧版本
  MagicStage-1.1.zip     ← 新版本
  appcast.xml            ← 自动更新，包含两个版本的条目
```

### 用户（v1.0）的视角

打开 MagicStage → 系统设置 → 检查更新：

```
appcast.xml 里最新 version = 2
用户本地 App 的 version = 1
2 > 1 → "MagicStage 发现新版本！现已推出 MagicStage 1.1，你当前版本为 1.0"
       → 点"安装更新" → 自动下载 zip → 替换旧 App → 新版本上线
```

### 用户（v1.1）的视角

```
appcast.xml 里最新 version = 2
用户本地 App 的 version = 2
2 = 2 → "已是最新版本！MagicStage 1.1 为当前可用最新版本"
```

---

## 六、常见问题

### Q1：我还没上传，为什么 App 就显示"已是最新版本"？

因为 `appcast.xml` 里只有 v1.0（version=1），你的 App 也是 version=1，Sparkle 判断"没有更新"。

**只有当你上传了更大的版本号（如 version=2），其他用户（version=1）才会收到更新通知。**

### Q2：GitHub 上的源码和 docs/ 里的 .zip 是什么关系？

**没关系。** 源码是给你开发用的，docs/ 里的 zip 是给用户下载的。你改源码不一定要推，但发新版必须推 `docs/`。

### Q3：私钥丢了怎么办？

重新生成一对密钥，更新 Info.plist 里的 `SUPublicEDKey`，然后重新发版。**旧用户无法更新到新版本**（因为公钥不匹配），他们需要手动下载。

### Q4：怎么确认 Vercel 部署成功了？

浏览器打开 https://magic-stage.vercel.app/appcast.xml，看到 XML 代码就说明成功了。

### Q5：推送到 GitHub 失败了怎么办？

```bash
# 先拉取远程更新
git pull --rebase
# 再推送
git push
```

---

## 七、速查表

```
改版本号 → bash build.sh → 打包 zip → ./generate_appcast → git push
```

每次发版就这 5 步，记住即可。