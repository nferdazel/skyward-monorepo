import 'package:equatable/equatable.dart';

import '../../domain/user_model.dart';

abstract class AuthState {
  const AuthState();
}

class AuthInitial extends AuthState with Equatable {
  const AuthInitial();

  @override
  List<Object?> get props => [];
}

class AuthLoading extends AuthState with Equatable {
  const AuthLoading();

  @override
  List<Object?> get props => [];
}

class AuthAuthenticated extends AuthState with Equatable {
  final AppUser user;
  final String token;

  const AuthAuthenticated({required this.user, required this.token});

  @override
  List<Object?> get props => [user, token];
}

class AuthUnauthenticated extends AuthState with Equatable {
  const AuthUnauthenticated();

  @override
  List<Object?> get props => [];
}

class AuthError extends AuthState with Equatable {
  final String message;

  const AuthError({required this.message});

  @override
  List<Object?> get props => [message];
}
