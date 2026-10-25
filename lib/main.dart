import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'safety_vault_screen.dart';

final demoReports = ValueNotifier<List<Map<String, String>>>([]);
final trustedContacts = ValueNotifier<List<Map<String, String>>>([]);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  ); 

  runApp(const CommunitySafeApp());
}

class CommunitySafeApp extends StatelessWidget {
  const CommunitySafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Community Safe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00695C)),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const MethodChannel _volumeChannel =
      MethodChannel('community_safe/volume');

  static bool _sosInProgress = false;

  @override
  void initState() {
    super.initState();

    _volumeChannel.setMethodCallHandler(_handleVolumeCall);
    _setVolumeTriggerEnabled(true);
  }

  Future<void> _setVolumeTriggerEnabled(bool enabled) async {
    try {
      await _volumeChannel.invokeMethod<void>(
        'setEnabled',
        {'enabled': enabled},
      );
    } on MissingPluginException {
      // Not available on web or until Android is rebuilt.
      debugPrint('Volume SOS requires the rebuilt Android app.');
    } on PlatformException catch (error) {
      debugPrint('Could not configure Volume SOS: ${error.message}');
    }
  }

  Future<dynamic> _handleVolumeCall(MethodCall call) async {
    if (call.method != 'volumeSos') return null;

    if (!mounted ||
        !TickerMode.valuesOf(context).enabled ||
        WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true ||
        FirebaseAuth.instance.currentUser == null ||
        _sosInProgress) {
      return null;
    }

    await showSosDialog(context);
    return null;
  }

  @override
  void dispose() {
    _volumeChannel.setMethodCallHandler(null);
    _setVolumeTriggerEnabled(false);
    super.dispose();
  }

  void showDemoMessage(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature is coming soon. No alert has been sent.'),
      ),
    );
  }

    Future<void> showSosDialog(BuildContext context) async {
    if (_sosInProgress) return;
    _sosInProgress = true;

    try {
      final contacts = trustedContacts.value
          .map((contact) => Map<String, String>.from(contact))
          .toList();

      if (contacts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add a trusted contact before using SOS.'),
          ),
        );
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Send SOS?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'After the countdown, Community Safe will request '
                  'your location and send a real emergency SMS to '
                  'each trusted contact below.\n\n'
                  'If location is unavailable, the SMS will say so. '
                  'Normal SMS charges apply. This does not '
                  'automatically contact emergency services.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Recipients:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                for (final contact in contacts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${contact['name']} — ${contact['phone']}',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB3261E),
                foregroundColor: Colors.white,
              ),
              child: const Text('Start SOS countdown'),
            ),
          ],
        ),
      );

      if (!context.mounted || confirmed != true) return;

      final countdownCompleted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const SosCountdownDialog(),
      );

      if (!context.mounted) return;

      if (countdownCompleted != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SOS cancelled. No SMS was submitted.'),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Preparing location and submitting SOS SMS...'),
          duration: Duration(seconds: 3),
        ),
      );

      String senderName = '';

      final profileUser = FirebaseAuth.instance.currentUser;

      if (profileUser != null) {
        try {
          final profile = await FirebaseFirestore.instance
              .collection('users')
              .doc(profileUser.uid)
              .collection('profile')
              .doc('details')
              .get()
              .timeout(const Duration(seconds: 2));

          final data = profile.data();

          if (FirebaseAuth.instance.currentUser?.uid == profileUser.uid &&
              data != null) {
            final preferred =
                (data['preferredName'] as String? ?? '').trim();
            final firstName =
                (data['firstName'] as String? ?? '').trim();
            final surname =
                (data['surname'] as String? ?? '').trim();

            senderName = preferred.isNotEmpty
                ? preferred
                : '$firstName $surname'.trim();
          }
        } catch (_) {
          // Send the usual SOS even when the profile cannot be loaded.
        }
      }

      final response = await const MethodChannel('community_safe/sms')
          .invokeMapMethod<String, dynamic>(
        'sendSos',
        {
          'contacts': contacts,
          'senderName': senderName,
        },
      );

      if (response == null) {
        throw StateError('No SMS result returned.');
      }

      final submitted = (response['submitted'] as num).toInt();
      final failed = (response['failed'] as num).toInt();
      final locationAvailable = response['locationAvailable'] == true;

      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'SMS submitted to Android for $submitted contact(s). '
              '$failed submission(s) failed. '
              '${locationAvailable ? 'Location included.' : 'Location unavailable.'} '
              'Delivery is not confirmed.',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }

      // Record the attempt after SMS submission.
      // A database failure must not prevent the SMS attempt.
      final user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('events')
              .add({
            'type': 'sos',
            'status': submitted == 0
                ? 'submission_failed'
                : failed > 0
                    ? 'partially_submitted'
                    : 'submitted_to_android',
            'isDemo': false,
            'submittedCount': submitted,
            'failedCount': failed,
            'locationAvailable': locationAvailable,
            'deliveryConfirmed': false,
            'createdAt': FieldValue.serverTimestamp(),
          }).timeout(const Duration(seconds: 10));
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not confirm SOS history was saved. '
                  'The SMS submission result above still applies.',
                ),
              ),
            );
          }
        }
      }
    } on PlatformException catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ?? 'Could not start SMS submission.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not confirm the SOS result. Check the receiving '
            'phones before retrying to avoid duplicate messages.',
          ),
          duration: Duration(seconds: 8),
        ),
      );
    } finally {
      _sosInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F7),
        appBar: AppBar(
        title: const Text('Community Safe'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'My profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const UserProfileScreen(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text(
                    'Your saved reports and SOS history '
                    'will remain in your account.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () =>
                          Navigator.pop(dialogContext, true),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              );

              if (confirmed != true || !context.mounted) return;

              try {
                await const MethodChannel(
                  'community_safe/check_in',
                ).invokeMethod<bool>('cancel');
                await FirebaseAuth.instance.signOut();

                // Clear account-specific lists held in memory.
                trustedContacts.value = [];
                demoReports.value = [];

                if (!context.mounted) return;

                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (_) => const AuthGate(),
                  ),
                  (route) => false,
                );
              } catch (_) {
                if (!context.mounted) return;

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not sign out. Please try again.',
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.shield_outlined,
                    size: 72,
                    color: Color(0xFF00695C),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Your safety matters',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A place to seek support, report concerns, '
                    'and connect with people you trust.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 28),

                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                                                'SOS sends a real SMS to your trusted contacts '
                                                'after confirmation and a countdown. Your location '
                                                'is included when available. SMS charges may apply. '
                                                'Emergency services are not automatically contacted.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  FilledButton.icon(
                    onPressed: () {
                      showSosDialog(context);
                    },
                    icon: const Icon(Icons.sos),
                    label: const Text('SOS — Request help'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB3261E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () async {
                      final contacts = trustedContacts.value
                          .map((contact) => <String, String>{
                                'name': contact['name'] ?? '',
                                'phone': contact['phone'] ?? '',
                              })
                          .toList();

                      try {
                        await const MethodChannel(
                          'community_safe/check_in',
                        ).invokeMethod<void>(
                          'show',
                          {'contacts': contacts},
                        );
                      } catch (_) {
                        if (!context.mounted) return;

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not open safety check-in. '
                              'Use the rebuilt Android app.',
                            ),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.timer_outlined),
                    label: const Text('Safety check-in'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () async {
                      final contacts = trustedContacts.value
                          .map((contact) => <String, String>{
                                'name': contact['name'] ?? '',
                                'phone': contact['phone'] ?? '',
                              })
                          .toList();

                      if (contacts.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Add a trusted contact first.'),
                          ),
                        );
                        return;
                      }

                      try {
                        await const MethodChannel('community_safe/sms')
                            .invokeMethod<void>(
                          'showTrustedSmsTest',
                          {
                            'contacts': contacts,
                          },
                        );
                      } catch (_) {
                        if (!context.mounted) return;

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not open the contact SMS test. '
                              'Check that the Android changes were rebuilt.',
                            ),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('Send test SMS'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SafetyVaultScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('Safety Vault'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const ReportIncidentScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.edit_document),
                    label: const Text('Report an incident'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SupportScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.support_agent),
                    label: const Text('Find support'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const TrustedContactsScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.people_outline),
                    label: const Text('Trusted contacts'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
                    ),
                  ),
                  const SizedBox(height: 16),

                                    Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const ReportHistoryScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.history),
                          label: const Text(
                            'Report history',
                            textAlign: TextAlign.center,
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 80),
                            padding: const EdgeInsets.all(8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const SosHistoryScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.history_rounded),
                          label: const Text(
                            'SOS history',
                            textAlign: TextAlign.center,
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 80),
                            padding: const EdgeInsets.all(8),
                          ),
                        ),
                      ),
                    ],
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

