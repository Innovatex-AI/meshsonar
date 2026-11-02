// AppSymbols: one name per icon the redesigned screens use (manifest: symbols_manifest.md).
//
// Spike S14 outcome (WP0): the plan wanted an icon font built from exported SF Symbols. The SF Symbols licence could not
// be verified here (SF Symbols.app is not installed on this machine, and Apple's text forbids using the glyphs outside
// Apple-platform apps and, in the common reading, shipping them in a font file), so the documented default is taken: every symbol
// resolves to an open-licence glyph, CupertinoIcons (MIT, already a dependency) on Apple platforms and Material Icons
// (Apache 2.0) on Android. The `AppSymbol` API is the seam: swapping to a bundled symbol font later changes this file only.
//
// Coordinator update (chat spikes, PR #132 S14): do not export SF Symbols into a font or SVG; open-licence Lucide/Phosphor SVGs may
// be added later behind this same API (record each licence in symbols_manifest.md). None are needed yet: CupertinoIcons covers every row.
//
// This file and app_surfaces.dart are the ONLY places allowed to name `Icons.` (the Android branch); the lint test
// (test/lint/widget_ban_test.dart) enforces that.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

/// One symbol: the SF Symbol name it stands for and the glyph used on each platform family.
@immutable
class AppSymbol {
  final String sfName;
  final IconData apple;
  final IconData material;
  const AppSymbol(this.sfName, this.apple, this.material);
}

abstract final class AppSymbols {
  // Tabs and places
  static const car = AppSymbol('car', CupertinoIcons.car, Icons.directions_car_outlined);
  static const carFill = AppSymbol('car.fill', CupertinoIcons.car_fill, Icons.directions_car);
  static const message = AppSymbol('message', CupertinoIcons.chat_bubble, Icons.chat_bubble_outline);
  static const messageFill = AppSymbol('message.fill', CupertinoIcons.chat_bubble_fill, Icons.chat_bubble);
  static const chartBar = AppSymbol('chart.bar', CupertinoIcons.chart_bar, Icons.bar_chart);
  static const ellipsisCircle = AppSymbol('ellipsis.circle', CupertinoIcons.ellipsis_circle, Icons.more_horiz);
  static const map = AppSymbol('map', CupertinoIcons.map, Icons.map_outlined);
  static const mapFill = AppSymbol('map.fill', CupertinoIcons.map_fill, Icons.map);

  // People
  static const person = AppSymbol('person', CupertinoIcons.person, Icons.person_outline);
  static const personFill = AppSymbol('person.fill', CupertinoIcons.person_fill, Icons.person);
  static const person2 = AppSymbol('person.2', CupertinoIcons.person_2, Icons.people_outline);
  static const person2Fill = AppSymbol('person.2.fill', CupertinoIcons.person_2_fill, Icons.people);
  static const personBadgePlus = AppSymbol('person.badge.plus', CupertinoIcons.person_badge_plus, Icons.person_add_outlined);

  // Navigation and controls
  static const chevronRight = AppSymbol('chevron.right', CupertinoIcons.chevron_right, Icons.chevron_right);
  static const chevronLeft = AppSymbol('chevron.left', CupertinoIcons.chevron_left, Icons.chevron_left);
  static const chevronDown = AppSymbol('chevron.down', CupertinoIcons.chevron_down, Icons.expand_more);
  static const chevronUp = AppSymbol('chevron.up', CupertinoIcons.chevron_up, Icons.expand_less);
  static const plus = AppSymbol('plus', CupertinoIcons.plus, Icons.add);
  static const minus = AppSymbol('minus', CupertinoIcons.minus, Icons.remove);
  static const xmark = AppSymbol('xmark', CupertinoIcons.xmark, Icons.close);
  static const xmarkCircleFill = AppSymbol('xmark.circle.fill', CupertinoIcons.xmark_circle_fill, Icons.cancel);
  static const checkmark = AppSymbol('checkmark', CupertinoIcons.check_mark, Icons.check);
  static const checkmarkCircleFill = AppSymbol('checkmark.circle.fill', CupertinoIcons.check_mark_circled_solid, Icons.check_circle);
  static const ellipsis = AppSymbol('ellipsis', CupertinoIcons.ellipsis, Icons.more_horiz);
  static const magnifyingglass = AppSymbol('magnifyingglass', CupertinoIcons.search, Icons.search);
  static const lineDecrease = AppSymbol('line.3.horizontal.decrease', CupertinoIcons.line_horizontal_3_decrease, Icons.filter_list);
  static const layers = AppSymbol('square.stack.3d.up', CupertinoIcons.square_stack_3d_up, Icons.layers_outlined);
  static const squareAndArrowUp = AppSymbol('square.and.arrow.up', CupertinoIcons.share, Icons.ios_share);
  static const docOnDoc = AppSymbol('doc.on.doc', CupertinoIcons.doc_on_doc, Icons.copy);
  static const trash = AppSymbol('trash', CupertinoIcons.trash, Icons.delete_outline);
  static const pin = AppSymbol('pin', CupertinoIcons.pin, Icons.push_pin_outlined);
  static const pinFill = AppSymbol('pin.fill', CupertinoIcons.pin_fill, Icons.push_pin);
  static const paperplaneFill = AppSymbol('paperplane.fill', CupertinoIcons.paperplane_fill, Icons.send);
  static const arrowUpCircleFill = AppSymbol('arrow.up.circle.fill', CupertinoIcons.arrow_up_circle_fill, Icons.arrow_circle_up);

