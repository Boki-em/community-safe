# Community Safe

Community Safe is an Android safety app prototype built for the
**Safer Communities and Gender-Based Violence Response** challenge.

It helps users discreetly access safety tools, request help from trusted
contacts, keep incident records, and find South African support services.

## Current features

- Working calculator interface with secret PIN access.
- Email and password registration, login, and sign-out.
- Account-specific trusted contacts.
- SOS confirmation and a cancellable countdown.
- Emergency SMS submission through the Android phone's SIM.
- Location link, capture time, and estimated accuracy when available.
- SOS messages without location when a location fix is unavailable.
- Account-based SOS history.
- Incident report preview, saving, history, and deletion.
- Support service numbers, dialler links, and official source links.

## How SOS works

1. The user adds trusted contacts.
2. The user selects SOS and reviews the recipients.
3. After confirmation, a countdown provides an opportunity to cancel.
4. The app requests location and submits an emergency SMS to Android
   for each distinct recipient number.
5. The app attempts to save the submission result to the user's account.

If location cannot be obtained, the message states that it is unavailable.

Submitting an SMS to Android does **not** confirm that the network sent
it or that the recipient received it. The app currently does not track
sending or delivery callbacks.

## Technologies

- Flutter and Dart
- Kotlin for Android SMS and location integration
- Firebase Authentication
- Cloud Firestore
- Flutter Secure Storage and Cryptography for PIN protection
- URL Launcher for support links
- Git and GitHub

## Project structure

- `lib/main.dart` — application screens and Flutter logic
- `lib/firebase_options.dart` — generated Firebase client configuration
- `android/app/src/main/AndroidManifest.xml` — Android configuration
- `android/app/src/main/kotlin/com/example/community_safe/`
  — native Android helpers, including `MainActivity`, `TrustedSmsTest`,
  and `SosLocation`
- `firestore.rules` — versioned Firestore security rules
- `test/widget_test.dart` — login form validation test

## Setup

### Requirements

- Flutter SDK compatible with the Dart SDK constraint in `pubspec.yaml`
- Android SDK and Flutter Android development tools
- A Firebase project
- An Android phone with USB debugging enabled
- An active SMS-capable SIM for SMS testing

### Install dependencies

From the project folder:

```bash
flutter pub get
```

### Firebase configuration

The app requires Firebase Authentication and Cloud Firestore.

When using your own Firebase project:

1. Register the Android app with Firebase.
2. Enable Email/Password authentication.
3. Create a Firestore database.
4. Configure the app using the FlutterFire CLI:

```bash
flutterfire configure
```

5. Publish the rules in `firestore.rules` to the correct Firebase project.

Keeping `firestore.rules` in Git does not automatically publish it.

Do not commit service-account credentials, private keys, signing
keystores, passwords, or real incident evidence.

### Run on Android

Connect the phone, accept the USB debugging prompt, and run:

```bash
flutter devices
flutter run
```

Allow the required SMS and location permissions. On a phone with multiple
SIMs, select a default SMS SIM.

### Run in Chrome

```bash
flutter run -d chrome
```

Chrome can be used for screens, authentication, reports, and account data.
Native SIM SMS and Android hardware-button functionality require Android.

Dialler links depend on a compatible phone application being available.

## Data and privacy

Account data is organised under the signed-in user's Firebase UID:

- `users/{uid}/contacts`
- `users/{uid}/events`
- `users/{uid}/reports`

Firestore rules restrict client access to the account owner and validate
permitted writes.

Incident reports are saved to the user's account. They are not sent to
authorities, support services, or trusted contacts, and are not monitored.

Reports do not currently have app-level end-to-end encryption. The
prototype does not include an encrypted evidence-file vault.

The calculator interface provides discreet entry, but does not guarantee
that the app, notifications, SMS records, or account activity are hidden.

Use fictional information during demonstrations.

## Testing

Run the automated checks:

```bash
flutter test
flutter analyze
```

### Checks completed during development

- Login form rejects an invalid email and empty password.
- Flutter analysis completed with no reported issues.
- Calculator calculations and secret PIN entry were manually checked.
- SOS countdown cancellation was checked.
- Trusted contacts received SOS messages with location links on Android.
- Missing SMS permission produced an explanatory message.
- SOS messages were received when location was unavailable.
- SOS history displayed saved records.
- Incident reports remained after a browser refresh.
- Report deletion and deletion cancellation were checked.
- Sign-out returned to email login.
- Different accounts displayed their own contacts, reports, and SOS history.
- Support links were manually checked.

These checks are development observations, not a full security audit.
Account separation still needs direct unauthorised-access testing.

### Next Android checks

- Calculator and PIN regression check
- Incident report creation, history, and deletion
- SOS and report history navigation
- Support dialler numbers, without placing test calls
- Sign-out and account switching
- App restart behaviour
- Final signed APK installation

Never place test calls to emergency or support services. Inform trusted
contacts before testing real SOS messages. SMS charges may apply.

## Limitations

- Community Safe is a prototype.
- SOS does not automatically contact emergency services.
- SMS depends on permission, SIM service, network availability,
  and sufficient balance or an applicable SMS allowance.
- Location can be unavailable or inaccurate.
- SMS delivery is not confirmed by the app.
- Saving and synchronising account records requires connectivity.
- Support details and service availability may change.
- No production security or reliability guarantees have been established.

## Development status

### Planned for the hackathon

A timed safety check-in workflow:

- Set a check-in deadline.
- Confirm safety before the deadline.
- Cancel an active check-in.
- Handle a missed check-in.
- Test and document behaviour when the app is closed or the phone is locked.

This feature is not implemented yet.

### Experimental Android trigger

A five-second Volume Down trigger was prototyped and tested while the
home screen was open, then removed from the current code.

Further experimentation is planned. Background and locked-phone
activation are not implemented or verified.

### Deferred work

- Encrypted evidence-file vault
- Independent trusted-contact verification
- SMS sending and delivery status tracking

Pre-event development and work completed during the hackathon will be
identified separately in project updates.

## Developer

Emily Moeletsi

Built with Flutter, Firebase, and Kotlin for the FNB App of the Year
Hackathon 2026.