class ReportIncidentScreen extends StatefulWidget {
  const ReportIncidentScreen({super.key});

  @override
  State<ReportIncidentScreen> createState() => _ReportIncidentScreenState();
}

class _ReportIncidentScreenState extends State<ReportIncidentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _locationController = TextEditingController();

  String? _incidentType;

  bool _isSaving = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

    Future<void> _previewReport() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in before saving a report.'),
        ),
      );
      return;
    }

    final type = _incidentType!;
    final description = _descriptionController.text.trim();
    final location = _locationController.text.trim();

    setState(() => _isSaving = true);

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Report preview'),
          content: SingleChildScrollView(
            child: Text(
              'Type: $type\n\n'
              'Description: $description\n\n'
              'Location: $location\n\n'
              'Save this report to your account in Firebase? '
              'It will not be sent to authorities or trusted contacts. '
              'Reports are not monitored.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, true),
              child: const Text('Save to my account'),
            ),
          ],
        ),
      );

      if (!mounted || confirmed != true) return;

      if (FirebaseAuth.instance.currentUser?.uid != user.uid) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your account changed. Please reopen the report form.',
            ),
          ),
        );
        return;
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('reports')
          .add({
        'type': type,
        'description': description,
        'location': location,
        'status': 'saved_only',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);

      Navigator.pop(context);

      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Report saved to your account. No one was notified.',
          ),
        ),
      );
    } on FirebaseException catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'permission-denied'
                ? 'Saving was denied. Check the published report rules.'
                : 'Could not save the report. Your form is still here.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not confirm the report was saved. '
            'Check report history before trying again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report an incident')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Tell us what happened',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Save an incident record to your account. '
                      'Reports are not sent to authorities or monitored. '
                      'Use fictional details while testing.',
                    ),
                    const SizedBox(height: 24),
                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(
                        labelText: 'Incident type',
                        border: OutlineInputBorder(),
                      ),
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                          value: 'Harassment',
                          child: Text('Harassment'),
                        ),
                        DropdownMenuItem(
                          value: 'Violence or threats',
                          child: Text('Violence or threats'),
                        ),
                        DropdownMenuItem(
                          value: 'Safety concern',
                          child: Text('Safety concern'),
                        ),
                        DropdownMenuItem(value: 'Other', child: Text('Other')),
                      ],
                      onChanged: (value) {
                        _incidentType = value;
                      },
                      validator: (value) {
                        if (value == null) {
                          return 'Please select an incident type.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'What happened?',
                        hintText: 'Enter a fictional description',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                      minLines: 4,
                      maxLines: 6,
                      maxLength: 2000,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a description.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _locationController,
                      decoration: const InputDecoration(
                        labelText: 'Location or area',
                        hintText: 'For example: Example Street',
                        border: OutlineInputBorder(),
                      ),
                      maxLength: 200,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a location or area.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _previewReport,
                      icon: const Icon(Icons.preview_outlined),
                      label: Text(
                        _isSaving
                            ? 'Preparing or saving…'
                            : 'Preview report',
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.all(18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TrustedContactsScreen extends StatefulWidget {
  const TrustedContactsScreen({super.key});

  @override
  State<TrustedContactsScreen> createState() =>
      _TrustedContactsScreenState();
}

class _TrustedContactsScreenState extends State<TrustedContactsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<bool> _saveContacts(
    List<Map<String, String>> contacts,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    try {
      final collection = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('contacts');

      final batch = FirebaseFirestore.instance.batch();

      // Give new contacts a document ID without writing yet.
      for (final contact in contacts) {
        contact['id'] ??= collection.doc().id;
      }

      final remainingIds = contacts.map((c) => c['id']!).toSet();

      // Remove contacts deleted from the current list.
      for (final oldContact in trustedContacts.value) {
        final id = oldContact['id'];
        if (id != null && !remainingIds.contains(id)) {
          batch.delete(collection.doc(id));
        }
      }

      for (final contact in contacts) {
        batch.set(collection.doc(contact['id']!), {
          'name': contact['name']!,
          'phone': contact['phone']!,
        });
      }

      await batch.commit();

      return FirebaseAuth.instance.currentUser?.uid == user.uid;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not confirm contact changes were saved. '
              'Check your connection.',
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _addContact() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    final updatedContacts = [
      ...trustedContacts.value,
      {
        'name': name,
        'phone': phone,
      },
    ];

    final saved = await _saveContacts(updatedContacts);
    if (!saved) return;

    trustedContacts.value = updatedContacts;

    if (!mounted) return;

    _nameController.clear();
    _phoneController.clear();
    _formKey.currentState!.reset();
    FocusScope.of(context).unfocus();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name added to trusted contacts.')),
    );
  }

  Future<void> _editContact(int index) async {
    final contact = trustedContacts.value[index];
    final editFormKey = GlobalKey<FormState>();
    final nameController = TextEditingController(
      text: contact['name'],
    );
    final phoneController = TextEditingController(
      text: contact['phone'],
    );

    final updatedContact = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit contact'),
        content: SingleChildScrollView(
          child: Form(
            key: editFormKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Contact name',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 100,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a name.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 25,
                  validator: (value) {
                    final phone = value?.trim() ?? '';

                    if (phone.isEmpty) {
                      return 'Please enter a phone number.';
                    }

                    if (!RegExp(r'^\+?[0-9 ()-]+$').hasMatch(phone)) {
                      return 'Please enter a valid phone number.';
                    }

                    final digits =
                        phone.replaceAll(RegExp(r'\D'), '');

                    if (digits.length < 10 || digits.length > 15) {
                      return 'Enter a number with 10 to 15 digits.';
                    }

                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (!editFormKey.currentState!.validate()) return;

              Navigator.pop(dialogContext, <String, String>{
                'name': nameController.text.trim(),
                'phone': phoneController.text.trim(),
              });
            },
            child: const Text('Save changes'),
          ),
        ],
      ),
    );

    // Wait for the dialog's closing animation before disposing its controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    nameController.dispose();
    phoneController.dispose();

    if (!mounted || updatedContact == null) return;

    final updatedContacts =
        List<Map<String, String>>.from(trustedContacts.value);

    final currentIndex = updatedContacts.indexOf(contact);
    if (currentIndex == -1) return;

    updatedContacts[currentIndex] = {
      ...updatedContact,
      if (contact['id'] != null) 'id': contact['id']!,
    };

    final saved = await _saveContacts(updatedContacts);
    if (!saved) return;

    trustedContacts.value = updatedContacts;

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Contact updated.'),
      ),
    );
  }

  Future<void> _removeContact(int index) async {
    final contact = trustedContacts.value[index];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove contact?'),
        content: Text(
          'Remove ${contact['name']} from your trusted contacts?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB3261E),
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    final updatedContacts =
        List<Map<String, String>>.from(trustedContacts.value);

    updatedContacts.remove(contact);

    final saved = await _saveContacts(updatedContacts);
    if (!saved) return;

    trustedContacts.value = updatedContacts;

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${contact['name']} removed.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trusted contacts'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'People you trust',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Demo contacts are saved to your account. '
                  'No messages or alerts are sent.',
                ),
                const SizedBox(height: 24),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Contact name',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        maxLength: 100,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a name.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                          hintText: 'For example: 082 123 4567',
                          prefixIcon: Icon(Icons.phone_outlined),
                          border: OutlineInputBorder(),
                        ),
                        maxLength: 25,
                        validator: (value) {
                          final phone = value?.trim() ?? '';

                          if (phone.isEmpty) {
                            return 'Please enter a phone number.';
                          }

                          // Allow common phone-number formatting.
                          if (!RegExp(r'^\+?[0-9 ()-]+$')
                              .hasMatch(phone)) {
                            return 'Please enter a valid phone number.';
                          }

                          final digits =
                              phone.replaceAll(RegExp(r'\D'), '');

                          if (digits.length < 10 || digits.length > 15) {
                            return 'Enter a number with 10 to 15 digits.';
                          }

                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _addContact,
                        icon: const Icon(Icons.person_add_outlined),
                        label: const Text('Add contact'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.all(18),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Your contacts',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<List<Map<String, String>>>(
                  valueListenable: trustedContacts,
                  builder: (context, contacts, child) {
                    if (contacts.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No trusted contacts added yet.',
                          textAlign: TextAlign.center,
                        ),
                      );
                    }

                    return Column(
                      children: [
                        for (int index = 0;
                            index < contacts.length;
                            index++)
                          Card(
                            child: ListTile(
                              leading: const Icon(
                                Icons.account_circle_outlined,
                                color: Color(0xFF00695C),
                              ),
                              title: Text(contacts[index]['name']!),
                              subtitle: Text(contacts[index]['phone']!),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Edit contact',
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _editContact(index),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove contact',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _removeContact(index),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find support'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: const [
                Icon(
                  Icons.support_agent,
                  size: 64,
                  color: Color(0xFF00695C),
                ),
                SizedBox(height: 16),
                Text(
                  'You deserve support',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'South African support services',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Dialler buttons open your phone app. '
                      'You choose whether to place the call. '
                      'Your saved reports and location are not '
                      'automatically shared with these services.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                SizedBox(height: 16),
                _SupportCategory(
                  icon: Icons.emergency_outlined,
                  title: 'Emergency assistance',
                  description:
                      'For immediate danger or an emergency, '
                      'dial 112 from a cellphone.',
                  phone: '112',
                  website:
                      'https://www.ekurhuleni.gov.za/'
                      'press-releases/featured-article/'
                      'know-your-life-threatening-emergency-services-number/',
                ),
                _SupportCategory(
                  icon: Icons.local_police_outlined,
                  title: 'Police emergency',
                  description:
                      'Contact SAPS on 10111 for a crime emergency.',
                  phone: '10111',
                  website:
                      'https://www.gov.za/services/services-residents/'
                      'dealing-law/report-crime/how-report-crime',
                ),
                _SupportCategory(
                  icon: Icons.volunteer_activism_outlined,
                  title: 'GBV support and counselling',
                  description:
                      'The Gender-Based Violence Command Centre '
                      'offers 24-hour support, trauma counselling '
                      'and referrals to social workers.',
                  phone: '0800428428',
                  displayPhone: '0800 428 428',
                  website: 'https://gbv.org.za/about-us/',
                ),
                _SupportCategory(
                  icon: Icons.home_outlined,
                  title: 'Shelter referrals',
                  description:
                      'Ask the GBV Command Centre about shelter '
                      'referrals and available support. '
                      'Accommodation availability must be confirmed '
                      'with the service.',
                  phone: '0800428428',
                  displayPhone: '0800 428 428',
                  website: 'https://gbv.org.za/about-us/',
                ),
                _SupportCategory(
                  icon: Icons.gavel_outlined,
                  title: 'Legal assistance',
                  description:
                      'Contact Legal Aid South Africa for legal '
                      'advice and information about available assistance.',
                  phone: '0800110110',
                  displayPhone: '0800 110 110',
                  website: 'https://legal-aid.co.za/selfhelp/',
                ),
                SizedBox(height: 8),
                Text(
                  'Contact details checked against official sources '
                  'on 21 October 2026. Service details may change.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SupportCategory extends StatelessWidget {
  const _SupportCategory({
    required this.icon,
    required this.title,
    required this.description,
    required this.phone,
    required this.website,
    this.displayPhone,
  });

  final IconData icon;
  final String title;
  final String description;
  final String phone;
  final String website;
  final String? displayPhone;

  Future<void> _openLink(
    BuildContext context,
    Uri uri,
  ) async {
    try {
      final opened = await launchUrl(uri);

      if (opened) return;
    } catch (_) {
      // Show a readable fallback below.
    }

    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          uri.scheme == 'tel'
              ? 'Could not open a phone app. '
                  'Dial ${displayPhone ?? phone} manually.'
              : 'Could not open the website. Please try again.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: const Color(0xFF00695C),
              size: 30,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(description),
                  const SizedBox(height: 12),
                  SelectableText(
                    displayPhone ?? phone,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00695C),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _openLink(
                          context,
                          Uri(scheme: 'tel', path: phone),
                        ),
                        icon: const Icon(Icons.dialpad),
                        label: const Text('Open dialler'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _openLink(
                          context,
                          Uri.parse(website),
                        ),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Official source'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Stream<User?> _authStream;

  @override
  void initState() {
    super.initState();
    _authStream = FirebaseAuth.instance.authStateChanges();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(
              child: Text('Unable to check sign-in. Please restart the app.'),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.data != null) {
          return AccountContactsGate(
            key: ValueKey(snapshot.data!.uid),
            userId: snapshot.data!.uid,
          );
        }

        return const AuthScreen();
      },
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLogin = true;
  bool _isLoading = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading || !_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;

      if (_isLogin) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      }

      // AuthGate opens the home screen after successful authentication.
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;

      setState(() {
        switch (error.code) {
          case 'invalid-email':
            _error = 'Please enter a valid email address.';
            break;
          case 'weak-password':
            _error = 'Choose a stronger password.';
            break;
          case 'email-already-in-use':
            _error = 'Unable to register. Try logging in instead.';
            break;
          case 'invalid-credential':
          case 'user-not-found':
          case 'wrong-password':
            _error = 'The email or password is incorrect.';
            break;
          case 'network-request-failed':
            _error = 'Check your internet connection and try again.';
            break;
          case 'too-many-requests':
            _error = 'Too many attempts. Please try again later.';
            break;
          default:
            _error = 'Sign-in failed (${error.code}). Please try again.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLogin ? 'Log in' : 'Create account'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 450),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 64,
                      color: Color(0xFF00695C),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Community Safe',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _emailController,
                      enabled: !_isLoading,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.none,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final email = value?.trim() ?? '';
                        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                            .hasMatch(email)) {
                          return 'Please enter a valid email address.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      enabled: !_isLoading,
                      obscureText: _hidePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _hidePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () {
                            setState(() {
                              _hidePassword = !_hidePassword;
                            });
                          },
                          icon: Icon(
                            _hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter a password.';
                        }
                        if (!_isLogin && value.length < 8) {
                          return 'Use at least 8 characters.';
                        }
                        return null;
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _isLoading ? null : _submit,
                      child: Text(
                        _isLoading
                            ? 'Please wait...'
                            : (_isLogin ? 'Log in' : 'Create account'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () {
                              setState(() {
                                _isLogin = !_isLogin;
                                _error = null;
                                _passwordController.clear();
                                _formKey.currentState!.reset();
                              });
                            },
                      child: Text(
                        _isLogin
                            ? 'New here? Create an account'
                            : 'Already registered? Log in',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PinGate extends StatefulWidget {
  const PinGate({
    super.key,
    required this.userId,
  });

  final String userId;

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate>
    with WidgetsBindingObserver {
  final _storage = const FlutterSecureStorage();
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  Map<String, dynamic>? _record;
  bool _loading = true;
  bool _busy = false;
  bool _unlocked = false;
  bool _hasOpenedSafety = false;
  bool _storageFailed = false;
  int _lockVersion = 0;
  String? _error;

  String get _storageKey => 'pin_v1_${widget.userId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPin();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _lockVersion++;

      if (mounted) {
        setState(() {
          _unlocked = false;
          _pinController.clear();
          _confirmController.clear();
        });
      }
    }
  }

  Future<void> _loadPin() async {
    try {
      final saved = await _storage.read(key: _storageKey);

      if (saved != null) {
        final record =
            Map<String, dynamic>.from(jsonDecode(saved) as Map);

        // Invalid stored data must not silently reset the PIN.
        base64Decode(record['salt'] as String);
        base64Decode(record['hash'] as String);
        record['attempts'] as int;
        record['lockedUntil'] as int;

        _record = record;
      }
    } catch (_) {
      _storageFailed = true;
      _error = 'Unable to read PIN storage. Restart and try again.';
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<String> _hashPin(String pin, String salt) async {
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 600000,
      bits: 256,
    );

    final key = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: base64Decode(salt),
    );

    return base64Encode(await key.extractBytes());
  }

  bool _matches(String first, String second) {
    final a = base64Decode(first);
    final b = base64Decode(second);

    if (a.length != b.length) return false;

    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }

    return difference == 0;
  }

  Future<void> _submitPin() async {
    if (_busy || _storageFailed) return;
    if (_record == null) {
    if (!_formKey.currentState!.validate()) return;
    } else if (!RegExp(r'^\d{6}$').hasMatch(_pinController.text)) {
      return;
    }

    final version = _lockVersion;
    final pin = _pinController.text;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      var verified = false;
      late Map<String, dynamic> nextRecord;

      if (_record == null) {
        final random = Random.secure();
        final salt = base64Encode(
          List<int>.generate(16, (_) => random.nextInt(256)),
        );

        nextRecord = {
          'salt': salt,
          'hash': await _hashPin(pin, salt),
          'attempts': 0,
          'lockedUntil': 0,
        };
        verified = true;
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        final lockedUntil = _record!['lockedUntil'] as int;

        if (now < lockedUntil) {
          final seconds = ((lockedUntil - now) / 1000).ceil();
          setState(() {
            _error = 'Please wait $seconds seconds, then try again.';
          });
          return;
        }

        final hash = await _hashPin(
          pin,
          _record!['salt'] as String,
        );

        verified = _matches(hash, _record!['hash'] as String);
        nextRecord = Map<String, dynamic>.from(_record!);

        if (verified) {
          nextRecord['attempts'] = 0;
          nextRecord['lockedUntil'] = 0;
        } else {
          final attempts = (nextRecord['attempts'] as int) + 1;

          if (attempts >= 5) {
            nextRecord['attempts'] = 0;
            nextRecord['lockedUntil'] =
                DateTime.now().millisecondsSinceEpoch + 60000;
          } else {
            nextRecord['attempts'] = attempts;
            nextRecord['lockedUntil'] = 0;
          }
        }
      }

      await _storage.write(
        key: _storageKey,
        value: jsonEncode(nextRecord),
      );

      if (!mounted) return;

      setState(() {
        _record = nextRecord;
        _pinController.clear();
        _confirmController.clear();

        if (verified && version == _lockVersion) {
          _unlocked = true;
          _hasOpenedSafety = true;
        } else if (!verified) {
          _error = nextRecord['lockedUntil'] > 0
              ? 'Too many incorrect attempts. Wait one minute.'
              : 'Incorrect PIN. Please try again.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Unable to unlock or save the PIN. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_hasOpenedSafety) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: !_unlocked,
            child: TickerMode(
              enabled: _unlocked,
              child: ExcludeFocus(
                excluding: !_unlocked,
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => const ProfileSetupGate(),
                  ),
                ),
              ),
            ),
          ),
          if (!_unlocked)
            CalculatorScreen(
              busy: _busy,
              onTryPin: (digits) async {
                _pinController.text = digits;
                await _submitPin();

                if (!mounted || _unlocked) return null;
                return _error;
              },
            ),
        ],
      );
    }

    if (_record != null && !_storageFailed) {
      return CalculatorScreen(
        busy: _busy,
        onTryPin: (digits) async {
          _pinController.text = digits;
          await _submitPin();

          if (!mounted || _unlocked) return null;
          return _error;
        },
      );
    }

    final settingUp = _record == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(settingUp ? 'Create your PIN' : 'Enter your PIN'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      size: 56,
                      color: Color(0xFF00695C),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      settingUp
                          ? 'Choose a 6-digit PIN for everyday access.'
                          : 'Enter your 6-digit PIN to continue.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _pinController,
                      enabled: !_busy && !_storageFailed,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      enableSuggestions: false,
                      autocorrect: false,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: const InputDecoration(
                        labelText: '6-digit PIN',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (!RegExp(r'^\d{6}$').hasMatch(value ?? '')) {
                          return 'Enter exactly 6 digits.';
                        }
                        return null;
                      },
                    ),
                    if (settingUp) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmController,
                        enabled: !_busy && !_storageFailed,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        enableSuggestions: false,
                        autocorrect: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Confirm PIN',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value != _pinController.text) {
                            return 'The PINs do not match.';
                          }
                          return null;
                        },
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed:
                          _busy || _storageFailed ? null : _submitPin,
                      child: Text(
                        _busy
                            ? 'Please wait...'
                            : settingUp
                                ? 'Save PIN'
                                : 'Unlock',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({
    super.key,
    required this.busy,
    required this.onTryPin,
  });

  final bool busy;
  final Future<String?> Function(String digits) onTryPin;

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  String _display = '0';
  double? _first;
  String? _operator;
  bool _newEntry = true;

  String _format(double value) {
    if (!value.isFinite) return 'Error';
    if (value == 0) return '0';
    return value == value.truncateToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsPrecision(10);
  }

  void _clear() {
    _display = '0';
    _first = null;
    _operator = null;
    _newEntry = true;
  }

  void _calculate() {
    final second = double.tryParse(_display);
    if (_first == null || _operator == null || second == null) {
      return;
    }

    double result;
    switch (_operator) {
      case '+':
        result = _first! + second;
        break;
      case '−':
        result = _first! - second;
        break;
      case '×':
        result = _first! * second;
        break;
      case '÷':
        result = second == 0 ? double.nan : _first! / second;
        break;
      default:
        return;
    }

    _display = _format(result);
    _first = null;
    _operator = null;
    _newEntry = true;
  }

  Future<void> _press(String key) async {
    if (widget.busy) return;

    if (key == '=' &&
        _operator == null &&
        !_newEntry &&
        RegExp(r'^\d{6}$').hasMatch(_display)) {
      final message = await widget.onTryPin(_display);
      if (!mounted) return;

      setState(_clear);

      if (message != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
      return;
    }

    setState(() {
      if (key == 'C') {
        _clear();
      } else if (key == '⌫') {
        if (_newEntry || _display == 'Error') {
          _display = '0';
        } else {
          _display = _display.length > 1
              ? _display.substring(0, _display.length - 1)
              : '0';
        }
      } else if (['+', '−', '×', '÷'].contains(key)) {
        if (_operator != null && !_newEntry) {
          _calculate();
        }

        _first = double.tryParse(_display);
        _operator = _first == null ? null : key;
        _newEntry = true;
      } else if (key == '=') {
        _calculate();
      } else if (key == '±') {
        if (_display != '0' && _display != 'Error') {
          _display = _display.startsWith('-')
              ? _display.substring(1)
              : '-$_display';
        }
      } else if (key == '.') {
        if (_newEntry || _display == 'Error') {
          _display = '0.';
          _newEntry = false;
        } else if (!_display.contains('.')) {
          _display += '.';
        }
      } else {
        if (_newEntry || _display == 'Error') {
          _display = key;
          _newEntry = false;
        } else if (_display.length < 16) {
          // Preserve leading zeroes so PINs can start with zero.
          _display += key;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const keys = [
      'C', '⌫', '±', '÷',
      '7', '8', '9', '×',
      '4', '5', '6', '−',
      '1', '2', '3', '+',
      '0', '.', '=', 
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Calculator')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 100,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _display,
                          style: const TextStyle(fontSize: 48),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    children: [
                      for (final key in keys)
                        FilledButton.tonal(
                          onPressed:
                              widget.busy ? null : () => _press(key),
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(
                            key,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                    ],
                  ),
                  if (widget.busy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SosCountdownDialog extends StatefulWidget {
  const SosCountdownDialog({super.key});

  @override
  State<SosCountdownDialog> createState() =>
      _SosCountdownDialogState();
}

class _SosCountdownDialogState extends State<SosCountdownDialog>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _seconds = 10;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _finished) return;

      if (_seconds <= 1) {
        _finish(true);
      } else {
        setState(() => _seconds--);
      }
    });
  }

  void _finish(bool completed) {
    if (_finished || !mounted) return;

    _finished = true;
    _timer?.cancel();
    Navigator.of(context).pop(completed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Cancel this foreground demo if the app is hidden.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _finish(false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('SOS demo countdown'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$_seconds',
            style: const TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.bold,
              color: Color(0xFFB3261E),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'A simulated SOS event will be saved when the '
            'countdown ends. No messages or alerts will be sent.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => _finish(false),
          child: const Text('Cancel SOS'),
        ),
      ],
    );
  }
}

class AccountContactsGate extends StatefulWidget {
  const AccountContactsGate({
    super.key,
    required this.userId,
  });

  final String userId;

  @override
  State<AccountContactsGate> createState() =>
      _AccountContactsGateState();
}

class _AccountContactsGateState extends State<AccountContactsGate> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();

    // Never display a previous account's in-memory data.
    trustedContacts.value = [];
    demoReports.value = [];

    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .collection('contacts')
          .get(const GetOptions(source: Source.server));

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != widget.userId) {
        return;
      }

      trustedContacts.value = result.docs.map((document) {
        final data = document.data();

        return <String, String>{
          'id': document.id,
          'name': data['name'] as String,
          'phone': data['phone'] as String,
        };
      }).toList();

      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'Could not load your contacts. '
            'Check your internet connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loadContacts,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return PinGate(userId: widget.userId);
  }
}

class SosHistoryScreen extends StatelessWidget {
  const SosHistoryScreen({super.key});

  String _statusLabel(Map<String, dynamic> event) {
    if (event['isDemo'] == true ||
        event['status'] == 'simulated') {
      return 'Demo — no SMS sent';
    }

    switch (event['status']) {
      case 'submitted_to_android':
        return 'SMS submitted to Android';
      case 'partially_submitted':
        return 'Some SMS submissions failed';
      case 'submission_failed':
        return 'SMS submission failed';
      default:
        return 'Submission status unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F7),
      appBar: AppBar(
        title: const Text('SOS history'),
      ),
      body: SafeArea(
        child: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          initialData: FirebaseAuth.instance.currentUser,
          builder: (context, authSnapshot) {
            final user = authSnapshot.data;

            if (user == null) {
              return const Center(
                child: Text('Please sign in to view SOS history.'),
              );
            }

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              key: ValueKey(user.uid),
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .collection('events')
                  .orderBy('createdAt', descending: true)
                  .limit(100)
                  .snapshots(includeMetadataChanges: true),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Could not load SOS history. '
                        'Check your connection and account permissions.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final query = snapshot.data!;
                final events = query.docs
                    .where((doc) => doc.data()['type'] == 'sos')
                    .toList();

                return Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Recent SOS records. Submission to Android '
                        'does not confirm SMS delivery.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (query.metadata.isFromCache)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          'Showing cached history. '
                          'It may not include the latest records.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    Expanded(
                      child: events.isEmpty
                          ? const Center(
                              child: Text('No SOS records to show.'),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: events.length,
                              itemBuilder: (context, index) {
                                final document = events[index];
                                final event = document.data();

                                final isDemo =
                                    event['isDemo'] == true ||
                                    event['status'] == 'simulated';

                                final timestamp = event['createdAt'];
                                final date = timestamp is Timestamp
                                    ? timestamp.toDate().toLocal()
                                    : null;

                                final timeLabel = date == null
                                    ? 'Time not yet available'
                                    : '${MaterialLocalizations.of(context).formatMediumDate(date)} '
                                      '${TimeOfDay.fromDateTime(date).format(context)}';

                                final submitted =
                                    event['submittedCount'];
                                final failed = event['failedCount'];

                                final locationLabel =
                                    event['locationAvailable'] == true
                                        ? 'Location included'
                                        : event['locationAvailable'] == false
                                            ? 'Location unavailable'
                                            : 'Location status not recorded';

                                return Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          isDemo
                                              ? 'Demo SOS'
                                              : 'SOS attempt',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(timeLabel),
                                        const SizedBox(height: 8),
                                        Text(
                                          _statusLabel(event),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (!isDemo) ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            'Submitted to Android: '
                                            '${submitted is num ? submitted.toInt() : 'Not recorded'}',
                                          ),
                                          Text(
                                            'Submission failures: '
                                            '${failed is num ? failed.toInt() : 'Not recorded'}',
                                          ),
                                          const SizedBox(height: 8),
                                          Text(locationLabel),
                                          const SizedBox(height: 8),
                                          const Text(
                                            'Delivery not confirmed by this app.',
                                          ),
                                        ],
                                        if (document
                                            .metadata.hasPendingWrites) ...[
                                          const SizedBox(height: 8),
                                          const Text(
                                            'History sync pending',
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class ReportHistoryScreen extends StatelessWidget {
  const ReportHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report history')),
      body: SafeArea(
        child: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          initialData: FirebaseAuth.instance.currentUser,
          builder: (context, authSnapshot) {
            final user = authSnapshot.data;

            if (user == null) {
              return const Center(
                child: Text('Please sign in to view your reports.'),
              );
            }

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              key: ValueKey(user.uid),
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .collection('reports')
                  .orderBy('createdAt', descending: true)
                  .snapshots(includeMetadataChanges: true),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Could not load reports. Check your connection '
                        'and the published report rules.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final query = snapshot.data!;
                final reports = query.docs;

                return Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Reports saved to your account. '
                        'Not sent to authorities or monitored.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (query.metadata.isFromCache)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          'Showing cached reports. '
                          'The latest changes may not appear.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    Expanded(
                      child: reports.isEmpty
                          ? const Center(
                              child: Text('No saved reports yet.'),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: reports.length,
                              itemBuilder: (context, index) {
                                final document = reports[index];
                                final report = document.data();

                                final timestamp = report['createdAt'];
                                final date = timestamp is Timestamp
                                    ? timestamp.toDate().toLocal()
                                    : null;

                                final timeLabel = date == null
                                    ? 'Time pending'
                                    : '${MaterialLocalizations.of(context).formatMediumDate(date)} '
                                      '${TimeOfDay.fromDateTime(date).format(context)}';

                                return Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          report['type'] as String? ??
                                              'Incident',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          report['description']
                                                  as String? ??
                                              '',
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Area: ${report['location'] ?? ''}',
                                        ),
                                        const SizedBox(height: 8),
                                        Text('Created: $timeLabel'),
                                        const SizedBox(height: 8),
                                        Text(
                                          document.metadata.hasPendingWrites
                                              ? 'Waiting to sync'
                                              : 'Saved to account — not sent',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        TextButton.icon(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          label: const Text('Delete report'),
                                          style: TextButton.styleFrom(
                                            foregroundColor:
                                                const Color(0xFFB3261E),
                                          ),
                                          onPressed:
                                              document.metadata.hasPendingWrites
                                                  ? null
                                                  : () async {
                                              final confirmed =
                                                  await showDialog<bool>(
                                                context: context,
                                                builder: (dialogContext) =>
                                                    AlertDialog(
                                                  title: const Text(
                                                    'Delete report?',
                                                  ),
                                                  content: const Text(
                                                    'This permanently removes '
                                                    'this report from your '
                                                    'account. It cannot be undone.',
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                        dialogContext,
                                                        false,
                                                      ),
                                                      child: const Text(
                                                        'Keep report',
                                                      ),
                                                    ),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                        dialogContext,
                                                        true,
                                                      ),
                                                      child: const Text(
                                                        'Delete',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );

                                              if (confirmed != true ||
                                                  !context.mounted) {
                                                return;
                                              }

                                              final messenger =
                                                  ScaffoldMessenger.of(context);

                                              try {
                                                if (FirebaseAuth.instance
                                                        .currentUser?.uid !=
                                                    user.uid) {
                                                  messenger.showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        'Your account changed. '
                                                        'Reopen report history.',
                                                      ),
                                                    ),
                                                  );
                                                  return;
                                                }

                                                await document.reference
                                                    .delete();

                                                if (!context.mounted) return;

                                                messenger.showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'Report deleted.',
                                                    ),
                                                  ),
                                                );
                                              } catch (_) {
                                                if (!context.mounted) return;

                                                messenger.showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'Could not confirm deletion. '
                                                      'Check your connection '
                                                      'and report history.',
                                                    ),
                                                  ),
                                                );
                                              }
                                            },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
class ProfileSetupGate extends StatefulWidget {
  const ProfileSetupGate({super.key});

  @override
  State<ProfileSetupGate> createState() => _ProfileSetupGateState();
}

class _ProfileSetupGateState extends State<ProfileSetupGate> {
  late final Future<bool> _needsSetup;

  @override
  void initState() {
    super.initState();
    _needsSetup = _checkProfile();
  }

  Future<bool> _checkProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    try {
      final document = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('profile')
          .doc('details')
          .get()
          .timeout(const Duration(seconds: 5));

      return !document.exists;
    } catch (_) {
      // Profile loading must not prevent access to safety tools.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _needsSetup,
      builder: (context, snapshot) {
        // Keep SOS available while checking the profile.
        if (snapshot.connectionState != ConnectionState.done) {
          return const HomeScreen();
        }

        if (snapshot.data == true) {
          return UserProfileScreen(
            initialSetup: true,
            onFinished: () {
              if (mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const HomeScreen(),
                  ),
                );
              }
            },
          );
        }

        return const HomeScreen();
      },
    );
  }
}

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({
    super.key,
    this.initialSetup = false,
    this.onFinished,
  });

  final bool initialSetup;
  final VoidCallback? onFinished;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _surname = TextEditingController();
  final _preferredName = TextEditingController();
  final _phone = TextEditingController();

  late final String? _userId;
  bool _loading = true;
  bool _saving = false;
  bool _loadFailed = false;
  String? _error;

  DocumentReference<Map<String, dynamic>> get _profile =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(_userId!)
          .collection('profile')
          .doc('details');

  @override
  void initState() {
    super.initState();
    _userId = FirebaseAuth.instance.currentUser?.uid;
    _loadProfile();
  }

  @override
  void dispose() {
    _firstName.dispose();
    _surname.dispose();
    _preferredName.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
      _error = null;
    });

    try {
      if (_userId == null) {
        throw StateError('Not signed in');
      }

      final document = await _profile
          .get()
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (FirebaseAuth.instance.currentUser?.uid != _userId) {
        throw StateError('Account changed');
      }

      final data = document.data() ?? <String, dynamic>{};
      _firstName.text = data['firstName'] as String? ?? '';
      _surname.text = data['surname'] as String? ?? '';
      _preferredName.text = data['preferredName'] as String? ?? '';
      _phone.text = data['phone'] as String? ?? '';
    } catch (_) {
      if (!mounted) return;
      _loadFailed = true;
      _error = 'Could not load your profile. Try again, '
          'or return to the safety tools.';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _finish() {
    if (widget.onFinished != null) {
      widget.onFinished!();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _saveProfile() async {
    if (_saving || _loadFailed) return;
    if (!_formKey.currentState!.validate()) return;

    if (_userId == null ||
        FirebaseAuth.instance.currentUser?.uid != _userId) {
      setState(() => _error = 'Please sign in again.');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await _profile.set({
        'firstName': _firstName.text.trim(),
        'surname': _surname.text.trim(),
        'preferredName': _preferredName.text.trim(),
        'phone': _phone.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true)).timeout(
        const Duration(seconds: 10),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved.')),
      );
      _finish();
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not confirm that your profile synced. '
            'Check your connection and Firestore permissions. '
            'A pending save may sync when you reconnect.';
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _nameField({
    required TextEditingController controller,
    required String label,
    bool requiredField = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: !_saving,
        maxLength: 60,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          counterText: '',
        ),
        validator: (value) {
          if (requiredField && (value ?? '').trim().isEmpty) {
            return 'Please enter your first name.';
          }
          return null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initialSetup ? 'Set up your profile' : 'My profile',
        ),
        actions: [
          if (widget.initialSetup)
            TextButton(
              onPressed: _saving ? null : _finish,
              child: const Text('Skip for now'),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _finish,
                      child: const Text('Return to safety tools'),
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Only your first name is required to save '
                            'a profile. Other details are optional. '
                            'Your profile is saved to your account.',
                          ),
                          const SizedBox(height: 24),
                          if (_error != null) ...[
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          if (_loadFailed)
                            OutlinedButton(
                              onPressed: _loadProfile,
                              child: const Text('Retry loading profile'),
                            )
                          else ...[
                            _nameField(
                              controller: _firstName,
                              label: 'First name *',
                              requiredField: true,
                            ),
                            _nameField(
                              controller: _surname,
                              label: 'Surname (optional)',
                            ),
                            _nameField(
                              controller: _preferredName,
                              label: 'Preferred name (optional)',
                            ),
                            TextFormField(
                              controller: _phone,
                              enabled: !_saving,
                              keyboardType: TextInputType.phone,
                              maxLength: 25,
                              decoration: const InputDecoration(
                                labelText: 'Phone number (optional)',
                                hintText: '0821234567 or +27821234567',
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) {
                                final number = (value ?? '').trim();
                                if (number.isEmpty) return null;

                                final compact = number.replaceAll(
                                  RegExp(r'[\s()\-]'),
                                  '',
                                );

                                if (!RegExp(r'^\+?[0-9]{7,15}$')
                                    .hasMatch(compact)) {
                                  return 'Enter a valid phone number.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _saving ? null : _saveProfile,
                              icon: const Icon(Icons.save_outlined),
                              label: Text(
                                _saving ? 'Saving…' : 'Save profile',
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _saving ? null : _finish,
                            child: const Text('Return to safety tools'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
