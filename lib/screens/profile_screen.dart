import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../models/user_model.dart';
import '../widgets/medical_loader.dart';
import 'login_screen.dart';
import 'edit_profile_screen.dart';
import '../main.dart';
import '../services/session_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _supabaseService = SupabaseService();
  UserModel? _user;
  bool _isLoading = true;
  bool _isUploadingImage = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    try {
      final currentUserRow = currentUserNotifier.value;
      if (currentUserRow != null) {
        final userId = currentUserRow['id']?.toString() ?? '';
        final response = await Supabase.instance.client
            .from('users')
            .select()
            .eq('id', userId)
            .maybeSingle();
        if (mounted && response != null) {
          setState(() {
            _user = UserModel.fromJson(response);
            _isLoading = false;
          });
        } else if (mounted) {
          setState(() => _isLoading = false);
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _pickAndUploadImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 75,
    );

    if (pickedFile == null) return;

    setState(() => _isUploadingImage = true);

    try {
      if (_user != null && _user!.id != null) {
        final imageUrl = await _supabaseService.uploadProfileImage(
          _user!.id!,
          File(pickedFile.path),
        );

        if (imageUrl != null) {
          await _supabaseService.updateUser(_user!.id!, {
            'profile_image': imageUrl,
          });

          await _loadUserProfile();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Profile photo updated successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  void _logout() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _performLogout();
            },
            child: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _performLogout() async {
    // Clear the local session
    await SessionService.clearLoggedInUser();
    currentUserNotifier.value = null;
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Profile',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: _isLoading
          ? const Center(child: MedicalLoader(size: 96))
          : SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  // Profile Header with editable photo
                  Center(
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF5F5F5),
                                shape: BoxShape.circle,
                                image: _user?.profileImage != null
                                    ? DecorationImage(
                                        image: NetworkImage(
                                          _user!.profileImage!,
                                        ),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                              ),
                              child: _isUploadingImage
                                  ? const Center(
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                Color(0xFF2E86DE),
                                              ),
                                        ),
                                      ),
                                    )
                                  : _user?.profileImage == null
                                  ? const Icon(
                                      Icons.person,
                                      size: 50,
                                      color: Colors.grey,
                                    )
                                  : null,
                            ),
                            // Camera icon for changing photo
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: _isUploadingImage
                                    ? null
                                    : _pickAndUploadImage,
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A237E),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.camera_alt,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _user?.name ?? 'User',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _user?.phoneNumber ?? 'No phone number',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Menu Items
                  _buildMenuItem(
                    icon: Icons.person_outline,
                    title: 'Edit Profile',
                    onTap: () async {
                      if (_user != null) {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EditProfileScreen(user: _user!),
                          ),
                        );
                        // Refresh profile if updated
                        if (result == true) {
                          _loadUserProfile();
                        }
                      }
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.favorite_outline,
                    title: 'Favorite',
                    onTap: () {
                      // Navigate to favorites
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.notifications_outlined,
                    title: 'Notifications',
                    onTap: () {
                      // Navigate to notifications
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.settings_outlined,
                    title: 'Settings',
                    onTap: () {
                      // Navigate to settings
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.help_outline,
                    title: 'Help and Support',
                    onTap: () {
                      // Navigate to help
                    },
                  ),
                  _buildMenuItem(
                    icon: Icons.description_outlined,
                    title: 'Terms and Conditions',
                    onTap: () {
                      // Navigate to terms
                    },
                  ),
                  const SizedBox(height: 16),
                  // Logout button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: InkWell(
                      onTap: _logout,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withAlpha(25),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.logout, color: Colors.red, size: 24),
                            SizedBox(width: 16),
                            Text(
                              'Log Out',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Icon(icon, color: Colors.black87, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}
