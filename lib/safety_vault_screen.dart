import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show compute;

// Derive the encryption key outside the UI isolate.
// Both the PIN and the device secret are required.
Future<List<int>> _deriveVaultKey(Map<String, String> input) async {
  final algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  );

  final key = await algorithm.deriveKeyFromPassword(
    password: '${input['pin']}:${input['deviceSecret']}',
    nonce: base64Decode(input['salt']!),
  );

  return key.extractBytes();
}

class SafetyVaultScreen extends StatefulWidget {
  const SafetyVaultScreen({super.key});

  @override
  State<SafetyVaultScreen> createState() => _SafetyVaultScreenState();
}

class _SafetyVaultScreenState extends State<SafetyVaultScreen>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  static const _privacy = MethodChannel('community_safe/vault_privacy');
  static const _files = MethodChannel('community_safe/vault_files');
  static const _maxBytes = 10 * 1024 * 1024;

  final _pin = TextEditingController();
  final _confirmation = TextEditingController();
  final _cipher = AesGcm.with256bits();

  StreamSubscription<User?>? _authSubscription;
  Directory? _directory;
  String? _uid;
  String? _storageKey;
  Map<String, dynamic>? _config;
  SecretKey? _key;

  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _preview;
  Map<String, dynamic>? _pendingFile;

  bool _loading = true;
  bool _busy = false;
  bool _picking = false;
  bool _privacyReady = false;

  int _session = 0;
  String? _message;

  bool get _sameAccount =>
      _uid != null && FirebaseAuth.instance.currentUser?.uid == _uid;

  bool _valid(int session) =>
      mounted && _sameAccount && session == _session && _key != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _uid = FirebaseAuth.instance.currentUser?.uid;

    _authSubscription =
        FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user?.uid != _uid) {
        _pendingFile = null;
        _lock('Account changed. Return to the home screen.');
      }
    });

    _initialise();
  }

  Future<void> _initialise() async {
    try {
      if (_uid == null) {
        throw StateError('Sign in before opening the vault.');
      }

      if (!Platform.isAndroid) {
        throw StateError('This vault version is for Android.');
      }

      await _privacy.invokeMethod<void>('enable');
      _privacyReady = true;

      final digest = await Sha256().hash(utf8.encode(_uid!));
      final accountId = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();

      _storageKey = 'community_safe_vault_v1_$accountId';

      final support = await getApplicationSupportDirectory();
      _directory = Directory(
        '${support.path}/safety_vault_v1/$accountId',
      );

      await _directory!.create(recursive: true);

      final stored = await _storage.read(key: _storageKey!);

      if (stored != null) {
        _config = Map<String, dynamic>.from(
          jsonDecode(stored) as Map,
        );
      } else {
          final existing = await _directory!
            .list()
            .any((entry) => entry.path.endsWith('.vault'));

        if (existing) {
          throw StateError(
            'Vault files exist but their unlock information is missing. '
            'Do not reset or overwrite them.',
          );
        }
      }

      if (!mounted) return;

      setState(() {
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _privacyReady = false;
        _message =
            'Could not prepare the vault. Check the Android setup and '
            'rebuild. Existing files have not been reset.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _lock('Vault locked. Enter your PIN to continue.');
    }
  }

  void _lock([String? message]) {
    _session++;
    _key = null;
    _items = [];
    _preview = null;
    _pin.clear();
    _confirmation.clear();

    if (mounted) {
      setState(() {
        _message = message;
      });
    }
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<String> _encrypt(
    List<int> bytes,
    SecretKey key,
  ) async {
    final box = await _cipher.encrypt(bytes, secretKey: key);

    return jsonEncode({
      'version': 1,
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<List<int>> _decrypt(
    String encrypted,
    SecretKey key,
  ) async {
    final data = jsonDecode(encrypted) as Map<String, dynamic>;

    if (data['version'] != 1) {
      throw StateError('Unsupported vault format.');
    }

    final box = SecretBox(
      base64Decode(data['cipherText'] as String),
      nonce: base64Decode(data['nonce'] as String),
      mac: Mac(base64Decode(data['mac'] as String)),
    );

    return _cipher.decrypt(box, secretKey: key);
  }

  Future<void> _unlock() async {
    if (_busy || !_privacyReady || !_sameAccount) return;

    final pin = _pin.text;
    final creating = _config == null;

    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() {
        _message = 'Enter a six-digit vault PIN.';
      });
      return;
    }

    if (creating && pin != _confirmation.text) {
      setState(() {
        _message = 'The PINs do not match.';
      });
      return;
    }

    final blockedUntil =
        (_config?['blockedUntil'] as num?)?.toInt() ?? 0;

    if (DateTime.now().millisecondsSinceEpoch < blockedUntil) {
      setState(() {
        _message = 'Too many attempts. Wait one minute before trying again.';
      });
      return;
    }

    final session = _session;
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final config = creating
          ? <String, dynamic>{
              'salt': base64Encode(_randomBytes(16)),
              'deviceSecret': base64Encode(_randomBytes(32)),
              'failures': 0,
              'blockedUntil': 0,
            }
          : Map<String, dynamic>.from(_config!);

      final input = <String, String>{
        'pin': pin,
        'salt': config['salt'] as String,
        'deviceSecret': config['deviceSecret'] as String,
      };

      final bytes = await compute(_deriveVaultKey, input);
      final candidate = SecretKey(bytes);

      if (!mounted || !_sameAccount || session != _session) return;

      if (creating) {
        config['check'] = await _encrypt(
          utf8.encode('community-safe-vault-v1'),
          candidate,
        );
      } else {
        try {
          final check = await _decrypt(
            config['check'] as String,
            candidate,
          );

          if (utf8.decode(check) != 'community-safe-vault-v1') {
            throw StateError('Invalid unlock data.');
          }
        } on SecretBoxAuthenticationError {
          final failures =
              ((config['failures'] as num?)?.toInt() ?? 0) + 1;

          config['failures'] = failures;
          config['blockedUntil'] = failures >= 5
              ? DateTime.now().millisecondsSinceEpoch + 60000
              : 0;

          await _storage.write(
            key: _storageKey!,
            value: jsonEncode(config),
          );
          _config = config;

          throw StateError(
            failures >= 5
                ? 'Too many attempts. Wait one minute.'
                : 'Incorrect PIN or damaged unlock data.',
          );
        }
      }

      config['failures'] = 0;
      config['blockedUntil'] = 0;

      await _storage.write(
        key: _storageKey!,
        value: jsonEncode(config),
      );
      _config = config;

      if (!mounted || !_sameAccount || session != _session) return;

      _key = candidate;
      _pin.clear();
      _confirmation.clear();

      await _loadItems(session);

      if (_valid(session) && _pendingFile != null) {
        await _savePendingFile(session);
      }
    } catch (error) {
      if (mounted && session == _session) {
        setState(() {
          _message = error is StateError
              ? error.message.toString()
              : 'Could not unlock the vault. Existing files were not reset.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _loadItems(int session) async {
    final key = _key!;
    final items = <Map<String, dynamic>>[];

    await for (final entry in _directory!.list()) {
      if (!_valid(session)) return;

      if (entry is! File || !entry.path.endsWith('.vault')) continue;

      final plain = await _decrypt(await entry.readAsString(), key);
      final data = Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)));

      items.add({
        'path': entry.path,
        'name': data['name'],
        'createdAt': data['createdAt'],
        'size': data['size'],
      });
    }

    items.sort(
      (a, b) => (b['createdAt'] as String)
          .compareTo(a['createdAt'] as String),
    );

    if (!_valid(session)) return;

    setState(() {
      _items = items;
    });
  }

    Future<void> _pickFile() async {
    if (_busy || _picking || _key == null || !_sameAccount) return;

    setState(() {
      _picking = true;
    });

    try {
      final file = await _files.invokeMapMethod<String, dynamic>('pick');

      if (!mounted || !_sameAccount) {
        await _files.invokeMethod<void>('clear');
        return;
      }

      _pendingFile = file;

      _lock(
        file == null
            ? 'Selection cancelled. Unlock to continue.'
            : 'File selected. Re-enter your vault PIN to import it.',
      );
    } on PlatformException catch (error) {
      _lock(error.message ?? 'Could not select the file.');
    } catch (_) {
      _lock('Could not select the file. Unlock and try again.');
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
        });
      }
    }
  }

    Future<void> _savePendingFile(int session) async {
    final selected = _pendingFile!;
    _pendingFile = null;
    final key = _key!;

    try {
      final bytes = await _files.invokeMethod<Uint8List>('read');

      if (bytes == null) {
        throw StateError('Could not read the selected file.');
      }

      if (bytes.length > _maxBytes) {
        throw StateError('Choose a file no larger than 10 MB.');
      }

      if (!_valid(session)) return;

      final data = {
        'name': selected['name'] as String,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'size': bytes.length,
        'bytes': base64Encode(bytes),
      };

      final encrypted = await _encrypt(
        utf8.encode(jsonEncode(data)),
        key,
      );

      if (!_valid(session)) return;

      final id = _randomBytes(16)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();

      final temporary = File('${_directory!.path}/$id.part');
      final target = '${_directory!.path}/$id.vault';

      await temporary.writeAsString(encrypted, flush: true);
      await temporary.rename(target);

      if (!_valid(session)) return;

      await _loadItems(session);

      if (_valid(session)) {
        setState(() {
          _message =
              'Encrypted copy saved. The original file remains outside '
              'the vault.';
        });
      }
    } finally {
      try {
        await _files.invokeMethod<void>('clear');
      } catch (_) {
        // The native selection may already have been cleared.
      }
    }
  }

    Future<void> _openItem(Map<String, dynamic> item) async {
    if (_busy || _key == null) return;

    final session = _session;
    final key = _key!;

    setState(() {
      _busy = true;
    });

    try {
      final encrypted =
          await File(item['path'] as String).readAsString();

      final bytes = await _decrypt(encrypted, key);

      final data = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(bytes)) as Map,
      );

      if (!_valid(session)) return;

      setState(() {
        _preview = data;
      });
    } catch (_) {
      if (_valid(session)) {
        setState(() {
          _message =
              'Could not decrypt this file. It has not been changed.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    if (_busy || _key == null) return;

    final session = _session;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete vault copy?'),
        content: const Text(
          'This removes the encrypted copy from this phone. '
          'It does not delete the original file outside the vault.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !_valid(session)) return;

    setState(() {
      _busy = true;
    });

    try {
      await File(item['path'] as String).delete();
      if (_valid(session)) await _loadItems(session);
    } catch (_) {
      if (_valid(session)) {
        setState(() {
          _message = 'Could not delete the vault copy.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Widget _previewWidget() {
    final data = _preview!;
    final name = data['name'] as String;
    final extension = name.split('.').last.toLowerCase();
    final bytes = base64Decode(data['bytes'] as String);

    if (['jpg', 'jpeg', 'png'].contains(extension)) {
      return Expanded(
        child: InteractiveViewer(
          child: Center(
            child: Image.memory(
              Uint8List.fromList(bytes),
              errorBuilder: (_, _, _) =>
                  const Text('Image preview unavailable.'),
            ),
          ),
        ),
      );
    }

    if (extension == 'txt') {
      return Expanded(
        child: SingleChildScrollView(
          child: Text(
            utf8.decode(bytes, allowMalformed: true),
          ),
        ),
      );
    }

    return const Expanded(
      child: Center(
        child: Text(
          'This document is stored encrypted.\n'
          'PDF preview is not included in this version.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = _key != null && _sameAccount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety Vault'),
        actions: [
          if (unlocked)
            IconButton(
              tooltip: 'Lock vault',
              onPressed: () => _lock('Vault locked.'),
              icon: const Icon(Icons.lock_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_message != null) ...[
                    Text(_message!),
                    const SizedBox(height: 16),
                  ],
                  if (!_privacyReady || !_sameAccount)
                    const Text(
                      'Vault unavailable. Return to the home screen '
                      'and check that you are signed in.',
                    )
                  else if (!unlocked)
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _config == null
                                  ? 'Create your vault PIN'
                                  : 'Unlock your vault',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Files are stored on this phone. There is no '
                              'PIN recovery in this version. Uninstalling, '
                              'clearing app data or losing the device keys '
                              'can make files unrecoverable.\n\n'
                              'Importing does not remove originals from '
                              'Gallery, Files or cloud storage.',
                            ),
                            const SizedBox(height: 20),
                            TextField(
                              controller: _pin,
                              enabled: !_busy && !_picking,
                              obscureText: true,
                              enableSuggestions: false,
                              autocorrect: false,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(6),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Six-digit vault PIN',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            if (_config == null) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: _confirmation,
                                enabled: !_busy,
                                obscureText: true,
                                enableSuggestions: false,
                                autocorrect: false,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(6),
                                ],
                                decoration: const InputDecoration(
                                  labelText: 'Confirm PIN',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _busy || _picking ? null : _unlock,
                              child: Text(
                                _busy
                                    ? 'Please wait…'
                                    : _config == null
                                        ? 'Create vault'
                                        : 'Unlock',
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (_preview != null) ...[
                    Text(
                      _preview!['name'] as String,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _preview = null;
                        });
                      },
                      child: const Text('Back to files'),
                    ),
                    _previewWidget(),
                  ] else ...[
                    const Text(
                      'Encrypted copies on this phone • Maximum 10 MB per file\n'
                      'Images: JPG, JPEG, PNG\n'
                      'Documents: PDF, TXT\n'
                      'Videos: MP4, M4V, 3GP, WEBM, MOV',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy || _picking ? null : _pickFile,
                      icon: const Icon(Icons.add),
                      label: const Text('Import file'),
                    ),
                    const SizedBox(height: 12),
                    if (_busy) const LinearProgressIndicator(),
                    Expanded(
                      child: _items.isEmpty
                          ? const Center(child: Text('No files saved yet.'))
                          : ListView.builder(
                              itemCount: _items.length,
                              itemBuilder: (_, index) {
                                final item = _items[index];

                                return ListTile(
                                  leading:
                                      const Icon(Icons.insert_drive_file),
                                  title: Text(item['name'] as String),
                                  subtitle: Text(
                                    '${item['size']} bytes • '
                                    '${DateTime.parse(
                                      item['createdAt'] as String,
                                    ).toLocal()}',
                                  ),
                                  onTap: _busy ? null : () => _openItem(item),
                                  trailing: IconButton(
                                    tooltip: 'Delete vault copy',
                                    onPressed:
                                        _busy ? null : () => _deleteItem(item),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    _session++;
    _key = null;
    _items = [];
    _preview = null;
    _pendingFile = null;
    _pin.dispose();
    _confirmation.dispose();

    if (_privacyReady) {
      _privacy.invokeMethod<void>('disable').catchError((Object _) {});
    }

    super.dispose();
  }
}