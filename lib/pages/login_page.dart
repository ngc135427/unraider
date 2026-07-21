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
  bool _hasInputFocus = false;
  bool _isSubmitting = false;
  bool _showPassword = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _domainFocusNode.addListener(_handleFocusChange);
    _usernameFocusNode.addListener(_handleFocusChange);
    _passwordFocusNode.addListener(_handleFocusChange);
    _loadRememberedLogin();
  }

  @override
  void dispose() {
    _domainFocusNode.removeListener(_handleFocusChange);
    _usernameFocusNode.removeListener(_handleFocusChange);
    _passwordFocusNode.removeListener(_handleFocusChange);
    _domainFocusNode.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _domainController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final hasFocus = _domainFocusNode.hasFocus ||
        _usernameFocusNode.hasFocus ||
        _passwordFocusNode.hasFocus;
    if (_hasInputFocus == hasFocus) {
      return;
    }
    setState(() => _hasInputFocus = hasFocus);
  }

  Future<void> _submit() async {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    final client = UnraidWebGuiClient(
      baseUrl: _buildBaseUrl(),
      username: _usernameController.text,
      password: _passwordController.text,
    );

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await client.checkConnection();
      await _saveRememberedLogin();
      if (!mounted) {
        return;
      }
      setState(() => _loginSucceeded = true);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacementNamed(
        MainShellPage.routeName,
        arguments: client,
      );
    } on UnraidClientException catch (error) {
      client.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _isSubmitting = false;
      });
    } on Object catch (error) {
      client.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = '登录失败：$error';
        _isSubmitting = false;
      });
    }
  }

  Future<void> _loadRememberedLogin() async {
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
    });
  }

  Future<void> _saveRememberedLogin() async {
    await LoginPreferences.save(
      rememberMe: _rememberMe,
      domain: _domainController.text.trim(),
      username: _usernameController.text.trim().isEmpty
          ? 'root'
          : _usernameController.text.trim(),
      password: _passwordController.text,
      useHttps: _useHttps,
    );
  }

  String _buildBaseUrl() {
    final input = _domainController.text.trim();
    if (input.startsWith('http://') || input.startsWith('https://')) {
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
          _AuthHeader(compact: _hasInputFocus),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(30, 38, 30, 24),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: FadeSlide(
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
                          onToggle: () =>
                              setState(() => _useHttps = !_useHttps),
                        ),
                        const SizedBox(height: 21),
                        AppTextField(
                          label: '用户名',
                          controller: _usernameController,
                          focusNode: _usernameFocusNode,
                          hint: 'root',
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
                        AppTextField(
                          label: '密码',
                          controller: _passwordController,
                          focusNode: _passwordFocusNode,
                          hint: '请输入 root 密码',
                          obscureText: !_showPassword,
                          suffixIcon: IconButton(
                            tooltip: _showPassword ? '隐藏密码' : '显示密码',
                            onPressed: () {
                              setState(() => _showPassword = !_showPassword);
                            },
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: const Color(0xFFA0A8B9),
                            ),
                          ),
                          validator: (value) {
                            if ((value ?? '').trim().isEmpty) {
                              return '请输入密码';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Checkbox(
                              value: _rememberMe,
                              activeColor: AppTheme.secondary,
                              visualDensity: VisualDensity.compact,
                              onChanged: (value) {
                                setState(() => _rememberMe = value ?? false);
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
                        if (_errorMessage != null) ...[
                          Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: AppTheme.danger,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        GradientButton(
                          label: _loginSucceeded
                              ? '登录成功'
                              : _isSubmitting
                                  ? '正在连接'
                                  : '登录',
                          icon: _loginSucceeded ? Icons.check : null,
                          isSuccess: _loginSucceeded,
                          onPressed:
                              _loginSucceeded || _isSubmitting ? null : _submit,
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

class _ProtocolDomainField extends StatelessWidget {
  const _ProtocolDomainField({
    required this.useHttps,
    required this.controller,
    required this.focusNode,
    required this.onToggle,
  });

  final bool useHttps;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      validator: (value) {
        if ((value ?? '').trim().isEmpty) {
          return '请输入有效的 IP 地址或域名';
        }
        return null;
      },
      decoration: InputDecoration(
        hintText: '请输入 IP 地址或域名',
        prefixIconConstraints: const BoxConstraints(
          minWidth: 102,
          minHeight: 24,
        ),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 15, right: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  useHttps ? 'https://' : 'http://',
                  style: const TextStyle(
                    color: AppTheme.textMedium,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.arrow_drop_down,
                  color: AppTheme.textMedium,
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
