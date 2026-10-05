// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../receiver/receiver_model.dart';
import 'receiver_strings.dart';
import 'receiver_name_field.dart';
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
    ).push<void>(MaterialPageRoute(builder: (_) => _TvNamePage(model: model)));
  }

  Future<void> _editVideoQuality() async {
    await _save();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => _VideoQualityPage(model: model)),
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

  Future<void> _systemSettings(String method) async {
    try {
      await const MethodChannel('tech.soit.flutterairplay/window')
          .invokeMethod<void>(method);
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
              subtitle: Text(_qualityLabel(context, model.videoQuality)),
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
              onTap: () => _systemSettings('requestBackgroundLaunch'),
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
              onTap: () => _systemSettings('openAppSettings'),
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
        if (model.platform == 'android')
          ExpansionTile(
            key: const Key('advancedSettings'),
            title: Text(l10n(context).advanced),
            tilePadding: EdgeInsets.zero,
            children: [
              TvFocus(
                outline: tv,
                child: ListTile(
                  key: const Key('audioOutput'),
                  contentPadding: EdgeInsets.zero,
                  focusNode: _audioOutputFocus,
                  title: Text(l10n(context).audioOutput),
                  subtitle: Text(_audioOutputLabel(context, model.audioOutput)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: model.editable
                      ? () async {
                          await _save();
                          if (!context.mounted) return;
                          await Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => _AudioOutputPage(model: model),
                            ),
                          );
                          if (mounted && model.isTelevision) {
                            _audioOutputFocus.requestFocus();
                          }
                        }
                      : null,
                ),
              ),
            ],
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
              l10n(context).settingsNextStart,
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

class _TvNamePage extends StatefulWidget {
  const _TvNamePage({required this.model});
  final ReceiverModel model;
  @override
  State<_TvNamePage> createState() => _TvNamePageState();
}

class _TvNamePageState extends State<_TvNamePage> {
  late final _name = TextEditingController(text: widget.model.name);
  Timer? _textSave;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(_scheduleSave);
  }

  void _scheduleSave() {
    _textSave?.cancel();
    _textSave = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    _textSave?.cancel();
    setState(() => _error = widget.model.validateName(_name.text));
    if (_error != null || _name.text.trim() == widget.model.name) return;
    await widget.model.save(_name.text, widget.model.path);
    if (mounted) setState(() => _error = widget.model.commandError);
  }

  @override
  void dispose() {
    _textSave?.cancel();
    if (_name.text.trim() != widget.model.name &&
        widget.model.validateName(_name.text) == null) {
      unawaited(widget.model.save(_name.text, widget.model.path));
    }
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(l10n(context).name)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReceiverNameField(
                controller: _name,
                television: true,
                enabled: widget.model.loaded,
                error: _error,
                onGenerated: () => setState(() => _error = null),
                onSubmitted: _save,
              ),
              const SizedBox(height: 24),
              Text(l10n(context).nextStartHelp),
            ],
          ),
        ),
      ),
    ),
  );
}

String _qualityLabel(BuildContext context, String value) => switch (value) {
  '720' => l10n(context).quality720,
  '1080' => l10n(context).quality1080,
  '1440' => l10n(context).quality1440,
  '2160' => l10n(context).quality2160,
  _ => l10n(context).qualityAuto,
};

class _VideoQualityPage extends StatefulWidget {
  const _VideoQualityPage({required this.model});
  final ReceiverModel model;
  @override
  State<_VideoQualityPage> createState() => _VideoQualityPageState();
}

class _VideoQualityPageState extends State<_VideoQualityPage> {
  Future<void> _select(String value) => widget.model.save(
    widget.model.name,
    widget.model.path,
    videoQuality: value,
  );

