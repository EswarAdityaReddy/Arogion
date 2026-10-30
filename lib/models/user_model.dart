class UserModel {
  final String? id;
  final String? firebaseUid;
  final String name;
  final String? nickname;
  final String email;
  final DateTime? dob;
  final String? gender;
  final String? profileImage;
  final String? phoneNumber;
  final double? height;
  final double? weight;
  final String? bloodGroup;
  final String? allergies;
  final String? medicalConditions;
  final DateTime? createdAt;

  UserModel({
    this.id,
    this.firebaseUid,
    required this.name,
    this.nickname,
    required this.email,
    this.dob,
    this.gender,
    this.profileImage,
    this.phoneNumber,
    this.height,
    this.weight,
    this.bloodGroup,
    this.allergies,
    this.medicalConditions,
    this.createdAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'],
      firebaseUid: json['firebase_uid'],
      name: json['name'] ?? '',
      nickname: json['nickname'],
      email: json['email'] ?? '',
      dob: json['dob'] != null ? DateTime.parse(json['dob']) : null,
      gender: json['gender'],
      profileImage: json['profile_image'],
      phoneNumber: json['phone_number'],
      height: json['height']?.toDouble(),
      weight: json['weight']?.toDouble(),
      bloodGroup: json['blood_group'],
      allergies: json['allergies'],
      medicalConditions: json['medical_conditions'],
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'firebase_uid': firebaseUid,
      'name': name,
      'nickname': nickname,
      'email': email,
      'dob': dob?.toIso8601String().split('T').first,
      'gender': gender,
      'profile_image': profileImage,
      'phone_number': phoneNumber,
      'height': height,
      'weight': weight,
      'blood_group': bloodGroup,
      'allergies': allergies,
      'medical_conditions': medicalConditions,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  UserModel copyWith({
    String? id,
    String? firebaseUid,
    String? name,
    String? nickname,
    String? email,
    DateTime? dob,
    String? gender,
    String? profileImage,
    String? phoneNumber,
    double? height,
    double? weight,
    String? bloodGroup,
    String? allergies,
    String? medicalConditions,
    DateTime? createdAt,
  }) {
    return UserModel(
      id: id ?? this.id,
      firebaseUid: firebaseUid ?? this.firebaseUid,
      name: name ?? this.name,
      nickname: nickname ?? this.nickname,
      email: email ?? this.email,
      dob: dob ?? this.dob,
      gender: gender ?? this.gender,
      profileImage: profileImage ?? this.profileImage,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      height: height ?? this.height,
      weight: weight ?? this.weight,
      bloodGroup: bloodGroup ?? this.bloodGroup,
      allergies: allergies ?? this.allergies,
      medicalConditions: medicalConditions ?? this.medicalConditions,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
