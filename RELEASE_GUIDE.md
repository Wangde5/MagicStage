# MagicStage — 发布与更新指南

> 本文档只描述版本交付：版本号、测试门槛、签名、公证、Sparkle、上传、远端验证和回滚。项目结构与功能回归见 `PROJECT_GUIDE.md`，界面实现规范见 `DESIGN_GUIDE.md`。任何发布操作都可能影响现有用户，不得猜测凭据、下载地址或密钥状态。

## 1. 当前发布状态：默认停止

当前仓库**不能直接安全发布**，原因如下：

1. `sparkle_private_key` 从初始提交起就在 Git 历史中，必须视为已经泄露。
2. 文件虽然已被 `.gitignore` 覆盖，但仍是 tracked file；忽略规则不能撤销历史泄露。
3. 当前 App 内嵌的是旧 Sparkle 公钥，已安装用户只接受旧私钥签名的更新。
4. 历史 zip 曾包含开发签名构建；历史产物不能作为新发布模板。
5. 仓库中没有可供 AI 使用的 Developer ID、公证 Keychain profile 或新 Sparkle 私钥。

因此，除非用户明确提供并授权一套密钥迁移方案，否则 AI 只能：

- 编译无签名的 Debug/Release 用于验证；
- 检查版本与配置；
- 准备发布清单；
- 不得生成、覆盖、签名、上传或推送正式更新。

## 2. 绝对禁止事项

- 不得读取后在输出中展示 Sparkle 私钥内容。
- 不得继续使用仓库中的旧私钥签署新公开版本。
- 不得直接替换 `SUPublicEDKey` 后宣称旧用户可以更新。
- 不得发布 `Apple Development`、ad-hoc 或未公证构建。
- 不得把新私钥、Apple ID 密码、API key、notary profile 导出到仓库。
- 不得修改历史 appcast 条目的最低系统版本来迎合当前源码；历史条目必须匹配对应历史二进制。
- 不得在未验证 GitHub Pages 文件可访问前推送 appcast 给用户。
- 未获用户明确授权，不得 commit、push、创建 tag、发布 GitHub Release 或改写 Git 历史。

## 3. 发布相关事实

| 项目 | 当前值/来源 |
|---|---|
| Bundle ID | `com.WDW.MagicStage` |
| Feed | `https://wangde5.github.io/MagicStage/appcast.xml` |
| Pages 源目录 | `main` 分支的 `docs/` |
| 最低系统 | target `MACOSX_DEPLOYMENT_TARGET`，当前 14.0 |
| 人类版本 | target `MARKETING_VERSION` |
| 构建号 | target `CURRENT_PROJECT_VERSION` |
| Info 版本 | `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` |
| Sparkle 公钥 | `MagicStage/Resources/Info.plist` 的 `SUPublicEDKey` |
| Appcast | `docs/appcast.xml` |
| Sparkle 工具 | 根目录 `generate_appcast`、`sign_update` |

发布前重新从工程读取这些值，不要照抄本文档中的版本数字。

## 4. Sparkle 密钥迁移

### 4.1 正确的信任链

旧用户验证的是“下载包签名”，不是 Git 提交。安全迁移通常需要：

```text
旧版 App（只信旧公钥）
  → 过渡版（由旧钥签名，App 内改为新公钥）
  → 后续版（由新钥签名）
```

但当前旧私钥已经公开，攻击者理论上也能签署更新，所以不能把它继续当作安全身份。迁移前用户必须决定风险接受方案，例如：

- 暂停自动更新，要求用户手动安装使用新公钥的可信版本；或
- 在控制 feed 与下载域名且完成额外公告/校验的前提下发布一次过渡版本，并接受旧钥已不可信的风险。

AI 不得自行选择方案。

### 4.2 新密钥要求

