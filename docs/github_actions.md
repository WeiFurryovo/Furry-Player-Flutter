# GitHub Actions 打包/发布（推荐：给别人长期下载）

本仓库使用 `.github/workflows/release.yml`：
- 推送 tag（例如 `v1.0.0`）后自动构建：
  - Android：`app-release.apk`、`app-release.aab`（**需要正式签名**）
  - Linux：Flutter 桌面 bundle（tar.gz）
  - Windows：Flutter 桌面 Release（zip）
- 自动创建 GitHub Release 并上传上述产物 + SHA256 校验文件（各平台文件会放在对应子目录下，避免 `SHA256SUMS.txt` 重名覆盖）

同时提供 `.github/workflows/ci.yml`：
- 每次 push/PR 自动构建 **测试用 Artifacts**
  - Android：`app-debug.apk`（不需要签名 secrets）
  - Linux/Windows：桌面包（同样以 artifacts 形式提供）

工作流复用脚本位于 `apps/furry_flutter/scripts/`：
- `flutter_quality_gate.sh`：统一执行 `create_flutter_app + analyze + test`
- `flutter_doctor.sh` / `flutter_doctor.ps1`：统一执行 Flutter doctor（默认非阻塞）
- `setup_android_ndk.sh`：统一安装 cmdline-tools、accept licenses、安装 NDK
- `install_linux_desktop_deps.sh`：统一安装 Linux Flutter 桌面构建依赖
- `build_android_flutter.sh`：统一构建 Android debug/release 包并处理签名注入
- `build_linux_desktop_bundle.sh`：统一构建 Linux Flutter 桌面包并拷贝 `libfurry_ffi.so`
- `build_windows_desktop_bundle.ps1`：统一构建 Windows Flutter 桌面包并打包 `furry_flutter_windows.zip`
- `write_sha256_sums.sh` / `write_sha256_sums.ps1`：统一生成平台产物 SHA256SUMS.txt
- `prepare_flutter_app_windows.ps1`：Windows 下增量同步模板与依赖（基于 deps hash）

## 1) 配置 Secrets（Android 签名必需）
在 GitHub 仓库设置里：Settings → Secrets and variables → Actions → New repository secret

需要以下 Secrets：
- `ANDROID_KEYSTORE_BASE64`：你的 `upload-keystore.jks` 文件做 base64 的结果
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

生成 base64（本地）：
```sh
base64 -w0 upload-keystore.jks > keystore.b64
```
把 `keystore.b64` 的内容粘到 `ANDROID_KEYSTORE_BASE64`。

（可选）生成 keystore 示例：
```sh
keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

## 2) 发版方式（打 tag）
在仓库根目录：
```sh
git tag v1.0.0
git push origin v1.0.0
```

然后去 GitHub 的 Releases 页面下载产物。

## 2.1) 不发版也要下载（CI Artifacts）
不打 tag 的情况下：
- 去 GitHub → Actions → 选择最新一次 CI（`CI (Artifacts)`）→ Artifacts 下载

## 3) 常见问题
- Linux/Windows 桌面构建依赖 Flutter 桌面能力：工作流已在对应 runner 上执行 `flutter config --enable-...-desktop`
- Android 打包失败多半是签名 Secrets 没配齐或 keystore base64 不正确
