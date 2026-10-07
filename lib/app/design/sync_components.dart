import 'package:flutter/material.dart';

import 'sync_theme.dart';

/// Consistent page frame used by the three top-level modules.
class SyncTunePageScaffold extends StatelessWidget {
  const SyncTunePageScaffold({
    required this.title,
    required this.body,
    super.key,
    this.actions,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(title: Text(title), floating: true, actions: actions),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            SyncTuneTokens.space24,
            SyncTuneTokens.space16,
            SyncTuneTokens.space24,
            SyncTuneTokens.space32,
          ),
          sliver: SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SyncTuneTokens.contentMaxWidth,
                ),
                child: body,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class SyncTuneSection extends StatelessWidget {
  const SyncTuneSection({
    required this.title,
    required this.child,
    super.key,
    this.description,
  });

  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: textTheme.headlineSmall),
        if (description != null) ...[
          const SizedBox(height: SyncTuneTokens.space8),
          Text(description!),
        ],
        const SizedBox(height: SyncTuneTokens.space16),
        child,
      ],
    );
  }
}

enum SyncTuneStatusTone { neutral, positive, warning, error }

class SyncTuneStatusCard extends StatelessWidget {
  const SyncTuneStatusCard({
    required this.title,
    required this.message,
    required this.icon,
    super.key,
    this.tone = SyncTuneStatusTone.neutral,
    this.action,
  });

  final String title;
  final String message;
  final IconData icon;
  final SyncTuneStatusTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (tone) {
      SyncTuneStatusTone.neutral => colors.onSurfaceVariant,
      SyncTuneStatusTone.positive => colors.primary,
      SyncTuneStatusTone.warning => colors.tertiary,
      SyncTuneStatusTone.error => colors.error,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(SyncTuneTokens.space16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: SyncTuneTokens.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: SyncTuneTokens.space4),
                  Text(message),
                  if (action != null) ...[
                    const SizedBox(height: SyncTuneTokens.space12),
                    Align(alignment: Alignment.centerLeft, child: action!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SyncTuneKeyValue extends StatelessWidget {
  const SyncTuneKeyValue({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label：$value',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SyncTuneTokens.space4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 100, child: Text(label)),
            Expanded(child: SelectableText(value)),
          ],
        ),
      ),
    );
  }
}