  // Status
  static const star = AppSymbol('star', CupertinoIcons.star, Icons.star_border);
  static const starFill = AppSymbol('star.fill', CupertinoIcons.star_fill, Icons.star);
  static const bell = AppSymbol('bell', CupertinoIcons.bell, Icons.notifications_none);
  static const bellSlash = AppSymbol('bell.slash', CupertinoIcons.bell_slash, Icons.notifications_off_outlined);
  static const exclamationTriangle = AppSymbol('exclamationmark.triangle', CupertinoIcons.exclamationmark_triangle, Icons.warning_amber);
  static const exclamationCircle = AppSymbol('exclamationmark.circle', CupertinoIcons.exclamationmark_circle, Icons.error_outline);
  static const infoCircle = AppSymbol('info.circle', CupertinoIcons.info, Icons.info_outline);
  static const lock = AppSymbol('lock', CupertinoIcons.lock, Icons.lock_outline);
  static const lockFill = AppSymbol('lock.fill', CupertinoIcons.lock_fill, Icons.lock);
  static const clock = AppSymbol('clock', CupertinoIcons.clock, Icons.schedule);
  static const flag = AppSymbol('flag', CupertinoIcons.flag, Icons.flag_outlined);
  static const gear = AppSymbol('gearshape', CupertinoIcons.gear, Icons.settings_outlined);

  // Radio and location
  static const location = AppSymbol('location', CupertinoIcons.location, Icons.near_me_outlined);
  static const locationFill = AppSymbol('location.fill', CupertinoIcons.location_fill, Icons.near_me);
  static const antenna = AppSymbol('antenna.radiowaves.left.and.right', CupertinoIcons.antenna_radiowaves_left_right, Icons.settings_input_antenna);
  static const wifi = AppSymbol('wifi', CupertinoIcons.wifi, Icons.wifi);
  static const bolt = AppSymbol('bolt', CupertinoIcons.bolt, Icons.bolt);
  static const battery = AppSymbol('battery.75', CupertinoIcons.battery_75_percent, Icons.battery_5_bar);
  static const thermometer = AppSymbol('thermometer', CupertinoIcons.thermometer, Icons.thermostat);
  static const tray = AppSymbol('tray', CupertinoIcons.tray, Icons.inbox_outlined);
  static const waveform = AppSymbol('waveform', CupertinoIcons.waveform, Icons.graphic_eq);

  /// Every symbol, for the manifest test and the gallery.
  static const List<AppSymbol> all = [
    car, carFill, message, messageFill, chartBar, ellipsisCircle, map, mapFill, //
    person, personFill, person2, person2Fill, personBadgePlus, //
    chevronRight, chevronLeft, chevronDown, chevronUp, plus, minus, xmark, xmarkCircleFill, checkmark,
    checkmarkCircleFill, ellipsis, magnifyingglass, lineDecrease, layers, squareAndArrowUp, docOnDoc, trash, pin,
    pinFill, paperplaneFill, arrowUpCircleFill, //
    star, starFill, bell, bellSlash, exclamationTriangle, exclamationCircle, infoCircle, lock, lockFill, clock, flag,
    gear, //
    location, locationFill, antenna, wifi, bolt, battery, thermometer, tray, waveform,
  ];
}

/// Draws an [AppSymbol] at [size] in the text colour (or [color]). Scales with text when [scaleWithText] is set.
class AppSymbolIcon extends StatelessWidget {
  final AppSymbol symbol;
  final double size;
  final Color? color;
  final String? semanticLabel;
  final bool scaleWithText;
  const AppSymbolIcon(this.symbol, {super.key, this.size = 22, this.color, this.semanticLabel, this.scaleWithText = true});

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).platform;
    final apple = p == TargetPlatform.iOS || p == TargetPlatform.macOS;
    final s = scaleWithText ? MediaQuery.textScalerOf(context).scale(size) : size;
    return Icon(apple ? symbol.apple : symbol.material, size: s, color: color, semanticLabel: semanticLabel);
  }
}
