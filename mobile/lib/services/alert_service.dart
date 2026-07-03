import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'report_service.dart';
import 'settings_service.dart';

class AlertService {
  static const _baseUrl = 'https://ai-dpmms-app.onrender.com';

  // In-memory guard: prevents race-condition duplicates within a single session.
  static final _inFlight = <String>{};

  /// Fire-and-forget — never throws.
  /// Pass [targetUid] to check a specific patient (doctor-side).
  /// Omit it to check the currently logged-in patient.
  static Future<void> analyzeAndAlert({String? targetUid}) async {
    final uid = targetUid ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_inFlight.contains(uid)) return;
    _inFlight.add(uid);
    try {

      final firestore = FirebaseFirestore.instance;

      //  Cooldown: max 1 alert per patient per day 
      final today = DateTime.now();
      final midnight = DateTime(today.year, today.month, today.day);

      final existing = await firestore
          .collection('alerts')
          .where('patientId', isEqualTo: uid)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(midnight))
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) return;

      //  Fetch patient profile 
      final userDoc = await firestore.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      final patientName = (userData['name'] as String?)?.trim().isNotEmpty == true
          ? userData['name'] as String
          : (userData['username'] as String?) ?? 'Patient';

      final medications = await _fetchMedicationNames(uid, firestore);
      final conditions =
          List<String>.from((userData['conditions'] as List?) ?? []);

      // No medications → nothing to alert about
      if (medications.isEmpty) return;

      //  Adherence: schedule-aware (matches the doctor home card) 
      final adherence = await ReportService().getAdherenceLast7Days(uid);

      //  Consecutive missed days (unrecorded past days count as missed) 
      int consecutiveMissed = 0;
      bool countingConsecutive = true;
      final checkToday = DateTime(today.year, today.month, today.day);

      for (int i = 1; i <= 7 && countingConsecutive; i++) {
        final date = checkToday.subtract(Duration(days: i));
        final dateStr = DateFormat('yyyy-MM-dd').format(date);

        final dayDoc = await firestore
            .collection('users')
            .doc(uid)
            .collection('daily_intake')
            .doc(dateStr)
            .get();

        bool anyTaken = false;
        bool anyMissed = false;

        if (!dayDoc.exists) {
          anyMissed = true; // unrecorded past day = missed
        } else {
          final dayData = dayDoc.data() ?? {};
          for (final value in dayData.values) {
            if (value is Map) {
              final status = value['status'] as String? ?? '';
              if (status == 'taken') {
                anyTaken = true;
              } else if (status == 'missed' || status == 'skipped') {
                anyMissed = true;
              }
            }
          }
        }

        if (anyTaken) {
          countingConsecutive = false;
        } else if (anyMissed) {
          consecutiveMissed++;
        }
      }

      // Approximate raw counts for the backend API
      const approxTotal = 7;
      final approxTaken = (adherence * approxTotal).round();
      final approxMissed = approxTotal - approxTaken;

      //  Try backend /analyze (5-second timeout) 
      bool handledByBackend = false;
      try {
        final response = await http
            .post(
              Uri.parse('$_baseUrl/analyze'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'patient_name': patientName,
                'medications': medications,
                'conditions': conditions,
                'total_doses': approxTotal,
                'taken_doses': approxTaken,
                'missed_doses': approxMissed,
                'consecutive_missed': consecutiveMissed,
              }),
            )
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          handledByBackend = true;
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['should_alert'] == true) {
            await _writeAlert(
              firestore, uid, patientName,
              data['message'] as String? ?? 'Medication adherence concern',
              data['severity'] as String? ?? 'warning',
            );
          }
        }
      } catch (_) {
        // Backend unreachable — fall through to client-side logic below
      }

      if (handledByBackend) return;

      //  Client-side fallback when backend is unavailable 
      final lang = SettingsService.instance.locale.languageCode;
      if (adherence <= 0.5) {
        await _writeAlert(
          firestore, uid, patientName,
          _fallbackMessage(lang, adherence, 'critical'),
          'critical',
        );
      }
      // adherence > 50% → no alert needed
    } catch (_) {
      // Silent — never interrupt the patient's dose logging flow
    } finally {
      _inFlight.remove(uid);
    }
  }

  static String _fallbackMessage(String lang, double adherence, String severity) {
    final pct = (adherence * 100).round();
    switch (lang) {
      case 'ar':
        return severity == 'critical'
            ? 'حرج: $pct% التزام بالدواء خلال الأيام الأخيرة'
            : 'التزام منخفض: $pct% خلال الأيام الأخيرة';
      case 'he':
        return severity == 'critical'
            ? 'קריטי: עמידה של $pct% בטיפול בימים האחרונים'
            : 'עמידה נמוכה: $pct% בימים האחרונים';
      default:
        return severity == 'critical'
            ? 'Critical: $pct% adherence over the last days'
            : 'Low adherence: $pct% over the last days';
    }
  }

  static Future<void> _writeAlert(
    FirebaseFirestore firestore,
    String uid,
    String patientName,
    String message,
    String severity,
  ) async {
    await firestore.collection('alerts').add({
      'patientId': uid,
      'patientName': patientName,
      'type': message,
      'severity': severity,
      'createdAt': FieldValue.serverTimestamp(),
      'isRead': false,
    });
  }

  static Future<List<String>> _fetchMedicationNames(
      String uid, FirebaseFirestore firestore) async {
    final snap = await firestore
        .collection('users')
        .doc(uid)
        .collection('medications')
        .get();
    return snap.docs
        .map((d) => (d.data()['name'] as String?) ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }
}
