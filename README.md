# 墨阅 · 纯本地小说阅读器

「墨阅」是一款 **完全离线** 的中文小说阅读器，基于 Flutter 开发。
它只做一件事：找到你手机里的小说文件，让你舒服地把它们读完。

- 🔌 **本地优先**：书架/进度/书签全在本机；联网仅用于可选的「从链接导入」，且有总开关默认关闭
- 📚 **本地找书**：全盘扫描（含 SD 卡/U 盘）+ 手动指定文件夹 + 从其他 App 一键导入
- 🌐 **从链接导入**：粘贴文件直链下载入书架（需打开「允许联网下载」开关，只访问你粘贴的链接）
- 📖 **格式支持**：TXT / EPUB / MOBI / AZW3 / FB2 / HTML（五种主流小说格式）
- 🌙 **日间 / 夜间 / 跟随系统** 三种主题模式
- 🎨 纸白、米黄、护眼绿、羊皮纸、夜黑五种阅读背景，还支持 **自定义背景图片**
- 🔤 字号 / 行距可调，支持 **导入 .ttf 自定义字体**
- 📑 TXT 智能章节识别、目录跳转、书签
- ⏱ 每本书独立的进度记忆，下次打开接着读
- 🗂 书架：搜索、排序、重命名、自定义标签、已读/未读、置顶、批量管理、书籍详情

---

## 一、如何获得 APK（云端打包，无需安装任何开发环境）

本项目已配置 GitHub Actions，推送到 GitHub 后会**自动构建并产出 APK**。

### 步骤

1. **创建 GitHub 仓库**
   - 登录 [github.com](https://github.com) → 右上角 `+` → `New repository`
   - 仓库名随意（如 `moyue`），可选 **Public**（免费额度最充裕）或 Private

2. **把代码推上去**（在本项目目录执行，把 `<你的用户名>/<仓库名>` 换成自己的）
   ```bash
   cd moyue
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

3. **等待云端构建**
   - 打开仓库页面 → 顶部 **Actions** 标签
   - 点进正在运行的 `Build APK` 工作流
   - 构建约需 5~10 分钟，全部变绿即成功

4. **下载 APK**
   - 工作流详情页底部 → **Artifacts** → 下载 `moyue-apk`
   - 解压得到 `app-release.apk`

5. **安装到手机**
   - 把 APK 传到手机（微信文件传输助手 / 数据线 / 网盘均可）
   - 点击安装，系统提示「未知来源」时选择允许
   - 首次打开按提示授权「所有文件访问」即可开始全盘扫描

> 每次修改代码重新 `git push`，都会自动构建新的 APK。

## 二、权限与隐私说明

| 权限 | 用途 | 说明 |
|------|------|------|
| 所有文件访问（MANAGE_EXTERNAL_STORAGE） | 全盘扫描小说文件 | 安卓 11+ 需要，拒绝后仍可手动导入 |
| 读取存储（READ_EXTERNAL_STORAGE） | 老系统扫描存储 | 仅安卓 12 及以下生效 |
| 联网（INTERNET） | 「从链接导入」下载 | 受应用内「允许联网下载」开关约束，开关默认关闭；只访问用户粘贴的直链，无内置书源，绝无后台请求与上传 |

> 隐私承诺：墨阅不提供任何内容资源；联网仅发生在用户主动下载粘贴的直链时；
> 书籍、进度、书签不上传。分享链接由用户自行获取，请支持正版。

应用数据（书架、进度、书签、导入的书）全部保存在应用私有目录，卸载即清除。
不会认为它是病毒：应用使用标准 Flutter 框架、正常签名、无任何可疑行为。

## 三、正式签名（可选）

默认构建使用 debug 签名，**可以直接安装使用**。如果想用正式签名（比如以后上架应用市场）：

1. 本机生成密钥库（需要 Java 环境，或让 AI 帮你生成命令）：
   ```bash
   keytool -genkey -v -keystore moyue-key.jks -keyalg RSA -keysize 2048 -validity 36500 -alias moyue
   ```
2. 在 GitHub 仓库 → `Settings` → `Secrets and variables` → `Actions` → `New repository secret`，添加 4 个：
   | Secret 名 | 值 |
   |-----------|-----|
   | `MOYUE_KEYSTORE_BASE64` | `moyue-key.jks` 文件的 Base64 内容（`base64 -w0 moyue-key.jks`） |
   | `MOYUE_STORE_PASSWORD` | 生成密钥库时输入的 store 密码 |
   | `MOYUE_KEY_ALIAS` | `moyue` |
   | `MOYUE_KEY_PASSWORD` | key 密码 |
3. 重新触发构建即可得到正式签名的 APK。

> ⚠️ 密钥库文件请自己妥善备份，**不要**提交到仓库。

## 四、日常使用

- **找书**：首次打开会询问是否全盘扫描；之后可通过书架右下角「添加书籍」随时重新扫描、管理扫描文件夹或手动导入
- **从其他 App 导入**：在 QQ 浏览器 / 文件管理器里点击 txt / epub 文件 → 选择「用墨阅打开」，自动加入书架
- **阅读界面**：点屏幕中间呼出菜单；左侧 1/3 上一页，右侧 1/3 下一页
- **菜单**：目录、书签、上一章/下一章、进度滑块、夜间模式切换、设置（字号 / 行距 / 缩进 / 翻页模式 / 背景 / 字体）
- **书架管理**：长按书籍进入批量选择（删除 / 置顶）；单击书名卡片打开；长按不松手也能呼出单书详情（重命名、标签、删除）

## 五、本地开发（可选）

如果你以后想在电脑上开发调试：

1. 安装 [Flutter SDK](https://docs.flutter.dev/get-started/install)（本项目使用 3.47.1 stable 开发）
2. 安装 Android Studio（提供安卓 SDK）
3. `flutter pub get` → `flutter run` 或 `flutter build apk`

测试与检查：

```bash
flutter analyze   # 静态检查，当前 0 问题
flutter test      # 单元测试，当前 35 个用例全通过
```

## 六、iOS 版

代码使用 Flutter 编写，已兼容 iOS（工程内含 `ios/` 目录）。
但 iOS 需要 macOS + Xcode 打包，且安装到 iPhone 需要 Apple 开发者账号或自签，
当前按需求暂不处理，需要时可随时基于同一份代码出 iOS 包。

## 七、已知限制

- MOBI/AZW3 中使用 **HUFF/CDIC 压缩** 的少数文件暂不支持（会给出友好提示），转换成 EPUB/TXT 即可
- 繁体中文 Big5 编码的旧文件暂不支持，建议先转为 UTF-8 或 GBK
- 扫描跳过 `Android/` 和隐藏目录，这些位置不会有小说

## 项目结构

```
moyue/
├── lib/
│   ├── core/          # 格式识别、编码识别、文本工具
│   ├── data/          # 数据模型、SQLite、设置
│   ├── parser/        # TXT / EPUB / MOBI / FB2 / HTML 解析器
│   ├── reader/        # 分页引擎
│   ├── services/      # 文件扫描
│   ├── state/         # 状态管理（书架 / 阅读 / 主题 / 配置）
│   ├── ui/            # 界面（书架 / 阅读器 / 文件夹管理 / 详情）
│   ├── platform/      # 与原生通信（接收其他 App 的文件）
│   └── main.dart      # 入口
├── android/           # 安卓工程（权限最小化 + VIEW intent 接收）
├── ios/               # iOS 工程（代码兼容，暂不打包）
├── test/              # 35 个单元测试
└── .github/workflows/ # GitHub Actions 云端打包
```
