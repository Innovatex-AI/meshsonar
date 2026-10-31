// The shared empty / loading / error states. Rules: no spinner without a timeout, every message says what happened
// and what to do next, and the one action is a real button. (EmptyState lives in widgets.dart with the other
// small shared widgets; these two sit beside it.)
import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// "Something went wrong, here is what to do": an icon, a short title, one sentence of cause, an optional retry.
class ErrorState extends StatelessWidget {
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;
  const ErrorState({
    super.key,
    required this.title,
    this.message,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.icon = Icons.error_outline_rounded,
  });

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
              Icon(icon, size: 40, color: t.colorScheme.error),
              const SizedBox(height: Gap.m),
              Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(message!,
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: Gap.l),
                FilledButton.tonal(
                  key: const Key('state-retry'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onRetry,
                  child: Text(retryLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A spinner with a message that gives up after [timeout] and becomes an [ErrorState]. Never spins forever.
class LoadingState extends StatefulWidget {
  final String message;
  final Duration timeout;
  final String timeoutTitle;
  final String timeoutMessage;
  final VoidCallback? onRetry;
  const LoadingState({
    super.key,
    this.message = 'Loading…',
    this.timeout = const Duration(seconds: 15),
    this.timeoutTitle = 'This is taking longer than it should',
    this.timeoutMessage = 'Check your connection. Nothing is lost.',
    this.onRetry,
  });
  @override
  State<LoadingState> createState() => _LoadingStateState();
}

class _LoadingStateState extends State<LoadingState> {
  Timer? _timer;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timedOut = false;
    _timer = Timer(widget.timeout, () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_timedOut) {
      return ErrorState(
        title: widget.timeoutTitle,
        message: widget.timeoutMessage,
        icon: Icons.hourglass_empty_rounded,
        onRetry: widget.onRetry == null
            ? null
            : () {
                setState(_arm);
                widget.onRetry!();
              },
      );
    }
    final t = Theme.of(context);
    return Center(
      child: Semantics(
        liveRegion: true,
        label: widget.message,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: Gap.m),
            Text(widget.message,
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
