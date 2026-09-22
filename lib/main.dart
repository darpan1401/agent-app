import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BridgeApp());
}

class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alexa Device Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  IO.Socket? socket;

  final serverUrlController = TextEditingController();
  final secretController = TextEditingController();
  final deviceNameController = TextEditingController();

  static const defaultServerUrl = 'https://agentbackend-5nca.onrender.com';

  bool showSecret = false;

  // Permission keys and labels
  final Map<String, String> permissionLabels = {
    'open_url': 'Open URLs',
    'open_app': 'Open Apps',
    'start_music': 'Start Music',
    'lock_pc': 'Lock PC',
    'shutdown_pc': 'Shutdown PC',
    'restart_pc': 'Restart PC',
    'notifications': 'Read Notifications',
    'battery': 'Battery Status',
  };

  // Current permission state (loaded/saved)
  Map<String, bool> permissions = {};

  bool connected = false;
  bool registered = false;
  bool connecting = false;

  String statusMessage = 'Not connected';

  final List<String> logs = [];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    socket?.dispose();
    serverUrlController.dispose();
    secretController.dispose();
    deviceNameController.dispose();
    super.dispose();
  }

  // ============================================================
  // PLATFORM
  // ============================================================

  String platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  String platformDisplayName() {
    switch (platformName()) {
      case 'windows':
        return 'Windows PC';
      case 'linux':
        return 'Ubuntu/Linux PC';
      case 'macos':
        return 'macOS';
      case 'android':
        return 'Android Phone';
      case 'ios':
        return 'iPhone/iPad';
      default:
        return 'Device';
    }
  }

  String defaultDeviceName() {
    return 'My ${platformDisplayName()}';
  }

  // ============================================================
  // CONFIG
  // ============================================================

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();

    serverUrlController.text = prefs.getString('serverUrl') ?? defaultServerUrl;

    secretController.text = prefs.getString('secret') ?? '';

    // load permissions
    permissions = {};
    for (final key in permissionLabels.keys) {
      permissions[key] = prefs.getBool('perm_$key') ?? true;
    }

    deviceNameController.text =
        prefs.getString('deviceName') ?? defaultDeviceName();

    _log('Platform detected: ${platformDisplayName()}');

    if (mounted) setState(() {});
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'serverUrl',
      serverUrlController.text.trim(),
    );

    await prefs.setString(
      'secret',
      secretController.text.trim(),
    );

    await prefs.setString(
      'deviceName',
      deviceNameController.text.trim(),
    );

    // save permissions
    for (final entry in permissions.entries) {
      await prefs.setBool('perm_${entry.key}', entry.value);
    }
  }

  // ============================================================
  // LOGGING
  // ============================================================

  void _log(String message) {
    final line =
        '${DateTime.now().toIso8601String().substring(11, 19)}  $message';

    debugPrint('[BRIDGE] $line');

    if (!mounted) return;

    setState(() {
      logs.insert(0, line);
      if (logs.length > 200) {
        logs.removeLast();
      }
    });
  }

  void _logError(String message, Object error) {
    _log('❌ $message: $error');
    debugPrintStack(stackTrace: StackTrace.current);
  }

  // ============================================================
  // SOCKET CONNECT
  // ============================================================

  Future<void> _connect() async {
    var connectUrl = serverUrlController.text.trim();

    if (connectUrl.isEmpty) {
      _log('⚠️ Server URL is empty');
      return;
    }

    if (!connectUrl.startsWith('https://')) {
      _log('⚠️ Server URL must start with https://');
      return;
    }

    // Remove trailing slash
    connectUrl = connectUrl.replaceFirst(RegExp(r'/+$'), '');

    // Migrate old Render host
    if (connectUrl.contains('agentbackend-x3s2.onrender.com')) {
      connectUrl = defaultServerUrl;
      serverUrlController.text = connectUrl;
      await _saveConfig();

      _log('⚙️ Server URL migrated to: $connectUrl');
    }

    final secret = secretController.text.trim();
    final deviceName = deviceNameController.text.trim();

    if (secret.isEmpty) {
      _log('⚠️ Shared Secret is empty');
      return;
    }

    if (deviceName.isEmpty) {
      _log('⚠️ Device name is empty');
      return;
    }

    await _saveConfig();

    _disconnectInternal();

    if (mounted) {
      setState(() {
        connecting = true;
        connected = false;
        registered = false;
        statusMessage = 'Connecting...';
      });
    }

    _log('🌐 Server: $connectUrl');
    _log('📱 Device: $deviceName');
    _log('🖥️ Platform: ${platformName()}');
    _log('🔌 Creating Socket.IO connection...');

    try {
      // DNS diagnostic
      final uri = Uri.parse(connectUrl);

      _log('🔎 DNS lookup: ${uri.host}');

      final addresses = await InternetAddress.lookup(uri.host);

      if (addresses.isEmpty) {
        throw const SocketException('DNS returned no addresses');
      }

      _log('✅ DNS resolved: ${addresses.first.address}');

      socket = IO.io(
        connectUrl,
        <String, dynamic>{
          'transports': ['websocket'],
          'path': '/socket.io',
          'autoConnect': false,
          'reconnection': true,
          'reconnectionAttempts': 20,
          'reconnectionDelay': 2000,
          'reconnectionDelayMax': 10000,
          'timeout': 30000,
          'secure': true,
          'forceNew': true,
        },
      );

      socket!.onConnect((_) {
        _log('✅ Socket.IO connected');
        _log('🆔 Socket ID: ${socket?.id}');

        if (mounted) {
          setState(() {
            connecting = false;
            connected = true;
            statusMessage = 'Connected - Registering...';
          });
        }

        _register();
      });

      socket!.on('registered', (data) {
        _log('✅ DEVICE REGISTERED');
        _log('📡 Server response: $data');

        if (mounted) {
          setState(() {
            connecting = false;
            connected = true;
            registered = true;
            statusMessage = '✅ Connected to Alexa Bridge';
          });
        }
      });

      socket!.on('register_failed', (data) {
        final reason = _extractReason(data);

        _log('❌ Registration failed: $reason');

        if (mounted) {
          setState(() {
            connecting = false;
            connected = false;
            registered = false;
            statusMessage = '❌ Registration failed';
          });
        }
      });

      socket!.onConnectError((error) {
        _log('❌ Socket connection error: $error');

        if (mounted) {
          setState(() {
            connected = false;
            registered = false;
            connecting = false;
            statusMessage = '❌ Connection error';
          });
        }
      });

      socket!.onError((error) {
        _log('❌ Socket error: $error');
      });

      socket!.on('command', _receiveCommand);

      socket!.onDisconnect((reason) {
        _log('🔴 Socket disconnected: $reason');

        if (mounted) {
          setState(() {
            connected = false;
            registered = false;
            connecting = false;
            statusMessage = 'Disconnected';
          });
        }
      });

      socket!.onReconnectAttempt((attempt) {
        _log('🔄 Reconnect attempt: $attempt');
      });

      socket!.onReconnect((attempt) {
        _log('✅ Reconnected after attempt: $attempt');
      });

      socket!.onReconnectError((error) {
        _log('❌ Reconnect error: $error');
      });

      socket!.connect();
    } catch (e) {
      _logError('Failed to create Socket.IO connection', e);

      if (mounted) {
        setState(() {
          connecting = false;
          connected = false;
          registered = false;
          statusMessage = '❌ Connection failed';
        });
      }
    }
  }

  void _register() {
    final secret = secretController.text.trim();
    final deviceName = deviceNameController.text.trim();

    _log('📡 Sending register event...');

    // include enabled permissions when registering
    final enabled = permissions.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toList();

    socket?.emit(
      'register',
      {
        'secret': secret,
        'deviceName': deviceName,
        'platform': platformName(),
        'platformDisplayName': platformDisplayName(),
        'permissions': enabled,
      },
    );
  }

  // ============================================================
  // COMMAND RECEIVER
  // ============================================================

  Future<void> _receiveCommand(dynamic data) async {
    _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    _log('📥 ALEXA COMMAND RECEIVED');
    _log('Raw command: $data');

    try {
      if (data is! Map) {
        _log('⚠️ Invalid command format');
        return;
      }

      final commandId = data['commandId']?.toString();
      final type = data['type']?.toString() ?? 'unknown';

      final payload = data['payload'] is Map
          ? Map<String, dynamic>.from(data['payload'])
          : <String, dynamic>{};

      _log('Command ID: $commandId');
      _log('Command type: $type');
      _log('Payload: $payload');

      final result = await _handleCommand(type, payload);

      _log('📤 COMMAND RESULT: $result');

      socket?.emit(
        'command_result',
        {
          'commandId': commandId,
          'result': result,
        },
      );

      _log('✅ Result sent to Render');
    } catch (e) {
      _logError('Command processing error', e);

      socket?.emit(
        'command_result',
        {
          'commandId': data is Map ? data['commandId'] : null,
          'result': {
            'success': false,
            'speech': 'Sorry, the device could not execute that command.',
            'error': e.toString(),
          },
        },
      );
    }

    _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }

  // ============================================================
  // COMMAND ROUTER
  // ============================================================

  String? _permissionForCommand(String type) {
    switch (type) {
      case 'open_chrome':
      case 'open_vscode':
      case 'open_chatgpt':
        return 'open_app';
      case 'open_url':
        return 'open_url';
      case 'open_app':
        return 'open_app';
      case 'start_music':
        return 'start_music';
      case 'lock_pc':
        return 'lock_pc';
      case 'shutdown_pc':
        return 'shutdown_pc';
      case 'restart_pc':
        return 'restart_pc';
      case 'check_notifications':
        return 'notifications';
      case 'battery_status':
        return 'battery';
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _handleCommand(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final permission = _permissionForCommand(type);
    if (permission != null && !(permissions[permission] ?? false)) {
      return {
        'success': false,
        'speech': 'That command is disabled in this device permissions settings.',
      };
    }

    switch (type) {
      case 'ping':
        return {
          'success': true,
          'speech': 'Your device is online and responding.',
          'platform': platformName(),
          'deviceName': deviceNameController.text.trim(),
        };

      case 'open_chrome':
        return _openChrome();

      case 'open_vscode':
        return _openVSCode();

      case 'open_chatgpt':
        return _openUrl(
          'https://chatgpt.com',
          'ChatGPT',
        );

      case 'start_music':
        return _startMusic();

      case 'lock_pc':
        return _lockDevice();

      case 'shutdown_pc':
        return _shutdownDevice();

      case 'restart_pc':
        return _restartDevice();

      case 'open_url':
        final url = payload['url']?.toString() ?? '';
        if (url.isEmpty) {
          return {
            'success': false,
            'speech': 'No URL was provided.',
          };
        }
        return _openUrl(url, 'the requested website');

      case 'open_app':
        final app = payload['app']?.toString() ?? '';
        return _openAllowedApp(app);

      case 'check_notifications':
        return {
          'success': true,
          'speech':
              'Notification reading is not configured on this device yet.',
        };

      case 'battery_status':
        return {
          'success': true,
          'speech': 'Battery status is not configured on this device yet.',
        };

      default:
        return {
          'success': false,
          'speech': 'Unknown command: $type',
        };
    }
  }

  // ============================================================
  // URL OPENING - ALL PLATFORMS
  // ============================================================

  Future<Map<String, dynamic>> _openUrl(
    String url,
    String name,
  ) async {
    try {
      final uri = Uri.tryParse(url);

      if (uri == null) {
        return {
          'success': false,
          'speech': 'The URL is invalid.',
        };
      }

      _log('🌐 Opening $url');

      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!opened) {
        _log('❌ Could not open URL');

        return {
          'success': false,
          'speech': 'I could not open $name.',
        };
      }

      _log('✅ Opened $name');

      return {
        'success': true,
        'speech': 'Opening $name.',
      };
    } catch (e) {
      _logError('URL opening failed', e);

      return {
        'success': false,
        'speech': 'I could not open $name.',
        'error': e.toString(),
      };
    }
  }

  // ============================================================
  // CHROME
  // ============================================================

  Future<Map<String, dynamic>> _openChrome() async {
    // Windows/Linux/macOS: try native Chrome first.
    if (Platform.isWindows) {
      try {
        await Process.start(
          'cmd',
          ['/c', 'start', '', 'chrome'],
          runInShell: true,
        );

        _log('🌐 Chrome launched on Windows');

        return {
          'success': true,
          'speech': 'Opening Chrome.',
        };
      } catch (e) {
        _log('⚠️ Windows Chrome executable failed, using browser fallback');
      }
    }

    if (Platform.isLinux) {
      try {
        await Process.start(
          'google-chrome',
          [],
          runInShell: true,
        );

        _log('🌐 Chrome launched on Linux');

        return {
          'success': true,
          'speech': 'Opening Chrome.',
        };
      } catch (e) {
        _log('⚠️ Linux Chrome executable failed, using browser fallback');
      }
    }

    if (Platform.isMacOS) {
      try {
        await Process.start(
          'open',
          ['-a', 'Google Chrome'],
          runInShell: true,
        );

        _log('🌐 Chrome launched on macOS');

        return {
          'success': true,
          'speech': 'Opening Chrome.',
        };
      } catch (e) {
        _log('⚠️ macOS Chrome executable failed, using browser fallback');
      }
    }

    // Android/iOS, and PC fallback.
    return _openUrl(
      'https://www.google.com',
      'your browser',
    );
  }

  // ============================================================
  // VS CODE
  // ============================================================

  Future<Map<String, dynamic>> _openVSCode() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.start(
          'code',
          [],
          runInShell: true,
        );

        _log('💻 VS Code launched');

        return {
          'success': true,
          'speech': 'Opening Visual Studio Code.',
        };
      } catch (e) {
        _logError('VS Code executable not found', e);

        return {
          'success': false,
          'speech': 'Visual Studio Code is not available on this computer.',
        };
      }
    }

    return {
      'success': false,
      'speech':
          'Visual Studio Code is a computer application and is not configured for this phone.',
    };
  }

  // ============================================================
  // MUSIC
  // ============================================================

  Future<Map<String, dynamic>> _startMusic() {
    return _openUrl(
      'https://music.youtube.com',
      'YouTube Music',
    );
  }

  // ============================================================
  // LOCK
  // ============================================================

  Future<Map<String, dynamic>> _lockDevice() async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'rundll32.exe',
          ['user32.dll,LockWorkStation'],
          runInShell: true,
        );

        _log('🔒 Windows locked');

        return {
          'success': true,
          'speech': 'Locking your computer.',
        };
      }

      if (Platform.isLinux) {
        await Process.start(
          'loginctl',
          ['lock-session'],
          runInShell: true,
        );

        _log('🔒 Linux locked');

        return {
          'success': true,
          'speech': 'Locking your computer.',
        };
      }

      if (Platform.isMacOS) {
        await Process.start(
          'pmset',
          ['displaysleepnow'],
          runInShell: true,
        );

        _log('🔒 macOS display locked/slept');

        return {
          'success': true,
          'speech': 'Locking your Mac.',
        };
      }

      return {
        'success': false,
        'speech':
            'Locking a phone remotely is not configured because mobile operating systems restrict this action.',
      };
    } catch (e) {
      _logError('Lock command failed', e);

      return {
        'success': false,
        'speech': 'I could not lock this device.',
      };
    }
  }

  // ============================================================
  // SHUTDOWN
  // ============================================================

  Future<Map<String, dynamic>> _shutdownDevice() async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'shutdown',
          ['/s', '/t', '10'],
          runInShell: true,
        );

        _log('⏻ Windows shutdown scheduled');

        return {
          'success': true,
          'speech': 'The computer will shut down in ten seconds.',
        };
      }

      if (Platform.isLinux) {
        await Process.start(
          'shutdown',
          ['-h', 'now'],
          runInShell: true,
        );

        _log('⏻ Linux shutdown requested');

        return {
          'success': true,
          'speech': 'The computer is shutting down.',
        };
      }

      if (Platform.isMacOS) {
        await Process.start(
          'sudo',
          ['shutdown', '-h', 'now'],
          runInShell: true,
        );

        _log('⏻ macOS shutdown requested');

        return {
          'success': true,
          'speech': 'The Mac is shutting down.',
        };
      }

      return {
        'success': false,
        'speech':
            'Mobile phones do not allow an ordinary app to shut down the device remotely.',
      };
    } catch (e) {
      _logError('Shutdown failed', e);

      return {
        'success': false,
        'speech': 'I could not shut down this device.',
      };
    }
  }

  // ============================================================
  // RESTART
  // ============================================================

  Future<Map<String, dynamic>> _restartDevice() async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'shutdown',
          ['/r', '/t', '10'],
          runInShell: true,
        );

        return {
          'success': true,
          'speech': 'The computer will restart in ten seconds.',
        };
      }

      if (Platform.isLinux) {
        await Process.start(
          'shutdown',
          ['-r', 'now'],
          runInShell: true,
        );

        return {
          'success': true,
          'speech': 'The computer is restarting.',
        };
      }

      if (Platform.isMacOS) {
        await Process.start(
          'sudo',
          ['shutdown', '-r', 'now'],
          runInShell: true,
        );

        return {
          'success': true,
          'speech': 'The Mac is restarting.',
        };
      }

      return {
        'success': false,
        'speech':
            'Mobile phones do not allow an ordinary app to restart the device remotely.',
      };
    } catch (e) {
      _logError('Restart failed', e);

      return {
        'success': false,
        'speech': 'I could not restart this device.',
      };
    }
  }

  // ============================================================
  // ALLOWED APPS
  // ============================================================

  Future<Map<String, dynamic>> _openAllowedApp(
    String app,
  ) async {
    final normalized = app.toLowerCase().trim();

    if (normalized.isEmpty) {
      return {
        'success': false,
        'speech': 'Please specify an application.',
      };
    }

    // PC
    if (Platform.isWindows) {
      const apps = {
        'chrome': 'chrome',
        'google chrome': 'chrome',
        'vscode': 'code',
        'vs code': 'code',
        'visual studio code': 'code',
        'notepad': 'notepad',
        'calculator': 'calc',
      };

      final executable = apps[normalized];

      if (executable == null) {
        return {
          'success': false,
          'speech': 'That application is not configured on Windows.',
        };
      }

      try {
        await Process.start(
          executable,
          [],
          runInShell: true,
        );

        _log('🚀 Windows app opened: $normalized');

        return {
          'success': true,
          'speech': 'Opening $normalized.',
        };
      } catch (e) {
        return {
          'success': false,
          'speech': 'I could not open $normalized.',
        };
      }
    }

    if (Platform.isLinux) {
      const apps = {
        'chrome': 'google-chrome',
        'google chrome': 'google-chrome',
        'vscode': 'code',
        'vs code': 'code',
        'visual studio code': 'code',
        'calculator': 'gnome-calculator',
      };

      final executable = apps[normalized];

      if (executable == null) {
        return {
          'success': false,
          'speech': 'That application is not configured on Linux.',
        };
      }

      try {
        await Process.start(
          executable,
          [],
          runInShell: true,
        );

        _log('🚀 Linux app opened: $normalized');

        return {
          'success': true,
          'speech': 'Opening $normalized.',
        };
      } catch (e) {
        return {
          'success': false,
          'speech': 'I could not open $normalized.',
        };
      }
    }

    if (Platform.isMacOS) {
      const apps = {
        'chrome': 'Google Chrome',
        'google chrome': 'Google Chrome',
        'vscode': 'Visual Studio Code',
        'vs code': 'Visual Studio Code',
        'visual studio code': 'Visual Studio Code',
        'calculator': 'Calculator',
      };

      final appName = apps[normalized];

      if (appName == null) {
        return {
          'success': false,
          'speech': 'That application is not configured on macOS.',
        };
      }

      try {
        await Process.start(
          'open',
          ['-a', appName],
          runInShell: true,
        );

        return {
          'success': true,
          'speech': 'Opening $normalized.',
        };
      } catch (e) {
        return {
          'success': false,
          'speech': 'I could not open $normalized.',
        };
      }
    }

    // Mobile: open common web destinations.
    if (Platform.isAndroid || Platform.isIOS) {
      final mobileUrls = {
        'chrome': 'https://www.google.com',
        'google chrome': 'https://www.google.com',
        'chatgpt': 'https://chatgpt.com',
        'youtube': 'https://youtube.com',
        'youtube music': 'https://music.youtube.com',
        'music': 'https://music.youtube.com',
      };

      final url = mobileUrls[normalized];

      if (url != null) {
        return _openUrl(url, normalized);
      }

      return {
        'success': false,
        'speech':
            'That phone application cannot be remotely launched by this bridge.',
      };
    }

    return {
      'success': false,
      'speech': 'This platform is not configured.',
    };
  }

  // ============================================================
  // DISCONNECT
  // ============================================================

  void _disconnectInternal() {
    try {
      socket?.disconnect();
      socket?.dispose();
    } catch (_) {}

    socket = null;
  }

  void _disconnect() {
    _disconnectInternal();

    if (mounted) {
      setState(() {
        connected = false;
        registered = false;
        connecting = false;
        statusMessage = 'Not connected';
      });
    }

    _log('🔌 Disconnected manually');
  }

  // ============================================================
  // TEST PING
  // ============================================================

  void _sendLocalPing() {
    if (socket == null || !registered) {
      _log('⚠️ Device is not registered');
      return;
    }

    _log('📤 Sending manual ping to Render');

    socket!.emit('ping');
  }

  // ============================================================
  // HELPERS
  // ============================================================

  String _extractReason(dynamic data) {
    if (data is Map && data['reason'] != null) {
      return data['reason'].toString();
    }

    return data?.toString() ?? 'Unknown reason';
  }

  void _clearLogs() {
    setState(() {
      logs.clear();
    });
  }

  Future<void> _copyLogsToClipboard() async {
    final text = logs.reversed.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Activity log copied to clipboard')),
      );
    }
  }

  Future<void> _copySecretToClipboard() async {
    await Clipboard.setData(ClipboardData(text: secretController.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Secret copied to clipboard')),
      );
    }
  }

  void _resetToDefaults() {
    serverUrlController.text = defaultServerUrl;
    for (final key in permissionLabels.keys) {
      permissions[key] = true;
    }
    _saveConfig();
    if (mounted) setState(() {});
    _log('🔁 Reset configuration to defaults');
  }

  Future<void> _showPermissionsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Permissions'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: permissionLabels.keys.map((key) {
                return StatefulBuilder(
                  builder: (context, setLocalState) {
                    return SwitchListTile(
                      title: Text(permissionLabels[key]!),
                      value: permissions[key] ?? true,
                      onChanged: (v) {
                        permissions[key] = v;
                        setLocalState(() {});
                        setState(() {});
                      },
                    );
                  },
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _resetToDefaults();
                Navigator.of(context).pop();
              },
              child: const Text('Reset'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                _saveConfig();
                Navigator.of(context).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Permissions saved')),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final statusIcon = registered
        ? Icons.cloud_done
        : connecting
            ? Icons.cloud_sync
            : Icons.cloud_off;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alexa Device Bridge'),
        actions: [
          IconButton(
            tooltip: 'Permissions',
            icon: const Icon(Icons.security),
            onPressed: _showPermissionsDialog,
          ),
          IconButton(
            tooltip: 'Reset defaults',
            icon: const Icon(Icons.restore),
            onPressed: _resetToDefaults,
          ),
          Icon(
            statusIcon,
            color: registered
                ? Colors.green
                : connecting
                    ? Colors.orange
                    : Colors.redAccent,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Card(
                child: ListTile(
                  leading: Icon(
                    registered ? Icons.check_circle : Icons.info,
                    color: registered ? Colors.green : Colors.orange,
                    size: 32,
                  ),
                  title: Text(statusMessage),
                  subtitle: Text(
                    '${platformDisplayName()} • ${deviceNameController.text}',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: serverUrlController,
                decoration: const InputDecoration(
                  labelText: 'Render / Server URL',
                  hintText: 'https://your-app.onrender.com',
                  prefixIcon: Icon(Icons.cloud),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: secretController,
                obscureText: !showSecret,
                decoration: InputDecoration(
                  labelText: 'Shared Secret',
                  prefixIcon: const Icon(Icons.key),
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: showSecret ? 'Hide secret' : 'Show secret',
                        icon: Icon(showSecret ? Icons.visibility_off : Icons.visibility),
                        onPressed: () {
                          setState(() {
                            showSecret = !showSecret;
                          });
                        },
                      ),
                      IconButton(
                        tooltip: 'Copy secret',
                        icon: const Icon(Icons.copy),
                        onPressed: _copySecretToClipboard,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: deviceNameController,
                decoration: const InputDecoration(
                  labelText: 'Device Name',
                  prefixIcon: Icon(Icons.devices),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: connected || connecting ? null : _connect,
                      icon: const Icon(Icons.power),
                      label: Text(
                        connecting ? 'Connecting...' : 'Connect',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: connected ? _disconnect : null,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Disconnect'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: registered ? _sendLocalPing : null,
                      icon: const Icon(Icons.network_ping),
                      label: const Text('Ping Server'),
                    ),
                  ),
                  const SizedBox(width: 10),
                    IconButton(
                      tooltip: 'Clear logs',
                      onPressed: _clearLogs,
                      icon: const Icon(Icons.delete_outline),
                    ),
                    IconButton(
                      tooltip: 'Copy logs',
                      onPressed: logs.isEmpty ? null : _copyLogsToClipboard,
                      icon: const Icon(Icons.copy_all),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Activity Log (${logs.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.grey.shade700,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: logs.isEmpty
                      ? Center(
                          child: Text(
                            'No activity yet',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: logs.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                logs[index],
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
}
