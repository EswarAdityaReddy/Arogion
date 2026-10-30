import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'main.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import 'screens/agora_call_screen.dart';
import 'screens/profile_screen.dart';
import 'services/local_notification_service.dart';
import 'services/supabase_service.dart';
import 'widgets/medical_loader.dart';

class BottomNavBar extends StatefulWidget {
  const BottomNavBar({super.key});

  @override
  State<BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<BottomNavBar> {
  int _currentIndex = 0;

  late final List<Widget> _screens = [
    HomeScreen(
      onOpenDoctor: _openDoctorDetails,
      onOpenHospital: _openHospitalDetails,
    ),
    const LocationScreen(),
    const AppointmentsScreen(),
    const MedicationsAndPrescriptionsScreen(),
    const ProfileScreen(),
  ];

  void _openDoctorDetails(Doctor doctor) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DoctorDetailsScreen(doctor: doctor)),
    );
  }

  void _openHospitalDetails(HospitalSummary hospital) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HospitalDetailsScreen(
          hospitalId: hospital.id,
          hospitalName: hospital.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.only(bottom: 10, left: 8, right: 8),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F223A).withAlpha(22),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(index: 0, icon: Icons.home_rounded),
              _navItem(index: 1, icon: Icons.location_on_outlined),
              _navItem(index: 2, icon: Icons.calendar_today_rounded),
              _navItem(index: 3, icon: Icons.medication),
              _navItem(index: 4, icon: Icons.person_outline_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem({required int index, required IconData icon}) {
    final bool active = index == _currentIndex;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? const Color(0xFF0F223A) : const Color(0xFFF2F4F8),
        ),
        child: Icon(
          icon,
          color: active ? Colors.white : const Color(0xFF8A94A6),
          size: 22,
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.onOpenDoctor,
    required this.onOpenHospital,
    super.key,
  });

  final ValueChanged<Doctor> onOpenDoctor;
  final ValueChanged<HospitalSummary> onOpenHospital;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SupabaseService _supabaseService = SupabaseService();

  bool _isLoading = true;
  String? _errorMessage;
  String _locationLabel = 'Fetching location...';
  List<DoctorCategory> _categories = <DoctorCategory>[];
  List<Doctor> _allDoctors = <Doctor>[];

  List<Doctor> get _topDoctors {
    final sorted = List<Doctor>.from(_allDoctors);
    sorted.sort((a, b) {
      final ratingCompare = b.rating.compareTo(a.rating);
      if (ratingCompare != 0) {
        return ratingCompare;
      }
      return b.reviewsCount.compareTo(a.reviewsCount);
    });
    return sorted;
  }

  List<HospitalSummary> get _allHospitals {
    final Map<String, HospitalSummary> byHospital = <String, HospitalSummary>{};
    for (final doctor in _allDoctors) {
      final key = doctor.hospitalId.isNotEmpty ? doctor.hospitalId : doctor.hospital;
      if (key.isEmpty) {
        continue;
      }

      final existing = byHospital[key];
      if (existing == null) {
        byHospital[key] = HospitalSummary(
          id: key,
          name: doctor.hospital,
          city: doctor.hospitalCity,
          doctorsCount: 1,
        );
      } else {
        byHospital[key] = existing.copyWith(
          doctorsCount: existing.doctorsCount + 1,
        );
      }
    }

    return byHospital.values.toList(growable: false);
  }

  List<HospitalSummary> get _nearbyHospitals => _allHospitals;

  @override
  void initState() {
    super.initState();
    _loadDoctors();
    _loadCurrentLocation();
  }

  Future<void> _loadDoctors() async {
    try {
      final results = await Future.wait([
        _supabaseService.fetchDoctorListingData(),
        _supabaseService.fetchHomeCategories(),
      ]);

      final doctorRows = List<Map<String, dynamic>>.from(results[0] as List);
      final categoryRows = List<Map<String, dynamic>>.from(results[1] as List);

      // Create initial doctors from rows
      final initialDoctors = doctorRows
          .map(Doctor.fromListingRow)
          .toList(growable: false);

      // Group doctors by ID and merge hospitals
      final doctors = _groupDoctorsByIdAndMergeHospitals(initialDoctors);

      final categories = categoryRows
          .map(DoctorCategory.fromDbRow)
          .toList(growable: false);

      if (!mounted) {
        return;
      }

      setState(() {
        _categories = categories;
        _allDoctors = doctors;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  // Group doctors by ID and merge their hospitals
  List<Doctor> _groupDoctorsByIdAndMergeHospitals(List<Doctor> doctors) {
    final groupedMap = <String, Doctor>{};

    for (final doctor in doctors) {
      if (groupedMap.containsKey(doctor.id)) {
        final existing = groupedMap[doctor.id]!;
        // Merge hospitals if not already present
        final mergedHospitals = [...existing.hospitals];
        for (final hospital in doctor.hospitals) {
          if (!mergedHospitals.any((h) => h.id == hospital.id)) {
            mergedHospitals.add(hospital);
          }
        }
        groupedMap[doctor.id] = existing.copyWith(hospitals: mergedHospitals);
      } else {
        groupedMap[doctor.id] = doctor;
      }
    }

    return groupedMap.values.toList();
  }

  Future<void> _loadCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() => _locationLabel = 'Location service off');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        if (!mounted) return;
        setState(() => _locationLabel = 'Location permission denied');
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() => _locationLabel = 'Enable location in settings');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final places = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      String label = 'Current location';
      if (places.isNotEmpty) {
        final place = places.first;
        final city = (place.locality ?? '').trim().isNotEmpty
            ? place.locality!.trim()
            : (place.subAdministrativeArea ?? '').trim();
        final country = (place.country ?? '').trim();

        if (city.isNotEmpty && country.isNotEmpty) {
          label = '$city, $country';
        } else if (country.isNotEmpty) {
          label = country;
        } else if (city.isNotEmpty) {
          label = city;
        }
      }

      if (!mounted) return;
      setState(() => _locationLabel = label);
    } catch (_) {
      if (!mounted) return;
      setState(() => _locationLabel = 'Unable to fetch location');
    }
  }

  String _normalizeSearchText(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9 ]'),
      ' ',
    );
    return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<Doctor> _doctorsForCategory(DoctorCategory category) {
    final categoryKey = _normalizeSearchText(category.name);
    if (categoryKey.isEmpty || categoryKey == 'general') {
      return _allDoctors;
    }

    return _allDoctors
        .where((doctor) {
          final speciality = _normalizeSearchText(doctor.speciality);
          final treatments = _normalizeSearchText(doctor.treatments.join(' '));
          return speciality.contains(categoryKey) ||
              treatments.contains(categoryKey) ||
              categoryKey.contains(speciality);
        })
        .toList(growable: false);
  }

  void _openSearchPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchDiscoveryScreen(
          allDoctors: _allDoctors,
          categories: _categories,
          hospitals: _allHospitals,
          onOpenDoctor: widget.onOpenDoctor,
          onOpenHospital: widget.onOpenHospital,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Doctor? featuredDoctor = _allDoctors.isNotEmpty
        ? _allDoctors.first
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Location',
                style: TextStyle(fontSize: 12, color: Color(0xFF97A1B2)),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.location_on,
                    size: 16,
                    color: Color(0xFF0F223A),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _locationLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1C2A3A),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.my_location, size: 16),
                    onPressed: _loadCurrentLocation,
                    tooltip: 'Refresh location',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.notifications_outlined, size: 20),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No new notifications')),
                      );
                    },
                    tooltip: 'Notifications',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF2F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.search,
                      color: Color(0xFF9AA4B2),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        readOnly: true,
                        onTap: _openSearchPage,
                        decoration: const InputDecoration(
                          hintText: 'Search doctor, treatment, hospital...',
                          hintStyle: TextStyle(
                            color: Color(0xFF9AA4B2),
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (featuredDoctor != null) _heroBanner(doctor: featuredDoctor),
              const SizedBox(height: 10),
              _sectionHeader(
                'Categories',
                onSeeAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CategoriesListScreen(
                        categories: _categories,
                        allDoctors: _allDoctors,
                        onOpenDoctor: widget.onOpenDoctor,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              SizedBox(height: 94, child: _categoryGrid()),
              const SizedBox(height: 8),
              _buildHomeListsSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeListsSection() {
    if (_isLoading) {
      return const Center(child: MedicalLoader(size: 92));
    }

    if (_errorMessage != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Failed to load doctors from database. $_errorMessage',
          style: const TextStyle(color: Color(0xFFB00020), fontSize: 13),
        ),
      );
    }

    if (_allDoctors.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'No doctors found.',
          style: TextStyle(color: Color(0xFF6F7B8C), fontSize: 14),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          'Top Doctors',
          onSeeAll: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DoctorsListScreen(
                  title: 'All Doctors',
                  doctors: _topDoctors,
                  onOpenDoctor: widget.onOpenDoctor,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        SizedBox(height: 176, child: _topDoctorsScroller()),
        const SizedBox(height: 8),
        _sectionHeader(
          'Nearby Hospitals',
          onSeeAll: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HospitalsListScreen(
                  hospitals: _allHospitals,
                  onOpenHospital: widget.onOpenHospital,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        SizedBox(height: 170, child: _nearbyHospitalsScroller()),
      ],
    );
  }

  Widget _heroBanner({required Doctor doctor}) {
    return Container(
      height: 120,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFF8BC3CC), Color(0xFFABD6DF)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 14,
            top: 16,
            child: SizedBox(
              width: 180,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Looking for\nSpecialist Doctors?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Schedule an appointment with\nour top doctors.',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 10,
            top: 10,
            child: CircleAvatar(
              radius: 40,
              backgroundColor: Colors.white.withAlpha(50),
              child: const Icon(
                Icons.local_hospital,
                size: 34,
                color: Colors.white,
              ),
            ),
          ),
          Positioned(
            bottom: 12,
            left: 128,
            child: Row(children: [_dot(true), _dot(false), _dot(false)]),
          ),
        ],
      ),
    );
  }

  Widget _dot(bool active) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      width: active ? 14 : 6,
      height: 6,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: active ? Colors.white : Colors.white54,
      ),
    );
  }

  Widget _sectionHeader(String title, {VoidCallback? onSeeAll}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF202B38),
          ),
        ),
        GestureDetector(
          onTap: onSeeAll,
          child: Text(
            'See All',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: onSeeAll == null
                  ? const Color(0xFFBCC5D3)
                  : const Color(0xFF8B95A8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _categoryGrid() {
    if (_isLoading) {
      return const Center(child: MedicalLoader(size: 56));
    }

    if (_categories.isEmpty) {
      return const Center(
        child: Text(
          'No categories in database',
          style: TextStyle(color: Color(0xFF8B95A8), fontSize: 12),
        ),
      );
    }

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _categories.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final category = _categories[index];
        return GestureDetector(
          onTap: () {
            final doctors = _doctorsForCategory(category);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CategoryDoctorsScreen(
                  category: category,
                  doctors: doctors,
                  onOpenDoctor: widget.onOpenDoctor,
                ),
              ),
            );
          },
          child: SizedBox(
            width: 76,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: category.color,
                    ),
                    child: Center(
                      child: Icon(category.icon, color: Colors.white, size: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3A4454),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _doctorCard(Doctor doctor, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F223A).withAlpha(16),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: const Color(0xFFEAF0F7),
              ),
              child: const Icon(
                Icons.local_hospital_rounded,
                color: Color(0xFF8FA4BD),
                size: 40,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doctor.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF202B38),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    doctor.speciality,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6F7B8C),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    doctor.hospital,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF687385),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topDoctorsScroller() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _topDoctors.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final doctor = _topDoctors[index];
        return SizedBox(
          width: 330,
          child: _doctorCard(doctor, onTap: () => widget.onOpenDoctor(doctor)),
        );
      },
    );
  }

  Widget _nearbyHospitalsScroller() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _nearbyHospitals.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final hospital = _nearbyHospitals[index];
        return _hospitalCard(
          hospital,
          onTap: () {
            widget.onOpenHospital(hospital);
          },
        );
      },
    );
  }

  Widget _hospitalCard(
    HospitalSummary hospital, {
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 270,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F223A).withAlpha(16),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.local_hospital_outlined,
              color: Color(0xFF39506D),
              size: 26,
            ),
            Text(
              hospital.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F2A38),
              ),
            ),
            Text(
              hospital.city.isNotEmpty ? hospital.city : 'City not available',
              style: const TextStyle(fontSize: 16, color: Color(0xFF6F7B8C)),
            ),
            Text(
              '${hospital.doctorsCount} doctor(s) available',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF41546E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HospitalDetailsScreen extends StatefulWidget {
  const HospitalDetailsScreen({
    required this.hospitalId,
    required this.hospitalName,
    super.key,
  });

  final String hospitalId;
  final String hospitalName;

  @override
  State<HospitalDetailsScreen> createState() => _HospitalDetailsScreenState();
}

class CategoriesListScreen extends StatelessWidget {
  const CategoriesListScreen({
    required this.categories,
    required this.allDoctors,
    required this.onOpenDoctor,
    super.key,
  });

  final List<DoctorCategory> categories;
  final List<Doctor> allDoctors;
  final ValueChanged<Doctor> onOpenDoctor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F8FC),
        title: const Text('All Categories'),
      ),
      body: categories.isEmpty
          ? const Center(
              child: Text(
                'No categories available.',
                style: TextStyle(color: Color(0xFF667385)),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: categories.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.92,
              ),
              itemBuilder: (context, index) {
                final category = categories[index];
                return _CategoryTileCard(
                  category: category,
                  onTap: () {
                    final doctors = _DiscoverySearch.doctorsForCategory(
                      allDoctors,
                      category,
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CategoryDoctorsScreen(
                          category: category,
                          doctors: doctors,
                          onOpenDoctor: onOpenDoctor,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class CategoryDoctorsScreen extends StatelessWidget {
  const CategoryDoctorsScreen({
    required this.category,
    required this.doctors,
    required this.onOpenDoctor,
    super.key,
  });

  final DoctorCategory category;
  final List<Doctor> doctors;
  final ValueChanged<Doctor> onOpenDoctor;

  @override
  Widget build(BuildContext context) {
    return DoctorsListScreen(
      title: '${category.name} Doctors',
      doctors: doctors,
      onOpenDoctor: onOpenDoctor,
    );
  }
}

class DoctorsListScreen extends StatelessWidget {
  const DoctorsListScreen({
    required this.title,
    required this.doctors,
    required this.onOpenDoctor,
    super.key,
  });

  final String title;
  final List<Doctor> doctors;
  final ValueChanged<Doctor> onOpenDoctor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F8FC),
        title: Text(title),
      ),
      body: doctors.isEmpty
          ? const Center(
              child: Text(
                'No doctors found.',
                style: TextStyle(color: Color(0xFF667385)),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: doctors.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final doctor = doctors[index];
                return _DoctorListTileCard(
                  doctor: doctor,
                  onTap: () => onOpenDoctor(doctor),
                );
              },
            ),
    );
  }
}

class HospitalsListScreen extends StatelessWidget {
  const HospitalsListScreen({
    required this.hospitals,
    required this.onOpenHospital,
    super.key,
  });

  final List<HospitalSummary> hospitals;
  final ValueChanged<HospitalSummary> onOpenHospital;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F8FC),
        title: const Text('All Hospitals'),
      ),
      body: hospitals.isEmpty
          ? const Center(
              child: Text(
                'No hospitals found.',
                style: TextStyle(color: Color(0xFF667385)),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: hospitals.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final hospital = hospitals[index];
                return _HospitalListTileCard(
                  hospital: hospital,
                  onTap: () => onOpenHospital(hospital),
                );
              },
            ),
    );
  }
}

