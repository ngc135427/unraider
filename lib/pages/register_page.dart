import 'package:flutter/material.dart';

import '../widgets/app_text_field.dart';
import '../widgets/fade_slide.dart';
import '../widgets/gradient_button.dart';
import '../widgets/phone_frame.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  static const routeName = '/register';

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _registered = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _submit() {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }
    setState(() => _registered = true);
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 520,
      child: Column(
        children: [
          const _RegisterHeader(),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(30, 38, 30, 24),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: FadeSlide(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppTextField(
                        label: '用户名 / 手机号',
                        controller: _usernameController,
                        hint: '请输入用户名或手机号',
                        icon: Icons.person,
                        validator: (value) {
                          if ((value ?? '').trim().isEmpty) {
                            return '请输入有效的用户名或手机号';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 21),
                      AppTextField(
                        label: '密码',
                        controller: _passwordController,
                        hint: '请输入密码（至少 6 位）',
                        obscureText: true,
                        icon: Icons.lock,
                        validator: (value) {
                          if ((value ?? '').length < 6) {
                            return '密码不能少于 6 位';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 21),
                      AppTextField(
                        label: '确认密码',
                        controller: _confirmPasswordController,
                        hint: '请再次输入密码',
                        obscureText: true,
                        icon: Icons.lock,
                        validator: (value) {
                          if (value != _passwordController.text) {
                            return '两次输入的密码不一致';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 28),
                      GradientButton(
                        label: _registered ? '注册成功' : '注册',
                        icon: _registered ? Icons.check : null,
                        isSuccess: _registered,
                        onPressed: _registered ? null : _submit,
                      ),
                      const SizedBox(height: 22),
                      Center(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Text('已有账号？'),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('返回登录'),
                            ),
                          ],
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

class _RegisterHeader extends StatelessWidget {
  const _RegisterHeader();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '创建账号',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '请填写以下信息完成注册',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.80),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
