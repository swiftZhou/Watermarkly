# Watermarkly — Cursor 开工指令

你是一个资深的 iOS 开发专家，请协助我构建一个名为 Watermarkly 的 Swift 项目。

## 要求

1. 纯 UIKit 代码，不使用 Storyboard，支持 iOS 15+
2. 功能：
   - 主界面一个「选择照片」按钮，调用 PHPicker 多选图片（免费版最多 3 张）
   - 编辑界面实时预览水印效果，底部工具栏切换三种模式：全屏平铺、角落 Logo、带壳截图
   - 全屏平铺水印：文字可调透明度、旋转角度、间距；默认 45° 倾斜，40% 透明度
   - 角落水印：支持四角和居中放置，可调大小
   - 带壳截图：内置 3 款模板（iPhone / iPad / Mac），将用户截图套入壳内，底部添加文字
   - 编辑完成后批量保存到系统相册，不压缩画质
3. 免费试用逻辑：UserDefaults 记录已使用次数，最多 3 次，之后弹出内购页面（$2.99 买断），使用 StoreKit 2
4. 所有图像合成均使用 Core Graphics，不依赖第三方库
5. 界面风格：系统浅灰背景 `#F2F2F7`，蓝色主色调 `#007AFF`，iOS 原生组件，圆角 10pt

## 开发顺序

| 阶段 | 任务 |
|------|------|
| Day 1-2 | 工程搭建、相册多选、全屏平铺水印核心算法 |
| Day 3 | 参数调节 UI（透明度、旋转、间距滑块） |
| Day 4 | 角落 Logo 水印 + 批量保存 |
| Day 5 | 带壳截图模板（iPhone / iPad / Mac） |
| Day 6 | StoreKit 2 内购 + 免费试用 |
| Day 7 | 全面测试、App Store 素材 |

## 架构

```
MainViewController → EditViewController
WatermarkEngine（Core Graphics 合成）
TrialManager / StoreManager（内购）
```

完整产品规划见项目根目录产品文档（用户提供的 PRD）。
