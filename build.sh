#!/bin/bash
# Furry Player 构建脚本
# 用法: ./build.sh [target]
#   target: linux, windows, android, all

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查依赖
check_deps() {
    command -v cargo >/dev/null 2>&1 || error "需要安装 Rust (cargo)"
}

# 构建 Linux
build_linux() {
    info "构建 Linux x86_64..."
    cargo build --release

    mkdir -p dist/linux
    cp target/release/furry_gui dist/linux/
    cp target/release/furry-cli dist/linux/

    info "Linux 构建完成: dist/linux/"
}

# 构建 Windows
build_windows() {
    info "构建 Windows x86_64..."

    # 检查工具链
    if ! rustup target list --installed | grep -q "x86_64-pc-windows-gnu"; then
        info "添加 Windows 目标..."
        rustup target add x86_64-pc-windows-gnu
    fi

    if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        warn "未找到 mingw-w64-gcc，请安装:"
        warn "  Arch Linux: sudo pacman -S mingw-w64-gcc"
        warn "  Ubuntu: sudo apt install gcc-mingw-w64-x86-64"
        warn "  Fedora: sudo dnf install mingw64-gcc"
        return 1
    fi

    # 构建 CLI (无 GUI 依赖，更容易交叉编译)
    cargo build --release --target x86_64-pc-windows-gnu --bin furry-cli

    mkdir -p dist/windows
    cp target/x86_64-pc-windows-gnu/release/furry-cli.exe dist/windows/

    info "Windows CLI 构建完成: dist/windows/"
    warn "注意: Windows GUI 需要额外的图形库依赖，建议在 Windows 上原生构建"
}

# 构建 Android
build_android() {
    info "构建 Android..."

    # 检查 NDK
    if [ -z "$ANDROID_NDK_HOME" ]; then
        warn "未设置 ANDROID_NDK_HOME 环境变量"
        warn "请下载 Android NDK 并设置:"
        warn "  export ANDROID_NDK_HOME=/path/to/android-ndk"
        return 1
    fi

    # 添加目标
    for target in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; do
        if ! rustup target list --installed | grep -q "$target"; then
            info "添加目标: $target"
            rustup target add "$target"
        fi
    done

    # 设置 NDK 工具链路径
    export PATH="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

    mkdir -p dist/android

    # 构建各架构
    for target in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; do
        info "构建 $target..."
        cargo build --release --target "$target" --lib -p furry_android

        case "$target" in
            aarch64-linux-android)
                mkdir -p dist/android/arm64-v8a
                cp "target/$target/release/libfurry_android.so" dist/android/arm64-v8a/ 2>/dev/null || true
                ;;
            armv7-linux-androideabi)
                mkdir -p dist/android/armeabi-v7a
                cp "target/$target/release/libfurry_android.so" dist/android/armeabi-v7a/ 2>/dev/null || true
                ;;
            x86_64-linux-android)
                mkdir -p dist/android/x86_64
                cp "target/$target/release/libfurry_android.so" dist/android/x86_64/ 2>/dev/null || true
                ;;
        esac
    done

    info "Android 库构建完成: dist/android/"
    warn "注意: Android GUI 需要使用 Kotlin/Java 包装层"
}

# 清理
clean() {
    info "清理构建产物..."
    cargo clean
    rm -rf dist/
    info "清理完成"
}

# 显示帮助
show_help() {
    echo "Furry Player 构建脚本"
    echo ""
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  linux     构建 Linux 版本"
    echo "  windows   构建 Windows 版本 (需要 mingw-w64)"
    echo "  android   构建 Android 库 (需要 NDK)"
    echo "  all       构建所有平台"
    echo "  clean     清理构建产物"
    echo "  help      显示此帮助"
    echo ""
    echo "示例:"
    echo "  $0 linux          # 仅构建 Linux"
    echo "  $0 all            # 构建所有平台"
}

# 主函数
main() {
    check_deps

    case "${1:-linux}" in
        linux)
            build_linux
            ;;
        windows)
            build_windows
            ;;
        android)
            build_android
            ;;
        all)
            build_linux
            build_windows || true
            build_android || true
            ;;
        clean)
            clean
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知命令: $1"
            ;;
    esac
}

main "$@"
