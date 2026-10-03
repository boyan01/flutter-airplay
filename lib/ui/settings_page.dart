// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver/receiver_model.dart';
import 'receiver_strings.dart';
import 'tv_focus.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.model,
    required this.editName,
    required this.onLogs,
  });
  final ReceiverModel model;
  final bool editName;
  final VoidCallback onLogs;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _name = TextEditingController(text: widget.model.name);
  late final _path = TextEditingController(text: widget.model.path);
  late bool _autoStart = widget.model.autoStart;
  late final _options = Map<String, bool>.of(widget.model.desktopOptions);
  String? _error;
  ReceiverModel get model => widget.model;
  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _error = model.validateName(_name.text));
    if (_error != null || !model.editable) return;
    await model.save(
      _name.text,
      _path.text,
      autoStart: _autoStart,
      desktopOptions: _options,
    );
    if (!mounted) return;
    if (model.commandError == null) {
      Navigator.pop(context);
    } else {
      setState(() => _error = model.commandError);
    }
  }

  Future<void> _editTvName() async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => _TvNamePage(model: model)));
    if (mounted && changed == true) setState(() => _name.text = model.name);
  }

  Widget _option(String key, String title, {bool enabled = true}) =>
      SwitchListTile(
        key: Key(key),
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        value: _options[key]!,
        onChanged: enabled && model.editable
            ? (value) => setState(() => _options[key] = value)
            : null,
      );

  Future<void> _tvAutoStart(bool value) async {
    await model.save(model.name, model.path, autoStart: value);
    if (mounted) setState(() => _autoStart = model.autoStart);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final desktop = model.platform == 'macos';
      final tv = model.isTelevision;
      final entries = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (desktop) ...[
            Text(
              l10n(context).general,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 16),
          ],
          if (tv)
            TvFocus(
              outline: tv,
              child: ListTile(
                key: const Key('tvName'),
                autofocus: true,
                title: Text(l10n(context).name),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text(model.name), const Icon(Icons.chevron_right)],
                ),
                onTap: _editTvName,
              ),
            )
          else
            TextField(
              key: const Key('receiverName'),
              controller: _name,
              autofocus: widget.editName,
              enabled: model.editable,
              decoration: InputDecoration(
                labelText: l10n(context).name,
                helperText: l10n(context).nameHelp,
                helperMaxLines: 2,
                errorText: _error == null
                    ? null
                    : localizedMessage(context, _error!),
              ),
              onSubmitted: (_) => _save(),
            ),
          const SizedBox(height: 12),
          if (tv)
            TvFocus(
              outline: true,
              child: SwitchListTile(
                key: const Key('autoStart'),
                title: Text(l10n(context).autoStart),
                value: model.autoStart,
                onChanged: model.editable ? _tvAutoStart : null,
              ),
            )
          else
            SwitchListTile(
              key: const Key('autoStart'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n(context).autoStart),
              value: _autoStart,
              onChanged: model.editable
                  ? (value) => setState(() => _autoStart = value)
                  : null,
            ),
          if (desktop) ...[
            _option(
              'launchAtLogin',
              l10n(context).launchAtLogin,
              enabled: model.supportsLaunchAtLogin,
            ),
            if (!model.supportsLaunchAtLogin)
              Text(
                l10n(context).loginUnavailable,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            _option('keepInMenuBar', l10n(context).keepInMenuBar),
            const SizedBox(height: 20),
            Text(
              l10n(context).playback,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            _option('showOnConnect', l10n(context).showOnConnect),
            _option('fullscreenOnConnect', l10n(context).fullscreenOnConnect),
            _option('alwaysOnTop', l10n(context).alwaysOnTop),
          ],
          if (model.active && !tv)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n(context).restartHelp,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (model.supportsExecutablePath)
            ExpansionTile(
              title: Text(l10n(context).advanced),
              tilePadding: EdgeInsets.zero,
              children: [
                TextField(
                  key: const Key('receiverPath'),
                  controller: _path,
                  enabled: model.editable,
                  decoration: InputDecoration(
                    labelText: l10n(context).path,
                    helperText: l10n(context).pathHelp,
                    helperMaxLines: 2,
                  ),
                ),
                TextButton(
                  onPressed: model.canStart
                      ? () => model.check(_path.text)
                      : null,
                  child: Text(l10n(context).check),
                ),
              ],
            ),
          if (model.commandError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                localizedMessage(context, model.commandError!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!desktop) ...[
            TvFocus(
              outline: tv,
              child: ListTile(
                title: Text(l10n(context).logs),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => widget.onLogs(),
                  );
                },
              ),
            ),
            TvFocus(
              outline: tv,
              child: ListTile(
                title: Text(l10n(context).licenses),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Flutter AirPlay',
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (desktop)
            TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Flutter AirPlay',
              ),
              child: Text(
                'UxPlay + C++ · GPLv3 · ${l10n(context).licenses}',
              ),
            )
          else
            Text(
              'UxPlay · GPLv3',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      );
      final actions = Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          children: [
            TextButton(
              onPressed: model.busy ? null : () => Navigator.pop(context),
              child: Text(l10n(context).cancel),
            ),
            FilledButton(
              onPressed: model.editable ? _save : null,
              child: Text(
                model.busy ? l10n(context).saving : l10n(context).done,
              ),
            ),
          ],
        ),
      );
      final content = desktop
          ? Material(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(16),
              ),
              elevation: 12,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n(context).settings,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: entries,
                    ),
                  ),
                  actions,
                ],
              ),
            )
          : Scaffold(
              appBar: AppBar(title: Text(l10n(context).settings)),
              body: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(tv ? 48 : 24),
                      child: entries,
                    ),
                  ),
                  if (!tv) actions,
                ],
              ),
            );
      return PopScope(
        canPop: !model.busy,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!model.busy) Navigator.pop(context);
            },
            const SingleActivator(LogicalKeyboardKey.goBack): () {
              if (!model.busy) Navigator.pop(context);
            },
          },
          child: content,
        ),
      );
    },
  );
}

class _TvNamePage extends StatefulWidget {
  const _TvNamePage({required this.model});
  final ReceiverModel model;
  @override
  State<_TvNamePage> createState() => _TvNamePageState();
}

class _TvNamePageState extends State<_TvNamePage> {
  late final _name = TextEditingController(text: widget.model.name);
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() => _error = widget.model.validateName(_name.text));
    if (_error != null) return;
    await widget.model.save(_name.text, widget.model.path);
    if (!mounted) return;
    if (widget.model.commandError == null) {
      Navigator.pop(context, true);
    } else {
      setState(() => _error = widget.model.commandError);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(l10n(context).name)),
      body: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('receiverName'),
              controller: _name,
              autofocus: true,
              enabled: !widget.model.busy,
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                labelText: l10n(context).name,
                helperText: l10n(context).nameHelp,
                errorText: _error == null
                    ? null
                    : localizedMessage(context, _error!),
              ),
            ),
            const SizedBox(height: 24),
            TvFocus(
              child: FilledButton(
                onPressed: widget.model.editable ? _confirm : null,
                child: Text(l10n(context).confirm),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