- 在仓库外生成并保存。
- 优先存放于受保护的 Keychain、密码管理器或离线安全介质。
- 只把新公钥写入 Info.plist。
- 私钥路径通过临时环境变量传给 Sparkle 工具。
- 更新 `.gitignore` 并在提交前运行秘密扫描。

### 4.3 旧密钥的 Git 处理

从当前分支删除 tracked 文件只能防止未来提交，不能清除历史。改写历史会改变所有 commit hash，属于单独的仓库迁移任务，需要：

1. 用户明确授权；
2. 通知所有协作者重新 clone；
3. 使用 `git filter-repo` 等工具清除全部引用；
4. 强制推送；
5. 仍然把旧密钥视为永久失效。

## 5. 发布门槛

以下所有条件都必须为真：

- [ ] 用户已批准 Sparkle 密钥迁移方案。
- [ ] 使用仓库外的新私钥或经批准的过渡方案。
- [ ] `MARKETING_VERSION` 是目标版本。
- [ ] `CURRENT_PROJECT_VERSION` 严格大于 appcast 最新构建号。
- [ ] Debug build 成功。
- [ ] 单元测试全部通过。
- [ ] Release build 成功。
- [ ] `PROJECT_GUIDE.md` 的手工回归清单全部通过，并记录测试系统、硬件与结果。
- [ ] 本版本涉及界面修改时，`DESIGN_GUIDE.md` 对应检查全部通过。
- [ ] `CHANGELOG.md` 与发布说明只描述本版本已经交付的用户可见变化。
- [ ] 正式 App 使用 `Developer ID Application` 签名。
- [ ] Apple notarization accepted。
- [ ] stapler validate 成功。
- [ ] Gatekeeper assessment 成功。
- [ ] 最终 zip 在 staple 之后重新生成。
- [ ] Sparkle 对最终 zip 的签名有效。
- [ ] appcast enclosure URL、length、version、minimumSystemVersion 正确。
- [ ] GitHub Pages 上 appcast 与 zip 都能下载。

任何一项失败都停止发布。

## 6. 版本准备

版本由 Xcode target build settings 管理。先读取当前值，不根据文档中的历史数字判断：

```bash
xcodebuild -project MagicStage.xcodeproj -scheme MagicStage \
  -showBuildSettings | \
  grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION|MACOSX_DEPLOYMENT_TARGET'
```

然后修改：

- `MARKETING_VERSION`：本次对用户展示的版本号。
- `CURRENT_PROJECT_VERSION`：整数，且严格大于 appcast 中已经公开的最高构建号。

确认展开后的产物：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /path/to/MagicStage.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /path/to/MagicStage.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' /path/to/MagicStage.app/Contents/Info.plist
```

不要直接在 Info.plist 写死版本。

## 7. 发布前代码验证

参考 `PROJECT_GUIDE.md` 的完整命令。最低要求：

```bash
xcodebuild test \
  -project MagicStage.xcodeproj \
  -scheme MagicStage \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/MagicStageTests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MagicStageTests

xcodebuild -project MagicStage.xcodeproj -scheme MagicStage \
  -configuration Release -derivedDataPath /tmp/MagicStageRelease \
  CODE_SIGNING_ALLOWED=NO build

git diff --check
plutil -lint MagicStage/Resources/Info.plist
xmllint --noout docs/appcast.xml
```

无签名 Release build 只能证明代码可编译，不是发行包。

## 8. Developer ID 归档

推荐在 Xcode 中选择 Any Mac，执行 Product → Archive，再从 Organizer 选择 Developer ID 分发。若使用命令行，必须由用户提供有效签名身份和 export 配置；AI 不得猜测。

导出的 App 应显示 Developer ID，而不是 Apple Development：

```bash
codesign -dv --verbose=4 /path/to/MagicStage.app 2>&1
codesign --verify --deep --strict --verbose=2 /path/to/MagicStage.app
```

同时检查嵌入的 Sparkle framework、Updater 和 Installer 等嵌套代码均通过验证。

## 9. Apple 公证与 staple

凭据应预先存入 Keychain profile。示意流程：

```bash
# 只用于提交公证的临时 zip
ditto -c -k --keepParent /path/to/MagicStage.app /tmp/MagicStage-notary.zip

