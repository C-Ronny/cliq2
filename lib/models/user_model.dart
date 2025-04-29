class UserModel {
  final String id;
  final String email;
  final String firstName;
  final String lastName;
  final String? username;
  final String? profilePicture;

  UserModel({
    required this.id,
    required this.email,
    required this.firstName,
    required this.lastName,
    this.username,
    this.profilePicture,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as String,
      email: json['email'] as String,
      firstName: json['first_name'] as String,
      lastName: json['last_name'] as String,
      username: json['username'] as String?,
      profilePicture: json['profile_picture'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'first_name': firstName,
      'last_name': lastName,
      'username': username,
      'profile_picture': profilePicture,
    };
  }
}