class SearchDiscoveryScreen extends StatefulWidget {
  const SearchDiscoveryScreen({
    required this.allDoctors,
    required this.categories,
    required this.hospitals,
    required this.onOpenDoctor,
    required this.onOpenHospital,
    super.key,
  });

  final List<Doctor> allDoctors;
  final List<DoctorCategory> categories;
  final List<HospitalSummary> hospitals;
  final ValueChanged<Doctor> onOpenDoctor;
  final ValueChanged<HospitalSummary> onOpenHospital;

  @override
  State<SearchDiscoveryScreen> createState() => _SearchDiscoveryScreenState();
}

class _SearchDiscoveryScreenState extends State<SearchDiscoveryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  List<Doctor> get _doctorResults {
    if (_query.isEmpty) {
      return <Doctor>[];
    }
    return widget.allDoctors
        .where((doctor) => _DiscoverySearch.matchesDoctor(doctor, _query))
        .toList(growable: false);
  }

  List<DoctorCategory> get _categoryResults {
    if (_query.isEmpty) {
      return <DoctorCategory>[];
    }
    return widget.categories
        .where((category) => _DiscoverySearch.matchesCategory(category, _query))
        .toList(growable: false);
  }

  List<HospitalSummary> get _hospitalResults {
    if (_query.isEmpty) {
      return <HospitalSummary>[];
    }
    return widget.hospitals
        .where((hospital) => _DiscoverySearch.matchesHospital(hospital, _query))
        .toList(growable: false);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doctorResults = _doctorResults;
    final categoryResults = _categoryResults;
    final hospitalResults = _hospitalResults;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F8FC),
        title: const Text('Search'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF2F7),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(Icons.search, color: Color(0xFF9AA4B2), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      onChanged: (value) {
                        setState(() => _query = value);
                      },
                      decoration: const InputDecoration(
                        hintText: 'Search doctors, categories, hospitals...',
                        border: InputBorder.none,
                        isCollapsed: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _query.trim().isEmpty
                ? const Center(
                    child: Text(
                      'Type to search categories, doctors, and hospitals.',
                      style: TextStyle(color: Color(0xFF667385)),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
                    children: [
                      _resultHeader('Categories', categoryResults.length),
                      const SizedBox(height: 8),
                      if (categoryResults.isEmpty)
                        const _EmptySearchLabel(label: 'No categories matched.')
                      else
                        ...categoryResults.map(
                          (category) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _CategoryRowCard(
                              category: category,
                              onTap: () {
                                final doctors =
                                    _DiscoverySearch.doctorsForCategory(
                                      widget.allDoctors,
                                      category,
                                    );
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => CategoryDoctorsScreen(
                                      category: category,
                                      doctors: doctors,
                                      onOpenDoctor: widget.onOpenDoctor,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _resultHeader('Doctors', doctorResults.length),
                      const SizedBox(height: 8),
                      if (doctorResults.isEmpty)
                        const _EmptySearchLabel(label: 'No doctors matched.')
                      else
                        ...doctorResults.map(
                          (doctor) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _DoctorListTileCard(
                              doctor: doctor,
                              onTap: () => widget.onOpenDoctor(doctor),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _resultHeader('Hospitals', hospitalResults.length),
                      const SizedBox(height: 8),
                      if (hospitalResults.isEmpty)
                        const _EmptySearchLabel(label: 'No hospitals matched.')
                      else
                        ...hospitalResults.map(
                          (hospital) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _HospitalListTileCard(
                              hospital: hospital,
                              onTap: () => widget.onOpenHospital(hospital),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _resultHeader(String title, int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF202B38),
          ),
        ),
        Text(
          '$count',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF8B95A8),
          ),
        ),
      ],
    );
  }
}

class _EmptySearchLabel extends StatelessWidget {
  const _EmptySearchLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Color(0xFF6F7B8C), fontSize: 14),
      ),
    );
  }
}

class _DoctorListTileCard extends StatelessWidget {
  const _DoctorListTileCard({required this.doctor, required this.onTap});

  final Doctor doctor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F223A).withAlpha(12),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF0F7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.local_hospital_rounded,
                color: Color(0xFF8FA4BD),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doctor.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF202B38),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    doctor.speciality,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6F7B8C),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${doctor.hospital}, ${doctor.hospitalCity}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6F7B8C),
                    ),
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

class _HospitalListTileCard extends StatelessWidget {
  const _HospitalListTileCard({required this.hospital, required this.onTap});

  final HospitalSummary hospital;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F223A).withAlpha(12),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF0F7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.local_hospital_outlined,
                color: Color(0xFF39506D),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hospital.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2A38),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hospital.city.isNotEmpty
                        ? hospital.city
                        : 'City not available',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6F7B8C),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${hospital.doctorsCount} doctor(s) available',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6F7B8C),
                      fontWeight: FontWeight.w600,
                    ),
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

class _CategoryTileCard extends StatelessWidget {
  const _CategoryTileCard({required this.category, required this.onTap});

  final DoctorCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F223A).withAlpha(12),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: category.color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(category.icon, color: Colors.white, size: 20),
            ),
            const SizedBox(height: 8),
            Text(
              category.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF3A4454),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRowCard extends StatelessWidget {
  const _CategoryRowCard({required this.category, required this.onTap});

  final DoctorCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: category.color,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(category.icon, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                category.name,
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF2C3746),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF9AA4B2)),
          ],
        ),
      ),
    );
  }
}

class _DiscoverySearch {
  static String normalize(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9 ]'),
      ' ',
    );
    return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static bool matchesDoctor(Doctor doctor, String query) {
    final normalizedQuery = normalize(query);
    if (normalizedQuery.isEmpty) {
      return false;
    }

    final inDoctorName = normalize(doctor.name).contains(normalizedQuery);
    final inSpeciality = normalize(doctor.speciality).contains(normalizedQuery);
    final inHospital = normalize(doctor.hospital).contains(normalizedQuery);
    final inCity = normalize(doctor.hospitalCity).contains(normalizedQuery);
    final inTreatments = normalize(
      doctor.treatments.join(' '),
    ).contains(normalizedQuery);

    return inDoctorName || inSpeciality || inHospital || inCity || inTreatments;
  }

  static bool matchesCategory(DoctorCategory category, String query) {
    final normalizedQuery = normalize(query);
    if (normalizedQuery.isEmpty) {
      return false;
    }
    return normalize(category.name).contains(normalizedQuery);
  }

  static bool matchesHospital(HospitalSummary hospital, String query) {
    final normalizedQuery = normalize(query);
    if (normalizedQuery.isEmpty) {
      return false;
    }
    final inName = normalize(hospital.name).contains(normalizedQuery);
    final inCity = normalize(hospital.city).contains(normalizedQuery);
    return inName || inCity;
  }

  static List<Doctor> doctorsForCategory(
    List<Doctor> allDoctors,
    DoctorCategory category,
  ) {
    final categoryKey = normalize(category.name);
    if (categoryKey.isEmpty || categoryKey == 'general') {
      return allDoctors;
    }

    return allDoctors
        .where((doctor) {
          final speciality = normalize(doctor.speciality);
          final treatments = normalize(doctor.treatments.join(' '));
          return speciality.contains(categoryKey) ||
              treatments.contains(categoryKey) ||
              categoryKey.contains(speciality);
        })
        .toList(growable: false);
  }
}

class _HospitalDetailsScreenState extends State<HospitalDetailsScreen> {
  final SupabaseService _supabaseService = SupabaseService();

  bool _isLoading = true;
  String? _error;
  List<HospitalTreatmentPrice> _treatments = <HospitalTreatmentPrice>[];
  List<Doctor> _allDoctors = <Doctor>[];

  @override
  void initState() {
    super.initState();
    _loadHospitalDetails();
  }

