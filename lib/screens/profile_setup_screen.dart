import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../services/supabase_service.dart';
import '../models/user_model.dart';
import '../widgets/custom_textfield.dart';
import '../widgets/primary_button.dart';
import '../bottom_navbar.dart';
import '../main.dart';

class ProfileSetupScreen extends StatefulWidget {
  final String? initialName;
  final String? initialEmail;
  /// The Supabase users table row ID. Required when creating a new profile.
  final String? userId;

  const ProfileSetupScreen({
    super.key,
    this.initialName,
    this.initialEmail,
    this.userId,
  });

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _emailController = TextEditingController();
  final _dobController = TextEditingController();
  final _supabaseService = SupabaseService();
  final _imagePicker = ImagePicker();

  File? _profileImage;
  DateTime? _selectedDate;
  String? _selectedGender;
  bool _isLoading = false;

  final List<String> _genderOptions = ['Male', 'Female', 'Other'];

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName ?? '';
    _emailController.text = widget.initialEmail ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nicknameController.dispose();
    _emailController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 80,
    );

    if (image != null) {
      setState(() {
        _profileImage = File(image.path);
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

    if (picked != null) {
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
      // Determine the user id – either passed in (signup flow) or from the global notifier (edit flow)
      final resolvedId = widget.userId ?? currentUserNotifier.value?['id']?.toString();
      if (resolvedId == null || resolvedId.isEmpty) {
        throw 'User session not found. Please sign in again.';
      }

      String? profileImageUrl;
      if (_profileImage != null) {
        profileImageUrl = await _supabaseService.uploadProfileImage(
          resolvedId,
          _profileImage!,
        );
      }

      final user = UserModel(
        id: resolvedId,
        name: _nameController.text.trim(),
        nickname: _nicknameController.text.trim().isEmpty
            ? null
            : _nicknameController.text.trim(),
        email: _emailController.text.trim(),
        dob: _selectedDate,
        gender: _selectedGender,
        profileImage: profileImageUrl,
        createdAt: DateTime.now(),
      );

      await _supabaseService.updateUser(resolvedId, {
        'name': user.name,
        'nickname': user.nickname,
        'email': user.email,
        'dob': user.dob?.toIso8601String().split('T').first,
        'gender': user.gender,
        if (profileImageUrl != null) 'profile_image': profileImageUrl,
      });

      if (mounted) {
        _showSuccessDialog();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  color: Color(0xFF1A237E),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  color: Colors.white,
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Profile Saved!',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Your account is ready to use.',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                text: 'Go to Home',
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const BottomNavBar()),
                    (route) => false,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _validateName(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your full name';
    }
    return null;
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your email';
    }
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value)) {
      return 'Please enter a valid email';
    }
    return null;
  }

  String? _validateDob(String? value) {
    if (_selectedDate == null) {
      return 'Please select your date of birth';
    }
    return null;
  }

  String? _validateGender(String? value) {
    if (_selectedGender == null) {
      return 'Please select your gender';
    }
    return null;
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
          'Fill Your Profile',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Form(
            key: _formKey,
            child: Column(
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
                          image: _profileImage != null
                              ? DecorationImage(
                                  image: FileImage(_profileImage!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _profileImage == null
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
                // Full Name
                CustomTextField(
                  controller: _nameController,
                  hintText: 'Full Name',
                  validator: _validateName,
                ),
                const SizedBox(height: 16),
                // Nickname
                CustomTextField(
                  controller: _nicknameController,
                  hintText: 'Nickname',
                ),
                const SizedBox(height: 16),
                // Email
                CustomTextField(
                  controller: _emailController,
                  hintText: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  validator: _validateEmail,
                  readOnly: true,
                ),
                const SizedBox(height: 16),
                // Date of Birth
                CustomTextField(
                  controller: _dobController,
                  hintText: 'Date of Birth',
                  suffixIcon: Icons.calendar_today,
                  readOnly: true,
                  onTap: _selectDate,
                  validator: _validateDob,
                ),
                const SizedBox(height: 16),
                // Gender Dropdown
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: DropdownButtonFormField<String>(
                    value: _selectedGender,
                    hint: Text(
                      'Gender',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 16,
                      ),
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                    ),
                    icon: Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.grey[400],
                    ),
                    items: _genderOptions.map((String gender) {
                      return DropdownMenuItem<String>(
                        value: gender,
                        child: Text(gender),
                      );
                    }).toList(),
                    validator: _validateGender,
                    onChanged: (String? value) {
                      setState(() {
                        _selectedGender = value;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 40),
                // Save Button
                PrimaryButton(
                  text: 'Save',
                  onPressed: _saveProfile,
                  isLoading: _isLoading,
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
