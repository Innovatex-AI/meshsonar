// The shared empty / loading / error views for the redesigned screens (Cupertino look). Same rules as the existing
// widgets in ../state_widgets.dart: no spinner without a timeout, every message says what happened and what to do next,
// and the one action is a real button.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_symbols.dart';
import 'tokens.dart';

class AppEmptyView extends StatelessWidget {
  final AppSymbol symbol;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  const AppEmptyView({super.key, required this.symbol, required this.title, this.message, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) =>
      _CentredMessage(symbol: symbol, title: title, message: message, actionLabel: actionLabel, onAction: onAction);
}

class AppErrorView extends StatelessWidget {
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;
  const AppErrorView({super.key, required this.title, this.message, this.onRetry, this.retryLabel = 'Try again'});

  @override
  Widget build(BuildContext context) => _CentredMessage(
    symbol: AppSymbols.exclamationCircle,
    title: title,
    message: message,
    actionLabel: onRetry == null ? null : retryLabel,
    onAction: onRetry,
    tint: Theme.of(context).colorScheme.error,
  );
}

/// A spinner that gives up: after [timeout] it becomes an error with a retry (never an endless spinner).
class AppLoadingView extends StatefulWidget {
  final String? label;
  final Duration timeout;
  final VoidCallback? onRetry;
  const AppLoadingView({super.key, this.label, this.timeout = const Duration(seconds: 15), this.onRetry});

  @override
  State<AppLoadingView> createState() => _AppLoadingViewState();
}

class _AppLoadingViewState extends State<AppLoadingView> {
  Timer? _t;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _t = Timer(widget.timeout, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_slow) {
      return AppErrorView(
        title: 'This is taking longer than expected',
        message: 'Check your connection and try again.',
        onRetry: widget.onRetry,
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CupertinoActivityIndicator(radius: 14),
          if (widget.label != null) ...[
            const SizedBox(height: Gap.m),
            Text(widget.label!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class _CentredMessage extends StatelessWidget {
  final AppSymbol symbol;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? tint;
  const _CentredMessage({required this.symbol, required this.title, this.message, this.actionLabel, this.onAction, this.tint});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSymbolIcon(symbol, size: 44, color: tint ?? t.colorScheme.primary),
              const SizedBox(height: Gap.m),
              Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: Gap.xs),
                Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
              ],
              if (actionLabel != null) ...[
                const SizedBox(height: Gap.l),
                CupertinoButton.filled(minimumSize: const Size(Hit.min, Hit.min), onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