  Future<void> _loadHospitalDetails() async {
    try {
      final treatmentRows = await _supabaseService
          .fetchHospitalTreatmentPricing(widget.hospitalId);
      final doctorRows = await _supabaseService.fetchDoctorsByHospital(
        widget.hospitalId,
      );

      // Convert doctorRows to Doctor objects for clickable cards
      final doctors = doctorRows
          .map((row) => Doctor(
            id: row['doctor_id']?.toString() ?? '',
            name: row['full_name']?.toString() ?? 'Doctor',
            speciality: row['specialty']?.toString() ?? 'General',
            hospitals: [
              HospitalInfo(
                id: widget.hospitalId,
                name: row['hospital_name']?.toString() ?? '',
                city: row['city']?.toString() ?? '',
              ),
            ],
            about: '',
            treatments: <String>[],
            rating: 4.5,
            reviewsCount: 125,
            yearsExperience: 5,
          ))
          .toList();

      if (!mounted) return;
      setState(() {
        _treatments = treatmentRows
            .map(HospitalTreatmentPrice.fromDbRow)
            .toList(growable: false);
        _allDoctors = doctors;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        title: Text(widget.hospitalName),
        backgroundColor: const Color(0xFFF6F8FC),
      ),
      body: _isLoading
          ? const Center(child: MedicalLoader(size: 92))
          : _error != null
          ? Center(child: Text(_error!))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Available Treatments & Prices',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (_treatments.isEmpty)
                    const Text(
                      'No treatment pricing configured for this hospital.',
                    )
                  else
                    ..._treatments.map(
                      (item) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                item.treatmentName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            Text(
                              'Rs ${item.price.toStringAsFixed(0)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A2D46),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Available Doctors',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF1F2A38)),
                  ),
                  const SizedBox(height: 12),
                  if (_allDoctors.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE8EEF5)),
                      ),
                      child: const Center(
                        child: Text(
                          'No doctors available at this hospital.',
                          style: TextStyle(color: Color(0xFF6F7B8C), fontSize: 14),
                        ),
                      ),
                    )
                  else
                    ..._allDoctors.map(
                      (doctor) => GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => BookAppointmentScreen(doctor: doctor),
                            ),
                          );
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0F223A).withAlpha(10),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                // Doctor Icon Avatar
                                Container(
                                  width: 66,
                                  height: 66,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEAF0F7),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Icon(
                                    Icons.local_hospital_rounded,
                                    color: Color(0xFF8FA4BD),
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Doctor Info
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        doctor.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF1F2A38),
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        doctor.speciality,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Color(0xFF6F7B8C),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFDB022)),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${doctor.rating.toStringAsFixed(1)} (${doctor.reviewsCount} reviews)',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF6F7B8C),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            '${doctor.yearsExperience} yrs',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF6F7B8C),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                // Arrow Icon
                                const Icon(
                                  Icons.arrow_forward_ios_rounded,
                                  size: 16,
                                  color: Color(0xFFBFBFBF),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class DoctorDetailsScreen extends StatefulWidget {
  const DoctorDetailsScreen({required this.doctor, super.key});

  final Doctor doctor;

  @override
  State<DoctorDetailsScreen> createState() => _DoctorDetailsScreenState();
}

class _DoctorDetailsScreenState extends State<DoctorDetailsScreen> {
  late HospitalInfo _selectedHospital;
  final TextEditingController _searchController = TextEditingController();
  List<HospitalInfo> _filteredHospitals = [];

  @override
  void initState() {
    super.initState();
    _selectedHospital = widget.doctor.hospitals.first;
    _filteredHospitals = widget.doctor.hospitals;
    _searchController.addListener(_filterHospitals);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterHospitals() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredHospitals = widget.doctor.hospitals
          .where((hospital) =>
              hospital.name.toLowerCase().contains(query) ||
              hospital.city.toLowerCase().contains(query))
          .toList();
    });
  }

  void _showHospitalSelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (context, scrollController) => Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select Hospital',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2A38),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Search box
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search hospital or city...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFFE0E8F0),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Hospital list
            Expanded(
              child: _filteredHospitals.isEmpty
                  ? Center(
                      child: Text(
                        'No hospitals found',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: _filteredHospitals.length,
                      itemBuilder: (context, index) {
                        final hospital = _filteredHospitals[index];
                        final isSelected = hospital.id == _selectedHospital.id;
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedHospital = hospital;
                              _searchController.clear();
                              _filteredHospitals = widget.doctor.hospitals;
                            });
                            Navigator.pop(context);
                            _showHospitalDetails(hospital);
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFFEBF3FF)
                                  : Colors.white,
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF0F223A)
                                    : const Color(0xFFE0E8F0),
                                width: isSelected ? 2 : 1,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? const Color(0xFF0F223A)
                                        : const Color(0xFFF0F3F7),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.local_hospital_outlined,
                                    color: isSelected
                                        ? Colors.white
                                        : const Color(0xFF708094),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        hospital.name,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF212D3D),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.location_on_outlined,
                                            size: 14,
                                            color: Color(0xFF708094),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            hospital.city,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: Color(0xFF708094),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (isSelected)
                                  const Icon(
                                    Icons.check_circle,
                                    color: Color(0xFF0F223A),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showHospitalDetails(HospitalInfo hospital) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(hospital.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('City: ${hospital.city}'),
            const SizedBox(height: 8),
            const Text('Now available for appointment'),
            const SizedBox(height: 4),
            StreamBuilder(
              stream: Stream.periodic(const Duration(seconds: 1)),
              builder: (context, snapshot) {
                final now = DateTime.now();
                final formattedTime =
                    DateFormat('hh:mm:ss a').format(now);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Device Time: $formattedTime',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Status: ✓ Online',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const Expanded(
                    child: Text(
                      'Doctor Details',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF2A3443),
                      ),
                    ),
                  ),
                  const Icon(Icons.favorite_border),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0F223A).withAlpha(16),
                            blurRadius: 10,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 84,
                            height: 84,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE9EEF5),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.person,
                              size: 50,
                              color: Color(0xFF7D8DA3),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.doctor.name,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF212D3D),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.doctor.speciality,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF657284),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                GestureDetector(
                                  onTap: _showHospitalSelector,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEBF3FF),
                                      border: Border.all(
                                        color: const Color(0xFF0F223A),
                                        width: 1.5,
                                      ),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.local_hospital_outlined,
                                          size: 18,
                                          color: Color(0xFF0F223A),
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            _selectedHospital.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF0F223A),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(
                                          Icons.expand_more,
                                          size: 18,
                                          color: Color(0xFF0F223A),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        _StatItem(
                          icon: Icons.groups,
                          value: '2,000+',
                          label: 'patients',
                        ),
                        _StatItem(
                          icon: Icons.military_tech,
                          value: '10+',
                          label: 'experience',
                        ),
                        _StatItem(
                          icon: Icons.star,
                          value: '5',
                          label: 'rating',
                        ),
                        _StatItem(
                          icon: Icons.chat_bubble,
                          value: '1,872',
                          label: 'reviews',
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'About me',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.doctor.about,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xFF6C788A),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Working Time',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Monday-Friday, 08:00 AM - 06:00 PM',
                      style: TextStyle(fontSize: 14, color: Color(0xFF6C788A)),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text(
                          'Reviews',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1F2A38),
                          ),
                        ),
                        Text(
                          'See All',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF7E8898),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: Color(0xFFE7ECF3),
                            child: Icon(Icons.person, color: Color(0xFF7D8CA1)),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Reshma',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF273244),
                                  ),
                                ),
                                SizedBox(height: 2),
                                Row(
                                  children: [
                                    Text(
                                      '5.0  ',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Color(0xFF7A879A),
                                      ),
                                    ),
                                    Icon(
                                      Icons.star,
                                      size: 14,
                                      color: Color(0xFFFFB545),
                                    ),
                                    Icon(
                                      Icons.star,
                                      size: 14,
                                      color: Color(0xFFFFB545),
                                    ),
                                    Icon(
                                      Icons.star,
                                      size: 14,
                                      color: Color(0xFFFFB545),
                                    ),
                                    Icon(
                                      Icons.star,
                                      size: 14,
                                      color: Color(0xFFFFB545),
                                    ),
                                    Icon(
                                      Icons.star,
                                      size: 14,
                                      color: Color(0xFFFFB545),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 6),
                                Text(
                                  'Dr. Patel is a true professional who genuinely care\nabout patients. I highly recommend this doctor.',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Color(0xFF6C788A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F223A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BookAppointmentScreen(doctor: widget.doctor),
                      ),
                    );
                  },
                  child: const Text(
                    'Book Appointment',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BookAppointmentScreen extends StatefulWidget {
  const BookAppointmentScreen({required this.doctor, super.key});

  final Doctor doctor;

  @override
  State<BookAppointmentScreen> createState() => _BookAppointmentScreenState();
}

enum ConsultationType { physical, online }

class _BookAppointmentScreenState extends State<BookAppointmentScreen> {
  late final DateTime _month;
  late DateTime _selectedDate;
  final SupabaseService _supabaseService = SupabaseService();
  List<AvailabilitySlot> _slots = <AvailabilitySlot>[];
  AvailabilitySlot? _selectedSlot;
  ConsultationType _consultationType = ConsultationType.physical;
  bool _isSaving = false;
  bool _autoDateResolved = false;
  late HospitalInfo _selectedHospital;
  final TextEditingController _hospitalSearchController = TextEditingController();
  bool _showHospitalDropdown = false;
  List<HospitalInfo> _filteredHospitals = [];

  // Treatment selection state
  List<Treatment> _availableTreatments = <Treatment>[];
  Treatment? _selectedTreatment;
  final TextEditingController _treatmentSearchController = TextEditingController();
  bool _showTreatmentDropdown = false;
  List<Treatment> _filteredTreatments = <Treatment>[];
  bool _treatmentLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedHospital = widget.doctor.hospitals.first;
    _filteredHospitals = widget.doctor.hospitals;
    // Set initial search value to selected hospital
    _hospitalSearchController.text = _selectedHospital.name;
    _hospitalSearchController.addListener(_filterHospitals);
    _treatmentSearchController.addListener(_filterTreatments);
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _selectedDate = DateTime(now.year, now.month, now.day);
    _loadSlotsForDate();
    _loadTreatments();
  }

  @override
  void dispose() {
    _hospitalSearchController.dispose();
    _treatmentSearchController.dispose();
    super.dispose();
  }

  void _filterHospitals() {
    final query = _hospitalSearchController.text.toLowerCase();
    setState(() {
      _filteredHospitals = widget.doctor.hospitals
          .where((hospital) =>
              hospital.name.toLowerCase().contains(query) ||
              hospital.city.toLowerCase().contains(query))
          .toList();
    });
  }

  Future<void> _loadTreatments() async {
    try {
      setState(() {
        _treatmentLoading = true;
        _selectedTreatment = null;
        _availableTreatments = <Treatment>[];
        _filteredTreatments = <Treatment>[];
        _treatmentSearchController.clear();
      });

      final rows = await _supabaseService.fetchDoctorTreatmentsByHospital(
        doctorId: widget.doctor.id,
        hospitalId: _selectedHospital.id,
      );

      if (!mounted) return;

      final treatments = rows.map(Treatment.fromDbRow).toList();
      setState(() {
        _availableTreatments = treatments;
        _filteredTreatments = treatments;
        _treatmentLoading = false;
        if (treatments.isNotEmpty) {
          _selectedTreatment = treatments.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _treatmentLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading treatments: $e')),
      );
    }
  }

  void _filterTreatments() {
    final query = _treatmentSearchController.text.toLowerCase();
    setState(() {
      _filteredTreatments = _availableTreatments
          .where((treatment) =>
              treatment.name.toLowerCase().contains(query) ||
              treatment.category.toLowerCase().contains(query))
          .toList();
    });
  }

  String get _selectedAppointmentModeValue {
    return _consultationType == ConsultationType.online ? 'video' : 'in_person';
  }

  String get _selectedConsultationLabel {
    return _consultationType == ConsultationType.online
        ? 'Online Consultation'
        : 'Physical Consultation';
  }

  String get _selectedHospitalIdForBooking {
    final slotHospitalId = _selectedSlot?.hospitalId ?? '';
    return slotHospitalId.isNotEmpty ? slotHospitalId : _selectedHospital.id;
  }

  Future<void> _loadSlotsForDate() async {
    try {
      final rows = await _supabaseService.fetchAvailableSlots(
        doctorId: widget.doctor.id,
        hospitalId: _selectedHospital.id,
        date: _selectedDate,
        appointmentMode: _selectedAppointmentModeValue,
      );

      if (rows.isEmpty && !_autoDateResolved) {
        _autoDateResolved = true;
        final nextDate = await _supabaseService.fetchFirstAvailableSlotDate(
          doctorId: widget.doctor.id,
          hospitalId: _selectedHospital.id,
          fromDate: _selectedDate,
          appointmentMode: _selectedAppointmentModeValue,
        );
        if (nextDate != null) {
          _selectedDate = DateTime(nextDate.year, nextDate.month, nextDate.day);
          final nextRows = await _supabaseService.fetchAvailableSlots(
            doctorId: widget.doctor.id,
            hospitalId: _selectedHospital.id,
            date: _selectedDate,
            appointmentMode: _selectedAppointmentModeValue,
          );
          if (!mounted) return;
          final nextSlots = nextRows
              .expand(AvailabilitySlot.expandFromDbRow)
              .toList(growable: false);
          setState(() {
            _slots = nextSlots;
            _selectedSlot = nextSlots.isNotEmpty ? nextSlots.first : null;
          });
          return;
        }
      }

      if (!mounted) return;
      final slots = rows
          .expand(AvailabilitySlot.expandFromDbRow)
          .toList(growable: false);
      setState(() {
        _slots = slots;
        if (slots.isNotEmpty) {
          _selectedSlot = slots.first;
        } else {
          _selectedSlot = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _slots = <AvailabilitySlot>[];
        _selectedSlot = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const Expanded(
                    child: Text(
                      'Book Appointment',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF273244),
                      ),
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.doctor.hospitals.length > 1) ...[
                      const Text(
                        'Select Hospital',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1F2A38),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Hospital search field
                      TextField(
                        controller: _hospitalSearchController,
                        onTap: () {
                          setState(() {
                            _showHospitalDropdown = true;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Search hospital...',
                          hintStyle: const TextStyle(
                            color: Color(0xFFA0A7B0),
                            fontSize: 14,
                          ),
                          prefixIcon: const Padding(
                            padding: EdgeInsets.only(left: 12, right: 8),
                            child: Icon(Icons.search, size: 20, color: Color(0xFF7D8DA3)),
                          ),
                          prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                          suffixIcon: _hospitalSearchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close, size: 20, color: Color(0xFF7D8DA3)),
                                  onPressed: () {
                                    _hospitalSearchController.clear();
                                    setState(() {
                                      _filteredHospitals = widget.doctor.hospitals;
                                    });
                                  },
                                )
                              : (_showHospitalDropdown
                                  ? const Icon(Icons.expand_less, size: 20, color: Color(0xFF7D8DA3))
                                  : const Icon(Icons.expand_more, size: 20, color: Color(0xFF7D8DA3))),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE0E8F0),
                              width: 1,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EEF5),
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF0F223A),
                              width: 1.5,
                            ),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFFAFBFD),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF1F2A38),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Hospital dropdown list
                      if (_showHospitalDropdown)
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFE8EEF5), width: 1),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF000000).withAlpha(8),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                            color: Colors.white,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 280),
                            child: _filteredHospitals.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.local_hospital_outlined,
                                            size: 32,
                                            color: Colors.grey[400]),
                                          const SizedBox(height: 8),
                                          Text(
                                            'No hospitals found',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.grey[600],
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    itemCount: _filteredHospitals.length,
                                    separatorBuilder: (context, index) => const Divider(
                                      height: 1,
                                      color: Color(0xFFF0F3F7),
                                      indent: 56,
                                    ),
                                    itemBuilder: (context, index) {
                                      final hospital = _filteredHospitals[index];
                                      final isSelected =
                                          hospital.id == _selectedHospital.id;
                                      return GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _selectedHospital = hospital;
                                            _autoDateResolved = false;
                                            _selectedSlot = null;
                                            _showHospitalDropdown = false;
                                            _hospitalSearchController.text = hospital.name;
                                            _filteredHospitals =
                                                widget.doctor.hospitals;
                                          });
                                          _loadSlotsForDate();
                                          _loadTreatments();
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                          color: isSelected ? const Color(0xFFF8FAFF) : Colors.transparent,
                                          child: Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(6),
                                                decoration: BoxDecoration(
                                                  color: isSelected
                                                      ? const Color(0xFF0F223A)
                                                      : const Color(0xFFF0F3F7),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Icon(
                                                  Icons.local_hospital_outlined,
                                                  color: isSelected
                                                      ? Colors.white
                                                      : const Color(0xFF708094),
                                                  size: 16,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      hospital.name,
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: isSelected
                                                            ? const Color(
                                                                0xFF0F223A)
                                                            : const Color(
                                                                0xFF212D3D),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 3),
                                                    Row(
                                                      children: [
                                                        const Icon(
                                                          Icons
                                                              .location_on_outlined,
                                                          size: 12,
                                                          color: Color(
                                                              0xFF9CA3AF),
                                                        ),
                                                        const SizedBox(
                                                            width: 3),
                                                        Text(
                                                          hospital.city,
                                                          style:
                                                              const TextStyle(
                                                            fontSize: 12,
                                                            color: Color(
                                                                0xFF9CA3AF),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (isSelected)
                                                Container(
                                                  padding: const EdgeInsets.all(4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF0F223A),
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: const Icon(
                                                    Icons.check,
                                                    size: 14,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      const SizedBox(height: 24),
                    ],
                    const Text(
                      'Select Treatment',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_treatmentLoading)
                      const SizedBox(
                        height: 50,
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_availableTreatments.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE8EEF5)),
                        ),
                        child: const Text(
                          'No treatments available for this hospital',
                          style: TextStyle(
                            color: Color(0xFF6F7B8C),
                            fontSize: 14,
                          ),
                        ),
                      )
                    else ...[
                      // Treatment search field
                      TextField(
                        controller: _treatmentSearchController,
                        onTap: () {
                          setState(() {
                            _showTreatmentDropdown = true;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Search treatment...',
                          hintStyle: const TextStyle(
                            color: Color(0xFFA0A7B0),
                            fontSize: 14,
                          ),
                          prefixIcon: const Padding(
                            padding: EdgeInsets.only(left: 12, right: 8),
                            child: Icon(Icons.medical_services_outlined, size: 20, color: Color(0xFF7D8DA3)),
                          ),
                          prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                          suffixIcon: _treatmentSearchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close, size: 20, color: Color(0xFF7D8DA3)),
                                  onPressed: () {
                                    _treatmentSearchController.clear();
                                    setState(() {
                                      _filteredTreatments = _availableTreatments;
                                    });
                                  },
                                )
                              : (_showTreatmentDropdown
                                  ? const Icon(Icons.expand_less, size: 20, color: Color(0xFF7D8DA3))
                                  : const Icon(Icons.expand_more, size: 20, color: Color(0xFF7D8DA3))),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EEF5),
                              width: 1,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EEF5),
                              width: 1,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF0F223A),
                              width: 1.5,
                            ),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFFAFBFD),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF1F2A38),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Treatment dropdown list
                      if (_showTreatmentDropdown)
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFE8EEF5), width: 1),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF000000).withAlpha(8),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                            color: Colors.white,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 280),
                            child: _filteredTreatments.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.medical_services_outlined,
                                            size: 32,
                                            color: Colors.grey[400]),
                                          const SizedBox(height: 8),
                                          Text(
                                            'No treatments found',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.grey[600],
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : ListView.separated(
                                    itemCount: _filteredTreatments.length,
                                    separatorBuilder: (context, index) => const Divider(
                                      height: 1,
                                      color: Color(0xFFF0F3F7),
                                      indent: 56,
                                    ),
                                    itemBuilder: (context, index) {
                                      final treatment = _filteredTreatments[index];
                                      final isSelected = treatment.id == _selectedTreatment?.id;
                                      return GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _selectedTreatment = treatment;
                                            _showTreatmentDropdown = false;
                                            _treatmentSearchController.text = treatment.name;
                                            _filteredTreatments = _availableTreatments;
                                          });
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                          color: isSelected ? const Color(0xFFF8FAFF) : Colors.transparent,
                                          child: Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.all(6),
                                                decoration: BoxDecoration(
                                                  color: isSelected
                                                      ? const Color(0xFF0F223A)
                                                      : const Color(0xFFF0F3F7),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Icon(
                                                  Icons.medical_services_outlined,
                                                  color: isSelected
                                                      ? Colors.white
                                                      : const Color(0xFF708094),
                                                  size: 16,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            treatment.name,
                                                            style: TextStyle(
                                                              fontSize: 14,
                                                              fontWeight: FontWeight.w600,
                                                              color: isSelected
                                                                  ? const Color(0xFF0F223A)
                                                                  : const Color(0xFF212D3D),
                                                            ),
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 8),
                                                        Text(
                                                          '₹${treatment.price.toStringAsFixed(0)}',
                                                          style: TextStyle(
                                                            fontSize: 13,
                                                            fontWeight: FontWeight.w600,
                                                            color: const Color(0xFF0F223A),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 3),
                                                    Text(
                                                      treatment.category,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: Color(0xFF9CA3AF),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (isSelected)
                                                Container(
                                                  padding: const EdgeInsets.all(4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF0F223A),
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  child: const Icon(
                                                    Icons.check,
                                                    size: 14,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      const SizedBox(height: 24),
                    ],
                    const Text(
                      'Consultation Type',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_selectedTreatment != null && !_selectedTreatment!.canUseVideoConsultation)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3E2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFFFDBA5)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline, color: Color(0xFFF59E0B), size: 18),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Video consultation is not available for this treatment. Only in-person consultation is available.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF92400E),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _consultationTypeCard(
                            label: 'Physical',
                            icon: Icons.local_hospital_outlined,
                            type: ConsultationType.physical,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _consultationTypeCard(
                            label: 'Online',
                            icon: Icons.videocam_outlined,
                            type: ConsultationType.online,
                            disabled: _selectedTreatment != null && !_selectedTreatment!.canUseVideoConsultation,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Select Date',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _calendarCard(),
                    const SizedBox(height: 20),
                    const Text(
                      'Select Time',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_slots.isEmpty)
                      const Text(
                        'No available slots for the selected date.',
                        style: TextStyle(color: Color(0xFF6F7B8C)),
                      )
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _slots.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 2.25,
                            ),
                        itemBuilder: (context, index) {
                          final slot = _slots[index];
                          final bool selected = slot.id == _selectedSlot?.id;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedSlot = slot),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: selected
                                    ? const Color(0xFF1A2D46)
                                    : const Color(0xFFEFF2F7),
                              ),
                              child: Center(
                                child: Text(
                                  slot.displayLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected
                                        ? Colors.white
                                        : const Color(0xFF6F7B8C),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F223A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  onPressed: _isSaving ? null : _onConfirm,
                  child: Text(
                    _isSaving ? 'Booking...' : 'Confirm',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _calendarCard() {
    const List<String> weekDays = [
      'Sun',
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
    ];
    final DateTime firstDay = DateTime(_month.year, _month.month, 1);
    final int daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final int leadingGap = firstDay.weekday % 7;

    final List<DateTime?> cells = List<DateTime?>.filled(42, null);
    for (int day = 1; day <= daysInMonth; day++) {
      final int index = leadingGap + day - 1;
      if (index < cells.length) {
        cells[index] = DateTime(_month.year, _month.month, day);
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F223A).withAlpha(18),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                DateFormat('MMMM yyyy').format(_month),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF273244),
                ),
              ),
              const Spacer(),
              const Icon(Icons.keyboard_arrow_left, color: Color(0xFF6C788A)),
              const Icon(Icons.keyboard_arrow_right, color: Color(0xFF6C788A)),
            ],
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: weekDays.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
            ),
            itemBuilder: (context, index) {
              return Center(
                child: Text(
                  weekDays[index],
                  style: const TextStyle(
                    color: Color(0xFF7A8598),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            },
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: cells.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 5,
              crossAxisSpacing: 5,
            ),
            itemBuilder: (context, index) {
              final DateTime? date = cells[index];
              if (date == null) {
                return const SizedBox.shrink();
              }

              final bool isSelected =
                  _selectedDate.year == date.year &&
                  _selectedDate.month == date.month &&
                  _selectedDate.day == date.day;

              return GestureDetector(
                onTap: () async {
                  setState(() => _selectedDate = date);
                  await _loadSlotsForDate();
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: isSelected
                        ? const Color(0xFF1A2D46)
                        : Colors.transparent,
                  ),
                  child: Center(
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF69758A),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _consultationTypeCard({
    required String label,
    required IconData icon,
    required ConsultationType type,
    bool disabled = false,
  }) {
    final selected = _consultationType == type;
    return GestureDetector(
      onTap: () async {
        if (disabled) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sorry, you can\'t choose video consultation for this treatment.')),
          );
          return;
        }

        if (_consultationType == type) {
          return;
        }

        setState(() {
          _consultationType = type;
          _selectedSlot = null;
          _slots = <AvailabilitySlot>[];
          _autoDateResolved = false;
        });

        await _loadSlotsForDate();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: (disabled && type == ConsultationType.online)
              ? const Color(0xFFF5F6F8)
              : (selected ? const Color(0xFF1A2D46) : Colors.white),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: (disabled && type == ConsultationType.online)
                ? const Color(0xFFDFE5EE)
                : (selected ? const Color(0xFF1A2D46) : const Color(0xFFDFE5EE)),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF0F223A).withAlpha(30),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: (disabled && type == ConsultationType.online)
                  ? const Color(0xFFBFBFBF)
                  : (selected ? Colors.white : const Color(0xFF607088)),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: (disabled && type == ConsultationType.online)
                    ? const Color(0xFFBFBFBF)
                    : (selected ? Colors.white : const Color(0xFF3A475A)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onConfirm() async {
    if (_selectedSlot == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an available slot.')),
      );
      return;
    }

    final currentUserRow = currentUserNotifier.value;
    if (currentUserRow == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please login again to book appointment.'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    final ticketNumber = _generateTicketNumber();
    final qrPayload = _buildTicketQrPayload(ticketNumber);

    try {
      final userId = currentUserRow['id']?.toString() ?? '';
      if (userId.isEmpty) {
        throw 'User profile not found in database.';
      }

      await _supabaseService.reserveSlotCapacity(_selectedSlot!.sourceSlotId);
      await _supabaseService.createAppointment(
        patientUserId: userId,
        doctorId: widget.doctor.id,
        hospitalId: _selectedHospitalIdForBooking,
        appointmentDate: _selectedDate,
        startTime: _selectedSlot!.startTime,
        endTime: _selectedSlot!.endTime,
        appointmentMode: _selectedAppointmentModeValue,
        status: 'upcoming',
        slotId: _selectedSlot!.sourceSlotId,
        ticketNumber: ticketNumber,
        qrPayload: qrPayload,
      );

      if (!mounted) return;
      setState(() => _isSaving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Appointment Ticket',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1F2A38),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F0FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.doctor.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Hospital name
                    Row(
                      children: [
                        const Icon(Icons.local_hospital_outlined, size: 16, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _selectedHospital.name,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF5F6F84),
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Date and Time
                    Row(
                      children: [
                        const Icon(Icons.calendar_today_rounded, size: 16, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Text(
                          DateFormat('MMM d, yyyy').format(_selectedDate),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF5F6F84),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Time slot
                    Row(
                      children: [
                        const Icon(Icons.access_time_rounded, size: 16, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Text(
                          _selectedSlot!.displayLabel,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF5F6F84),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Consultation type
                    Row(
                      children: [
                        Icon(
                          _consultationType == ConsultationType.online
                              ? Icons.videocam_outlined
                              : Icons.local_hospital_outlined,
                          size: 16,
                          color: const Color(0xFF707B8C),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _selectedConsultationLabel,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF5F6F84),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (_selectedTreatment != null) ...[
                      const SizedBox(height: 6),
                      // Treatment and Price
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                const Icon(Icons.medical_services_outlined, size: 16, color: Color(0xFF707B8C)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _selectedTreatment!.name,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF5F6F84),
                                      fontWeight: FontWeight.w500,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '₹${_selectedTreatment!.price.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF243145),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    const Divider(color: Color(0xFFE0D7FF), height: 1),
                    const SizedBox(height: 10),
                    Text(
                      'Ticket No: $ticketNumber',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF243145),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE0E6EF)),
                ),
                child: Column(
                  children: [
                    QrImageView(
                      data: qrPayload,
                      version: QrVersions.auto,
                      size: 170,
                      backgroundColor: Colors.white,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Show this QR at check-in',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6B788A)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Your appointment is confirmed.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Color(0xFF6D788B)),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F223A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  },
                  child: const Text(
                    'Done',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Stay on this page',
                  style: TextStyle(color: Color(0xFF8B95A8), fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _generateTicketNumber() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final randomPart = Random.secure().nextInt(9000) + 1000;
    return 'ARO-$now-$randomPart';
  }

  String _buildTicketQrPayload(String ticketNumber) {
    return 'ticket=$ticketNumber;doctor=${widget.doctor.id};hospital=$_selectedHospitalIdForBooking;date=${DateFormat('yyyy-MM-dd').format(_selectedDate)};start=${_selectedSlot!.startTime};mode=$_selectedAppointmentModeValue';
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFE9EEF5),
          ),
          child: Icon(icon, color: const Color(0xFF2D3A4D), size: 26),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF273244),
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF6C788A)),
        ),
      ],
    );
  }
}

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  static const CameraPosition _fallbackCamera = CameraPosition(
    target: LatLng(20.5937, 78.9629),
    zoom: 5.5,
  );

  final SupabaseService _supabaseService = SupabaseService();
  final TextEditingController _hospitalSearchController =
      TextEditingController();
  GoogleMapController? _mapController;
  bool _isLoading = true;
  String? _error;

  Position? _currentPosition;
  List<HospitalMapLocation> _hospitals = <HospitalMapLocation>[];
  HospitalMapLocation? _selectedHospital;

  @override
  void initState() {
    super.initState();
    _loadMapData();
  }

  @override
  void dispose() {
    _hospitalSearchController.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _loadMapData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final position = await _resolveCurrentLocation();
      final rows = await _supabaseService.fetchHospitalsWithCoordinates();
      final hospitals = rows
          .map((row) => HospitalMapLocation.fromDbRow(row))
          .whereType<HospitalMapLocation>()
          .toList(growable: false);

      final sortedHospitals = _sortHospitalsByDistance(hospitals, position);

      if (!mounted) return;
      setState(() {
        _currentPosition = position;
        _hospitals = sortedHospitals;
        _selectedHospital = null;
        _isLoading = false;
      });

      if (position != null && _mapController != null) {
        await _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(position.latitude, position.longitude),
            13.5,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<Position?> _resolveCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return null;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  List<HospitalMapLocation> _sortHospitalsByDistance(
    List<HospitalMapLocation> hospitals,
    Position? userPosition,
  ) {
    if (userPosition == null) {
      return hospitals;
    }

    final withDistance = hospitals
        .map(
          (hospital) => hospital.copyWith(
            distanceInKm:
                Geolocator.distanceBetween(
                  userPosition.latitude,
                  userPosition.longitude,
                  hospital.latitude,
                  hospital.longitude,
                ) /
                1000,
          ),
        )
        .toList(growable: false);

    withDistance.sort((a, b) {
      final aDistance = a.distanceInKm ?? double.infinity;
      final bDistance = b.distanceInKm ?? double.infinity;
      return aDistance.compareTo(bDistance);
    });

    return withDistance;
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{
      for (final hospital in _hospitals)
        Marker(
          markerId: MarkerId('hospital_${hospital.id}'),
          position: LatLng(hospital.latitude, hospital.longitude),
          infoWindow: InfoWindow(
            title: hospital.name,
            snippet: hospital.subtitle,
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            _selectedHospital?.id == hospital.id
                ? BitmapDescriptor.hueRed
                : BitmapDescriptor.hueRose,
          ),
        ),
    };

    if (_currentPosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('user_location'),
          position: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          infoWindow: const InfoWindow(title: 'Your location'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
        ),
      );
    }

    return markers;
  }

  CameraPosition get _initialCamera {
    if (_currentPosition == null) {
      return _fallbackCamera;
    }
    return CameraPosition(
      target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      zoom: 13.5,
    );
  }

  List<HospitalMapLocation> get _searchMatches {
    final query = _hospitalSearchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return const <HospitalMapLocation>[];
    }

    final startsWith = _hospitals
        .where((hospital) => hospital.name.toLowerCase().startsWith(query))
        .toList(growable: false);
    final contains = _hospitals
        .where(
          (hospital) =>
              !hospital.name.toLowerCase().startsWith(query) &&
              hospital.name.toLowerCase().contains(query),
        )
        .toList(growable: false);

    return <HospitalMapLocation>[...startsWith, ...contains]
        .take(6)
        .toList(growable: false);
  }

  HospitalMapLocation? _findBestMatch(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }

    for (final hospital in _hospitals) {
      if (hospital.name.toLowerCase() == normalized) {
        return hospital;
      }
    }

    for (final hospital in _hospitals) {
      if (hospital.name.toLowerCase().startsWith(normalized)) {
        return hospital;
      }
    }

    for (final hospital in _hospitals) {
      if (hospital.name.toLowerCase().contains(normalized)) {
        return hospital;
      }
    }

    return null;
  }

  Future<void> _moveToHospital(HospitalMapLocation hospital) async {
    setState(() {
      _selectedHospital = hospital;
      _hospitalSearchController.text = hospital.name;
      _hospitalSearchController.selection = TextSelection.collapsed(
        offset: _hospitalSearchController.text.length,
      );
    });

    if (_mapController != null) {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(hospital.latitude, hospital.longitude),
          15,
        ),
      );
      await _mapController!.showMarkerInfoWindow(
        MarkerId('hospital_${hospital.id}'),
      );
    }
  }

  Future<void> _handleSearchSubmit() async {
    final match = _findBestMatch(_hospitalSearchController.text);
    if (match == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hospital not found. Try exact or partial name.'),
        ),
      );
      return;
    }

    await _moveToHospital(match);
  }

  Widget _buildHeaderSearchBar() {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE3E8F0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 20, color: Color(0xFF6B7A8F)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _hospitalSearchController,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Search hospital by name',
              ),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF223148),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _handleSearchSubmit(),
            ),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF0F223A),
              borderRadius: BorderRadius.circular(9),
            ),
            child: IconButton(
              tooltip: 'Search hospital',
              onPressed: _handleSearchSubmit,
              icon: const Icon(
                Icons.arrow_forward_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 10,
    ),
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(16)),
  }) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(210),
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white.withAlpha(120)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F223A).withAlpha(28),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 12,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: const Color(0xFFF6F8FC),
        title: _buildHeaderSearchBar(),
      ),
      body: _isLoading
          ? const Center(child: MedicalLoader(size: 82))
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF5F6D80)),
                ),
              ),
            )
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: _initialCamera,
                  myLocationEnabled: _currentPosition != null,
                  myLocationButtonEnabled: false,
                  compassEnabled: true,
                  mapToolbarEnabled: true,
                  markers: _buildMarkers(),
                  onMapCreated: (controller) {
                    _mapController = controller;
                  },
                ),
                if (_searchMatches.isNotEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 10,
                    child: _glassCard(
                      borderRadius: const BorderRadius.all(Radius.circular(14)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      child: Column(
                        children: [
                          for (final hospital in _searchMatches)
                            InkWell(
                              onTap: () => _moveToHospital(hospital),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 11,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.local_hospital,
                                      size: 18,
                                      color: Color(0xFF50627B),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        hospital.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF2E3A4B),
                                        ),
                                      ),
                                    ),
                                    if (hospital.city.isNotEmpty)
                                      Text(
                                        hospital.city,
                                        style: const TextStyle(
                                          color: Color(0xFF6B7A8F),
                                          fontSize: 12,
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
                Positioned(
                  right: 16,
                  bottom: 162,
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: IconButton(
                      tooltip: 'Refresh current location',
                      onPressed: _loadMapData,
                      icon: const Icon(
                        Icons.my_location_rounded,
                        color: Color(0xFF0F223A),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class AppointmentsScreen extends StatefulWidget {
  const AppointmentsScreen({super.key});

  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen> {
  int _tab = 0;
  final SupabaseService _supabaseService = SupabaseService();
  bool _isLoading = true;
  String? _error;
  List<AppointmentItem> _appointments = <AppointmentItem>[];

  @override
  void initState() {
    super.initState();
    _loadAppointments();
  }

  String get _statusForTab {
    switch (_tab) {
      case 0:
        return 'upcoming';
      case 1:
        return 'completed';
      case 2:
        return 'canceled';
      default:
        return 'upcoming';
    }
  }

  Future<void> _loadAppointments() async {
    final currentUserRow = currentUserNotifier.value;
    if (currentUserRow == null) {
      setState(() {
        _isLoading = false;
        _appointments = <AppointmentItem>[];
        _error = 'Please login to view bookings.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final userId = currentUserRow['id']?.toString() ?? '';
      final rows = await _supabaseService.fetchAppointmentsByUserId(
        userId: userId,
        status: _statusForTab,
      );

      if (!mounted) return;
      setState(() {
        _appointments = rows
            .map(AppointmentItem.fromDbRow)
            .toList(growable: false);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _cancelAppointment(String appointmentId) async {
    try {
      await _supabaseService.updateAppointmentStatus(
        appointmentId: appointmentId,
        status: 'canceled',
      );
      await _loadAppointments();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _joinConsultation(AppointmentItem appointment) {
    final currentUserRow = currentUserNotifier.value;
    final participantName = currentUserRow?['name']?.toString().trim().isNotEmpty == true
        ? currentUserRow!['name'].toString().trim()
        : 'Patient';
    final channelSeed = appointment.ticketNumber.isNotEmpty
        ? appointment.ticketNumber
        : appointment.id;
    final doctorSeed = appointment.doctorId.isNotEmpty
        ? appointment.doctorId
        : 'doctor';
    final channelName =
        'ticket_${_sanitizeAgoraChannelPart(channelSeed)}_${_sanitizeAgoraChannelPart(doctorSeed)}';

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AgoraCallScreen(
          appId: '7e2f41f3561f4b4caebcc52e1bdc6bba',
          channelName: channelName,
          displayName: participantName,
          consultationTitle: appointment.doctorName,
          token:
              '007eJxTYNgUy+1p1hSyYJ1WXd8jQYMrEzienFmkdsstrmdWpoNvqowCg3mqUZqJYZqxqZlhmkmSSXJialJysqlRqmFSSrJZUlLi5fLvmQ2BjAx3rvSxMjJAIIjPwlCSWlzCwAAAIeAgfw==',
          isVideoEnabled: true,
        ),
      ),
    );
  }

  String _sanitizeAgoraChannelPart(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return 'room';
    }
    return normalized.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  }

  void _showAppointmentTicket(AppointmentItem appointment) {
    final ticketNumber = appointment.ticketNumber.isNotEmpty
        ? appointment.ticketNumber
        : 'NA';
    final qrData = appointment.qrPayload.isNotEmpty
        ? appointment.qrPayload
        : 'appointment=${appointment.id};ticket=$ticketNumber;doctor=${appointment.doctorName};time=${appointment.timeLabel}';

    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Text(
                  'Appointment Ticket',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2A38),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F0FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appointment.doctorName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A38),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Hospital
                    Row(
                      children: [
                        const Icon(Icons.local_hospital_outlined, size: 14, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            appointment.location,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF5F6F84),
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // Date
                    Row(
                      children: [
                        const Icon(Icons.calendar_today_rounded, size: 14, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Text(
                          appointment.dateLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF5F6F84),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // Time
                    Row(
                      children: [
                        const Icon(Icons.access_time_rounded, size: 14, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Text(
                          appointment.timeLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF5F6F84),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // Consultation
                    Row(
                      children: [
                        Icon(
                          appointment.consultationLabel.toLowerCase().contains('online')
                              ? Icons.videocam_outlined
                              : Icons.local_hospital_outlined,
                          size: 14,
                          color: const Color(0xFF707B8C),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          appointment.consultationLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF5F6F84),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Divider(color: Color(0xFFE0D7FF), height: 1),
                    const SizedBox(height: 10),
                    Text(
                      'Ticket No: $ticketNumber',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF243145),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.info_outline, size: 14, color: Color(0xFF707B8C)),
                        const SizedBox(width: 6),
                        Text(
                          'Booked on: ${appointment.bookedOnLabel}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF9AA4B2),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE0E6EF)),
                  ),
                  child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 160,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F223A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Close',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> tabs = ['Upcoming', 'Completed', 'Canceled'];

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 6),
            const Text(
              'My Bookings',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: Color(0xFF273244),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(tabs.length, (index) {
                final bool active = _tab == index;
                return GestureDetector(
                  onTap: () async {
                    setState(() => _tab = index);
                    await _loadAppointments();
                  },
                  child: Column(
                    children: [
                      Text(
                        tabs[index],
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? const Color(0xFF273244)
                              : const Color(0xFF98A2B1),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 84,
                        height: 3,
                        color: active
                            ? const Color(0xFF273244)
                            : Colors.transparent,
                      ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _isLoading
                  ? const Center(child: MedicalLoader(size: 92))
                  : _error != null
                  ? Center(child: Text(_error!))
                  : _appointments.isEmpty
                  ? const Center(
                      child: Text(
                        'No bookings available.',
                        style: TextStyle(color: Color(0xFF667385)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _appointments.length,
                      itemBuilder: (context, index) {
                        final appointment = _appointments[index];
                        return InkWell(
                          onTap: () => _showAppointmentTicket(appointment),
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0F223A).withAlpha(16),
                                  blurRadius: 10,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${appointment.dateLabel} - ${appointment.timeLabel}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF293548),
                                  ),
                                ),
                                const Divider(height: 16),
                                Row(
                                  children: [
                                    Container(
                                      width: 94,
                                      height: 94,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE9EEF5),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(
                                        Icons.person,
                                        color: Color(0xFF7E8DA3),
                                        size: 50,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            appointment.doctorName,
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF273244),
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            appointment.speciality,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: Color(0xFF667385),
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            appointment.location,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: Color(0xFF6B788A),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            appointment.consultationLabel,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF5B677A),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          if (appointment
                                              .ticketNumber
                                              .isNotEmpty)
                                            Text(
                                              'Ticket: ${appointment.ticketNumber}',
                                              style: const TextStyle(
                                                fontSize: 13,
                                                color: Color(0xFF5B677A),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFFE9ECF2,
                                          ),
                                          foregroundColor: const Color(
                                            0xFF3A4658,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                          ),
                                          side: BorderSide.none,
                                          minimumSize: const Size(0, 46),
                                        ),
                                        onPressed: _tab == 0
                                            ? () => _cancelAppointment(
                                                appointment.id,
                                              )
                                            : null,
                                        child: const Text(
                                          'Cancel',
                                          style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF112742,
                                          ),
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              24,
                                            ),
                                          ),
                                          minimumSize: const Size(0, 46),
                                        ),
                                        onPressed: null,
                                        child: const Text(
                                          'Reschedule',
                                          style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (appointment.isOnlineConsultation) ...[
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFF1B8F5A,
                                            ),
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(
                                                24,
                                              ),
                                            ),
                                            minimumSize: const Size(0, 44),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 10,
                                            ),
                                          ),
                                          onPressed: () => _joinConsultation(appointment),
                                          child: const Text(
                                            'Join',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              height: 1.0,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
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

class HospitalInfo {
  const HospitalInfo({
    required this.id,
    required this.name,
    required this.city,
  });

  final String id;
  final String name;
  final String city;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HospitalInfo &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          city == other.city;

  @override
  int get hashCode => id.hashCode ^ name.hashCode ^ city.hashCode;
}

class Doctor {
  const Doctor({
    required this.id,
    required this.name,
    required this.speciality,
    required this.hospitals,
    required this.about,
    required this.treatments,
    required this.rating,
    required this.reviewsCount,
    required this.yearsExperience,
  });

  factory Doctor.fromListingRow(Map<String, dynamic> row) {
    final rawTreatments = row['treatments'];
    final treatments = rawTreatments is List
        ? rawTreatments
              .whereType<dynamic>()
              .map((item) => item?.toString() ?? '')
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];

    final rawRating = row['rating'];
    final rating = rawRating is num
        ? rawRating.toDouble()
        : double.tryParse(rawRating?.toString() ?? '') ?? 0;

    final rawReviews = row['reviews_count'];
    final reviewsCount = rawReviews is num
        ? rawReviews.toInt()
        : int.tryParse(rawReviews?.toString() ?? '') ?? 0;

    final rawExperience = row['years_experience'];
    final yearsExperience = rawExperience is num
        ? rawExperience.toInt()
        : int.tryParse(rawExperience?.toString() ?? '') ?? 0;

    final doctorName = (row['full_name']?.toString().trim().isNotEmpty ?? false)
        ? row['full_name'].toString().trim()
        : 'Unknown Doctor';
    final speciality = (row['specialty']?.toString().trim().isNotEmpty ?? false)
        ? row['specialty'].toString().trim()
        : 'General';
    final hospital =
        (row['hospital_name']?.toString().trim().isNotEmpty ?? false)
        ? row['hospital_name'].toString().trim()
        : 'Unknown Hospital';
    final hospitalId = row['hospital_id']?.toString() ?? '';
    final city = row['city']?.toString() ?? '';

    final hospitalInfo = HospitalInfo(id: hospitalId, name: hospital, city: city);

    return Doctor(
      id: row['doctor_id']?.toString() ?? '',
      name: doctorName,
      speciality: speciality,
      hospitals: [hospitalInfo],
      about:
          '$doctorName is a $speciality specialist. Book an appointment to know treatment options and consultation availability.',
      treatments: treatments,
      rating: rating,
      reviewsCount: reviewsCount,
      yearsExperience: yearsExperience,
    );
  }

  // Helper to get first hospital for backward compatibility
  String get hospitalId => hospitals.isNotEmpty ? hospitals.first.id : '';
  String get hospitalCity => hospitals.isNotEmpty ? hospitals.first.city : '';
  String get hospital => hospitals.isNotEmpty ? hospitals.first.name : '';

  final String id;
  final String name;
  final String speciality;
  final List<HospitalInfo> hospitals;
  final String about;
  final List<String> treatments;
  final double rating;
  final int reviewsCount;
  final int yearsExperience;

  Doctor copyWith({
    String? id,
    String? name,
    String? speciality,
    List<HospitalInfo>? hospitals,
    String? about,
    List<String>? treatments,
    double? rating,
    int? reviewsCount,
    int? yearsExperience,
  }) {
    return Doctor(
      id: id ?? this.id,
      name: name ?? this.name,
      speciality: speciality ?? this.speciality,
      hospitals: hospitals ?? this.hospitals,
      about: about ?? this.about,
      treatments: treatments ?? this.treatments,
      rating: rating ?? this.rating,
      reviewsCount: reviewsCount ?? this.reviewsCount,
      yearsExperience: yearsExperience ?? this.yearsExperience,
    );
  }
}

class HospitalSummary {
  const HospitalSummary({
    required this.id,
    required this.name,
    required this.city,
    required this.doctorsCount,
  });

  final String id;
  final String name;
  final String city;
  final int doctorsCount;

  HospitalSummary copyWith({
    String? id,
    String? name,
    String? city,
    int? doctorsCount,
  }) {
    return HospitalSummary(
      id: id ?? this.id,
      name: name ?? this.name,
      city: city ?? this.city,
      doctorsCount: doctorsCount ?? this.doctorsCount,
    );
  }
}

class HospitalMapLocation {
  const HospitalMapLocation({
    required this.id,
    required this.name,
    required this.city,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.distanceInKm,
  });

  final String id;
  final String name;
  final String city;
  final String address;
  final double latitude;
  final double longitude;
  final double? distanceInKm;

  static double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static HospitalMapLocation? fromDbRow(Map<String, dynamic> row) {
    final lat = _toDouble(row['latitude']);
    final lng = _toDouble(row['longitude']);
    if (lat == null || lng == null) {
      return null;
    }

    final id = row['id']?.toString() ?? '';
    final name = row['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      return null;
    }

    return HospitalMapLocation(
      id: id,
      name: name,
      city: row['city']?.toString().trim() ?? '',
      address: row['address']?.toString().trim().isNotEmpty == true
          ? row['address'].toString().trim()
          : (row['location_label']?.toString().trim() ?? ''),
      latitude: lat,
      longitude: lng,
    );
  }

  String get subtitle {
    final parts = <String>[];
    if (city.isNotEmpty) {
      parts.add(city);
    }
    if (distanceInKm != null) {
      parts.add('${distanceInKm!.toStringAsFixed(1)} km away');
    }
    if (parts.isNotEmpty) {
      return parts.join(' • ');
    }
    if (address.isNotEmpty) {
      return address;
    }
    return 'Hospital location';
  }

  HospitalMapLocation copyWith({double? distanceInKm}) {
    return HospitalMapLocation(
      id: id,
      name: name,
      city: city,
      address: address,
      latitude: latitude,
      longitude: longitude,
      distanceInKm: distanceInKm ?? this.distanceInKm,
    );
  }
}

class DoctorCategory {
  const DoctorCategory({
    required this.name,
    required this.icon,
    required this.color,
  });

  factory DoctorCategory.fromDbRow(Map<String, dynamic> row) {
    final name = (row['name']?.toString().trim().isNotEmpty ?? false)
        ? row['name'].toString().trim()
        : 'General';
    final iconKey = row['icon_key']?.toString() ?? 'medical_services';
    final colorHex = row['color_hex']?.toString() ?? '#89C2D1';

    return DoctorCategory(
      name: name,
      icon: _iconFromKey(iconKey),
      color: _colorFromHex(colorHex),
    );
  }

  final String name;
  final IconData icon;
  final Color color;

  static IconData _iconFromKey(String key) {
    switch (key) {
      case 'favorite':
        return Icons.favorite;
      case 'face_retouching_natural':
        return Icons.face_retouching_natural;
      case 'accessibility_new':
        return Icons.accessibility_new;
      case 'psychology':
        return Icons.psychology;
      case 'pregnant_woman':
        return Icons.pregnant_woman;
      case 'child_care':
        return Icons.child_care;
      case 'hearing':
        return Icons.hearing;
      case 'vaccines':
        return Icons.vaccines;
      case 'science':
        return Icons.science;
      case 'air':
        return Icons.air;
      case 'monitor_heart':
        return Icons.monitor_heart;
      case 'medical_services':
      default:
        return Icons.medical_services;
    }
  }

  static Color _colorFromHex(String colorHex) {
    final cleaned = colorHex.replaceAll('#', '').trim();
    if (cleaned.length != 6) {
      return const Color(0xFF89C2D1);
    }

    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) {
      return const Color(0xFF89C2D1);
    }

    return Color(0xFF000000 | value);
  }
}

class AppointmentItem {
  const AppointmentItem({
    required this.id,
    required this.status,
    required this.doctorId,
    required this.dateLabel,
    required this.timeLabel,
    required this.consultationLabel,
    required this.doctorName,
    required this.speciality,
    required this.location,
    required this.ticketNumber,
    required this.qrPayload,
    required this.bookedOnLabel,
  });

  factory AppointmentItem.fromDbRow(Map<String, dynamic> row) {
    final rawDate = row['appointment_date']?.toString() ?? '';
    final parsedDate = DateTime.tryParse(rawDate);
    final dateLabel = parsedDate != null
        ? DateFormat('MMM d, yyyy').format(parsedDate)
        : rawDate;

    final startTime = row['start_time']?.toString() ?? '';
    final timeLabel = AvailabilitySlot.formatTimeForDisplay(startTime);
    final modeRaw = row['appointment_mode']?.toString() ?? 'in_person';
    final consultationLabel = modeRaw == 'video'
        ? 'Online Consultation'
        : 'Physical Consultation';

    // Parse created_at for "booked on" display
    final rawCreatedAt = row['created_at']?.toString() ?? '';
    final parsedCreatedAt = DateTime.tryParse(rawCreatedAt);
    final bookedOnLabel = parsedCreatedAt != null
        ? DateFormat('MMM d, yyyy • hh:mm a').format(parsedCreatedAt)
        : 'Date unknown';

    final doctorJson = row['doctors'];
    final hospitalJson = row['hospitals'];

    final doctorName = doctorJson is Map<String, dynamic>
        ? (doctorJson['full_name']?.toString() ?? 'Doctor')
        : 'Doctor';
    final speciality = doctorJson is Map<String, dynamic>
        ? (doctorJson['specialty']?.toString() ?? 'General')
        : 'General';

    String location = 'Hospital';
    if (hospitalJson is Map<String, dynamic>) {
      final hospitalName = hospitalJson['name']?.toString() ?? '';
      final city = hospitalJson['city']?.toString() ?? '';
      if (hospitalName.isNotEmpty && city.isNotEmpty) {
        location = '$hospitalName, $city';
      } else if (hospitalName.isNotEmpty) {
        location = hospitalName;
      }
    }

    return AppointmentItem(
      id: row['id']?.toString() ?? '',
      status: row['status']?.toString() ?? 'upcoming',
      doctorId: row['doctor_id']?.toString() ?? '',
      dateLabel: dateLabel,
      timeLabel: timeLabel,
      consultationLabel: consultationLabel,
      doctorName: doctorName,
      speciality: speciality,
      location: location,
      ticketNumber: row['ticket_number']?.toString() ?? '',
      qrPayload: row['qr_payload']?.toString() ?? '',
      bookedOnLabel: bookedOnLabel,
    );
  }

  final String id;
  final String status;
  final String doctorId;
  final String dateLabel;
  final String timeLabel;
  final String consultationLabel;
  final String doctorName;
  final String speciality;
  final String location;
  final String ticketNumber;
  final String qrPayload;
  final String bookedOnLabel;

  bool get isOnlineConsultation =>
      consultationLabel.toLowerCase().contains('online');

  bool get canJoinVideoConsultation {
    const joinableStatuses = {'accepted', 'confirmed', 'approved'};
    return isOnlineConsultation && joinableStatuses.contains(status.toLowerCase());
  }
}

class AvailabilitySlot {
  const AvailabilitySlot({
    required this.id,
    required this.sourceSlotId,
    required this.hospitalId,
    required this.slotDate,
    required this.startTime,
    required this.endTime,
    required this.slotDurationMinutes,
  });

  factory AvailabilitySlot.fromDbRow(Map<String, dynamic> row) {
    return AvailabilitySlot(
      id: row['id']?.toString() ?? '',
      sourceSlotId: row['id']?.toString() ?? '',
      hospitalId: row['hospital_id']?.toString() ?? '',
      slotDate: row['slot_date']?.toString() ?? '',
      startTime: row['start_time']?.toString() ?? '',
      endTime: row['end_time']?.toString() ?? '',
      slotDurationMinutes: (row['slot_duration_minutes'] as num?)?.toInt() ?? 0,
    );
  }

  static List<AvailabilitySlot> expandFromDbRow(Map<String, dynamic> row) {
    final base = AvailabilitySlot.fromDbRow(row);
    final start = _parseRawTime(base.startTime);
    final end = _parseRawTime(base.endTime);
    if (start == null || end == null || !end.isAfter(start)) {
      return <AvailabilitySlot>[base];
    }

    final durationMinutes = base.slotDurationMinutes;
    if (durationMinutes <= 0) {
      return <AvailabilitySlot>[base];
    }

    final step = Duration(minutes: durationMinutes);
    final List<AvailabilitySlot> chunks = <AvailabilitySlot>[];
    var cursor = start;
    var index = 0;

    while (cursor.add(step).isBefore(end) ||
        cursor.add(step).isAtSameMomentAs(end)) {
      final next = cursor.add(step);
      chunks.add(
        AvailabilitySlot(
          id: '${base.id}-$index',
          sourceSlotId: base.id,
          hospitalId: base.hospitalId,
          slotDate: base.slotDate,
          startTime: _toRawTime(cursor),
          endTime: _toRawTime(next),
          slotDurationMinutes: durationMinutes,
        ),
      );
      cursor = next;
      index += 1;
    }

    return chunks.isNotEmpty ? chunks : <AvailabilitySlot>[base];
  }

  final String id;
  final String sourceSlotId;
  final String hospitalId;
  final String slotDate;
  final String startTime;
  final String endTime;
  final int slotDurationMinutes;

  String get displayLabel {
    return '${formatTimeForDisplay(startTime)} - ${formatTimeForDisplay(endTime)}';
  }

  String get detailedLabel {
    final parsed = DateTime.tryParse(slotDate);
    final dateText = parsed != null
        ? DateFormat('MMM d').format(parsed)
        : slotDate;
    final durationText = slotDurationMinutes > 0
        ? ' / ${slotDurationMinutes}m'
        : '';
    return '$dateText $displayLabel$durationText';
  }

  static String formatTimeForDisplay(String raw) {
    final parts = raw.split(':');
    if (parts.length < 2) {
      return raw;
    }
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;
    final dt = DateTime(2000, 1, 1, hour, minute);
    return DateFormat('hh:mm a').format(dt);
  }

  static DateTime? _parseRawTime(String raw) {
    final parts = raw.split(':');
    if (parts.length < 2) {
      return null;
    }
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return null;
    }
    return DateTime(2000, 1, 1, hour, minute);
  }

  static String _toRawTime(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm:00';
  }
}

class HospitalTreatmentPrice {
  const HospitalTreatmentPrice({
    required this.treatmentName,
    required this.price,
  });

  factory HospitalTreatmentPrice.fromDbRow(Map<String, dynamic> row) {
    final treatment = row['treatments'];
    final treatmentName = treatment is Map<String, dynamic>
        ? (treatment['name']?.toString() ?? 'Treatment')
        : 'Treatment';
    final price = (row['price'] as num?)?.toDouble() ?? 0;

    return HospitalTreatmentPrice(treatmentName: treatmentName, price: price);
  }

  final String treatmentName;
  final double price;
}

class Treatment {
  const Treatment({
    required this.id,
    required this.name,
    required this.category,
    required this.offeredAs,
    required this.price,
  });

  factory Treatment.fromDbRow(Map<String, dynamic> row) {
    final treatmentData = row['treatments'] is Map<String, dynamic>
        ? row['treatments'] as Map<String, dynamic>
        : <String, dynamic>{};

    return Treatment(
      id: treatmentData['id']?.toString() ?? '',
      name: treatmentData['name']?.toString() ?? 'Treatment',
      category: treatmentData['category']?.toString() ?? '',
      offeredAs: row['offered_as']?.toString() ?? 'op',
      price: (row['price'] as num?)?.toDouble() ?? 0,
    );
  }

  final String id;
  final String name;
  final String category;
  final String offeredAs; // 'op', 'procedure', 'ip'
  final double price;

  bool get canUseVideoConsultation => offeredAs == 'op';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Treatment &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name;

  @override
  int get hashCode => id.hashCode ^ name.hashCode;
}

class HospitalDoctorAvailability {
  const HospitalDoctorAvailability({
    required this.name,
    required this.specialty,
    required this.slots,
  });

  factory HospitalDoctorAvailability.fromDb({
    required Map<String, dynamic> doctorRow,
    required List<Map<String, dynamic>> slots,
  }) {
    final slotLabels = slots
        .map((slot) {
          final date = slot['slot_date']?.toString() ?? '';
          final start = slot['start_time']?.toString() ?? '';
          final end = slot['end_time']?.toString() ?? '';
          final duration =
              (slot['slot_duration_minutes'] as num?)?.toInt() ?? 0;
          if (start.isEmpty || end.isEmpty) {
            return '';
          }
          final parsedDate = DateTime.tryParse(date);
          final dateLabel = parsedDate != null
              ? DateFormat('MMM d').format(parsedDate)
              : date;
          final durationLabel = duration > 0 ? ' / ${duration}m' : '';
          return '$dateLabel ${AvailabilitySlot.formatTimeForDisplay(start)} - ${AvailabilitySlot.formatTimeForDisplay(end)}$durationLabel';
        })
        .where((item) => item.isNotEmpty)
        .take(2)
        .toList(growable: false);

    return HospitalDoctorAvailability(
      name: doctorRow['full_name']?.toString() ?? 'Doctor',
      specialty: doctorRow['specialty']?.toString() ?? 'General',
      slots: slotLabels,
    );
  }

  final String name;
  final String specialty;
  final List<String> slots;
}

const List<Doctor> demoDoctors = [
  Doctor(
    id: 'demo-1',
    name: 'Dr. Naveen',
    speciality: 'Cardiologist',
    hospitals: [
      HospitalInfo(id: 'demo-hospital-1', name: 'Golden Cardiology Center', city: 'Potheri'),
    ],
    about:
        'Dr. Samaram is a dedicated cardiologist, brings a wealth of experience to Golden Gate Cardiology Center in Golden Gate, CA.',
    treatments: ['OP Consultation', 'Echo', 'Angiography Review'],
    rating: 4.8,
    reviewsCount: 250,
    yearsExperience: 10,
  ),
  Doctor(
    id: 'demo-2',
    name: 'Dr. Varanasi',
    speciality: 'Orthopedic Surgery',
    hospitals: [
      HospitalInfo(id: 'demo-hospital-2', name: 'Elite Ortho Clinic, Guindy', city: 'Guindy'),
    ],
    about:
        'Dr. Varanasi is known for patient-first care and advanced orthopedic treatment plans including OP and procedure guidance.',
    treatments: ['OP Consultation', 'Sports Injury Care', 'Minor Procedure'],
    rating: 4.7,
    reviewsCount: 180,
    yearsExperience: 9,
  ),
  Doctor(
    id: 'demo-3',
    name: 'Dr. Sai Kumar',
    speciality: 'Gastroenterologist',
    hospitals: [
      HospitalInfo(id: 'demo-hospital-3', name: 'Digestive Institute, MM Nagar', city: 'MM Nagar'),
    ],
    about:
        'Dr. Sai Kumar specializes in digestive disorders and preventive treatment planning with day-care procedure follow-up.',
    treatments: ['OP Consultation', 'Endoscopy Follow-up', 'IP Management'],
    rating: 4.6,
    reviewsCount: 160,
    yearsExperience: 11,
  ),
];

class MedicationsAndPrescriptionsScreen extends StatefulWidget {
  const MedicationsAndPrescriptionsScreen({super.key});

  @override
  State<MedicationsAndPrescriptionsScreen> createState() => _MedicationsAndPrescriptionsScreenState();
}

class _MedicationsAndPrescriptionsScreenState extends State<MedicationsAndPrescriptionsScreen> {
  int _tab = 0;
  List<Medication> _medications = [];
  List<Prescription> _prescriptions = [];
  bool _isUploadingReport = false;
  final SupabaseService _supabaseService = SupabaseService();

  String _resolveMedicationUserId(Map<String, dynamic> userRow) {
    final appUserId = userRow['id']?.toString() ?? '';
    if (appUserId.isNotEmpty) {
      return appUserId;
    }
    return userRow['firebase_uid']?.toString() ?? '';
  }

  List<String> _resolveMedicationUserIds(Map<String, dynamic> userRow) {
    final appUserId = userRow['id']?.toString() ?? '';
    final firebaseUid = userRow['firebase_uid']?.toString() ?? '';
    return [appUserId, firebaseUid]
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() async {
    // Fetch medications from Supabase for the current user
    final currentUserRow = currentUserNotifier.value;
    if (currentUserRow == null) {
      debugPrint('❌ No user logged in');
      setState(() => _medications = []);
      return;
    }

    final userIds = _resolveMedicationUserIds(currentUserRow);
    debugPrint('✅ User IDs: $userIds');
    debugPrint('🔍 Fetching medications for this user...');

    try {
      // Fetch medications from Supabase
      final medicationsData = await _supabaseService.fetchMedicationsByUserIds(userIds);
      debugPrint('📦 Received ${medicationsData.length} medications from Supabase');

      if (medicationsData.isEmpty) {
        debugPrint('⚠️  No medications found in database for this user!');
        debugPrint('   User IDs checked: $userIds');
      }

      List<Medication> loadedMedications = [];
      for (final medData in medicationsData) {
        try {
          // Parse medication from Supabase record
          final medication = _parseMedicationFromSupabase(medData);
          debugPrint('   → Loading: ${medication.name}');
          
          // Fetch alarms for this medication
          final alarmsData = await _supabaseService.fetchMedicationAlarms(medication.id);
          debugPrint('      Alarms: ${alarmsData.length}');
          
          final alarms = alarmsData
              .map((alarmData) => MedicationAlarm(
                    id: alarmData['id'] ?? '',
                    doseNumber: alarmData['dose_number'] ?? 0,
                    doseLabel: alarmData['alarm_label'] ?? '',
                    alarmTime: _normalizeAlarmTime(alarmData['alarm_time']?.toString()),
                    isEnabled: alarmData['is_enabled'] ?? true,
                    notificationType: alarmData['notification_type'] ?? 'Sound+Vibration',
                    notifyBeforeMinutes: alarmData['notify_before_minutes'] ?? 15,
                  ))
              .toList();

          for (final alarm in alarms) {
            await LocalNotificationService.scheduleDailyMedicationAlarm(
              medicationId: medication.id,
              medicationName: medication.name,
              doseNumber: alarm.doseNumber,
              doseLabel: alarm.doseLabel,
              alarmTime: alarm.alarmTime,
              enabled: medication.alarmEnabled && alarm.isEnabled,
              notificationType: alarm.notificationType,
              notifyBeforeMinutes: alarm.notifyBeforeMinutes,
            );
          }

          loadedMedications.add(medication.copyWith(alarms: alarms));
        } catch (e) {
          debugPrint('❌ Error parsing medication: $e');
        }
      }

      if (mounted) {
        setState(() => _medications = loadedMedications);
        debugPrint('✅ Loaded ${loadedMedications.length} medications total');
      }
    } catch (e) {
      debugPrint('❌ Error loading medications: $e');
      if (mounted) {
        setState(() => _medications = []);
      }
    }

    // Demo prescriptions (keep for now)
    _prescriptions = [
      Prescription(
        id: '1',
        doctorName: 'Dr. Varanasi',
        hospitalName: 'Elite Ortho Clinic, Guindy',
        diagnosis: 'Muscle strain and inflammation',
        prescribedMedications: ['Aspirin 500mg - Twice daily', 'Ibuprofen 200mg - As needed'],
        prescriptionDate: DateTime(2026, 3, 20),
        validUntil: DateTime(2026, 9, 20),
      ),
      Prescription(
        id: '2',
        doctorName: 'Dr. Sai Kumar',
        hospitalName: 'Digestive Institute, MM Nagar',
        diagnosis: 'Common cold and cough',
        prescribedMedications: ['Cough Syrup 5ml - Thrice daily', 'Vitamin C 1000mg - Once daily'],
        prescriptionDate: DateTime(2026, 3, 18),
        validUntil: DateTime(2026, 6, 18),
      ),
    ];
  }

  Future<void> _uploadMedicalReport() async {
    final currentUserRow = currentUserNotifier.value;
    if (currentUserRow == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please login to upload reports')),
      );
      return;
    }

    final userId = _resolveMedicationUserId(currentUserRow);
    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to identify user for upload')),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty || result.files.single.path == null) {
      return;
    }

    final pickedFile = result.files.single;
    setState(() => _isUploadingReport = true);

    try {
      final reportUrl = await _supabaseService.uploadMedicalReport(
        userId: userId,
        file: File(pickedFile.path!),
        originalFileName: pickedFile.name,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Report uploaded successfully: $reportUrl'),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to upload PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUploadingReport = false);
      }
    }
  }

  Medication _parseMedicationFromSupabase(Map<String, dynamic> data) {
    final timingLabels = (data['timing_labels'] as List?)?.cast<String>() ?? [];
    final timingValues = (data['timing_values'] as List?)?.cast<String>() ?? [];
    
    return Medication(
      id: data['id'] ?? '',
      name: data['medication_name'] ?? 'Unknown',
      dosage: data['dosage'] ?? '',
      type: data['medication_type'] ?? '',
      timingLabels: timingLabels,
      timingValues: timingValues,
      timeFrequency: data['time_frequency'] ?? '',
      daysOfWeek: (data['days_of_week'] as List?)?.cast<int>() ?? [0, 1, 2, 3, 4, 5, 6],
      startDate: DateTime.tryParse(data['start_date']?.toString() ?? '') ?? DateTime.now(),
      endDate: DateTime.tryParse(data['end_date']?.toString() ?? ''),
      prescribedDate: DateTime.tryParse(data['prescribed_date']?.toString() ?? ''),
      expiryDate: DateTime.tryParse(data['expiry_date']?.toString() ?? ''),
      durationDays: data['duration_days'],
      instructions: data['instructions']?.toString() ?? '',
      warnings: data['warnings']?.toString() ?? '',
      alarmEnabled: data['alarm_enabled'] ?? true,
      isActive: data['is_active'] ?? true,
    );
  }

  String _normalizeAlarmTime(String? rawTime) {
    if (rawTime == null || rawTime.isEmpty) {
      return '00:00';
    }

    final segments = rawTime.split(':');
    if (segments.length < 2) {
      return rawTime;
    }

    final hour = segments[0].padLeft(2, '0');
    final minute = segments[1].padLeft(2, '0');
    return '$hour:$minute';
  }

  List<MedicationAlarm> _displayAlarmsForMedication(Medication medication) {
    if (medication.alarms.isNotEmpty) {
      final alarms = List<MedicationAlarm>.from(medication.alarms);
      alarms.sort((a, b) => a.doseNumber.compareTo(b.doseNumber));
      return alarms;
    }

    return List.generate(
      medication.timingLabels.length,
      (index) => MedicationAlarm(
        id: 'generated-${medication.id}-${index + 1}',
        doseNumber: index + 1,
        doseLabel: medication.timingLabels[index],
        alarmTime: _normalizeAlarmTime(medication.timingValues[index]),
      ),
    );
  }

  Future<void> _requestNotificationPermissionsAndStatus() async {
    try {
      final status = await LocalNotificationService.requestNotificationPermissions();
      if (!mounted) return;

      final notificationsEnabled = status['notificationsEnabled'] ?? false;
      final exactAlarmEnabled = status['exactAlarmEnabled'] ?? false;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Notifications: ${notificationsEnabled ? 'ON' : 'OFF'} | Exact alarm: ${exactAlarmEnabled ? 'ON' : 'OFF'}',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to check notification status: $e')),
      );
    }
  }

  Future<void> _scheduleNotificationTest() async {
    try {
      await LocalNotificationService.scheduleTestNotificationInSeconds(seconds: 10);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Test notification scheduled for 10 seconds. Lock screen and wait.'),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to schedule test notification: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<String> tabs = ['Medications', 'Prescriptions', 'Reports'];

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 6),
            const Text(
              'Health Records',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: Color(0xFF273244),
              ),
            ),
            const SizedBox(height: 12),
            // Tabs
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(tabs.length, (index) {
                final bool active = _tab == index;
                return GestureDetector(
                  onTap: () => setState(() => _tab = index),
                  child: Column(
                    children: [
                      Text(
                        tabs[index],
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? const Color(0xFF273244)
                              : const Color(0xFF98A2B1),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 60,
                        height: 3,
                        color: active
                            ? const Color(0xFF273244)
                            : Colors.transparent,
                      ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 12),
            if (_tab == 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _requestNotificationPermissionsAndStatus,
                        icon: const Icon(Icons.notifications_outlined),
                        label: const Text('Check Notification Setup'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _scheduleNotificationTest,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F223A),
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: const Text('Run 10s Test'),
                      ),
                    ),
                  ],
                ),
              ),
            if (_tab == 0) const SizedBox(height: 10),
            // Content
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _buildMedicationsTab(),
                  _buildPrescriptionsTab(),
                  _buildReportsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedicationsTab() {
    return _medications.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9EEF5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.medication,
                    size: 50,
                    color: Color(0xFF9AA4B2),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'No Medications Added',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1F2A38),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add medications to get started',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF6F7B8C),
                  ),
                ),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            itemCount: _medications.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              final medication = _medications[index];
              final isExpired = medication.expiryDate != null &&
                  medication.expiryDate!.isBefore(DateTime.now());
              final daysLeft = medication.expiryDate != null
                  ? medication.expiryDate!.difference(DateTime.now()).inDays
                  : -1;
              final scheduleAlarms = _displayAlarmsForMedication(medication);

              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F223A).withAlpha(14),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Premium Header
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isExpired
                              ? [
                                  const Color(0xFFFFEBEE),
                                  const Color(0xFFFFCDD2)
                                ]
                              : [
                                  const Color(0xFFF0F4FF),
                                  const Color(0xFFE8F0FF)
                                ],
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        children: [
                          // Icon with background
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: isExpired
                                  ? const Color(0xFFFF5252).withAlpha(25)
                                  : const Color(0xFF0F223A).withAlpha(12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: Icon(
                                _getIconForMedicationType(medication.type),
                                color: isExpired
                                    ? const Color(0xFFD32F2F)
                                    : const Color(0xFF0F223A),
                                size: 28,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  medication.name,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1F2A38),
                                    letterSpacing: 0.3,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${medication.dosage} • ${medication.type}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF5F6F84),
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                if (isExpired)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFD32F2F),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'Expired',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Alarm toggle
                          GestureDetector(
                            onTap: () async {
                              final currentUserRow = currentUserNotifier.value;
                              if (currentUserRow == null) {
                                return;
                              }
                              final userId = _resolveMedicationUserId(currentUserRow);

                              final updatedAlarmEnabled = !medication.alarmEnabled;

                              await _supabaseService.saveMedication(
                                userId: userId,
                                medicationId: medication.id,
                                medicationName: medication.name,
                                dosage: medication.dosage,
                                medicationType: medication.type,
                                timingLabels: medication.timingLabels,
                                timingValues: medication.timingValues,
                                timeFrequency: medication.timeFrequency,
                                durationDays: medication.durationDays,
                                startDate: medication.startDate,
                                expiryDate: medication.expiryDate,
                                instructions: medication.instructions,
                                warnings: medication.warnings,
                                alarmEnabled: updatedAlarmEnabled,
                                isActive: medication.isActive,
                              );

                              final scheduleAlarms = _displayAlarmsForMedication(medication);
                              for (final alarm in scheduleAlarms) {
                                await LocalNotificationService.scheduleDailyMedicationAlarm(
                                  medicationId: medication.id,
                                  medicationName: medication.name,
                                  doseNumber: alarm.doseNumber,
                                  doseLabel: alarm.doseLabel,
                                  alarmTime: alarm.alarmTime,
                                  enabled: updatedAlarmEnabled && alarm.isEnabled,
                                  notificationType: alarm.notificationType,
                                  notifyBeforeMinutes: alarm.notifyBeforeMinutes,
                                );
                              }

                              setState(() {
                                _medications[index] = medication.copyWith(
                                  alarmEnabled: updatedAlarmEnabled,
                                );
                              });
                            },
                            child: Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: medication.alarmEnabled
                                    ? const Color(0xFF0F223A)
                                    : const Color(0xFFE8EEF5),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                medication.alarmEnabled
                                    ? Icons.notifications_active_outlined
                                    : Icons.notifications_off_outlined,
                                size: 22,
                                color: medication.alarmEnabled
                                    ? Colors.white
                                    : const Color(0xFF9AA4B2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Content
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Frequency badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0F4FF),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFDCE4F0),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF0F223A),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  medication.timeFrequency,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1F2A38),
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          // Timings section
                          const Text(
                            'Dose Schedule',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF6F7B8C),
                              letterSpacing: 0.3,
                              textBaseline: TextBaseline.alphabetic,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFE8EEF5),
                                width: 1.2,
                              ),
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: List.generate(
                                scheduleAlarms.length,
                                (i) => Padding(
                                  padding: EdgeInsets.only(
                                    bottom: i < scheduleAlarms.length - 1
                                        ? 12
                                        : 0,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0F223A),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${i + 1}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              scheduleAlarms[i].doseLabel,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF1F2A38),
                                                letterSpacing: 0.2,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              medication.instructions.isNotEmpty
                                                  ? medication.instructions
                                                  : 'Take as prescribed',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                                color: Color(0xFF9AA4B2),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0F223A),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          _normalizeAlarmTime(
                                            scheduleAlarms[i].alarmTime,
                                          ),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white,
                                            fontFamily: 'Courier',
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          // Info section
                          if (medication.instructions.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0F7FF),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFDCE9FF),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.info_outlined,
                                    size: 16,
                                    color: Color(0xFF0F223A),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      medication.instructions,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: Color(0xFF1F2A38),
                                        height: 1.4,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (medication.expiryDate != null)
                            Padding(
                              padding:
                                  EdgeInsets.only(top: medication.instructions.isNotEmpty ? 10 : 0),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.calendar_today_outlined,
                                        size: 14,
                                        color: isExpired
                                            ? const Color(0xFFD32F2F)
                                            : const Color(0xFF6F7B8C),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Expires: ${DateFormat('MMM dd, yyyy').format(medication.expiryDate!)}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: isExpired
                                              ? const Color(0xFFD32F2F)
                                              : const Color(0xFF6F7B8C),
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (!isExpired && daysLeft >= 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: daysLeft <= 7
                                            ? const Color(0xFFFFF3E0)
                                            : const Color(0xFFE8F5E9),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '$daysLeft days left',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: daysLeft <= 7
                                              ? const Color(0xFFF57C00)
                                              : const Color(0xFF388E3C),
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 16),
                          // Action buttons
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    _showAlarmDialog(context, medication, index);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        const Color(0xFF0F223A),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    elevation: 2,
                                  ),
                                  icon: const Icon(
                                    Icons.schedule_outlined,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Set Alarms',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    _showEditMedicationDialog(medication, index);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                      color: Color(0xFF0F223A),
                                      width: 1.5,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                    color: Color(0xFF0F223A),
                                  ),
                                  label: const Text(
                                    'Edit',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F223A),
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
  }


  Widget _buildPrescriptionsTab() {
    return _prescriptions.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.description_outlined,
                    size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  'No prescriptions available',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            itemCount: _prescriptions.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final prescription = _prescriptions[index];
              final isExpired =
                  prescription.validUntil.isBefore(DateTime.now());

              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F223A).withAlpha(12),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isExpired
                              ? const Color(0xFFFFEBEE)
                              : const Color(0xFFF0F4FF),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 45,
                              height: 45,
                              decoration: BoxDecoration(
                                color: isExpired
                                    ? const Color(0xFFFFCDD2)
                                    : const Color(0xFFEAF0F7),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.description_outlined,
                                color: isExpired
                                    ? const Color(0xFFD32F2F)
                                    : const Color(0xFF0F223A),
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    prescription.doctorName,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1F2A38),
                                    ),
                                  ),
                                  Text(
                                    prescription.hospitalName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF7E8DA3),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              prescription.diagnosis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF6F7B8C),
                              ),
                            ),
                            const SizedBox(height: 8),
                            _miniInfoRow(
                              'Valid Until',
                              DateFormat('MMM dd').format(prescription.validUntil),
                              valueColor: isExpired
                                  ? const Color(0xFFD32F2F)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
  }

  Widget _buildReportsTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFE9EEF5),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.assessment_outlined,
              size: 40,
              color: Color(0xFF9AA4B2),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Medical Reports',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1F2A38),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Lab results and medical documents\ncoming soon',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF9AA4B2),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _isUploadingReport ? null : _uploadMedicalReport,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F223A),
            ),
            icon: _isUploadingReport
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.upload_file),
            label: Text(_isUploadingReport ? 'Uploading...' : 'Upload PDF Report'),
          ),
        ],
      ),
    );
  }

  Widget _miniInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF9AA4B2),
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            color: valueColor ?? const Color(0xFF1F2A38),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  void _showEditMedicationDialog(Medication medication, int index) {
    String medName = medication.name;
    String dosage = medication.dosage;
    String medType = medication.type;
    String instructions = medication.instructions;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F223A),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(25),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _getIconForMedicationType(medication.type),
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Edit Medication',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                medication.name,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFFB0BFC9),
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Content
              Padding(
                padding: const EdgeInsets.all(20),
                child: StatefulBuilder(
                  builder: (context, setDialogState) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name field
                      _buildTextField(
                        label: 'Medication Name',
                        initialValue: medName,
                        onChanged: (val) => medName = val,
                      ),
                      const SizedBox(height: 16),
                      // Dosage field
                      _buildTextField(
                        label: 'Dosage',
                        initialValue: dosage,
                        onChanged: (val) => dosage = val,
                      ),
                      const SizedBox(height: 16),
                      // Type dropdown
                      Text(
                        'Type',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6F7B8C),
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0xFFDCE4F0),
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: medType,
                            isExpanded: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            items: [
                              'Tablet',
                              'Capsule',
                              'Syrup',
                              'Liquid',
                              'Injection',
                              'Powder'
                            ]
                                .map((type) => DropdownMenuItem(
                                      value: type,
                                      child: Text(
                                        type,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Color(0xFF1F2A38),
                                        ),
                                      ),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => medType = val);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Instructions field
                      _buildTextField(
                        label: 'Instructions',
                        initialValue: instructions,
                        onChanged: (val) => instructions = val,
                        maxLines: 3,
                      ),
                      const SizedBox(height: 20),
                      // Buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                  color: Color(0xFF0F223A),
                                  width: 1.5,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: const Text(
                                'Cancel',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F223A),
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                try {
                                  final currentUserRow = currentUserNotifier.value;
                                  if (currentUserRow == null) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('User not authenticated'),
                                      ),
                                    );
                                    return;
                                  }
                                  final userId = _resolveMedicationUserId(currentUserRow);

                                  await _supabaseService.saveMedication(
                                    userId: userId,
                                    medicationId: medication.id,
                                    medicationName: medName,
                                    dosage: dosage,
                                    medicationType: medType,
                                    timingLabels: medication.timingLabels,
                                    timingValues: medication.timingValues,
                                    timeFrequency: medication.timeFrequency,
                                    durationDays: medication.durationDays,
                                    startDate: medication.startDate,
                                    expiryDate: medication.expiryDate,
                                    instructions: instructions,
                                    warnings: medication.warnings,
                                    alarmEnabled: medication.alarmEnabled,
                                    isActive: medication.isActive,
                                  );

                                  setState(() {
                                    _medications[index] = medication.copyWith(
                                      name: medName,
                                      dosage: dosage,
                                      type: medType,
                                      instructions: instructions,
                                    );
                                  });

                                  if (!context.mounted) return;
                                  Navigator.pop(context);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '✓ $medName updated successfully',
                                      ),
                                      backgroundColor:
                                          const Color(0xFF4CAF50),
                                      duration:
                                          const Duration(milliseconds: 2500),
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      margin:
                                          const EdgeInsets.only(bottom: 20),
                                    ),
                                  );
                                } catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Error updating medication: $e'),
                                      backgroundColor: const Color(0xFFD32F2F),
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0F223A),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                elevation: 3,
                              ),
                              child: const Text(
                                'Save Changes',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ),
                        ],
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
  }

  Widget _buildTextField({
    required String label,
    required String initialValue,
    required Function(String) onChanged,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF6F7B8C),
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: TextEditingController(text: initialValue),
          onChanged: onChanged,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: 'Enter $label',
            hintStyle: const TextStyle(
              color: Color(0xFFB0BFC9),
              fontSize: 13,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: Color(0xFFDCE4F0),
                width: 1.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: Color(0xFFDCE4F0),
                width: 1.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: Color(0xFF0F223A),
                width: 2,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
          ),
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF1F2A38),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  IconData _getIconForMedicationType(String type) {
    switch (type.toLowerCase()) {
      case 'tablet':
      case 'capsule':
        return Icons.medication;
      case 'syrup':
      case 'liquid':
        return Icons.science_outlined;
      case 'injection':
        return Icons.health_and_safety;
      case 'powder':
        return Icons.grain;
      default:
        return Icons.medication_outlined;
    }
  }

  void _showAlarmDialog(
    BuildContext context,
    Medication medication,
    int medicationIndex,
  ) {
    final List<MedicationAlarm> editableAlarms = medication.alarms.isNotEmpty
        ? medication.alarms.map((a) => a.copyWith()).toList()
        : _displayAlarmsForMedication(medication)
              .map((a) => a.copyWith())
              .toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setDialogState) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 12,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(sheetContext).size.height * 0.84,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(30),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 46,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD9E0EA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${medication.name} Alarms',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1F2A38),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Tap each time to edit like mobile alarm',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF7E8DA3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: editableAlarms.isEmpty
                          ? const Center(child: Text('No alarms configured'))
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                              itemCount: editableAlarms.length,
                              itemBuilder: (_, index) {
                                final alarm = editableAlarms[index];
                                return _buildSimpleAlarmEditItem(
                                  alarm,
                                  index,
                                  () => setDialogState(() {}),
                                  (field, value) {
                                    if (field == 'time') {
                                      alarm.alarmTime = value;
                                    } else if (field == 'enabled') {
                                      alarm.isEnabled = value;
                                    } else if (field == 'type') {
                                      alarm.notificationType = value;
                                    } else if (field == 'minutes') {
                                      alarm.notifyBeforeMinutes = value;
                                    }
                                    setDialogState(() {});
                                  },
                                );
                              },
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFF0F223A)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0F223A),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: () async {
                                try {
                                  final currentUserRow = currentUserNotifier.value;
                                  if (currentUserRow == null) {
                                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                                      const SnackBar(content: Text('User not authenticated')),
                                    );
                                    return;
                                  }
                                  final userId = _resolveMedicationUserId(currentUserRow);

                                  final sortedAlarms =
                                      List<MedicationAlarm>.from(editableAlarms)
                                        ..sort((a, b) => a.doseNumber.compareTo(b.doseNumber));

                                  final updatedTimingLabels = sortedAlarms
                                      .map((alarm) => alarm.doseLabel)
                                      .toList(growable: false);
                                  final updatedTimingValues = sortedAlarms
                                      .map((alarm) => alarm.alarmTime)
                                      .toList(growable: false);

                                  await _supabaseService.saveMedication(
                                    userId: userId,
                                    medicationId: medication.id,
                                    medicationName: medication.name,
                                    dosage: medication.dosage,
                                    medicationType: medication.type,
                                    timingLabels: updatedTimingLabels,
                                    timingValues: updatedTimingValues,
                                    timeFrequency: medication.timeFrequency,
                                    durationDays: medication.durationDays,
                                    startDate: medication.startDate,
                                    expiryDate: medication.expiryDate,
                                    instructions: medication.instructions,
                                    warnings: medication.warnings,
                                    alarmEnabled: medication.alarmEnabled,
                                    isActive: medication.isActive,
                                  );

                                  for (final alarm in sortedAlarms) {
                                    await _supabaseService.saveMedicationAlarm(
                                      medicationId: medication.id,
                                      userId: userId,
                                      alarmId: alarm.id,
                                      doseNumber: alarm.doseNumber,
                                      doseLabel: alarm.doseLabel,
                                      alarmTime: alarm.alarmTime,
                                      isEnabled: alarm.isEnabled,
                                      notificationType: alarm.notificationType,
                                      notifyBeforeMinutes: alarm.notifyBeforeMinutes,
                                    );

                                    await LocalNotificationService.scheduleDailyMedicationAlarm(
                                      medicationId: medication.id,
                                      medicationName: medication.name,
                                      doseNumber: alarm.doseNumber,
                                      doseLabel: alarm.doseLabel,
                                      alarmTime: alarm.alarmTime,
                                      enabled: medication.alarmEnabled && alarm.isEnabled,
                                      notificationType: alarm.notificationType,
                                      notifyBeforeMinutes: alarm.notifyBeforeMinutes,
                                    );
                                  }

                                  setState(() {
                                    _medications[medicationIndex] = medication.copyWith(
                                      alarms: sortedAlarms,
                                      timingLabels: updatedTimingLabels,
                                      timingValues: updatedTimingValues,
                                    );
                                  });

                                  if (!sheetContext.mounted) return;
                                  Navigator.pop(sheetContext);
                                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Saved ${sortedAlarms.where((a) => a.isEnabled).length} active alarm(s)',
                                      ),
                                      backgroundColor: const Color(0xFF4CAF50),
                                    ),
                                  );
                                } catch (e) {
                                  if (!sheetContext.mounted) return;
                                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                                    SnackBar(
                                      content: Text('Error saving alarms: $e'),
                                      backgroundColor: const Color(0xFFD32F2F),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Save Alarms'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSimpleAlarmEditItem(
    MedicationAlarm alarm,
    int index,
    VoidCallback onUpdate,
    Function(String, dynamic) onFieldChange,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8EEF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Dose ${alarm.doseNumber}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Color(0xFF1F2A38),
                    ),
                  ),
                  Text(
                    alarm.doseLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9AA4B2),
                    ),
                  ),
                ],
              ),
              Switch.adaptive(
                value: alarm.isEnabled,
                activeColor: const Color(0xFF0F223A),
                onChanged: (value) => onFieldChange('enabled', value),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Time
          GestureDetector(
            onTap: alarm.isEnabled
                ? () async {
                    final timeParts = alarm.alarmTime.split(':');
                    final initialTime = TimeOfDay(
                      hour: int.parse(timeParts[0]),
                      minute: int.parse(timeParts[1]),
                    );
                    final pickedTime = await showTimePicker(
                      context: context,
                      initialTime: initialTime,
                      initialEntryMode: TimePickerEntryMode.dial,
                      helpText: 'Select alarm time',
                    );
                    if (pickedTime != null) {
                      final newTime =
                          '${pickedTime.hour.toString().padLeft(2, '0')}:${pickedTime.minute.toString().padLeft(2, '0')}';
                      onFieldChange('time', newTime);
                    }
                  }
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: alarm.isEnabled ? Colors.white : const Color(0xFFF0F3F7),
                border: Border.all(color: const Color(0xFFE8EEF5)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time, size: 14, color: Color(0xFF7E8DA3)),
                  const SizedBox(width: 8),
                  Text(
                    alarm.alarmTime,
                    key: ValueKey('alarm-time-${alarm.id}-${alarm.alarmTime}'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Notification type
          DropdownButtonFormField<String>(
            value: alarm.notificationType,
            onChanged: alarm.isEnabled
                ? (val) {
                    if (val != null) onFieldChange('type', val);
                  }
                : null,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
            items: ['Sound+Vibration', 'Sound only', 'Vibration only', 'Silent']
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
          ),
          const SizedBox(height: 10),
          // Minutes before
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: alarm.notifyBeforeMinutes.toDouble(),
                  onChanged: alarm.isEnabled
                      ? (val) {
                          onFieldChange('minutes', val.toInt());
                        }
                      : null,
                  min: 0,
                  max: 60,
                  divisions: 12,
                  activeColor: const Color(0xFF0F223A),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F223A),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${alarm.notifyBeforeMinutes}m',
                  key: ValueKey('notify-minutes-${alarm.id}-${alarm.notifyBeforeMinutes}'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}



class Prescription {
  final String id;
  final String doctorName;
  final String hospitalName;
  final String diagnosis;
  final List<String> prescribedMedications;
  final DateTime prescriptionDate;
  final DateTime validUntil;

  Prescription({
    required this.id,
    required this.doctorName,
    required this.hospitalName,
    required this.diagnosis,
    required this.prescribedMedications,
    required this.prescriptionDate,
    required this.validUntil,
  });
}

class MedicationAlarm {
  final String id;
  final int doseNumber;
  final String doseLabel; // After Breakfast, Before Lunch, etc.
  String alarmTime; // HH:mm format
  bool isEnabled;
  String notificationType; // Sound+Vibration, Sound only, Vibration only, Silent
  int notifyBeforeMinutes;

  MedicationAlarm({
    required this.id,
    required this.doseNumber,
    required this.doseLabel,
    required this.alarmTime,
    this.isEnabled = true,
    this.notificationType = 'Sound+Vibration',
    this.notifyBeforeMinutes = 15,
  });

  MedicationAlarm copyWith({
    String? id,
    int? doseNumber,
    String? doseLabel,
    String? alarmTime,
    bool? isEnabled,
    String? notificationType,
    int? notifyBeforeMinutes,
  }) {
    return MedicationAlarm(
      id: id ?? this.id,
      doseNumber: doseNumber ?? this.doseNumber,
      doseLabel: doseLabel ?? this.doseLabel,
      alarmTime: alarmTime ?? this.alarmTime,
      isEnabled: isEnabled ?? this.isEnabled,
      notificationType: notificationType ?? this.notificationType,
      notifyBeforeMinutes: notifyBeforeMinutes ?? this.notifyBeforeMinutes,
    );
  }
}

class Medication {
  final String id;
  final String name;
  final String dosage;
  final String type;
  final List<String> timingLabels;
  final List<String> timingValues;
  final String timeFrequency;
  final List<int> daysOfWeek;
  final DateTime startDate;
  final DateTime? endDate;
  final DateTime? prescribedDate;
  final DateTime? expiryDate;
  final int? durationDays; // How many days to take (e.g., 7 for 7-day course)
  final String instructions;
  final String warnings;
  final bool alarmEnabled;
  final bool isActive;
  final List<MedicationAlarm> alarms;

  Medication({
    required this.id,
    required this.name,
    required this.dosage,
    required this.type,
    required this.timingLabels,
    required this.timingValues,
    required this.timeFrequency,
    required this.daysOfWeek,
    required this.startDate,
    this.endDate,
    this.prescribedDate,
    this.expiryDate,
    this.durationDays,
    this.instructions = '',
    this.warnings = '',
    this.alarmEnabled = true,
    this.isActive = true,
    List<MedicationAlarm>? alarms,
  }) : alarms = alarms ?? _generateDefaultAlarms(timingLabels, timingValues);

  static List<MedicationAlarm> _generateDefaultAlarms(
    List<String> labels,
    List<String> times,
  ) {
    return List.generate(
      labels.length,
      (i) => MedicationAlarm(
        id: const Uuid().v4(),
        doseNumber: i + 1,
        doseLabel: labels[i],
        alarmTime: times[i],
      ),
    );
  }

  Medication copyWith({
    String? id,
    String? name,
    String? dosage,
    String? type,
    List<String>? timingLabels,
    List<String>? timingValues,
    String? timeFrequency,
    List<int>? daysOfWeek,
    DateTime? startDate,
    DateTime? endDate,
    DateTime? prescribedDate,
    DateTime? expiryDate,
    int? durationDays,
    String? instructions,
    String? warnings,
    bool? alarmEnabled,
    bool? isActive,
    List<MedicationAlarm>? alarms,
  }) {
    return Medication(
      id: id ?? this.id,
      name: name ?? this.name,
      dosage: dosage ?? this.dosage,
      type: type ?? this.type,
      timingLabels: timingLabels ?? this.timingLabels,
      timingValues: timingValues ?? this.timingValues,
      timeFrequency: timeFrequency ?? this.timeFrequency,
      daysOfWeek: daysOfWeek ?? this.daysOfWeek,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      prescribedDate: prescribedDate ?? this.prescribedDate,
      expiryDate: expiryDate ?? this.expiryDate,
      durationDays: durationDays ?? this.durationDays,
      instructions: instructions ?? this.instructions,
      warnings: warnings ?? this.warnings,
      alarmEnabled: alarmEnabled ?? this.alarmEnabled,
      isActive: isActive ?? this.isActive,
      alarms: alarms ?? this.alarms,
    );
  }
}


const List<AppointmentItem> demoAppointments = [
  AppointmentItem(
    id: 'demo-appointment-1',
    status: 'upcoming',
    doctorId: 'demo-doctor-1',
    dateLabel: 'May 22, 2023',
    timeLabel: '10.00 AM',
    consultationLabel: 'Physical Consultation',
    doctorName: 'Dr. Varanasi',
    speciality: 'Orthopedic Surgery',
    location: 'Elite Ortho Clinic, Guindy',
    ticketNumber: 'ARO-DEMO-1001',
    qrPayload: 'demo-qr-1',
    bookedOnLabel: 'May 20, 2023 • 02:30 PM',
  ),
  AppointmentItem(
    id: 'demo-appointment-2',
    status: 'upcoming',
    doctorId: 'demo-doctor-2',
    dateLabel: 'June 14, 2023',
    timeLabel: '15.00 PM',
    consultationLabel: 'Online Consultation',
    doctorName: 'Dr. Sai Kumar',
    speciality: 'Gastroenterologist',
    location: 'Digestive Institute, MM Nagar',
    ticketNumber: 'ARO-DEMO-1002',
    qrPayload: 'demo-qr-2',
    bookedOnLabel: 'June 10, 2023 • 11:15 AM',
  ),
  AppointmentItem(
    id: 'demo-appointment-3',
    status: 'upcoming',
    doctorId: 'demo-doctor-3',
    dateLabel: 'June 21, 2023',
    timeLabel: '10.00 AM',
    consultationLabel: 'Physical Consultation',
    doctorName: 'Dr. Naveen K',
    speciality: 'Cardiologist',
    location: 'Golden Cardiology Center, Potheri',
    ticketNumber: 'ARO-DEMO-1003',
    qrPayload: 'demo-qr-3',
    bookedOnLabel: 'June 15, 2023 • 04:45 PM',
  ),
];
