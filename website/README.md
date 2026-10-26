# 1Agent 官网

独立的纯静态官网，无 npm 依赖或前端构建步骤。页面以简体中文提供，安装要求与 `.github/workflows/release.yml`、`project.yml` 保持一致。

- `index.html`：产品介绍、原生界面截图轮播、功能切换与下载。
- `install.html`：系统要求、DMG 安装、首次打开、使用、更新与源码构建。
- `site.css` / `site.js`：共享样式与交互。
- `assets/appicon.png`：从项目现有 Original 应用图标导出的官网尺寸资源。

## 本地预览

在仓库根目录执行：

```sh
mkdir -p dist/pages
cp -R website/. dist/pages/
gh release view --repo itjun/1Agent --json tagName,assets \
  --jq '{version: .tagName, assets: [.assets[] | {name,url,size}]}' \
  > dist/pages/release.json
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist/pages
```

打开 `http://127.0.0.1:4173/`。不生成 `release.json` 时，下载链接回退到 GitHub 最新正式版页面，页面仍可使用。

## GitHub Pages

目标地址为 `https://itjun.github.io/1Agent/`。首次启用时，在仓库 Settings → Pages → Build and deployment 中选择 **GitHub Actions**。

`.github/workflows/pages.yml` 在官网改动推送到 `main`、正式版发布或手动运行时部署。现有 Release 工作流由 `GITHUB_TOKEN` 发布，因此也监听 Release 工作流成功完成事件。网站始终从 `main` 取内容，部署时生成同源 `release.json`，从最新正式版获取实际 DMG 文件地址、版本和大小，不将版本号固定在页面源码中。

下载清单不接受其他仓库或其他域名的包地址。读取失败、超时或未找到 arm64 DMG 时，页面保留 GitHub Releases 入口并显示说明。

## 验证

发布前检查桌面与手机宽度、截图轮播、功能页签的鼠标与键盘切换、深浅外观切换、安装页复制命令、折叠问答、页内锚点和下载清单成功与失败分支。通过 `/1Agent/` 子路径访问，确认相对资源路径适用于项目型 Pages。

官网参考 Otty 的留白、字号与布局节奏，使用 1Agent 自有图标和原生界面截图。截图在隔离偏好和目录下使用内存终端与示例项目生成，不包含私人主机、命令历史或凭据。Inter 字体及许可随站点自托管。
