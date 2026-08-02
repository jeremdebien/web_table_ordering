part of 'auth_bloc.dart';

sealed class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

/// Before the startup session check has run.
class AuthInitial extends AuthState {}

/// Reading the persisted session.
class AuthChecking extends AuthState {}

/// No session — show the PIN login.
class AuthUnauthenticated extends AuthState {}

/// Verifying an entered passcode.
class AuthAuthenticating extends AuthState {}

/// A waiter is logged in.
class AuthAuthenticated extends AuthState {
  final AuthUserModel user;

  const AuthAuthenticated(this.user);

  @override
  List<Object?> get props => [user.id];
}

/// Login attempt failed (wrong PIN or server error).
class AuthFailure extends AuthState {
  final String message;

  const AuthFailure(this.message);

  @override
  List<Object?> get props => [message];
}
