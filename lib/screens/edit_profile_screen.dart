import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../models/user_model.dart';
import '../services/supabase_service.dart';
import '../widgets/custom_textfield.dart';
import '../widgets/primary_button.dart';

class EditProfileScreen extends StatefulWidget {
  final UserModel user;

  const EditProfileScreen({
    super.key,
    required this.user,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _supabaseService = SupabaseService();

  late TextEditingController _nameController;
  late TextEditingController _nicknameController;
  late TextEditingController _emailController;
  late TextEditingController _phoneController;
  late TextEditingController _dobController;
  late TextEditingController _heightController;
  late TextEditingController _weightController;
  late TextEditingController _allergiesController;
  late TextEditingController _medicalConditionsController;

  String? _selectedGender;
  String? _selectedBloodGroup;
  File? _imageFile;
  String? _currentImageUrl;
  DateTime? _selectedDate;
  bool _isLoading = false;

  final List<String> _genders = ['Male', 'Female', 'Other'];
  final List<String> _bloodGroups = [
    'A+',
    'A-',
    'B+',
    'B-',
    'AB+',
    'AB-',
    'O+',
    'O-'
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
    _nicknameController = TextEditingController(text: widget.user.nickname);
    _emailController = TextEditingController(text: widget.user.email);
    _phoneController = TextEditingController(text: widget.user.phoneNumber);
    _heightController = TextEditingController(
      text: widget.user.height?.toString() ?? '',
    );
    _weightController = TextEditingController(
      text: widget.user.weight?.toString() ?? '',
    );
    _allergiesController = TextEditingController(
      text: widget.user.allergies ?? '',
    );
    _medicalConditionsController = TextEditingController(
      text: widget.user.medicalConditions ?? '',
    );
    _selectedGender = widget.user.gender;
    _selectedBloodGroup = widget.user.bloodGroup;
    _currentImageUrl = widget.user.profileImage;

    if (widget.user.dob != null) {
      _selectedDate = widget.user.dob;
      _dobController = TextEditingController(
        text: DateFormat('dd/MM/yyyy').format(widget.user.dob!),
      );
    } else {
      _dobController = TextEditingController();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nicknameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _dobController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    _allergiesController.dispose();
    _medicalConditionsController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 75,
    );

    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path);
      });
    }
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF1A237E),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
        _dobController.text = DateFormat('dd/MM/yyyy').format(picked);
      });
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      String? imageUrl = _currentImageUrl;

      // Upload new image if selected
      if (_imageFile != null) {
        imageUrl = await _supabaseService.uploadProfileImage(
          widget.user.id!,
          _imageFile!,
        );
      }

      // Parse height and weight
      double? height;
      double? weight;
      if (_heightController.text.isNotEmpty) {
        height = double.tryParse(_heightController.text.trim());
      }
      if (_weightController.text.isNotEmpty) {
        weight = double.tryParse(_weightController.text.trim());
      }

      // Update user data
      final updateData = {
        'name': _nameController.text.trim(),
        'nickname': _nicknameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone_number': _phoneController.text.trim(),
        'gender': _selectedGender,
        'dob': _selectedDate?.toIso8601String().split('T')[0],
        'height': height,
        'weight': weight,
        'blood_group': _selectedBloodGroup,
        'allergies': _allergiesController.text.trim().isEmpty
            ? null
            : _allergiesController.text.trim(),
        'medical_conditions': _medicalConditionsController.text.trim().isEmpty
            ? null
            : _medicalConditionsController.text.trim(),
        if (imageUrl != null) 'profile_image': imageUrl,
      };

      await _supabaseService.updateUser(widget.user.id!, updateData);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate update
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update profile: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Edit Profile',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              // Profile Image
              Center(
                child: Stack(
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        shape: BoxShape.circle,
                        image: _imageFile != null
                            ? DecorationImage(
                                image: FileImage(_imageFile!),
                                fit: BoxFit.cover,
                              )
                            : _currentImageUrl != null
                                ? DecorationImage(
                                    image: NetworkImage(_currentImageUrl!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                      ),
                      child: _imageFile == null && _currentImageUrl == null
                          ? const Icon(
                              Icons.person,
                              size: 60,
                              color: Colors.grey,
                            )
                          : null,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: _pickImage,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            color: Color(0xFF1A237E),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Personal Information Section
              _buildSectionHeader('Personal Information'),
              const SizedBox(height: 16),
              CustomTextField(
                controller: _nameController,
                hintText: 'Full Name',
                prefixIcon: Icons.person_outline,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              CustomTextField(
                controller: _nicknameController,
                hintText: 'Nickname',
                prefixIcon: Icons.person_outline,
              ),
              const SizedBox(height: 16),
              CustomTextField(
                controller: _emailController,
                hintText: 'Email',
                prefixIcon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                enabled: false, // Email cannot be changed
              ),
              const SizedBox(height: 16),
              CustomTextField(
                controller: _phoneController,
                hintText: 'Phone Number',
                prefixIcon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              // Date of Birth
              GestureDetector(
                onTap: _selectDate,
                child: AbsorbPointer(
                  child: CustomTextField(
                    controller: _dobController,
                    hintText: 'Date of Birth',
                    prefixIcon: Icons.calendar_today_outlined,
                    suffixIcon: Icons.calendar_today,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Gender Dropdown
              _buildDropdown(
                value: _selectedGender,
                hintText: 'Gender',
                icon: Icons.people_outline,
                items: _genders,
                onChanged: (value) {
                  setState(() => _selectedGender = value);
                },
              ),
              const SizedBox(height: 32),

              // Health Information Section
              _buildSectionHeader('Health Information'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: CustomTextField(
                      controller: _heightController,
                      hintText: 'Height (cm)',
                      prefixIcon: Icons.height,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: CustomTextField(
                      controller: _weightController,
                      hintText: 'Weight (kg)',
                      prefixIcon: Icons.monitor_weight_outlined,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Blood Group Dropdown
              _buildDropdown(
                value: _selectedBloodGroup,
                hintText: 'Blood Group',
                icon: Icons.bloodtype_outlined,
                items: _bloodGroups,
                onChanged: (value) {
                  setState(() => _selectedBloodGroup = value);
                },
              ),
              const SizedBox(height: 16),
              CustomTextField(
                controller: _allergiesController,
                hintText: 'Allergies (if any)',
                prefixIcon: Icons.warning_amber_outlined,
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              CustomTextField(
                controller: _medicalConditionsController,
                hintText: 'Medical Conditions (if any)',
                prefixIcon: Icons.medical_information_outlined,
                maxLines: 2,
              ),
              const SizedBox(height: 40),
              PrimaryButton(
                text: 'Save Changes',
                onPressed: _saveProfile,
                isLoading: _isLoading,
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Color(0xFF1A237E),
      ),
    );
  }

  Widget _buildDropdown({
    required String? value,
    required String hintText,
    required IconData icon,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: Icon(
            icon,
            color: Colors.grey[600],
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        items: items.map((item) {
          return DropdownMenuItem(
            value: item,
            child: Text(item),
          );
        }).toList(),
        onChanged: onChanged,
      ),
    );
  }
}
