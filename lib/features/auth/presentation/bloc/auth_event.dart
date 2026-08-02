part of 'auth_bloc.dart';

abstract class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

/// Hydrate the session from storage on startup.
class AuthCheckSession extends AuthEvent {
  const AuthCheckSession();
}

/// Attempt login with an entered passcode.
class AuthLoginRequested extends AuthEvent {
  final String passcode;

  const AuthLoginRequested(this.passcode);

  @override
  List<Object?> get props => [passcode];
}

/// Clear the session.
class AuthLogout extends AuthEvent {
  const AuthLogout();
}
