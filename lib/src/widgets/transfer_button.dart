import 'package:flutter/material.dart';

import '../models.dart';
import '../transfer.dart';

/// An adaptive action button for a [Transfer].
///
/// Dynamically toggles between Pause, Resume, Retry, and Complete actions
/// based on the transfer's current [TaskStatus].
class TransferButton extends StatelessWidget {
  /// The [Transfer] to control.
  final Transfer transfer;

  /// Icon size in logical pixels (defaults to `24.0`).
  final double iconSize;

  /// Padding around the icon button.
  final EdgeInsetsGeometry padding;

  /// Color override for the icon.
  final Color? color;

  /// Creates a reactive [TransferButton].
  const TransferButton({
    super.key,
    required this.transfer,
    this.iconSize = 24.0,
    this.padding = const EdgeInsets.all(8.0),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<TaskStatus>(
      valueListenable: transfer.statusNotifier,
      builder: (context, status, _) {
        switch (status) {
          case TaskStatus.running:
          case TaskStatus.enqueued:
            return IconButton(
              icon: Icon(Icons.pause_circle_outline, size: iconSize),
              color: color ?? theme.colorScheme.primary,
              padding: padding,
              tooltip: 'Pause',
              onPressed: () => transfer.pause(),
            );

          case TaskStatus.paused:
          case TaskStatus.waitingToRetry:
            return IconButton(
              icon: Icon(Icons.play_circle_outline, size: iconSize),
              color: color ?? Colors.orange,
              padding: padding,
              tooltip: 'Resume',
              onPressed: () => transfer.resume(),
            );

          case TaskStatus.failed:
          case TaskStatus.notFound:
            return IconButton(
              icon: Icon(Icons.refresh, size: iconSize),
              color: color ?? theme.colorScheme.error,
              padding: padding,
              tooltip: 'Retry',
              onPressed: () => transfer.resume(),
            );

          case TaskStatus.complete:
            return Icon(
              Icons.check_circle,
              size: iconSize,
              color: color ?? Colors.green,
            );

          case TaskStatus.canceled:
            return IconButton(
              icon: Icon(Icons.replay, size: iconSize),
              color: color ?? theme.colorScheme.outline,
              padding: padding,
              tooltip: 'Restart',
              onPressed: () => transfer.resume(),
            );
        }
      },
    );
  }
}

/// Alias for [TransferButton] for backward compatibility
typedef FileTransferButton = TransferButton;