xcrun notarytool submit /tmp/MagicStage-notary.zip \
  --keychain-profile '<NOTARY_PROFILE>' \
  --wait

xcrun stapler staple /path/to/MagicStage.app
xcrun stapler validate /path/to/MagicStage.app
spctl --assess --type execute --verbose=4 /path/to/MagicStage.app
```

只有 notarytool 明确返回 Accepted 才继续。最终分发 zip 必须在 staple 之后创建。

## 10. 最终更新包与 appcast

```bash
VERSION='<MARKETING_VERSION>'
APP_DIR='/path/to/exported-directory'
FINAL_ZIP="$PWD/docs/MagicStage-${VERSION}.zip"

cd "$APP_DIR"
ditto -c -k --keepParent MagicStage.app "$FINAL_ZIP"
cd -

./generate_appcast \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
  --download-url-prefix 'https://wangde5.github.io/MagicStage/' \
  docs/
```

生成后检查最新 item：

- `sparkle:version` 等于构建号；
- `sparkle:shortVersionString` 等于人类版本；
- `sparkle:minimumSystemVersion` 来自最终 App；
- enclosure 指向 GitHub Pages；
- length 等于最终 zip 字节数；
- EdDSA signature 针对最终 zip；
- 旧历史 item 未被无意改写。

## 11. 本地最终验证

```bash
unzip -q docs/MagicStage-<VERSION>.zip -d /tmp/MagicStage-final-check

codesign --verify --deep --strict --verbose=2 \
  /tmp/MagicStage-final-check/MagicStage.app
xcrun stapler validate /tmp/MagicStage-final-check/MagicStage.app
spctl --assess --type execute --verbose=4 \
  /tmp/MagicStage-final-check/MagicStage.app

shasum -a 256 docs/MagicStage-<VERSION>.zip
xmllint --noout docs/appcast.xml
```

建议把 SHA-256 作为发布说明的一部分，但 Sparkle 的 EdDSA 签名仍是自动更新信任基础。

## 12. 上传与远端验证

只有用户明确授权后才能提交和推送。建议提交范围：

- `MagicStage.xcodeproj/project.pbxproj` 的版本变化；
- `MagicStage/Resources/Info.plist` 的新公钥变化（仅密钥迁移时）；
- `docs/appcast.xml`；
- 新版本 zip；
- 发布说明。

推送后验证：

```text
https://wangde5.github.io/MagicStage/appcast.xml
https://wangde5.github.io/MagicStage/MagicStage-<VERSION>.zip
```

必须实际下载远端 zip，比较本地和远端 SHA-256，并再次解压验证签名、公证与版本。不要只看 HTTP 200。

## 13. 回滚原则

- appcast 或 zip 尚未公开：停止并修正，不增加无意义版本。
- appcast 已公开但 zip 错误：不要用同名 zip 静默覆盖；缓存会导致用户拿到不同内容。增加构建号，重新签名发布。
- 已发布 App 崩溃：发布更高构建号的修复版；Sparkle 不会把较低构建号当成更新。
- 签名、公证或密钥错误：立即从 feed 移除错误 item，暂停更新并通知用户。
- 私钥再次泄露：停止发布，重新执行密钥事件响应，不要仅删除文件。

## 14. 发布报告格式

每次发布任务结束时必须明确报告：

1. 版本和构建号；
2. 测试与构建结果；
3. codesign authority；
4. notarization submission ID 和最终状态；
5. stapler 与 Gatekeeper 结果；
6. 最终 zip SHA-256；
7. appcast URL 与 zip URL；
8. 是否 commit、push、tag；
9. 任何未完成或无法验证的步骤。

不得用“发布完成”概括未验证的流程。
