Codex Dream Skin 一键安装包（Windows）

使用方法：
1. 先确认已经安装 Codex 桌面端，并且能正常登录打开。
2. 解压整个文件夹，不要只单独复制某一个文件。
3. 双击 Start-CodexDreamSkin-GUI.vbs。
4. 第一次使用点击“安装 / 修复”，它会自动安装并启动皮肤版 Codex。

如果图形界面打不开：
- 再双击 Start-CodexDreamSkin.cmd 使用备用菜单。

常用功能：
- 安装 / 修复：第一次使用、Codex 更新后、皮肤失效后都可以运行；如果 Codex 正在运行，会先提示关闭，完成后会自动启动皮肤版 Codex。
- 启动皮肤版 Codex：手动启动入口。
- 重启并启动：Codex 已经打开但没有皮肤时使用；会先弹出确认。
- 验证并截图：售后确认效果时使用。
- 换自己的图片：选择本地 PNG/JPG/JPEG/WEBP 图片，自动生成全窗口自适应主题并立即启动/刷新皮肤。
- 主题库 / 导入主题：选择本机保存的主题，或导入卖家制作的 theme.json 主题文件夹，并立即启动/刷新皮肤。
- 恢复默认图片：恢复内置默认自适应主题并立即启动/刷新皮肤。
- 恢复官方外观：回到 Codex 原始外观。
- 卸载快捷方式：删除 Dream Skin 创建的快捷方式。
- 打开日志：遇到问题时，把日志发给卖家排查。

主题文件夹格式：
- 一个文件夹里放 theme.json 和图片文件。
- theme.json 里的 image 字段写图片文件名，例如 "image": "arina.jpg"。
- 详细格式见 docs\theme-packages.txt。

重要说明：
- 这是第三方主题美化工具，不是 OpenAI 官方产品。
- 不提供 Codex 账号，不读取密码，不读取 API Key。
- 不修改 Codex 官方安装包，不替换 WindowsApps 或 app.asar。
- Codex 客户端更新后，可能需要重新运行“安装 / 修复”。
- 自定义图片的版权、肖像权、商标授权由图片提供者自行确认。

系统要求：
- Windows 版 Codex 桌面端。
- Node.js 22 或更新版本。
- PowerShell。

如果安装 / 修复失败：
1. 先关闭 Codex。
2. 重新双击 Start-CodexDreamSkin-GUI.vbs。
3. 点击“安装 / 修复”。
4. 如果仍失败，点击“打开日志”，把日志发给卖家排查。

如果启动失败：
1. 先关闭 Codex。
2. 重新双击 Start-CodexDreamSkin-GUI.vbs。
3. 点击“安装 / 修复”。
4. 点击“重启并启动”。
5. 仍失败时点击“打开日志”，把日志发给卖家排查。


