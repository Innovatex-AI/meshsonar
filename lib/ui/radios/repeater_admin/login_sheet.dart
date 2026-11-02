// The one login sheet for repeaters and rooms (chat plan 4.9). One password field, a "Log in as guest" button, no Admin/Guest
// switch: the node's reply decides the role. Failure states are inline, never dialogs, and they differ on purpose:
//   wrong password (PUSH 0x86)  -> "That password was not accepted."  (the node heard us)
//   no reply (silence)          -> "No reply after N s ..."           (wrong password, out of range, stale route or busy)
//   radio busy (queue)          -> "The radio is busy with another request"
// Passwords are never logged: this file has no logging and the model never puts a password in a message.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme, Material;
import 'package:flutter/semantics.dart';

import '../../../radio/admin_password_vault.dart';
import '../../../radio/default_passwords.dart';
import '../../../radio/login_outcome.dart';
import '../../design/app_haptics.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/app_widgets.dart';
import '../../design/tokens.dart';
import 'admin_controller.dart';

/// Whether a login goes along the saved route or searches for the node first (a flood login).
enum LoginRoute { saved, search }

enum LoginPhase { idle, waiting, failed, done }

/// State of one login sheet. Pure enough to test without a widget tree: give it an [attempt] and read [phase] / [outcome].
class LoginSheetModel extends ChangeNotifier {
  final String title;
  final String keyHex;
  final bool isRoom;

  /// "Via 3 repeaters - Strong" or similar; null when unknown.
  final String? routeLine;
  final AdminPasswordVault? vault;

  /// Runs one login. [guest] true = "Log in as guest" (the attempt picks the saved guest password, else the factory one).
  final Future<LoginOutcome> Function(String password, {required bool guest, required LoginRoute route}) attempt;

  /// Requests ahead on the radio's queue (0 = free), polled while waiting.
  final int Function() queueAhead;

  /// Called when the person gives up while a login is on the air.
  final VoidCallback? onCancel;

  /// Forget the radio's saved route to this node so the next login floods (called before a [LoginRoute.search] attempt).
  final Future<void> Function()? resetRoute;

