// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';
import 'package:share_plus/share_plus.dart';

import '../../log_export.dart';
import '../../receiver/receiver_model.dart';
import '../../receiver/receiver_state.dart';
import '../widgets/receiver_strings.dart';
import '../tv_focus.dart';
import '../receiver_back.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.model});
  final ReceiverModel model;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _scroll = ScrollController();
  final _shareFocus = FocusNode(debugLabel: 'Share logs');
  bool _sharing = false;

  @override
  void dispose() {
    _scroll.dispose();
    _shareFocus.dispose();
    super.dispose();
  }

  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _sharing = true);
    try {
      final file = await exportLogs(widget.model);
      if (!mounted) return;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          title: 'Flutter AirPlay logs',
          sharePositionOrigin: origin,
        ),
      );
      if (mounted && result.status == ShareResultStatus.unavailable) {
        _message(l10n(context).shareLogsUnavailable);
      }
    } catch (error, stack) {
      e('Log export/share failed', error, stack);
      if (mounted) _message(l10n(context).shareLogsFailed);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _scrollBy(double amount) {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(
      (_scroll.offset + amount).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  Widget _actions(BuildContext context) {
    final model = widget.model;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TvFocus(
          child: TextButton.icon(
            onPressed: model.logs.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: model.logText));
                    if (context.mounted) _message(l10n(context).logsCopied);
                  },
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: Text(l10n(context).copyLogs),
          ),
        ),
        TvFocus(
          child: TextButton.icon(
            onPressed: model.logs.isEmpty ? null : model.clearLogs,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            label: Text(l10n(context).clearLogView),
          ),
        ),
        Builder(
          builder: (buttonContext) => TvFocus(
            child: FilledButton.icon(
              key: const Key('shareLogs'),
              focusNode: _shareFocus,
              autofocus: true,
              onPressed: _sharing ? null : () => _share(buttonContext),
              icon: _sharing
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : const Icon(Icons.ios_share_rounded, size: 20),
              label: Text(
                _sharing
                    ? l10n(context).exportingLogs
                    : l10n(context).shareLogs,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, {required bool compact}) {
    final title = Row(
      children: [
        const TvFocus(child: BackButton()),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            l10n(context).logs,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    return compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 16), _actions(context)],
          )
        : Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 24),
              _actions(context),
            ],
          );
  }

  Widget _entry(
    BuildContext context,
    ReceiverLog entry, {
    required bool compact,
  }) {
    final tv = widget.model.isTelevision;
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: tv ? 16 : 13,
      height: 1.65,
      color: colors.onSurface,
    );
    final time = Text(
      entry.time.length >= 19 ? entry.time.substring(11, 19) : entry.time,
      style: style.copyWith(color: colors.onSurfaceVariant),
    );
    final message = Text(entry.text, style: style);
    return Semantics(
      label: entry.display,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: tv ? 24 : 16,
          vertical: tv ? 14 : 10,
        ),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .35),
            ),
          ),
        ),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [time, const SizedBox(height: 4), message],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  time,
                  SizedBox(width: tv ? 24 : 20),
                  Expanded(child: message),
                ],
              ),
      ),
    );
  }

  Widget _logView(BuildContext context, {required bool compact}) {
    final model = widget.model;
    final tv = model.isTelevision;
    final colors = Theme.of(context).colorScheme;
    return TvFocus(
      borderRadius: BorderRadius.circular(16),
      child: CallbackShortcuts(
        bindings: {
          if (tv) ...{
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _scrollBy(-100),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _scrollBy(100),
            const SingleActivator(LogicalKeyboardKey.arrowLeft):
                _shareFocus.requestFocus,
            const SingleActivator(LogicalKeyboardKey.arrowRight):
                _shareFocus.requestFocus,
          },
        },
        child: Focus(
          debugLabel: 'Log list',
          descendantsAreFocusable: !tv,
          child: Container(
            key: const Key('logPanel'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .6),
              ),
            ),
            child: model.logs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: tv ? 40 : 32,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n(context).noLogs,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                : Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      key: const Key('logList'),
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      reverse: true,
                      itemCount: model.logs.length,
                      itemBuilder: (_, index) => _entry(
                        context,
                        model.logs[model.logs.length - 1 - index],
                        compact: compact,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final tv = model.isTelevision;
    return CallbackShortcuts(
      bindings: receiverBackShortcuts(
        model.platform,
        () => Navigator.pop(context),
      ),
      child: Scaffold(
        body: SafeArea(
          child: ListenableBuilder(
            listenable: model,
            builder: (context, _) => LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final inset = constraints.maxWidth < 600
                    ? 16.0
                    : tv
                    ? 32.0
                    : 24.0;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    inset,
                    tv ? 24 : 16,
                    inset,
                    inset,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(
                        context,
                        compact:
                            constraints.maxWidth < (tv ? 900 : 720) * scale,
                      ),
                      SizedBox(height: tv ? 24 : 20),
                      Expanded(
                        child: _logView(
                          context,
                          compact: constraints.maxWidth < 480 * scale,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