  Widget _qualityOption(BuildContext context, String value) {
    final model = widget.model;
    final supported = model.videoQualities.contains(value);
    final enabled = model.editable && supported;
    final title = Text(_qualityLabel(context, value));
    final subtitle = supported ? null : Text(l10n(context).qualityUnsupported);
    final autofocus = value == model.videoQuality;
    return model.isTelevision
        ? TvFocus(
            outline: true,
            child: ListTile(
              key: Key('quality$value'),
              autofocus: autofocus,
              enabled: enabled,
              title: title,
              subtitle: subtitle,
              trailing: Icon(
                value == model.videoQuality
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              selected: value == model.videoQuality,
              onTap: enabled ? () => _select(value) : null,
            ),
          )
        : RadioListTile<String>(
            key: Key('quality$value'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            value: value,
            autofocus: autofocus,
            enabled: enabled,
            title: title,
            subtitle: subtitle,
          );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      return PopScope(
        canPop: !model.busy,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!model.busy) Navigator.pop(context);
            },
            if (model.platform != 'android')
              const SingleActivator(LogicalKeyboardKey.goBack): () {
                if (!model.busy) Navigator.pop(context);
              },
          },
          child: Scaffold(
            appBar: AppBar(title: Text(l10n(context).videoQuality)),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: model.isTelevision
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(model.isTelevision ? 48 : 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          RadioGroup<String>(
                            groupValue: model.videoQuality,
                            onChanged: (value) {
                              if (value != null && model.editable) {
                                _select(value);
                              }
                            },
                            child: Column(
                              children: [
                                for (final value in const [
                                  'auto',
                                  '720',
                                  '1080',
                                  '1440',
                                  '2160',
                                ])
                                  _qualityOption(context, value),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(l10n(context).qualityHelp),
                          const SizedBox(height: 8),
                          Text(l10n(context).nextStartHelp),
                          if (model.commandError != null)
                            Text(
                              localizedMessage(context, model.commandError!),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

String _audioOutputLabel(BuildContext context, String value) => switch (value) {
  'aaudio' => l10n(context).audioOutputAAudio,
  'audiotrack' => l10n(context).audioOutputTrack,
  _ => l10n(context).audioOutputAuto,
};

class _AudioOutputPage extends StatefulWidget {
  const _AudioOutputPage({required this.model});
  final ReceiverModel model;
  @override
  State<_AudioOutputPage> createState() => _AudioOutputPageState();
}

class _AudioOutputPageState extends State<_AudioOutputPage> {
  Future<void> _select(String value) => widget.model.save(
    widget.model.name,
    widget.model.path,
    audioOutput: value,
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      return PopScope(
        canPop: !model.busy,
        child: Scaffold(
          appBar: AppBar(title: Text(l10n(context).audioOutput)),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: model.isTelevision
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(model.isTelevision ? 48 : 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        RadioGroup<String>(
                          groupValue: model.audioOutput,
                          onChanged: (value) {
                            if (value != null && model.editable) _select(value);
                          },
                          child: Column(
                            children: [
                              for (final value in const [
                                'auto',
                                'aaudio',
                                'audiotrack',
                              ])
                                model.isTelevision
                                    ? TvFocus(
                                        outline: true,
                                        child: ListTile(
                                          key: Key('audioOutput$value'),
                                          autofocus: value == model.audioOutput,
                                          enabled: model.editable,
                                          title: Text(
                                            _audioOutputLabel(context, value),
                                          ),
                                          subtitle: value == 'auto'
                                              ? Text(
                                                  l10n(context)
                                                      .audioOutputAutoHelp,
                                                )
                                              : null,
                                          trailing: Icon(
                                            value == model.audioOutput
                                                ? Icons.radio_button_checked
                                                : Icons.radio_button_unchecked,
                                          ),
                                          selected: value == model.audioOutput,
                                          onTap: model.editable
                                              ? () => _select(value)
                                              : null,
                                        ),
                                      )
                                    : RadioListTile<String>(
                                        key: Key('audioOutput$value'),
                                        contentPadding: EdgeInsets.zero,
                                        controlAffinity:
                                            ListTileControlAffinity.trailing,
                                        value: value,
                                        enabled: model.editable,
                                        title: Text(
                                          _audioOutputLabel(context, value),
                                        ),
                                        subtitle: value == 'auto'
                                            ? Text(
                                                l10n(context)
                                                    .audioOutputAutoHelp,
                                              )
                                            : null,
                                      ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(l10n(context).audioOutputRestartHelp),
                        if (model.commandError != null)
                          Text(
                            localizedMessage(context, model.commandError!),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
