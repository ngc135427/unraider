import 'package:flutter/material.dart';

import '../services/unraid_client.dart';
import '../services/video_stream_preferences.dart';
import '../theme/app_theme.dart';
import '../widgets/app_text_field.dart';
import '../widgets/phone_frame.dart';

class VideoStreamSettingsPage extends StatefulWidget {
  const VideoStreamSettingsPage({
    super.key,
    required this.client,
  });

  final UnraidClient client;

  @override
  State<VideoStreamSettingsPage> createState() =>
      _VideoStreamSettingsPageState();
}

class _VideoStreamSettingsPageState extends State<VideoStreamSettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _pathPrefixController = TextEditingController(text: '/mnt/user');
  final _tokenController = TextEditingController();
  bool _enabled = false;
  bool _showToken = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final configuration = await VideoStreamPreferences.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _enabled = configuration.enabled;
      _urlController.text = configuration.webDavUrl;
      _pathPrefixController.text = configuration.unraidPathPrefix;
      _tokenController.text = configuration.apiToken;
      _loading = false;
    });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false) || _saving) {
      return;
    }
    setState(() => _saving = true);
    final configuration = VideoStreamConfiguration(
      enabled: _enabled,
      webDavUrl: _urlController.text.trim(),
      unraidPathPrefix: _pathPrefixController.text.trim(),
      apiToken: _tokenController.text.trim(),
    );
    await VideoStreamPreferences.save(configuration);
    widget.client.configureWebDav(
      enabled: configuration.enabled,
      webDavUrl: configuration.webDavUrl,
      unraidPathPrefix: configuration.unraidPathPrefix,
      apiToken: configuration.apiToken,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_enabled ? '视频流配置已保存并启用' : 'WebDAV 视频直连已停用'),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _pathPrefixController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 620,
      child: Column(
        children: [
          SizedBox(
            height: 72,
            child: Row(
              children: [
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const SizedBox(width: 4),
                const Text(
                  '视频流配置',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color:
                                      AppTheme.primary.withValues(alpha: 0.16),
                                ),
                              ),
                              child: const Text(
                                '视频会优先通过 FileBrowser Quantum WebDAV 直连播放；连接失败时自动回退到 SMB/SFTP 渐进缓冲。',
                                style: TextStyle(
                                  color: AppTheme.textMedium,
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              value: _enabled,
                              activeTrackColor: AppTheme.secondary,
                              title: const Text(
                                '启用 WebDAV 视频直连',
                                style: TextStyle(
                                  color: AppTheme.textDark,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: const Text('停用后仍可使用 SMB/SFTP 播放'),
                              onChanged: _saving
                                  ? null
                                  : (value) => setState(() => _enabled = value),
                            ),
                            const SizedBox(height: 16),
                            AppTextField(
                              label: 'WebDAV 根地址',
                              controller: _urlController,
                              hint: '如 https://files.example.com/dav/data/',
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              enabled: !_saving,
                              validator: (value) {
                                if (!_enabled) {
                                  return null;
                                }
                                final uri = Uri.tryParse((value ?? '').trim());
                                if (uri == null ||
                                    (uri.scheme != 'http' &&
                                        uri.scheme != 'https') ||
                                    uri.host.isEmpty) {
                                  return '请输入完整的 http(s) WebDAV 根地址';
                                }
                                return null;
                              },
                              suffixIcon: const Icon(
                                Icons.link,
                                color: Color(0xFFA0A8B9),
                              ),
                            ),
                            const SizedBox(height: 18),
                            AppTextField(
                              label: 'Unraid 路径前缀',
                              controller: _pathPrefixController,
                              hint: '/mnt/user',
                              textInputAction: TextInputAction.next,
                              enabled: !_saving,
                              validator: (value) {
                                if (_enabled && (value ?? '').trim().isEmpty) {
                                  return '请输入 FileBrowser 数据源对应的 Unraid 路径';
                                }
                                return null;
                              },
                              suffixIcon: const Icon(
                                Icons.folder_outlined,
                                color: Color(0xFFA0A8B9),
                              ),
                            ),
                            const SizedBox(height: 18),
                            AppTextField(
                              label: 'FileBrowser API Token',
                              controller: _tokenController,
                              hint: '粘贴完整、未定制的 API Token',
                              obscureText: !_showToken,
                              textInputAction: TextInputAction.done,
                              enabled: !_saving,
                              onFieldSubmitted: (_) => _save(),
                              validator: (value) {
                                if (_enabled && (value ?? '').trim().isEmpty) {
                                  return '请输入 FileBrowser API Token';
                                }
                                return null;
                              },
                              suffixIcon: IconButton(
                                tooltip: _showToken ? '隐藏 Token' : '显示 Token',
                                onPressed: _saving
                                    ? null
                                    : () => setState(
                                          () => _showToken = !_showToken,
                                        ),
                                icon: Icon(
                                  _showToken
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  color: const Color(0xFFA0A8B9),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'API Token 可在 FileBrowser Quantum 的“设置 → API Tokens”中创建，数据源需授予下载权限。',
                              style: TextStyle(
                                color: AppTheme.textLight,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 26),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _saving ? null : _save,
                                icon: _saving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.save_outlined),
                                label: Text(_saving ? '正在保存…' : '保存配置'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
