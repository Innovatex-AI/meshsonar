// One action set for every node surface (release 0.38, plan 4.5 item 2): Plan from here · Add to plan · Link to… ·
// Ping · Open page · Claim · Admin, only the ones valid for the node's kind, key, position and the app's state.
//
// [nodeActions] is the pure rule (unit-tested as a matrix per kind); [NodeActionBar] draws it the same way on every
// surface and dispatches: the three plan actions go to the Plan tab through ShellController.openPlan with a
// PlanRequest (planFrom / addNode / linkTo), Ping opens Trace with the node as the last hop (or the host's own ping),
// Open page calls the host, Claim is the claim flow (ClaimRepeaterAction: "Claim this repeater" or "Owned by you"),
// Admin opens the repeater or room admin over the connected radio.
//
// Rules:
//  * Plan from here / Add to plan: a site (repeater, room, sensor, observer) with a public position. Link to…: any node
//    with a public position (a person's radio can be a link end). A hidden position (U+1F6AB in the name, or not
//    published) offers none of the three: they would carry the coordinates.
//  * Ping: a repeater or room with a full key (a trace works on every firmware); other kinds only when the host has its
//    own ping (the contact profile). Needs the radio: shown dimmed with the reason otherwise.
//  * Open page: when the host can open the node's page (a region roster knows it), repeaters and rooms only.
//  * Claim: a repeater (never a room) with a full key, when claims are available or it is already yours.
//  * Admin: a repeater or room with a full key. Needs a radio connection that can administer: dimmed with the reason
//    otherwise, the same on every surface.
//  * A dimmed action stays tappable and says why (never a dead button); the first reason is also written under the bar.
import 'package:flutter/material.dart';

import '../app.dart' show AppScope;
import '../claims/claim_widgets.dart' show ClaimRepeaterAction;
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/tokens.dart' show Hit;
import '../radios/admin_launcher.dart' show adminUnavailableReason, openRepeaterAdmin;
import '../shell/shell_controller.dart';
import '../theme.dart' show Gap;
import '../tools/contact_ref.dart';
import '../tools/trace_screen.dart';
import 'node_ref.dart';

enum NodeActionId { planFrom, addToPlan, linkTo, ping, openPage, claim, admin }

@immutable
class NodeAction {
  final NodeActionId id;
  final String label;
  final AppSymbol symbol;

  /// False = drawn dimmed; [reason] says why.
  final bool enabled;
  final String? reason;
  const NodeAction(this.id, this.label, this.symbol, {this.enabled = true, this.reason});

  /// The widget key every surface uses for this action.
  Key get widgetKey => Key('node-action-${id.name}');

  @override
  String toString() => '${id.name}${enabled ? '' : '(off: $reason)'}';
}

/// What the app and the host offer right now, besides the node itself.
@immutable
class NodeActionEnv {
  /// The radio is connected.
  final bool radioConnected;

  /// Why the connected radio cannot administer (null = it can, or there is no radio: then [radioConnected] says so).
  final String? adminBlockedReason;

  /// The host can open the node's own page.
  final bool canOpenPage;

  /// The host has its own ping for this node (the contact profile's ping sheet works for every kind).
  final bool hostPing;

  /// Claims are on for this phone (or the node is already yours, which still shows "Owned by you").
  final bool claimAvailable;

  const NodeActionEnv({
    this.radioConnected = false,
    this.adminBlockedReason,
    this.canOpenPage = false,
    this.hostPing = false,
    this.claimAvailable = false,
  });

  /// The env from the app state above [context] (no app state = nothing that needs the radio or claims).
  factory NodeActionEnv.of(BuildContext context, NodeRef node, {bool canOpenPage = false, bool hostPing = false}) {
    final s = AppScope.maybeOf(context);
    final session = s?.radioSession;
    final connected = session != null && session.isConnected;
    final claims = s != null && s.nodeClaimsEnabled && (s.ownsRadio(node.key) || s.repeaterClaimEnabled);
    return NodeActionEnv(
      radioConnected: connected,
      adminBlockedReason: connected ? adminUnavailableReason(context) : null,
      canOpenPage: canOpenPage,
      hostPing: hostPing,
      claimAvailable: claims,
    );
  }
}

const String kNeedRadioReason = 'Connect your radio to use this.';
const String kNeedRadioAdminReason = 'Connect your radio to log in.';

/// The valid actions for [n], in display order.
List<NodeAction> nodeActions(NodeRef n, NodeActionEnv env) {
  final out = <NodeAction>[];
  final public = n.planSeed != null;
  final infra = n.kind == NodeKind.repeater || n.kind == NodeKind.room;
  if (public && n.kind.isSite) {
    out.add(const NodeAction(NodeActionId.planFrom, 'Plan from here', AppSymbols.map));
    out.add(const NodeAction(NodeActionId.addToPlan, 'Add to plan', AppSymbols.plus));
  }
  if (public) out.add(const NodeAction(NodeActionId.linkTo, 'Link to…', AppSymbols.location));
  if (n.kind.isRadioNode && n.hasFullKey && (infra || env.hostPing)) {
    out.add(NodeAction(NodeActionId.ping, 'Ping', AppSymbols.antenna,
        enabled: env.radioConnected, reason: env.radioConnected ? null : kNeedRadioReason));
  }
  if (env.canOpenPage && infra) {
    out.add(NodeAction(NodeActionId.openPage, n.kind == NodeKind.room ? 'Open room page' : 'Open repeater page', AppSymbols.infoCircle));
  }
  if (n.kind == NodeKind.repeater && n.hasFullKey && env.claimAvailable) {
    out.add(const NodeAction(NodeActionId.claim, 'Claim', AppSymbols.lock));
  }
  if (infra && n.hasFullKey) {
    final why = !env.radioConnected ? kNeedRadioAdminReason : env.adminBlockedReason;
    out.add(NodeAction(NodeActionId.admin, n.kind == NodeKind.room ? 'Administer room' : 'Administer', AppSymbols.gauge,
        enabled: why == null, reason: why));
  }
  return out;
}

