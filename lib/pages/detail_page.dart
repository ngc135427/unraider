import 'package:flutter/material.dart';

import '../services/unraid_client.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide.dart';
import '../widgets/gradient_button.dart';
import '../widgets/phone_frame.dart';

part 'detail_widgets.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  static const routeName = '/detail';

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is UnraidDashboard) {
      return _DashboardDetailPage(dashboard: args);
    }

    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          SizedBox(
            height: 120,
            child: Stack(
              children: [
                Positioned(
                  left: 12,
                  top: 28,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    label: const Text(
                      '返回',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        '产品详情',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '查看完整信息',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.80),
                          fontSize: 14,
                        ),
                      ),
                    ],
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 30, 30, 30),
                child: FadeSlide(
                  animate: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _DetailSection(
                        icon: Icons.info,
                        title: '基本信息',
                        child: Text(
                          '这是一个详情页面示例，展示如何按照登录页面的设计风格创建移动端详情页。页面保持相同的紫蓝渐变、圆角设计和柔和动效，确保视觉一致性。',
                          style: _bodyStyle,
                        ),
                      ),
                      const _DetailSection(
                        icon: Icons.list,
                        title: '功能列表',
                        child: Column(
                          children: [
                            _FeatureRow(label: '支持响应式设计'),
                            _FeatureRow(label: '保持视觉一致性'),
                            _FeatureRow(label: '优雅的动画效果'),
                            _FeatureRow(label: '清晰的信息层次'),
                          ],
                        ),
                      ),
                      const _DetailSection(
                        icon: Icons.description,
                        title: '详细说明',
                        child: Column(
                          children: [
                            _InfoCard(
                              title: '设计理念',
                              text: '延续登录页面的现代简约风格，以紫蓝渐变作为主视觉元素，创建统一且专业的用户体验。',
                            ),
                            SizedBox(height: 12),
                            _InfoCard(
                              title: '交互设计',
                              text: '页面元素采用顺序淡入动画，增强层次感和用户体验，按钮包含清晰的点击反馈。',
                            ),
                          ],
                        ),
                      ),
                      const _DetailSection(
                        icon: Icons.style,
                        title: 'UI 元素',
                        child: Text(
                          '采用大圆角设计增强现代感和友好度，适当的阴影提供层次感，合理的间距确保阅读舒适。',
                          style: _bodyStyle,
                        ),
                      ),
                      GradientButton(
                        label: '确认操作',
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('操作已确认'),
                            content: const Text('这里可以接入实际业务逻辑。'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('知道了'),
                              ),
                            ],
                          ),
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

