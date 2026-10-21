import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

/// Prefills the configuration, base64 encoded:
/// `flutter run --dart-define=OVPN_CONFIG=$(base64 < client.ovpn)`.
const String _configFromEnvironment = String.fromEnvironment('OVPN_CONFIG');

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenVPN Flutter',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const VpnPage(),
    );
  }
}

class VpnPage extends StatefulWidget {
  const VpnPage({super.key});

  @override
  State<VpnPage> createState() => _VpnPageState();
}

class _VpnPageState extends State<VpnPage> {
  late final OpenVPN engine;
  final _config = TextEditingController(text: _decode(_configFromEnvironment));
  final _username = TextEditingController();
  final _password = TextEditingController();
  final List<VpnLog> _logs = [];
  StreamSubscription<VpnLog>? _logSubscription;

  VPNStage _stage = VPNStage.disconnected;
  VpnStatus _status = VpnStatus.empty();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    engine = OpenVPN(
      onVpnStatusChanged: (status) {
        if (status != null) setState(() => _status = status);
      },
      onVpnStageChanged: (stage, raw) {
        setState(() => _stage = stage);
        if (stage == VPNStage.error || stage == VPNStage.auth_failed) {
          engine.lastError().then((error) {
            if (mounted) setState(() => _error = error);
          });
        }
      },
    );
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await engine.initialize(
        // iOS and macOS: your App Group and Network Extension bundle identifier.
        groupIdentifier: 'group.com.laskarmedia.vpn',
        providerBundleIdentifier:
            'id.laskarmedia.openvpnFlutterExample.VPNExtension',
        localizedDescription: 'OpenVPN Flutter Example',
        lastStage: (stage) => setState(() => _stage = stage),
        lastStatus: (status) => setState(() => _status = status),
      );
      final logs = await engine.getLogs();
      setState(() => _logs.addAll(logs.reversed.take(200)));
      _logSubscription = engine.logStream.listen(
        (log) {
          setState(() {
            _logs.insert(0, log);
            if (_logs.length > 200) _logs.removeLast();
          });
        },
        onError: (Object error) => debugPrint('Log stream: $error'),
      );
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final started = await engine.connect(
        _config.text,
        'Example VPN',
        username: _username.text.isEmpty ? null : _username.text,
        password: _password.text.isEmpty ? null : _password.text,
      );
      if (!started) setState(() => _error = 'VPN permission denied');
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await engine.disconnect();
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    engine.dispose();
    _config.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final connectedOrConnecting = _stage.isConnected || _stage.isConnecting;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenVPN Flutter'),
        actions: [
          if (isAndroid)
            IconButton(
              tooltip: 'System VPN settings',
              icon: const Icon(Icons.settings_ethernet),
              onPressed: engine.openVpnSettings,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(stage: _stage, status: _status, error: _error),
          const SizedBox(height: 16),
          TextField(
            controller: _config,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              labelText: 'OpenVPN configuration (.ovpn content)',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) _config.text = data!.text!;
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: 'Username (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                key: const Key('connect'),
                onPressed: _busy || connectedOrConnecting ? null : _connect,
                icon: const Icon(Icons.vpn_lock),
                label: const Text('Connect'),
              ),
              OutlinedButton.icon(
                key: const Key('disconnect'),
                onPressed: _busy || _stage.isDisconnected ? null : _disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
              if (isAndroid)
                TextButton(
                  onPressed: () async {
                    final granted = await engine.requestPermissionAndroid();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(granted
                          ? 'VPN permission granted'
                          : 'VPN permission not granted'),
                    ));
                  },
                  child: const Text('Request permission'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Log', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final log in _logs.take(100))
            Text(
              '${log.time.toIso8601String().substring(11, 19)} ${log.message}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: log.level == VpnLogLevel.error
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  static String _decode(String base64Config) {
    if (base64Config.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(base64Config));
    } on FormatException {
      return '';
    }
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.stage, required this.status, this.error});

  final VPNStage stage;
  final VpnStatus status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = stage.isConnected
        ? Colors.green
        : stage.isConnecting
            ? Colors.orange
            : scheme.outline;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: color),
                const SizedBox(width: 8),
                Text(
                  stage.name,
                  key: const Key('stage'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                Text(status.duration ?? '00:00:00',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            Text('Down ${_bytes(status.byteIn)} (${_speed(status.speedIn)})  '
                'Up ${_bytes(status.byteOut)} (${_speed(status.speedOut)})'),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  static String _bytes(String? value) {
    var bytes = double.tryParse(value ?? '') ?? 0;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var unit = 0;
    while (bytes >= 1024 && unit < units.length - 1) {
      bytes /= 1024;
      unit++;
    }
    return '${bytes.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String _speed(int? bytesPerSecond) =>
      '${_bytes('${bytesPerSecond ?? 0}')}/s';
}
