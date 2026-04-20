// ignore_for_file: deprecated_member_use

import 'dart:math';

import 'package:dropweb/common/common.dart';
import 'package:dropweb/providers/config.dart';
import 'package:dropweb/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hugeicons/hugeicons.dart';

class ThemeModeItem {
  const ThemeModeItem({
    required this.themeMode,
    required this.icon,
    required this.label,
  });
  final ThemeMode themeMode;
  final Widget icon;
  final String label;
}

class ThemeView extends StatelessWidget {
  const ThemeView({super.key});

  @override
  Widget build(BuildContext context) => const SingleChildScrollView(
        child: Column(
          spacing: 24,
          children: [
            _ThemeModeItem(),
            _PrueBlackItem(),
            _TextScaleFactorItem(),
            SizedBox(
              height: 64,
            ),
          ],
        ),
      );
}

class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.info,
    required this.child,
    this.actions = const [],
  });
  final Widget child;
  final Info info;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Wrap(
        runSpacing: 16,
        children: [
          InfoHeader(
            info: info,
            actions: actions,
          ),
          child,
        ],
      );
}

class _ThemeModeItem extends ConsumerWidget {
  const _ThemeModeItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode =
        ref.watch(themeSettingProvider.select((state) => state.themeMode));
    final themeModeItems = <ThemeModeItem>[
      ThemeModeItem(
        icon: HugeIcon(icon: HugeIcons.strokeRoundedRotate01, size: 18),
        label: appLocalizations.auto,
        themeMode: ThemeMode.system,
      ),
      ThemeModeItem(
        icon: HugeIcon(icon: HugeIcons.strokeRoundedSun01, size: 18),
        label: appLocalizations.light,
        themeMode: ThemeMode.light,
      ),
      ThemeModeItem(
        icon: HugeIcon(icon: HugeIcons.strokeRoundedMoon02, size: 18),
        label: appLocalizations.dark,
        themeMode: ThemeMode.dark,
      ),
    ];
    return ItemCard(
      info: Info(
        label: appLocalizations.themeMode,
        iconWidget: HugeIcon(icon: HugeIcons.strokeRoundedSun03, size: 24),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: themeModeItems.length,
          itemBuilder: (_, index) {
            final themeModeItem = themeModeItems[index];
            return CommonCard(
              isSelected: themeModeItem.themeMode == themeMode,
              onPressed: () {
                ref.read(themeSettingProvider.notifier).updateState(
                      (state) => state.copyWith(
                        themeMode: themeModeItem.themeMode,
                      ),
                    );
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Flexible(
                      child: themeModeItem.icon,
                    ),
                    const SizedBox(
                      width: 6,
                    ),
                    Flexible(
                      child: Text(
                        themeModeItem.label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          separatorBuilder: (_, __) => const SizedBox(
            width: 12,
          ),
        ),
      ),
    );
  }
}

class _PrueBlackItem extends ConsumerWidget {
  const _PrueBlackItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prueBlack = ref.watch(
      themeSettingProvider.select(
        (state) => state.pureBlack,
      ),
    );
    return ListItem.switchItem(
      leading: HugeIcon(icon: HugeIcons.strokeRoundedSun02, size: 24),
      horizontalTitleGap: 12,
      title: Text(
        appLocalizations.pureBlackMode,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
      ),
      delegate: SwitchDelegate(
        value: prueBlack,
        onChanged: (value) {
          ref.read(themeSettingProvider.notifier).updateState(
                (state) => state.copyWith(
                  pureBlack: value,
                ),
              );
        },
      ),
    );
  }
}

class _TextScaleFactorItem extends ConsumerWidget {
  const _TextScaleFactorItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textScale = ref.watch(
      themeSettingProvider.select(
        (state) => state.textScale,
      ),
    );
    final process = "${((textScale.scale * 100) as double).round()}%";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ListItem.switchItem(
            leading: HugeIcon(icon: HugeIcons.strokeRoundedTextFont, size: 24),
            horizontalTitleGap: 12,
            title: Text(
              appLocalizations.textScale,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
            ),
            delegate: SwitchDelegate(
              value: textScale.enable,
              onChanged: (value) {
                ref.read(themeSettingProvider.notifier).updateState(
                      (state) => state.copyWith.textScale(
                        enable: value,
                      ),
                    );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            mainAxisSize: MainAxisSize.max,
            spacing: 32,
            children: [
              Expanded(
                child: DisabledMask(
                  status: !textScale.enable,
                  child: ActivateBox(
                    active: textScale.enable,
                    child: SliderTheme(
                      data: _SliderDefaultsM3(context),
                      child: Slider(
                        padding: EdgeInsets.zero,
                        min: minTextScale,
                        max: maxTextScale,
                        value: textScale.scale,
                        onChanged: (value) {
                          ref.read(themeSettingProvider.notifier).updateState(
                                (state) => state.copyWith.textScale(
                                  scale: value,
                                ),
                              );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  process,
                  style: context.textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SliderDefaultsM3 extends SliderThemeData {
  _SliderDefaultsM3(this.context) : super(trackHeight: 16.0);

  final BuildContext context;
  late final ColorScheme _colors = Theme.of(context).colorScheme;

  @override
  Color? get activeTrackColor => _colors.primary;

  @override
  Color? get inactiveTrackColor => _colors.secondaryContainer;

  @override
  Color? get secondaryActiveTrackColor => _colors.primary.withOpacity(0.54);

  @override
  Color? get disabledActiveTrackColor => _colors.onSurface.withOpacity(0.38);

  @override
  Color? get disabledInactiveTrackColor => _colors.onSurface.withOpacity(0.12);

  @override
  Color? get disabledSecondaryActiveTrackColor =>
      _colors.onSurface.withOpacity(0.38);

  @override
  Color? get activeTickMarkColor => _colors.onPrimary.withOpacity(1.0);

  @override
  Color? get inactiveTickMarkColor => _colors.onSecondaryContainer;

  @override
  Color? get disabledActiveTickMarkColor =>
      _colors.onPrimary.withOpacity(0.38);

  @override
  Color? get disabledInactiveTickMarkColor =>
      _colors.onSurface.withOpacity(0.38);

  @override
  Color? get thumbColor => _colors.primary;

  @override
  Color? get overlappingShapeStrokeColor => _colors.primary;

  @override
  Color? get disabledThumbColor =>
      Color.alphaBlend(_colors.onSurface.withOpacity(.38), _colors.surface);

  @override
  Color? get overlayColor => _colors.primary.withOpacity(0.12);

  @override
  Color? get valueIndicatorColor => _colors.primary;

  @override
  Color? get valueIndicatorTextColor => _colors.onPrimary;

  @override
  SliderTrackShape? get trackShape => const RoundedRectSliderTrackShape();

  @override
  SliderComponentShape? get thumbShape =>
      const RoundSliderThumbShape(enabledThumbRadius: 10);

  @override
  SliderComponentShape? get overlayShape =>
      const RoundSliderOverlayShape(overlayRadius: 20);

  @override
  SliderTickMarkShape? get tickMarkShape => const RoundSliderTickMarkShape();

  @override
  SliderComponentShape? get valueIndicatorShape =>
      const PaddleSliderValueIndicatorShape();

  @override
  ShowValueIndicator? get showValueIndicator => ShowValueIndicator.onlyForDiscrete;

  @override
  TextStyle? get valueIndicatorTextStyle =>
      Theme.of(context).textTheme.labelMedium?.copyWith(color: _colors.onPrimary);

  @override
  double? get trackGap => 0;
}