  LoginSheetModel({
    required this.title,
    required this.keyHex,
    required this.attempt,
    this.isRoom = false,
    this.routeLine,
    this.vault,
    this.queueAhead = _zero,
    this.onCancel,
    this.resetRoute,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static int _zero() => 0;
  final DateTime Function() _clock;

  LoginPhase phase = LoginPhase.idle;
  LoginOutcome? outcome;
  LoginRoute route = LoginRoute.saved;
  bool rememberOn = false;
  bool rememberOffered = false;
  bool faceIdOn = false;
  bool faceIdOffered = false;

  /// The last login to this node found nothing on the saved route; cleared by a successful search (flood) login.
  bool routeStale = false;
  int elapsed = 0;
  int ahead = 0;
  String? prefill;
  Timer? _tick;
  DateTime? _started;
  bool _disposed = false;

  /// "Resumed session" is shown for a login the radio already held.
  bool resumed = false;

  Future<void> load() async {
    final v = vault;
    if (v == null) return;
    rememberOffered = v.canRemember;
    rememberOn = await v.remembering();
    faceIdOffered = v.canFaceId;
    faceIdOn = await v.faceIdOn();
    prefill = await v.recall(keyHex);
    _notify();
  }

  Future<void> setRemember(bool on) async {
    await vault?.setRemember(on, knownKeys: [keyHex]);
    rememberOn = on;
    if (!on) faceIdOn = false;
    _notify();
  }

  Future<void> setFaceId(bool on) async {
    await vault?.setFaceId(on);
    faceIdOn = on;
    _notify();
  }

  void setRoute(LoginRoute r) {
    route = r;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// The password field's text decides nothing about the role; [guest] only chooses which saved/default password is tried.
  Future<LoginOutcome> submit(String password, {bool guest = false}) async {
    if (phase == LoginPhase.waiting) return outcome ?? const LoginOutcome(LoginKind.other);
    phase = LoginPhase.waiting;
    outcome = null;
    elapsed = 0;
    ahead = queueAhead();
    _started = _clock();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsed = _clock().difference(_started!).inSeconds;
      ahead = queueAhead();
      _notify();
    });
    _notify();
    final searched = route == LoginRoute.search;
    if (searched) {
      try {
        await resetRoute?.call();
      } catch (_) {}
    }
    LoginOutcome o;
    try {
      o = await attempt(password, guest: guest, route: route);
    } catch (e) {
      o = classifyLoginError(e);
    }
    _tick?.cancel();
    if (_disposed) return o;
    if (phase != LoginPhase.waiting) return o; // cancelled meanwhile
    final secs = _clock().difference(_started!).inSeconds;
    if (o.kind == LoginKind.noReply && o.waitedSecs == null) o = LoginOutcome(o.kind, o.message, secs);
    outcome = o;
    if (o.ok) {
      phase = LoginPhase.done;
      if (searched) routeStale = false;
      AppHaptics.success();
    } else {
      phase = LoginPhase.failed;
      if (o.kind == LoginKind.noReply && !searched) routeStale = true;
      if (o.kind == LoginKind.wrongPassword) AppHaptics.warning();
    }
    _notify();
    return o;
  }

  void cancel() {
    if (phase == LoginPhase.waiting) {
      _tick?.cancel();
      phase = LoginPhase.idle;
      outcome = null;
      onCancel?.call();
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    super.dispose();
  }

  /// Adapter for the repeater admin screen.
  static LoginSheetModel forAdmin(RepeaterAdminController c, {String? routeLine, Future<void> Function()? resetRoute}) => LoginSheetModel(
        title: c.title,
        keyHex: c.session.keyHex,
        isRoom: c.isRoom,
        routeLine: routeLine,
        vault: c.vault,
        queueAhead: () => c.queueAhead,
        onCancel: c.cancelLogin,
        resetRoute: resetRoute,
        attempt: (pw, {required guest, required route}) async {
          final ok = guest ? await c.loginAsGuest() : await c.login(pw);
          return ok ? (c.loginOutcome ?? const LoginOutcome(LoginKind.guest)) : (c.loginOutcome ?? const LoginOutcome(LoginKind.other));
        },
      );
}

/// Copy for each failure, in one place so the sheet and its tests agree.
abstract final class LoginCopy {
  static const String wrongPassword = 'That password was not accepted.';
  static String noReply(int? secs) =>
      'No reply${secs == null ? '' : ' after $secs s'}. Wrong password, out of range, or the saved route is stale.';
  static String busy(int ahead) => 'The radio is busy with another request${ahead > 0 ? ' (waiting 1 of ${ahead + 1})' : ''}.';
  static const String notConnected = 'Your radio is not connected. Connect it, then try again.';
  static const String waiting = 'Can take up to 30 s.';
  static const String field = 'Enter the password for this repeater.';
  static const String roomField = 'Enter the room password.';
  static const String guestNote = 'Guest access is read only.';
}

String signedInAs(LoginOutcome o) => o.isAdmin ? 'Signed in as Admin' : 'Signed in as Guest';

/// Opens the login sheet. Returns the outcome when the login succeeded, null when the person closed the sheet.
Future<LoginOutcome?> showLoginSheet(BuildContext context, {required LoginSheetModel model}) {
  return showAppSheet<LoginOutcome>(
    context,
    detents: const [0.92],
    keyboardAware: true,
    builder: (ctx, controller) => LoginSheet(model: model, scrollController: controller),
  );
}

class LoginSheet extends StatefulWidget {
  final LoginSheetModel model;
  final ScrollController? scrollController;

  /// Pops the sheet with the outcome on success. Tests set false to look at the success state.
  final bool popOnSuccess;
  const LoginSheet({super.key, required this.model, this.scrollController, this.popOnSuccess = true});

  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  final _pw = TextEditingController();
  bool _show = false;
  bool _more = false;
  int _lastAnnounced = -1;

  LoginSheetModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.load().then((_) {
      if (mounted && m.prefill != null && _pw.text.isEmpty) setState(() => _pw.text = m.prefill!);
    });
    m.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (m.phase == LoginPhase.waiting && m.elapsed % 10 == 0 && m.elapsed != _lastAnnounced) {
      _lastAnnounced = m.elapsed;
      SemanticsService.sendAnnouncement(View.of(context), m.elapsed == 0 ? 'Logging in' : 'Still waiting, ${m.elapsed} seconds', Directionality.of(context));
    }
    if (m.phase == LoginPhase.failed && m.outcome?.kind == LoginKind.wrongPassword) {
      _pw.selection = TextSelection(baseOffset: 0, extentOffset: _pw.text.length);
    }
    setState(() {});
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    _pw.clear();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _go({bool guest = false}) async {
    final o = await m.submit(_pw.text, guest: guest);
    if (o.ok) {
      _pw.clear();
      if (widget.popOnSuccess && mounted) Navigator.of(context).maybePop(o);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppColors.of(context);
    final waiting = m.phase == LoginPhase.waiting;
    final factory = detectFactoryPassword(_pw.text);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Material(
      color: t.colorScheme.surface,
      child: SafeArea(
        key: const Key('login-sheet'),
        child: Column(children: [
          // Cancel is LEADING, as in every iOS sheet.
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Layout.screenMargin, 0),
            child: Row(children: [
              CupertinoButton(
                key: const Key('login-cancel'),
                minimumSize: const Size(Hit.min, Hit.min),
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                onPressed: () {
                  m.cancel();
                  Navigator.of(context).maybePop();
                },
                child: const Text('Cancel'),
              ),
              Expanded(child: Semantics(header: true, child: Text('Log in', textAlign: TextAlign.center, style: t.textTheme.titleMedium))),
              const SizedBox(width: Hit.min + Gap.s),
            ]),
          ),
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
              children: [
                Text(m.title, key: const Key('login-title'), style: t.textTheme.titleLarge),
                if (m.routeLine != null) Text(m.routeLine!, style: t.textTheme.bodyMedium?.copyWith(color: c.textMuted)),
                const SizedBox(height: Gap.m),
                CupertinoTextField(
                  key: const Key('login-password'),
                  controller: _pw,
                  autofocus: true,
                  enabled: !waiting,
                  obscureText: !_show,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 15,
                  placeholder: 'Password',
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _pw.text.isEmpty ? null : _go(),
                  onChanged: (_) => setState(() {}),
                  padding: const EdgeInsets.all(Gap.m),
                  suffix: CupertinoButton(
                    key: const Key('login-show'),
                    minimumSize: const Size(Hit.min, Hit.min),
                    padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                    onPressed: () => setState(() => _show = !_show),
                    child: Text(_show ? 'Hide' : 'Show'),
                  ),
                ),
                const SizedBox(height: Gap.xs),
                Text(m.isRoom ? LoginCopy.roomField : LoginCopy.field, key: const Key('login-help'), style: t.textTheme.bodySmall),
                if (_pw.text.isEmpty) Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(factoryPasswordHint, key: const Key('login-defaults'), style: t.textTheme.bodySmall?.copyWith(color: c.textMuted))),
                Row(children: [
                  Flexible(child: Text('No password?', style: t.textTheme.bodyMedium)),
                  CupertinoButton(
                    key: const Key('login-guest'),
                    minimumSize: const Size(Hit.min, Hit.min),
                    padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                    onPressed: waiting ? null : () => _go(guest: true),
                    child: const Text('Log in as guest'),
                  ),
                ]),
                if (factory != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.s),
                    child: _Notice(key: const Key('login-factory'), symbol: AppSymbols.exclamationTriangle, text: factoryPasswordWarning, color: c.warning),
                  ),
                if (m.rememberOffered) ...[
                  const SizedBox(height: Gap.s),
                  AppSwitchTile(
                    switchKey: const Key('login-remember'),
                    title: 'Remember on this iPhone',
                    subtitle: 'Kept in the iPhone Keychain, only on this phone.',
                    value: m.rememberOn,
                    onChanged: waiting ? null : m.setRemember,
                  ),
                  if (m.faceIdOffered && m.rememberOn)
                    AppSwitchTile(
                      switchKey: const Key('login-faceid'),
                      title: 'Ask for Face ID',
                      value: m.faceIdOn,
                      onChanged: waiting ? null : m.setFaceId,
                    ),
                ],
                CupertinoButton(
                  key: const Key('login-more'),
                  minimumSize: const Size(Hit.min, Hit.min),
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                  onPressed: () => setState(() => _more = !_more),
                  child: Row(children: [
                    Expanded(child: Text('More options', style: t.textTheme.bodyLarge)),
                    AppSymbolIcon(_more ? AppSymbols.chevronDown : AppSymbols.chevronRight, size: 16),
                  ]),
                ),
                if (_more) _routeChoice(context),
                const SizedBox(height: Gap.s),
                _status(context),
                const SizedBox(height: Gap.l),
              ],
            ),
          ),
          // Pinned above the keyboard.
          Container(
            padding: EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.s + (inset > 0 ? 0 : 0)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CupertinoButton.filled(
                key: const Key('login-go'),
                minimumSize: const Size(double.infinity, 50),
                onPressed: waiting ? () { m.cancel(); } : (_pw.text.isEmpty ? null : () => _go()),
                child: Text(waiting ? 'Cancel login' : 'Log in'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(waiting ? '${LoginCopy.waiting}   ${m.elapsed} s' : LoginCopy.waiting,
                    key: const Key('login-wait'), textAlign: TextAlign.center, style: t.textTheme.bodySmall?.copyWith(color: c.textMuted)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _routeChoice(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      key: const Key('login-route'),
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('How to reach it', style: t.textTheme.labelLarge),
        const SizedBox(height: Gap.xs),
        CupertinoSlidingSegmentedControl<LoginRoute>(
          groupValue: m.route,
          children: const {LoginRoute.saved: Text('Saved route'), LoginRoute.search: Text('Search for it')},
          onValueChanged: (v) {
            if (v != null && m.phase != LoginPhase.waiting) m.setRoute(v);
          },
        ),
        const SizedBox(height: Gap.xs),
        Text(m.route == LoginRoute.saved ? 'Uses the route your radio already knows. Quickest.' : 'Forgets the saved route and searches the whole mesh. Uses more airtime.',
            style: t.textTheme.bodySmall),
      ]),
    );
  }

  /// The inline result area, directly above the button. Each state has its own key and its own words.
  Widget _status(BuildContext context) {
    final c = AppColors.of(context);
    final o = m.outcome;
    if (m.phase == LoginPhase.waiting) {
      if (m.ahead > 0) {
        return _Notice(key: const Key('login-busy'), symbol: AppSymbols.clock, text: LoginCopy.busy(m.ahead), color: c.warning);
      }
      return Row(key: const Key('login-progress'), children: [
        const CupertinoActivityIndicator(),
        const SizedBox(width: Gap.s),
        Expanded(child: Text('Waiting for ${m.title}')),
      ]);
    }
    if (m.phase == LoginPhase.done && o != null) {
      return _Notice(key: const Key('login-success'), symbol: AppSymbols.checkmarkCircleFill, text: '${signedInAs(o)}${o.isAdmin ? '' : '. ${LoginCopy.guestNote}'}', color: c.ok);
    }
    if (m.phase == LoginPhase.failed && o != null) {
      switch (o.kind) {
        case LoginKind.wrongPassword:
          return _Notice(key: const Key('login-wrong'), symbol: AppSymbols.lock, text: LoginCopy.wrongPassword, color: c.danger);
        case LoginKind.noReply:
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Notice(key: const Key('login-noreply'), symbol: AppSymbols.antenna, text: LoginCopy.noReply(o.waitedSecs), color: c.warning),
            Wrap(children: [
              CupertinoButton(
                key: const Key('login-search'),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: () {
                  m.setRoute(LoginRoute.search);
                  _go();
                },
                child: const Text('Search for it'),
              ),
              CupertinoButton(key: const Key('login-retry'), minimumSize: const Size(Hit.min, Hit.min), onPressed: () => _go(), child: const Text('Try again')),
            ]),
          ]);
        case LoginKind.busy:
          return _Notice(key: const Key('login-busy'), symbol: AppSymbols.clock, text: LoginCopy.busy(m.ahead), color: c.warning);
        case LoginKind.notConnected:
          return _Notice(key: const Key('login-offline'), symbol: AppSymbols.exclamationCircle, text: LoginCopy.notConnected, color: c.danger);
        default:
          return _Notice(key: const Key('login-error'), symbol: AppSymbols.exclamationCircle, text: o.message.isEmpty ? 'Something went wrong. Try again.' : o.message, color: c.danger);
      }
    }
    return const SizedBox.shrink();
  }
}

class _Notice extends StatelessWidget {
  final AppSymbol symbol;
  final String text;
  final Color color;
  const _Notice({super.key, required this.symbol, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: AppSymbolIcon(symbol, size: 18, color: color)),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
      ]),
    );
  }
}
