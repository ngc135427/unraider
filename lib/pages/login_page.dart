import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../services/login_preferences.dart';
import '../services/unraid_client.dart';
import '../widgets/app_text_field.dart';
import '../widgets/fade_slide.dart';
import '../widgets/gradient_button.dart';
import '../widgets/phone_frame.dart';
import 'main_shell_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  static const routeName = '/login';

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _domainController = TextEditingController();
  final _usernameController = TextEditingController(text: 'root');
  final _passwordController = TextEditingController();
  final _domainFocusNode = FocusNode();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  bool _rememberMe = false;
  bool _useHttps = false;
  bool _loginSucceeded = false;
  /// Header compact mode only — avoids rebuilding the whole login form on focus.
  final ValueNotifier<bool> _hasInputFocus = ValueNotifier<bool>(false);
  /// Submit busy + status/error strip are isolated from the rest of the form.
  final ValueNotifier<bool> _isSubmitting = ValueNotifier<bool>(false);
  final ValueNotifier<_LoginFeedback?> _feedback =
      ValueNotifier<_LoginFeedback?>(null);
  /// Password visibility is isolated so toggles do not rebuild the full form.
  final ValueNotifier<bool> _showPassword = ValueNotifier<bool>(false);
  bool _loadingPreferences = true;
  Timer? _navigateHomeTimer;

  @override
  void initState() {
    super.initState();
    _domainFocusNode.addListener(_handleFocusChange);
    _usernameFocusNode.addListener(_handleFocusChange);
    _passwordFocusNode.addListener(_handleFocusChange);
    unawaited(_loadRememberedLogin());
  }

  @override
  void dispose() {
    _navigateHomeTimer?.cancel();
    _domainFocusNode.removeListener(_handleFocusChange);
    _usernameFocusNode.removeListener(_handleFocusChange);
    _passwordFocusNode.removeListener(_handleFocusChange);
    _domainFocusNode.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _hasInputFocus.dispose();
    _isSubmitting.dispose();
    _feedback.dispose();
    _showPassword.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final hasFocus = _domainFocusNode.hasFocus ||
        _usernameFocusNode.hasFocus ||
        _passwordFocusNode.hasFocus;
    if (_hasInputFocus.value == hasFocus) {
      return;
    }
    _hasInputFocus.value = hasFocus;
  }

  void _clearErrorOnEdit() {
    if (_feedback.value == null) {
      return;
    }
    _feedback.value = null;
  }

  Future<void> _submit() async {
    if (_isSubmitting.value || _loginSucceeded || _loadingPreferences) {
      return;
    }

    FocusScope.of(context).unfocus();
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    final client = UnraidWebGuiClient(
      baseUrl: _buildBaseUrl(),
      username: _usernameController.text,
      password: _passwordController.text,
    );

    _isSubmitting.value = true;
    _feedback.value = _LoginFeedback.status(
      '正在连接 ${_domainController.text.trim()}…',
    );

    try {
      await client.checkConnection();
      // Pre-warm SSH and dashboard while the success animation plays so the
      // home shell can join the same in-flight fetches on open.
      unawaited(client.warmSsh());
      unawaited(client.fetchDashboard(forceRefresh: true));
      await _saveRememberedLogin();
      if (!mounted) {
        return;
      }
      setState(() => _loginSucceeded = true);
      _feedback.value = const _LoginFeedback.status('已连接，正在进入主页…');
      _navigateHomeTimer?.cancel();
      _navigateHomeTimer = Timer(const Duration(milliseconds: 320), () {
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacementNamed(
          MainShellPage.routeName,
          arguments: client,
        );
      });
    } on UnraidClientException catch (error) {
      client.close();
      if (!mounted) {
        return;
      }
      _isSubmitting.value = false;
      _feedback.value = _LoginFeedback.error(error.message);
    } on TimeoutException {
      client.close();
      if (!mounted) {
        return;
      }
      _isSubmitting.value = false;
      _feedback.value = const _LoginFeedback.error(
        '连接超时，请检查服务器地址、协议和网络',
      );
    } on Object catch (error) {
      client.close();
      if (!mounted) {
        return;
      }
      _isSubmitting.value = false;
      _feedback.value = _LoginFeedback.error('登录失败：$error');
    }
  }

  Future<void> _loadRememberedLogin() async {
    try {
      final rememberedLogin = await LoginPreferences.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _rememberMe = rememberedLogin.rememberMe;
        if (rememberedLogin.rememberMe) {
          _domainController.text = rememberedLogin.domain;
          _usernameController.text = rememberedLogin.username;
          _passwordController.text = rememberedLogin.password;
          _useHttps = rememberedLogin.useHttps;
        }
        _loadingPreferences = false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _loadingPreferences = false);
    }
  }

  Future<void> _saveRememberedLogin() async {
    if (!_rememberMe) {
      await LoginPreferences.clear();
      return;
    }
    await LoginPreferences.save(
      rememberMe: true,
      domain: _domainController.text.trim(),
      username: _usernameController.text.trim().isEmpty
          ? 'root'
          : _usernameController.text.trim(),
      password: _passwordController.text,
      useHttps: _useHttps,
    );
  }

  String _buildBaseUrl() {
    var input = _domainController.text.trim();
    // Strip accidental trailing slashes for a cleaner base URL.
    while (input.endsWith('/')) {
      input = input.substring(0, input.length - 1);
    }
    // Users sometimes paste a full URL; honor the scheme as-is.
    if (input.startsWith('https://') || input.startsWith('http://')) {
      return input;
    }
    return '${_useHttps ? 'https' : 'http'}://$input';
  }

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 520,
      child: Column(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _hasInputFocus,
            builder: (context, compact, _) => _AuthHeader(compact: compact),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(30, 38, 30, 24),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: FadeSlide(
                // Login rebuilds on submit/errors; skip re-entrance animation.
                animate: false,
                child: SingleChildScrollView(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '服务器地址',
                          style: TextStyle(
                            color: AppTheme.textMedium,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _ProtocolDomainField(
                          useHttps: _useHttps,
                          controller: _domainController,
                          focusNode: _domainFocusNode,
                          enabled: !_isSubmitting.value && !_loginSucceeded,
                          onChanged: (_) => _clearErrorOnEdit(),
                          onToggle: () {
                            if (_isSubmitting.value || _loginSucceeded) {
                              return;
                            }
                            setState(() => _useHttps = !_useHttps);
                            _clearErrorOnEdit();
                          },
                          onSubmitted: (_) =>
                              _usernameFocusNode.requestFocus(),
                        ),
                        const SizedBox(height: 21),
                        AppTextField(
                          label: '用户名',
                          controller: _usernameController,
                          focusNode: _usernameFocusNode,
                          hint: 'root',
                          enabled: !_isSubmitting.value && !_loginSucceeded,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          onChanged: (_) => _clearErrorOnEdit(),
                          onFieldSubmitted: (_) =>
                              _passwordFocusNode.requestFocus(),
                          suffixIcon: const Icon(
                            Icons.person_outline,
                            color: Color(0xFFA0A8B9),
                          ),
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.isEmpty) {
                              return '请输入用户名';
                            }
                            if (text != 'root') {
                              return 'Unraid WebGUI 仅支持 root 用户登录';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 21),
                        ValueListenableBuilder<bool>(
                          valueListenable: _showPassword,
                          builder: (context, showPassword, _) {
                            return AppTextField(
                              label: '密码',
                              controller: _passwordController,
                              focusNode: _passwordFocusNode,
                              hint: '请输入 root 密码',
                              obscureText: !showPassword,
                              enabled: !_isSubmitting.value && !_loginSucceeded,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.password],
                              onChanged: (_) => _clearErrorOnEdit(),
                              onFieldSubmitted: (_) => unawaited(_submit()),
                              suffixIcon: IconButton(
                                tooltip: showPassword ? '隐藏密码' : '显示密码',
                                onPressed: _isSubmitting.value || _loginSucceeded
                                    ? null
                                    : () {
                                        _showPassword.value = !showPassword;
                                      },
                                icon: Icon(
                                  showPassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  color: const Color(0xFFA0A8B9),
                                ),
                              ),
                              validator: (value) {
                                if ((value ?? '').isEmpty) {
                                  return '请输入密码';
                                }
                                return null;
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Checkbox(
                              value: _rememberMe,
                              activeColor: AppTheme.secondary,
                              visualDensity: VisualDensity.compact,
                              onChanged: _isSubmitting.value || _loginSucceeded
                                  ? null
                                  : (value) {
                                      setState(
                                        () => _rememberMe = value ?? false,
                                      );
                                    },
                            ),
                            const Text(
                              '记住我',
                              style: TextStyle(
                                color: AppTheme.textMedium,
                                fontSize: 14,
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.lock_outline,
                              color: AppTheme.textLight,
                              size: 18,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ValueListenableBuilder<_LoginFeedback?>(
                          valueListenable: _feedback,
                          builder: (context, feedback, _) {
                            if (feedback == null) {
                              return const SizedBox.shrink();
                            }
                            if (feedback.isError) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.danger.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: AppTheme.danger.withValues(alpha: 0.28),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Icon(
                                        Icons.error_outline,
                                        color: AppTheme.danger,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          feedback.message,
                                          style: const TextStyle(
                                            color: AppTheme.danger,
                                            fontSize: 13,
                                            height: 1.35,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: ValueListenableBuilder<bool>(
                                valueListenable: _isSubmitting,
                                builder: (context, submitting, __) {
                                  return Row(
                                    children: [
                                      if (submitting && !_loginSucceeded) ...[
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Expanded(
                                        child: Text(
                                          feedback.message,
                                          style: const TextStyle(
                                            color: AppTheme.textMedium,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            );
                          },
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: _isSubmitting,
                          builder: (context, submitting, _) {
                            return GradientButton(
                              label: _loginSucceeded
                                  ? '登录成功'
                                  : submitting
                                      ? '正在连接…'
                                      : _loadingPreferences
                                          ? '加载中…'
                                          : '登录',
                              icon: _loginSucceeded ? Icons.check : null,
                              isSuccess: _loginSucceeded,
                              onPressed: _loginSucceeded ||
                                      submitting ||
                                      _loadingPreferences
                                  ? null
                                  : _submit,
                            );
                          },
                        ),
                      ],
                    ),
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

class _LoginFeedback {
  const _LoginFeedback._({
    required this.message,
    required this.isError,
  });

  const _LoginFeedback.status(String message)
      : this._(message: message, isError: false);

  const _LoginFeedback.error(String message)
      : this._(message: message, isError: true);

  final String message;
  final bool isError;
}

class _ProtocolDomainField extends StatelessWidget {
  const _ProtocolDomainField({
    required this.useHttps,
    required this.controller,
    required this.focusNode,
    required this.onToggle,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
  });

  final bool useHttps;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onToggle;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      textInputAction: TextInputAction.next,
      keyboardType: TextInputType.url,
      autofillHints: const [AutofillHints.url],
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      validator: (value) {
        final text = (value ?? '').trim();
        if (text.isEmpty) {
          return '请输入有效的 IP 地址或域名';
        }
        if (text.contains(' ')) {
          return '地址不能包含空格';
        }
        return null;
      },
      decoration: InputDecoration(
        hintText: 'IP 地址或域名，如 tower.local',
        prefixIconConstraints: const BoxConstraints(
          minWidth: 102,
          minHeight: 24,
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 15, right: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: enabled ? onToggle : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  useHttps ? 'https://' : 'http://',
                  style: TextStyle(
                    color: enabled ? AppTheme.textMedium : AppTheme.textLight,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_drop_down,
                  color: enabled ? AppTheme.textMedium : AppTheme.textLight,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Container(width: 1, height: 22, color: AppTheme.line),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthHeader extends StatelessWidget {
  const _AuthHeader({
    required this.compact,
  });

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      height: compact ? 108 : 180,
      child: Center(
        child: AnimatedScale(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          scale: compact ? 0.74 : 1,
          child: const _UnraidMark(),
        ),
      ),
    );
  }
}

class _UnraidMark extends StatelessWidget {
  const _UnraidMark();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Unraid',
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.24),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: CustomPaint(
          painter: _UnraidMarkPainter(),
        ),
      ),
    );
  }
}

class _UnraidMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final barPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final orangePaint = Paint()
      ..color = const Color(0xFFFF8A00)
      ..style = PaintingStyle.fill;

    void drawBar(double x, double y, double width, double height) {
      final radius = Radius.circular(height / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, y), width: width, height: height),
          radius,
        ),
        barPaint,
      );
    }

    void drawDot(double x, double y, double radius) {
      canvas.drawCircle(Offset(x, y), radius, orangePaint);
    }

    drawBar(center.dx, center.dy - 22, size.width * 0.46, 8);
    drawBar(center.dx, center.dy, size.width * 0.62, 8);
    drawBar(center.dx, center.dy + 22, size.width * 0.46, 8);

    drawDot(center.dx - 33, center.dy - 22, 5);
    drawDot(center.dx + 33, center.dy - 22, 5);
    drawDot(center.dx - 39, center.dy, 5);
    drawDot(center.dx + 39, center.dy, 5);
    drawDot(center.dx - 33, center.dy + 22, 5);
    drawDot(center.dx + 33, center.dy + 22, 5);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
