import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_model.dart';

class SupabaseService {
    /// Sign up by inserting a new user into the users table.
    Future<Map<String, dynamic>?> signUpWithSimpleEmailPassword(
      String email,
      String password,
      String name,
    ) async {
      try {
        // Check if email already exists
        final existing = await _client
            .from('users')
            .select('id')
            .eq('email', email)
            .maybeSingle();
        if (existing != null) {
          throw 'An account with this email already exists.';
        }
        final response = await _client
            .from('users')
            .insert({
              'email': email,
              'password': password,
              'name': name,
              'created_at': DateTime.now().toIso8601String(),
            })
            .select()
            .single();
        return response;
      } catch (e) {
        rethrow;
      }
    }

    /// Sign in using email and password from users table (basic, not secure)
    Future<Map<String, dynamic>?> signInWithEmailAndPassword(String email, String password) async {
      try {
        final response = await _client
            .from('users')
            .select()
            .eq('email', email)
            .eq('password', password)
            .maybeSingle();
        return response;
      } catch (e) {
        return null;
      }
    }
  final SupabaseClient _client = Supabase.instance.client;

  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  bool _isValidUuid(String value) => _uuidRegex.hasMatch(value.trim());

  Future<T> _runWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
    Duration initialDelay = const Duration(milliseconds: 300),
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on SocketException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts) {
        await Future<void>.delayed(
          Duration(milliseconds: initialDelay.inMilliseconds * attempt),
        );
      }
    }

    throw lastError ?? 'Network request failed after retry attempts';
  }

  Future<String?> getAppUserIdByFirebaseUid(String firebaseUid) async {
    try {
      final response = await _client
          .from('users')
          .select('id')
          .eq('firebase_uid', firebaseUid)
          .maybeSingle();

      return response?['id']?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchHomeCategories() async {
    try {
      final response = await _client
          .from('home_categories')
          .select()
          .eq('is_active', true)
          .order('sort_order', ascending: true)
          .order('name', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to fetch home categories: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchDoctorListingData() async {
    try {
      final response = await _client
          .from('doctor_listing_view')
          .select()
          .order('full_name', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to fetch doctor listings: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchHospitalTreatmentPricing(
    String hospitalId,
  ) async {
    try {
      final response = await _client
          .from('hospital_treatment_prices')
          .select('price,is_active,treatments(name,category)')
          .eq('hospital_id', hospitalId)
          .eq('is_active', true)
          .order('price', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to fetch hospital treatment pricing: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchDoctorsByHospital(
    String hospitalId,
  ) async {
    try {
      final response = await _client
          .from('doctor_listing_view')
          .select(
            'doctor_id,full_name,specialty,hospital_id,hospital_name,city',
          )
          .eq('hospital_id', hospitalId)
          .order('full_name', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to fetch doctors by hospital: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchHospitalsWithCoordinates() async {
    try {
      final response = await _client
          .from('hospitals')
          .select('id,name,city,address,location_label,latitude,longitude')
          .not('latitude', 'is', null)
          .not('longitude', 'is', null)
          .order('name', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to fetch hospitals with coordinates: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchAvailableSlots({
    required String doctorId,
    required String hospitalId,
    required DateTime date,
    String appointmentMode = 'in_person',
  }) async {
    try {
      final dateLabel = date.toIso8601String().split('T').first;
      final baseQuery = _client
          .from('doctor_availability_slots')
          .select(
            'id,doctor_id,hospital_id,slot_date,start_time,end_time,slot_duration_minutes,booked_patients,max_patients,status,appointment_mode',
          )
          .eq('doctor_id', doctorId)
          .eq('slot_date', dateLabel)
          .eq('appointment_mode', appointmentMode)
          .eq('status', 'available');

      if (hospitalId.isNotEmpty) {
        final strictResponse = await baseQuery
            .eq('hospital_id', hospitalId)
            .order('start_time', ascending: true);
        final strictRows = List<Map<String, dynamic>>.from(strictResponse);
        if (strictRows.isNotEmpty) {
          return strictRows;
        }
      }

      final fallbackResponse = await baseQuery.order(
        'start_time',
        ascending: true,
      );
      final fallbackRows = List<Map<String, dynamic>>.from(fallbackResponse);

      return fallbackRows;
    } catch (e) {
      throw 'Failed to fetch available slots: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchUpcomingSlots({
    required String doctorId,
    required String hospitalId,
    required DateTime fromDate,
    int daysAhead = 14,
    String? appointmentMode,
  }) async {
    try {
      final fromLabel = fromDate.toIso8601String().split('T').first;
      final toDate = fromDate.add(Duration(days: daysAhead));
      final toLabel = toDate.toIso8601String().split('T').first;

      var query = _client
          .from('doctor_availability_slots')
          .select(
            'id,slot_date,start_time,end_time,slot_duration_minutes,booked_patients,max_patients,status',
          )
          .eq('doctor_id', doctorId)
          .eq('hospital_id', hospitalId)
          .gte('slot_date', fromLabel)
          .lte('slot_date', toLabel)
          .eq('status', 'available');

      if (appointmentMode != null && appointmentMode.isNotEmpty) {
        query = query.eq('appointment_mode', appointmentMode);
      }

      final response = await query
          .order('slot_date', ascending: true)
          .order('start_time', ascending: true);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to fetch upcoming slots: $e';
    }
  }

  Future<DateTime?> fetchFirstAvailableSlotDate({
    required String doctorId,
    required String hospitalId,
    required DateTime fromDate,
    String appointmentMode = 'in_person',
  }) async {
    try {
      final fromLabel = fromDate.toIso8601String().split('T').first;
      final baseQuery = _client
          .from('doctor_availability_slots')
          .select('slot_date,hospital_id')
          .eq('doctor_id', doctorId)
          .gte('slot_date', fromLabel)
          .eq('appointment_mode', appointmentMode)
          .eq('status', 'available');

      Map<String, dynamic>? response;
      if (hospitalId.isNotEmpty) {
        response = await baseQuery
            .eq('hospital_id', hospitalId)
            .order('slot_date', ascending: true)
            .limit(1)
            .maybeSingle();
      }

      response ??= await baseQuery
          .order('slot_date', ascending: true)
          .limit(1)
          .maybeSingle();

      final rawDate = response?['slot_date']?.toString();
      if (rawDate == null || rawDate.isEmpty) {
        return null;
      }
      return DateTime.tryParse(rawDate);
    } catch (_) {
      return null;
    }
  }

  Future<void> reserveSlotCapacity(String slotId) async {
    try {
      final slot = await _client
          .from('doctor_availability_slots')
          .select('booked_patients,max_patients,status')
          .eq('id', slotId)
          .single();

      final booked = (slot['booked_patients'] as num?)?.toInt() ?? 0;
      final max = (slot['max_patients'] as num?)?.toInt() ?? 0;
      if (booked >= max) {
        throw 'Selected slot is already full.';
      }

      final nextBooked = booked + 1;
      final nextStatus = nextBooked >= max ? 'full' : 'available';

      await _client
          .from('doctor_availability_slots')
          .update({'booked_patients': nextBooked, 'status': nextStatus})
          .eq('id', slotId);
    } catch (e) {
      throw 'Failed to reserve slot capacity: $e';
    }
  }

  Future<void> createAppointment({
    required String patientUserId,
    required String doctorId,
    required String hospitalId,
    required DateTime appointmentDate,
    required String startTime,
    String? endTime,
    String appointmentMode = 'in_person',
    String status = 'upcoming',
    double? amount,
    String? slotId,
    String? ticketNumber,
    String? qrPayload,
  }) async {
    try {
      final dateLabel = appointmentDate.toIso8601String().split('T').first;
      await _client.from('appointments').insert({
        'patient_user_id': patientUserId,
        'doctor_id': doctorId,
        'hospital_id': hospitalId,
        'appointment_date': dateLabel,
        'start_time': startTime,
        'end_time': endTime,
        'appointment_mode': appointmentMode,
        'status': status,
        'amount': amount,
        'slot_id': slotId,
        'ticket_number': ticketNumber,
        'qr_payload': qrPayload,
      });
    } catch (e) {
      throw 'Failed to create appointment: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchAppointmentsByFirebaseUid({
    required String firebaseUid,
    required String status,
  }) async {
    try {
      final userId = await getAppUserIdByFirebaseUid(firebaseUid);
      if (userId == null) {
        return <Map<String, dynamic>>[];
      }

      final rows = await _client
          .from('appointments')
          .select(
            'id,appointment_date,start_time,created_at,status,appointment_mode,ticket_number,qr_payload,amount,doctor_id,hospital_id,doctors(full_name,specialty),hospitals(name,city)',
          )
          .eq('patient_user_id', userId)
          .eq('status', status)
          .order('created_at', ascending: false);

      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      throw 'Failed to fetch appointments: $e';
    }
  }

  /// Fetch appointments directly by user table row ID (no Firebase needed)
  Future<List<Map<String, dynamic>>> fetchAppointmentsByUserId({
    required String userId,
    required String status,
  }) async {
    try {
      final rows = await _client
          .from('appointments')
          .select(
            'id,appointment_date,start_time,created_at,status,appointment_mode,ticket_number,qr_payload,amount,doctor_id,hospital_id,doctors(full_name,specialty),hospitals(name,city)',
          )
          .eq('patient_user_id', userId)
          .eq('status', status)
          .order('created_at', ascending: false);

      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      throw 'Failed to fetch appointments: $e';
    }
  }

  Future<void> updateAppointmentStatus({
    required String appointmentId,
    required String status,
  }) async {
    try {
      await _client
          .from('appointments')
          .update({'status': status})
          .eq('id', appointmentId);
    } catch (e) {
      throw 'Failed to update appointment status: $e';
    }
  }

  Future<UserModel?> getUserByFirebaseUid(String firebaseUid) async {
    try {
      final response = await _client
          .from('users')
          .select()
          .eq('firebase_uid', firebaseUid)
          .maybeSingle();

      if (response == null) return null;
      return UserModel.fromJson(response);
    } catch (e) {
      throw 'Failed to fetch user profile: $e';
    }
  }

  Future<UserModel> createUser(UserModel user) async {
    try {
      final response = await _client
          .from('users')
          .insert(user.toJson())
          .select()
          .single();

      return UserModel.fromJson(response);
    } catch (e) {
      throw 'Failed to create user profile: $e';
    }
  }

  Future<UserModel> updateUser(String id, Map<String, dynamic> data) async {
    try {
      final response = await _client
          .from('users')
          .update(data)
          .eq('id', id)
          .select()
          .single();

      return UserModel.fromJson(response);
    } catch (e) {
      throw 'Failed to update user profile: $e';
    }
  }

  Future<String?> uploadProfileImage(String userId, File imageFile) async {
    try {
      final fileExt = imageFile.path.split('.').last;
      final fileName = '$userId.$fileExt';
      final filePath = 'profile_images/$fileName';

      await _client.storage
          .from('avatars')
          .upload(
            filePath,
            imageFile,
            fileOptions: const FileOptions(upsert: true),
          );

      final imageUrl = _client.storage.from('avatars').getPublicUrl(filePath);
      return imageUrl;
    } catch (e) {
      throw 'Failed to upload profile image: $e';
    }
  }

  Future<bool> checkProfileExists(String firebaseUid) async {
    try {
      final response = await _client
          .from('users')
          .select('id')
          .eq('firebase_uid', firebaseUid)
          .maybeSingle();

      return response != null;
    } catch (e) {
      return false;
    }
  }

  Future<void> deleteUser(String id) async {
    try {
      await _client.from('users').delete().eq('id', id);
    } catch (e) {
      throw 'Failed to delete user: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchDoctorTreatmentsByHospital({
    required String doctorId,
    required String hospitalId,
  }) async {
    try {
      // Fetch doctor treatments with treatment details
      final doctorTreatments = await _runWithRetry(
        () => _client
            .from('doctor_treatments')
            .select('treatment_id,offered_as,notes,treatments(id,name,category)')
            .eq('doctor_id', doctorId)
            .timeout(const Duration(seconds: 12)),
      );

      // Fetch hospital treatment prices
      final hospitalPrices = await _runWithRetry(
        () => _client
            .from('hospital_treatment_prices')
            .select('treatment_id,price')
            .eq('hospital_id', hospitalId)
            .eq('is_active', true)
            .timeout(const Duration(seconds: 12)),
      );

      // Create price map for quick lookup
      final priceMap = <String, double>{};
      for (final price in hospitalPrices) {
        final treatmentId = price['treatment_id']?.toString() ?? '';
        final priceValue = (price['price'] as num?)?.toDouble() ?? 0;
        priceMap[treatmentId] = priceValue;
      }

      // Combine data: only include treatments that have prices at this hospital
      final result = <Map<String, dynamic>>[];
      for (final row in doctorTreatments) {
        final treatmentId = row['treatment_id']?.toString() ?? '';
        if (priceMap.containsKey(treatmentId)) {
          result.add({
            ...row,
            'price': priceMap[treatmentId],
          });
        }
      }

      return result;
    } on SocketException {
      return <Map<String, dynamic>>[];
    } on TimeoutException {
      return <Map<String, dynamic>>[];
    } catch (e) {
      throw 'Failed to fetch doctor treatments: $e';
    }
  }

  // ============================================
  // MEDICATION MANAGEMENT
  // ============================================

  /// Save or update a medication
  Future<void> saveMedication({
    required String userId,
    required String medicationId,
    required String medicationName,
    required String dosage,
    required String medicationType,
    required List<String> timingLabels,
    required List<String> timingValues,
    required String timeFrequency,
    required int? durationDays,
    required DateTime startDate,
    required DateTime? expiryDate,
    required String instructions,
    required String warnings,
    required bool alarmEnabled,
    required bool isActive,
  }) async {
    try {
      final data = {
        'user_id': userId,
        'medication_name': medicationName,
        'dosage': dosage,
        'medication_type': medicationType,
        'timing_labels': timingLabels,
        'timing_values': timingValues,
        'time_frequency': timeFrequency,
        'start_date': startDate.toIso8601String().split('T').first,
        'expiry_date': expiryDate?.toIso8601String().split('T').first,
        'instructions': instructions,
        'warnings': warnings,
        'alarm_enabled': alarmEnabled,
        'is_active': isActive,
        'updated_at': DateTime.now().toIso8601String(),
      };

      // Check if medication exists
      final existing = await _client
          .from('medications')
          .select('id')
          .eq('id', medicationId)
          .maybeSingle();

      if (existing != null) {
        // Update existing
        await _client
            .from('medications')
            .update(data)
            .eq('id', medicationId);
      } else {
        // Insert new
        data['id'] = medicationId;
        data['created_at'] = DateTime.now().toIso8601String();
        await _client
            .from('medications')
            .insert(data);
      }
    } catch (e) {
      throw 'Failed to save medication: $e';
    }
  }

  /// Save medication alarm (for each dose)
  Future<void> saveMedicationAlarm({
    required String medicationId,
    required String userId,
    required String alarmId,
    required int doseNumber,
    required String doseLabel,
    required String alarmTime,
    required bool isEnabled,
    required String notificationType,
    required int notifyBeforeMinutes,
  }) async {
    try {
      final normalizedAlarmId = _isValidUuid(alarmId) ? alarmId : null;

      final data = {
        'medication_id': medicationId,
        'user_id': userId,
        'dose_number': doseNumber,
        'alarm_label': doseLabel,
        'alarm_time': alarmTime,
        'is_enabled': isEnabled,
        'notification_type': notificationType,
        'notify_before_minutes': notifyBeforeMinutes,
        'updated_at': DateTime.now().toIso8601String(),
      };

      Map<String, dynamic>? existing;

      if (normalizedAlarmId != null) {
        // Valid UUID: update by explicit alarm id.
        existing = await _client
            .from('medication_alarms')
            .select('id')
            .eq('id', normalizedAlarmId)
            .maybeSingle();
      } else {
        // Fallback for legacy/local ids (for example "alarm_1").
        // Update by medication + dose so we never pass invalid UUID to Postgres.
        existing = await _client
            .from('medication_alarms')
            .select('id')
            .eq('medication_id', medicationId)
            .eq('dose_number', doseNumber)
            .maybeSingle();
      }

      if (existing != null) {
        // Update existing
        await _client
            .from('medication_alarms')
            .update(data)
            .eq('id', existing['id']);
      } else {
        // Insert new
        if (normalizedAlarmId != null) {
          data['id'] = normalizedAlarmId;
        }
        data['created_at'] = DateTime.now().toIso8601String();
        await _client
            .from('medication_alarms')
            .insert(data);
      }
    } catch (e) {
      throw 'Failed to save medication alarm: $e';
    }
  }

  /// Fetch all medications for a user
  Future<List<Map<String, dynamic>>> fetchMedicationsByUserId(
    String userId,
  ) async {
    return fetchMedicationsByUserIds([userId]);
  }

  /// Fetch all medications for a user by any known identifier.
  /// This supports both legacy rows saved with users.id and rows saved with firebase_uid.
  Future<List<Map<String, dynamic>>> fetchMedicationsByUserIds(
    List<String> userIds,
  ) async {
    try {
      final normalizedUserIds = userIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (normalizedUserIds.isEmpty) {
        return [];
      }

      final query = _client.from('medications').select().eq('is_active', true);

      if (normalizedUserIds.length == 1) {
        return await query
            .eq('user_id', normalizedUserIds.first)
            .order('created_at', ascending: false);
      }

      final orFilter = normalizedUserIds
          .map((id) => 'user_id.eq.$id')
          .join(',');

      return await query
          .or(orFilter)
          .order('created_at', ascending: false);
    } catch (e) {
      throw 'Failed to fetch medications: $e';
    }
  }

  Future<String> uploadMedicalReport({
    required String userId,
    required File file,
    required String originalFileName,
  }) async {
    try {
      final safeName = originalFileName
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')
          .toLowerCase();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_$safeName';
      final filePath = '$userId/$fileName';

      await _client.storage
          .from('medical-reports')
          .upload(
            filePath,
            file,
            fileOptions: const FileOptions(
              upsert: false,
              contentType: 'application/pdf',
            ),
          );

      return _client.storage.from('medical-reports').getPublicUrl(filePath);
    } catch (e) {
      throw 'Failed to upload medical report: $e';
    }
  }

  /// Fetch all alarms for a medication
  Future<List<Map<String, dynamic>>> fetchMedicationAlarms(
    String medicationId,
  ) async {
    try {
      return await _client
          .from('medication_alarms')
          .select()
          .eq('medication_id', medicationId)
          .order('dose_number', ascending: true);
    } catch (e) {
      throw 'Failed to fetch medication alarms: $e';
    }
  }

  /// Delete a medication
  Future<void> deleteMedication(String medicationId) async {
    try {
      await _client
          .from('medications')
          .update({'is_active': false})
          .eq('id', medicationId);
    } catch (e) {
      throw 'Failed to delete medication: $e';
    }
  }

  /// Delete medication alarm
  Future<void> deleteMedicationAlarm(String alarmId) async {
    try {
      await _client
          .from('medication_alarms')
          .delete()
          .eq('id', alarmId);
    } catch (e) {
      throw 'Failed to delete medication alarm: $e';
    }
  }
}
