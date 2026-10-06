// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';
import 'package:share_plus/share_plus.dart';

import '../../log_export.dart';
import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../tv_focus.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.model});
  final ReceiverModel model;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _scroll = ScrollController();
  bool _sharing = false;

  @override
  void dispose() {
    _scroll.dispose();
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

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final tv = model.isTelevision;
    return CallbackShortcuts(
      bindings: {
        // Android back keys must reach system navigation without an early pop.
        if (model.platform != 'android')
          const SingleActivator(LogicalKeyboardKey.goBack): () =>
              Navigator.pop(context),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l10n(context).logs)),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: model,
            builder: (context, _) => Padding(
              padding: EdgeInsets.all(tv ? 32 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Builder(
                        builder: (buttonContext) => TvFocus(
                          outline: tv,
                          child: FilledButton.icon(
                            key: const Key('shareLogs'),
                            autofocus: true,
                            onPressed: _sharing
                                ? null
                                : () => _share(buttonContext),
                            icon: const Icon(Icons.share),
                            label: Text(
                              _sharing
                                  ? l10n(context).exportingLogs
                                  : l10n(context).shareLogs,
                            ),
                          ),
                        ),
                      ),
                      TvFocus(
                        outline: tv,
                        child: OutlinedButton(
                          onPressed: model.logs.isEmpty
                              ? null
                              : () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: model.logText),
                                  );
                                  if (context.mounted) {
                                    _message(l10n(context).logsCopied);
                                  }
                                },
                          child: Text(l10n(context).copyLogs),
                        ),
                      ),
                      TvFocus(
                        outline: tv,
                        child: TextButton(
                          onPressed: model.logs.isEmpty
                              ? null
                              : model.clearLogs,
                          child: Text(l10n(context).clearLogView),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(l10n(context).shareLogsHelp),
                  const SizedBox(height: 16),
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: {
                        if (tv) ...{
                          const SingleActivator(
                            LogicalKeyboardKey.arrowDown,
                          ): () =>
                              _scrollBy(-100),
                          const SingleActivator(
                            LogicalKeyboardKey.arrowUp,
                          ): () =>
                              _scrollBy(100),
                        },
                      },
                      child: Focus(
                        debugLabel: 'Log list',
                        child: Scrollbar(
                          controller: _scroll,
                          thumbVisibility: model.logs.isNotEmpty,
                          child: model.logs.isEmpty
                              ? Center(child: Text(l10n(context).noLogs))
                              : ListView.builder(
                                  key: const Key('logList'),
                                  controller: _scroll,
                                  reverse: true,
                                  itemCount: model.logs.length,
                                  itemBuilder: (_, index) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 3,
                                    ),
                                    child: Text(
                                      model
                                          .logs[model.logs.length - 1 - index]
                                          .display,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 13,
                                        height: 1.6,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