/// The shell controller for [context]. Sheets and pushed screens live on the root navigator, beside the shell rather
/// than under it, so when [ShellScope] is not an ancestor the shell is looked up under the root navigator.
ShellController? shellControllerFor(BuildContext context) {
  final direct = ShellScope.maybeRead(context);
  if (direct != null) return direct;
  final root = Navigator.maybeOf(context, rootNavigator: true);
  if (root == null) return null;
  ShellController? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is ShellScope) {
      found = w.notifier;
      return;
    }
    e.visitChildElements(visit);
  }

  root.context.visitChildElements(visit);
  return found;
}

/// Sends [request] to the Plan tab: closes the sheets and screens above the tabs first so the planner is what shows.
/// False when there is no shell (an isolated screen); the person is told.
bool sendToPlanner(BuildContext context, PlanRequest request) {
  final shell = shellControllerFor(context);
  if (shell == null) {
    showAppToast(context, 'The planner is not available here.', kind: AppToastKind.error);
    return false;
  }
  final local = Navigator.maybeOf(context);
  final root = Navigator.maybeOf(context, rootNavigator: true);
  root?.popUntil((r) => r.isFirst);
  if (local != null && local != root) local.popUntil((r) => r.isFirst);
  shell.openPlan(request);
  return true;
}

/// Runs one action of [node]. [onOpenPage] / [onPing] are the host's own handlers (null = the default).
Future<void> runNodeAction(
  BuildContext context,
  NodeRef node,
  NodeAction action, {
  VoidCallback? onOpenPage,
  Future<void> Function()? onPing,
}) async {
  if (!action.enabled) {
    AppHaptics.warning();
    showAppToast(context, action.reason ?? 'Not available right now.');
    return;
  }
  AppHaptics.selection();
  final seed = node.planSeed;
  switch (action.id) {
    case NodeActionId.planFrom:
      if (seed != null) sendToPlanner(context, PlanRequest.planFrom(seed));
    case NodeActionId.addToPlan:
      if (seed != null) sendToPlanner(context, PlanRequest.addNode(seed));
    case NodeActionId.linkTo:
      if (seed != null) sendToPlanner(context, PlanRequest.linkTo(seed));
    case NodeActionId.ping:
      if (onPing != null) {
        await onPing();
      } else {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TraceScreen(contact: ContactRef.fromNode(node))));
      }
    case NodeActionId.openPage:
      onOpenPage?.call();
    case NodeActionId.claim:
      // Drawn by ClaimRepeaterAction, which owns the claim flow and the "Owned by you" state.
      break;
    case NodeActionId.admin:
      await openRepeaterAdmin(context, keyHex: node.key, name: node.name, isRoom: node.kind == NodeKind.room);
  }
}

/// The node's actions as one row of buttons (wrapping), then the claim button and the reason line. Same look on every
/// surface. [exclude] drops actions the surface already shows in its own way (the contact profile's tiles).
class NodeActionBar extends StatelessWidget {
  final NodeRef node;

  /// Opens the node's page; null = the surface has none (no "Open page").
  final VoidCallback? onOpenPage;

  /// The host's own ping (the contact profile); null = Trace with the node as the last hop.
  final Future<void> Function()? onPing;
  final Set<NodeActionId> exclude;

  /// Test seam: the env instead of the app state.
  final NodeActionEnv? env;

  const NodeActionBar({super.key, required this.node, this.onOpenPage, this.onPing, this.exclude = const {}, this.env});

  @override
  Widget build(BuildContext context) {
    final e = env ?? NodeActionEnv.of(context, node, canOpenPage: onOpenPage != null, hostPing: onPing != null);
    final all = [for (final a in nodeActions(node, e)) if (!exclude.contains(a.id)) a];
    final buttons = [for (final a in all) if (a.id != NodeActionId.claim) a];
    final claim = all.any((a) => a.id == NodeActionId.claim);
    if (buttons.isEmpty && !claim) return const SizedBox.shrink();
    final t = Theme.of(context);
    final reason = [for (final a in buttons) if (!a.enabled && a.reason != null) a.reason!].firstOrNull;
    final target = Hit.of(context);
    return Padding(
      key: const Key('node-actions'),
      padding: const EdgeInsets.only(top: Gap.m),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (buttons.isNotEmpty)
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                for (final a in buttons)
                  Semantics(
                    button: true,
                    label: a.enabled ? a.label : '${a.label}, unavailable. ${a.reason ?? ''}',
                    excludeSemantics: true,
                    child: FilledButton.tonalIcon(
                      key: a.widgetKey,
                      style: FilledButton.styleFrom(
                        minimumSize: Size(target, target),
                        foregroundColor: a.enabled ? null : t.colorScheme.onSurface.withValues(alpha: 0.45),
                        backgroundColor: a.enabled ? null : t.colorScheme.onSurface.withValues(alpha: 0.06),
                      ),
                      icon: AppSymbolIcon(a.symbol, size: 18),
                      label: Text(a.label),
                      onPressed: () => runNodeAction(context, node, a, onOpenPage: onOpenPage, onPing: onPing),
                    ),
                  ),
              ],
            ),
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(reason, key: const Key('node-actions-reason'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
          if (claim) ClaimRepeaterAction(keyHex: node.key, name: node.name, isRoom: node.kind == NodeKind.room),
        ],
      ),
    );
  }
}
