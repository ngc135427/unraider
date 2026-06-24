import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class BottomNavItem {
  const BottomNavItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
  });

  final List<BottomNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppTheme.softLine)),
      ),
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            for (var index = 0; index < items.length; index++)
              Expanded(
                child: InkWell(
                  onTap: () => onChanged(index),
                  child: _NavTile(
                    item: items[index],
                    selected: index == currentIndex,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.item, required this.selected});

  final BottomNavItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primary : AppTheme.textLight;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(item.icon, color: color, size: 21),
        const SizedBox(height: 2),
        Text(
          item.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 12),
        ),
      ],
    );
  }
}
