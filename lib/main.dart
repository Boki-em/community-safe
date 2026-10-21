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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static bool _sosInProgress = false;

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

      final response = await const MethodChannel('community_safe/sms')
          .invokeMapMethod<String, dynamic>(
        'sendSos',
        {'contacts': contacts},
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
                        'Prototype: SOS saves simulated events only. '
                        'The Send test SMS button sends a real text '
                        'only after you confirm. SMS charges may apply. '
                        'No emergency services are contacted.',
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
                          {'contacts': contacts},
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

                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const ReportHistoryScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.history),
                    label: const Text('Demo report history'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(20),
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

  @override
  void dispose() {
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _previewReport() async {
    if (!_formKey.currentState!.validate()) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Demo report preview'),
        content: SingleChildScrollView(
          child: Text(
            'Type: $_incidentType\n\n'
            'Description: ${_descriptionController.text.trim()}\n\n'
            'Location: ${_locationController.text.trim()}\n\n'
            'This report has not been saved or sent. '
            'No emergency services or contacts have been notified.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () {
              demoReports.value = [
                {
                  'type': _incidentType!,
                  'description': _descriptionController.text.trim(),
                  'location': _locationController.text.trim(),
                  'createdAt': DateTime.now()
                      .toLocal()
                      .toString()
                      .split('.')
                      .first,
                },
                ...demoReports.value,
              ];

              Navigator.pop(dialogContext);
              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Demo report added to history. Nothing was sent.',
                  ),
                ),
              );
            },
            child: const Text('Add to demo history'),
          ),
        ],
      ),
    );
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
                      'Demo form: use fictional details. '
                      'Reports are not saved, sent, or monitored.',
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
                      onPressed: _previewReport,
                      icon: const Icon(Icons.preview_outlined),
                      label: const Text('Preview demo report'),
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

class ReportHistoryScreen extends StatelessWidget {
  const ReportHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Demo report history')),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Demo only. Reports are not sent and disappear '
                'when the app restarts.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<List<Map<String, String>>>(
                valueListenable: demoReports,
                builder: (context, reports, child) {
                  if (reports.isEmpty) {
                    return const Center(child: Text('No demo reports yet.'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: reports.length,
                    itemBuilder: (context, index) {
                      final report = reports[index];

                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                report['type']!,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(report['description']!),
                              const SizedBox(height: 8),
                              Text('Area: ${report['location']}'),
                              const SizedBox(height: 8),
                              Text('Created: ${report['createdAt']}'),
                              const SizedBox(height: 8),
                              const Text(
                                'Demo only — not sent',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
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
                  'Explore the types of help available.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Information only. This page does not contact '
                      'a service. Verified contact details will be '
                      'added in a later step.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                SizedBox(height: 16),
                _SupportCategory(
                  icon: Icons.local_police_outlined,
                  title: 'Emergency assistance',
                  description:
                      'Emergency services can help when someone '
                      'is in immediate danger.',
                ),
                _SupportCategory(
                  icon: Icons.volunteer_activism_outlined,
                  title: 'Gender-based violence support',
                  description:
                      'Specialist services can offer support '
                      'after abuse, threats, or sexual violence.',
                ),
                _SupportCategory(
                  icon: Icons.chat_bubble_outline,
                  title: 'Counselling and emotional support',
                  description:
                      'A counsellor can help you talk through '
                      'difficult experiences and explore next steps.',
                ),
                _SupportCategory(
                  icon: Icons.home_outlined,
                  title: 'Shelters and safe accommodation',
                  description:
                      'Shelter services may help you find temporary '
                      'safe accommodation and practical support.',
                ),
                _SupportCategory(
                  icon: Icons.gavel_outlined,
                  title: 'Legal assistance',
                  description:
                      'Legal support can help explain your rights, '
                      'protection orders, and reporting options.',
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
  });

  final IconData icon;
  final String title;
  final String description;

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

    if (_unlocked) {
      // Keep safety screens inside this navigator so locking hides
      // any open report or contact screen as well.
      return Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const HomeScreen(),
        ),
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