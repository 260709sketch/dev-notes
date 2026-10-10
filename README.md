# WellMusic (SwiftUI 重写版)

WellMusic 全功能迁移到 SwiftUI 的工程。原版为 React Native (Expo SDK 50) 实现，本工程用 100% 原生 SwiftUI + AVFoundation 重写，功能与体验对齐原版。

## 构建要求

- macOS 13+ / Xcode 15+（推荐 Xcode 16）
- 真机（iPhone）调试需要开发者账号签名；模拟器可直接运行（部分锁屏/后台功能需真机验证）

## 打开方式

### 方式一：直接打开（推荐，Xcode 16+）
```
open WellMusicSwiftUI.xcodeproj
```

### 方式二：XcodeGen（Xcode 15 及以下，或添加新文件后不想改工程）
1. 安装：`brew install xcodegen`
2. 在工程根目录执行：`xcodegen generate`
3. 打开生成的 `WellMusicSwiftUI.xcodeproj`

工程使用文件夹同步（PBXFileSystemSynchronizedRootGroup），新增 Swift 文件会自动纳入编译，无需手动改工程文件。

## 与原版的功能对应关系

| 原 RN 模块 | SwiftUI 替代 | 状态 |
|---|---|---|
| react-native-track-player | PlayerCore (AVPlayer + MPNowPlayingInfoCenter) | 核心 |
| expo-av | AVPlayer | 核心 |
| @applemusic-like-lyrics/lyric | LyricsEngine (原生逐字渲染) / WKWebView 兼容模式 | 重写 |
| react-native-quick-crypto / crypto-js | CryptoKit + CommonCrypto (CryptoUtils) | 重写 |
| pako + iconv-lite | zlib (Compression) + String.Encoding | 重写 |
| react-native-mmkv / async-storage | UserDefaults + JSON 文件存储 (AppState) | 重写 |
| expo-music-info-2 | MediaLibrary + FileManager | 重写 |
| react-native-volume-manager | MPVolumeView | 重写 |
| qrcode | CoreImage.CIQRCodeGenerator | 重写 |
| react-native-image-colors | UIImage 主色提取 | 重写 |
| expo-share-intent | Share Extension | 另建 target |
| reanimated / gesture-handler | SwiftUI 原生动画 / DragGesture | 重写 |
| flash-list | ScrollView / LazyVStack | 重写 |

## 目录结构

```
WellMusicSwiftUI/
├── WellMusicSwiftUI/
│   ├── WellMusicApp.swift        # App 入口
│   ├── AppTheme.swift            # 主题色/样式
│   ├── Models/                   # 数据模型
│   ├── Core/                     # 状态、网络、加密
│   ├── Player/                   # 播放内核与队列
│   ├── Services/                 # 四大音乐源 API
│   ├── Lyrics/                   # 歌词解析与逐字引擎
│   └── Views/                    # 全部 SwiftUI 界面
└── project.yml                   # XcodeGen 配置（可选）
```

## 已知限制

- AMLL 逐字歌词动画：默认用 SwiftUI Canvas 原生重绘（效果接近苹果音乐）；如需要与原版像素级一致，可切换 WKWebView 内嵌原 JS 引擎模式。
- JS 脚本型自定义音源（LX/ikun）：仅保留内置 QQ/网易/酷狗/酷我 四大源；脚本源需要 JavaScriptCore 适配（后续版本）。
- 无音源 API 密钥/账号体系依赖，全部沿用原版公开接口逻辑，接口失效风险与原版一致。