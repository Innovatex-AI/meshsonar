// The foundation gallery: every shared helper, the type scale, the semantic colours and the symbols on one scrolling
// screen. It is the sample screen the helpers are exercised from (WP0 acceptance) and what the simulator screenshot sheet
// (DR0, integration_test/foundation_gallery_test.dart) photographs. Not linked from the app UI.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_haptics.dart';
import 'app_surfaces.dart';
import 'app_symbols.dart';
import 'app_type.dart';
import 'app_widgets.dart';
import 'avatar_style.dart';
import 'state_views.dart';
import 'tokens.dart';

class HelperGallery extends StatefulWidget {
  const HelperGallery({super.key});

  @override
  State<HelperGallery> createState() => _HelperGalleryState();
}

class _HelperGalleryState extends State<HelperGallery> {
  bool _sw = true;
  final ScrollController scroll = ScrollController();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget h(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Layout.sectionGap, Layout.screenMargin, Gap.s),
      child: Semantics(header: true, child: Text(s.toUpperCase(), style: AppType.footnote.copyWith(color: c.textMuted))),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Foundation gallery')),
      body: ListView(
        controller: scroll,
        children: [
          h('Type scale'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Large title 34', key: const Key('type-largeTitle'), style: AppType.largeTitle),
                Text('Title 22 semibold', style: AppType.title2),
                Text('Headline 17 semibold', style: AppType.headline),
                Text('Body 17 regular text', style: AppType.body),
                Text('Callout 16', style: AppType.callout),
                Text('Subhead 15', style: AppType.subhead),
                Text('Footnote 13', style: AppType.footnote),
                Text('Caption 12', style: AppType.caption),
                const SizedBox(height: Gap.s),
                Text('0123456789 Hero', key: const Key('type-hero'), style: AppType.hero),
                Text('1111111111', style: AppType.hero),
                Text('0000000000', style: AppType.hero),
              ],
            ),
          ),
          h('Semantic colours'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              for (final e in {
                'accent': c.accent,
                'bubbleOut': c.bubbleOut,
                'beacon': c.beacon,
                'danger': c.danger,
                'warning': c.warning,
                'ok': c.ok,
                'surfaceHigh': c.surfaceHigh,
              }.entries)
                Container(
                  width: 96,
                  padding: const EdgeInsets.all(Gap.s),
                  decoration: BoxDecoration(color: e.value, borderRadius: BorderRadius.circular(Corners.small), border: Border.all(color: c.outline)),
                  child: Text(e.key, style: AppType.caption.copyWith(color: e.value.computeLuminance() > 0.4 ? Colors.black : Colors.white)),
                ),
            ]),
          ),
          h('Avatars'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              for (var i = 0; i < 12; i++) _Avatar(keyHex: '${i * 7919}ab', initials: String.fromCharCode(65 + i), colors: c),
            ]),
          ),
          h('Symbols'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [for (final s in AppSymbols.all) AppSymbolIcon(s, size: 24, color: c.textPrimary)]),
          ),
          h('Rows and banners'),
          AppSwitchTile(symbol: AppSymbols.waveform, title: 'Haptics', subtitle: 'Small taps for toggles and results', value: _sw, onChanged: (v) => setState(() => _sw = v)),
          const ChatStatusBanner(kind: StatusBannerKind.warning, message: 'Radio not connected', actionLabel: 'Connect'),
          const TipCard(tipId: 'gallery-tip', title: 'Tip', message: 'Open the guide for the legend.'),
          h('Helpers'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              CupertinoButton.filled(key: const Key('g-sheet'), onPressed: () => galleryOpenSheet(context), child: const Text('Sheet')),
              CupertinoButton.filled(key: const Key('g-action'), onPressed: () => galleryOpenActionSheet(context), child: const Text('Action sheet')),
              CupertinoButton.filled(key: const Key('g-alert'), onPressed: () => galleryOpenAlert(context), child: const Text('Alert')),
              CupertinoButton.filled(key: const Key('g-toast'), onPressed: () => galleryOpenToast(context), child: const Text('Toast')),
              CupertinoButton(onPressed: () => AppHaptics.success(), child: const Text('Haptic: success')),
            ]),
          ),
          h('States'),
          const SizedBox(height: 180, child: AppEmptyView(symbol: AppSymbols.tray, title: 'No messages yet', message: 'Say hello to someone on the mesh.', actionLabel: 'New message')),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

void galleryOpenSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (ctx, sc) => AppSheetScaffold(
    controller: sc,
    title: 'Layers',
    primaryAction: CupertinoButton.filled(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
    children: [
      for (final n in ['Coverage', 'Repeaters', 'Your pings', 'Network age'])
        AppSwitchTile(symbol: AppSymbols.layers, title: n, subtitle: 'Shown on the map', value: true, onChanged: (_) {}),
    ],
  ),
);

void galleryOpenActionSheet(BuildContext context) => showAppActionSheet<String>(
  context,
  title: 'Stop this drive?',
  message: 'Pings stop and the drive is saved on this phone.',
  actions: const [
    AppAction('Keep driving', 'keep', isDefault: true),
    AppAction('Stop drive', 'stop', destructive: true),
  ],
);

void galleryOpenAlert(BuildContext context) =>
    showAppAlert(context, title: 'Discard message?', message: 'Your draft will be lost.', confirmLabel: 'Discard', destructive: true);

void galleryOpenToast(BuildContext context) =>
    showAppToast(context, 'Drive saved on this phone', kind: AppToastKind.success, actionLabel: 'Undo', onAction: () {});

class _Avatar extends StatelessWidget {
  final String keyHex, initials;
  final AppColors colors;
  const _Avatar({required this.keyHex, required this.initials, required this.colors});

  @override
  Widget build(BuildContext context) {
    final s = avatarStyle(keyHex, colors);
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: s.fill, shape: BoxShape.circle),
      child: Text(initials, style: AppType.headline.copyWith(color: s.initials)),
    );
  }
}
