// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../receiver/receiver_model.dart';
import '../../platform/window_controller.dart';
import '../widgets/receiver_strings.dart';
import '../widgets/receiver_name_field.dart';
import '../tv_focus.dart';

import 'tv_name_page.dart';

import 'video_quality_page.dart';

import 'audio_output_page.dart';

import 'settings_labels.dart';

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
  final _qualityFocus = FocusNode();
  final _audioOutputFocus = FocusNode();
  Timer? _textSave;
  String? _error;
  String? _systemSettingsError;
  ReceiverModel get model => widget.model;
  String get _localBuildTime {
    final time = DateTime.tryParse(model.buildTime);
    return time == null
        ? model.buildTime
        : DateFormat('yyyy-MM-dd HH:mm:ss').format(time.toLocal());
  }

  @override
  void initState() {
    super.initState();
    _name.addListener(_scheduleSave);
    _path.addListener(_scheduleSave);
  }

  void _scheduleSave() {
    _textSave?.cancel();
    _textSave = Timer(const Duration(milliseconds: 600), _save);
  }

  @override
  void dispose() {
    _textSave?.cancel();
    if (!model.isTelevision &&
        (_name.text.trim() != model.name || _path.text.trim() != model.path) &&
        model.validateName(_name.text) == null) {
      unawaited(model.save(_name.text, _path.text));
    }
    _name.dispose();
    _path.dispose();
    _qualityFocus.dispose();
    _audioOutputFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _textSave?.cancel();
    setState(() => _error = model.validateName(_name.text));
    final nextName = !model.isTelevision && _error == null
        ? _name.text
        : model.name;
    final optionsChanged = _options.entries.any(
      (entry) => model.desktopOptions[entry.key] != entry.value,
    );
    if (nextName.trim() == model.name &&
        _path.text.trim() == model.path &&
        _autoStart == model.autoStart &&
        !optionsChanged) {
      return;
    }
    await model.save(
      nextName,
      _path.text,
      autoStart: _autoStart,
      desktopOptions: _options,
    );
    if (mounted && model.commandError != null) {
      setState(() {
        _error = model.commandError;
        _autoStart = model.autoStart;
        _options.addAll(model.desktopOptions);
      });
    }
  }

  Future<void> _editTvName() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => TvNamePage(model: model)));
  }

  Future<void> _editVideoQuality() async {
    await _save();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => VideoQualityPage(model: model)),
    );
    if (mounted && model.isTelevision) _qualityFocus.requestFocus();
  }

  Widget _option(String key, String title, {bool enabled = true}) =>
      SwitchListTile(
        key: Key(key),
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        value: _options[key]!,
        onChanged: enabled && model.editable
            ? (value) {
                setState(() => _options[key] = value);
                _save();
              }
            : null,
      );

  Future<void> _tvAutoStart(bool value) async {
    await model.save(model.name, model.path, autoStart: value);
    if (mounted) setState(() => _autoStart = model.autoStart);
  }

  Future<void> _systemSettings(WindowCommand command) async {
    try {
      await const WindowController().execute(command);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _systemSettingsError = error.message);
    }
  }

  Widget _settingsGroup(
    BuildContext context,
    String? title,
    List<Widget> children,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final desktop = model.supportsWindowPreferences;
      final tv = model.isTelevision;
      final generalEntries = <Widget>[
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
          ReceiverNameField(
            controller: _name,
            defaultName: model.defaultName,
            autofocus: widget.editName,
            enabled: model.loaded,
            error: _error,
            onGenerated: () => setState(() => _error = null),
            onSubmitted: _save,
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
                ? (value) {
                    setState(() => _autoStart = value);
                    _save();
                  }
                : null,
          ),
        if (desktop) ...[
          _option(
            'launchAtLogin',
            l10n(context).launchAtLogin,
            enabled: model.supportsLaunchAtLogin,
          ),
          if (!model.supportsLaunchAtLogin && model.platform == 'macos')
            Text(
              l10n(context).loginUnavailable,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          _option(
            'keepInMenuBar',
            model.platform != 'macos'
                ? l10n(context).keepInTray
                : l10n(context).keepInMenuBar,
          ),
        ],
      ];
      final playbackEntries = <Widget>[
        if (desktop) ...[
          _option('showOnConnect', l10n(context).showOnConnect),
          _option('fullscreenOnConnect', l10n(context).fullscreenOnConnect),
          _option('alwaysOnTop', l10n(context).alwaysOnTop),
        ],
        if (model.supportsVideoQuality) ...[
          TvFocus(
            outline: tv,
            child: ListTile(
              key: const Key('videoQuality'),
              focusNode: _qualityFocus,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n(context).videoQuality),
              subtitle: Text(qualityLabel(context, model.videoQuality)),
              trailing: const Icon(Icons.chevron_right),
              onTap: model.editable ? _editVideoQuality : null,
            ),
          ),
          Text(
            '${l10n(context).screenSize}: ${model.screenWidth} × ${model.screenHeight}',
          ),
          Text(
            '${l10n(context).receivedSize}: ${model.hasVideo ? '${model.videoWidth} × ${model.videoHeight}' : l10n(context).noReceivedVideo}',
          ),
          const SizedBox(height: 12),
        ],
      ];
      final systemEntries = <Widget>[
        if (model.platform == 'android') ...[
          TvFocus(
            outline: tv,
            child: ListTile(
              key: const Key('backgroundLaunch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n(context).backgroundLaunch),
              subtitle: Text(l10n(context).backgroundLaunchHelp),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  _systemSettings(WindowCommand.requestBackgroundLaunch),
            ),
          ),
          TvFocus(
            outline: tv,
            child: ListTile(
              key: const Key('appPermissions'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n(context).appPermissions),
              subtitle: Text(l10n(context).appPermissionsHelp),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _systemSettings(WindowCommand.openAppSettings),
            ),
          ),
        ],
        if (_systemSettingsError != null && model.platform == 'android')
          Text(
            _systemSettingsError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ];
      final advancedEntries = <Widget>[
        ExpansionTile(
          key: const Key('advancedSettings'),
          title: Text(l10n(context).advanced),
          tilePadding: EdgeInsets.zero,
          children: [
            TvFocus(
              outline: tv,
              child: SwitchListTile(
                key: const Key('fastPairing'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n(context).fastPairing),
                subtitle: Text(l10n(context).fastPairingHelp),
                value: model.fastPairing,
                onChanged: model.editable
                    ? (value) async {
                        await _save();
                        if (!mounted) return;
                        await model.save(
                          model.name,
                          model.path,
                          fastPairing: value,
                        );
                      }
                    : null,
              ),
            ),
            if (model.platform == 'android')
              TvFocus(
                outline: tv,
                child: ListTile(
                  key: const Key('audioOutput'),
                  contentPadding: EdgeInsets.zero,
                  focusNode: _audioOutputFocus,
                  title: Text(l10n(context).audioOutput),
                  subtitle: Text(audioOutputLabel(context, model.audioOutput)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: model.editable
                      ? () async {
                          await _save();
                          if (!context.mounted) return;
                          await Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => AudioOutputPage(model: model),
                            ),
                          );
                          if (mounted && model.isTelevision) {
                            _audioOutputFocus.requestFocus();
                          }
                        }
                      : null,
                ),
              ),
            if (model.supportsExecutablePath) ...[
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
          ],
        ),
      ];
      final aboutEntries = <Widget>[
        if (model.buildVersion.isNotEmpty || model.buildTime.isNotEmpty)
          ListTile(
            key: const Key('buildInfo'),
            contentPadding: EdgeInsets.zero,
            title: model.buildVersion.isEmpty
                ? null
                : Text('${l10n(context).buildVersion}: ${model.buildVersion}'),
            subtitle: model.buildTime.isEmpty
                ? null
                : Text('${l10n(context).buildTime}: $_localBuildTime'),
          ),
        if (!desktop)
          TvFocus(
            outline: tv,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
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
            contentPadding: EdgeInsets.zero,
            title: Text(l10n(context).licenses),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Flutter AirPlay',
            ),
          ),
        ),
      ];
      final entries = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (desktop) ...[
            _settingsGroup(context, l10n(context).general, generalEntries),
            _settingsGroup(context, l10n(context).playback, playbackEntries),
            if (advancedEntries.isNotEmpty)
              _settingsGroup(context, null, advancedEntries),
          ] else ...[
            ...generalEntries,
            ...playbackEntries,
            ...systemEntries,
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n(context).settingsApplyHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (!desktop) ...advancedEntries,
          if (model.commandError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                localizedMessage(context, model.commandError!),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (desktop)
            _settingsGroup(context, l10n(context).about, aboutEntries)
          else
            ...aboutEntries,
        ],
      );
      final content = desktop
          ? Material(
              elevation: 12,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n(context).settings,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          key: const Key('closeSettings'),
                          tooltip: l10n(context).close,
                          onPressed: model.busy
                              ? null
                              : () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                      child: entries,
                    ),
                  ),
                ],
              ),
            )
          : Scaffold(
              appBar: AppBar(title: Text(l10n(context).settings)),
              body: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(tv ? 48 : 24),
                        child: entries,
                      ),
                    ),
                  ],
                ),
              ),
            );
      return PopScope(
        canPop: !model.busy,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!model.busy) Navigator.pop(context);
            },
            // Android back keys must reach system navigation without an early pop.
            if (model.platform != 'android')
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
